# 主机流记录的存储（`NetworkFlow` → field）

> 状态：**设计稿**（2026-11-28）。上游：
> [`wist-agentd/docs/design/host-ebpf-flow-collection.md`](../../../../wist/wist-agentd/docs/design/host-ebpf-flow-collection.md)（采集与记录契约）、
> [`wist-agentd/docs/design/host-flow-data-spec.md`](../../../../wist/wist-agentd/docs/design/host-flow-data-spec.md)（上行帧格式）、
> [`evidence-service.md`](evidence-service.md)（证据服务的边界与索引模型）、
> [`wist-atlas` 网络建模分析](../../../../wist-atlas/doc/architecture/network-modeling-analysis.md)（`DepObs` 分层纪律）。

## 1. 目的与边界

**要回答的问题**：某台主机在一段时间内**跟谁通信过**（对端 IP、端口、协议、方向、字节数、报文数），
能按主机 + 时间窗查、能按对端 IP 反查"谁连过它"。

**不在本文**：

- 采集与记录形状（`wist.host_flow/v1`）→ agentd 的两份设计文档；
- 数据面帧格式与 WPL/OML → 同上 `host-flow-data-spec.md` §2–§3；
- 拓扑推导（`DepObs` / `DepEdge` / inventory）→ atlas 的网络建模分析，本文只划"数据从哪来"。

## 2. 链路

```text
agentd（tc/eBPF）
  └─ FLOW 帧 ──► wparse tcp_1（framing=len）
                   └─ WPL agent_uplink_flow_frame → OML → sink 分组 agent-flows
                        ├─ file_json_sink        → agent-flows.jsonl（本机兜底 + 对账底账）
                        └─ gateway_flows_sink    → POST 127.0.0.1:3001/api/v1/ingest/agent-flows
                                                     │  网关补 cust_id（= 登记表 tenant_id）
                                                     ▼
                                        POST <field>/internal/flows（evidence 写端口）
                                                     ▼
                                        pg-<cust>: flow_window（天分区）
                                                     ▼
                                        field-api 只读查询 → 「数据场」页面
                                                     ▼
                                        atlas 后台任务扫窗口 → DepObs / DepEdge（不碰 inventory）
```

**为什么多一跳网关**：客户标识不能出现在数据面（`wist-field-stack/docs/multi-customer.md`：
sink 只有一份投递配置），而**网关知道 agent → tenant 的绑定**（`store.get_agent().tenant_id`）。
让网关补 `cust_id` 是唯一不需要给每个客户配一条 sink 的做法。

## 3. 决策

| # | 决定 | 为什么 |
|---|---|---|
| **D1** | 存储 = **PG 天分区表**（每客户库） | 需要幂等 upsert + 按主机/时间/对端查询 + 便宜的保留期删除；field 已有每客户 PG，不引入新的存储引擎 |
| **D2** | **不进 VictoriaMetrics** | 五元组是天然高基数（每窗每对端一条序列），进 TSDB 会炸 |
| **D3** | 原始批次**可选**落对象存储（冷备） | 可回放/可重算口径；按批落一个 ndjson 对象，**不**按窗口落对象 |
| **D4** | 落 **evidence 服务**，但**不是** `evidence_artifact` | 一产物一对象的模型（正文在 COS、索引可重建）不适合百万级小记录；`flow_window` 是同库的**运行时观测表** |
| **D5** | 客户归属由**网关**补，不信任数据面 | 数据面 `tenant_id` 当前恒为 `unbound`；网关是绑定关系的权威 |
| **D6** | 幂等键 = 记录规范 §7 的 11 段 + `tenant_id` | 重发/重放覆盖而不是追加；`seq` 不参与（传输层键） |
| **D7** | 保留期 = **按天 `DROP PARTITION`** | 流是这套体系里体量最大的数据，行级删除会拖垮 vacuum |
| **D8** | atlas 只做**下游推导** | 它的设计纪律要求 flow 先进观测层，不得直接 materialize 成 inventory |
| **D9** | 文件 sink 保留为**底账** | 网关端点失败时 wparse 落 rescue，本地还有 jsonl；对账靠两边行数 |

**D4 的退出条件**（写下来，避免永久将就）：出现下列任一情况就拆独立 `flow` 服务——
① 单客户日增 > 2000 万行或库体积影响 evidence 的备份窗口；② 需要独立的读写扩缩容；
③ 保留期策略与证据保留期开始互相牵制。

## 4. 网关端点：`POST /api/v1/ingest/agent-flows`

与 `agent-facts` / `agent-logs` 同一张**明文、只绑环回**的内部监听（`ingest_router`），
请求体是 wparse 记录（单对象或数组，`batch_size` 调大后会出现数组）。

### 4.1 请求

```json
[
  {
    "schema": "v1",
    "agent": "agent-host-d97e23da6111",
    "ts": "2026-11-28T04:16:42Z",
    "seq": 100231,
    "log_type": "agent_uplink_flow_frame",
    "body": "{\"record_schema\":\"wist.host_flow/v1\",...}"
  }
]
```

`body` 是**转义后的 JSON 字符串**（数据面不拆字段），网关要再解析一层。

### 4.2 逐条校验（顺序固定，失败即整条拒绝）

| 检查 | 失败返回的 detail |
|---|---|
| `log_type == "agent_uplink_flow_frame"` | `not a flow record: log_type=<x>` |
| `body` 能解析成 `wist_contracts::host_flow::HostFlowRecord` | `body is not a HostFlowRecord: <err>` |
| `record_schema == "wist.host_flow/v1"`（未知版本**整条拒**） | `unsupported record_schema <x>` |
| 信封 `agent` 与正文 `collector_instance_id` 一致 | `envelope agent disagrees with collector_instance_id` |
| `store.get_agent(agent)` 存在且未吊销 | `unknown agent_id` / `agent is revoked` |
| 数据面 `tenant_id` 非 `unbound` 时必须等于登记表 `tenant_id` | `tenant mismatch: data plane <a>, registry <b>` |

`cust_id = agent.tenant_id`（= evidence 的 `tenant_id` = 对象键第一段，三者是同一个值）。

### 4.3 响应

```json
{"ingested": 128, "rejected": 0, "failures": []}
```

- 全部成功 → **202**；
- 有失败 → **400** + 逐条 `record #n: <detail>`。**故意不回 2xx**：wparse 的 http sink
  对非 2xx 会重试并落 rescue（可见），回 202 会让记录静默消失。

### 4.4 限额

| 项 | 值 |
|---|---|
| body 上限 | 4 MiB（一拍 4096 条 × ~700B ≈ 2.8 MB；留一倍余量） |
| 单次最多记录数 | 4096（超过 400，让数据面调小 `batch_size`，不要悄悄截断） |
| 超时 | 5s（与 facts 一致） |

### 4.5 数据面配置（`wist-gateway-stack`）

`sinks/business.d/agent_flows.toml` 加第二个 sink，写法照 `22-gateway_facts_sink.toml`：

```toml
[[sink_group.sinks]]
name = "http-gateway"
connect = "gateway_flows_sink"
# 与 facts 不同：流记录**不重发**（窗口事实，agentd 已经发完），rescue 堆起来没有意义。
# 丢的批次仍可从同分组的 file sink（agent-flows.jsonl）补投。
drop_when_error = true
tags = ["sink:gateway"]

[sink_group.sinks.params]
endpoint = "${WPARSE_GATEWAY_ENDPOINT}/api/v1/ingest/agent-flows"
batch_size = 64          # 先小批量跑通链路；吞吐上来再调
```

## 5. 存储：`flow_window`

### 5.1 DDL（`wist-evidence/migrations/0003_flow_window.sql`）

```sql
-- 主机流记录的**运行时观测表**（不是证据产物：一条几十字节、一天上百万条）。
-- 保留期靠分区 drop（见 5.3），幂等靠业务键 upsert（见 5.2）。
create table if not exists flow_window (
  tenant_id             text        not null,
  collector_instance_id text        not null,
  ifname                text        not null,
  direction             text        not null,   -- in | out
  protocol              text        not null,   -- 6 | 17 | 1 | 58
  srcaddr               text        not null,
  srcport               text        not null,
  dstaddr               text        not null,
  dstport               text        not null,
  icmp_type             text        not null default '',
  icmp_code             text        not null default '',
  window_start          timestamptz not null,   -- 记录里的 start（Unix 秒 → timestamptz）
  window_seconds        integer     not null,
  host_id               text        not null,
  host_name             text,
  ifindex               integer     not null,
  if_mac                text,
  local_addrs           jsonb       not null default '[]'::jsonb,
  kernel                text,
  packets               bigint      not null,
  bytes                 bigint      not null,
  wire_bytes            bigint,                 -- 当前恒 null（基线内核没有 wire_len）
  skb_count             bigint,
  gso_skb_count         bigint,
  truncated             boolean     not null default false,
  dropped               integer     not null default 0,
  partial               boolean     not null default false,
  partial_reason        text,
  coverage              text        not null,
  source                text        not null,
  capture               text        not null,
  ingested_at           timestamptz not null default now(),
  -- 幂等键：与记录规范 §7 逐段对应（icmp 用 '' 占位以参与唯一约束）
  unique (tenant_id, collector_instance_id, ifname, direction, protocol,
          srcaddr, srcport, dstaddr, dstport, icmp_type, icmp_code, window_start)
) partition by range (window_start);

-- 查询路径
create index if not exists flow_window_host_time on flow_window (tenant_id, host_id, window_start desc);
create index if not exists flow_window_src_time  on flow_window (tenant_id, srcaddr, window_start desc);
create index if not exists flow_window_dst_time  on flow_window (tenant_id, dstaddr, window_start desc);
```

分区由写入端按 `window_start::date` **按需创建**（`create table if not exists ... partition of`），
不需要预建未来分区；保留作业只需要 drop 过期分区。

### 5.2 写入（`POST /internal/flows`，evidence 写端口）

```json
{"cust_id": "c-001", "records": [ { ...HostFlowRecord... } ]}
```

- 单条 SQL 批量 upsert：
  `insert ... on conflict (...) do update set packets=excluded.packets, bytes=excluded.bytes, ...`；
- **last-write-wins**：同键同窗口的重发覆盖（不累加 —— 记录里是窗口聚合值，不是增量）；
- 响应 `{"accepted": n, "partitions_created": m}`；任一条约束不满足 → 400（不静默跳过）。

### 5.3 保留

- 默认 **30 天**（每客户可调，后续放 evidence 的客户配置）；
- 作业：每天 `drop table flow_window_<date>`（分区名带日期，扫描 `pg_class` 即可，不需要计数）；
- 不做行级 delete、不做 `vacuum` 调优以外的动作。

## 6. 幂等与重放

| 场景 | 结果 |
|---|---|
| wparse 重试同一批 | 业务键相同 → upsert 覆盖，行数不变 |
| 从 `agent-flows.jsonl` 补投（**这里没有工具，见 §10**） | 同上 |
| agentd 重启后窗口重新开始 | `window_start` 不同 → 新行（本来也是新窗口） |
| 同一窗口被 `partial` 截断后再发一条完整窗口 | **不会发生**：一个键一个窗口一条记录（agentd 侧保证，`partial` 只是标注） |

## 7. 查询（`wist-field-api`）

```text
GET /api/flows?host_id=&since=&until=&peer=&direction=&protocol=&limit=&cursor=
  → { rows: [{ host_id, direction, protocol, srcaddr, srcport, dstaddr, dstport,
               window_start, window_seconds, packets, bytes, truncated, partial_reason }],
      next_cursor }
GET /api/flows/peers?addr=&since=&until=
  → { hosts: [{ host_id, direction_in, direction_out, bytes_in, bytes_out }] }
   # 「谁连过这个 IP」：按 dstaddr 查入站、按 srcaddr 查出站，两侧分别聚合
```

- 只读、无任意 SQL；租户与 scope 闸在 BFF（与 `/api/evidence` 同一套）；
- 默认 `limit = 500`，最大 5000；时间范围默认最近 1 小时、最长 31 天；
- **不做实时**：数据延迟 = 数据面 batch（≤ 300ms）+ 网关→evidence 一跳。

## 8. 失败与对账

| 失败 | 可见性 |
|---|---|
| 网关端点不可达 / 5xx | wparse 记 `drop_when_error`（本批不落 rescue）+ 日志；`agent-flows.jsonl` 仍有同一批（**底账**） |
| 网关 400（逐条校验失败） | 同上；失败明细进网关日志与 `ingest_rejected_total` |
| evidence 写失败 | 网关回 400 → 同上链路 |
| 数据面压根没收到帧 | agentd 侧 `flows.status`（`sent` / `filtered`）+ 网关 `ingest_accepted_total` |

**对账口径**（现场排查第一条）：`agent-flows.jsonl` 的行数 vs PG 行数（按 `host_id` + 时间窗），
差值只应来自 `drop_when_error` 与保留期。

## 9. 上线顺序

1. **wist-evidence**：`0003_flow_window.sql` + `POST /internal/flows`（先不接网关也能用 curl 灌数据）；
2. **wist-field-api**：`/api/flows` 只读接口（没有写入也能先上，返回空）；
3. **wist-gateway**：`/api/v1/ingest/agent-flows`（先只做校验与日志、不转发，用于验证数据面真的在推）；
4. **wist-gateway-stack**：`agent_flows.toml` 加第二个 sink，`batch_size = 64`；
5. **网关 → evidence 的地址 + 凭据**：写端口是明文内网可信（evidence P0），跨区连通性按现场部署定。

旧 agent / 旧数据面不受影响：没有这个 sink 时，`agent-flows.jsonl` 照常落。

## 10. 待定

| # | 问题 | 建议 |
|---|---|---|
| 1 | 保留期默认值 | 30 天；先在 `evidence` 客户配置里留口子 |
| 2 | 是否需要 `agent-flows.jsonl` **回灌**工具 | 需要（否则 `drop_when_error` 丢的批次只能手工 SQL）；做成 `wist-evidence` 的一个 CLI 子命令 |
| 3 | 网关→evidence 的租户校验 | 网关已按登记表补 `cust_id`，evidence 侧只做存在性检查；P1 上 mTLS 后改为双向 |
| 4 | 跨区连通 | gateway 在接入区、evidence 在计算区：按现场走 VPN/专线，不加公网暴露 |
| 5 | 冷备（D3）要不要在 P0 做 | 建议 P1 —— 底账已经在网关本地 jsonl |

## 11. 验收

- [ ] 一条 `FLOW` 帧从 agentd 出发，经 wparse → 网关 → evidence，能在 `flow_window` 查到同一行；
- [ ] 同一批重发 3 次，行数不变（幂等）；
- [ ] `icmp` 记录的 `srcport/dstport = '0'`，`icmp_type/code` 进库并能按类型筛；
- [ ] 保留作业 drop 掉昨天以前的分区后，查询仍正常；
- [ ] 只有主机来源时，atlas 的拒绝类视图显示"不覆盖"而不是 0；
- [ ] 网关停掉后，`agent-flows.jsonl` 仍有数据，且对账能算出缺口。
