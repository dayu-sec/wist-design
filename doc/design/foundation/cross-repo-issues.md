# 跨仓 issue 清单

> 状态：**Open** — 跨仓库、无法在单一仓内闭环的问题集中记录在此。
> 每条给出：现象、证据（可点到的文件行）、影响、待决方向、验收。

---

## CR-001 进程 RSS 指标单位随平台漂移，消费侧按 KiB 直读导致量级偏大

**涉及仓**：`wist/wist-metrics`（生产者）/ `dayu-topology`（消费者）

### 现象

`process.memory.rss` / `container.memory.rss` 这**一个归一化指标名**，在 Linux 上由
procfs 采集，单位是**内存页（pages）**；在其它 unix 上由 `ps -o rss` 采集，单位是
**KiB**。两个来源平台互斥，因此同名指标的单位随平台变化。

### 证据

- 生产侧：`wist/wist-metrics/src/spec.rs`
  - L95-101：`process.memory.rss_pages` → `process.memory.rss`，`unit = "pages"`
  - L102-108：`process.memory.rss_kb` → `process.memory.rss`，`unit = "KiBy"`
  - L117-129：`container.memory.rss` 同样两组
  - `unit` 本身是规范字段（`MetricSpec.unit`），即单位是随指标一起下发的。
- 消费侧：`dayu-topology/crates/topology-api/src/service/materialize/telemetry.rs`
  - L60-64 与 L119-123：`"process.memory.rss" => process.memory_rss_kib = candidate.value_i64;`
  - 只按 `metric_name` 匹配，**完全不读 `unit`**，直接当作 KiB 存入 `memory_rss_kib`。
  - 佐证：`dayu-topology/crates/topology-api/src/service/tests/process.rs` L288-316，
    输入 `value: 7456` 不经换算即断言 `memory_rss_kib == Some(7456)`。

### 影响

Linux 主机（page size 通常 4 KiB，arm64 上可达 16/64 KiB）上 RSS 会被高估约
**4×**（或更多）。进程内存排行、容量判断据此失真。

### 为什么是跨仓

生产侧只要把两个来源归一化成同一个指标名就「看起来对」；消费侧只要按名匹配就
「跑得通」。任一侧单独看都不明显，只有把两侧契约对齐才暴露。因此必须跨仓决定。

### 待决方向（择一）

- **A 生产侧统一成字节/KiB**：Linux 采集时按 page size 换算（`rss_pages * page_size`），
  只保留一个单位。改动集中在 `wist-metrics`。
- **B 消费侧尊重 `unit`**：`dayu` 按 `unit` 换算到 KiB 后再入库（保留两来源）。改动集中在
  `dayu-topology`。
- **C 拆分指标名**：不再共用 `process.memory.rss`，改为带单位/来源的独立名。破坏性，
  需两侧同步改并迁移历史数据。

### 验收

- 明确选定 A/B/C 并记录。
- 新增一条跨侧用例：给定 Linux 侧 pages 值，最终 `memory_rss_kib` 等于**换算后**的 KiB
  （而非原值）；再补一条非 Linux 侧 KiB 值不变的用例。
