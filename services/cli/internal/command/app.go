package command

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

var ErrHelp = errors.New("help requested")

type options struct {
	endpoint      string
	output        string
	timeout       time.Duration
	tlsCA         string
	tlsServerName string
}

type app struct {
	conn    grpc.ClientConnInterface
	printer *printer
	stderr  io.Writer
}

func Run(ctx context.Context, args []string, stdout, stderr io.Writer, version string) error {
	var opts options
	fs := flag.NewFlagSet("zettidectl", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.endpoint, "endpoint", os.Getenv("ZETTIDE_ENDPOINT"), "gRPC target host:port (or ZETTIDE_ENDPOINT)")
	fs.StringVar(&opts.output, "output", "table", "output format: table or json")
	fs.DurationVar(&opts.timeout, "timeout", 10*time.Second, "RPC timeout")
	fs.StringVar(&opts.tlsCA, "tls-ca", "", "PEM CA file; enables TLS")
	fs.StringVar(&opts.tlsServerName, "tls-server-name", "", "TLS server name override")
	showVersion := fs.Bool("version", false, "print version")
	fs.Usage = func() { writeRootUsage(stderr, fs) }

	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return ErrHelp
		}
		return err
	}
	if *showVersion {
		fmt.Fprintln(stdout, version)
		return nil
	}
	if opts.endpoint == "" {
		return errors.New("--endpoint is required (or set ZETTIDE_ENDPOINT)")
	}
	if opts.timeout <= 0 {
		return errors.New("--timeout must be positive")
	}
	if opts.output != "table" && opts.output != "json" {
		return fmt.Errorf("unsupported --output %q (want table or json)", opts.output)
	}
	remaining := fs.Args()
	if len(remaining) == 0 {
		writeRootUsage(stderr, fs)
		return errors.New("a target is required (controller or data-node)")
	}

	transport, err := transportCredentials(opts)
	if err != nil {
		return err
	}
	conn, err := grpc.NewClient(opts.endpoint, grpc.WithTransportCredentials(transport))
	if err != nil {
		return fmt.Errorf("create gRPC client: %w", err)
	}
	defer conn.Close()

	rpcCtx, cancel := context.WithTimeout(ctx, opts.timeout)
	defer cancel()

	a := app{conn: conn, printer: newPrinter(stdout, opts.output), stderr: stderr}
	switch remaining[0] {
	case "controller":
		return a.runController(rpcCtx, remaining[1:])
	case "data-node":
		return a.runDataNode(rpcCtx, remaining[1:])
	default:
		return fmt.Errorf("unknown target %q (want controller or data-node)", remaining[0])
	}
}

func transportCredentials(opts options) (credentials.TransportCredentials, error) {
	if opts.tlsCA == "" {
		if opts.tlsServerName != "" {
			return nil, errors.New("--tls-server-name requires --tls-ca")
		}
		return insecure.NewCredentials(), nil
	}

	pem, err := os.ReadFile(opts.tlsCA)
	if err != nil {
		return nil, fmt.Errorf("read TLS CA: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		return nil, errors.New("TLS CA file contains no valid certificates")
	}
	return credentials.NewTLS(&tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
		ServerName: opts.tlsServerName,
	}), nil
}

func writeRootUsage(w io.Writer, fs *flag.FlagSet) {
	fmt.Fprintln(w, "Usage: zettidectl [global flags] <controller|data-node> <resource> <command> [flags]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Targets:")
	fmt.Fprintln(w, "  controller  Manage pools, nodes, members, volumes, and inspect heartbeats")
	fmt.Fprintln(w, "  data-node   Inspect holder and primary authority state")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Global flags:")
	fs.PrintDefaults()
}

func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	return fs
}

func parseFlags(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return ErrHelp
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %v", fs.Args())
	}
	return nil
}

func require(value, flagName string) error {
	if value == "" {
		return fmt.Errorf("--%s is required", flagName)
	}
	return nil
}
