//! Optional gperftools integration enabled with `-Dgperftools=true`.

const std = @import("std");
const grpc_lite = @import("grpc_lite");

comptime {
    _ = grpc_lite;
}

const c = @cImport({
    @cInclude("gperftools/profiler.h");
    @cInclude("gperftools/heap-profiler.h");
    @cInclude("gperftools/malloc_extension_c.h");
});

/// Uses tcmalloc because gperftools replaces the process C allocator.
pub const allocator = std.heap.c_allocator;

pub const CpuProfilerError = error{ProfilerStartFailed};

/// Starts process-wide CPU profiling and writes samples to `path`.
pub fn startCpuProfiler(path: [:0]const u8) CpuProfilerError!void {
    if (c.ProfilerStart(path.ptr) == 0) return error.ProfilerStartFailed;
}

/// Flushes the currently active process-wide CPU profile.
pub fn flushCpuProfiler() void {
    c.ProfilerFlush();
}

/// Stops process-wide CPU profiling and flushes its output.
pub fn stopCpuProfiler() void {
    c.ProfilerStop();
}

pub fn cpuProfilerRunning() bool {
    return c.ProfilingIsEnabledForAllThreads() != 0;
}

/// Starts process-wide heap profiling with the given output prefix.
pub fn startHeapProfiler(prefix: [:0]const u8) void {
    c.HeapProfilerStart(prefix.ptr);
}

/// Writes the current heap profile to the next file for the active prefix.
pub fn dumpHeapProfile(reason: [:0]const u8) void {
    c.HeapProfilerDump(reason.ptr);
}

/// Stops process-wide heap profiling.
pub fn stopHeapProfiler() void {
    c.HeapProfilerStop();
}

pub fn heapProfilerRunning() bool {
    return c.IsHeapProfilerRunning() != 0;
}

pub fn getNumericProperty(name: [:0]const u8) ?usize {
    var value: usize = 0;
    return if (c.MallocExtension_GetNumericProperty(name.ptr, &value) != 0) value else null;
}

pub fn owns(pointer: *const anyopaque) bool {
    return c.MallocExtension_GetOwnership(pointer) == c.MallocExtension_kOwned;
}

pub fn releaseFreeMemory() void {
    c.MallocExtension_ReleaseFreeMemory();
}

pub fn setGuardedSamplingInterval(interval: i64) void {
    c.MallocExtension_SetGuardedSamplingInterval(interval);
}

pub fn guardedSamplingInterval() i64 {
    return c.MallocExtension_GetGuardedSamplingInterval();
}

pub fn activateGuardedSampling() void {
    c.MallocExtension_ActivateGuardedSampling();
}
