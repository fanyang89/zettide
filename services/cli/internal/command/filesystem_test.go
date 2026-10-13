package command

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"testing"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

const filesystemTestID = "0198f54d-5c2a-7000-8000-000000000301"
const filesystemTestPool = "0198f54d-5c2a-7000-8000-000000000001"

type filesystemTestServer struct {
	pb.UnimplementedFilesystemServiceServer
	mutations []*pb.FilesystemMutationRequest
	methods   []string
	get       *pb.GetFilesystemRequest
	list      *pb.ListFilesystemsRequest
	failure   error
}

func (s *filesystemTestServer) mutation(method string, r *pb.FilesystemMutationRequest) (*pb.FilesystemResponse, error) {
	s.mutations = append(s.mutations, r)
	s.methods = append(s.methods, method)
	if s.failure != nil {
		return nil, s.failure
	}
	fs := &pb.Filesystem{
		Id: r.FilesystemId, PoolId: r.PoolId, Name: r.Name, Description: r.Description,
		BackendKind: pb.FilesystemBackendKind_FILESYSTEM_BACKEND_KIND_BLOB,
		NameProfile: r.NameProfile, FormatVersion: 1, ResourceVersion: 12,
		LifecycleState: pb.FilesystemLifecycleState_FILESYSTEM_LIFECYCLE_STATE_PROVISIONING,
	}
	if method == "delete" {
		fs.LifecycleState = pb.FilesystemLifecycleState_FILESYSTEM_LIFECYCLE_STATE_DELETED
		fs.DeletedRevision = 12
	}
	return &pb.FilesystemResponse{Filesystem: fs}, nil
}

func (s *filesystemTestServer) CreateFilesystem(_ context.Context, r *pb.FilesystemMutationRequest) (*pb.FilesystemResponse, error) {
	return s.mutation("create", r)
}
func (s *filesystemTestServer) UpdateFilesystem(_ context.Context, r *pb.FilesystemMutationRequest) (*pb.FilesystemResponse, error) {
	return s.mutation("update", r)
}
func (s *filesystemTestServer) DeleteFilesystem(_ context.Context, r *pb.FilesystemMutationRequest) (*pb.FilesystemResponse, error) {
	return s.mutation("delete", r)
}
func (s *filesystemTestServer) GetFilesystem(_ context.Context, r *pb.GetFilesystemRequest) (*pb.FilesystemResponse, error) {
	s.get = r
	if s.failure != nil {
		return nil, s.failure
	}
	return &pb.FilesystemResponse{Filesystem: &pb.Filesystem{Id: r.FilesystemId, Name: "files", ResourceVersion: 12}}, nil
}
func (s *filesystemTestServer) ListFilesystems(_ context.Context, r *pb.ListFilesystemsRequest) (*pb.ListFilesystemsResponse, error) {
	s.list = r
	if s.failure != nil {
		return nil, s.failure
	}
	if r.AfterFilesystemId != "" {
		return &pb.ListFilesystemsResponse{}, nil
	}
	return &pb.ListFilesystemsResponse{
		Filesystems:           []*pb.Filesystem{{Id: filesystemTestID, Name: "files", ResourceVersion: 12}},
		NextAfterFilesystemId: filesystemTestID,
	}, nil
}

func filesystemTestApp(t *testing.T, format string) (*app, *filesystemTestServer, *bytes.Buffer) {
	t.Helper()
	listener := bufconn.Listen(1024 * 1024)
	server := grpc.NewServer()
	service := &filesystemTestServer{}
	pb.RegisterFilesystemServiceServer(server, service)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { server.Stop(); _ = listener.Close() })
	conn, err := grpc.NewClient("passthrough:///bufnet", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return listener.DialContext(ctx) }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	output := new(bytes.Buffer)
	return &app{conn: conn, printer: newPrinter(output, format), stderr: new(bytes.Buffer)}, service, output
}

func filesystemCreateArgs() []string {
	return []string{"filesystem", "create", "--filesystem-id", filesystemTestID, "--pool-id", filesystemTestPool, "--name", "files"}
}

func TestFilesystemCreateProfilesAndOutput(t *testing.T) {
	for _, format := range []string{"table", "json"} {
		for _, profile := range []string{"", "legacy-raw", "portable-v1"} {
			t.Run(format+"/"+profile, func(t *testing.T) {
				a, service, output := filesystemTestApp(t, format)
				args := append(filesystemCreateArgs(), "--request-id", "create-1", "--description", "shared files")
				wantProfile := pb.FilesystemNameProfile_FILESYSTEM_NAME_PROFILE_LEGACY_RAW
				if profile != "" {
					args = append(args, "--name-profile", profile)
				}
				if profile == "portable-v1" {
					wantProfile = pb.FilesystemNameProfile_FILESYSTEM_NAME_PROFILE_PORTABLE_V1
				}
				if err := a.runController(t.Context(), args); err != nil {
					t.Fatal(err)
				}
				want := &pb.FilesystemMutationRequest{RequestId: "create-1", FilesystemId: filesystemTestID, PoolId: filesystemTestPool,
					Name: "files", Description: "shared files", BackendKind: pb.FilesystemBackendKind_FILESYSTEM_BACKEND_KIND_BLOB, NameProfile: wantProfile}
				if len(service.mutations) != 1 || !proto.Equal(service.mutations[0], want) || service.methods[0] != "create" {
					t.Fatalf("unexpected create: %v", service.mutations)
				}
				for _, expected := range []string{filesystemTestID, "FILESYSTEM_LIFECYCLE_STATE_PROVISIONING", wantProfile.String(), "shared files"} {
					if !strings.Contains(output.String(), expected) {
						t.Fatalf("missing %q in output: %s", expected, output)
					}
				}
			})
		}
	}
}

func TestFilesystemUpdateDeleteAndExactRetry(t *testing.T) {
	a, service, output := filesystemTestApp(t, "json")
	for _, op := range []string{"update", "delete"} {
		args := []string{"filesystem", op, "--filesystem-id", filesystemTestID, "--expected-resource-version", "11", "--request-id", op + "-1"}
		if op == "update" {
			args = append(args, "--description", "")
		}
		for range 2 {
			output.Reset()
			if err := a.runController(t.Context(), args); err != nil {
				t.Fatal(err)
			}
			want := &pb.FilesystemMutationRequest{RequestId: op + "-1", FilesystemId: filesystemTestID, ExpectedResourceVersion: 11}
			last := len(service.mutations) - 1
			if service.methods[last] != op || !proto.Equal(service.mutations[last], want) {
				t.Fatalf("unexpected %s request: %v", op, service.mutations[last])
			}
			var response pb.FilesystemResponse
			if err := protojson.Unmarshal(output.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Filesystem.ResourceVersion != 12 || (op == "delete" && response.Filesystem.DeletedRevision != 12) {
				t.Fatalf("missing versions: %v", &response)
			}
		}
	}
}

func TestFilesystemGetAndCursor(t *testing.T) {
	for _, format := range []string{"table", "json"} {
		t.Run(format, func(t *testing.T) {
			a, service, output := filesystemTestApp(t, format)
			if err := a.runController(t.Context(), []string{"filesystem", "get", "--filesystem-id", filesystemTestID}); err != nil {
				t.Fatal(err)
			}
			if service.get.GetFilesystemId() != filesystemTestID || !strings.Contains(output.String(), filesystemTestID) {
				t.Fatalf("unexpected get: %v / %s", service.get, output)
			}
			output.Reset()
			if err := a.runController(t.Context(), []string{"filesystem", "list", "--pool-id", filesystemTestPool, "--page-size", "32"}); err != nil {
				t.Fatal(err)
			}
			if !proto.Equal(service.list, &pb.ListFilesystemsRequest{PoolId: filesystemTestPool, PageSize: 32}) {
				t.Fatalf("unexpected list: %v", service.list)
			}
			if format == "table" {
				if !strings.Contains(output.String(), "NEXT_AFTER_FILESYSTEM_ID\t"+filesystemTestID) {
					t.Fatalf("missing text cursor: %s", output)
				}
			} else {
				var response pb.ListFilesystemsResponse
				if err := protojson.Unmarshal(output.Bytes(), &response); err != nil || response.NextAfterFilesystemId != filesystemTestID {
					t.Fatalf("missing JSON cursor: %s (%v)", output, err)
				}
			}
			output.Reset()
			if err := a.runController(t.Context(), []string{"filesystem", "list", "--pool-id", filesystemTestPool, "--after-filesystem-id", filesystemTestID}); err != nil {
				t.Fatal(err)
			}
			if service.list.AfterFilesystemId != filesystemTestID || service.list.PageSize != 0 {
				t.Fatalf("unexpected continuation: %v", service.list)
			}
			if format == "table" && (!strings.Contains(output.String(), "(no rows)") || strings.Contains(output.String(), "NEXT_AFTER_FILESYSTEM_ID")) {
				t.Fatalf("unexpected empty page: %s", output)
			}
		})
	}
}

func TestFilesystemValidationBeforeRPC(t *testing.T) {
	cases := [][]string{
		{"filesystem", "create"},
		{"filesystem", "get"},
		{"filesystem", "get", "--filesystem-id", strings.ToUpper(filesystemTestID)},
		{"filesystem", "get", "--filesystem-id", "0198f54d-5c2a-4000-8000-000000000301"},
		{"filesystem", "get", "--filesystem-id", filesystemTestID, "unexpected"},
		{"filesystem", "list"},
		{"filesystem", "list", "--pool-id", filesystemTestPool, "--page-size", "33"},
		{"filesystem", "list", "--pool-id", filesystemTestPool, "--page-size", "-1"},
		{"filesystem", "list", "--pool-id", filesystemTestPool, "--page-size", "18446744073709551616"},
		{"filesystem", "list", "--pool-id", filesystemTestPool, "--after-filesystem-id", "AA=="},
		{"filesystem", "update", "--filesystem-id", filesystemTestID},
		{"filesystem", "delete", "--filesystem-id", filesystemTestID, "--expected-resource-version", "0"},
		{"filesystem", "update", "--filesystem-id", filesystemTestID, "--expected-resource-version", "1", "--pool-id", filesystemTestPool},
		{"filesystem", "delete", "--filesystem-id", filesystemTestID, "--expected-resource-version", "1", "--description", "changed"},
	}
	for _, flags := range [][]string{
		{"--name", ""}, {"--name", strings.Repeat("é", 64)}, {"--description", strings.Repeat("x", 1025)},
		{"--description", "\xff"}, {"--request-id", strings.Repeat("x", 128)}, {"--request-id", "\xff"},
		{"--name-profile", "unknown"}, {"--pool-id", "bad"}, {"--filesystem-id", ""},
	} {
		cases = append(cases, append(filesystemCreateArgs(), flags...))
	}
	for _, args := range cases {
		a := app{stderr: io.Discard}
		if err := a.runController(t.Context(), args); err == nil {
			t.Fatalf("accepted invalid flags: %q", args)
		}
	}
	for _, op := range []string{"create", "get", "list", "update", "delete"} {
		a := app{stderr: io.Discard}
		if err := a.runController(t.Context(), []string{"filesystem", op, "-h"}); !errors.Is(err, ErrHelp) {
			t.Fatalf("%s help: %v", op, err)
		}
	}
}

func TestFilesystemTextBoundaries(t *testing.T) {
	a, service, _ := filesystemTestApp(t, "json")
	name := strings.Repeat("é", 63) + "x"
	description := strings.Repeat("界", 341) + "x"
	args := append(filesystemCreateArgs(), "--name", name, "--description", description, "--request-id", name)
	if err := a.runController(t.Context(), args); err != nil {
		t.Fatal(err)
	}
	if service.mutations[0].Name != name || service.mutations[0].Description != description || service.mutations[0].RequestId != name {
		t.Fatal("text boundary changed")
	}
}

func TestFilesystemRPCFailureRetainsGeneratedRetryKey(t *testing.T) {
	a, service, _ := filesystemTestApp(t, "json")
	service.failure = status.Error(codes.Unavailable, "unknown outcome")
	for _, op := range []string{"create", "update", "delete"} {
		args := filesystemCreateArgs()
		if op != "create" {
			args = []string{"filesystem", op, "--filesystem-id", filesystemTestID, "--expected-resource-version", "11"}
		}
		before := len(service.mutations)
		err := a.runController(t.Context(), args)
		if status.Code(err) != codes.Unavailable || len(service.mutations) != before+1 {
			t.Fatalf("%s changed status or retried: %v", op, err)
		}
		id := service.mutations[before].RequestId
		if !strings.HasPrefix(id, "zettidectl-") || !strings.Contains(err.Error(), id) {
			t.Fatalf("lost retry key %q: %v", id, err)
		}
	}
}

type filesystemFailWriter struct{}

func (filesystemFailWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestFilesystemOutputFailureRetainsRetryKey(t *testing.T) {
	a, service, _ := filesystemTestApp(t, "json")
	a.printer.w = filesystemFailWriter{}
	err := a.runController(t.Context(), filesystemCreateArgs())
	if !errors.Is(err, io.ErrClosedPipe) || len(service.mutations) != 1 || !strings.Contains(err.Error(), service.mutations[0].RequestId) || !strings.Contains(err.Error(), "committed") {
		t.Fatalf("lost commit result or retry key: %v", err)
	}
}
