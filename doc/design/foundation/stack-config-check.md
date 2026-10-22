# 栈级配置检查（`wist-stackcheck`）

> **状态**：已实现（`wist-gateway-stack` 0.2.5-alpha 起发布）；本文是**跨栈约定**，
> 供 `wist-center-stack` 对齐。
> **实现**：`wist-dev-gateway/wist-gateway-stack/tools/stackcheck`（Rust，lib + bin）
> + `scripts/check-stack.sh`（薄壳）。
> **关联**：[`config-and-state-layout.md`](./config-and-state-layout.md)（配置四类内容与落点）、
> [`layered-config-recipe.md`](./layered-config-recipe.md)（`toml` 声明 + `.env` 值）、
> [`upgrade-order.md`](./upgrade-order.md)（升级序）。

## 1. 要解决的问题

部署栈的故障里，**绝大多数不是组件写错了，而是「配置错了但不报错」**：解析通过、进程起来、
状态上报正常，只有真正用到那一项时才炸，而且报错点离根因很远。以下是三条真实事故：

| 现象 | 根因 | 发现时机 |
|---|---|---|
| 每个 `push-agent-package` 计划都以「未配置 `agent_package_drop_dir`」失败 | 两个键被渲染在 `[[upgrade.component]]` **之后**，按 TOML 规则归属最后一个 component 表 | 计划派到网关才失败 |
| 知识库导入 422 `package_signature_invalid` | `packages/` 里只有 `.tar.gz`，没有同名 `.sig` | 点「录入」才失败 |
| 脚本 POST 到 `https://gw.example.com` | 渲染值 `public_base_url` 只在**新建**时写，域名改了不落盘 | 无人发现，直到某个脚本超时 |

三者共同点：**栈自己生成的配置互相矛盾，但没有任何一层在「写入后、使用前」检查它。**

## 2. 边界：栈查什么，组件查什么

这是本文最重要的一条，也是复用给 center-stack 的前提。

| 谁生成 | 谁校验 | 例子 |
|---|---|---|
| **栈**：模板渲染、变量解析、目录与挂载约定、投放包、版本口径 | **栈检查器** | 键落在哪个 TOML 段、`/packages/agents` 是否自洽、`.sig` 是否配对 |
| **组件**：自己的配置键语义（取值范围、依赖关系） | **组件自己** | `deny_unknown_fields` + 组件 `diagnose`（endpoint 有没有 scheme、token 长度） |

理由：**只有组件知道自己的键是什么意思**。栈去猜就会漂移；组件去查栈的目录约定又看不到全局。

推论（很重要）：

- 检查器**不需要**理解业务语义，所以它可以是**只读**的——不改盘、不 chmod、不重启。
- 需要 TOML 语义的两类问题里，「键属于哪个结构体」留给组件的严格解析；
  检查器只判「键是否在**文档根**」（因为那是栈的模板写错了）。

## 3. 判据清单（17 项）

全部只读。列「分级」为**失败时的等级**；「阻断」表示是否让 `--gate` 拒绝继续（见 §6）。

| code | 读什么 | 判据 | 分级 | 阻断 |
|---|---|---|---|---|
| `package.drop_dir` | `configs/gwlinkd/gwlinkd.toml` | `agent_package_drop_dir` 在**文档根**、是绝对路径、等于 `<PACKAGE_DIR>/agents`；若不在根则**指出真实段路径** | FAIL | ✓ |
| `package.container_dir` | 同上 | 等于 `<GWLINKD_AGENT_PACKAGE_CONTAINER_DIR>/agents` | FAIL | ✓ |
| `package.compose_mount` | compose | 存在 `${PACKAGE_DIR}:<target>` 挂载，且 `<target>` 与容器基址同源（短语法与长语法都认） | FAIL | ✓ |
| `render.freshness.{gwlinkd,gateway,web}` | 渲染产物 + 值文件 | 产物 mtime **不早于**值文件（= 改了值没重渲）；值文件在而产物缺失报 WARN | FAIL/WARN | ✓/✗ |
| `render.placeholder` | 6 个渲染产物 / 现场态文件 | 不含 `example.com` / `CHANGEME`；一个文件都没扫到时**报 WARN 而不是 OK** | FAIL | ✓ |
| `secret.file_mode` | `.wist/sec-value.yml` | 不得有其他用户位（`mode & 0o007`）；属组可写报 WARN；文件缺失 = FAIL | FAIL | ✓ |
| `secret.private_key_mode` | `identity/` 下按**内容**识别（含 `PRIVATE KEY`） | 私钥不得 world 可读 | FAIL | ✓ |
| `package.knowledge_signature` | `packages/wist-knowledge-*.tar.gz` | 配了验签公钥时，**最新**那个包必须有同名 `.sig` | FAIL | ✗ |
| `package.knowledge_signature.history` | 同上 | 历史包缺签名只计数 | WARN | ✗ |
| `package.knowledge_signature.orphan` | 同上 | 有 `.sig` 找不到对应的包 | WARN | ✗ |
| `identity.signing_pubkey` | `wist-gateway.value.json` | 配了 `knowledge_signing_pubkey` 就必须在候选落点之一存在 | FAIL | ✗ |
| `identity.gwlinkd_paths` | `gwlinkd.toml` + `identity/gwlinkd/.env` | `state_dir` / `identity_dir` / `GWLINKD_TRUST_BUNDLE` 指向的路径存在 | WARN | ✗ |
| `knowledge.initial_layout` | `configs/gateway/knowledge/initial/` | 五份数据文件齐全（缺 → FAIL；目录整体不在 → WARN） | FAIL/WARN | ✓/✗ |
| `tls.san_covers_domain` | `[server] tls_cert_file` | 证书在有效期内，且 SAN **精确**覆盖 `WEB_DOMAIN`（`*.a.b` 只覆盖一层） | FAIL | ✓ |
| `port.available` | compose + docker | 排除**本栈自己**已发布的端口后，其余端口能被 bind | FAIL | ✓ |
| `image.reachable` | compose + docker | 本地已有则直接通过；否则并行取 manifest（每 6s 超时）；离线收敛成一条 WARN | WARN | ✗ |

### 几处判据为什么这样定

- **「阻断」不等于「严重」**：知识库包缺 `.sig` 与验签公钥丢失都是 FAIL（该修），但**不该拦住升级**
  ——当前跑着的栈是好的，只是「以后导入」会失败。阻断类只放会让本次部署直接坏掉的项。
- **`port.available` 必须排除本栈自己**：升级的 `localize` 阶段容器正在跑，不排除就是每次误报。
  认「自己」用 compose **项目名**（`com.docker.compose.project`），**不用** `project.working_dir`
  ——栈目录搬过位置后，仍在跑的容器带的是旧路径标签。
- **`tls.san_covers_domain` 不能用子串匹配**：`init-gateway.sh` 原来用
  `openssl x509 … | grep -q "DNS:${domain}"`，正则里 `.` 是通配符且整体是子串匹配，
  证书 SAN 为 `gw.example.com.evil.net` 时也会判过。
- **`render.freshness` 是启发式**（mtime），已知误报：手工改了值文件里**主配置并不引用**的字段。
  见 §10。

## 4. 变量来源：生效值，不是默认值

**这条是踩出来的，必须写进任何移植方案。**

| 文件 | 内容 | 谁写 |
|---|---|---|
| `sys/merged_vars.yml` | **INITIAL（默认值）** | 仓里维护，随制品发布 |
| `sys/setting/vars.yml` | 变量声明（默认值来源） | 仓里维护 |
| `values/<system>/*.yml` | 现场覆盖 | 部署方 |
| **`.env`（栈根）** | **EFFECTIVE（生效值）** | `gops sys localize` 生成 |

检查器必须读 `.env`；只有它不存在（首次部署、还没 localize）时才回落 `sys/merged_vars.yml`，
并在结果 detail 里**标明来源**。

反例（真实）：某站点把 `PACKAGE_DIR` 覆盖成 `/data/packages`，而检查器读默认值
`./packages`，于是「投放目录不一致」永远 FAIL —— 而这项是**阻断类**，等于闸门把所有升级拦死。

## 5. 输出契约

对齐 `gops run diagnose` 的 **Flow Result v1**（`galaxy-ops/docs/design/run-diagnose.md` §6）：

```json
{
  "schema_version": "1",
  "source": "diagnose",
  "checks": [
    {
      "code": "tls.san_covers_domain",
      "status": "fail",
      "blocking": false,
      "title": "叶证书 SAN 不覆盖 WEB_DOMAIN",
      "detail": "WEB_DOMAIN=… 证书 SAN=[…]",
      "hint": "跑一次 `gops sys localize`"
    }
  ]
}
```

- `blocking` 是**扩展字段**（gops 按 key 读取、不认识就忽略），表示「该修，但不该拦升级」。
- 同一次运行内 `code` **不得重复**（gops 的 `merge_flow_result` 会因此**整份拒收**）——
  因此写结果文件时按 code 去重。
- 结果文件**追加**而非覆盖：一个 flow 里可以有多个诊断动作，谁都不该吞掉前面那份。

## 6. 运行模式与退出码

| 模式 | 触发 | 退出码 |
|---|---|---|
| **闸门** `--gate` | `flow localize` 末尾 | 有**阻断类** FAIL → 2，否则 0（WARN 与非阻断 FAIL 都放行） |
| **结果文件** | 设置了 `GOPS_DIAGNOSE_RESULT` 或 `--result` | 始终 0，结论在 `checks[]` |
| **普通** | 手工运行 | 0 全好 / 1 有 WARN / 2 有 FAIL |

优先级固定为 **闸门 > 结果文件 > 严重度**。原因：若环境里恰好有 `GOPS_DIAGNOSE_RESULT`，
「结果模式始终退 0」会把守门**完全绕过**（这条是审阅时发现的真缺陷）。

`--offline` 或 `STACKCHECK_OFFLINE=1` 跳过镜像可达检查（离线站点）。

## 7. 调用点

全仓只有三处直接调用（都走同一个薄壳 `scripts/check-stack.sh`）：

```
sys/workflows/operators.gxl    flow localize   →  ./scripts/check-stack.sh --gate
sys/workflows/operators.gxl    flow diagnose   →  ./scripts/check-stack.sh          （追加 checks）
scripts/restore-gateway.sh     还原完成后      →  ./scripts/check-stack.sh          （只读自检）
```

对应到命令：

| 命令 | 经过 | 作用 |
|---|---|---|
| `gops run diagnose` | `flow diagnose` | 全量体检（17 项） |
| `gops sys localize` | `flow localize` | 渲染完立刻守门 |
| **`gops prj upgrade`** | `apply → regenerate`（= `gops sys localize`） | **新配置渲染后、`pull`/`up` 之前**拦截；失败触发 `rollback-all` |
| `scripts/restore-gateway.sh` | 还原后 | 把「文件写回去了但互相矛盾」当场报出来 |

> **注意（容易误解）**：`gops prj upgrade` 的 `diagnose` 步用的是**项目级**
> `project_diagnose`（values 目录 / `sys_models` 重名 / `contract` 齐备），**不跑**系统的
> `flow diagnose`。所以升级流水线里**只有 `regenerate` 这一段**是自动拦截。

## 8. 分发与执行

约束：栈制品是 `git archive` 出的**平台无关单包**，不能直接塞二进制。
做法：**多平台预编译件打进同一个包**。

```
<包根>/bin/<triple>/wist-stackcheck      # 3 个：x86_64/aarch64 linux-musl、aarch64 darwin
<包根>/scripts/check-stack.sh            # 按 uname 选一份
```

- CI 为三个 triple 交叉编译（linux-musl 用 `cross`），`tar -rf` 追加进**未压缩**的 tar，
  再 `gzip -9`。制品仍是「一个包、一个下载地址、一个 sha256」，**升级协议不变**。
- 单平台约 672 KB，整包 +约 2 MB。
- 薄壳行为：
  1. 找到对应 triple 的二进制 → 先跑 `--version` 自检（**架构不对时明确报错**，而不是只给 126/127）；
  2. 没有预编译件但仓里有源码 → 回落 `cargo run`（开发态）；
  3. 都没有 → **退出 2**。静默跳过等于检查没做，比不检查更危险。

## 9. 实现约束（移植时请一并遵守）

1. **只读**：不写盘、不改权限、不重启。写盘的动作留在 `scripts/init-*.sh`。
2. **词法归一**：路径比较去掉 `.` 分量，**不用** `canonicalize`（目标可能还不存在，
   而且要比的是「配置里写的那个路径」）。
3. **候选落点**：容器里 `/config/identity` 挂的是宿主 `identity/gateway`，
   所以同一个相对路径可能落在栈根 / `configs/<stack>/` / `identity/gateway/` 三处，都要认。
4. **外部命令只用于 docker**，且**必须可降级**：docker 不可用时报「无法判定」而不是误报；
   所有调用带超时（`docker manifest inspect` 在慢网络上实测 34s）。
5. **并行**：镜像探测并行执行，否则一个慢 registry 会把体检拖成几十秒。
6. **不做第二份真相源**：判据尽量复用配置里的原值，不要把 compose/vars 的内容抄一份常量。
7. **假绿比红更糟**：任何「没扫到 / 没比对」都要显式报 WARN，不能静默 OK。

## 10. 已知限制

- **`render.freshness` 用 mtime 启发式**：手工改了值文件里主配置并不引用的字段会误报。
  更准的做法是让 `gx.tpl` 在渲染时把「值文件摘要」写进产物旁边，用摘要比对替代 mtime
  —— 需要改 galaxy-flow，未做。
- **证书只判 SAN 与有效期，不验签发链**：`openssl verify`（脚本里）仍由
  `init-gateway.sh` 负责；两边判据不一致不会死锁（脚本会更激进地重签），但检查器漏报。
- **未检查 `sys/merged_vars.yml` 与 `sys/setting/vars.yml` 的漂移**（`gops sys update` 的职责）。
- **`port.available` 依赖 docker CLI**：容器运行时栈自己的端口会被整体跳过，
  所以这项主要在「首次部署 / 栈停着」时有价值。

## 11. 移植到 `wist-center-stack`

**当前实现里的路径是写死的（gateway-stack 专用）**，复用的正确做法是抽出 `StackProfile`，
而不是拷贝一份改字符串。

### 11.1 需要参数化的点

| 现在写死的 | 建议字段 |
|---|---|
| `configs/gwlinkd/gwlinkd.toml`、`configs/gateway/wist-gateway.toml` | `render_pairs: [{rendered, value_file, code_suffix}]` |
| `agent_package_drop_dir` / `agent_package_container_dir` | `drop_dir: Option<DropDirSpec { toml, keys, subdir }>`（center 没有 ②，设为 `None`） |
| `PACKAGE_DIR` / `GWLINKD_AGENT_PACKAGE_CONTAINER_DIR` | `package_dir_var` / `package_container_var` |
| `.wist/sec-value.yml` | `secret_files: Vec<PathBuf>` |
| `identity/` 私钥扫描 | `private_key_roots: Vec<PathBuf>` |
| `configs/gateway/knowledge/initial/` | `knowledge: Option<KnowledgeSpec { dir, files, signing_key }>` |
| `[server] tls_cert_file` + `WEB_DOMAIN` | `tls: Option<TlsSpec { toml, section, key, domain_var }>` |
| compose 文件名候选、项目名规则 | 已通用，无需参数化 |
| 端口 / 镜像 | 已通用（从 compose 读），无需参数化 |

### 11.2 center-stack 需要额外考虑

| 项 | 说明 |
|---|---|
| `configs/center/center.toml` | 对应 `render_pairs` 的一条 |
| `knowledge/` 与 `artifacts/` | 投放/内容目录的**自洽**：与 compose 挂载、与容器内路径 |
| 数据库 | **不要**把 schema/migration 放进检查器；最多判「数据目录存在且可写」 |
| `git-proxy` / `postgres` | 镜像可达与端口占用通用；注意 center 有多个 `127.0.0.1:` 绑定的端口 |
| 版本口径 | `version.txt` ↔ 运行容器镜像 tag（`version.consistency`，本实现尚未做） |

### 11.3 建议的落地顺序

1. 把 `StackProfile` 抽出来，让 gateway 用 profile 跑（**行为不变**，先加回归测试锁住 17 项）；
2. center 写自己的 profile，先只启用已通用的检查（compose 挂载、端口、镜像、secret 权限、TLS）；
3. 再按 center 的实际痛点补判据（内容目录自洽、artifact 目录、版本一致性）；
4. 两边**同一套输出契约**，`gops run diagnose` 天然聚合，管理面渲染不用写第二份解析。

## 12. 验收

- 单元测试 54 条（45 判据 + 9 CLI），覆盖：键落错段、渲染过期、占位值、缺签名、
  有效值优先、TLS 覆盖/不覆盖/过期、SAN 通配与后缀攻击、compose 备选文件名与长语法、
  端口冲突、离线收敛、结果文件追加与去重。
- 现场实测（`wist-gateway-stack` 0.2.5-alpha）：17 项 / 16 ok / 1 warn（历史知识库包缺 `.sig`）/ 0 fail，
  整次体检 **0.17 秒**（镜像走本地快路径）。
- 发版门禁：`gops sys localize` 与 `gops prj upgrade` 的 `regenerate` 阶段都会执行它。
