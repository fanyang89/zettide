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
	request *pb.CreatePoolRequest
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
