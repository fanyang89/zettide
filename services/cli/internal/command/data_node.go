package command

import (
	"context"
	"errors"
	"flag"
	"fmt"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
)

func (a *app) runDataNode(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return errors.New("usage: zettidectl [global flags] data-node <holder identify|primary inspect> [flags]")
	}
	resource, command, flags := args[0], args[1], args[2:]
	switch resource + " " + command {
	case "holder identify":
		return a.identifyHolder(ctx, flags)
	case "primary inspect":
		return a.inspectPrimary(ctx, flags)
	default:
		return fmt.Errorf("unknown data-node command %q", resource+" "+command)
	}
}

func (a *app) identifyHolder(ctx context.Context, args []string) error {
	fs := newFlagSet("data-node holder identify", a.stderr)
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	response, err := pb.NewDataServiceClient(a.conn).IdentifyHolder(ctx, &pb.IdentifyHolderRequest{})
	if err != nil {
		return fmt.Errorf("identify data-node holder: %w", err)
	}
	return a.printer.print(response)
}

type authorityBindingFlags struct {
	volumeID          *string
	primaryPlacement  *string
	primaryNode       *string
	leaseID           *string
	holderBootID      *string
	authorityGen      *uint64
	writeEpoch        *uint64
	placementRevision *uint64
	activationNonce   *string
	authorityDigest   *string
}

func addAuthorityBindingFlags(fs *flag.FlagSet) authorityBindingFlags {
	return authorityBindingFlags{
		volumeID:          fs.String("volume-id", "", "16-byte volume UUIDv7 (required)"),
		primaryPlacement:  fs.String("primary-placement-id", "", "16-byte placement UUIDv7 (required)"),
		primaryNode:       fs.String("primary-node-id", "", "16-byte node UUIDv7 (required)"),
		leaseID:           fs.String("lease-id", "", "16-byte lease UUIDv7 (required)"),
		holderBootID:      fs.String("holder-boot-id", "", "16-byte holder boot UUIDv7 (required)"),
		authorityGen:      fs.Uint64("authority-generation", 0, "authority generation (required)"),
		writeEpoch:        fs.Uint64("write-epoch", 0, "write epoch (required)"),
		placementRevision: fs.Uint64("placement-revision", 0, "placement revision (required)"),
		activationNonce:   fs.String("activation-nonce", "", "16-byte activation UUIDv7 (required)"),
		authorityDigest:   fs.String("authority-digest", "", "32-byte authority digest (required)"),
	}
}

func (flags authorityBindingFlags) binding() (*pb.DataAuthorityBinding, error) {
	for _, required := range []struct{ value, name string }{
		{*flags.volumeID, "volume-id"}, {*flags.primaryPlacement, "primary-placement-id"},
		{*flags.primaryNode, "primary-node-id"}, {*flags.leaseID, "lease-id"},
		{*flags.holderBootID, "holder-boot-id"}, {*flags.activationNonce, "activation-nonce"},
		{*flags.authorityDigest, "authority-digest"},
	} {
		if err := require(required.value, required.name); err != nil {
			return nil, err
		}
	}
	for _, required := range []struct {
		value uint64
		name  string
	}{
		{*flags.authorityGen, "authority-generation"},
		{*flags.writeEpoch, "write-epoch"},
		{*flags.placementRevision, "placement-revision"},
	} {
		if required.value == 0 {
			return nil, fmt.Errorf("--%s must be greater than zero", required.name)
		}
	}
	volumeID, err := parseUUIDv7(*flags.volumeID, "volume-id")
	if err != nil {
		return nil, err
	}
	placementID, err := parseUUIDv7(*flags.primaryPlacement, "primary-placement-id")
	if err != nil {
		return nil, err
	}
	nodeID, err := parseUUIDv7(*flags.primaryNode, "primary-node-id")
	if err != nil {
		return nil, err
	}
	leaseID, err := parseUUIDv7(*flags.leaseID, "lease-id")
	if err != nil {
		return nil, err
	}
	bootID, err := parseUUIDv7(*flags.holderBootID, "holder-boot-id")
	if err != nil {
		return nil, err
	}
	nonce, err := parseUUIDv7(*flags.activationNonce, "activation-nonce")
	if err != nil {
		return nil, err
	}
	digest, err := parseFixedBytes(*flags.authorityDigest, 32, "authority-digest")
	if err != nil {
		return nil, err
	}
	return &pb.DataAuthorityBinding{
		VolumeId:            volumeID,
		PrimaryPlacementId:  placementID,
		PrimaryNodeId:       nodeID,
		LeaseId:             leaseID,
		HolderBootId:        bootID,
		AuthorityGeneration: *flags.authorityGen,
		WriteEpoch:          *flags.writeEpoch,
		PlacementRevision:   *flags.placementRevision,
		ActivationNonce:     nonce,
		AuthorityDigest:     digest,
	}, nil
}

func (a *app) inspectPrimary(ctx context.Context, args []string) error {
	fs := newFlagSet("data-node primary inspect", a.stderr)
	bindingFlags := addAuthorityBindingFlags(fs)
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	binding, err := bindingFlags.binding()
	if err != nil {
		return err
	}
	response, err := pb.NewDataServiceClient(a.conn).InspectPrimary(ctx, &pb.InspectPrimaryRequest{Binding: binding})
	if err != nil {
		return fmt.Errorf("inspect data-node primary: %w", err)
	}
	return a.printer.print(response)
}
