# 栈级配置检查（`wist-stackcheck`）

> **状态**：已实现，并已抽成共享引擎
> [`wist-stack-tools`](https://github.com/dayu-sec/wist-stack-tools) 的 `stackcheck-core`
> （crates.io `wist-stackcheck-core` 0.1.x；发布由 tag `v*.*.*` 的 CI 执行）。
> gateway 19 项 / center 15 项；两个栈只保留 profile + 专属判据 + 薄 main。
> 本文是**跨栈约定**。
> **实现**：`wist-stack-tools/stackcheck-core`（Rust lib）
> + `wist-dev-gateway/wist-gateway-stack/tools/stackcheck`
> + `wist-dev-center/wist-center-stack/tools/stackcheck`
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
| **环境**：宿主 PATH 里那些工具的能力（openssl 实现、python3 是否在） | **栈检查器（`prereq.*`）** | 升级由 gwlinkd 派生，`openssl` 解析到 LibreSSL 而不认 `x509 -ext` |

理由：**只有组件知道自己的键是什么意思**。栈去猜就会漂移；组件去查栈的目录约定又看不到全局。
而**环境**既不是栈生成的东西、也不是组件的事 —— 但它是「栈跑不跑得起来」的前提，只能是栈检查器管。

推论（很重要）：

- 检查器**不需要**理解业务语义，所以它可以是**只读**的——不改盘、不 chmod、不重启。
  （唯一例外：`prereq.tls_san_reader` 要起一个 `bash` 去跑随包脚本；它仍然不写盘。）
- 需要 TOML 语义的两类问题里，「键属于哪个结构体」留给组件的严格解析；
  检查器只判「键是否在**文档根**」（因为那是栈的模板写错了）。

## 3. 判据清单（22 项）

全部只读。列「分级」为**失败时的等级**；「阻断」表示是否让 `--gate` 拒绝继续（见 §6）。

| code | 读什么 | 判据 | 分级 | 阻断 |
|---|---|---|---|---|
| `prereq.toolchain` | 两份 `PATH` | `bash` / `openssl` / `python3` / sha256 工具都在；**当前** PATH 缺 = 后面必然失败，只有**守护进程的** PATH 缺 = 本机能跑但交给 gwlinkd 就炸 | FAIL/WARN | ✓/✗ |
| `prereq.tls_san_reader` | `[server] tls_cert_file`（或还没有证书） | 用**随包** `scripts/lib/tls-san.sh` 在两份 PATH 下各读一次 SAN；读不出 / **静默读空** 都算失败 | FAIL/WARN | ✓/✗ |
| `prereq.container_gid` | compose + `/proc/self/status` | 从**有 bind 挂载的非 root 服务**的 `user:` 派生容器 gid，当前进程的组里必须有（对应 `gops sys perms` 整片 `Operation not permitted`） | FAIL/WARN | ✓/✗ |
| `layout.bind_source_type` | compose 的 bind 挂载 + 宿主 | **文件类**挂载源（容器目标末段含 `.`，如 `*.pem` / `*.toml` / `*.conf`）在宿主上必须是文件；「源是目录、目标像文件」= 源文件曾缺失、被 docker 建成了目录。变量源（`${PACKAGE_DIR}`）与缺失源不在此判 | FAIL | ✓ |
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
| `identity.gwlinkd_paths` | `gwlinkd.toml` + `identity/gwlinkd/.env` | `state_dir` / `identity_dir` / `GWLINKD_TRUST_BUNDLE` 指向的路径存在（**相对路径按栈根解析**，不按进程 CWD） | WARN | ✗ |
| `identity.trust_anchor` | `identity/gwlinkd/.env` 的 `GWLINKD_TRUST_BUNDLE` | 文件不存在 → 放行（回落系统根）；**是目录**（docker 建的）或不是 `BEGIN CERTIFICATE` → FAIL。目录挡住的正是「CA 写回原位」 | FAIL | ✓ |
| `identity.trust_projection` | `identity/gwlinkd/{control-center.pem,trust/control-center.pem}` | 真身有可读 PEM 时，容器投影必存在且**逐字节相同**；真身没了但投影还在 = 陈旧。两头都没有 = 合法现场（公网 CA / 尚未接入中心） | WARN | ✗ |
| `knowledge.initial_layout` | `configs/gateway/knowledge/initial/` | 五份数据文件齐全（缺 → FAIL；目录整体不在 → WARN） | FAIL/WARN | ✓/✗ |
| `tls.san_covers_domain` | `[server] tls_cert_file` | 证书在有效期内，且 SAN **精确**覆盖 `WEB_DOMAIN`（`*.a.b` 只覆盖一层） | FAIL | ✓ |
| `port.available` | compose + docker | 排除**本栈自己**已发布的端口后，其余端口能被 bind | FAIL | ✓ |
| `image.reachable` | compose + docker | 本地已有则直接通过；否则并行取 manifest（每 6s 超时）；离线收敛成一条 WARN | WARN | ✗ |

### 几处判据为什么这样定

- **`prereq.*` 判的是「环境」，不是「配置」**：它们是唯一会 **spawn（`bash`）** 的判据。
  因为要判的恰好是「本机的 `openssl` 在**这份** PATH 下能不能干活」——用 Rust 自己解析 SAN
  会得出与脚本不同的答案，那就又回到「检查器说行、脚本说不行」。所以它们**执行随包脚本**。
- **为什么看两份 PATH**：升级流程由 `gwlinkd` 派生，它的 PATH 里没有 Homebrew 这类目录。
  2026-10-23 的事故就是这个差：同一份 `init-gateway.sh`，交互式跑得过、升级跑不过，而且**静默**
  （`set -e` + `pipefail`）。于是：当前 PATH 缺 → **阻断**（后面必然失败）；
  只有守护进程的 PATH 缺 → **WARN**（本机能用，不拦开发机）。
- **「静默读空」也要算失败**：老实现 `openssl x509 -ext | tr | sed` 在 LibreSSL 下 openssl 失败，
  但**管道退出码来自 `sed`** → helper 退出 0、输出为空。只看退出码会把事故判成 OK。
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
- **`layout.bind_source_type` 与 `identity.trust_anchor` 是同一起事故的两面**（2026-10-23）：
  `identity/gwlinkd/control-center.pem` 缺失时，docker 会**静默**把这条 bind 建成同名目录；
  wparse 容器把它当 `SSL_CERT_FILE`，构造 HTTP 客户端失败（`build victoriametric client failed`），
  容器重启 52 次。教训是：**「挂载源存在」不等于「挂载源是文件」** —— gops 的 `mount` 检查只看存在性，
  所以栈这一侧要自己判类型；同时「非 PEM 的信任锚」还要在**组件启动前**报，不能等它把容器拖进重启循环。
- **信任锚的三条结构契约**（比只加检查更重要）：
  1. 它是**可选输入**：公网 CA 的中心不需要，中心还没接入时也不存在 —— 两个状态都必须能跑；
  2. 容器**只挂目录**（`identity/gwlinkd/trust/`），不挂单文件 —— 从根上不给 docker「把文件建成目录」的机会；
  3. 真身（`identity/gwlinkd/control-center.pem`，gwlinkd 页面接入时写）与投影分开，由
     `scripts/init-gwlinkd-pub.sh` 在 localize 时同步（有就拷、没有就删，幂等）。
     代价：接入后新写入的 CA 要等下一次 localize 才到容器 —— 在那之前 `project_remote` 本来也
     拉不动（还没接中心），所以这个窗口是空的。
  组件侧兜底：入口脚本判到投影不是可读 PEM 就 `unset SSL_CERT_FILE` / `GIT_SSL_CAINFO` 并回落到系统根。

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

全仓只有四处直接调用（都走同一个薄壳 `scripts/check-stack.sh`）：

```
sys/workflows/operators.gxl    flow localize   →  ./scripts/check-stack.sh --gate --only prereq   （**最前**：前置条件）
sys/workflows/operators.gxl    flow localize   →  ./scripts/check-stack.sh --gate                 （最后：全量守门）
sys/workflows/operators.gxl    flow diagnose   →  ./scripts/check-stack.sh          （追加 checks）
scripts/restore-gateway.sh     还原完成后      →  ./scripts/check-stack.sh          （只读自检）
```

**为什么前置条件要单独跑在最前面**：`flow localize` 的渲染动作在 `apply` **之后** ——
那一刻新包的文件刚换上去、还没重渲，`render.freshness.*` 会**合理地**判 FAIL。
全量闸门放在开头会误拦每一次升级，所以用 `--only prereq` 只跑那一组；全量仍留在尾部。

对应到命令：

| 命令 | 经过 | 作用 |
|---|---|---|
| `gops run diagnose` | `flow diagnose` | 全量体检（19 项） |
| `gops sys localize` | `flow localize` | 开头查前置条件，渲染完立刻全量守门 |
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
8. **`prereq.*` 执行随包脚本，不复刻逻辑**：判据与真正跑的代码必须是**同一份实现**
   （脚本侧只有 `scripts/lib/tls-san.sh` 一处，Rust 侧 `san_covers` 自带单测锁口径）。
9. **守护进程的 PATH 是常量**（`/usr/bin:/bin:/usr/sbin:/sbin`）：不要去解析 launchd plist /
   systemd unit 的实际环境——那是猜，而且改一次就要跟着改。
10. **探针失败不能拖垮体检**：`bash` 不存在、脚本半途死掉都要落成一条具名结论，
   而不是让整个进程非零退出或卡住（`--gate` 只认阻断类 FAIL）。

## 10. 已知限制

- **`render.freshness` 用 mtime 启发式**：手工改了值文件里主配置并不引用的字段会误报。
  更准的做法是让 `gx.tpl` 在渲染时把「值文件摘要」写进产物旁边，用摘要比对替代 mtime
  —— 需要改 galaxy-flow，未做。
- **证书只判 SAN 与有效期，不验签发链**：`openssl verify`（脚本里）仍由
  `init-gateway.sh` 负责；两边判据不一致不会死锁（脚本会更激进地重签），但检查器漏报。
- **未检查 `sys/merged_vars.yml` 与 `sys/setting/vars.yml` 的漂移**（`gops sys update` 的职责）。
- **`port.available` 依赖 docker CLI**：容器运行时栈自己的端口会被整体跳过，
  所以这项主要在「首次部署 / 栈停着」时有价值。

## 11. 落地：共享 `stackcheck-core` + 两个 profile

**已实施为公共仓**：[`wist-stack-tools`](https://github.com/dayu-sec/wist-stack-tools) 的
`stackcheck-core`（crates.io `wist-stackcheck-core` 0.1.x）承载：Flow Result / CLI /
`StackProfile` 类型 / 渲染、密钥、身份、挂载、`public_url`、端口、镜像判据 /
compose、路径、TOML、x509 helper。两个栈各自只保留：

- `tools/stackcheck/src/profile.rs`：本栈的路径 / 变量 / 渲染对 / 身份文件；
- `checks.rs`：本栈专属判据（gateway 的 layout / package / knowledge / identity / prereq / TLS 策略；
  center 的 TLS 策略）；
- `main.rs`：约 50 行，调 `stackcheck_core::cli::run`。

center 落地判据 15 项：

| 组 | code |
|---|---|
| 变量 | `config.vars` |
| 渲染 | `render.freshness.{center,git-proxy,web,center-pub}`、`render.placeholder` |
| 域名 | `domain.configured` |
| 密钥 | `secret.file_mode`、`secret.private_key_mode` |
| 身份 / TLS | `identity.center_files`、`tls.san_covers_domain` |
| 布局 | `layout.mounts`、`layout.public_url` |
| 存储 | `database.initdb` |
| 运行面 | `port.available`、`image.reachable` |

与 gateway 实现的差异（有意为之）：

- `public_url` 用的是 **声明（`${VAR}`）+ `.env`（现场值）** 两层，检查器比的是 `.env` 的生效值
  与当前 `API_WGC_DOMAIN` / `CENTER_HOST_PORT` —— 改了域名但 `.env` 不跟着改会报 FAIL（不阻断升级：
  当前栈还是好的，错的是以后生成的网关安装 URL）；
- `layout.mounts` 把 compose 源表达式、变量展开后的落点、localize 实际写入位置三者一起比，
  防止现场覆盖 `CENTER_CONFIG_DIR` 之类的变量把容器指到旧目录；
- 端口探测按 compose 里的 `*_BIND_IP` 绑（center 有多个 `127.0.0.1:`），并修正了
  `docker ps --format` 多行解析（每行第一个映射以前会漏）。

**两个栈已用同一份引擎**：gateway 的硬编码路径已收进 `profile::GATEWAY`；`checks.rs` 只留
package / knowledge / identity / prereq / TLS 策略。共享引擎同时修掉了此前分叉的
`docker ps` 多行、IPv6/行内 ports、`.env` 回落、渲染产物无来源等边界。

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
| `REQUIRED_COMMANDS` / 守护进程的最低 PATH | `prereq: Option<PrereqSpec { commands, daemon_path }>`（center 的 flow 可能用别的工具，例如 `psql`、`tar`） |
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

### 11.3 建议的落地顺序（center 已完成）

1. 把 `StackProfile` 抽出来，让 gateway 用 profile 跑（**行为不变**，先加回归测试锁住 19 项）；
2. center 写自己的 profile，先只启用已通用的检查（compose 挂载、端口、镜像、secret 权限、TLS）；
3. 再按 center 的实际痛点补判据（内容目录自洽、artifact 目录、版本一致性）；
4. 两边**同一套输出契约**，`gops run diagnose` 天然聚合，管理面渲染不用写第二份解析。

## 12. 验收

- 单元测试 60 条（50 判据 + 10 CLI），覆盖：键落错段、渲染过期、占位值、缺签名、
  有效值优先、TLS 覆盖/不覆盖/过期、SAN 通配与后缀攻击、compose 备选文件名与长语法、
  端口冲突、离线收敛、结果文件追加与去重；以及 `prereq.*` 的「两份 PATH 分级」、
  「静默读空算失败」、「`--only` 只跑一组」。
- 现场实测（`wist-gateway-stack` 0.2.5-alpha，17 项）：16 ok / 1 warn（历史知识库包缺 `.sig`）/ 0 fail，
  整次体检 **0.17 秒**（镜像走本地快路径）。0.2.6-alpha 起为 19 项（新增 `prereq.*`）。
- 发版门禁：`gops sys localize` 与 `gops prj upgrade` 的 `regenerate` 阶段都会执行它。
