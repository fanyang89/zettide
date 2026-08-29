# 安全边界

> 状态：可信隔离部署约束；生产级认证授权尚未完成

## 初始模型

- Management、NVMf、iSCSI、NFS、Raft 与内部 Replica ports 不暴露到公网或不可信租户网络。
- 只允许受管 virtualization host、NFS client、control voter 和 storage node 访问对应平面。
- 主机 root、内核、SPDK/NFS-Ganesha/FUSE 进程与本地介质属于可信计算基。
- 网络可达、Host NQN、IQN、UID/GID、Node ID 或 service account name 不自动授予权限。
- 节点加入经过受控 bootstrap；网络可达本身不能注册 Node 或加入 Raft。

该模型不能抵御已取得 host root、任意注入隔离网络流量、恶意控制面多数派、DMA 或恶意固件的攻击者。
这是当前可信网络限制，不是零信任或生产多租户安全声明。

## 身份域

以下身份和凭据分离：

- 管理员与 management client；
- qtr/PVE adapter 与 virtualization host；
- CSI Controller service account 与 CSI Node identity；
- 标准 host-facing NVMf initiator；
- iSCSI initiator；
- NFS client/principal；
- local FUSE mount owner；
- Tier 3 control voter、Data Node 与 internal Replica initiator。

稳定 resource ID 不依赖地址、hostname、mount path 或 device path。
节点重装后不能仅凭旧 hostname、IP 或声明的 Node ID 复用旧身份；必须持有对应持久身份材料并经过运维重新授权。

## 标准 NVMf Publication

当前 export 支持显式 Host NQN 或 `allow_any_host`。后者只适合受控测试；Host NQN 是 initiator 提供的字符串，不构成强认证。

目标安全策略：

- 每 publication/host 最小权限 allowlist；
- TCP/RDMA network segmentation；
- DH-HMAC-CHAP 或经过验证的等价 host authentication；
- credential revision 与 publication access generation 绑定；
- detach/republish 时先撤销旧 host，再授权新 host；
- standard publication credential 与 internal Replica credential 分离。

## iSCSI Publication

iSCSI 继续需要 portal ACL、initiator IQN restriction、CHAP 或等价认证、每 host credential、轮换与撤销顺序。CHAP secret 不进入 VM config、普通日志或 Raft plaintext state；由 host credential store 与 target secret store 管理。

iSCSI session 恢复与 CHAP/ACL revision 是协议特有安全状态，不能用 NVMf Host NQN 规则替代。

## NFS Export

- Export 绑定 BlobFilesystem identity、client network/principal scope 与 read/write mode。
- 当前 NFSv3 `AUTH_SYS` 信任 client 提供的 UID/GID，只适用于可信隔离 client；它不是强身份认证。
- Root squash、anonymous mapping、export ACL、firewall 和只读策略需要显式配置。
- NFS-Ganesha module/config 文件、Unix ownership 与 service account 必须受限。
- 进入更强安全边界前需评估 NFSv4/Kerberos 或等价方案；当前未实现。

## FUSE Local Permission

- Mount service 使用专用 Unix account/group 与最小设备权限。
- `allow_other` 默认不得无条件开启；启用时必须配套 mount policy、directory mode 与 SELinux。
- 持久 UID/GID 与 name profile 参与 BlobFilesystem 语义，但不替代 host authentication。
- Endpoint control socket 当前 owner-only；runtime directory 不允许非 owner 注入 request 或替换 state。

## Virtualization Adapter

qtr/PVE adapter 只能请求已授权 Pool/Volume 与 access mode。它持久化 stable identity，不记录可重放 secret，不把 provider error 原样泄露 secret。Adapter 必须验证返回 device identity，防止把错误 namespace/LUN attach 到 VM。

同机部署不取消权限边界：qtr/PVE service 不应自动获得所有 raw disk 或 endpoint state 的写权限。Zettide 独占 physical devices，adapter 只访问 lifecycle API 与已发布 frontend。

## CSI

当前静态 FUSE CSI Node service 约束 source/publish path 必须位于配置 root 下，以独占 lock 保护持久
state directory，并在 mount 前用 `zettide://filesystem/<uuid>` 校验 regular Blob file identity。它仍信任
本机 kubelet/容器部署边界，不构成 Controller authorization 或多租户安全模型。

完整目标要求：

- CSI Controller service account 只执行其 StorageClass/tenant scope 内的 Volume/publication mutation。
- CSI Node identity 绑定稳定 Kubernetes Node 与受管 host identity，不能只信任 RPC 中的 node name。
- Node plugin 只接收其 Node 已获授权的 NVMf/iSCSI credential 或 NFS export 信息。
- Secret 不写入 `volume_id`、`volume_context` 日志、PV annotation 或 pod-visible path。
- Controller/Node RBAC 与 Zettide authorization 双重约束；Kubernetes RBAC 不自动替代 storage-side ACL。

## Tier 3 Internal Replica

Internal Replica NVMf 使用独立 NQN/credential/port 与 vendor command authorization。Lease、Volume epoch 与 `max_accepted_epoch` 解决 crash/partition fencing，不等于抵御恶意 Node。若要进入不可信网络，session 必须绑定不可伪造、可轮换的 primary/epoch authorization。

## 数据写安全

网络隔离不能解决 stale primary。Tier 3 目标数据面必须同时使用：

- 有期限且绑定 Volume、holder 和 epoch 的 lease；
- 单调 Volume write epoch；
- Replica 持久化并执行 `max_accepted_epoch`；
- 与当前 epoch/Replica generation 匹配的 internal session；
- 满足 protection policy 的 durable commit evidence，默认 profile 为 2/3。

撤销路由、关闭 listener、断开 controller/qpair 或让旧 Node 不可达都只是辅助措施，不能替代 Replica 在持久写入边界执行 epoch fencing。Lease/epoch/commit evidence 是 crash 与 partition 安全机制，不等于恶意节点认证。

## grpc-lite 与 Control RPC

grpc-lite 支持明文 HTTP/2，以及通过可选 mbedTLS 提供的 TLS 1.2+。TLS 模式要求服务端 PEM certificate chain、未加密 PEM private key、客户端显式 PEM CA、按 Channel target 执行 hostname verification/SNI，并强制 ALPN `h2`；客户端不搜索系统 CA。

grpc-lite 当前不支持 mTLS、客户端证书或服务端 client verification，也不提供内建 identity/RBAC。Channel 可以重连，但不会重放 RPC；没有内建 RPC retry policy、service config 或 load balancing，应用必须用稳定 request ID 处理未知结果并显式重试。xDS、ALTS 和 cloud credentials 也不在当前边界内。

因此 TLS 只能提供链路加密和服务端认证，不能证明调用方是合法 Node。`cluster_id`、`node_id` 和 metadata 是协议/配置校验字段，不是 credential。当前 `raftz` grpc-lite transport 仍是明文可信网络 transport，必须保留网络隔离约束。

## 数据完整性与秘密

A/B headers、CRC/digest、control history 和 WAL checksum 用于发现损坏，不提供机密性或身份认证。当前不承诺静态数据加密。

私钥、CHAP secret、NVMf secret、CSI secret、可重放 lease token 与原始数据不得进入仓库、VM/PV 配置、Raft plaintext state 或普通日志。Control、standard publication、internal Replica、NFS、adapter 和 CSI credential 使用独立用途与最小权限的 secret store；轮换和撤销不能要求把 secret 复制到 consumer identity 或 locator 中。

安全日志可以记录 resource ID、revision、generation、epoch、状态转换、认证主体引用和错误码，但不得记录私钥、token、完整 credential、原始块数据或会使 credential 可重放的 provider error。credential 加载或验证失败必须 fail closed，不静默回退明文、`allow_any_host` 或匿名写访问。

## 放宽前提

在 management/DataService 双向认证、细粒度授权、NVMf/iSCSI/NFS credential lifecycle、CSI identity binding、certificate/secret rotation、网络分区测试与独立安全审查完成前，不得宣称适用于不可信网络或生产多租户环境。
