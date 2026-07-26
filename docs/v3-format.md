# DevDrive v3 On-Disk Formats

## Scope

This document freezes the v3 member header, topology record, replicated layout, genesis payload,
control record, commit certificate codecs, member-local creation, fixed-three-member set creation,
existing-set control authority, control journal scan, and append. It defines no volume mounting,
journal repair, signatures, manifest, erasure coding, or CLI behavior.
A volume containing only these records is not mountable.

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

Decoded headers own their label in a fixed-capacity value. Decoding copies label bytes; no label
slice refers to the input header buffer. Label construction validates UTF-8 and canonicalizes
unused capacity to zero.

`member_format.validate` is the public structural validation contract for an in-memory header.
Encoding and decoding use the same function, so direct validation applies the identical identity,
placement, role, algorithm, label, geometry, and checkpoint rules without changing wire bytes.
It does not apply open policy or establish topology authority.

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
offset is 4096-byte aligned inside the control region, and sequence and digest are nonzero. A
checkpoint publication increments the header sequence, writes the non-selected A/B copy, and
whole-file syncs it before changing the in-memory selected copy. Publication never overwrites the
currently selected copy. A successful publication therefore alternates copies and repairs degraded
header redundancy. A write or sync failure freezes the member and retains the old in-memory header,
source, and degradation state; a complete newer header may still be selected after reopen.

## Feature Policy

Structural decoding records all three feature masks but does not reject unknown feature bits.
Open-mode policy is evaluated separately:

| Unknown feature class | Read-only | Writable |
|---|---|---|
| Compatible | Accept | Accept |
| Read-only-compatible | Accept | Reject |
| Incompatible | Reject | Reject |

The initial supported masks are zero.

## Subformat Policy

Structural decoding preserves metadata, object, layout, and control-record format versions even
when they are unknown. This keeps unsupported values available for diagnostics and A/B static
comparison. It does not imply that an unknown subformat can be used.

The initial supported value for each of the four subformat versions is exactly 1. Before either
read-only or writable use, open policy rejects an unsupported metadata, object, layout, or
control-record format with a distinct error. Subformat policy is independent of feature-bit
policy; callers use the combined open policy before accessing a member.

## A/B Selection

Each copy is structurally decoded independently, retaining its decode error. One valid copy is
selected with degraded redundancy. If both are invalid, selection reports no valid header.

When both copies are valid, all static fields are compared before sequence numbers. A static
conflict rejects both copies, so a higher sequence cannot replace identity or geometry. Static
comparison excludes only header sequence, checkpoint offset, checkpoint local record sequence,
checkpoint digest, and the final CRC. With equal static fields, the higher sequence wins. Equal
sequences with different checkpoint semantics are ambiguous; identical copies select A.

## Member File Boundary

The v3 member API opens or exclusively creates a file relative to a caller-owned directory using a
single-component basename. It does not expose the underlying file handle. Read-only opens
take a shared non-blocking advisory lock; writable opens take an exclusive non-blocking lock.
Header A at offset 0 and header B at offset 4096 are read and decoded independently after locking.
A single valid copy permits a degraded open. When neither copy is valid, the first transport read
error takes precedence over `NoValidMemberHeader`. Open policy is checked after A/B selection, and
the physical file length must exactly equal the selected header's `member_bytes` value.

Region I/O uses offsets relative to the control, metadata, or data region and cannot cross a
region boundary. Empty I/O is valid at a region end. Reads are exact; an unexpected end is
`TruncatedMember`. Reads, writes, whole-file syncs, and close are serialized by one member mutex so
close cannot release the file handle during I/O. Writes require writable mode. After lifecycle and
boundary validation, an empty write succeeds without dirtying the member, consuming a fault, or
issuing file I/O. A nonempty write is dirty before the underlying I/O starts. A durable write holds
the member mutex across the complete positional write and whole-file sync, so close cannot run
between them; success clears the dirty state. Any injected or real write or sync failure freezes
future writes and syncs while reads remain available. A dirty,
unfrozen close syncs the file. Close waits for the member mutex without cancellation, always
releases the lock and file resource, reports the first durability error, and is idempotent. This
boundary also supports initialized member creation. Create validates the complete header and genesis
payload before filesystem mutation. The initial header must have sequence 1, a zero checkpoint trio,
writable feature and subformat policy, and `member_bytes` no larger than `maxInt(i64)`. Genesis
topology identity, member placement and roles, topology digest, layout, and chunk size must match the
header. Creation uses exclusive create and an exclusive non-blocking lock, so an existing path is
reported as `PathAlreadyExists` without truncation.

After extending the file, create publishes in this exact durability order: whole-file sync, write the
member-local genesis to control slot 0, whole-file sync, write header B at offset 4096, whole-file
sync, write header A at offset 0, whole-file sync, then on Linux sync the parent directory. The Linux
step opens and closes a sync-capable `.` duplicate relative to the borrowed `Dir`; it never closes or
takes ownership of the caller's handle. Thus no normally openable header exists before genesis is
durable, and B is recoverable before A is published. A successful create returns a writable, clean,
nondegraded member selected from A. Every failure unlocks and closes but retains the created file for
diagnosis or recovery; it never unlinks. A Linux parent-directory sync failure can therefore leave a
complete member that can
be reopened. Other targets skip parent-directory sync, so successful return does not guarantee
directory-entry durability there. The control journal scanner uses exact region reads.

The fixed-three-member creation boundary accepts three borrowed directory handles and basenames in
topology slot order. Before creating any file, it validates every member input and cross-validates
the complete header set against the genesis topology and layout. Reusing the same borrowed directory
handle and basename for multiple slots is rejected. It then creates members in slot order using the
single-member durability protocol. A failure closes and unlocks every member already
returned, retains every file whose creation was attempted, and does not attempt later slots. Set
close attempts all three member closes, reports the first error, and is idempotent. The set owns only
the returned member handles; caller-owned directories and basename storage remain borrowed. This
boundary does not open existing sets, select authority, establish quorum, or repair partial creation.

## Member Set Open and Control Authority

Existing-set open accepts three slot-indexed optional locations and acquires member locks in slot
order. A null location is absent. A provided member that cannot open, scans unsuccessfully, or is in
the wrong input slot is recorded in that slot's diagnostics and excluded. History allocation failure
aborts open. Every error path releases all retained history allocations and member locks.

Open has three intents. Diagnostic open requires one readable history and may return without an
authority. Read-only open requires a genesis authority. Writable open additionally requires a
control-write-ready quorum and never silently downgrades. The resulting owning set must be moved
rather than copied. It exposes per-slot status, selected authority, and optional control-write state.
An out-of-group member's writable handle is closed before successful return; its retained history is
available only as diagnostic evidence.

Genesis witnesses are unique topology slots whose accepted first records have the same shared
history digest. At least two witnesses establish the genesis group. Selected headers are
cross-validated for identity, static geometry, format, and layout even when the third member is
missing. Other genesis groups are foreign. A quorum-observed membership prepare or commit is rejected
until membership transitions have defined payload and authority semantics.

Generation commits are grouped by shared history digest and count each selected member at most once.
A group with at least two witnesses is a candidate only after its certificate resolves to exact
prepare evidence under the selected topology. Failure to validate a quorum-observed candidate is
fatal and cannot fall back to an older state. Candidates are ordered only by their position in an
accepted digest chain. The unique ancestry-maximal candidate becomes authority; incomparable quorum
candidates are conflicting authority. Generation, writer term, local sequence, physical frontier,
and checkpoint hints are never ordering tie-breakers.

Control-write-ready requires at least two writable, unfrozen selected members with no unresolved
tail damage, available journal capacity, the selected authority in their history, and exactly equal
tail history digests. The stable tail must currently be genesis or a generation commit; a prepare
quorum remains recovery-only. Interior abandoned damage, zero holes, degraded header redundancy, and
stale checkpoint hints do not independently disqualify a member. This state establishes only that a
control journal quorum can be extended. It does not establish metadata or data-root recovery and is
not a volume-writable claim.

## Topology Record

A topology is a separate 512-byte record. It defines exactly three members and does not define
topology journal I/O, quorum selection, or membership transitions. All integers are
little-endian. The committed fixture is an epoch 1 genesis topology example.

| Offset | Width | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVTOP1\0` |
| `0x008` | 2 | Format version, 1 |
| `0x00a` | 2 | Header size, 80 |
| `0x00c` | 4 | Encoded size, 512 |
| `0x010` | 16 | Set ID |
| `0x020` | 8 | Topology epoch |
| `0x028` | 32 | Parent topology digest |
| `0x048` | 2 | Control write quorum, 2 |
| `0x04a` | 2 | Member count, 3 |
| `0x04c` | 4 | Topology flags, zero in version 1 |
| `0x050` | 96 | Three canonical member descriptors |
| `0x0b0` | 332 | Reserved; zero in version 1 |
| `0x1fc` | 4 | CRC32C of bytes `[0, 508)` |

Each 32-byte descriptor contains a 16-byte member ID, a `u16` slot at byte 16, a control role
at byte 18, one reserved zero byte, `u32` role flags at byte 20, and eight reserved zero bytes.
The only version 1 control role is voter (`1`). Role flags are exactly metadata and data (`3`),
matching the member header.

Encoding sorts descriptors by slot. Slots are unique and cover `0..2`, so caller order cannot
change the encoded bytes. Decoding rejects descriptors that are not already in canonical slot
order. Set and member IDs are nonzero, member IDs are unique and differ from the set ID, and all
reserved bytes are zero. Epoch 1 has a zero parent digest; later epochs have a nonzero parent
digest. The topology digest is BLAKE3-256 over canonical bytes `[0, 508)` and does not include
the final CRC32C. The committed topology fixture has digest
`af1b230be435c77b3f1ca3064bd757df027bc7c1863bc1ae66e528dc2258a107`.

`validateMemberHeader` validates the supplied topology and cross-validates one structurally valid
header against it. Set ID, member identity and slot, member count, role flags, and a separately
supplied, already verified genesis digest must match. The genesis digest does not match the current
topology digest after epoch 1. This single-member operation does not require all three members and
does not determine quorum or authority.

`validateMemberSet` reuses single-member cross-validation and additionally requires exactly one
header for each member, independent of input order. Feature masks, creation time, logical capacity,
all three region geometries, block and I/O sizes, four subformat versions, algorithm IDs, and label
agree across the set. Header sequence and checkpoint hint fields are member-local and may differ.
Structural validation, set completeness, and open policy remain separate contracts.

## Replica Layout

A layout is a separate 256-byte envelope. Version 1 defines only replicated kind `1`, with
exactly three replicas. All integers are little-endian. The layout contains no allocation,
capacity reservation, manifest, placement I/O, quorum-commit, or erasure-coding state.

| Offset | Width | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVLAY1\0` |
| `0x008` | 2 | Envelope version, 1 |
| `0x00a` | 2 | Layout kind, 1 is replicated |
| `0x00c` | 4 | Encoded size, 256 |
| `0x010` | 8 | Layout epoch |
| `0x018` | 8 | Topology epoch |
| `0x020` | 4 | Chunk size |
| `0x024` | 2 | Target replicas, 3 |
| `0x026` | 2 | Durable write threshold, 2 |
| `0x028` | 2 | Read threshold, 1 |
| `0x02a` | 2 | Member count, 3 |
| `0x02c` | 4 | Layout flags, zero in version 1 |
| `0x030` | 6 | Three canonical `u16` member slots, `0, 1, 2` |
| `0x036` | 198 | Reserved; zero in version 1 |
| `0x0fc` | 4 | CRC32C of bytes `[0, 252)` |

Both epochs are nonzero. Chunk size is a power of two. Replicated layouts require the exact
thresholds above, three unique slots covering `0..2` in ascending order, and zero flags and
reserved bytes. The layout digest is BLAKE3-256 over canonical bytes `[0, 252)` and excludes the
final CRC32C. The committed fixture has digest
`40d718657f7fc9ee67045f8d3658c0a246e509fa1ae0cd770cd8f81885ffdd19`.

Structural decoding preserves an unknown layout kind for diagnostics. It is not corruption:
the separate kind policy rejects it with `UnsupportedLayoutKind` before use. A future layout
kind requires its own defined payload and version; version 1 does not reserve speculative
erasure-coding fields.

Topology validation is pure and requires the layout topology epoch not to exceed the already
verified current topology epoch. Every replica slot must exist and have voter control and data
roles. Header validation is also pure: callers first verify member and genesis identity, then
layout validation checks exactly three headers, matching chunk sizes, and supported layout
format version. It does not select member authority. Member-file preallocation is capacity
policy and is not encoded in the layout.

## Genesis Payload

The genesis payload is an owned 1024-byte envelope containing the canonical epoch 1 topology and
replicated layout. It is the exact payload of every member-local genesis control record. It does
not add authority, quorum selection, file creation, or journal I/O.

| Offset | Width | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVGEN1\0` |
| `0x008` | 2 | Format version, 1 |
| `0x00a` | 2 | Flags, zero |
| `0x00c` | 4 | Encoded size, 1024 |
| `0x010` | 4 | Topology length, 512 |
| `0x014` | 4 | Layout length, 256 |
| `0x018` | 8 | Reserved, zero |
| `0x020` | 512 | Canonical topology bytes |
| `0x220` | 256 | Canonical layout bytes |
| `0x320` | 220 | Reserved, zero |
| `0x3fc` | 4 | CRC32C of bytes `[0, 1020)` |

Decoding requires exactly 1024 bytes and rejects both truncation and trailing bytes. It copies the
embedded records into owned topology and layout values. The topology must be epoch 1 with a zero
parent digest. The layout must be epoch 1, refer to topology epoch 1, use replicated kind `1`, and
pass topology validation. The genesis payload digest is BLAKE3-256 over bytes `[0, 1020)` and does
not add a control-record field. The committed fixture has payload digest
`e8102b500fbc4f4685e9bb6460817ff3905d70889fbdfc8e4e8cc8e0cc5790a2`.

`makeRecord` creates a member-local genesis control record with sequence and membership epoch 1
and all required genesis fields zero. Its set ID and topology and layout digests come from the
payload. The member must exist in the topology and have voter control and data roles.
`validateRecord` applies control-record policy and independently recomputes and verifies the
record history digest, so callers do not need to decode the record first. It requires an exact
genesis payload, cross-validates set and member identity, and verifies both canonical
embedded-record digests. The three member records share one history digest because member-local
identity is excluded from control history, while their complete record digests remain distinct.

## Control Record

A control record is exactly 4096 bytes. Its codec and validation are pure: they perform no
journal I/O, recovery scanning, quorum selection, or authority decisions. All integers are
little-endian.

| Offset | Width | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVCTL1\0` |
| `0x008` | 2 | Envelope version, 1 |
| `0x00a` | 2 | Record kind |
| `0x00c` | 4 | Encoded size, 4096 |
| `0x010` | 2 | Header size, 320 |
| `0x012` | 2 | Header flags, zero |
| `0x014` | 4 | Payload length, at most 3752 |
| `0x018` | 8 | Local record sequence |
| `0x020` | 8 | Membership epoch |
| `0x028` | 8 | Writer term |
| `0x030` | 8 | Generation |
| `0x038` | 16 | Set ID |
| `0x048` | 16 | Member ID |
| `0x058` | 16 | Mount session ID |
| `0x068` | 16 | Transaction ID |
| `0x078` | 32 | Previous local record digest |
| `0x098` | 32 | Previous history digest |
| `0x0b8` | 32 | Current history digest |
| `0x0d8` | 32 | Data root digest |
| `0x0f8` | 32 | Topology digest |
| `0x118` | 32 | Layout digest |
| `0x138` | 8 | Reserved, zero |
| `0x140` | 3752 | Payload followed by zero padding through `0xfe8` |
| `0xfe8` | 8 | Repeated local sequence |
| `0xff0` | 2 | Repeated record kind |
| `0xff2` | 2 | Footer flags, zero |
| `0xff4` | 4 | Repeated payload length |
| `0xff8` | 4 | Footer magic `CTL!` |
| `0xffc` | 4 | CRC32C of bytes `[0, 4092)` |

The record digest is BLAKE3-256 over canonical bytes `[0, 4092)` and excludes only the final
CRC. Decoding copies the payload into a fixed-capacity owned value. Unused owned capacity and
wire padding are zero.

Kinds have stable values: genesis `1`, writer fence `2`, generation prepare `3`, generation
commit `4`, membership prepare `5`, membership commit `6`, mount dirty `7`, clean shutdown `8`,
and checkpoint `9`. Structural decoding preserves unknown kinds. Separate kind policy rejects
them before use.

Sequence and membership epoch are nonzero. Set and member IDs are nonzero and distinct.
Topology and layout digests are nonzero. Sequence 1 has a zero previous local record digest;
later sequences have a nonzero digest. Genesis is membership epoch 1 and local sequence 1, so its
previous local record digest is zero. It also has zero term, generation, session, transaction,
previous history, and data root. Other kinds have a nonzero previous history. Generation prepare
and commit additionally have nonzero term, generation, session, transaction, and data root.

The history digest is BLAKE3-256 over the following concatenation, with integers in
little-endian: the 16-byte domain `DDVCTL1-HISTORY\0`, kind, set ID, membership epoch, writer
term, generation, mount session ID, transaction ID, previous history digest, data root digest,
topology digest, layout digest, payload length, and payload. It excludes member ID, local
sequence, previous local record digest, stored current history digest, footer, and CRC. Encode and
decode verify the stored value against this canonical calculation.

The committed control-record fixture has record digest
`d6d8f95afb52b9b488823c3380eff25e97b649b970fb7d5e92598ed49d93f785`.

## Control Journal Scan

The member-local scanner reads every 4096-byte slot in the control region. An all-zero slot is a
hole, not an end marker. A nonzero slot advances the physical frontier to one past its slot, so the
frontier is one past the highest nonzero slot and the journal is full exactly when the frontier
equals the slot count. Zero holes are zero slots below that frontier. A checkpoint hint never skips
a slot or establishes commit, generation, topology, or chain authority. The full scan reports
`none` for a zero hint trio; `valid` when the hinted slot is an accepted checkpoint with matching
set and member identity, local sequence, and raw record digest and remains the tail; `stale` when
such a checkpoint is followed by another accepted record; and `invalid` for a zero, structurally
invalid, wrong-kind, wrong-sequence, or wrong-digest hinted slot. Hint failure alone does not fail
the scan. A decoded hinted slot still follows ordinary hard-failure rules for foreign identity,
semantic errors, or chain errors.

A nonzero slot that fails structural control-record decoding is counted as invalid and consumed,
then scanning continues. A later accepted record that directly extends the preceding accepted
record proves intervening invalid slots to be abandoned interior damage. Invalid slots not followed
by such an accepted extension are unresolved tail damage. An empty journal containing only invalid
slots therefore has no tail and has unresolved tail damage. Callers must not treat unresolved tail
damage as writable space.

Every decoded record is a hard validation boundary. Its set and member IDs must match the selected
member header, its kind and semantic policy must be supported, and its stored history digest has
already passed structural decoding. The first accepted record must be a fully validated genesis at
local sequence 1, including its embedded topology and layout. The scanner computes the canonical
genesis topology digest and validates the selected header against that topology and digest. This
binds the header's set ID, member ID, member slot, role flags, member count, and genesis topology
digest back to the decoded genesis payload. The header chunk size must also equal the genesis layout
chunk size. A later genesis is invalid. Subsequent local sequences must increase by exactly one,
their previous history digest must equal the preceding accepted history digest, and their previous
record digest must equal BLAKE3-256 of bytes `[0, 4092)` from the preceding accepted slot as read.
Duplicate, regressed, or gapped sequences, foreign identity, unsupported or semantically invalid
records, either digest mismatch, or a genesis/header mismatch aborts the scan. The scanner does not
choose a longest chain, append, repair, update checkpoint hints, or determine quorum authority. A
structurally and semantically valid final record is accepted without inferring whether another
member acknowledged it.

Callers that need cross-member recovery evidence can request an allocator-owned history scan. It
uses the same full-scan rules and result as the member-local scanner while retaining every accepted
record, its raw record digest, and its physical slot in chain order. Zero holes and structurally
invalid slots are represented only by the ordinary scan counters; they are not history entries.
History lookup supports both shared history digest and member-local raw record digest. Releasing the
history frees its complete slot-capacity allocation. The owning history value must be moved rather
than copied; evidence validation borrows pointers to it. Collecting evidence does not select
authority.

## Control Journal Append

Each member enforces at most one active `Journal` owner with an atomic runtime claim. Opening a
journal claims the member before performing a full control scan and releases the claim if scanning
or open policy fails. A journal requires a valid genesis: an empty journal is `MissingGenesis`, and
one containing only invalid records is `JournalNeedsRecovery`. Writable open also rejects any
unresolved tail damage with `JournalNeedsRecovery`; read-only open accepts valid genesis plus
unresolved tail damage for diagnostics. `Member.openAt` remains a low-level header and file boundary,
so operational callers complete open with `Journal.open`. A journal retains the resulting tail,
digests, physical frontier, and damage state. Appends
and state snapshots are serialized by the journal mutex and never accept a caller-supplied scan
result or physical slot. The API does not expose overwrite, wraparound, or raw control-slot writes.
Journal close is idempotent and releases the member claim, allowing a new owner to open and rescan.
A closed journal rejects append and state operations. If the member closes first, the journal can
only be closed or deinitialized; its close still releases the claim.

An append proposal supplies record semantics and payload, but not chain authority. The journal
replaces set ID, member ID, local sequence, previous record digest, previous history digest, and
current history digest from the selected member header and retained tail. An empty journal accepts
only a fully validated genesis proposal; a nonempty journal rejects another genesis. Proposal
validation and encoding complete before any write. Ordinary append rejects checkpoint records;
callers use the explicit checkpoint API.

Replicated callers use the exact two-step append boundary instead of ordinary append. A tail token
commits to the retained local sequence, raw record digest, shared history digest, and physical
frontier. Exact prepare requires that complete token, injects the same member-local chain fields,
validates policy, and returns an owned record, canonical bytes, raw digest, and target slot without
performing I/O or changing retained state. Prepared append reacquires the journal mutex, rebuilds the
canonical prepared value against the retained tail, and rejects a stale token or any changed field,
byte, digest, or slot before I/O. Only an exact match proceeds to the same durable write and retained
state update used by ordinary append. This lets a coordinator prove a common shared parent before
any member write while preserving member-local raw chains.

The append target is exactly the retained physical frontier. Interior zero or invalid slots are
never reused, and a full journal never wraps. Read-only, closed, frozen, full, sequence-overflow,
and unresolved-tail states reject before writing. Append does not resolve or abandon tail damage.
The encoded slot is committed with one member durable write. Only successful write and whole-file
sync advance the retained tail and frontier.

A failed write or sync leaves the retained journal state unchanged and freezes the member. Recovery
closes and reopens the member, then performs a new full scan: a failure before writing preserves the
old tail, a partial slot is unresolved tail damage, and a complete valid slot is accepted even when
the append call did not acknowledge it. Such a full-valid unacknowledged record becomes the new
tail and can be extended normally. This is local durability only and establishes no quorum or
authority.

The checkpoint API runs under the journal mutex. It first performs the same durable record append
and advances retained journal state, then publishes the checkpoint hint through the member's A/B
header protocol. A record write or sync failure leaves the header untouched. A subsequent header
write or sync failure returns an error and freezes the member, but the durable checkpoint remains
the retained journal tail and is never rolled back. Reopen selects whichever old or fully published
header copy is valid and always performs a full scan. Header sequence overflow is rejected before
header I/O, after the checkpoint record has become durable.

## Commit Certificate

A generation commit payload is exactly one 192-byte commit certificate. Generation prepare
payloads remain opaque.

Generation commit evidence validation requires both attested member histories. Each attestation
must resolve to the exact raw digest of an accepted generation prepare on the named topology voter,
and both prepares must have the attested shared history digest. The commit must directly extend that
prepare history and match its set, membership epoch, writer term, generation, mount session,
transaction, data root, topology, and layout fields. Its set, membership epoch, and topology digest
must also match the topology used to validate the certificate. The validator locates the commit by
member ID and raw digest in a borrowed history; detached records are not accepted. It re-decodes each
retained raw slot, recomputes its raw digest, and checks the cached record before using the evidence.
This proves certificate integrity and prepare/commit binding only; it does not prove that the commit
itself reached quorum.

| Offset | Width | Field |
|---:|---:|---|
| `0x00` | 8 | Magic `DDVCERT1` |
| `0x08` | 2 | Version, 1 |
| `0x0a` | 2 | Attestation count, 2 |
| `0x0c` | 4 | Flags, zero |
| `0x10` | 80 | Attestation A |
| `0x60` | 80 | Attestation B |
| `0xb0` | 12 | Reserved, zero |
| `0xbc` | 4 | CRC32C of bytes `[0, 188)` |

Each attestation contains a 16-byte member ID, a 32-byte prepare record digest, and a 32-byte
prepare history digest. Encoding orders attestations by ascending member ID. Member IDs are
distinct, all digests are nonzero, and both prepare history digests are identical. The
certificate digest is BLAKE3-256 over bytes `[0, 188)` and excludes the CRC. Pure topology
validation requires both members to be current voters. This is a two-voter crash and hardware
integrity check, not a signature, Byzantine proof, journal operation, or quorum authority claim.
The committed certificate fixture has certificate digest
`081fc29e4f925cdf4f24d638c0e14b23c1d5c0447f481ae1b75dd765e9868e07`.
