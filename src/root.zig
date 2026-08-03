//! Transactional shared-storage filesystem engine.

const builtin = @import("builtin");

pub const store = @import("store.zig");
pub const allocation_format = @import("allocation_format.zig");
pub const anchor = @import("anchor.zig");
pub const commit = @import("commit.zig");
pub const conditional_block = @import("conditional_block.zig");
pub const claim_gate_format = @import("claim_gate_format.zig");
pub const claim_index_format = @import("claim_index_format.zig");
pub const data_block = @import("data_block.zig");
pub const extent_allocator = @import("extent_allocator.zig");
pub const filesystem_format = @import("filesystem_format.zig");
pub const immutable_extent = @import("immutable_extent.zig");
pub const linux_sg_io = if (builtin.os.tag == .linux) @import("linux_sg_io.zig") else struct {};
pub const model_conditional_block = @import("model_conditional_block.zig");
pub const model_block_device = @import("model_block_device.zig");
pub const model_data_block = @import("model_data_block.zig");
pub const model_store = @import("model_store.zig");
pub const model_voting_disk = @import("model_voting_disk.zig");
pub const page = @import("page.zig");
pub const resolution = @import("resolution.zig");
pub const scsi = @import("scsi.zig");
pub const scsi_store = @import("scsi_store.zig");
pub const transaction = @import("transaction.zig");
pub const tree = @import("tree.zig");
pub const voting = @import("voting.zig");
pub const voting_protocol = @import("voting_protocol.zig");
pub const voting_region = @import("voting_region.zig");
pub const volume_format = @import("volume_format.zig");

test {
    _ = store;
    _ = allocation_format;
    _ = anchor;
    _ = commit;
    _ = conditional_block;
    _ = claim_gate_format;
    _ = claim_index_format;
    _ = data_block;
    _ = extent_allocator;
    _ = filesystem_format;
    _ = immutable_extent;
    _ = linux_sg_io;
    _ = model_conditional_block;
    _ = model_block_device;
    _ = model_data_block;
    _ = model_store;
    _ = model_voting_disk;
    _ = page;
    _ = resolution;
    _ = scsi;
    _ = scsi_store;
    _ = transaction;
    _ = tree;
    _ = voting;
    _ = voting_protocol;
    _ = voting_region;
    _ = volume_format;
}
