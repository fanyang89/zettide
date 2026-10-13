package command

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
)

func (a *app) createFilesystem(ctx context.Context, args []string) error {
	fs := newFlagSet("controller filesystem create", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	filesystemID := fs.String("filesystem-id", "", "fresh UUIDv7; retain across retries (required)")
	poolID := fs.String("pool-id", "", "logical pool ID (required)")
	name := fs.String("name", "", "filesystem name (required)")
	description := fs.String("description", "", "filesystem description")
	profile := fs.String("name-profile", "legacy-raw", "filename profile: legacy-raw (case-sensitive) or portable-v1 (case-folded)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := filesystemUUID(*filesystemID, "filesystem-id"); err != nil {
		return err
	}
	if err := filesystemUUID(*poolID, "pool-id"); err != nil {
		return err
	}
	if err := filesystemText(*name, "name", 127, false); err != nil {
		return err
	}
	if err := filesystemText(*description, "description", 1024, true); err != nil {
		return err
	}
	var nameProfile pb.FilesystemNameProfile
	switch *profile {
	case "legacy-raw":
		nameProfile = pb.FilesystemNameProfile_FILESYSTEM_NAME_PROFILE_LEGACY_RAW
	case "portable-v1":
		nameProfile = pb.FilesystemNameProfile_FILESYSTEM_NAME_PROFILE_PORTABLE_V1
	default:
		return errors.New("--name-profile must be legacy-raw or portable-v1")
	}
	id, err := filesystemRequestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewFilesystemServiceClient(a.conn).CreateFilesystem(ctx, &pb.FilesystemMutationRequest{
		RequestId: id, FilesystemId: *filesystemID, PoolId: *poolID, Name: *name, Description: *description,
		BackendKind: pb.FilesystemBackendKind_FILESYSTEM_BACKEND_KIND_BLOB, NameProfile: nameProfile,
	})
	return a.printFilesystemMutation("create", id, response, err)
}

func (a *app) mutateFilesystem(ctx context.Context, args []string, deleting bool) error {
	operation := "update"
	if deleting {
		operation = "delete"
	}
	fs := newFlagSet("controller filesystem "+operation, a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	filesystemID := fs.String("filesystem-id", "", "filesystem ID (required)")
	version := fs.Uint64("expected-resource-version", 0, "required optimistic concurrency version")
	var description string
	if !deleting {
		fs.StringVar(&description, "description", "", "new description (empty clears it)")
	}
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := filesystemUUID(*filesystemID, "filesystem-id"); err != nil {
		return err
	}
	if *version == 0 {
		return errors.New("--expected-resource-version must be greater than zero")
	}
	if err := filesystemText(description, "description", 1024, true); err != nil {
		return err
	}
	id, err := filesystemRequestID(*request)
	if err != nil {
		return err
	}
	mutation := &pb.FilesystemMutationRequest{
		RequestId: id, FilesystemId: *filesystemID, Description: description, ExpectedResourceVersion: *version,
	}
	client := pb.NewFilesystemServiceClient(a.conn)
	var response *pb.FilesystemResponse
	if deleting {
		response, err = client.DeleteFilesystem(ctx, mutation)
	} else {
		response, err = client.UpdateFilesystem(ctx, mutation)
	}
	return a.printFilesystemMutation(operation, id, response, err)
}

func (a *app) getFilesystem(ctx context.Context, args []string) error {
	fs := newFlagSet("controller filesystem get", a.stderr)
	id := fs.String("filesystem-id", "", "filesystem ID (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := filesystemUUID(*id, "filesystem-id"); err != nil {
		return err
	}
	response, err := pb.NewFilesystemServiceClient(a.conn).GetFilesystem(ctx, &pb.GetFilesystemRequest{FilesystemId: *id})
	if err != nil {
		return fmt.Errorf("get filesystem: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) listFilesystems(ctx context.Context, args []string) error {
	fs := newFlagSet("controller filesystem list", a.stderr)
	poolID := fs.String("pool-id", "", "logical pool ID (required)")
	after := fs.String("after-filesystem-id", "", "UUIDv7 continuation boundary")
	pageSize := fs.Uint64("page-size", 0, "maximum rows, up to 32 (0 uses server default)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := filesystemUUID(*poolID, "pool-id"); err != nil {
		return err
	}
	if *after != "" {
		if err := filesystemUUID(*after, "after-filesystem-id"); err != nil {
			return err
		}
	}
	if *pageSize > 32 {
		return errors.New("--page-size must not exceed 32")
	}
	response, err := pb.NewFilesystemServiceClient(a.conn).ListFilesystems(ctx, &pb.ListFilesystemsRequest{
		PoolId: *poolID, AfterFilesystemId: *after, PageSize: uint32(*pageSize),
	})
	if err != nil {
		return fmt.Errorf("list filesystems: %w", err)
	}
	return a.printer.print(response)
}

func filesystemUUID(value, name string) error {
	if err := require(value, name); err != nil {
		return err
	}
	if err := validateUUIDv7Text(value, name); err != nil {
		return err
	}
	if value != strings.ToLower(value) {
		return fmt.Errorf("--%s must use lowercase canonical UUID text", name)
	}
	return nil
}

func filesystemText(value, name string, maximum int, allowEmpty bool) error {
	if !allowEmpty {
		if err := require(value, name); err != nil {
			return err
		}
	}
	if len(value) > maximum || !utf8.ValidString(value) {
		return fmt.Errorf("--%s must be UTF-8 and at most %d bytes", name, maximum)
	}
	return nil
}

func filesystemRequestID(value string) (string, error) {
	if err := filesystemText(value, "request-id", 127, true); err != nil {
		return "", err
	}
	return requestID(value)
}

func (a *app) printFilesystemMutation(operation, requestID string, response *pb.FilesystemResponse, rpcErr error) error {
	if rpcErr != nil {
		// Retain generated keys for exact retries after an uncertain outcome.
		return fmt.Errorf("%s filesystem (request-id=%q): %w", operation, requestID, rpcErr)
	}
	if err := a.printer.print(response); err != nil {
		return fmt.Errorf("%s filesystem committed but output failed (request-id=%q): %w", operation, requestID, err)
	}
	return nil
}
