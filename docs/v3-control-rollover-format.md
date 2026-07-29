# V3 Control Rollover Checkpoint Format

## Status

This document freezes the authority checkpoint snapshot payload used by the planned dynamic Pool
control journal rollover. The codec is implemented in `src/v3/pool_authority_checkpoint.zig`.
Checkpoint records replicated to the current voter quorum advance authority while complete prior
history remains available; they are not yet accepted as compacted roots and no journal slots are
reused. The existing member-local checkpoint hint semantics remain unchanged.

All integers are little-endian. The fixed payload ends with CRC32C over all preceding bytes. Reserved
bytes must be zero. The enclosing 4096-byte control record also binds the payload through its shared
history digest and record CRC32C.

## Snapshot Payload

The payload is exactly 3584 bytes and fits inside the control record's 3752-byte payload capacity.

| Offset | Size | Field |
|---:|---:|---|
| `0x000` | 8 | Magic `DDVPCHK1` |
| `0x008` | 2 | Format version, 1 |
| `0x00a` | 2 | Flags |
| `0x00c` | 4 | Encoded size, 3584 |
| `0x010` | 32 | Previous authority shared-history digest |
| `0x030` | 32 | Authority data root digest |
| `0x050` | 8 | Authority writer term |
| `0x058` | 8 | Authority generation |
| `0x060` | 3200 | Canonical dynamic Pool topology |
| `0x0ce0` | 256 | Canonical dynamic Pool layout |
| `0x0de0` | 28 | Reserved, zero |
| `0x0dfc` | 4 | CRC32C |

Flag bit 0 records that authority passed through explicit administrative recovery. All other flag bits
are unsupported. The previous authority digest is nonzero. The embedded topology and layout must be
individually canonical, and the layout topology epoch cannot be newer than the embedded topology. The
initial rollover format rejects a topology containing a `joining` member; that member must be promoted
or removed first so compaction cannot discard bootstrap-completion evidence.

## Record Binding

An authority snapshot is carried by control record kind 9. Contextual validation requires:

1. The payload and record previous-history digests equal the selected prior authority digest.
2. Payload topology, layout, data root, writer term, generation, and recovery state equal the selected
   prior authority, so a checkpoint changes no snapshotted authority state; its kind, history digest,
   and witness count identify the new authority event.
3. The record set ID and membership epoch equal the embedded topology identity and epoch.
4. The record topology, layout, data root, writer term, and generation bind the payload snapshot.
5. The publishing member is a voter in the embedded topology and the transaction ID is nonzero.
6. The decoded outer record passes dynamic policy and shared-history digest validation.

Record CRC validation occurs when the enclosing 4096-byte record is decoded before contextual
validation. A payload plus its complete decoded control record is the self-contained authority
snapshot; the payload is not authority without that outer record and quorum evidence.

The snapshot codec alone does not make a checkpoint authoritative. A checkpoint directly extending
selected authority becomes its next authority only after current voter quorum has durably appended the
same shared-history event. An unknown append outcome freezes the coordinator and requires full reopen.
Rollover still requires compacted-root authority selection, a dual-header reclaim barrier, anchored
scan, and crash-safe slot clearing before any old record can be overwritten.

## Anchor Publication

The member anchor API writes one identical incremented header to the non-selected copy and syncs it,
then writes the same header to the other copy and syncs again. Only completion of both writes updates
the in-memory selected header and marks reclaim ready for the current writable open. Any publication
attempt first revokes that state. An interrupted publication may leave one newer valid header, but
never establishes a reclaim barrier on that member. Reopen observes header contents for recovery but
requires a fresh successful redundant publication before reclaim. No old control slot may be cleared
before the current voter quorum has established this current-open barrier.
