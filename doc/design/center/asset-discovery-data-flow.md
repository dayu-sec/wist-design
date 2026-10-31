# 资产发现数据流（现状）

把「发现」到「清单 / 用途」的落地路径画清楚：**一次上报，多个消费者**。本文只描述**当前已通**的链路与缺口，不描述待做形态。

> 两个词别混：**「发现」**是 agentd 的探针（本机事实）；**「资产清单」**是网关对事实摘要做的 **L1a 机械归并**。
> 发现侧同时产出**摘要**（控制面，喂用途推断/L1a）与**原文快照**（数据面，喂 `wist-atlas`）；
> 清单仍完全在网关算，不因原文通道而改变。

## 1. 全链路

```mermaid
flowchart TD
  subgraph EDGE["wist-agentd（边缘）"]
    PR["发现探针：host / network / endpoint / process"]
    SN["快照 combine：按周期刷新，未到期沿用上次"]
    FS["事实摘要 build_summary：去重 + 只留推断/展示字段"]
    PR --> SN --> FS
    SN -->|"DSNAP: 帧 · 原文快照"| WPL2
  end

  FS -->|"OBSFACT: 帧 · TCP :9000"| WPL
  PR -.->|"控制面：拉周期策略"| GW

  subgraph DP["数据面 warp-parse"]
    WPL["WPL agent_uplink/agent_uplink_obs_fact：拆信封，正文透传"]
    OML["OML agent_uplink_obs_fact"]
    SG["sink_group agent-facts"]
    WPL2["WPL agent_uplink/agent_uplink_obs_dsnap"]
    OML2["OML agent_uplink_obs_dsnap"]
    SG2["sink_group agent-dsnap"]
    WPL --> OML --> SG
    WPL2 --> OML2 --> SG2
  end

  SG -->|"file sink"| F1[("agent-facts.jsonl（肉眼验证）")]
  SG -->|"http_sink POST · 明文 127.0.0.1:3001"| ING
  SG2 -->|"file sink"| F2[("agent-dsnap.jsonl")]
  F2 --> AD["atlas 适配器：ReportDiscoverySnapshot → atlas.in.edge.v1"]
  AD --> AT["wist-atlas import-jsonl / 后续 HTTP ingest"]

  subgraph GW["wist-gateway"]
    ING["内部端点 POST /api/v1/ingest/agent-facts"]
    CORE["ingest_fact_summary：网关自算 digest 判重"]
    ING --> CORE
    CORE --> T1[("agent_fact_summary（覆盖式一台一条）")]
    CORE --> T2[("agent_software_inventory（L1a）")]
    CORE --> T3[("purpose_suggestion")]
  end

  T1 --> PG["管理面 / 页面：/admin/software 等"]
  T2 --> PG
  T3 --> PG
```

## 2. 分段说明

| 段 | 位置 | 做什么 |
|---|---|---|
| 发现 | `wist-agentd/src/discovery/` | 探针 `host / network / endpoint / process / container`（`[discovery] *_enabled` 控制；container 默认开）产出 `DiscoveredResource` |
| 快照 | `discovery/runtime.rs`、`cache.rs` | 把各探针输出拼成 `DiscoverySnapshot`；**只刷到期的探针**，未到期沿用上次输出（少交一个探针等于把它上次的资源删掉） |
| 摘要 | `reporting/fact_summary.rs` | `build_summary()`：去重压成 `process_executables` / `listen_ports` / `packages`（探针未实现，恒空）+ `os/arch/process_count`；另带 `host_id/host_name/network_addresses`（仅留痕，不进摘要） |
| 上行（摘要） | `runtime/daemon.rs::report_fact_summary` | 组 `{schema, agent, ts, seq} OBSFACT: <json>` 帧，走数据面 TCP sink |
| 原文快照 | `discovery/runtime.rs` 的 `latest_snapshot` | `ReportDiscoverySnapshot`（`kind=report_discovery_snapshot`，`report_mode=full_snapshot`）；周期由 `discovery.snapshot_uplink_interval_seconds` 控制（默认 3600s，最低 60s） |
| 上行（原文） | `runtime/daemon.rs::report_discovery_snapshot` | 组 `{schema, agent, ts, seq} DSNAP: <json>` 帧；与摘要共用 TCP sink 与全局 `seq` |
| 解析（摘要） | `data-plane/models/wpl/agent_uplink/parse.wpl` | `rule agent_uplink_obs_fact`：`symbol(OBSFACT:)` + `chars:body\0`，**正文不拆字段**（契约可演进） |
| 解析（原文） | 同一 WPL + `models/oml/agent_uplink/agent_uplink_obs_dsnap/adm.oml` | `rule agent_uplink_obs_dsnap`：`symbol(DSNAP:)` + `chars:body\0`；只拆信封，正文原样透传 |
| 建模（摘要） | `data-plane/models/oml/agent_uplink/agent_uplink_obs_fact/adm.oml` | 只把信封拆成 `schema/agent_id/observed_at/seq/category/body` |
| 分流（摘要） | `data-plane/topology/sinks/business.d/agent_facts.toml` | `sink_group agent-facts`，`oml=["agent_uplink_obs_fact"]` |
| 落两处（摘要） | 同上 | ① `file_json_sink` → `agent-facts.jsonl`（肉眼验证）；② `gateway_facts_sink`（`sink.d/22-gateway_facts_sink.toml`）POST 到网关 |
| 分流（原文） | `data-plane/topology/sinks/business.d/agent_dsnap.toml` | `sink_group agent-dsnap`，`oml=["agent_uplink_obs_dsnap"]` → `agent-dsnap.jsonl` |
| 原文消费 | `wist-atlas/scripts/wist-snapshot-to-atlas.py`（P0）| `ReportDiscoverySnapshot` → `atlas.in.edge.v1`（hosts/interfaces/processes）→ `import-jsonl` |
| 校验 | `wist-gateway/src/api/ingest.rs` | 只做两件正确性检查：`agent_id`/`instance_id` 对得上登记表、**信封自称 == 正文自称**（**不是认证**） |
| 派生 | `src/api/agent_ops.rs` | `ingest_fact_summary`：网关**自算** `content_digest` → 判重 → 覆盖写 `agent_fact_summary`；内容变才 `refresh_software_inventory`（`app/inventory.rs::derive_inventory`）+ 重跑用途推断 |
| 展示 | `src/api/software_ops.rs` 等 | 「按机器看软件」「按软件看机器」「用途」三类视图 |

**控制面**（与上行无关，只给周期）：agentd 拉 `POST /api/v1/agent/discovery-policies:poll` 拿各方向观测周期；网关未配表回 503，agentd 用内建默认值。它**不接管探针开关**。

### 2.1 发现面 → 资源 kind → atlas 模型

原文快照里的对象不是都能进 atlas。当前消费子集：

| 发现方向 | probe | resource kind | atlas 目标 | 平台覆盖 | 阶段 |
|---|---|---|---|---|---|
| host | `host` | `host` | `HostInventory` | macOS / Linux | P0 |
| network | `network` | `network_interface` / `ip_address` | `NetworkSegment` / `HostNetAssoc` | Linux 全；macOS 只有地址（无默认网关） | P0 |
| process | `process` | `process` | `ProcessRuntimeState` | macOS / Linux | P0 |
| endpoint | `endpoint` | `service_endpoint` | `SvcEp` / `EpRes` | Linux；macOS 空实现 | P2 |
| container | `container` | `container` | `ContainerRuntime` | 默认关 | P2 |
| k8s | `k8s` | —（`NotImplemented`） | `PodInventory` | 未实现 | P2 |
| package | 无探针 | — | `SoftwareEvidence` | Linux（待实现） | P2 |

约束：

- 原文快照是**全量**的，atlas 只取上表子集；未消费的 kind 仍保留在 `agent-dsnap.jsonl` 中供回放。
- `targets[]` 不直接落 atlas 的服务/端点对象；它只作为采集提示，P0 忽略。
- `host.id` 形如 `hostname:<name>` 时映射为 `external_ref`，**不能**当 `machine_id`。
- host 资源的 `os.name` / `os.version` / `host.arch` 映射为 `HostInventory.os_name` / `os_version` / `arch`。`os.name` 是**产品名**（`macOS` / `Ubuntu`），不是 sysinfo 的内核名（`Darwin`）；Linux 上 `os.version` 是内核版本。
- **进程与主机的退役判据不同**：进程按「一份快照没出现」算（churn 是常态）；主机按「连续 N 份完整快照都没出现」算（`HOST_STALE_AFTER_MISSES`，默认 3）—— 主机消失可能只是一轮探针失败。
- 主机退役要**多主机快照**才触发。当前适配器一台机一个信封，所以这条清扫实际上要等网关侧聚合 / CMDB 同步这类多主机输入；机制已就位，单主机输入下是空操作。

## 3. 关键性质（设计意图，非巧合）

- **判重在网关、不在 agent**：agentd **无条件周期全量**上报（只按最小间隔节流），网关从内容重算 digest 作幂等键 —— agent 侧算法退化不会造成静默漏报。
- **摘要只留当前、覆盖式**：一台一条，不记历史。
- **清单是摘要的派生投影**：内容变才重建，随时可由摘要重算。
- **失败要显形**：网关对坏记录回非 2xx → wparse 重试并最终落 `data/rescue`；agentd 用 file sink 时事实帧**报错**（不像指标静默跳过）。

## 4. 现状缺口

| 缺口 | 影响 |
|---|---|
| **原文快照的实时接收** | 已落地：`DSNAP:` → `agent-dsnap.jsonl` → `atlas-wist-ingest`（增量读 + 偏移检查点）→ `wist-atlas`。**没有**做 atlas 内部 HTTP ingest：网关的 `http_sink` 重试 3 次后就丢帧，而 sink 文件是追加写的，停机期间帧还在长；也不需要为写入口设计鉴权。快照替换（stale）已做，限 `processes[]`。 |
| **原文消费子集有限** | endpoint / container / k8s / package 暂不进 atlas，容器与编排资产仍不可见 |
| `packages` 探针未实现 | 已装包集合恒空（**空 = 没采，不是没装**，见 `B119`） |
| 数据面接入**无鉴权** | 网关/atlas 订阅端不校身份（有意接受的降级窗口，见交付计划 §9） |
| container / k8s 探针关闭 | 容器/编排资产不在当前发现范围 |
| Linux 只有可执行路径、没有参数 | `python3` / `java` / `node` 的不同用途分不出来；`cmdline` + 包清单仍缺（见 `B119`） |

## 5. 模型落点

本链路在模型里表达为 **`runtime/global/asset-discovery-dataflow.mju`** 的 `dataflow AssetDiscoveryDataFlow`：

- 端点用**模型条目**：`node<message> ReportAgentFactSummary`、`node<flow> IngestAgentFactSummaryFlow`、`node<resource> Control.AgentFactSummary / AgentSoftwareEntry / PurposeSuggestion`，数据面作 `node<external> WarpParseDataPlane`。
- 边：`write`（agentd→数据面）、`trigger`（数据面→ingest flow）、三条 `write`（flow→三张派生表）、`emit`（flow→数据面，回 `FactSummaryAccepted`）。
- **为什么不用 `topology.mju` 的 `link<data>`**：那要求两端是**主机节点**，而本链路要表达的是「什么数据经哪一步变成什么」，端点是 message/flow/struct。二者不是同一件事，故分列（`link<data>` 仍无法以拓扑 `node` 为端点）。
- **为什么声明 `domain Reporting`**：端点多在 Reporting 域，未限定名按 Reporting 解析，`node<flow>` 与其 interface 输出（`FactSummaryAccepted`）才同域对得上。
- **原文快照（`DSNAP:`）是同一条 dataflow 的第二条 write 边**：agentd → `WarpParseDataPlane`，消费端是 `wist-atlas`。当前模型只画了摘要这条；DSNAP 的 `node<message> ReportDiscoverySnapshot` 与 atlas 端点待 P1 稳定后补入（避免把未定型的 ingest 写成模型契约）。

## 6. 关联文档

- [`./agent-purpose-inference.md`](./agent-purpose-inference.md) §3：事实从哪来（摘要/原文两条载荷）。
- [`./agent-work-delivery-plan.md`](./agent-work-delivery-plan.md) §4.1：事实上报统一走数据面；§8.2：资产清单按层归属；§9：数据面接入无鉴权风险行。
- [`./report-discovery-snapshot-schema.md`](./report-discovery-snapshot-schema.md)：原文快照（`DSNAP:` body）的 schema。
- [`../foundation/jumo-verification-model.md`](../foundation/jumo-verification-model.md)：把模型做成机器可检规约（本条 dataflow 是其中一个可检端点）。
