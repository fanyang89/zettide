package driver

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	csi "github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

const (
	driverName   = "fuse.csi.zettide.io"
	targetKey    = "zettide.io/target-path"
	mountTimeout = 30 * time.Second
)

type Options struct {
	Endpoint           string
	NodeID             string
	Version            string
	ZettidePath        string
	FusermountPath     string
	StateDir           string
	AllowedSourceRoot  string
	AllowedPublishRoot string
}

type Driver struct {
	csi.UnimplementedIdentityServer
	csi.UnimplementedNodeServer

	options   Options
	logger    *slog.Logger
	mu        sync.Mutex
	records   map[string]mountRecord
	processes map[string]*mountProcess
	lockFile  *os.File
}

type mountRecord struct {
	VolumeID   string `json:"volume_id"`
	Source     string `json:"source"`
	Target     string `json:"target"`
	ReadOnly   bool   `json:"read_only"`
	PID        int    `json:"pid,omitempty"`
	Generation uint64 `json:"generation"`
}

type mountProcess struct {
	cmd  *exec.Cmd
	done chan struct{}
	mu   sync.Mutex
	err  error
}

func Run(ctx context.Context, options Options, logger *slog.Logger) error {
	driver, err := newDriver(options, logger)
	if err != nil {
		return err
	}
	defer driver.close()

	socketPath, err := socketPath(options.Endpoint)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o750); err != nil {
		return fmt.Errorf("create CSI socket directory: %w", err)
	}
	if err := removeSocket(socketPath); err != nil {
		return err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on CSI socket: %w", err)
	}
	defer listener.Close()
	if err := os.Chmod(socketPath, 0o660); err != nil {
		return fmt.Errorf("set CSI socket mode: %w", err)
	}

	server := grpc.NewServer()
	csi.RegisterIdentityServer(server, driver)
	csi.RegisterNodeServer(server, driver)
	serveError := make(chan error, 1)
	go func() { serveError <- server.Serve(listener) }()
	logger.Info("CSI node service started", "driver", driverName, "node_id", options.NodeID, "endpoint", options.Endpoint)

	select {
	case <-ctx.Done():
		gracefulStop := make(chan struct{})
		go func() {
			server.GracefulStop()
			close(gracefulStop)
		}()
		select {
		case <-gracefulStop:
		case <-time.After(5 * time.Second):
			server.Stop()
			<-gracefulStop
		}
		if shutdownErr := driver.shutdownForRestart(); shutdownErr != nil {
			return shutdownErr
		}
		err = <-serveError
		if errors.Is(err, grpc.ErrServerStopped) {
			return nil
		}
		return err
	case err = <-serveError:
		return err
	}
}

func newDriver(options Options, logger *slog.Logger) (*Driver, error) {
	if options.NodeID == "" {
		return nil, errors.New("node ID is required")
	}
	if options.Version == "" {
		options.Version = "dev"
	}
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	for name, path := range map[string]string{
		"zettide executable":    options.ZettidePath,
		"fusermount executable": options.FusermountPath,
	} {
		info, err := os.Stat(path)
		if err != nil {
			return nil, fmt.Errorf("inspect %s: %w", name, err)
		}
		if info.Mode()&0o111 == 0 {
			return nil, fmt.Errorf("%s is not executable: %s", name, path)
		}
	}
	if err := os.MkdirAll(options.StateDir, 0o750); err != nil {
		return nil, fmt.Errorf("create CSI state directory: %w", err)
	}
	lockFile, err := os.OpenFile(filepath.Join(options.StateDir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open CSI state lock: %w", err)
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lockFile.Close()
		return nil, fmt.Errorf("another CSI node service owns the state directory: %w", err)
	}
	driver := &Driver{
		options:   options,
		logger:    logger,
		records:   make(map[string]mountRecord),
		processes: make(map[string]*mountProcess),
		lockFile:  lockFile,
	}
	if err := driver.recoverMounts(); err != nil {
		driver.close()
		return nil, fmt.Errorf("recover FUSE mounts: %w", err)
	}
	return driver, nil
}

func (d *Driver) GetPluginInfo(context.Context, *csi.GetPluginInfoRequest) (*csi.GetPluginInfoResponse, error) {
	return &csi.GetPluginInfoResponse{Name: driverName, VendorVersion: d.options.Version}, nil
}

func (d *Driver) GetPluginCapabilities(context.Context, *csi.GetPluginCapabilitiesRequest) (*csi.GetPluginCapabilitiesResponse, error) {
	return &csi.GetPluginCapabilitiesResponse{}, nil
}

func (d *Driver) Probe(context.Context, *csi.ProbeRequest) (*csi.ProbeResponse, error) {
	return &csi.ProbeResponse{Ready: wrapperspb.Bool(true)}, nil
}

func (d *Driver) NodeGetInfo(context.Context, *csi.NodeGetInfoRequest) (*csi.NodeGetInfoResponse, error) {
	return &csi.NodeGetInfoResponse{NodeId: d.options.NodeID, MaxVolumesPerNode: 1}, nil
}

func (d *Driver) NodeGetCapabilities(context.Context, *csi.NodeGetCapabilitiesRequest) (*csi.NodeGetCapabilitiesResponse, error) {
	return &csi.NodeGetCapabilitiesResponse{Capabilities: []*csi.NodeServiceCapability{{
		Type: &csi.NodeServiceCapability_Rpc{Rpc: &csi.NodeServiceCapability_RPC{
			Type: csi.NodeServiceCapability_RPC_SINGLE_NODE_MULTI_WRITER,
		}},
	}}}, nil
}

func (d *Driver) NodePublishVolume(ctx context.Context, request *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
	if request.GetVolumeId() == "" {
		return nil, status.Error(codes.InvalidArgument, "volume ID is required")
	}
	if request.GetTargetPath() == "" {
		return nil, status.Error(codes.InvalidArgument, "target path is required")
	}
	capability := request.GetVolumeCapability()
	if capability == nil || capability.GetMount() == nil || capability.GetAccessMode() == nil {
		return nil, status.Error(codes.InvalidArgument, "a filesystem volume capability is required")
	}
	if mount := capability.GetMount(); mount.GetFsType() != "" && mount.GetFsType() != "fuse.zettide" {
		return nil, status.Errorf(codes.InvalidArgument, "unsupported filesystem type %q", mount.GetFsType())
	} else if len(mount.GetMountFlags()) != 0 {
		return nil, status.Error(codes.InvalidArgument, "custom mount flags are not supported")
	}
	mode := capability.GetAccessMode().GetMode()
	if mode != csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER &&
		mode != csi.VolumeCapability_AccessMode_SINGLE_NODE_READER_ONLY &&
		mode != csi.VolumeCapability_AccessMode_SINGLE_NODE_SINGLE_WRITER {
		return nil, status.Errorf(codes.InvalidArgument, "unsupported access mode %s", mode)
	}
	readOnly := request.GetReadonly() || mode == csi.VolumeCapability_AccessMode_SINGLE_NODE_READER_ONLY
	if mode == csi.VolumeCapability_AccessMode_SINGLE_NODE_READER_ONLY && !request.GetReadonly() {
		return nil, status.Error(codes.InvalidArgument, "reader-only capability requires readonly publish")
	}

	sourceValue := request.GetVolumeContext()[targetKey]
	if sourceValue == "" {
		return nil, status.Errorf(codes.InvalidArgument, "volume context %q is required", targetKey)
	}
	source, err := confinedExistingPath(d.options.AllowedSourceRoot, sourceValue, true)
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid static target: %v", err)
	}
	target, err := confinedExistingDirectory(d.options.AllowedPublishRoot, request.GetTargetPath())
	if errors.Is(err, os.ErrNotExist) {
		target, err = confinedMissingPath(d.options.AllowedPublishRoot, request.GetTargetPath())
	}
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid publish target: %v", err)
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	for key, record := range d.records {
		if record.VolumeID != request.GetVolumeId() {
			continue
		}
		if record.Target != target {
			return nil, status.Errorf(codes.FailedPrecondition, "volume is already published at %s", record.Target)
		}
		if record.Source != source || record.ReadOnly != readOnly {
			return nil, status.Error(codes.AlreadyExists, "existing publication has different attributes")
		}
		mounted, fsType, checkErr := mountAt(target)
		if checkErr != nil {
			return nil, status.Errorf(codes.Internal, "inspect existing publication: %v", checkErr)
		}
		process := d.processes[key]
		if mounted && fsType != "fuse.zettide" {
			return nil, status.Errorf(codes.FailedPrecondition, "publish target has unexpected filesystem type %q", fsType)
		}
		if mounted && process != nil && processRunning(process) {
			return &csi.NodePublishVolumeResponse{}, nil
		}
		if err := d.recoverRecordLocked(key, record); err != nil {
			return nil, status.Errorf(codes.Internal, "recover existing publication: %v", err)
		}
		return &csi.NodePublishVolumeResponse{}, nil
	}
	if mounted, _, err := mountAt(target); err != nil {
		return nil, status.Errorf(codes.Internal, "inspect publish target: %v", err)
	} else if mounted {
		return nil, status.Error(codes.FailedPrecondition, "publish target is already mounted without driver state")
	}
	if err := d.verifyVolumeIdentity(ctx, request.GetVolumeId(), source); err != nil {
		return nil, err
	}
	record := mountRecord{
		VolumeID:   request.GetVolumeId(),
		Source:     source,
		Target:     target,
		ReadOnly:   readOnly,
		Generation: uint64(time.Now().UnixNano()),
	}
	key := recordKey(record.VolumeID, record.Target)
	if err := d.writeRecord(key, record); err != nil {
		return nil, status.Errorf(codes.Internal, "persist publication intent: %v", err)
	}
	d.records[key] = record
	if err := d.startMountLocked(key, record); err != nil {
		mounted, _, checkErr := mountAt(record.Target)
		if checkErr == nil && !mounted && processStopped(d.processes[key]) {
			if removeErr := d.removeRecordLocked(key); removeErr != nil {
				err = errors.Join(err, fmt.Errorf("remove failed publication intent: %w", removeErr))
			}
		}
		return nil, status.Errorf(codes.Internal, "start FUSE publication: %v", err)
	}
	return &csi.NodePublishVolumeResponse{}, nil
}

func (d *Driver) NodeUnpublishVolume(_ context.Context, request *csi.NodeUnpublishVolumeRequest) (*csi.NodeUnpublishVolumeResponse, error) {
	if request.GetVolumeId() == "" {
		return nil, status.Error(codes.InvalidArgument, "volume ID is required")
	}
	if request.GetTargetPath() == "" {
		return nil, status.Error(codes.InvalidArgument, "target path is required")
	}
	target, err := confinedExistingDirectory(d.options.AllowedPublishRoot, request.GetTargetPath())
	if errors.Is(err, os.ErrNotExist) {
		target, err = confinedMissingPath(d.options.AllowedPublishRoot, request.GetTargetPath())
	}
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid publish target: %v", err)
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	for key, record := range d.records {
		if record.Target != target {
			continue
		}
		if record.VolumeID != request.GetVolumeId() {
			return nil, status.Error(codes.FailedPrecondition, "publish target belongs to another volume")
		}
		if err := d.stopMountLocked(key, record, true); err != nil {
			return nil, status.Errorf(codes.Internal, "stop FUSE publication: %v", err)
		}
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, status.Errorf(codes.Internal, "remove publish target: %v", err)
		}
		return &csi.NodeUnpublishVolumeResponse{}, nil
	}
	if mounted, _, err := mountAt(target); err != nil {
		return nil, status.Errorf(codes.Internal, "inspect untracked publish target: %v", err)
	} else if mounted {
		return nil, status.Error(codes.FailedPrecondition, "refusing to detach an untracked mount")
	}
	if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, status.Errorf(codes.Internal, "remove untracked publish target: %v", err)
	}
	return &csi.NodeUnpublishVolumeResponse{}, nil
}

func (d *Driver) verifyVolumeIdentity(ctx context.Context, volumeID, source string) error {
	commandCtx, cancel := context.WithTimeout(ctx, mountTimeout)
	defer cancel()
	output, err := exec.CommandContext(commandCtx, d.options.ZettidePath, "info", source).Output()
	if err != nil {
		return status.Errorf(codes.FailedPrecondition, "inspect static target identity: %v", err)
	}
	var uuid string
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "UUID: ") {
			uuid = strings.TrimPrefix(line, "UUID: ")
			break
		}
	}
	if uuid == "" {
		return status.Error(codes.FailedPrecondition, "static target did not report a filesystem UUID")
	}
	expected := "zettide://filesystem/" + uuid
	if volumeID != expected {
		return status.Errorf(codes.FailedPrecondition, "volume ID does not match static target identity")
	}
	return nil
}

func (d *Driver) recoverMounts() error {
	entries, err := os.ReadDir(d.options.StateDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		key := strings.TrimSuffix(entry.Name(), ".json")
		data, err := os.ReadFile(filepath.Join(d.options.StateDir, entry.Name()))
		if err != nil {
			return err
		}
		var record mountRecord
		if err := json.Unmarshal(data, &record); err != nil {
			return fmt.Errorf("decode %s: %w", entry.Name(), err)
		}
		source, err := confinedExistingPath(d.options.AllowedSourceRoot, record.Source, true)
		if err != nil || source != record.Source {
			return fmt.Errorf("state %s has invalid source", entry.Name())
		}
		target, err := confinedExistingDirectory(d.options.AllowedPublishRoot, record.Target)
		missingTarget := errors.Is(err, os.ErrNotExist)
		if missingTarget {
			target, err = confinedMissingPath(d.options.AllowedPublishRoot, record.Target)
		}
		if err != nil || target != record.Target || record.VolumeID == "" || key != recordKey(record.VolumeID, record.Target) {
			return fmt.Errorf("state %s has invalid identity or target", entry.Name())
		}
		if missingTarget {
			d.logger.Info("removing stale FUSE publication", "volume_id", record.VolumeID, "target", record.Target)
			if record.PID > 0 {
				if err := d.terminateRecordedPID(record); err != nil {
					return err
				}
			}
			if err := d.removeRecordLocked(key); err != nil {
				return err
			}
			continue
		}
		for _, existing := range d.records {
			if existing.VolumeID == record.VolumeID {
				return fmt.Errorf("volume %s has multiple persisted publications", record.VolumeID)
			}
		}
		d.records[key] = record
	}
	for key, record := range d.records {
		d.logger.Info("recovering FUSE publication", "volume_id", record.VolumeID, "target", record.Target)
		if err := d.recoverRecordLocked(key, record); err != nil {
			return err
		}
	}
	return nil
}

func (d *Driver) recoverRecordLocked(key string, record mountRecord) error {
	if err := d.detachTarget(record.Target); err != nil {
		return err
	}
	if record.PID > 0 {
		if err := d.terminateRecordedPID(record); err != nil {
			return err
		}
	}
	if err := d.verifyVolumeIdentity(context.Background(), record.VolumeID, record.Source); err != nil {
		return fmt.Errorf("verify persisted volume identity: %w", err)
	}
	record.PID = 0
	if err := d.writeRecord(key, record); err != nil {
		return err
	}
	d.records[key] = record
	return d.startMountLocked(key, record)
}

func (d *Driver) startMountLocked(key string, record mountRecord) error {
	if err := os.MkdirAll(record.Target, 0o750); err != nil {
		return err
	}
	logFile, err := os.OpenFile(filepath.Join(d.options.StateDir, key+".log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	args := []string{"mount", record.Source, record.Target, "--allow-other"}
	if record.ReadOnly {
		args = append(args, "--read-only")
	}
	command := exec.Command(d.options.ZettidePath, args...)
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		return err
	}
	process := &mountProcess{cmd: command, done: make(chan struct{})}
	d.processes[key] = process
	record.PID = command.Process.Pid
	go d.waitMountProcess(key, record.PID, process, logFile)
	if err := d.writeRecord(key, record); err != nil {
		return d.abortMountStartLocked(key, record, process, err)
	}
	d.records[key] = record

	deadline := time.NewTimer(mountTimeout)
	defer deadline.Stop()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-process.done:
			process.mu.Lock()
			processError := process.err
			process.mu.Unlock()
			if processError == nil {
				processError = errors.New("zettide mount exited successfully before readiness")
			} else {
				processError = fmt.Errorf("zettide mount exited before readiness: %w", processError)
			}
			return d.abortMountStartLocked(key, record, process, processError)
		case <-ticker.C:
			mounted, fsType, err := mountAt(record.Target)
			if err != nil {
				return d.abortMountStartLocked(key, record, process, err)
			}
			if mounted && fsType == "fuse.zettide" {
				d.logger.Info("FUSE volume published", "volume_id", record.VolumeID, "target", record.Target, "read_only", record.ReadOnly)
				return nil
			}
		case <-deadline.C:
			return d.abortMountStartLocked(key, record, process, errors.New("FUSE mount readiness timeout"))
		}
	}
}

func (d *Driver) abortMountStartLocked(key string, record mountRecord, process *mountProcess, cause error) error {
	record.PID = 0
	d.records[key] = record
	if processRunning(process) {
		_ = process.cmd.Process.Kill()
		select {
		case <-process.done:
		case <-time.After(5 * time.Second):
			cause = errors.Join(cause, errors.New("timed out waiting for failed FUSE process"))
		}
	}
	if err := d.detachTarget(record.Target); err != nil {
		cause = errors.Join(cause, fmt.Errorf("detach failed FUSE mount: %w", err))
	}
	if err := d.writeRecord(key, record); err != nil {
		cause = errors.Join(cause, fmt.Errorf("reset failed publication intent: %w", err))
	}
	return cause
}

func (d *Driver) waitMountProcess(key string, pid int, process *mountProcess, logFile *os.File) {
	err := process.cmd.Wait()
	_ = logFile.Close()
	process.mu.Lock()
	process.err = err
	process.mu.Unlock()
	close(process.done)
	time.Sleep(500 * time.Millisecond)
	d.mu.Lock()
	if d.processes[key] == process {
		delete(d.processes, key)
	}
	record, exists := d.records[key]
	if exists && record.PID == pid {
		d.logger.Warn("FUSE process exited; recovering publication", "volume_id", record.VolumeID, "target", record.Target, "error", err)
		if recoverErr := d.recoverRecordLocked(key, record); recoverErr != nil {
			d.logger.Error("automatic FUSE recovery failed", "volume_id", record.VolumeID, "target", record.Target, "error", recoverErr)
		}
	}
	d.mu.Unlock()
}

func (d *Driver) stopMountLocked(key string, record mountRecord, remove bool) error {
	process := d.processes[key]
	record.PID = 0
	d.records[key] = record
	if err := d.detachTarget(record.Target); err != nil {
		return err
	}
	if process != nil {
		select {
		case <-process.done:
		case <-time.After(10 * time.Second):
			_ = process.cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-process.done:
			case <-time.After(5 * time.Second):
				_ = process.cmd.Process.Kill()
				<-process.done
			}
		}
	}
	if remove {
		return d.removeRecordLocked(key)
	}
	if err := d.writeRecord(key, record); err != nil {
		return err
	}
	d.records[key] = record
	return nil
}

func (d *Driver) detachTarget(target string) error {
	mounted, err := isMountpoint(target)
	if err != nil || !mounted {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	err = exec.CommandContext(ctx, d.options.ZettidePath, "unmount", target).Run()
	cancel()
	if err != nil {
		ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
		err = exec.CommandContext(ctx, d.options.FusermountPath, "-uz", target).Run()
		cancel()
		if err != nil {
			return err
		}
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		mounted, err = isMountpoint(target)
		if err != nil || !mounted {
			return err
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("FUSE unmount timeout")
}

func (d *Driver) terminateRecordedPID(record mountRecord) error {
	cmdline, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(record.PID), "cmdline"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	arguments := strings.Split(strings.TrimSuffix(string(cmdline), "\x00"), "\x00")
	if len(arguments) < 4 || filepath.Base(arguments[0]) != filepath.Base(d.options.ZettidePath) ||
		arguments[1] != "mount" || arguments[2] != record.Source || arguments[3] != record.Target {
		d.logger.Warn("refusing to signal reused persisted PID", "pid", record.PID, "volume_id", record.VolumeID)
		return nil
	}
	process, err := os.FindProcess(record.PID)
	if err != nil {
		return err
	}
	if err := process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	for range 100 {
		if err := process.Signal(syscall.Signal(0)); err != nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err := process.Signal(syscall.SIGKILL); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	for range 100 {
		if err := process.Signal(syscall.Signal(0)); err != nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("persisted FUSE process %d did not exit", record.PID)
}

func (d *Driver) writeRecord(key string, record mountRecord) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	temporary := filepath.Join(d.options.StateDir, key+".json.tmp")
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(append(data, '\n')); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(temporary, filepath.Join(d.options.StateDir, key+".json")); err != nil {
		return err
	}
	return syncDirectory(d.options.StateDir)
}

func (d *Driver) removeRecordLocked(key string) error {
	if err := os.Remove(filepath.Join(d.options.StateDir, key+".json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := syncDirectory(d.options.StateDir); err != nil {
		return err
	}
	delete(d.records, key)
	delete(d.processes, key)
	if err := os.Remove(filepath.Join(d.options.StateDir, key+".log")); err != nil && !errors.Is(err, os.ErrNotExist) {
		d.logger.Warn("failed to remove FUSE publication log", "key", key, "error", err)
	}
	return nil
}

func (d *Driver) shutdownForRestart() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	for key, record := range d.records {
		if err := d.stopMountLocked(key, record, false); err != nil {
			return fmt.Errorf("stop %s for node service restart: %w", record.VolumeID, err)
		}
	}
	return nil
}

func (d *Driver) close() {
	if d.lockFile == nil {
		return
	}
	_ = syscall.Flock(int(d.lockFile.Fd()), syscall.LOCK_UN)
	_ = d.lockFile.Close()
	d.lockFile = nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func confinedExistingPath(root, candidate string, requireRegular bool) (string, error) {
	if !filepath.IsAbs(root) || !filepath.IsAbs(candidate) {
		return "", errors.New("path must be absolute")
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	resolvedCandidate, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	if err := requireWithin(resolvedRoot, resolvedCandidate); err != nil {
		return "", err
	}
	info, err := os.Stat(resolvedCandidate)
	if err != nil {
		return "", err
	}
	if requireRegular && !info.Mode().IsRegular() {
		return "", errors.New("target is not a regular file")
	}
	return filepath.Clean(resolvedCandidate), nil
}

func confinedExistingDirectory(root, candidate string) (string, error) {
	if !filepath.IsAbs(root) || !filepath.IsAbs(candidate) {
		return "", errors.New("path must be absolute")
	}
	cleanRoot := filepath.Clean(root)
	cleanCandidate := filepath.Clean(candidate)
	if err := requireWithin(cleanRoot, cleanCandidate); err != nil {
		return "", err
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	resolvedParent, err := filepath.EvalSymlinks(filepath.Dir(cleanCandidate))
	if err != nil {
		return "", err
	}
	resolvedCandidate := filepath.Join(resolvedParent, filepath.Base(cleanCandidate))
	if err := requireWithin(resolvedRoot, resolvedCandidate); err != nil {
		return "", err
	}
	info, err := os.Lstat(resolvedCandidate)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("publish target is not a directory")
	}
	return filepath.Clean(resolvedCandidate), nil
}

func confinedMissingPath(root, candidate string) (string, error) {
	if !filepath.IsAbs(root) || !filepath.IsAbs(candidate) {
		return "", errors.New("path must be absolute")
	}
	cleanRoot := filepath.Clean(root)
	cleanCandidate := filepath.Clean(candidate)
	if err := requireWithin(cleanRoot, cleanCandidate); err != nil {
		return "", err
	}
	resolvedRoot, err := filepath.EvalSymlinks(cleanRoot)
	if err != nil {
		return "", err
	}
	ancestor := filepath.Dir(cleanCandidate)
	for {
		resolvedAncestor, resolveErr := filepath.EvalSymlinks(ancestor)
		if resolveErr == nil {
			suffix, err := filepath.Rel(ancestor, cleanCandidate)
			if err != nil {
				return "", err
			}
			resolvedCandidate := filepath.Join(resolvedAncestor, suffix)
			if err := requireWithin(resolvedRoot, resolvedCandidate); err != nil {
				return "", err
			}
			return resolvedCandidate, nil
		}
		if !errors.Is(resolveErr, os.ErrNotExist) || ancestor == cleanRoot {
			return "", resolveErr
		}
		ancestor = filepath.Dir(ancestor)
	}
}

func requireWithin(root, candidate string) error {
	relative, err := filepath.Rel(root, candidate)
	if err != nil {
		return err
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("path escapes configured root")
	}
	if relative == "." {
		return errors.New("path must be below configured root")
	}
	return nil
}

func isMountpoint(target string) (bool, error) {
	mounted, _, err := mountAt(target)
	return mounted, err
}

func mountAt(target string) (bool, string, error) {
	file, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return false, "", err
	}
	defer file.Close()
	target = filepath.Clean(target)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) <= 4 || filepath.Clean(unescapeMountPath(fields[4])) != target {
			continue
		}
		for separator := 5; separator+1 < len(fields); separator++ {
			if fields[separator] == "-" {
				return true, fields[separator+1], nil
			}
		}
		return true, "", nil
	}
	return false, "", scanner.Err()
}

func processRunning(process *mountProcess) bool {
	if process == nil {
		return false
	}
	select {
	case <-process.done:
		return false
	default:
		return true
	}
}

func processStopped(process *mountProcess) bool {
	return process == nil || !processRunning(process)
}

func unescapeMountPath(path string) string {
	replacer := strings.NewReplacer("\\040", " ", "\\011", "\t", "\\012", "\n", "\\134", "\\")
	return replacer.Replace(path)
}

func recordKey(volumeID, target string) string {
	sum := sha256.Sum256([]byte(volumeID + "\x00" + target))
	return hex.EncodeToString(sum[:])
}

func socketPath(endpoint string) (string, error) {
	const prefix = "unix://"
	if !strings.HasPrefix(endpoint, prefix) {
		return "", errors.New("CSI endpoint must use unix://")
	}
	path := strings.TrimPrefix(endpoint, prefix)
	if !filepath.IsAbs(path) {
		return "", errors.New("CSI socket path must be absolute")
	}
	return filepath.Clean(path), nil
}

func removeSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("refusing to replace non-socket CSI endpoint: %s", path)
	}
	return os.Remove(path)
}
