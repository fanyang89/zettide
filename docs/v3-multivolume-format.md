# V3 Multi-Volume Metadata Format

## Status

This document freezes the first catalog root, catalog leaf page, volume descriptor, and extent run
codecs for multi-volume raw Pools. The codecs, graph validator, and durable catalog-generation
staging path are implemented in `src/v3/pool_catalog.zig`, `src/v3/pool_catalog_page.zig`,
`src/v3/pool_catalog_graph.zig`, and `src/v3/pool_catalog_store.zig`. They are not yet selected by
Pool provisioning. Existing raw Pools still use the single-volume metadata format.
This first catalog format does not migrate development-era dynamic generations that used an arbitrary
non-catalog `data_root_digest`.

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

All non-null direct root page references have distinct offsets. A single leaf cannot satisfy two
different page kinds.

## Page Reference

A page reference is 40 bytes.

| Relative offset | Size | Field |
|---:|---:|---|
| `0x00` | 8 | Metadata-relative page offset |
| `0x08` | 32 | BLAKE3 page digest |

The digest covers the complete 4096-byte referenced page, including its CRC32C.

## Catalog Leaf Page

The initial catalog page format supports one fixed 4096-byte leaf for each root reference. It does
not define internal nodes, sibling links, or multi-page trees. This deliberately limits a catalog to
7 volumes and each volume to 62 extent runs until a future page format adds tree structure. A writer
must reject a mutation that exceeds any page capacity; it must not emit a partial index.

Every leaf has this 64-byte header:

| Offset | Size | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVPG001` |
| `0x008` | 2 | Page format version, 1 |
| `0x00a` | 2 | Page kind |
| `0x00c` | 2 | Tree level, zero for a leaf |
| `0x00e` | 2 | Entry count |
| `0x010` | 2 | Entry size selected by page kind |
| `0x012` | 2 | Header size, 64 |
| `0x014` | 4 | Page flags, zero |
| `0x018` | 8 | Page creation generation |
| `0x020` | 16 | Owner volume ID for an extent-map page; otherwise zero |
| `0x030` | 16 | Reserved, zero |
| `0x040` | variable | Fixed-size entries |
| after entries | variable | Reserved, zero through `0xffb` |
| `0xffc` | 4 | CRC32C |

The page creation generation is nonzero. An immutable page may remain referenced by later catalog
generations, so it need not equal the generation of every root that references it. Entry count times
entry size plus 64 cannot exceed `0xffc`.

Page kinds and their fixed entry layouts are:

| Value | Kind | Entry size | Maximum entries |
|---:|---|---:|---:|
| 1 | Volume index | 512 | 7 |
| 2 | Name index | 160 | 25 |
| 3 | Extent map | 64 | 62 |
| 4 | Physical allocator | 32 | 125 |
| 5 | Retired extents | 32 | 125 |
| 6 | Metadata allocator | 32 | 125 |

The volume index embeds complete volume descriptors ordered by volume ID. The name index is ordered
by the unsigned bytewise UTF-8 name representation. Names and volume IDs are unique because both
orders are strict. The extent map embeds extent runs ordered by logical start. An extent-map owner is
nonzero and must match the volume descriptor that references the page; all other page owners are
zero.

Before publication, catalog-level validation must additionally prove that the volume and name indexes
contain the same one-to-one `(volume ID, name)` set, that the root volume count equals their counts,
and that each extent-map reference resolves to a page owned by its descriptor's volume ID.

## Name Index Entry

A name index entry is exactly 160 bytes.

| Relative offset | Size | Field |
|---:|---:|---|
| `0x00` | 16 | Volume ID |
| `0x10` | 2 | Name length |
| `0x12` | 14 | Reserved, zero |
| `0x20` | 127 | UTF-8 volume name |
| after name | variable | Reserved, zero through `0x9f` |

The volume ID is nonzero. Name validation is identical to the volume descriptor name validation.

## Physical Interval Entry

Physical allocator and retired-extent pages use the same 32-byte interval entry.

| Relative offset | Size | Field |
|---:|---:|---|
| `0x00` | 2 | Member slot |
| `0x02` | 6 | Reserved, zero |
| `0x08` | 8 | Physical extent ordinal start |
| `0x10` | 8 | Extent count |
| `0x18` | 8 | Retirement generation |

The physical allocator is a free-space index. Its retirement generation is zero. A retired-extent
entry is unavailable space removed from an older authoritative mapping. Its retirement generation is
exactly the first catalog generation whose root omits that mapping; it is nonzero and no newer than
its containing page's creation generation. A publication transition must derive newly retired ranges
from the previous authoritative mappings and assign the new root generation. It must preserve the
generation of ranges already retired instead of trusting caller-supplied values. A transition from
authoritative generation N to N+1 may reclaim an interval only when its retirement generation is no
greater than N.

Entries are ordered by member slot and then physical start. Ranges on one member do not overlap. Free
ranges are maximally merged. Adjacent retired ranges are maximally merged only when their retirement
generation is equal; preserving distinct generations is required for safe reclamation.

## Metadata Interval Entry

The metadata allocator contains both reusable and retired metadata pages. Its entries are exactly 32
bytes.

| Relative offset | Size | Field |
|---:|---:|---|
| `0x00` | 8 | Metadata page ordinal start |
| `0x08` | 4 | Page count |
| `0x0c` | 2 | Interval state |
| `0x0e` | 2 | Reserved, zero |
| `0x10` | 8 | Retirement generation |
| `0x18` | 8 | Reserved, zero |

State 1 is free and requires a zero retirement generation. State 2 is retired and requires a nonzero
retirement generation no newer than the page creation generation. As with physical retirement, newly
retired pages receive the first root generation that no longer references them and preserve that value
across later COW allocator pages. A transition from authoritative generation N to N+1 may make them
free only when their retirement generation is no greater than N.

Page ordinals 0 and 1 are the mirrored catalog roots and never appear in this index. Entries have a
nonzero count, are ordered by page start, and do not overlap. Adjacent entries are maximally merged
when state and retirement generation match. Multiplying the end page ordinal by 4096 must be
representable and within every publishing member's metadata region. Neither free nor retired
intervals may overlap a page referenced by the current root. Free intervals also cannot overlap any
older recoverable root, while retired intervals may: that is the reason they remain quarantined.
Current-root validation must include the metadata allocator leaf itself among the referenced pages.

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

## Graph Validation

`src/v3/pool_catalog_graph.zig` validates a collected graph without performing I/O. Its authority
binding must come from the selected control authority, not from the candidate root itself. Validation
requires all of the following:

1. The root generation equals the control generation, the root set ID equals the authoritative
   topology set ID, and the canonical root digest equals the authoritative `data_root_digest`.
2. Every referenced page is present at its metadata-relative offset and its complete-page digest
   matches. Different current references never alias one offset.
3. Every catalog leaf has its expected kind and owner, and its creation generation is no newer than
   the root generation.
4. Volume and name indexes are one-to-one, extent maps satisfy the authoritative layout/topology and
   member geometry, and mapped/free/retired physical ranges never overlap.
5. Each `LFSDRV2` header decodes successfully and matches its descriptor's volume ID, state, creation
   time, logical size, extent size, and name.
6. Current pages plus free and retired metadata intervals account for every metadata page after the
   two mirrored roots.

Standalone graph validation accepts no external recoverability witness. During a transition, the
validator internally treats every page in the previous authority-bound graph as protected. A current
page may share an offset with that graph only when the digest is identical, and free metadata cannot
overlap those pages. This input cannot be supplied or omitted by the caller.

Member geometry binds both member ID and slot. Reusing a numeric slot for a different device never
inherits allocator state from the old device.

## Transition Validation

A catalog generation transition is valid only when:

1. The generation advances by exactly one, root sequence increases, and `previous_root_digest`
   equals the previous canonical root digest.
2. The generation prepare preserves the selected topology and layout. Membership changes are
   separate control transactions that preserve the catalog generation and root digest.
3. A physical mapping either keeps the same `(volume ID, logical extent)` owner or enters retired
   state with the new generation. Free space may become mapped. A retired range preserves its
   original retirement generation.
4. An immutable metadata page either keeps the same offset and digest or enters retired state with
   the new generation. New pages come from previously free metadata space.
5. Free physical capacity may be withdrawn to absent state. This supports member removal: drain all
   mappings, publish a generation that removes the member's free allocator ranges while it remains in
   topology, then commit membership removal without changing the root.

The transition validator permits physical or metadata `retired -> free`, and can validate
`retired -> mapped/used`, only when the preserved retirement generation is no greater than the
previous authority-bound root generation. The previous binding is validated against selected control
authority, its digest must be the new root's `previous_root_digest`, and generation must advance by
exactly one. This is the reclaim barrier; the public commit API accepts neither a caller-supplied
generation nor a caller-supplied page list. The integrated publisher still rejects new physical data
mappings until it receives a trusted data-durability witness.

Known normal control commit establishes the new authority and makes earlier generations unreachable
to normal data access. An unknown outcome freezes the coordinator, performs no root repair, and
permits no later transition.
Reopen must first select one control authority before reclaim can be attempted again. A stale A/B root
copy that does not match selected control authority is not by itself recoverable authority.
Administrative recovery may select an older local authority from one trusted member, but nonzero
catalog authority remains permanently recovery-only and data-unavailable in that mode; it cannot
publish a catalog transition or expose reclaimed data.

## Durable Staging

`commitCatalogGeneration` is the only public dynamic-Pool generation commit path. It holds the
coordinator mutex and an owner-token catalog claim on every current voter through graph validation,
staging, control commit, and root repair. Ordinary Member metadata writes and close are rejected while
the claim is held.

Publication uses the complete current voter set, not only control quorum:

1. Validate the previous authority-bound graph and the proposed next graph.
2. On every voter, read A/B roots and select authority only by the control `data_root_digest`.
3. Read-verify unchanged pages. Never rewrite an immutable page referenced by the old root.
4. Batch-write new COW pages and issue one durable sync barrier.
5. Write the non-authoritative root slot and issue a second durable sync barrier.
6. Only after every voter has staged the root, append generation prepare records.
7. Verify every certificate prepare witness belongs to the staged-member set.
8. After known commit success, repair the other root slot on every voter.

Thus normal topologies stage on 1/1 or 3/3 voters, and a transient two-voter topology stages on 2/2,
even though the control certificate and commit require only the topology quorum. A staging failure
occurs before prepare, revokes write readiness, and freezes the coordinator. An unknown control commit
outcome skips repair and requires full authority reopen. A post-commit repair failure is returned as a
failure bitmap alongside the successful commit result and also revokes further writes.

Genesis has no old catalog root. Initial publication requires zero A/B slots, writes pages then A,
commits generation 1, and repairs B after known success. Retrying the same candidate accepts an exact
staged root or a recognized prefix left by a partial root write; a conflicting nonzero root is never
overwritten.

The integrated path currently supports metadata-only transitions. Any new, moved, or state-changed
data mapping is rejected until data initialization/write durability can be represented by a trusted
witness. Member removal is rejected until an authority-bound catalog drain proof shows that no mapping
or allocator interval references its slot. These are deliberate fail-closed functional limits.

## Joining Catalog Install

A bootstrapped `joining` non-voter whose control tail exactly equals current authority may install the
current catalog from an active voter. The source is held under a catalog claim while its complete graph
is loaded and validated. The target root slots are checked for zero, exact retry, or a recognized
partial candidate before metadata is changed. Conflicting roots or pages are never overwritten.

Install writes all missing or partial pages with one durable barrier, then writes and synchronizes root
A and root B separately. It finally reloads the target graph and requires both roots to match current
control authority. A crash at any write or sync boundary leaves zero, exact, or recognizable-prefix
state that the same candidate can retry after reopen.

Promotion never trusts a previous install result. It claims each promoted member, reloads the catalog,
requires redundant roots, validates the graph under both current and proposed topology, and retains the
claim through membership prepare and commit. This binds the target's durable metadata to its new-voter
attestation.

The first install API is intentionally limited to `joining` members with a healthy bootstrap history.
The same transaction must activate it as a voter. Activating a joining member as an active non-voter is
rejected because non-voters do not receive the membership commit. The API does not replay control
history for an existing active non-voter. If authority advances before promotion, the target becomes
stale and remains ineligible until a separate control-history catch-up protocol exists.

## Mirrored Root Selection

The control authority selects roots; root sequence alone is never Pool authority. A root copy is a
candidate only when its canonical digest equals the selected control authority's `data_root_digest`.
Replicated open requires matching candidate roots on a data read quorum. Equal-sequence divergent
roots therefore do not create a tie: only the control-bound digest is eligible. A missing or damaged
copy permits degraded read when quorum remains and is repaired before writable use.

After control authority selection, reopen loads the root and every referenced leaf from each candidate
voter independently. Root and leaves from different members are never combined. The complete graph
must validate against the selected generation, root digest, topology, layout, and available member
geometry. Catalog read quorum uses the layout data read threshold. A member with a corrupt graph is
reported as `catalog-failed` and excluded from catalog writes while its data remains eligible under the
separate data-availability policy.

Writable reopen first establishes both catalog read quorum and control write quorum without modifying
metadata. It then repairs only an already validated active voter with exactly one authority-matching
root copy. Repair stops if a failure removes control write quorum. Genesis authority never repairs or
clears an uncommitted staged candidate; an exact initialization retry must recognize it instead.

A topology member without supplied geometry may be omitted from graph validation only while it remains
`joining`. Catalog validation still rejects every allocator or extent reference that requires missing
geometry. Administrative recovery with a nonzero catalog authority remains control-only and exposes no
data access until normal catalog validation succeeds.

Root publication retains one copy of the current authoritative root while writing the next root. Slot
authority is determined by the selected control `data_root_digest`, never by root sequence. If exactly
one A/B copy matches authority, publication targets the other copy. If both copies match authority,
publication targets A. If neither copy matches authority, writable open fails instead of overwriting
either copy. The target copy is written and synchronized on all required data members before the
generation prepare/commit that binds its digest. If the control transaction does not commit, the new
copies are unreachable and the other copy retains previous authority. After a successful commit, the
other A/B slot can be repaired with the authoritative root. Any unknown control commit outcome freezes
mutation and requires authority reopen before repair or extent reuse.
