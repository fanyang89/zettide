# Architecture Decisions

This directory records repository-wide architecture decisions that constrain
component ownership, process boundaries, compatibility, and migrations.

| Decision | Status | Summary |
| --- | --- | --- |
| [0001](0001-data-node-naming-and-process-model.md) | Partially superseded | Storage-library/data-node separation remains; ADR 0005 replaces filesystem and cluster composition requirements |
| [0002](0002-keep-storage-engine-cohesive.md) | Accepted, narrowed by 0005 | Keep one cohesive `zettide_storage` package; historical filesystem clauses no longer apply |
| [0003](0003-storage-product-architecture.md) | Superseded | Historical dual-model, multi-frontend, distributed product architecture |
| [0004](0004-single-active-filesystem-service.md) | Superseded | Historical managed filesystem architecture |
| [0005](0005-single-node-vm-block-storage.md) | Accepted | Single-node VM block storage with the in-house engine and local multi-disk protection |
