# DevDrive v3 Member Header Format

## Scope

This document freezes the v3 member header codec. It defines no file I/O, member creation,
mounting, topology journal, or CLI behavior. A volume containing only this header is not
mountable.

All integers use little-endian encoding. The header is encoded field by field and is never a
serialized Zig or native ABI structure. Each header copy is exactly 4096 bytes.

## Wire Layout

| Offset | Width | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVMEM3\0` |
| `0x008` | 2 | Format major, 3 |
| `0x00a` | 2 | Format minor, 0 |
| `0x00c` | 4 | Header size, 4096 |
| `0x010` | 8 | Local header sequence |
| `0x018` | 8 | Compatible feature bits |
| `0x020` | 8 | Read-only-compatible feature bits |
| `0x028` | 8 | Incompatible feature bits |
| `0x030` | 16 | Set ID |
| `0x040` | 16 | Member ID |
| `0x050` | 2 | Member slot |
| `0x052` | 2 | Initial member count, 3 |
| `0x054` | 4 | Member role flags |
| `0x058` | 8 | Creation time in nanoseconds, signed i64 |
| `0x060` | 8 | Exact member bytes |
| `0x068` | 8 | Logical capacity |
| `0x070` | 8 | Control offset |
| `0x078` | 8 | Control length |
| `0x080` | 8 | Metadata offset |
| `0x088` | 8 | Metadata length |
| `0x090` | 8 | Data offset |
| `0x098` | 8 | Data length |
| `0x0a0` | 4 | Metadata block size |
| `0x0a4` | 4 | Metadata read size |
| `0x0a8` | 4 | Metadata program size |
| `0x0ac` | 4 | Chunk size |
| `0x0b0` | 2 | Metadata format version |
| `0x0b2` | 2 | Object format version |
| `0x0b4` | 2 | Layout format version |
| `0x0b6` | 2 | Control record format version |
| `0x0b8` | 2 | Checksum algorithm, 1 is CRC32C |
| `0x0ba` | 2 | Digest algorithm, 1 is BLAKE3-256 |
| `0x0bc` | 2 | Label byte length, at most 127 |
| `0x0be` | 2 | Header flags, zero in v3.0 |
| `0x0c0` | 128 | UTF-8 label followed by zero padding |
| `0x140` | 32 | Genesis topology digest |
| `0x160` | 8 | Checkpoint offset; zero means no hint |
| `0x168` | 8 | Checkpoint local record sequence |
| `0x170` | 32 | Checkpoint record digest |
| `0x190` | 3692 | Reserved; zero in v3.0 |
| `0xffc` | 4 | CRC32C of bytes `[0, 4092)` |

The committed golden fixture is a sparse hex representation of all 4096 bytes. Unlisted bytes
are zero. Its canonical BLAKE3-256 fingerprint is
`ac09bf5b06bcc8bbdb092530a7a199032e10eefb917b593ddb4591c464db5946`.

## Geometry

The control region starts at 64 KiB, is 4096-byte aligned, and contains at least one 4096-byte
record. Metadata starts at the control end rounded up to 1 MiB. Its length is at least 256 KiB,
is block-aligned, and contains between 2 and `maxInt(u32)` blocks. Data starts at the metadata
end rounded up to 1 MiB, has nonzero chunk-aligned length, and ends exactly at `member_bytes`.

Block, read, program, and chunk sizes are powers of two. Read and program sizes divide the
metadata block size. The block size divides the chunk size. Logical capacity is nonzero and no
larger than the data region. Region ends and alignment rounding use checked arithmetic.

## Identity And Roles

Set and member IDs are nonzero and distinct. The initial member count is exactly three, and the
slot is in `[0, 3)`. The first format requires both metadata and data role bits and rejects all
other role bits. The genesis topology digest is nonzero.

## Checkpoint Hint

The checkpoint fields are member-local scan hints only. They are not commit, generation, or
topology authority. With no hint, offset, sequence, and digest are all zero. With a hint, the
offset is 4096-byte aligned inside the control region, and sequence and digest are nonzero.

## Feature Policy

Structural decoding records all three feature masks but does not reject unknown feature bits.
Open-mode policy is evaluated separately:

| Unknown feature class | Read-only | Writable |
|---|---|---|
| Compatible | Accept | Accept |
| Read-only-compatible | Accept | Reject |
| Incompatible | Reject | Reject |

The initial supported masks are zero.

## A/B Selection

Each copy is structurally decoded independently, retaining its decode error. One valid copy is
selected with degraded redundancy. If both are invalid, selection reports no valid header.

When both copies are valid, all static fields are compared before sequence numbers. A static
conflict rejects both copies, so a higher sequence cannot replace identity or geometry. Static
comparison excludes only header sequence, checkpoint offset, checkpoint local record sequence,
checkpoint digest, and the final CRC. With equal static fields, the higher sequence wins. Equal
sequences with different checkpoint semantics are ambiguous; identical copies select A.
