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

The logical anchor is a fixed 512-byte envelope. A SCSI backend may embed it in
a larger logical block and use that complete physical block as its opaque
version token. Every published envelope includes a monotonically increasing
generation and transaction identifier, so a physical anchor value is never
reused.

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

The transaction coordinator snapshots one base anchor and owns one write batch.
It stages immutable objects, writes the commit record last, prepares the batch,
conditionally publishes the next anchor, and stabilizes a definite winner. The
published root must either belong to the transaction's batch or already be
loadable from the store.

A transaction is single-use. Conflicts and confirmed non-publications are
terminal. An indeterminate publication must be resolved before stabilization.
If publication succeeds but stabilization fails, only stabilization is retried;
the logical transaction is never republished. After backend recovery, terminal
resolution can detect that an unstable publication was rolled back.

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

## Planned Backends

The SCSI backend uses one logical-block COMPARE AND WRITE for anchor updates.
It owns append allocation and maps prepare/stabilize to cache synchronization.

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

Filesystem semantics live above this repository. Zettide will adapt its FUSE
layer to a backend-neutral filesystem interface. Existing littlefs volumes stay
single-writer; shared writable volumes use this engine.
