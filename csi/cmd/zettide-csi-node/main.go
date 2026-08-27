package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/fanyang89/zettide/csi/internal/driver"
)

var version = "dev"

func main() {
	var options driver.Options
	flag.StringVar(&options.Endpoint, "endpoint", "unix:///csi/csi.sock", "CSI Unix socket endpoint")
	flag.StringVar(&options.NodeID, "node-id", "", "stable Kubernetes node identifier")
	flag.StringVar(&options.ZettidePath, "zettide-path", "/usr/local/bin/zettide", "zettide executable")
	flag.StringVar(&options.FusermountPath, "fusermount-path", "/usr/bin/fusermount3", "fusermount3 executable")
	flag.StringVar(&options.StateDir, "state-dir", "/var/lib/zettide-csi/state", "persistent node state directory")
	flag.StringVar(&options.AllowedSourceRoot, "source-root", "/var/lib/zettide-csi-targets", "allowed static target root")
	flag.StringVar(&options.AllowedPublishRoot, "publish-root", "/var/lib/kubelet/pods", "allowed kubelet publish root")
	flag.Parse()
	options.Version = version

	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if err := driver.Run(ctx, options, logger); err != nil {
		logger.Error("CSI node service failed", "error", err)
		os.Exit(1)
	}
}
