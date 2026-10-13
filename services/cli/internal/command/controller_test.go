package command

import (
	"bytes"
	"context"
	"net"
	"strings"
	"testing"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

type poolTestServer struct {
	pb.UnimplementedPoolServiceServer
	request  *pb.CreatePoolRequest
	update   *pb.UpdatePoolRequest
	deletion *pb.DeletePoolRequest
}

func (server *poolTestServer) CreatePool(_ context.Context, request *pb.CreatePoolRequest) (*pb.CreatePoolResponse, error) {
	server.request = request
	return &pb.CreatePoolResponse{Pool: &pb.Pool{Id: "pool-1", Name: request.Name, Description: request.Description}}, nil
}

func TestCreatePoolCommand(t *testing.T) {
	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	service := &poolTestServer{}
	pb.RegisterPoolServiceServer(grpcServer, service)
	go func() {
		_ = grpcServer.Serve(listener)
	}()
	t.Cleanup(func() {
		grpcServer.Stop()
		_ = listener.Close()
	})

	conn, err := grpc.NewClient(
		"passthrough:///bufnet",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return listener.Dial() }),
	)
	if err != nil {
		t.Fatalf("create client: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	var output bytes.Buffer
	a := app{conn: conn, printer: newPrinter(&output, "table"), stderr: &bytes.Buffer{}}
	if err := a.createPool(context.Background(), []string{
		"--name", "fast", "--description", "NVMe pool", "--request-id", "request-1",
	}); err != nil {
		t.Fatalf("create pool: %v", err)
	}
	if service.request == nil || service.request.RequestId != "request-1" || service.request.Name != "fast" {
		t.Fatalf("unexpected request: %+v", service.request)
	}
	for _, expected := range []string{"pool-1", "fast", "NVMe pool"} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("output does not contain %q:\n%s", expected, output.String())
		}
	}
}

func TestGetPoolRequiresOneSelector(t *testing.T) {
	a := app{stderr: &bytes.Buffer{}}
	if err := a.getPool(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("got error %v, want selector validation", err)
	}
	if err := a.getPool(context.Background(), []string{"--id", "one", "--name", "two"}); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("got error %v, want selector validation", err)
	}
}

func (server *poolTestServer) UpdatePool(_ context.Context, request *pb.UpdatePoolRequest) (*pb.UpdatePoolResponse, error) {
	server.update = request
	return &pb.UpdatePoolResponse{Pool: &pb.Pool{Id: request.PoolId, Description: request.Description, ResourceVersion: 8}}, nil
}

func (server *poolTestServer) DeletePool(_ context.Context, request *pb.DeletePoolRequest) (*pb.DeletePoolResponse, error) {
	server.deletion = request
	return &pb.DeletePoolResponse{Pool: &pb.Pool{Id: request.PoolId, ResourceVersion: 9, DeletedRevision: 9}}, nil
}

func TestPoolMutationCommands(t *testing.T) {
	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	service := &poolTestServer{}
	pb.RegisterPoolServiceServer(grpcServer, service)
	go func() { _ = grpcServer.Serve(listener) }()
	t.Cleanup(func() { grpcServer.Stop(); _ = listener.Close() })
	conn, err := grpc.NewClient("passthrough:///bufnet", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return listener.Dial() }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	var output bytes.Buffer
	a := app{conn: conn, printer: newPrinter(&output, "json"), stderr: &bytes.Buffer{}}
	const poolID = "0198f54d-5c2a-7000-8000-000000000001"
	if err := a.runController(t.Context(), []string{"pool", "update", "--pool-id", poolID, "--description", "updated", "--expected-resource-version", "7", "--request-id", "update-1"}); err != nil {
		t.Fatal(err)
	}
	if service.update == nil || service.update.RequestId != "update-1" || service.update.PoolId != poolID || service.update.Description != "updated" || service.update.ExpectedResourceVersion != 7 {
		t.Fatalf("unexpected update: %+v", service.update)
	}
	if !strings.Contains(output.String(), `"resource_version":`) {
		t.Fatalf("missing version in output: %s", output.String())
	}
	output.Reset()
	if err := a.runController(t.Context(), []string{"pool", "delete", "--pool-id", poolID, "--expected-resource-version", "8", "--request-id", "delete-1"}); err != nil {
		t.Fatal(err)
	}
	if service.deletion == nil || service.deletion.RequestId != "delete-1" || service.deletion.PoolId != poolID || service.deletion.ExpectedResourceVersion != 8 {
		t.Fatalf("unexpected delete: %+v", service.deletion)
	}
	if !strings.Contains(output.String(), `"deleted_revision":`) {
		t.Fatalf("missing deletion in output: %s", output.String())
	}
}

func TestPoolMutationsValidateBeforeRPC(t *testing.T) {
	for _, command := range []string{"update", "delete"} {
		for _, flags := range [][]string{nil, {"--pool-id", "0198f54d-5c2a-7000-8000-000000000001"}, {"--pool-id", "invalid", "--expected-resource-version", "1"}} {
			a := app{stderr: &bytes.Buffer{}}
			args := append([]string{"pool", command}, flags...)
			if err := a.runController(t.Context(), args); err == nil {
				t.Fatalf("accepted invalid flags: %v", args)
			}
		}
	}
}
