# V3 Control Rollover Checkpoint Format

## Status

This document freezes the authority checkpoint snapshot payload and dynamic Pool control journal
rollover protocol. Checkpoint records replicated to the current voter quorum advance authority.
Redundant anchor publication, durable reclaim, compacted-root recovery, and circular append permit
old control slots to be reused without retaining the complete prior history.

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

## Reclaim And Circular Append

Replacing an already compacted anchor publishes every current voter before clearing any member. A
one-voter topology therefore requires 1/1 participation, and a three-voter topology requires 3/3
participation. The full voter set preserves an old- or new-anchor quorum throughout migration. The
first compacted anchor may be recovered from an authoritative checkpoint quorum because complete
linear history has not yet been reclaimed. A partial publication freezes the coordinator and never
starts reclaim.

After all publications succeed, each member durably zeros the ring arc after its current tail up to,
but excluding, the published anchor. Slot 0, the active anchor, and all live successors are retained.
A member becomes ring-write-ready only after its own current-open redundant publication and complete
clear. Reclaim failures exclude that member; fewer than the current quorum of successful members
freezes the coordinator.

Circular append uses the next physical ring slot, skips slot 0, and never overwrites the active anchor.
The target must be zero before writing. Generation and membership transactions require three free
slots: two records plus one reserved checkpoint slot. Bootstrap requires two free slots. An ordinary
authority checkpoint requires two slots so it cannot consume the final rollover slot; an explicit
rollover checkpoint requires one and must involve every supported voter. New Pools therefore require
at least five control records.

Reopen never inherits reclaim readiness. Anchored voters must repeat redundant publication and reclaim
before ordinary writes resume. Linear current voters remain write participants only while the active
voters still retain a quorum of one self-contained compacted root. A normal membership transition may
not remove that root quorum; it must publish a checkpoint for the new voter set first. Administrative
recovery may rebuild the barrier from its explicitly trusted survivor. A directly invoked member-local
checkpoint cannot replace an active authority anchor; anchor replacement is only performed by the
replicated rollover operation.
