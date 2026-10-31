# 磁盘容量采集方案（按挂载点 / 文件系统）

> **状态**：Phase 1–3 已落地（2026-10-19）；Phase 4（inode / APFS quota）待做。
> **当前实现**：逐挂载点 `system.filesystem.*` 已从 agentd 采集打通到数据面、网关 API 与
> Web 主机指标页；旧的 `system.disk.*` 聚合保留兼容，不再作为告警依据。
>
> **关联**：
> - [`resource-discovery-runtime.md`](./resource-discovery-runtime.md)（metrics runtime 目标态）
> - [`discovery-runtime-current-state.md`](./discovery-runtime-current-state.md)（当前覆盖范围）
> - [`gateway-status-report.md`](./gateway-status-report.md)（网关自身状态上报，另一条通道）
> - [`../center/collection-families.md`](../center/collection-families.md)（`HostMetrics` 采集面）
>
> **代码入口**：
> - `wist-agentd/src/telemetry/metrics/runtime.rs`
> - `wist-agentd/src/telemetry/metrics/samples.rs`
> - `wist-metrics/src/spec.rs`
> - `wist-gateway/src/api/host_metrics.rs`
> - 数据面 `data-plane/models/wpl/agent_uplink/parse.wpl`、
>   `data-plane/models/oml/agent_uplink/agent_uplink_metrics_frame/adm.oml`

## 1. 需求与结论

### 1.1 真实诉求

要能回答：

> **某个路径/挂载点空间不足了，但整机整体空间仍然充足。**

典型场景：

| 挂载点 | 总量 | 可用 | 使用率 |
|---|---:|---:|---:|
| `/` | 100 GiB | 40 GiB | 60% |
| `/var` | 20 GiB | 1 GiB | **95%** |
| `/data` | 1 TiB | 800 GiB | 21.9% |

整体约 1144 GiB、可用约 841 GiB，使用率约 26.5%，看起来非常健康；
但 `/var` 已经 95%，随时可能写失败。

### 1.2 结论

- **容量事实属于文件系统/挂载点，不属于整机，也不等于物理磁盘。**
- 必须**逐挂载点采集、逐挂载点告警**；采集侧不做汇总。
- 路径不是容量身份：一个路径属于某个挂载点；只有路径本身是挂载点时，它才有独立容量。
- 旧指标 `system.disk.*` 可以保留作总览/兼容，但**不能作为告警依据**。

### 1.3 非目标

- 不做物理磁盘拓扑识别（LVM/RAID/btrfs 底层物理盘归属）。
- 不做目录配额/项目配额采集（XFS project quota 等，另立指标）。
- 不在采集端做“系统盘/数据盘”语义判定；该语义由消费侧按需派生。
- 默认不采集网络文件系统容量（避免 `statfs` 阻塞和语义漂移）；确需展示时单独标记并做超时/降级。

## 2. 设计原则

1. **按挂载点采集，汇总只在查询侧。**
   采集端保留每个挂载点的独立时序；整体容量用 `sum()` 在查询时计算。
2. **路径 → 挂载点，而不是路径 → 容量。**
   任意路径解析到它所在的挂载点；挂载点才是容量身份。
3. **稳定标签。**
   指标身份只用 `mount` + `fstype`；不使用会随重启变化的 `device`（如 `/dev/sdX`）。
4. **平台差异用过滤器解决，不改变指标语义。**
   Linux 和 macOS 用同一套 `system.filesystem.*`；差异体现在“哪些挂载点计入”。
5. **告警按挂载点。**
   不用整体使用率触发告警；整体值只用于总览。
6. **重复容量只报一次。**
   同一文件系统被 bind mount 到多个路径时，按文件系统去重；路径映射由消费侧维护。

## 3. 指标模型

### 3.1 指标名与单位

| 指标 | 类型 | 单位 | 含义 |
|---|---|---|---|
| `system.filesystem.usage` | `gauge_f64` | `percent` | 已用百分比 |
| `system.filesystem.total` | `gauge_i64` | `KiBy` | 文件系统总容量 |
| `system.filesystem.available` | `gauge_i64` | `KiBy` | 可用容量（非特权用户可写） |
| `system.filesystem.inodes.usage` | `gauge_f64` | `percent` | 可选：inode 使用率 |
| `system.filesystem.inodes.available` | `gauge_i64` | `1` | 可选：可用 inode 数 |

> 单位沿用现有 `system.memory.*` / `system.disk.*` 的 `KiBy` 口径，避免同一体系里混用字节和 KiB。
> 如果后续告警更希望用字节，可新增 `*.available_bytes`，不要改现有单位。

### 3.2 标签

| 标签 | 必填 | 说明 |
|---|---|---|
| `mount` | 是 | 挂载点，如 `/`、`/var`、`/System/Volumes/Data`、`/Volumes/Backup` |
| `fstype` | 是 | 文件系统类型，如 `ext4`、`xfs`、`btrfs`、`apfs`、`hfs` |

约束：

- **不把 `device` 作为身份标签**：`/dev/sdX` 可能随重启变化，会造成序列换身份。
  需要展示设备时，由网关按 `mount` join `/proc/mounts` 或 `diskutil` 结果补齐。
- 同一文件系统被 bind mount 到多个路径时，只输出一条序列；`mount` 取按操作系统挂载表
  顺序（Linux `/proc/mounts`、macOS `getmntinfo`）出现的第一条（通常是原始挂载点）。
  路径 → 挂载点的映射由网关/UI 维护（见 §4.5）。
- 不对挂载点做“系统盘/数据盘”标签；需要时由消费侧按 `mount` 规则派生。

### 3.3 与旧指标的关系

| 指标 | 处理 |
|---|---|
| `system.disk.{usage,total,available}` | **保留兼容**，含义仍是“主盘/根文件系统”，仅用于旧页面/旧查询 |
| `system.disk.system.*` | Linux 过渡版的系统盘聚合，随 `system.filesystem.*` 落地后标记 deprecated |
| `system.disk.data.*` | Linux 过渡版的数据盘汇总，同上；不再作为告警依据 |
| `system.filesystem.*` | **目标主指标**，逐挂载点，告警依据 |

### 3.4 示例

一台 Linux 主机：

```json
{
  "name": "system.filesystem.usage",
  "value": 95.0,
  "type": "gauge_f64",
  "unit": "percent",
  "labels": [
    { "key": "mount", "value": "/var" },
    { "key": "fstype", "value": "xfs" }
  ]
}
```

```json
{
  "name": "system.filesystem.available",
  "value": 1048576,
  "type": "gauge_i64",
  "unit": "KiBy",
  "labels": [
    { "key": "mount", "value": "/var" },
    { "key": "fstype", "value": "xfs" }
  ]
}
```

## 4. 采集规则

### 4.1 通用

1. 读取挂载点列表（Linux：`/proc/mounts`；macOS：`getmntinfo`/`statfs`）。
2. 按平台规则过滤挂载点。
3. 对每个保留项调用一次 `statvfs`，得到 `total` / `available`。
4. 同一文件系统（同一设备/卷）只保留一条记录。
5. `usage = (total - available) / total * 100`；`available` 超过 `total` 时按 `total` 截断。
6. 采集失败（路径消失、`statvfs` 报错）时跳过该项，不写 0；记录一次采集状态。

### 4.2 Linux

**计入：**

- 根文件系统 `/`；
- 其余本地块设备挂载点，如 `/data`、`/home`、`/srv`、独立数据分区、`/var/lib/docker`（独立挂载时）。

**排除：**

| 类别 | 例子 |
|---|---|
| 引导/运行期挂载 | `/boot`、`/boot/*`、`/run`、`/run/*`、`/sys`、`/sys/*`、`/proc`、`/proc/*`、`/dev`、`/dev/*` |
| 虚拟/内存文件系统 | `tmpfs`、`devtmpfs`、`proc`、`sysfs`、`cgroup`/`cgroup2`、`pstore`、`mqueue`、`hugetlbfs`、`ramfs`、`rootfs` |
| 容器/镜像层 | `overlay`、`aufs`、`squashfs`（snap） |
| 网络/共享文件系统 | `nfs`、`nfs4`、`cifs`、`smb3`、`ceph`、`glusterfs`、`lustre`、`beegfs`、`gpfs`、`9p`、`virtiofs`、`fuse.*` |
| 只读/临时介质 | `iso9660`、可移动介质（按需） |

**去重：**

- 按设备名去重；根设备的 bind mount 不重复计入。
- btrfs 多子卷共享同一文件系统时只报一条。
- 同一物理盘上的不同分区/逻辑卷仍视为不同文件系统；本文不判断物理盘归属。

> 说明：`sysinfo::Disks` 已经过滤了部分虚拟/网络文件系统；这里仍显式做一层过滤，
> 避免 `sysinfo` 版本或 feature 变化导致行为漂移。

### 4.3 macOS

macOS 的 APFS 多个卷共享同一个 container，**不能简单把所有挂载点相加**。

**计入：**

- `/System/Volumes/Data`：内部用户数据卷，内部可用容量主要看它；
- `/Volumes/*` 下的本地卷：外接盘、独立 APFS/HFS 卷、DMG 磁盘映像。

**排除或仅展示：**

| 挂载/卷 | 处理 |
|---|---|
| `/System/Volumes/Preboot`、`VM`、`Update`、`xarts`、`iSCPreboot`、`Hardware` | 排除，与 Data 共享 container，会重复计数 |
| `/` | 只读封存系统快照；默认展示、不告警，容量与 Data 共享 |
| `devfs`、`map`、`autofs` | 排除 |
| `smbfs`、`nfs`、`webdav`、`afpfs` | 默认排除（`statfs` 可能阻塞） |

**聚合约束：**

- 同一 APFS container 内的卷不做求和；整体值只对独立 container/本地外接盘聚合。
- APFS 卷配额/保留容量（quota/reserve）不一定能被 `statfs` 完整体现；
  需要精确配额时，补充 `diskutil apfs list` 或 APFS 专有接口，本文暂不展开。
- `/Volumes/*` 的旧挂载可能已经失效；`statvfs` 报错时跳过，不要卡住整个采集 tick。

### 4.4 网络 / 虚拟 / 临时挂载

默认全部排除。原因：

1. 容量语义不属于本机；
2. `statvfs` 在 hung 的 NFS/CIFS/FUSE 上可能长时间阻塞；
3. 临时挂载会带来高基数和短命序列。

如果产品确实要展示网络卷，单独标记 `network`，并给采集设置超时/降级策略；不要混入
`system.filesystem.*` 的默认告警集合。

### 4.5 路径关注清单（可选）

用户关心的是“路径”，但容量身份是挂载点。处理方式：

1. 采集端默认输出全部本地挂载点；
2. 网关/UI 维护“路径 → 挂载点”的映射：
   - 精确匹配挂载点；
   - 否则取最长前缀挂载点（例如 `/var/log/app` → `/var`）。
3. 告警仍然按挂载点：

```promql
max by (agent, mount) (system.filesystem.usage) > 90
```

如果必须让告警文案带上路径，可在规则里 join 路径映射，或对配置的关注路径单独生成
`system.path.available{path="/var/log", mount="/var"}`。后者会为每个路径复制一份容量序列，
只建议在关注路径数量很少时使用，默认不开启。

## 5. 数据流与契约

### 5.1 采集端

目标形态：事实带 `labels`。

```json
{
  "key": "host.filesystem.usage_percent",
  "value": "95",
  "labels": [
    { "key": "mount", "value": "/var" },
    { "key": "fstype", "value": "xfs" }
  ]
}
```

采集端仍需保留主机级事实（loadavg、memory、uptime 等）；文件系统事实按挂载点重复。

> 不要直接给共享的 `StringKeyValue` 加 `labels`：它是 discovery / execution_hints 等
> 多处共用的契约类型。建议在 metrics 专用的事实类型上加 `labels`（或新增 `LabeledFact`），
> 避免影响其他消费者。

### 5.2 指标声明

在 `wist-metrics` 的 `METRIC_SPECS` 中新增：

```rust
MetricSpec {
    collection_kind: "host_metrics",
    fact_key: "host.filesystem.usage_percent",
    name: "system.filesystem.usage",
    unit: "percent",
    value_type: "gauge_f64",
},
MetricSpec {
    collection_kind: "host_metrics",
    fact_key: "host.filesystem.total_kb",
    name: "system.filesystem.total",
    unit: "KiBy",
    value_type: "gauge_i64",
},
MetricSpec {
    collection_kind: "host_metrics",
    fact_key: "host.filesystem.available_kb",
    name: "system.filesystem.available",
    unit: "KiBy",
    value_type: "gauge_i64",
},
```

### 5.3 指标样本

`MetricsSampleRecord` 增加可选 `labels`：

```rust
#[serde(default, skip_serializing_if = "Vec::is_empty")]
pub labels: Vec<StringKeyValue>,
```

样本示例：

```json
{
  "name": "system.filesystem.available",
  "value": 1048576,
  "type": "gauge_i64",
  "unit": "KiBy",
  "labels": [
    { "key": "mount", "value": "/var" },
    { "key": "fstype", "value": "xfs" }
  ]
}
```

### 5.4 上送数据面

VM 行把标签平铺到 `metric` 对象：

```json
{"metric":{"__name__":"system.filesystem.available","agent":"agent-001","kind":"host_metrics","target_ref":"hostname:demo-host:host","resource_ref":"hostname:demo-host","unit":"KiBy","mount":"/var","fstype":"xfs"},"values":[1048576.0],"timestamps":[1760860800000]}
```

数据面 `agent_uplink` 的 WPL/OML 需要透传 `metric.mount` / `metric.fstype`：

- `parse.wpl` 的 `agent_uplink_metrics_frame` 增加可选字段；旧 agent 帧不带标签时必须仍能解析；
- `agent_uplink_metrics_frame`（`oml/agent_uplink/agent_uplink_metrics_frame/adm.oml`）写回 `mount` / `fstype`（缺省时不要写空标签）。

### 5.5 网关接口

`GET /api/v1/admin/agents/{agent_id}/host-metrics` 增加逐挂载点列表：

```json
{
  "agentId": "agent-001",
  "nodeId": "node-001",
  "hostname": "demo-host",
  "filesystems": [
    {
      "mount": "/",
      "fstype": "ext4",
      "usagePercent": 60.0,
      "totalKb": 104857600,
      "availableKb": 41943040
    },
    {
      "mount": "/var",
      "fstype": "xfs",
      "usagePercent": 95.0,
      "totalKb": 20971520,
      "availableKb": 1048576
    },
    {
      "mount": "/data",
      "fstype": "ext4",
      "usagePercent": 21.875,
      "totalKb": 1073741824,
      "availableKb": 838860800
    }
  ]
}
```

旧字段（`diskUsagePercent` / `diskTotalKb` / `diskAvailableKb`）继续返回，保持兼容。

### 5.6 页面

主机详情页：

| 挂载点 | 文件系统 | 使用率 | 可用 | 状态 |
|---|---|---:|---:|---|
| `/` | ext4 | 60.0% | 40.0 GiB | 正常 |
| `/var` | xfs | **95.0%** | **1.0 GiB** | **危急** |
| `/data` | ext4 | 21.9% | 800.0 GiB | 正常 |

顶部总览显示整体使用率和“最紧张挂载点”，但告警只按挂载点触发。

## 6. 告警

```promql
# 任一挂载点使用率超过 90%
max by (agent, mount) (system.filesystem.usage) > 90
```

```promql
# /var 可用空间低于 5 GiB（指标单位是 KiB）
system.filesystem.available{mount="/var"} < 5 * 1024 * 1024
```

```promql
# 可选：inode 使用率
system.filesystem.inodes.usage{mount="/var"} > 90
```

约束：

- 不用 `sum(system.filesystem.*)` 触发告警；
- 不对同一 APFS container 的多个卷求和；
- 告警规则按 `agent` + `mount` 分组，避免多挂载点互相稀释。

## 7. 成本与容量规划

### 7.1 运行时

- 当前 `Disks::new_with_refreshed_list()` 已经枚举挂载点并对每个挂载点调用 `statvfs`；
  逐挂载点输出**不新增探测系统调用**，只是多产出样本。
- 普通服务器 5–20 个挂载点，单次 CPU 成本可忽略；字符串/JSON 序列化是主要新增开销。
- 真正的风险是 **网络/失效挂载导致 `statvfs` 阻塞**，必须过滤。

### 7.2 序列、网络、存储

假设每挂载点 3 个指标：

| 挂载点数/主机 | 序列数/主机 | 1000 台序列数 |
|---:|---:|---:|
| 10 | 30 | 30,000 |
| 20 | 60 | 60,000 |
| 100（K8s 节点） | 300 | 300,000 |

建议容量指标 **60s 一拍**（容量变化慢），不要和 15s 的负载指标绑死：

- 20 挂载点 × 3 指标 × 1440 次/天 ≈ 86,400 样本/天/主机；
- 1000 台 ≈ 86M 样本/天；
- 压缩后通常每样本 1–2 字节量级，30 天在几 GB 到十几 GB 量级（不含副本/索引）。

网络侧：每条约 200–300 字节；20 挂载点 × 3 指标约 15–18 KB/主机/拍，
60s 拍下 1000 台约 250–300 KB/s。15s 拍约为其 4 倍。

### 7.3 基数控制

- 只保留本地块设备文件系统；
- 排除 overlay/fuse/网络/临时挂载；
- 不使用 `device` 作为身份标签；
- 单机挂载点超过阈值（如 100）时记录告警/降级日志，避免异常挂载拖垮采集。

## 8. 边界与已知问题

| 问题 | 处理 |
|---|---|
| 路径不是挂载点 | 解析到所属挂载点；容量仍按挂载点报 |
| 同一文件系统 bind mount 到多个路径 | 按文件系统去重，只报一条；路径映射由网关维护 |
| LVM/RAID/btrfs 多逻辑卷同物理盘 | 按文件系统报；不判断物理盘归属 |
| inode 用尽导致写失败 | 可选采 `system.filesystem.inodes.*` |
| XFS project quota / 目录配额 | 需要单独配额指标，`statvfs` 不覆盖 |
| APFS 多卷共享 container | 不跨卷求和；排除系统辅助卷 |
| APFS quota/reserve | `statvfs` 可能不完整；需要时补 `diskutil apfs list` |
| 失效外接盘 / hung 网络盘 | 过滤网络 FS；`statvfs` 失败时跳过，不阻塞 tick |
| Agent 跑在容器里 | 看到的是容器挂载；按宿主系统服务部署时才是宿主容量 |

## 9. 与当前实现的关系

已落地的逐挂载点链路：

- **agentd**：`collect_host_filesystem_usage` 按挂载点产出
  `host.filesystem.{usage_percent,total_kb,available_kb}`，带 `mount` / `fstype` 标签；
  Linux 与 macOS 使用各自的过滤器；
- **wist-metrics**：新增 `MetricsLabeledFact`、`labeled_facts` 字段与
  `system.filesystem.*` spec；
- **数据面**：`agent_uplink` 的 WPL/OML 透传 `mount` / `fstype`；
- **网关**：`host-metrics` 接口新增 `filesystems[]`，摘要新增
  `maxFilesystemUsagePercent`；
- **Web**：主机详情页新增文件系统容量表，主机列表按“最紧张挂载点”分级/排序。

保留的兼容层：

- Linux 过渡版 `host.disk.system.*` / `host.disk.data.*` 仍在采集；
- `system.disk.*` 旧指标仍在返回，旧页面/旧查询不受影响；
- 两者后续可标记 deprecated，但不在本次改动中移除。

尚未落地：

- inode 指标；
- APFS quota/reserve 精确采集；
- 关注路径清单与路径 → 挂载点的服务端映射；
- 独立于 `MetricInterval` 的 60s 容量采集调度。

## 10. 实施计划

### Phase 1：采集与指标契约（已落地）

- `wist-metrics`：新增 `system.filesystem.*` spec 与 `labeled_facts` 契约；
- `wist-agentd`：
  - 逐挂载点采集（Linux / macOS 过滤器）；
  - 事实带 `labels`；
  - 本地 `metrics_samples.json` 输出 `labels`；
- 测试：Linux 多挂载点、bind mount 去重、macOS Data/外部卷、网络卷排除。

### Phase 2：数据面透传（已落地）

- `agent_uplink/parse.wpl` 增加 `mount` / `fstype` 可选字段；
- `agent_uplink_metrics_frame` OML 写回标签；
- 验证 VM 中能按 `mount` 查询到独立序列；
- 回归脚本：`dev/tests/agent-uplink-metric-labels.test.sh`（wparse batch，带标签/不带标签两条帧）。

### Phase 3：网关与页面（已落地）

- `host_metrics.rs` 返回 `filesystems[]`；
- 主机详情页新增文件系统容量表；主机列表按最紧张挂载点分级/排序；
- 旧字段保持兼容。

### Phase 4：告警与增强（待做）

- 按 `mount` 的告警规则；
- 可选 inode 指标；
- 可选关注路径清单与路径映射展示；
- 独立 60s 容量采集调度。

### 验收标准

1. 主机存在 `/var` 95%、`/data` 21.9%、整体 26.5% 时：
   - VM 中存在 `system.filesystem.usage{mount="/var"}`；
   - 告警只对 `/var` 触发；
   - 整体查询仍显示 26.5%。
2. 同一文件系统 bind mount 到多个路径时，只出现一条容量序列。
3. `/boot`、`/run`、`/sys`、`/proc`、`/dev`、overlay、fuse、网络 FS 不出现在默认序列中。
4. macOS：
   - `/System/Volumes/Data` 与本地 `/Volumes/*` 可见；
   - `/System/Volumes/Preboot` 等辅助卷不重复出现；
   - `/` 可展示但不触发告警。
5. 旧 `system.disk.*` 查询与页面不回归。

## 11. 待决问题

1. **全量挂载点 vs 配置关注路径**：默认全量本地挂载点；关注路径作为展示补充。
2. **`device` 是否作为展示标签**：默认不作为身份标签；如果需要显示设备，由网关 join。
3. **macOS Data 卷的展示名**：`mount` 保留真实路径 `/System/Volumes/Data`，UI 显示为
   “Macintosh HD（Data）”。
4. **APFS quota/reserve 是否纳入首版**：先不做，确认需求后补 `diskutil`。
5. **inode 指标是否首版上线**：先做容量三件套，inode 作为 Phase 4。
6. **容量采集间隔**：建议 60s；如果统一由 `MetricInterval` 控制，需要评估是否单独调度。

## 12. 相关文档

- [`resource-discovery-runtime.md`](./resource-discovery-runtime.md)
- [`discovery-runtime-current-state.md`](./discovery-runtime-current-state.md)
- [`../center/collection-families.md`](../center/collection-families.md)
- [`../telemetry/metrics-integration-roadmap.md`](../telemetry/metrics-integration-roadmap.md)
- `wist-agentd/docs/design/linux-security-audit-log-sources.md`（Linux 主机采集源清单 §5.15）
