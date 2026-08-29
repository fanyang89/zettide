package command

import (
	"context"
	"errors"
	"fmt"

	pb "github.com/fanyang89/zettide/cli/internal/gen/controller/v1"
)

func (a *app) runController(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return errors.New("usage: zettidectl [global flags] controller <pool|node|member|volume|heartbeat> <command> [flags]")
	}
	resource, command, flags := args[0], args[1], args[2:]
	switch resource + " " + command {
	case "pool create":
		return a.createPool(ctx, flags)
	case "pool get":
		return a.getPool(ctx, flags)
	case "pool list":
		return a.listPools(ctx, flags)
	case "node register":
		return a.registerNode(ctx, flags)
	case "node get":
		return a.getNode(ctx, flags)
	case "node list":
		return a.listNodes(ctx, flags)
	case "member register":
		return a.registerMember(ctx, flags)
	case "member get":
		return a.getMember(ctx, flags)
	case "member list":
		return a.listMembers(ctx, flags)
	case "heartbeat get":
		return a.getHeartbeat(ctx, flags)
	case "volume create":
		return a.createVolume(ctx, flags)
	case "volume get":
		return a.getVolume(ctx, flags)
	case "volume update":
		return a.updateVolume(ctx, flags)
	case "volume list":
		return a.listVolumes(ctx, flags)
	case "volume delete":
		return a.deleteVolume(ctx, flags)
	default:
		return fmt.Errorf("unknown controller command %q", resource+" "+command)
	}
}

func (a *app) createPool(ctx context.Context, args []string) error {
	fs := newFlagSet("controller pool create", a.stderr)
	name := fs.String("name", "", "pool name (required)")
	description := fs.String("description", "", "pool description")
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*name, "name"); err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewPoolServiceClient(a.conn).CreatePool(ctx, &pb.CreatePoolRequest{
		RequestId: id, Name: *name, Description: *description,
	})
	if err != nil {
		return fmt.Errorf("create pool: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) getPool(ctx context.Context, args []string) error {
	fs := newFlagSet("controller pool get", a.stderr)
	id := fs.String("id", "", "pool ID")
	name := fs.String("name", "", "pool name")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := requireExactlyOne(*id, "id", *name, "name"); err != nil {
		return err
	}
	request := &pb.GetPoolRequest{}
	if *id != "" {
		if err := validateUUIDv7Text(*id, "id"); err != nil {
			return err
		}
		request.Selector = &pb.GetPoolRequest_Id{Id: *id}
	} else {
		request.Selector = &pb.GetPoolRequest_Name{Name: *name}
	}
	response, err := pb.NewPoolServiceClient(a.conn).GetPool(ctx, request)
	if err != nil {
		return fmt.Errorf("get pool: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) listPools(ctx context.Context, args []string) error {
	fs := newFlagSet("controller pool list", a.stderr)
	pageSize := fs.Uint64("page-size", 0, "maximum rows returned")
	pageToken := fs.String("page-token", "", "base64 continuation token")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	size, err := checkedPageSize(*pageSize)
	if err != nil {
		return err
	}
	token, err := parsePageToken(*pageToken)
	if err != nil {
		return err
	}
	response, err := pb.NewPoolServiceClient(a.conn).ListPools(ctx, &pb.ListPoolsRequest{PageSize: size, PageToken: token})
	if err != nil {
		return fmt.Errorf("list pools: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) registerNode(ctx context.Context, args []string) error {
	fs := newFlagSet("controller node register", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	nodeID := fs.String("node-id", "", "stable node ID (required)")
	clusterID := fs.String("cluster-id", "", "16-byte cluster UUID (required)")
	controlEndpoint := fs.String("control-endpoint", "", "data-node gRPC endpoint (required)")
	nvmfEndpoint := fs.String("nvmf-endpoint", "", "NVMf endpoint")
	failureDomain := fs.String("failure-domain", "", "failure-domain label")
	capabilityBits := fs.Uint64("capability-bits", 0, "capability bit mask")
	protocolVersion := fs.Uint64("protocol-version", 0, "data-node protocol version")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	for _, required := range []struct{ value, name string }{
		{*nodeID, "node-id"}, {*clusterID, "cluster-id"}, {*controlEndpoint, "control-endpoint"},
		{*nvmfEndpoint, "nvmf-endpoint"}, {*failureDomain, "failure-domain"},
	} {
		if err := require(required.value, required.name); err != nil {
			return err
		}
	}
	if err := validateUUIDv7Text(*nodeID, "node-id"); err != nil {
		return err
	}
	cluster, err := parseFixedBytes(*clusterID, 16, "cluster-id")
	if err != nil {
		return err
	}
	if *protocolVersion == 0 {
		return errors.New("--protocol-version must be greater than zero")
	}
	version, err := checkedUint32(*protocolVersion, "protocol-version")
	if err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewNodeServiceClient(a.conn).RegisterNode(ctx, &pb.RegisterNodeRequest{
		RequestId:       id,
		NodeId:          *nodeID,
		ClusterId:       cluster,
		ControlEndpoint: *controlEndpoint,
		NvmfEndpoint:    *nvmfEndpoint,
		FailureDomain:   *failureDomain,
		CapabilityBits:  *capabilityBits,
		ProtocolVersion: version,
	})
	if err != nil {
		return fmt.Errorf("register node: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) getNode(ctx context.Context, args []string) error {
	fs := newFlagSet("controller node get", a.stderr)
	nodeID := fs.String("node-id", "", "node ID (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*nodeID, "node-id"); err != nil {
		return err
	}
	if err := validateUUIDv7Text(*nodeID, "node-id"); err != nil {
		return err
	}
	response, err := pb.NewNodeServiceClient(a.conn).GetNode(ctx, &pb.GetNodeRequest{NodeId: *nodeID})
	if err != nil {
		return fmt.Errorf("get node: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) listNodes(ctx context.Context, args []string) error {
	fs := newFlagSet("controller node list", a.stderr)
	pageSize := fs.Uint64("page-size", 0, "maximum rows returned")
	pageToken := fs.String("page-token", "", "base64 continuation token")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	size, err := checkedPageSize(*pageSize)
	if err != nil {
		return err
	}
	token, err := parsePageToken(*pageToken)
	if err != nil {
		return err
	}
	response, err := pb.NewNodeServiceClient(a.conn).ListNodes(ctx, &pb.ListNodesRequest{PageSize: size, PageToken: token})
	if err != nil {
		return fmt.Errorf("list nodes: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) registerMember(ctx context.Context, args []string) error {
	fs := newFlagSet("controller member register", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	clusterID := fs.String("cluster-id", "", "16-byte cluster UUID (required)")
	memberID := fs.String("member-id", "", "16-byte member UUID (required)")
	poolID := fs.String("pool-id", "", "pool ID (required)")
	nodeID := fs.String("node-id", "", "node ID (required)")
	localSetID := fs.String("local-set-id", "", "16-byte local-set UUID (required)")
	memberSlot := fs.Uint64("member-slot", 0, "member slot")
	topologyDigest := fs.String("birth-topology-digest", "", "32-byte topology digest (required)")
	metadataCapacity := fs.Uint64("metadata-capacity-bytes", 0, "metadata capacity in bytes")
	dataCapacity := fs.Uint64("data-capacity-bytes", 0, "data capacity in bytes")
	extentSize := fs.Uint64("extent-size-bytes", 0, "extent size in bytes")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	for _, required := range []struct{ value, name string }{
		{*clusterID, "cluster-id"}, {*memberID, "member-id"}, {*poolID, "pool-id"},
		{*nodeID, "node-id"}, {*localSetID, "local-set-id"}, {*topologyDigest, "birth-topology-digest"},
	} {
		if err := require(required.value, required.name); err != nil {
			return err
		}
	}
	if err := validateUUIDv7Text(*poolID, "pool-id"); err != nil {
		return err
	}
	if err := validateUUIDv7Text(*nodeID, "node-id"); err != nil {
		return err
	}
	cluster, err := parseFixedBytes(*clusterID, 16, "cluster-id")
	if err != nil {
		return err
	}
	member, err := parseFixedBytes(*memberID, 16, "member-id")
	if err != nil {
		return err
	}
	localSet, err := parseFixedBytes(*localSetID, 16, "local-set-id")
	if err != nil {
		return err
	}
	digest, err := parseFixedBytes(*topologyDigest, 32, "birth-topology-digest")
	if err != nil {
		return err
	}
	if string(member) == string(localSet) {
		return errors.New("--member-id and --local-set-id must differ")
	}
	if *metadataCapacity == 0 {
		return errors.New("--metadata-capacity-bytes must be greater than zero")
	}
	if *dataCapacity == 0 {
		return errors.New("--data-capacity-bytes must be greater than zero")
	}
	if *extentSize == 0 {
		return errors.New("--extent-size-bytes must be greater than zero")
	}
	slot, err := checkedUint16(*memberSlot, "member-slot")
	if err != nil {
		return err
	}
	extent, err := checkedUint32(*extentSize, "extent-size-bytes")
	if err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewMemberServiceClient(a.conn).RegisterMember(ctx, &pb.RegisterMemberRequest{
		RequestId:             id,
		ClusterId:             cluster,
		MemberId:              member,
		PoolId:                *poolID,
		NodeId:                *nodeID,
		LocalSetId:            localSet,
		MemberSlot:            slot,
		BirthTopologyDigest:   digest,
		MetadataCapacityBytes: *metadataCapacity,
		DataCapacityBytes:     *dataCapacity,
		ExtentSizeBytes:       extent,
	})
	if err != nil {
		return fmt.Errorf("register member: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) getMember(ctx context.Context, args []string) error {
	fs := newFlagSet("controller member get", a.stderr)
	memberID := fs.String("member-id", "", "16-byte member UUID (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	member, err := parseFixedBytes(*memberID, 16, "member-id")
	if err != nil {
		return err
	}
	response, err := pb.NewMemberServiceClient(a.conn).GetMember(ctx, &pb.GetMemberRequest{MemberId: member})
	if err != nil {
		return fmt.Errorf("get member: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) listMembers(ctx context.Context, args []string) error {
	fs := newFlagSet("controller member list", a.stderr)
	pageSize := fs.Uint64("page-size", 0, "maximum rows returned")
	pageToken := fs.String("page-token", "", "base64 continuation token")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	size, err := checkedPageSize(*pageSize)
	if err != nil {
		return err
	}
	token, err := parsePageToken(*pageToken)
	if err != nil {
		return err
	}
	response, err := pb.NewMemberServiceClient(a.conn).ListMembers(ctx, &pb.ListMembersRequest{
		PageSize: size, PageToken: token,
	})
	if err != nil {
		return fmt.Errorf("list members: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) getHeartbeat(ctx context.Context, args []string) error {
	fs := newFlagSet("controller heartbeat get", a.stderr)
	nodeID := fs.String("node-id", "", "node ID (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*nodeID, "node-id"); err != nil {
		return err
	}
	if err := validateUUIDv7Text(*nodeID, "node-id"); err != nil {
		return err
	}
	response, err := pb.NewHeartbeatServiceClient(a.conn).GetHeartbeat(ctx, &pb.GetHeartbeatRequest{NodeId: *nodeID})
	if err != nil {
		return fmt.Errorf("get heartbeat: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) createVolume(ctx context.Context, args []string) error {
	fs := newFlagSet("controller volume create", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	poolID := fs.String("pool-id", "", "pool ID (required)")
	name := fs.String("name", "", "volume name (required)")
	description := fs.String("description", "", "volume description")
	sizeBytes := fs.Uint64("size-bytes", 0, "volume size in bytes (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*poolID, "pool-id"); err != nil {
		return err
	}
	if err := require(*name, "name"); err != nil {
		return err
	}
	if err := validateUUIDv7Text(*poolID, "pool-id"); err != nil {
		return err
	}
	if err := validateVolumeSize(*sizeBytes); err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewVolumeServiceClient(a.conn).CreateVolume(ctx, &pb.CreateVolumeRequest{
		RequestId: id, PoolId: *poolID, Name: *name, Description: *description, SizeBytes: *sizeBytes,
	})
	if err != nil {
		return fmt.Errorf("create volume: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) getVolume(ctx context.Context, args []string) error {
	fs := newFlagSet("controller volume get", a.stderr)
	volumeID := fs.String("volume-id", "", "volume ID (required)")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*volumeID, "volume-id"); err != nil {
		return err
	}
	if err := validateUUIDv7Text(*volumeID, "volume-id"); err != nil {
		return err
	}
	response, err := pb.NewVolumeServiceClient(a.conn).GetVolume(ctx, &pb.GetVolumeRequest{VolumeId: *volumeID})
	if err != nil {
		return fmt.Errorf("get volume: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) updateVolume(ctx context.Context, args []string) error {
	fs := newFlagSet("controller volume update", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	volumeID := fs.String("volume-id", "", "volume ID (required)")
	description := fs.String("description", "", "new description")
	expectedVersion := fs.Uint64("expected-resource-version", 0, "required optimistic concurrency version")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*volumeID, "volume-id"); err != nil {
		return err
	}
	if *expectedVersion == 0 {
		return errors.New("--expected-resource-version must be greater than zero")
	}
	if err := validateUUIDv7Text(*volumeID, "volume-id"); err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewVolumeServiceClient(a.conn).UpdateVolume(ctx, &pb.UpdateVolumeRequest{
		RequestId: id, VolumeId: *volumeID, Description: *description, ExpectedResourceVersion: *expectedVersion,
	})
	if err != nil {
		return fmt.Errorf("update volume: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) listVolumes(ctx context.Context, args []string) error {
	fs := newFlagSet("controller volume list", a.stderr)
	poolID := fs.String("pool-id", "", "filter by pool ID")
	pageSize := fs.Uint64("page-size", 0, "maximum rows returned")
	pageToken := fs.String("page-token", "", "base64 continuation token")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	size, err := checkedPageSize(*pageSize)
	if err != nil {
		return err
	}
	token, err := parsePageToken(*pageToken)
	if err != nil {
		return err
	}
	if *poolID != "" {
		if err := validateUUIDv7Text(*poolID, "pool-id"); err != nil {
			return err
		}
	}
	response, err := pb.NewVolumeServiceClient(a.conn).ListVolumes(ctx, &pb.ListVolumesRequest{
		PoolId: *poolID, PageSize: size, PageToken: token,
	})
	if err != nil {
		return fmt.Errorf("list volumes: %w", err)
	}
	return a.printer.print(response)
}

func (a *app) deleteVolume(ctx context.Context, args []string) error {
	fs := newFlagSet("controller volume delete", a.stderr)
	request := fs.String("request-id", "", "idempotency key (generated when omitted)")
	volumeID := fs.String("volume-id", "", "volume ID (required)")
	expectedVersion := fs.Uint64("expected-resource-version", 0, "required optimistic concurrency version")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := require(*volumeID, "volume-id"); err != nil {
		return err
	}
	if *expectedVersion == 0 {
		return errors.New("--expected-resource-version must be greater than zero")
	}
	if err := validateUUIDv7Text(*volumeID, "volume-id"); err != nil {
		return err
	}
	id, err := requestID(*request)
	if err != nil {
		return err
	}
	response, err := pb.NewVolumeServiceClient(a.conn).DeleteVolume(ctx, &pb.DeleteVolumeRequest{
		RequestId: id, VolumeId: *volumeID, ExpectedResourceVersion: *expectedVersion,
	})
	if err != nil {
		return fmt.Errorf("delete volume: %w", err)
	}
	return a.printer.print(response)
}
