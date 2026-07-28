# zettide-control

Replicated metadata control plane for Zettide.

The initial service manages virtual Pools. A Pool is a global namespace for
Volumes; Volumes, Extents, replica placement, and DataService reconciliation
are separate metadata layers and are not part of the first milestone.

Pool mutations are committed and applied through Raft before an RPC reports
success. Reads use Raft ReadIndex rather than serving follower-local state.

## Development

```sh
zig build test --summary all
```
