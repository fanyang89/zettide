# V3 Multi-Volume Metadata Format

## Status

This document freezes the first catalog root, volume descriptor, and extent run codecs for
multi-volume raw Pools. The codecs are implemented in `src/v3/pool_catalog.zig` but are not yet
selected by Pool provisioning. Existing raw Pools still use the single-volume metadata format.

All integers are little-endian. Digests are BLAKE3-256. Fixed records end with a CRC32C over all
preceding bytes. Reserved bytes must be zero.

## Metadata Addressing

Metadata page references are relative to the start of each member's metadata region. Offset 0 and
4096 are reserved for mirrored catalog root publication. Referenced pages therefore start at offset
8192, use 4096-byte alignment, and bind the complete referenced page with a BLAKE3 digest.

A null page reference has a zero offset and zero digest. A non-null reference has a nonzero aligned
offset, a nonzero digest, and a representable `offset + 4096` range.

The canonical catalog root digest written to a control record's `data_root_digest` is BLAKE3 over
bytes `0..4092` of the root encoding. The final CRC32C is excluded.

## Catalog Root

The catalog root is exactly 4096 bytes.

| Offset | Size | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVPROOT` |
| `0x008` | 2 | Format version, 1 |
| `0x00a` | 2 | Header flags, zero |
| `0x00c` | 4 | Encoded size, 4096 |
| `0x010` | 16 | Pool set ID |
| `0x020` | 8 | Catalog generation |
| `0x028` | 8 | Root sequence |
| `0x030` | 32 | Previous root digest |
| `0x050` | 40 | Volume tree page reference |
| `0x078` | 40 | Name index page reference |
| `0x0a0` | 40 | Physical extent allocator page reference |
| `0x0c8` | 40 | Retired extent page reference |
| `0x0f0` | 40 | Metadata page allocator reference |
| `0x118` | 4 | Volume count |
| `0x11c` | 4 | Physical extent size |
| `0x120` | 4 | Root flags, zero |
| `0x124` | 2 | Extent entry format version, 1 |
| `0x126` | 2 | Extent entry size, 64 |
| `0x128` | 3796 | Reserved, zero |
| `0xffc` | 4 | CRC32C |

Generation and sequence are nonzero. Generation 1 has a zero previous root digest; later generations
have a nonzero previous root digest. Extent size is a power of two and at least 4096 bytes.

The root selects the extent leaf-entry version and size. A future EC-capable entry changes these root
fields and requires a new catalog root implementation; a decoder never guesses an entry layout from
leaf contents.

Allocator and metadata allocator roots are mandatory. An empty catalog has null volume and name
roots. A nonempty catalog has both roots; publishing only one index is invalid.

## Page Reference

A page reference is 40 bytes.

| Relative offset | Size | Field |
|---:|---:|---|
| `0x00` | 8 | Metadata-relative page offset |
| `0x08` | 32 | BLAKE3 page digest |

## Volume Descriptor

A volume descriptor is exactly 512 bytes.

| Offset | Size | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVVOL1\0` |
| `0x008` | 2 | Format version, 1 |
| `0x00a` | 2 | Volume state |
| `0x00c` | 2 | Provisioning mode |
| `0x00e` | 2 | Name offset, `0x0a0` |
| `0x010` | 16 | Volume ID |
| `0x020` | 8 | Creation time in nanoseconds |
| `0x028` | 8 | Logical size in bytes |
| `0x030` | 40 | `LFSDRV2` header page reference |
| `0x058` | 40 | Extent map root reference |
| `0x080` | 8 | Allocated extent count |
| `0x088` | 8 | Reserved extent count |
| `0x090` | 2 | Name length |
| `0x092` | 2 | Header flags, zero |
| `0x094` | 4 | Volume flags, zero |
| `0x098` | 4 | Extent size |
| `0x09c` | 4 | Reserved, zero |
| `0x0a0` | 127 | UTF-8 volume name |
| after name | variable | Reserved, zero through `0x1fb` |
| `0x1fc` | 4 | CRC32C |

Volume states have stable values:

| Value | State |
|---:|---|
| 1 | `creating` |
| 2 | `ready` |
| 3 | `deleting` |

Provisioning modes have stable values:

| Value | Mode |
|---:|---|
| 1 | `thin` |
| 2 | `thick` |

The volume ID is nonzero. The name is 1 through 127 valid UTF-8 bytes. Logical size is 4096-byte
aligned, at least 256 KiB, and no larger than `(2^32 - 1) * 4096` bytes. The extent size is a power of
two and at least 4096 bytes.

Every volume extent size equals its catalog root extent size and the Pool layout chunk size.

For a thick volume, allocated plus reserved extents exactly covers its rounded logical extent count.
For a thin volume, that sum cannot exceed its logical extent count. A thick volume always has an
extent map. A thin volume has an extent map exactly when it has allocated extents; capacity-only
reservations do not create logical mappings.

## Extent Run

An extent run is exactly 64 bytes. It is a leaf entry and therefore has no separate magic or version.

| Offset | Size | Field |
|---:|---:|---|
| `0x000` | 8 | Logical extent start |
| `0x008` | 8 | Physical extent ordinal |
| `0x010` | 4 | Extent count |
| `0x014` | 2 | Extent state |
| `0x016` | 2 | Member count, 1 or 3 |
| `0x018` | 6 | Three canonical member slots |
| `0x01e` | 2 | Reserved, zero |
| `0x020` | 4 | Extent flags, zero |
| `0x024` | 24 | Reserved, zero |
| `0x03c` | 4 | CRC32C |

Extent states have stable values:

| Value | State |
|---:|---|
| 1 | `reserved_zero` |
| 2 | `mapped` |

Member slots are strictly increasing, and unused slots are zero. The initial format supports only one
unprotected member or three replicated members. All replicas use the same physical extent ordinal.
Erasure-coded shard placement requires a future extent entry version.

Before publication, contextual validation binds every run to the authoritative Pool layout and
topology. Unprotected runs contain one eligible data slot; replicated runs contain three eligible data
slots. The Pool may contain additional eligible members, and different runs may select different
canonical slot sets. Each physical ordinal range, multiplied by the root extent size, must fit every
referenced member data region.

Runs in one volume are ordered by logical start, do not overlap logically, and are maximally merged.
Physical ordinal ranges cannot overlap when their member slot sets intersect; disjoint slot sets have
independent physical address spaces. Thick runs completely cover the volume. Thin runs may have
logical gaps, which read as zero, but cannot contain `reserved_zero` mappings. Capacity reserved for a
thin volume is accounted outside its logical extent map.

## Publication Invariants

These codecs do not by themselves publish a catalog. The metadata store and control journal must
enforce all of the following before this format becomes writable:

1. New data extents are initialized and durably synchronized before a mapping becomes authoritative.
2. Catalog and allocator pages are written copy-on-write and synchronized before root publication.
3. The committed control authority binds the canonical catalog root digest.
4. Extents referenced by any recoverable root are not reused.
5. Unknown commit outcomes freeze mutation and require authority reopen.
6. A physical extent has at most one owner in the authoritative allocator.

## Mirrored Root Selection

The control authority selects roots; root sequence alone is never Pool authority. A root copy is a
candidate only when its canonical digest equals the selected control authority's `data_root_digest`.
Replicated open requires matching candidate roots on a data read quorum. Equal-sequence divergent
roots therefore do not create a tie: only the control-bound digest is eligible. A missing or damaged
copy permits degraded read when quorum remains and is repaired before writable use.

Root publication retains one copy of the current authoritative root while writing the next root. Slot
authority is determined by the selected control `data_root_digest`, never by root sequence. If exactly
one A/B copy matches authority, publication targets the other copy. If both copies match authority,
publication targets A. If neither copy matches authority, writable open fails instead of overwriting
either copy. The target copy is written and synchronized on all required data members before the
generation prepare/commit that binds its digest. If the control transaction does not commit, the new
copies are unreachable and the other copy retains previous authority. After a successful commit, the
other A/B slot can be repaired with the authoritative root. Any unknown control commit outcome freezes
mutation and requires authority reopen before repair or extent reuse.
