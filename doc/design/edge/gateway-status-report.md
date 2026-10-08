# 网关状态上报（上报中心的字段与数据源）

> **状态**：**落地中**（Phase 1，2026-10-05）。
> **关联**：[`../foundation/cross-repo-issues.md`](../foundation/cross-repo-issues.md) **CR-003**（宿主侧常驻 `wist-gwlinkd` 代报）、
> [`gateway-linkd-status.md`](gateway-linkd-status.md)（gwlinkd **自身**状态 —— 另一条通道，勿混）。

## 1. 谁在报、报给谁

网关**容器自己不上报** —— 由宿主侧常驻 `wist-gwlinkd` 代报（CR-003）：

```
网关自述面（环回 GET /api/v1/gateway/self-state）
        │
        ▼
   gwlinkd（每 30s 拉一次，派生 health）
        │  POST {center}/api/v1/gateway/status（mTLS 客户端证书）
        ▼
     中心（submit_gateway_status → GatewayRuntimeStatus）
```

由此：**「网关上报的数据」= 自述面的字段**，经 gwlinkd 转报中心。要加字段，先改**自述面**（环回契约），
再按需扩中心侧上报契约（`wist-control::ReportGatewayStatus`）。

> 页面（`wist-gateway-web`「网关状态」页）读的是**同一份自述面**的 admin 读口
> （`GET /api/v1/admin/gateway/self-state`）—— 环回面浏览器够不到，故补一个等价计算的 admin 口。

## 2. 字段

| 字段 | 含义 | 来源 | 阶段 |
|---|---|---|---|
| `gateway_id` | 网关实例名（调用方回显） | 请求参数 | 已有 |
| `version` | **网关容器**版本 | `CARGO_PKG_VERSION` | 已有 |
| `public_base_url` | 网关**对外域名**（对外基址） | 管理面「对外地址」‖`[server] public_base_url` | **Phase 4** |
| `collected_at` | 采集时刻 | | 已有 |
| `store_healthy` | 存储能否查 | store `list_agents` | 已有 |
| `agent_count` | 已登记 Agent 数 | store | 已有 |
| `last_error` | 最近错误 | store | 已有 |
| `uptime_seconds` | 网关**进程**已运行秒数 | `sysinfo::Process::run_time` | **Phase 1** |
| `cpu_percent` | 网关**进程** CPU 占比（单核口径） | `sysinfo`（持久 System 算增量） | **Phase 1** |
| `memory_bytes` | 网关**进程** RSS（字节） | `sysinfo` | **Phase 1** |
| `online_agents` | 在线 Agent 台数 | 复用 `AgentOverview` 的在线判据 | **Phase 1** |
| `offline_agents` | 离线台数（= 总数 − 在线） | | **Phase 1** |
| `last_seen_lag_seconds` | 机队最久没上报的滞后秒数 | 复用 `AgentOverview` | **Phase 1** |
| `store_bytes` | 存储大小（SQLite 文件字节） | `AdminConfig.sqlite_path` 的文件 | **Phase 2** |
| `ingest_accepted_total` | 累计接收事实条数（自进程启动） | `AdminRuntimeState`（ingest 累加） | **Phase 2** |
| `ingest_rejected_total` | 累计拒收条数 | 同上 | **Phase 2** |
| `last_ingest_at` | 最近一次接收事实的时刻 | 同上 | **Phase 2** |
| `memory_total_bytes` | 主机内存总量 | `sysinfo` `total_memory` | **Phase 3** |
| `load_1m` / `load_5m` / `load_15m` | 主机 1/5/15 分钟负载 | `sysinfo::System::load_average` | **Phase 3** |
| `disk_usage_percent` / `disk_total_bytes` / `disk_available_bytes` | 主盘使用率 / 总量 / 可用 | `sysinfo::Disks`（汇总挂载点，近似） | **Phase 3** |

**要点**：`cpu_percent` / `memory_bytes` 是上报契约 `ReportGatewayStatus` 里**一直留着但恒空**的两位 ——
Phase 1 把它们填上（gwlinkd 从自述面取到即原样上报）。**量不出时给 `null`，不假装 0。**

### 进「中心」（已落地）

`ReportGatewayStatus`（`wist-control`）与模型 `GatewayRuntimeStatus` 已加上富化字段；中心
（`PgStore` / `FileStore` + `gateway_runtime_status`）**持久并暴露了全部富化字段**：
`uptime_seconds` / 机队（`agent_count` / `online_agents` / `offline_agents` / `last_seen_lag_seconds`）/ 存储（`store_bytes`）/
数据面（`ingest_accepted_total` / `ingest_rejected_total` / `last_ingest_at`）/ 主机（`memory_total_bytes` / `load_1m|5m|15m` /
`disk_usage_percent` / `disk_total_bytes` / `disk_available_bytes`），另加原有的 `cpu_percent` / `memory_bytes`。

**网关对外域名**（`public_base_url`）：网关**自己才知道**这个值（管理面「对外地址」优先、未设回落
`[server] public_base_url`），自述面带上它 → gwlinkd 随 **注册**（`RegisterGateway`）与**周期状态上报**
（`ReportGatewayStatus`）转带给中心；中心落库（`gateways.public_base_url`）并在网关列表展示「域名」。
状态上报不带（老网关 `None`）时**保留**已落值，不抹掉。三处均为**可选键**（线上 JSON 向后兼容）。

实测（中心 `GET /api/v1/admin/gateways/status`）：
```json
{"gateway_id":"GX01","version":"0.1.16","health":"ok","cpu_percent":0.198,"memory_bytes":32407552,
 "uptime_seconds":164,"agent_count":3,"online_agents":1,"offline_agents":2,"last_seen_lag_seconds":555271,
 "store_bytes":1622016,"ingest_accepted_total":0,"ingest_rejected_total":0,"last_ingest_at":null,
 "memory_total_bytes":68719476736,"load_1m":3.83,"load_5m":5.04,"load_15m":4.63,
 "disk_usage_percent":83.39,"disk_total_bytes":1990380990464,"disk_available_bytes":330521883866}
```

中心 Web（`wist-center-web`）的 `GatewayDetailPage` 已把这些渲染为指标块（运行时长 / Agent 在线·离线 / 存储 / 数据面接收 / 主机内存 / 磁盘 / 负载）；`GatewayStatusView` 归一化同步扩展（老后端缺键 → `null`，页面显示「—」）。

### 进「VictoriaMetrics」（时序，已落地）

中心在 `submit_gateway_status` 里把同一次上报转成 Prometheus 文本推给 VM
（`wist-center/src/infra/vm.rs::render_prometheus_lines`；push 失败仅告警，不阻塞落库）。标签统一 `{gateway_id, instance_id}`：

| 指标 | 来源字段 | 口径 |
|---|---|---|
| `gateway_up` | `status` | online → 1，否则 0 |
| `gateway_info{version}` / `gateway_health{health}` | `version` / `health` | info-style，恒 1 |
| `gateway_memory_bytes` / `gateway_cpu_percent` | 进程资源 | gauge |
| `gateway_uptime_seconds` | `uptime_seconds` | gauge |
| `gateway_agent_count` / `gateway_online_agents` / `gateway_offline_agents` | 机队 | gauge |
| `gateway_last_seen_lag_seconds` | 机队陈旧度 | gauge |
| `gateway_store_bytes` | 存储 | gauge |
| `gateway_ingest_accepted_total` / `gateway_ingest_rejected_total` | 数据面 | counter |
| `gateway_last_ingest_timestamp_seconds` | `last_ingest_at` | gauge（epoch 秒） |
| `gateway_memory_total_bytes` / `gateway_load1` / `gateway_load5` / `gateway_load15` / `gateway_disk_usage_percent` / `gateway_disk_total_bytes` / `gateway_disk_available_bytes` | 主机 | gauge |

**除 `gateway_up` / `gateway_info` / `gateway_health` 外，其余字段「有值才推」**（老网关没上报 → 不产生该序列，而不是写 0）——与「量不出即 `null`」同口径。

历史查询（`GET /api/v1/admin/gateways/{id}/status/history`）从 VM 拉 `gateway_up` / `gateway_memory_bytes` / `gateway_cpu_percent` /
`gateway_uptime_seconds` / `gateway_agent_count` / `gateway_online_agents` / `gateway_offline_agents` / `gateway_last_seen_lag_seconds` /
`gateway_store_bytes` / `gateway_load1` / `gateway_disk_usage_percent` 合并成 `GatewayMetricSample`；中心 Web `GatewayHistoryChart`
按「该序列有无数据」逐行条件渲染（老数据缺序列 → 不显示空行，agent 紧凑图也不出现网关专属行）。

### 跨仓 / 版本

- `wist-control` 是**独立仓**：已 bump `0.6.0 → 0.6.1`（**新增可选字段，向后兼容**）。
- `wist-gwlinkd` / `wist-center` 的 `Cargo.toml` 暂时把 `wist-control` 切到 **path（`../wist-control`）** 以便用本地版本；
  **发版前切回 registry**（`0.6`）。
- 中心用 **PostgreSQL**：表结构在 `docker/initdb/01_schema.sql`（**首次初始化**才建）。已有数据卷需手动
  `ALTER TABLE gateways ADD COLUMN …`（本仓已加；旧库需补跑）——无迁移框架，改列要手动上。

## 3. 契约（三份形状同钉）

| 面 | 类型 | 位置 |
|---|---|---|
| 环回自述面 + admin 读口 | `GatewaySelfState`（snake_case） | `wist-gateway/src/api/self_state.rs`；模型 `Control.GatewayApp.SelfInterface.GatewaySelfState` |
| 上报中心 | `ReportGatewayStatus` | `wist-control`；模型 `Control.Gateway.ReportGatewayStatus` |
| 中心视图 | `GatewayRuntimeStatus` | 模型 `Control.Gateway.GatewayRuntimeStatus` |

三者字段成对，任一侧改名即由各自的键集 / 解析测试爆掉（防拷贝漂移）。

## 4. 不变量

1. **网关仍不直连中心**：上报由 gwlinkd 代劳（CR-003 R1 不变）。
2. **准确值来自网关进程内**：`health` / 机队 / 进程资源都在网关侧算，gwlinkd 只搬运 + 派生 `health`。
3. **量不出即 `null`**，不用 0 冒充（页面显示「—」）；VM 同口径：除 `up`/`info`/`health` 外**有值才推**。
4. **自述面限环回**：admin 读口是等价计算的另一入口，不改变环回面的私密性。
5. **中心「在线」带陈旧度**：`online = status == "online" && (now − last_seen_at) ≤ 90s`（= 3× 上报节奏，与网关侧 linkd-status 失联阈值同口径）。
   只看状态字符串会让 gwlinkd 停报（崩溃/停服）后**永远显示在线**（它只在活着时上报、从不发 `offline`）—— 与网关侧口径不一致。
