package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"

	"github.com/fanyang89/zettide/cli/internal/command"
)

var version = "dev"

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	if err := command.Run(ctx, os.Args[1:], os.Stdout, os.Stderr, version); err != nil {
		if errors.Is(err, command.ErrHelp) {
			return
		}
		fmt.Fprintf(os.Stderr, "zettidectl: %v\n", err)
		os.Exit(1)
	}
}
