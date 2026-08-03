# Architecture

The engine writes immutable objects and publishes a new root through one
conditional anchor replacement. A successful transaction has four phases:

1. Stage immutable objects.
2. Prepare those objects durably.
3. Replace the anchor only if its version token is still current.
4. Stabilize the published anchor before acknowledging the transaction.

Backends expose version tokens and object references as opaque values. The
transaction layer never interprets physical LBAs, SCSI status, object-store
keys, ETags, or protocol-specific errors.

The logical anchor is a fixed 512-byte envelope. The SCSI backend stores its
meaningful prefix in a checksummed physical-block record that also contains the
volume ID, and uses that complete 512- or 4096-byte block as its opaque version
token. Every published envelope includes a monotonically increasing generation
and transaction identifier, so a physical anchor value is never reused or
accepted on another volume.

The contract distinguishes a definite conflict from an indeterminate outcome.
Indeterminate publication is resolved using the transaction identifier and the
parent chain stored in immutable commit records; it is never retried blindly.
Once a publication request may have reached storage, transport failure is
reported as indeterminate rather than as an ordinary error. Stabilization is
idempotent and may be retried.

Every immutable commit record stores its generation, globally unique
transaction identifier, optional parent commit reference, and filesystem root
reference. Resolution requires generations to decrease by one along the parent
chain and applies a caller-controlled traversal limit. A missing, malformed, or
inconsistent chain is an unresolved error rather than evidence of success or
failure.

An unchanged base anchor does not prove that an indeterminate request failed:
the request may still reach storage after the read. Resolution remains pending
until the transaction appears at its intended generation or another commit
advances the anchor. A future explicit fencing operation can force progress
when no other writer advances it.

## Transaction Coordination

The transaction coordinator snapshots one base anchor and creates its write
batch with that exact opaque version token. It stages immutable objects, writes
the commit record last, prepares the batch, conditionally publishes the next
anchor, and stabilizes a definite winner. The published root must either belong
to the transaction's batch or already be loadable from the store.

A transaction is single-use. Conflicts and confirmed non-publications are
terminal. An indeterminate publication must be resolved before stabilization.
If publication succeeds but stabilization fails, the logical transaction is
never republished. Stabilization first verifies that the replacement remains
visible. An in-process device reset invalidates the batch, and terminal
resolution determines whether the unstable publication was rolled back. Reset
also proves that an indeterminate command from the older transport epoch can no
longer arrive, so resolution may classify an unchanged base as not committed.

## Immutable Tree

The initial key-value index is a path-copying B+tree with canonical 4 KiB
pages. Leaves contain sorted inline key-value pairs. Internal pages contain a
first child followed by sorted separator/right-child pairs. Pages have no
parent or sibling references, so copying one path never requires rewriting
unrelated branches.

A tree mutator caches speculative pages because prepared objects are not
visible through `loadImmutable`. The cache uses `ObjectRef` indexing and a
caller-configurable page budget. Each update writes children before parents and
returns a new root for the transaction coordinator to publish. Values larger
than the inline entry limit will use separate immutable objects in a future
format.

Inclusive lower-bound cursors retain the immutable path needed to traverse leaf
pages without sibling links. Cursors can read either a published root or a
mutator's speculative pages. Deletion copies the affected path but does not
merge pages or raise stale separator lower bounds; empty leaves remain valid.
This keeps updates local while preserving lookup and ordered-scan correctness.

Insertion and split control flow is adapted from xitdb's `SortedMap` at commit
`97f5d68962a70cbf9d3bbaf0a087271e5da642b7`. The CAWFS fork is available at
<https://github.com/fanyang89/xitdb>; licensing details are in
`THIRD_PARTY.md`.

## Storage Backends

The SCSI conditional-block transport uses READ(16), one-logical-block COMPARE
AND WRITE, and SYNCHRONIZE CACHE(16). Initialization obtains geometry with READ
CAPACITY(16), confirms opcode support, and requires a nonzero maximum compare
and write length from the Block Limits VPD page. Reads and cache synchronization
may be retried within a fixed attempt budget; COMPARE AND WRITE is issued once.

The Linux executor uses synchronous `SG_IO` on a block device. It rejects SCSI
generic character devices because they have a separate retry policy. The block
node's capacity and logical sector size must exactly match the SCSI LUN, which
rejects partitions and sliced mappings whose passthrough LBAs would bypass the
block mapping. A post-dispatch timeout, path failure, or ambiguous status is an
indeterminate CAW result rather than permission to resend the command.

Mutable extent data uses aligned positioned I/O on the same complete Linux
block device with `O_DIRECT`, bypassing host page caches that are not coherent
between machines. A successful ordinary write may remain unstable until the
next durability barrier. Any failure after dispatch is indeterminate: a delayed
ordinary write has no expected-value guard and may overwrite a later write, so
the affected owner and range must stop issuing dependent writes until recovery
or fencing proves that the old command cannot arrive.

The first SCSI store slice is append-only and places exactly one immutable
object in each claimed extent. An object reference canonically encodes the
extent index, allocator claim epoch, claim ID, and payload SHA-256. The extent
header repeats that identity, binds it to the volume ID, records the payload
length, and is checksummed; the remainder of the extent is zero padding. Loads
require a matching `live` immutable allocation entry and verify the volume,
header, payload digest, and padding. Objects remain unobservable while their
allocation is only `claimed`.

Prepare writes each complete extent with ordinary block I/O, including its
zero padding, and then crosses a data durability barrier. Only afterward does
it activate each allocation with allocator CAW. An indeterminate ordinary
write permanently poisons that batch because a delayed write cannot be safely
retried or fenced by content; its claim remains allocated. A definite
durability-barrier failure resets every known-complete extent to the staged
phase, so retry rewrites the same complete claimed extents before crossing a
new barrier. A device reset invalidates the old batch instead of allowing it to
activate data whose visible write may have been rolled back.

The publication backend exposes the volume-bound, checksummed physical anchor
block as the opaque version token. Each batch captures that exact base token
and generation before claiming extents. Claim IDs include the volume, base
generation, transaction, sequence, and payload digest; allocator activation is
recorded at base generation plus one. Publication rejects another base token,
requires that same next generation and the batch transaction ID, issues exactly
one full-block CAW, and maps its three outcomes directly to committed, conflict,
or indeterminate.
Conflict and failure can therefore leave durable live orphan extents. This
slice intentionally has no reclaim, garbage collection, packing, or
multi-extent objects.

The SCSI store constructor requires the allocator, ordinary transport, and
conditional transport to expose the same device identity as well as matching
the volume-header geometry. Geometry equality alone does not prove storage
identity. The unified Linux construction uses the Linux block-device executor
as both transport identities, and the unified model device provides both views
over one complete image.
The model shares one visible image, stable image, crash operation, durability
barrier, and separate delayed-command queues between its two transport views.

The volume header is a canonical 512-byte envelope embedded in one physical
logical block. Blocks 0 and 1 hold immutable header copies, block 2 is the
publication anchor, and blocks 3 through 9 are the voting region. Persistent
claim gates, the global claim index, and full-block allocator pages follow in
that order. The extent arena starts at the next extent boundary; version 1
defaults to 1 MiB extents and records its exact geometry in the header.

Each claim ID hashes to one persistent gate block. A gate contains one
recoverable operation descriptor and serializes claims and releases only in
that stripe; unrelated stripes remain independent. Tiny volumes use one or a
small number of gates, while volumes with at least 1024 rough extents reserve
64 stripes. Every cross-block allocator or index mutation is first described
and stabilized in its gate. A successful target mutation is stabilized before
the gate advances or returns to idle.

The claim index is one volume-wide, linearly probed hash table rather than
fixed-capacity per-stripe buckets. Its slots are shared by all claim IDs and
are provisioned for at most seven-eighths active load. Empty, bound, and
tombstone records are canonical. The gate remains active while a release
tombstones its index record and then returns the retired extent to free, so an
absent index record never permits the same claim ID to race onto another
allocator page before the old extent is durably free.

Each allocator page is bound to the volume ID, one page index, and the
corresponding complete, non-overlapping range of volume extents. Its
monotonically changing generation and all entries participate in the checksum
and full-block CAW. Extents move through `free`, `claimed`, `live`, and
`retired`; claim identity, owner identity, owner incarnation, base generation,
owner epoch, and an allocator-generated claim epoch remain stable until a
retired extent is proven safe to return to `free`. The claim epoch changes when
a released claim ID is allocated again, preventing a delayed release token
from freeing its successor.

Allocator, claim-index, and claim-gate blocks use monotonically increasing
generations. When a CAW is indeterminate and the expected block is still
visible, recovery may issue a logically unchanged generation-bump CAW and
stabilize it. Either the delayed mutation or the fence can win the old compare,
but not both. Recovery never changes an extent candidate, index slot, or gate
phase until the old command is observed or durably fenced.
An in-process transport reset advances a reset epoch. CAW dispatch is atomically
bound to that epoch, and allocator completion crosses a barrier and rereads the
exact replacement before advancing a gate. Pending transition tokens carry the
epoch of the actual fence CAW; an older token is classified as not completed
when its expected entry remains, rather than waiting forever for a command
canceled by reset.
Mount recovery scans the fixed gate region and helps every active descriptor to
completion; it does not need a whole-index or whole-allocator reconstruction.

An S3 backend can create immutable objects with `If-None-Match: *` and replace
a fixed anchor object with `If-Match`. ETags remain opaque version tokens.
Every backend runs the same contract scenarios in addition to its protocol
integration tests.

## Shared-Disk Voting

An optional voting region is separate from the filesystem anchor and object
arena. It stores one immutable fixed-membership configuration, one
compare-and-write heartbeat and durable vote slot per member, and one active
authority record. Version 1 supports exactly three or five configured members;
changing the roster creates a new fencing domain.

The region occupies seven consecutive physical logical blocks: configuration,
authority, and five member slots. A 512-byte voting envelope is placed at the
start of each 512- or 4096-byte physical block; all physical padding is
canonical zero and participates in the full-block compare. Three-member
configurations leave the last two member blocks entirely zero.

Formatting writes and stabilizes authority and member records first, then
publishes and stabilizes configuration last. A valid configuration therefore
commits the region. A zero configuration block is unformatted, while a nonzero
invalid or different block is a conflict and is never overwritten implicitly.

Every member restart advances a persistent incarnation counter and chooses a
new opaque incarnation identifier. Heartbeat sequence numbers increase within
that incarnation. A ballot number is the ordered pair of counter and candidate
slot; its candidate incarnation identifier, candidate incarnation counter, and
proposal identifier bind one exact campaign but do not act as ordering
tie-breakers. Durable votes cover the full proposal, including its majority
cohort, and never move to a lower ballot.

Publishing authority requires both an exact candidate campaign and a quorum of
member slots containing the exact proposal. Authority only advances to a
higher ballot. Domain identifiers, incarnation identifiers, and proposal
identifiers are generated uniquely; persistent counters prevent record ABA
even if an opaque identifier is accidentally reused.

Votes must cross a backend durability barrier before authority publication.
The backend then rereads the durable member slots, validates the exact quorum
certificate, and only then issues the authority compare-and-write. A caller
cannot publish authority from an unverified in-memory or merely visible member
snapshot.

Authority publication first observes the member blocks, runs a durability
barrier, and rereads those exact physical blocks. Any change aborts the attempt.
Only an unchanged, durable quorum can authorize the authority full-block CAW;
the authority itself requires a final barrier before consumers may rely on it.

Nodes use private-network observations and their local monotonic clocks for
failure suspicion. A majority certificate published through the voting region
selects the surviving cohort, but never proves that an evicted node has stopped
I/O. Mutable file extents may be reassigned only after a watchdog, host power
fence, or LUN-access revocation confirms that the old path is drained.

The initial deployment places voting records in a reserved area of the data
LUN. Multiple records on that LUN are not independent voting failure groups;
loss of the LUN stops both voting and filesystem service.

## Filesystem Semantics

CAWFS owns the minimal persistent metadata model for shared writable volumes.
Each filesystem root references three immutable B+trees: inode records keyed by
inode ID, directory entries keyed by parent inode ID and raw component name, and
extent mappings keyed by inode ID and logical offset. Inode 1 is always the root
directory. Directory values repeat their parent and identify a child inode whose
kind must match; empty files have zero logical and allocated size and no extent
mappings.

Current file data support is one non-empty immutable object and one extent
mapping, written once to an existing empty regular file. The mapping persists an
opaque backend `ObjectRef`; filesystem metadata does not interpret SCSI extent
identity. `allocated_bytes` is the mapped payload length in this slice. Reads
require one exact offset-zero mapping whose length matches both the inode and the
loaded immutable object, and reject malformed or incomplete layouts.

Formatting and filesystem mutation use one tree mutator per transaction so
later updates can read pages staged earlier in the same batch. They stage a new
filesystem root but do not publish it. The transaction coordinator remains the
only publication boundary and exposes conflict, indeterminate resolution, and
stabilization directly to its caller; the filesystem layer does not retry or
hide outcomes. File payloads are staged with `Transaction.putImmutable` before
their mapping and updated inode. The SCSI batch writes all staged payload and
metadata objects, crosses one durability barrier, activates every object as
live, and only then permits anchor publication.

Zettide remains responsible for FUSE behavior and POSIX policy above this
metadata core. Existing littlefs volumes stay single-writer; shared writable
volumes use CAWFS. Overwrite, append, truncate, holes, multiple extents, mutable
`.data` allocations, orphan reclaim, garbage collection, and general POSIX data
semantics remain unsupported. Deletion, rename, symlinks, Unicode policy, and
clocks are also outside the current metadata core. External fencing is still
required before writable ownership or takeover; metadata publication does not
prove that an old writer can no longer issue I/O.
