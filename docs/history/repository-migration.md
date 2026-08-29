# Unified Repository Migration

Status: historical record; the repository and source-layout migrations described here are complete.

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

The original publication required the referenced `vendor/raftz` commit to be
available before the superproject and the former storage-owned repositories to
be archived afterward. These are provenance notes, not current bootstrap or
release steps. Current dependency setup is defined by the root `README.md` and
`mise run bootstrap`.
