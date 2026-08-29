package command

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
)

func TestParseUUIDv7(t *testing.T) {
	got, err := parseUUIDv7("0198f54d-5c2a-7000-8000-000000000001", "id")
	if err != nil {
		t.Fatalf("parse UUIDv7: %v", err)
	}
	if len(got) != 16 {
		t.Fatalf("got %d bytes, want 16", len(got))
	}
	if _, err := parseUUIDv7("0198f54d-5c2a-4000-8000-000000000001", "id"); err == nil {
		t.Fatal("accepted a UUID that is not version 7")
	}
}

func TestControllerValidationLimits(t *testing.T) {
	if _, err := checkedPageSize(1000); err != nil {
		t.Fatalf("accepted page size rejected: %v", err)
	}
	if _, err := checkedPageSize(1001); err == nil {
		t.Fatal("accepted page size above controller limit")
	}
	for _, size := range []uint64{256 * 1024, 10 * 1024 * 1024} {
		if err := validateVolumeSize(size); err != nil {
			t.Fatalf("accepted volume size %d rejected: %v", size, err)
		}
	}
	for _, size := range []uint64{1, 256*1024 + 1, uint64(1<<32) * 4096} {
		if err := validateVolumeSize(size); err == nil {
			t.Fatalf("invalid volume size %d accepted", size)
		}
	}
}

func TestValidateUUIDv7TextRequiresCanonicalForm(t *testing.T) {
	if err := validateUUIDv7Text("0198f54d-5c2a-7000-8000-000000000001", "id"); err != nil {
		t.Fatalf("canonical UUIDv7 rejected: %v", err)
	}
	if err := validateUUIDv7Text("0198f54d5c2a70008000000000000001", "id"); err == nil {
		t.Fatal("non-canonical UUID text accepted")
	}
}

func TestParsePageToken(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("next"))
	got, err := parsePageToken(encoded)
	if err != nil {
		t.Fatalf("parse page token: %v", err)
	}
	if string(got) != "next" {
		t.Fatalf("got %q, want next", got)
	}
}

func TestPrinterFormatsListAsTable(t *testing.T) {
	var output bytes.Buffer
	message := &pb.ListPoolsResponse{
		Pools:         []*pb.Pool{{Id: "pool-1", Name: "fast"}},
		NextPageToken: []byte("next"),
	}
	if err := newPrinter(&output, "table").print(message); err != nil {
		t.Fatalf("print table: %v", err)
	}
	for _, expected := range []string{"ID", "NAME", "pool-1", "fast", "NEXT_PAGE_TOKEN", "bmV4dA=="} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("output does not contain %q:\n%s", expected, output.String())
		}
	}
}

func TestPrinterFormatsProtoJSON(t *testing.T) {
	var output bytes.Buffer
	if err := newPrinter(&output, "json").print(&pb.GetNodeResponse{Node: &pb.Node{Id: "node-1"}}); err != nil {
		t.Fatalf("print JSON: %v", err)
	}
	var decoded struct {
		Node struct {
			ID string `json:"id"`
		} `json:"node"`
	}
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("decode output JSON: %v", err)
	}
	if decoded.Node.ID != "node-1" {
		t.Fatalf("unexpected JSON:\n%s", output.String())
	}
}
