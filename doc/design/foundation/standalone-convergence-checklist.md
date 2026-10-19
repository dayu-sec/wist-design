# standalone 收敛核对清单

> 口径（2026-10-18 定）：`standalone`（无网关）= **不采、不缓、不发**。
> 本文只做一件事：把这句话拆成**可观测、可验收**的核对项，用来判断代码是否真的做到了。
>
> 跟踪 issue：`dayu-sec/wist-agentd#26`（实现收敛与验收均在该 issue 下勾选）。
>
> 相关文档：
> - [`architecture.md`](architecture.md) §4.3：运行模式边界
> - [`../../../wist/wist-agentd/docs/design/agentd-architecture.md`](../../../wist/wist-agentd/docs/design/agentd-architecture.md) §2.1 / §2.2：功能开关矩阵
> - [`../../../wist/wist-agentd/docs/design/agent-config-schema.md`](../../../wist/wist-agentd/docs/design/agent-config-schema.md) §4 / §7 / §8：配置生效范围

---

## 0. 怎么用

- 每一项 = **一个可观测判据** + **验收方式** + **现状**；
- 现状只用三种：`✅ 已符合` / `⚠️ 需改` / `❓ 需拍板`；
- A–F 全部 `✅` 才算收敛；`❓` 必须先有结论再动手；
- 核对顺序建议：先跑 `diagnose` 看现象，再对代码，再补测试。

---

## 1. 先钉住三个状态

不要把「没有网关」和「网关暂时连不上」混成一个。

| 状态 | 触发条件 | 数据面 | 本地执行 |
|---|---|---|---|
| `standalone` | `[control_plane] enabled = false` | **不采、不缓、不发** | 状态机 + 本地触发执行 + 受限本地升级 |
| `managed` | `enabled = true`，且网关可达 | 采 / 缓 / 发 | 同上 + 远程任务 + 中心编排升级 |
| `managed` 断连 | `enabled = true`，网关暂不可达 | **继续有限采集 + spool**，受上限约束 | 同上 |

> 第三行是既有 spool / 断点续传设计的前提。如果把它也归进「不发」，spool 机制就失去意义。

---

## 2. 核对清单

### A. 启动与运行路径

| # | 核对项 | 判据 | 验收方式 | 现状 |
|---|---|---|---|---|
| A1 | 启动日志标明模式 | `mode=standalone` 出现在启动行 | 启动一次看日志 | ✅ |
| A2 | 主循环不启动发现 | `standalone` 下不构造 `DiscoveryRuntime` | 代码：`run_forever_async` | ⚠️ 当前无条件构造（`daemon.rs:946`） |
| A3 | 单次运行同样不启动 | `WIST_AGENTD_RUN_ONCE=1` 下不跑 discovery / telemetry | 代码：`run_once_with_work_async` | ⚠️ 当前无条件构造（`daemon.rs:2086`） |
| A4 | 不采集日志 | 跑 N 个 tick 后，源文件无读取、`state/logs/file_inputs` 无推进 | 造一个持续写入的文件，跑 5 分钟 | ⚠️ 取决于 A2/A3 |
| A5 | 不缓冲 | `spool_dir` 下不出现新的 `*.ndjson` | 直接看 spool 目录 | ⚠️ 取决于 A2/A3 |
| A6 | 不输出 | `output.kind = file` 时 `data/` 不增长；`tcp` 时目标端无连接 | 看文件 / 抓包 | ⚠️ 取决于 A2/A3 |
| A7 | 本地执行仍可用 | 本地 CLI 触发一次执行，状态机正常推进 | 手工触发 + 看 `state/` | ✅ |
| A8 | 单实例保护仍生效 | 第二个实例启动被 flock 拒绝 | 起两个进程 | ✅ |

### B. 配置与校验

| # | 核对项 | 判据 | 验收方式 | 现状 |
|---|---|---|---|---|
| B1 | standalone 下 telemetry 配置「不生效但不报错」 | 写了 `[telemetry.logs]` 仍能启动 | 改配置启动 | ⚠️ 当前仍会做完整校验 |
| B2 | 校验不因模式误拒 | `standalone` 下不因 `missing_logs_output_kind` / `missing_logs_output_tcp_addr` 等拒绝启动 | `validate_config` | ⚠️ 当前无条件校验（`validate.rs:10-55`） |
| B3 | discovery 全关不被拒 | `standalone` 下五个开关全 `false` 不应报 `missing_discovery_probe` | 改配置启动 | ❓ 需拍板：整段不生效，是否仍要求「至少一个探针」 |
| B4 | 默认模板可直接 standalone 启动 | 模板 `enabled = false` + 注释掉的 control_plane 可启动 | `init-config` 后直接跑 | ✅ |
| B5 | 有明确提示 | standalone 下写了采集配置，启动时一行 `WARN`（不是 `FAIL`） | 看日志 | ⚠️ 当前无此提示 |

### C. 输出与缓冲

| # | 核对项 | 判据 | 验收方式 | 现状 |
|---|---|---|---|---|
| C1 | 输出决策纳入模式 | `effective_output` 在 standalone 下直接返回 `enabled = false` | 代码：`daemon_telemetry_support.rs:38` | ⚠️ 当前只看本机配置 + grant，不看模式 |
| C2 | 不因缺 grant 回落本机输出 | standalone 下不能出现「没有授权 → 按本机配置走」 | `diagnose` + 代码 | ⚠️ 当前会回落 |
| C3 | spool 回放不运行 | standalone 下不调用 `replay_spool_only` | 代码路径 | ⚠️ 取决于 A2 |
| C4 | spool 目录不增长 | 连续运行后目录为空 | `du -sh` | ⚠️ 取决于 A5 |

### D. 自诊断

| # | 核对项 | 判据 | 验收方式 | 现状 |
|---|---|---|---|---|
| D1 | 控制面 WARN 文案完整 | 明确说「也不会采集 / 缓冲 / 上送」 | `diagnose` 文本 | ⚠️ 当前只说「不注册、不上报、拿不到工作」（`doctor.rs:406-410`） |
| D2 | standalone 下不报 uplink 结论 | `uplink.effective` / `uplink.target` / `uplink.spool` 不出现「按本机配置走」 | `diagnose` 输出 | ⚠️ 当前无条件执行（`doctor.rs:294-307`） |
| D3 | 四态可区分 | `standalone 不采` / `managed 待命` / `managed 已授权` / `managed 断连` 各有独立文案 | 四种配置各跑一次 | ⚠️ 当前没有 standalone 态 |
| D4 | `--offline` 一致 | 离线诊断与在线诊断的 standalone 结论一致 | 两种方式各跑一次 | ⚠️ 取决于 D2 |
| D5 | 退出码不误报 | standalone 是受支持模式，不应因此产生 `FAIL` | 看退出码 | ✅（当前是 WARN） |

### E. 文档与代码注释

| # | 核对项 | 判据 | 现状 |
|---|---|---|---|
| E1 | 设计文档口径一致 | `architecture.md` / `target.md` / `security-model.md` / `roadmap.md` 不再出现「standalone 跑数据面」 | ✅ 已统一 |
| E2 | agentd 架构的「实现对齐」注 | 收敛后删除或改成「已对齐」 | ⚠️ 保留中 |
| E3 | `telemetry/logs/mod.rs` 文件头 | 「for standalone replacement」改名 | ⚠️ `mod.rs:1-2` |
| E4 | `telemetry/logs/files/file.rs` 文件头 | 「End-to-end standalone file-input processing.」改名 | ⚠️ `file.rs:1` |
| E5 | 配置测试注释 | 「dev / standalone 不受影响」需改为「dev 不受影响；standalone 不采」 | ⚠️ `agent_config.rs:471-477` |
| E6 | 用户文档 | README / 安装手册 / 发日志指南已说明 | ✅ |

### F. 测试

| # | 核对项 | 判据 | 现状 |
|---|---|---|---|
| F1 | standalone 不产生数据 | 跑 N tick：无 spool 文件、无 file output、无 discovery 输出 | ⚠️ 缺 |
| F2 | standalone + 采集配置可启动 | 配置非法程度只到 warning，进程仍起得来 | ⚠️ 缺 |
| F3 | managed 断连仍 spool | 防止把「断连」误判成 standalone | ⚠️ 缺（建议补，保护既有语义） |
| F4 | `diagnose` 四态 | 四种状态各一条断言 | ⚠️ 缺 |
| F5 | 现有测试注释 | `an_output_section_without_enabled_is_on` 的说明与新口径一致 | ⚠️ 需改 |
| F6 | e2e | standalone 起进程 → 写日志 → 断言零记录 | ⚠️ 缺 |

---

## 3. 代码事实（核对依据）

| 事实 | 位置 |
|---|---|
| 主循环无条件构造 `DiscoveryRuntime` | `src/runtime/daemon.rs:946`（`run_forever_async`） |
| 单次运行同样无条件构造 | `src/runtime/daemon.rs:2086`（`run_once_with_work_async`） |
| 配置校验没有模式闸门 | `src/config/validate.rs:10-55` |
| 输出决策只看本机配置 + grant | `src/runtime/daemon_telemetry_support.rs:38-66`（`effective_output`） |
| `diagnose` 无条件跑 uplink 检查 | `src/doctor.rs:277-314` |
| bootstrap 不创建 spool 目录 | `src/bootstrap/mod.rs:15-49` |
| 控制面未启用的 WARN 文案 | `src/doctor.rs:406-410` |
| 文件尾注释仍写 standalone | `src/telemetry/logs/mod.rs:1-2`、`src/telemetry/logs/files/file.rs:1` |

---

## 4. 完成定义

- A–F 全部 `✅`，`❓` 全部有结论；
- `cargo test` 全绿；
- 手工验收一次：`standalone` 连续运行 ≥ 5 分钟，满足：
  1. `spool_dir` 为空；
  2. `data/`（file output）无增长；
  3. 数据面目标端无连接；
  4. `wist-agentd diagnose` 明确报「standalone：不采集、不缓冲、不送」且退出码为 0；
- `managed` 断连场景单独验收一次：仍产生 spool，且受 `spool_max_bytes` 封顶。

---

## 5. 建议的落地顺序

1. **C1 + A2/A3**：先加模式闸门（一处判定，主循环与单次运行共用），这是所有「不采 / 不缓 / 不发」的根；
2. **B1/B2/B3**：校验按模式分流（先拍板 B3）；
3. **D1/D2/D3**：诊断四态；
4. **F1–F6**：补测试并把注释改掉；
5. **E2**：删掉「实现对齐」注。
