# Volume range leases

## Scope and current boundary

`RangeLeaseService` adds Raft-backed metadata authorization for half-open Volume
byte intervals `[offset_bytes, offset_bytes + length_bytes)`. Reads may overlap
reads. Writes exclude every overlapping lease, including another lease held by
the same Node. Adjacent intervals do not overlap. Offsets and nonzero lengths
must be 4096-byte aligned and fit the immutable Volume capacity.

This provides control-plane leases, holder admission, a durable storage fence,
and an opt-in automatic reaper. It is not a new payload RPC.
`controller_agent.RangeLeaseSession` provides acquire/renew/revoke, polling,
and synchronized I/O admission/drain tracking for data services. No existing
frontend is automatically opted into range leasing yet. An I/O path using this
session must still enforce Replica readiness, primary authority, signed write
coordination, and backend fencing. A metadata lease does not make a provisioning
Volume readable/writable or permit bypassing the current primary.

## API

All RPCs are under `zettide.controller.v1.RangeLeaseService`:

| RPC | Meaning |
| --- | --- |
| AcquireLease | Reserve a caller-selected UUIDv7 lease ID and interval |
| RenewLease | Commit a new token revision for the same holder and interval |
| RevokeLease | Commit REVOKING; the interval is still reserved |
| CompleteRevoke | Holder drain acknowledgement; commit REVOKED |
| GetLease | ReadIndex-protected lookup, including terminal records |
| ListLeases | ReadIndex-protected per-Volume list, including terminal records |

Mutation requests carry `request_id`, `lease_id`, `volume_id`, `holder_node_id`,
16-byte `holder_boot_id`, `offset_bytes`, `length_bytes`, and READ/WRITE `mode`.
IDs other than boot ID are canonical UUIDv7 text. The holder Node must already
be registered. Acquire requires `expected_resource_version = 0`; later
operations require the last observed resource version and the entire original
binding. A range or mode change requires revoking/draining the old lease and
acquiring a new ID. A write lease admits both read and write I/O.

Mutations share the controller's global request-ID domain. A timeout is an
unknown outcome: retry the exact request with its original request ID. A new
operation, corrected version, or retry after a conflict has cleared requires a
new request ID. Retrying a previously rejected Acquire returns the original
conflict even after the conflicting leases have been revoked.

Responses contain creation revision, current resource version, token revision,
state, and the fixed duration of 30,000 ms. Renewal changes the token revision;
Revoke/CompleteRevoke change only resource version and state. Replaying a request
does not change any revision. IDs and terminal lease records are never reused.

List requires `volume_id`, defaults to 100 records, and accepts at most 1000.
Continue with `after_lease_id = next_after_lease_id` from the previous response.
Ordering is canonical lease ID order; pagination is not a frozen multi-page
snapshot. No continuation value means the current list is exhausted.

## Holder protocol

1. Create one `RangeLeaseSession` for the holder process's stable Node ID and
   fresh boot ID. Its allocator must be thread-safe. Keep the endpoint backing
   storage alive until session deinitialization.
2. `acquire` or `renew` sends the request, checks the echoed binding, and installs
   the token under the session mutex. The local deadline is anchored **before
   sending the RPC**, using the suspend-inclusive boot clock, not reply arrival.
3. Call `beginIo` before each actual backend I/O, supplying the exact token,
   Volume, interval, and access mode. It checks identity, scope, permission,
   token revision, and deadline, then returns an in-flight ticket.
4. Call `finishIo` only after the underlying operation actually completes or its
   cancellation has drained. Caller timeout alone does not justify finishing a
   ticket. Physical completion after the hard deadline is not reported as a
   lease-authorized success.
5. Schedule renewals early (for example, every 10 seconds), and poll revocation.
   `revoke` requests controller revocation and closes local admission;
   `pollRevocation` also observes revocation initiated elsewhere. It closes
   admission even if the original grant reply has not arrived yet.
6. Once every ticket for the lease has drained, `pollRevocation` sends
   CompleteRevoke with a **distinct, stable ACK request ID**. Failed/uncertain ACKs
   are retried or resolved by GetLease. Pending I/O prevents ACK transmission.

The gate stops admitting new I/O five seconds before the hard deadline. Exact
replays cannot extend an installed deadline. Renewal cannot revive an expired
or revoked gate. Old-token admission is rejected after renewal; already admitted
tickets retain their original completion deadline. Local revocation tombstones
reject delayed Acquire/Renew replies. A process restart gets a new boot ID and
cannot install or acknowledge the previous process's leases.

## Revocation and failures

```text
ACTIVE --Revoke (Raft)--> REVOKING --holder drain ACK (Raft)--> REVOKED
  |                           |
  +---- overlapping writers remain blocked ----+
```

Revoke success means **revocation was accepted**, not that old I/O has stopped.
Only REVOKED releases the interval. Both ACTIVE and REVOKING prevent Volume
deletion. A revoked lease remains queryable after Volume deletion.

Automatic reclamation is **opt-in through `Runtime.Options.range_lease_fencer`**.
Without that storage adapter, lost holders continue to block conflicting grants.
There is no force-release RPC. Neither elapsed time nor heartbeat staleness alone
proves that physical I/O has drained.

## Durable storage fencing and automatic expiry

`data-service-contracts.range_fence.Gate` serializes token checks and physical I/O
against durable fencing. A payload caller supplies the lease token, Volume,
interval, and mode. The trusted `Backend.authorize` callback must validate the
controller-issued full binding and required primary authority; a large integer
is not a credential. Hold the returned guard until physical completion or
cancellation drain, never merely until an RPC timeout.

A barrier binds the last granted token to the committed REVOKING resource
revision. That revision must be greater than the token revision. While holding
the same gate, fencing drains pending/replay work through `Backend.drain_flush`,
flushes media, appends the durable barrier, fsyncs the ledger, replaces it, and
fsyncs its parent. Only then can it acknowledge. Failures poison admission until
recovery; startup validates and syncs the recovered file and parent before an
idempotent retry can acknowledge an earlier uncertain rename.

Fencing is keyed by **Volume + lease ID**, not a Volume-wide maximum revision.
Another valid overlapping reader remains authorized. A fenced lease ID is
terminal, including delayed renewals or forged larger revisions. The reference
gate serializes I/O per gate instance; it does not yet optimize physical I/O
parallelism for disjoint intervals.

Use a dedicated ledger, never the Replica primary-fence ledger. Bootstrap with
`Gate.createLedger` once on new storage; it refuses to overwrite an existing
file. Recovery uses `Gate.open`, which fails if history is missing or corrupt.
Never recreate missing history as a recovery fallback. The enclosing storage
service must own the process lock and gate lifetime.

The opt-in controller worker performs:

```text
ReadIndex -> observe grant/renewal for 30 s -> Revoke CAS through Raft
  -> storage fence_all -> check exact receipt -> CompleteRevoke through Raft
```

It uses the suspend-inclusive monotonic boot clock outside Raft apply. Renewal
changes the observed revision and restarts the conservative expiry observation.
A new leader/process waits a complete TTL for ACTIVE records; existing REVOKING
records can resume fencing immediately. This can delay reclamation, but never
extends the holder's local admission window. Version CAS handles a concurrent
renewal; mutation retries retain deterministic request IDs. Reserve the
`range-reaper/` request-ID prefix for the worker.

The `Fencer.fence_all` adapter is a **trusted all-target assertion**, not a
cryptographic certificate. It must cover every possible read/write destination,
old routes, durable replay, and fence inheritance before publishing new routes.
An unavailable target, unsupported ungated path, or mismatched receipt must fail
without releasing the interval. Call cancellation must promptly unblock shutdown.
Unavailable leases are retried round-robin; range work alternates with placement
reconciliation so it does not starve primary recovery.

**Production integration remains incomplete:** the shipped controller daemon
does not configure this adapter, and existing payload paths are not yet all
forced through the storage gate. There is intentionally no CLI/config switch
that enables unsafe timer-only reclamation. The opt-in runtime is usable by an
embedding that supplies a complete storage integration; a holder-local gate or
one Replica ACK is insufficient.

CompleteRevoke is a **trusted holder assertion**, not a cryptographic drain proof.
The current controller transport does not authenticate/authorize callers. Keep
these RPCs on an isolated trusted control network. Node/boot IDs alone are not
credentials. Exposing this service to untrusted clients is not supported.

## Persistence and limits

Range leases were introduced in command v10 and snapshot v13. Current command
v11 and snapshot v14 additionally support Filesystem metadata and require a
coordinated controller upgrade. Previous command/snapshot formats remain readable. Lease transitions
are retained in the global request history; restore replays them in applied
revision order and compares every result with the recorded response. A
canonical lease-view digest detects lost or modified terminal/grant history.
Restore is atomic, including allocation failures. There are no wall-clock
reads or external I/O inside Raft apply.

There are at most 10,000 lease IDs (including revoked records), 50,000 global
request records, and 4096 concurrent local tickets per holder gate. Exhaustion
fails closed. Request-history compaction/lease GC is not implemented; frequent
renewal consumes history, so these limits are a development boundary, not an
unbounded production leasing service.

## Verification

Controller tests exercise shared readers, exclusive writers, adjacent ranges,
CAS, boot mismatch, bounds/overflow, cross-resource dedup, two-phase revocation,
Volume deletion protection, snapshot replay/digest corruption, and allocation
failures. Runtime tests exercise real RPC, ReadIndex queries, pagination, and
revocation across a single-voter WAL/snapshot restart. Holder-client transport
tests verify it does not send a drain ACK while a ticket remains in flight.
The three-voter runtime test also verifies that leader failover preserves a
REVOKING barrier, rejects overlapping grants, and retains the terminal record
when the former leader rejoins. Production payload-path enforcement remains
outside this test coverage.

The automatic-expiry integration test uses a real 30-second deadline, real Raft
and RPC, a file-backed storage gate, and a physical write held across expiry.
It verifies failed fencing and mismatched receipts leave REVOKING intact,
completion releases without a holder ACK, and old tokens remain rejected after
storage-gate reconstruction. Separate tests cover shared readers, uncertain
fsync recovery, corrupt/missing ledgers, leader-term/clock resets, and renewal
observations. The all-target network/routing adapter is not implemented or
validated by this single-storage-target test.
