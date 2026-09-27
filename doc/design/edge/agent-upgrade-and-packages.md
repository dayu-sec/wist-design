# Agent 升级与安装包（来源 → 网关托管 → 升级选包）

## 1. 要解决的问题

一次真实的失败升级（agentd 侧 `state/upgrade.json`）：

```
step   = fetch
status = failed
detail = package_unavailable: read /Users/…/wist-agentd/target/package/wist-agentd-0.1.9-aarch64-apple-darwin.tar.gz: No such file or directory
```

三件事凑在一起，缺一件都走不通：

1. **升级计划里的包地址是被逐台解释的**。运维填的是**开发机上的本地路径**，每台目标机去读**自己**的这个路径 —— 读不到。
2. **网关其实早就能托管包**：安装那条路（录入「安装包来源」→ 网关把制品拉进自己的包目录 → 对外只给网关地址）就是它。但**升级这条路没接**，让运维在升级页又手输了一遍，于是本地路径原样进了计划。
3. **就算把地址写成网关地址，也取不到**：包下载口只认「装机器用的 **bootstrap token**」，而要升级的机器早把它用掉了、手里只有自己的身份凭证；升级器取包时**也不带任何凭据** ⇒ 401。

## 2. 三层地址（核心概念）

| 层 | 是什么 | 谁定 |
|---|---|---|
| **来源**（source） | 新包在**哪**：本机绝对路径 或 https URL | 人（**填本机路径是允许且常见的**：包可能就在网关机上、外网访问不到、或还在开发） |
| **网关托管** | 网关把来源读进**自己的包目录**，每个包一份副本 | 网关 |
| **下发地址** | `<网关对外地址>/api/v1/agent/packages/<包 id>` | 网关**派生**（前端不自己拼） |

要点：**来源可以是本机路径，但下发给 agent 的永远是网关地址** —— 所以「本地路径」不会漂到别的机器上去。

## 3. 方案（四条）

1. **录入即存档 + 历史**。`POST /api/v1/admin/agent/install-package`（已有）在原有行为之外**追加**一条历史记录（内容寻址，`package_id = pkg-<sha256 前 16>`），并**为这个包单独存一份副本**在网关。
2. **升级从历史里选一个**。`GET /api/v1/admin/agent/install-packages` 列出历史（版本 / 架构 / 来源 / **可直接下发的网关地址**）；升级页做成选择器，**不再手输**；所选条目的网关地址 + 摘要进 spec。
3. **允许降级（显式）**。升级 spec 新增可选 `allow_downgrade`。默认 `false` = 只允许更新（升级器报 `not_newer`）；`true` 才放行**同版本 / 降级**。
4. **取包鉴权**。包下载端点接受 **bootstrap token 或已注册 agent 的凭据**；升级器取 https 包时带上 agent 凭据。

## 4. 清单

### 迁移（`wist-gateway/migrations/sqlite/0016_agent_install_package_history.sql`）

| 列 | 说明 |
|---|---|
| `package_id` | 主键，内容寻址 `pkg-<sha256 前 16>`（同一个包重复录入 = 同一行，**不重复存副本**） |
| `source` | 原始录入（`/abs/path` 或 `https://…`）；只作留痕 |
| `package_sha256` | 网关据自己缓存的那份字节算，`sha256:<64 hex>` |
| `version` / `arch` | 读自包内目录名；读不到留空 |
| `cached_path` | 网关自己存的那份副本 |
| `created_by` / `created_at` | 谁录的、何时 |

### 接口（`wist-gateway`）

| 端点 | 说明 |
|---|---|
| `POST /api/v1/admin/agent/install-package` | **已有**；现在**顺带**存一份副本 + 记一条历史 |
| `GET /api/v1/admin/agent/install-packages` | 新增：列出历史（含 `agent_package_url`） |
| `GET /api/v1/agent/packages/{package_id}` | 新增：按条目下载；鉴权 = bootstrap token **或** agent 凭据 |
| `GET /api/v1/agent/packages/current` | **已有**；鉴权同样放宽（安装/升级同一份包，语义一致） |

### agentd（`wist-agentd`）

- `UpgradeSpec` / `UpgradeRequest` 新增 `allow_downgrade`；`validate_request` / `resolve_target_version` 里 `ensure_newer` 改由该开关守卫（默认路径不变）。
- `fetch_package` 走 https 时附 `Authorization: Bearer <agent 凭据>`；本地路径分支不变。
- `wist-upgrader` 新增 `--allow-downgrade`（分离进程是新的 argv 边界，标志必须显式传）。

### web（`wist-gateway-web`）

- 升级页：包地址/摘要两个手输框 → **从历史选一个**；新增「允许降级」开关；历史为空时给「去 Gateway 初始化页录来源」的指引并禁用提交。
- 列表页的「安装包」列由 `agent_package_url` 反查版本/架构。

## 5. 边界与取舍

- **内容寻址**：同一个包重复录入落在同一行（副本不翻倍）；代价是「同一个包每次录入的时间」不分别留痕。
- **版本/架构读不出来不失败**：裸二进制、非标准包 → 留空，历史行照记（source + sha256 仍有用）。
- **失败不写历史**：来源读不到（路径不存在 / URL 拉不到 / 摘要不符）时**不留**历史行、不动已有设置（沿用原有语义）。
- `/current` 放宽到「bootstrap token 或 agent 凭据」：安装包不是秘密（`install.sh` 里就带地址与摘要），而取包的机器都已被网关认证过。若日后要收紧，改动隔离在 `download_agent_package` 一处。
- **降级默认拒绝**：显式声明才降 —— 免一次误填把机器降回旧版；降级同样没有额外回滚保护（机器上原本怎么升的，就怎么降）。
- **凭据只在 state，升级器要自己注入**：`bearer_token` **从不写进 `agentd.toml`**（见默认模板注释），只落在 `state/agent_runtime.json`；daemon 启动时经 `ensure_enrolled_*` 注入。而**升级器是独立进程**，只 `load_from_path` 会拿不到凭据 ⇒ https 取包发不出 `Authorization`（网关 401）。所以 `wist-upgrader` 加载配置后补调 `enrollment::restore_runtime_identity` 从 state 注入一次。

## 6. 代码对应

| 侧 | 位置 |
|---|---|
| 迁移 | `migrations/sqlite/0016_agent_install_package_history.sql` |
| 存储 | `src/infra/store.rs`（`StoredAgentInstallPackage` + 三个方法）、`src/infra/sqlite_store.rs`、`src/infra/config.rs`（`install_package_history_path` / `agent_package_url_by_id_at`） |
| 网关取包/存档 | `src/api/install_package.rs`（`fetch_into_package_cache`、`package_id_for_sha256`、`read_package_identity`） |
| 网关端点 | `src/api/admin_ops.rs`（`set_agent_install_package` 顺带记历史、`list_agent_install_packages`）、`src/api/install.rs`（`authorize_package_download`、`download_agent_package_by_id`）、`src/api/agent_ops.rs`（`authenticate_agent_credential_token`）、`src/api/mod.rs`（路由） |
| agentd | `src/upgrade.rs`（`UpgradeSpec.allow_downgrade`、`fetch_package` 带凭据）、`src/runtime/daemon.rs::dispatch_upgrade`、`src/bin/wist-upgrader.rs`（`--allow-downgrade`；加载配置后经 `enrollment::restore_runtime_identity` 从 state 注入凭据）、`src/control/enrollment.rs`（`restore_runtime_identity`） |
| web | `src/api/admin.ts`（`InstallPackageView` / `fetchInstallPackages` / `jsonUpgradeSpec.allowDowngrade`）、`src/hooks/index.ts`（`useInstallPackages`）、`src/components/SubsystemAgentUpgradePage.tsx` |
| 模型 | `runtime/subsystem/WistGateway/layout.agent-upgrade.mju`（`AgentUpgradeParamsFields` → `AgentUpgradePackageSelect` + `AgentUpgradeAllowDowngradeToggle`） |

## 7. 验收

1. 在「Gateway 初始化」页录入一个**本机路径**的包 → 历史里出现一条（版本/架构读出来了），且**网关存下了副本**。
2. 升级页能从历史里选到它；创建的计划里 `package_url` 是**网关地址**（不是那个本机路径）。
3. 待升级的机器**待命中/未派采集工作也能升级**（升级是一次性工作，不受上送闸门影响）。
4. 目标版本**更低**时：
   - 不勾「允许降级」 → 升级器报 `not_newer`，不换件；
   - 勾上 → 换件成功、重启、`wait_ready` 通过。
5. 取包：bootstrap token 与 **agent 凭据**都能下到；无凭据 401；未知 `package_id` 404。
6. 来源读不到（路径不存在 / URL 拉不到）→ 请求失败且**不留**历史行。

## 8. 遗留

- 历史没有「删除 / 过期」——旧包副本会一直留在网关（需要时再定清理策略）。
- 模型侧：**安装包历史的条目与列表用例尚未建模**，当前与其它管理面端点一样按「手加端点」处理（`impl/usecases.json`）。
