# Unified Repository Migration

Zettide storage is maintained in this repository. The former storage-owned
repositories were merged with full ancestry instead of being copied or retained
as submodules.

| Former repository | New path | Imported tip |
| --- | --- | --- |
| `zettide-control` | `services/controller/` | `c6c84e2c65c6d0363b0d64488fc85fd02cdee10c` |
| `zettide-cawfs` | `libs/txfs/` | `2b04f111bbaa70de5f060dab97536c79d2b5b480` |
| `zettide-node-protocol` | `libs/data-service-contracts/` | `74f55a5e63b55874e230e04f154a086fb71f6fa6` |

The ancestry joins are merge commits `2d6aebd`, `1297878`, and `9544865`.
Consequently, `git log --all`, `git blame`, and ancestry queries retain the
original histories.

The canonical current control-plane name is `controller`: source paths use
`services/controller/`, the Zig module is `zettide_controller`, and installed
artifacts use `zettide-controller`. The name `zettide-control` is retained only
when referring to the former repository or its historical commits.

The former in-repository `services/zettide/` source tree has also been split by
responsibility: reusable engine code is now `libs/storage-engine/` and product,
platform, endpoint, CLI, NFS, and SPDK adapters are under `services/node/`.
This was an internal `git mv` refactor, not another repository ancestry join.
The public engine module is `zettide_storage`; the existing `zettide` executable
and NFS C ABI remain compatibility surfaces.

External dependencies are pinned under `vendor/`:

- `vendor/grpc-lite`
- `vendor/raftz`
- `vendor/spdk`

When publishing this migration, push the new `vendor/raftz` commit referenced by
the superproject before pushing the Zettide branch. Then archive the former
storage-owned repositories and point their descriptions and README files to this
repository. Removing the old `zettide-mono` integration workspace is the final
operator step after the new repository has been cloned and validated independently.
