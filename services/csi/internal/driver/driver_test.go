package driver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSocketPath(t *testing.T) {
	t.Parallel()

	path, err := socketPath("unix:///tmp/csi.sock")
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/csi.sock" {
		t.Fatalf("unexpected socket path %q", path)
	}
	if _, err := socketPath("tcp://127.0.0.1:9000"); err == nil {
		t.Fatal("TCP endpoint unexpectedly accepted")
	}
}

func TestConfinedExistingPathRejectsEscapingSymlink(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(outside, []byte("target"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := confinedExistingPath(root, link, true); err == nil {
		t.Fatal("escaping source symlink unexpectedly accepted")
	}
}

func TestConfinedPublishPath(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	target := filepath.Join(root, "pod", "volume")
	if err := os.MkdirAll(target, 0o750); err != nil {
		t.Fatal(err)
	}
	resolved, err := confinedExistingDirectory(root, target)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != target {
		t.Fatalf("unexpected target path %q", resolved)
	}
	if _, err := confinedExistingDirectory(root, filepath.Join(root, "..", "escape")); err == nil {
		t.Fatal("escaping publish path unexpectedly accepted")
	}
}

func TestConfinedMissingPath(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	target := filepath.Join(root, "missing", "pod", "volume")
	resolved, err := confinedMissingPath(root, target)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != target {
		t.Fatalf("unexpected target path %q", resolved)
	}

	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := confinedMissingPath(root, filepath.Join(root, "escape", "volume")); err == nil {
		t.Fatal("escaping missing path unexpectedly accepted")
	}
}

func TestRecordKeyIncludesPublishTarget(t *testing.T) {
	t.Parallel()

	first := recordKey("volume", "/var/lib/kubelet/pods/a")
	second := recordKey("volume", "/var/lib/kubelet/pods/b")
	if first == second {
		t.Fatal("record key ignored publish target")
	}
}
