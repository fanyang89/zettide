# Architecture Decisions

This directory records repository-wide architecture decisions that constrain
component ownership, process boundaries, compatibility, and migrations.

| Decision | Status | Summary |
| --- | --- | --- |
| [0001](0001-data-node-naming-and-process-model.md) | Accepted | Defines the implemented storage-library/data-node naming split and the remaining daemon composition boundary |
| [0002](0002-keep-storage-engine-cohesive.md) | Accepted | Keep one cohesive `zettide_storage` package after the first extraction; require stronger DAG and consumer evidence before further package splits |
| [0003](0003-storage-product-architecture.md) | Accepted | Freezes the storage data models, Tier boundaries, frontend roles, component ownership, and external-consumer boundary |
