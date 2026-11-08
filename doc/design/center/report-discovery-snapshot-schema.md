# warp-insight ReportDiscoverySnapshot Schema

> 状态：**Current** —— 与 `wist-contracts::ingest::DiscoveryReport` 对齐；数据面帧为 `DSNAP:`。
> 当前实现与 telemetry **共用数据面 TCP**，用 `DSNAP:` 帧标记区分，落 `agent-dsnap` sink；
> 不另开 discovery 端口/receiver。
> 历史草案中的 OTel `attributes[]` / `runtime_facts` 已废弃（见 §13 注）。

## 1. 文档目的

本文档定义边缘 `warp-insightd` 向中心同步 discovery 本地快照时，通过 `warp-parse` discovery ingress receiver 投递的消息 envelope。

重点回答：

- `state/discovery/*.json` 是否应直接作为上送协议
- discovery 资源事实是否应复用 telemetry 数据面上送路径
- discovery 本地快照如何包装成控制面同步对象
- 中心如何做幂等接收、落库与后续资源目录归并

相关文档：

- [`../edge/resource-discovery-runtime.md`](../edge/resource-discovery-runtime.md)
- [`../edge/discovery-runtime-current-state.md`](../edge/discovery-runtime-current-state.md)
- [`discovery-sync-protocol.md`](discovery-sync-protocol.md)
- [`../telemetry/telemetry-uplink-and-warp-parse.md`](../telemetry/telemetry-uplink-and-warp-parse.md)
- [`control-center-storage-schema.md`](control-center-storage-schema.md)
- [`../foundation/glossary.md`](../foundation/glossary.md)

---

## 2. 核心结论

当前阶段固定以下结论：

- `DiscoverySnapshot` 是边缘本地事实快照，不是中心传输对象
- `state/discovery/resources.json` / `targets.json` / `meta.json` 是本地状态文件，不是对外协议
- discovery 资源事实同步应走 `warp-parse` 的 discovery ingress 协议
- discovery sync 不应默认复用 telemetry 数据面 uplink payload
- 但必须定义独立的 discovery envelope，而不是复用 `TelemetryRecord` 或 `ReportActionResult`
- 中心接收到的是边缘快照事实；中心资源目录仍需单独做归并、去重和生命周期管理

一句话说：

- discovery 要上送中心
- 但它上送的是 `ReportDiscoverySnapshot`
- 不是直接发送 `state/discovery/*.json`
- 也不是把资源事实伪装成 telemetry record

---

## 3. 角色边界

### 3.1 `DiscoverySnapshot`

`DiscoverySnapshot` 的统一定义见 [`../foundation/glossary.md`](../foundation/glossary.md)。

这里再次强调：

- 它是边缘 discovery 运行时产出的完整本地快照
- 它表达“本机当前发现到了哪些 resource / target”
- 它适用于边缘 cache、planner bridge 和本地只读查询

它不等于：

- 中心侧资源目录记录
- telemetry record
- capability report
- discovery sync transport envelope

### 3.2 `ReportDiscoverySnapshot`

本文定义的新对象：

- `ReportDiscoverySnapshot` 是控制面传输对象
- 用于把一轮边缘 `DiscoverySnapshot` 回报给中心

两者关系应固定为：

- `DiscoverySnapshot` 描述边缘本地事实
- `ReportDiscoverySnapshot` 描述边缘如何把该事实同步给中心

### 3.3 中心资源目录

中心侧最终资源目录仍是独立对象层：

- 它消费多个 agent 上送的 discovery 快照
- 它负责跨节点归并、去重、生命周期管理和关系补全

因此必须避免把：

- 边缘本地快照
- discovery 上送 envelope
- 中心资源目录记录

这三层混成一个对象。

---

## 4. 为什么不能复用 telemetry uplink

discovery sync 与 telemetry uplink 的对象语义不同。

### 4.1 telemetry uplink 解决的问题

telemetry uplink 解决的是：

- 日志
- 指标样本
- traces / security event
- 统一数据接入和下游路由

它传输的是：

- data-plane signal
- event / record / sample

### 4.2 discovery sync 解决的问题

discovery sync 解决的是：

- 边缘资源事实同步
- 控制面 target 选择参考
- 中心资源目录归并输入

它传输的是：

- control-plane resource fact snapshot

### 4.3 设计约束

因此第一版应固定：

- discovery sync 可以进入 `warp-parse`
- discovery sync 不复用 `TelemetryRecord`
- discovery sync 不把 `DiscoveredResource` / `DiscoveredTarget` 降级成一行文本 record

更准确地说：

- discovery sync 走 `warp-parse` 的专用 discovery receiver
- 但不走现有 telemetry record 接入语义

允许复用的包括：

- `warp-parse` ingress runtime
- 独立 discovery 端口
- 协议头校验
- 持久化接收
- ack 驱动的本地清理机制

---

## 5. 顶层结构

建议边缘向 `warp-parse` discovery receiver 上送以下对象：

```text
ReportDiscoverySnapshot {
  api_version
  kind
  report_id
  agent_id
  instance_id
  snapshot_id
  revision
  generated_at
  report_attempt
  report_mode
  reported_at
  snapshot
}
```

### 5.1 固定值

- `api_version = "v1"`
- `kind = "report_discovery_snapshot"`

### 5.2 必选字段

- `api_version`
- `kind`
- `report_id`
- `agent_id`
- `instance_id`
- `snapshot_id`
- `revision`
- `generated_at`
- `report_attempt`
- `report_mode`
- `reported_at`
- `snapshot`

---

## 6. 字段说明

### 6.1 `report_id`

建议类型：

- `string`

用途：

- 标识一次 discovery 快照回报尝试

注意：

- 它是传输尝试对象 id
- 不应拿它替代 `snapshot_id`

### 6.2 `agent_id`

建议类型：

- `string`

用途：

- 标识逻辑 agent 身份

### 6.3 `instance_id`

建议类型：

- `string`

用途：

- 标识本次 daemon 实例

说明：

- 中心可以借此区分同一 `agent_id` 的不同实例生命周期
- 但 discovery 快照幂等主语义仍应优先落在 `agent_id + snapshot_id` 或 `agent_id + revision`

### 6.4 `snapshot_id`

建议类型：

- `string`

说明：

- 直接引用边缘本轮 `DiscoverySnapshot.snapshot_id`
- 用于唯一标识某一轮边缘 discovery 快照

### 6.5 `revision`

建议类型：

- `uint64`

说明：

- 直接引用边缘本轮 `DiscoverySnapshot.revision`
- 用于表达同一 agent 本地 discovery 快照的推进顺序

### 6.6 `generated_at`

建议类型：

- RFC3339 UTC 时间

说明：

- 直接引用边缘本轮 `DiscoverySnapshot.generated_at`
- 表示边缘快照形成时间，不是消息发送时间

### 6.7 `report_attempt`

建议类型：

- `uint32`

说明：

- 表示边缘针对同一 `snapshot_id` 第几次回报
- 从 `1` 开始

### 6.8 `report_mode`

建议类型：

- `string`

第一版建议枚举：

- `full_snapshot`
- `snapshot_replace`

第一版建议固定：

- 先只实现 `full_snapshot`

含义说明：

- `full_snapshot`
  本次 payload 携带完整 `DiscoverySnapshot`
- `snapshot_replace`
  语义上表示用该完整快照替代中心对该 agent 最近一次已确认快照

说明：

- 第一版不建议设计部分 patch / delta 协议
- 先把“完整快照幂等替换”跑通

### 6.9 `reported_at`

建议类型：

- RFC3339 UTC 时间

说明：

- 表示本次 `ReportDiscoverySnapshot` 创建时间
- 它是传输时间，不等于 `generated_at`

### 6.10 `snapshot`

```text
snapshot: DiscoverySnapshot
```

说明：

- 直接复用 discovery 契约对象
- payload 内包含：
  - `resources[]`
  - `targets[]`
  - `executables[]`（软件指纹，按部署位；见 §7.4。旧 agentd 不带此字段）
- `meta.json` 中的额外本地缓存字段不要求原样进入线上协议

---

## 7. payload 约束

### 7.1 允许携带的内容

第一版建议只上传：

- `DiscoverySnapshot` 中的 `resources[]`
- `DiscoverySnapshot` 中的 `targets[]`
- `DiscoverySnapshot` 中的 `executables[]`（仅声明了 `fingerprint:sha256` 的 agentd）
- 与该快照强绑定的版本与时间字段

### 7.2 不建议直接上传的内容

第一版不建议把以下本地状态文件语义直接外露为协议字段：

- `meta.last_success_at`
- `meta.last_error`
- probe 局部故障细节
- 本地临时 cache 恢复原因

原因：

- 这些字段主要用于边缘运行时恢复与排障
- 不属于中心资源事实目录的核心主语义
- 若中心需要 agent 健康与故障信息，应走独立的 health / self-observability 通道

### 7.3 target 上送约束

第一版允许同步 `targets[]`，因为它们可服务：

- 控制面只读查询
- target 选择辅助
- 中心理解边缘“哪些对象可作为候选采集对象”

但必须明确：

- `DiscoveredTarget` 仍是 discovery 事实对象
- 它不是最终 `CandidateCollectionTarget`
- 中心不应把它直接等同于已下发采集配置

### 7.4 软件指纹块（按部署位）

> 2026-11-08 定。语义与模型见
> [`center/models/software-fingerprint-verification.md`](models/software-fingerprint-verification.md) §6 / §10。

**一条记录 = 一个部署位，不是一份文件。** 原因是「一个实例只认一个主二进制」这条规则
（同文档 §6.2）需要 `anchor` 才能执行；放到中心做等于把判断拆到两个仓，而且中心拿不到
unit / cgroup 这些环境知识（`software-identity.md` §4）。

```text
ExecutableEvidence {            // snapshot.executables[]
  anchor_kind       // systemd_unit | container | socket | argv0 | install_root | process
  anchor_value
  identity          // ExecutableIdentity?；为空 ⇔ identity_missing
  identity_missing_reason?   // identity 为空时必填
  claimed           // ClaimedPackage?；取不到可空
  sub_artifacts[]   // SubArtifact{ artifact_id, role }；不带 path
}

ExecutableIdentity {
  artifact_id       // 'sha256:<hex>'，即唯一权威 ID
  size_bytes
  build_id?         // ELF .note.gnu.build-id
  path?             // 仅 claimed_mismatch 时填，见 7.4.4
}

ClaimedPackage {
  source            // path_package | probe | image_tag
  package_name      // 'postgresql-16'（包名，不是产品名）
  version           // 原样保留
  product_hint?     // 归一前的提示，可为空
}
```

#### 7.4.1 唯一性

`(anchor_kind, anchor_value)` 在同一快照内唯一。同一部署位只出现一次；出现两次视为
边缘 bug，中心取最后一条并记 warn（不整帧拒收——拒收会丢掉同帧所有其他事实）。

#### 7.4.2 主二进制规则在边缘执行

按 §6.2 的五条判据（JVM 优先 → 对外监听 → `ExecStart` argv[0] → 包元数据 main binary → 兜底）
选出主二进制算 `identity`，其余进 `sub_artifacts[]`。

`sub_artifacts[]` **只带 `artifact_id` 与 `role`**，不带 path / inode / mtime——
否则 §6.6 的「体积与抖动」理由就白写了（容器内路径每轮会变，进摘要只会把去重打散）。

#### 7.4.3 `identity` 允许为空，但不许伪造

`identity` 为空时必须带 `identity_missing_reason`，枚举与判定口径**只以模型文档 §6.4 为准**（本文不复制一份，避免两边漂）。
**绝不能用 `claimed` 拼一个 `artifact_id`**——那会把「可信度」偷换成猜测（§7 的结论分级会直接失效）。

#### 7.4.4 `path` 的规则

| 情况 | 带不带 path |
| --- | --- |
| `status` 将由中心判成 `claimed_mismatch` | **必须带**（否则中心无法复查「到底哪个文件不对」，§5 矩阵右上角那格的价值折一半） |
| 其余 | **不带**；要时另行按需拉取 |
| 根本拿不到 hash（`identity_missing`） | 带上——此时 path 是唯一可调查的线索，且这种条目本来就少 |

判定放在边缘：agentd 自己先比一次 `claimed.version` 与已知产物 hash，
不一致就带 path（它比中心更清楚包反查结果）。

#### 7.4.5 上限

| 项 | 上限 | 超了怎么办 |
| --- | --- | --- |
| 条目数 | 200 / 快照 | 按 §3 候选集优先级截断，被截数量写进 `report.limits` |
| 单个文件参与 hash | 64 MB | 跳过，记 `oversize` 原因 |
| 整块序列化后 | 512 KB | 截断 `sub_artifacts`；仍超则只带 `identity` |

实测参考：一台开发机 713 个可执行里只有 29 个（4%）够格，正常块在几 KB 量级。

#### 7.4.6 兼容：`deny_unknown_fields` 决定了升级顺序

`DiscoverySnapshot` 及内层 7 个 struct 都带 `#[serde(deny_unknown_fields)]`（`wist-contracts/src/discovery.rs`）——
**旧端收到新字段会整帧拒收**，不是忽略。所以不能靠「未知字段自然忽略」：

| 方向 | 结果 | 处理 |
| --- | --- | --- |
| 旧 agentd → 新中心 | ✅ 字段缺省即空 | 新端 `#[serde(default)]`，语义是「未上报」而非「没有软件」 |
| 新 agentd → 旧网关/中心 | ❌ **整帧拒收** | **必须门控**：不支持就不发这个字段 |
| 新 agentd → 旧中心，走了老 `api_version` | ❌ 同上 | 同上 |

**因此发布纪律是：网关 → 中心 → agentd，不可逆序。** 门控靠既有的能力协商：

- agentd 在 `CapabilityReport` 里声明 `fingerprint:sha256` 与 `pkg_query:dpkg|rpm|apk`；
- 中心/网关回执（或配置下发）告诉 agentd 本区是否启用该块；
- agentd 侧另有本地开关，默认关，开启需两者同时满足。

> 不引入「宽松解析」来绕开这个限制。`deny_unknown_fields` 是契约测试能起作用的前提，
> 为了一次升级把它拆掉，以后每个字段都会变成静默兼容问题。

#### 7.4.7 与 `revision` 的关系

**只有指纹变了也要推进 `revision`。** 否则中心看到的 `snapshot` 视图停在旧字节上，
而 §8 的变化检测与归因全部以此为基线——升级（hash 变、进程表不变）将完全不可见。

#### 7.4.8 示例

三个典型条目（省略未变字段）：

```json
{
  "executables": [
    {
      "anchor_kind": "systemd_unit", "anchor_value": "nginx.service",
      "identity": { "artifact_id": "sha256:0145bbac…", "size_bytes": 1572864, "build_id": "9f2c…" },
      "claimed": { "source": "path_package", "package_name": "nginx", "version": "1.27.5-r1" }
    },
    {
      "anchor_kind": "systemd_unit", "anchor_value": "postgresql@16-main.service",
      "identity": { "artifact_id": "sha256:d3f1c9e2…", "size_bytes": 7340032 },
      "claimed": { "source": "path_package", "package_name": "postgresql-16", "version": "16.15-1.pgdg13+2" },
      "sub_artifacts": [
        { "artifact_id": "sha256:7b21…", "role": "sub_artifact" },
        { "artifact_id": "sha256:4c8e…", "role": "sub_artifact" }
      ]
    },
    {
      "anchor_kind": "argv0", "anchor_value": "/opt/kafka/bin/kafka-server-start.sh",
      "identity": { "artifact_id": "sha256:5a0d…", "size_bytes": 12800000 },
      "claimed": { "source": "image_tag", "package_name": "apache/kafka", "version": "3.7.0" }
    }
  ]
}
```

注意第三条的 `anchor_value` 是启动脚本，但 `identity` 是 **`libs/kafka_2.13-3.7.0.jar` 的 hash**——
这正是 §6.2「JVM 必须排第一」与「主文件要选带版本语义的那个」两条规则的结果；
两边（边缘选主文件 / 库里 `main_file`）不对齐，命中率会静默归零。

---

## 8. ack 与幂等

discovery sync 需要显式 ack。

建议中心返回：

```text
DiscoveryIngestAck {
  api_version
  kind
  report_id
  agent_id
  instance_id
  snapshot_id
  revision
  ack_status
  accepted_at
  reason_code?
  reason_message?
}
```

### 8.1 固定值

- `kind = "discovery_ingest_ack"`

### 8.2 `ack_status`

第一版建议枚举：

- `accepted`
- `duplicate`
- `stale`
- `rejected`

含义说明：

- `accepted`
  `warp-parse` 已可靠接收并完成当前快照落地
- `duplicate`
  相同 `snapshot_id` 或等价快照已处理
- `stale`
  收到的 `revision` 明显落后于中心已确认 revision
- `rejected`
  envelope 非法、schema 不匹配或身份不合法

### 8.3 幂等键建议

第一版建议 discovery ingress 至少支持以下幂等约束：

- `discovery_reports(report_id)` 唯一
- `agent_discovery_snapshots(agent_id, snapshot_id)` 唯一

同时建议中心维护：

- 每个 `agent_id` 当前最新已确认 `revision`

### 8.4 边缘重试原则

边缘应按如下原则处理：

1. 为同一 `snapshot_id` 保留本地待确认 reporting 状态
2. 未收到 `accepted` / `duplicate` 前允许重试
3. 收到 `duplicate` 后视为可安全清理本地待确认项
4. 收到 `stale` 时停止重试该快照，并记录控制面可见原因

---

## 9. 发送时机

第一版建议仅在以下场景发送：

### 9.1 首次成功形成快照后

- daemon 启动后首轮成功 discovery refresh

### 9.2 revision 前进后

- 仅当形成新的 `DiscoverySnapshot.revision` 时上送

### 9.3 会话恢复后补发未确认快照

- 若之前已形成本地 reporting 状态但未收到 ack
- 会话恢复后允许按原 `snapshot_id` 重试发送

### 9.4 不建议的发送时机

第一版不建议：

- 每次 tick 无条件重发最近快照
- 把 discovery sync 做成高频心跳负载
- 为单个 resource 变化设计即时碎片化单条上报

---

## 10. 中心落库分层

中心接收 `ReportDiscoverySnapshot` 后，建议拆成两层：

### 10.1 discovery ingress receipt

用途：

- 保存原始 ingress envelope 的接收事实
- 支撑幂等、审计、排障和重试判定

建议字段：

- `report_id`
- `agent_id`
- `instance_id`
- `snapshot_id`
- `revision`
- `reported_at`
- `received_at`
- `ack_status`
- `report_blob_ref`

### 10.2 agent scoped discovery snapshot

用途：

- 保存某个 agent 最近一次已确认的 discovery 快照索引

建议字段：

- `agent_id`
- `instance_id`
- `snapshot_id`
- `revision`
- `generated_at`
- `snapshot_blob_ref`
- `is_current`

### 10.3 center resource catalog

用途：

- 基于多个 agent 的 discovery snapshot 做归并后的中心资源目录

注意：

- 该层不是 `ReportDiscoverySnapshot` 的直接镜像表
- 需要独立的归并任务和生命周期规则

### 10.4 指纹块落到哪

`executables[]` **不新增接收层**，它跟着同一个 blob 进，只在最后一层被拆表：

```text
ReportDiscoverySnapshot
  → 10.1 ingress receipt        （整帧原样，含 executables[]）
  → 10.2 agent snapshot 索引      （不动）
  → 10.3 资源目录归并
        ├─ resources / targets → 现有资源表
        └─ executables[]       → software_fingerprint / software_instance
                                 （见 software-fingerprint-verification.md §10.1）
```

两条约束：

1. **归并失败不能回退整帧**。单条 `executables[]` 写不进去（未知 anchor_kind、hash 格式错）
   就丢那一条并记 warn，其余照常落库——与 §7.4.1 同一条纪律。
2. **`product_hint` 只作提示**。命中 KB 的唯一依据是 `artifact_id` 与 `claimed.package_name`，
   `product_hint` 不能直接写进 `claimed_product_id`（否则等于把边缘猜测当归一结果）。

---

## 11. 与其它控制面对象的关系

### 11.1 与 telemetry uplink

- telemetry uplink 面向 logs / metrics / traces / security
- `ReportDiscoverySnapshot` 面向 resource fact snapshot

两者都可进入 `warp-parse`，但必须走不同 receiver 语义。

### 11.2 与 `CapabilityReport`

- `CapabilityReport`
  表达“本机能做什么”
- `ReportDiscoverySnapshot`
  表达“本机当前发现到了什么”

二者语义独立，不应混为一个对象。

但**前者是后者的门控前提**：`DiscoverySnapshot` 开了 `deny_unknown_fields`，
新字段只能在对方明确支持之后才发（§7.4.6）。软件指纹依赖两个能力位：

| 能力位 | 含义 | 缺失时的行为 |
| --- | --- | --- |
| `fingerprint:sha256` | 能对候选二进制算 sha256 | 不发 `executables[]` |
| `pkg_query:dpkg\|rpm\|apk` | 能做包反查 | `claimed` 恒为空，但 hash 仍上报 |

第二个是独立的一档：**算得出 hash、反查不了**是常态（tarball / 容器 / 自编译），
此时仍有权威 ID，只是没有可交叉验证的声称值（结论落到 `observed`）。

### 11.3 与 `ReportActionResult`

- `ReportActionResult` 回报的是一次动作执行结果
- `ReportDiscoverySnapshot` 回报的是一轮 discovery 事实快照

两者都可复用 reporting / ack / retry 思路，但不应复用同一 payload。

---

## 12. 第一版实现建议

建议按以下顺序落地：

### 12.1 Step 1

先固定合同与网关消息：

- `report_discovery_snapshot`
- `discovery_ingest_ack`

### 12.2 Step 2

再补本地 reporting 状态：

- 待发送快照索引
- `report_attempt`
- ack 后清理

### 12.3 Step 3

再补中心接收与幂等：

- ingress receipt 落库
- snapshot 当前视图更新
- stale / duplicate 判定

### 12.4 Step 4

最后补中心资源目录归并：

- resource 去重
- 生命周期推进
- 跨 agent 关联

---

## 13. 最小示例

> 数据面传输：`{schema,agent,ts,seq} DSNAP: <本对象 JSON>\0`。
> 下面是 `wist-contracts::ingest::DiscoveryReport` 的**实际形状**（扁平 `attributes`、单 `resource_ref`、无 `runtime_facts`）。

```json
{
  "api_version": "v1",
  "kind": "report_discovery_snapshot",
  "report_id": "disrep_01",
  "agent_id": "agent_prod_web_01",
  "instance_id": "inst_01",
  "snapshot_id": "discovery:42:2026-04-19T08:00:00Z",
  "revision": 42,
  "generated_at": "2026-04-19T08:00:00Z",
  "report_attempt": 1,
  "report_mode": "full_snapshot",
  "reported_at": "2026-04-19T08:00:02Z",
  "snapshot": {
    "schema_version": "v1",
    "snapshot_id": "discovery:42:2026-04-19T08:00:00Z",
    "revision": 42,
    "generated_at": "2026-04-19T08:00:00Z",
    "origins": [
      {
        "origin_id": "local_runtime:host:2026-04-19T08:00:00Z",
        "probe": "host",
        "source": "local_runtime",
        "observed_at": "2026-04-19T08:00:00Z"
      }
    ],
    "resources": [
      {
        "resource_id": "hostname:host-01",
        "kind": "host",
        "origin_idx": 0,
        "attributes": {
          "host.id": "hostname:host-01",
          "host.name": "host-01"
        },
        "discovered_at": "2026-04-19T08:00:00Z",
        "last_seen_at": "2026-04-19T08:00:00Z",
        "health": "healthy",
        "source": "host"
      }
    ],
    "targets": [
      {
        "target_id": "hostname:host-01:host",
        "kind": "host",
        "origin_idx": 0,
        "resource_ref": "hostname:host-01",
        "execution_hints": {
          "host.name": "host-01"
        },
        "state": "active"
      }
    ]
  }
}
```

---

## 14. 当前决定

当前阶段固定以下结论：

- discovery 上送中心是必要能力
- discovery 上送应定义为独立 ingress 协议对象
- 本地 `state/discovery/*.json` 不直接等于线上协议
- 第一版采用完整快照上送 + ack 幂等替换模型
- 中心按 ingress receipt、agent 当前快照、资源目录归并三层分离处理

### 补充（2026-09-22：消费方与模型状态）

- **消费方有两个**：中心（资产整理：资源目录归并、软件归一化与漏洞关联）与 **网关**
  （用途推断与平台校验，取的是**派生摘要**而不是全量明细）。因此本文的“上送中心”
  应读作“上送数据面后由各方订阅”：**不需要网关替 agent 向中心代报**。
- 模型侧已把 envelope 与载荷填实：`Reporting.ReportDiscoverySnapshot`、
  `Reporting.DiscoveryIngestAck`（含 `snapshot_id`/`revision`/`report_attempt`/`report_mode`）
  与 `Observed.Snapshot` 全模块。
- 待补：
  1. discovery receiver 的**身份校验**（事实是资产清单，现状接入层无鉴权）；
  2. 本文 §13 的示例已按 `wist-contracts` 实际契约修正：`attributes` 是**扁平 map**，
     `targets[]` 是 `resource_ref` + `execution_hints`，**没有** `runtime_facts` / `resource_refs[]`。
  3. `DSNAP:` 帧标记与 `agent-dsnap` sink 已落地；消费端（wist-atlas）的导入链路见
     [`asset-discovery-data-flow.md`](./asset-discovery-data-flow.md)。
