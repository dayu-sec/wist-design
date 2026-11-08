# 软件指纹与可信源校验

> 状态：**决策草案**（2026-11-07）；**2026-11-08 定：指纹上传，作主机软件实例的唯一权威身份 ID**（见 §6）。
> 上游：[`software-asset-scope.md`](../../foundation/software-asset-scope.md)（哪些软件是目标）、
> [`software-identity.md`](../../foundation/software-identity.md)（单位与判据）、
> [`software-kb-import.md`](software-kb-import.md)（签名包怎么进 atlas）。
>
> 本文回答：**主机上跑的东西到底是哪个产品、哪个版本、是不是原厂出品、有没有已知漏洞。**

---

## 1. 核心逻辑

```text
主机上「重要二进制」的 sha256
        ↓  对照可信源（官方制品）的 sha256
① 来源完整性：是不是原厂那个字节
② 身份：是哪个产品、哪个版本
③ 漏洞：这个版本有没有已知公告
```

一句话：**同时采集「它声称是什么」和「它实际是什么字节」，用可信源把两者对上。**

- 对得上 → 原厂出品，身份与漏洞都可判；
- 对不上 → **声称是 X，文件却不是官方那个**（可疑）；
- 两边都缺 → 未知（自研 / 自编译 / 私有）。

### 「可信度」是两个正交的轴，不能混

| 轴 | 问题 | 靠什么 | 强度 |
| --- | --- | --- | --- |
| **来源完整性** | 这个文件是不是原厂那份 | hash 命中可信源 | 很强 |
| **漏洞状态** | 这个版本有没有已知洞 | advisory 区间匹配 | 取决于数据完整度 |

两条互不推导：**原厂 ≠ 安全**（官方 1.22 也有洞）；**有洞 ≠ 被篡改**（只是没打补丁）。

---

## 2. 为什么需要（实测）

| 软件来源 | 上游有权威映射吗 |
| --- | --- |
| 宿主 deb/rpm/apk | ✅ `dpkg -S` / `rpm -qf` |
| **官方容器镜像** | ❌ **6 个里 5 个不打包自己**（redis / kafka / rabbitmq / elasticsearch / openjdk） |
| tarball / 静态二进制 | ❌ |
| 自研软件 | ❌（本文不处理） |

在那 5 个里，唯一能回答「这是什么版本」的方式就是指纹 + 可信源。

---

## 3. 采集范围：只采候选集

**不扫全盘。** 实测一台开发机 713 个可执行里只有 29 个（4%）够格进图谱。

候选判定按 [`software-asset-scope.md`](../../foundation/software-asset-scope.md) 四档短路：

```text
A 对外监听（业务端口段）
B 被 runtime_binding 绑到服务实例
C 命中类别规则（数据库 / MQ / 缓存 / Web / 运行时 / 采集器）
   ↓ 都不命中 → 不算指纹、不计数、不出现（D 档）
```

> 边界：**不采全量包清单**（`dpkg -l` 那种）。一台机 500–2500 条，
> 既不进资产（没跑的软件不是运行资产），也会把摘要通道撑爆。
> 需要的是「这个在跑的东西属于哪个包」，见 §4 的**包反查**。

---

## 4. 采集什么

### 4.1 实际字节

| 字段 | 来源 |
| --- | --- |
| `sha256` | 读 `/proc/<pid>/exe` 指向的唯一路径 |
| `size_bytes` | `stat` |
| `build_id` | ELF `.note.gnu.build-id`（可选；重新链接仍稳定） |

缓存键 `(path, size, mtime, inode)`：首轮全量，之后只算新出现的文件。
实测体量：`postgres` 约 7 MB、`nginx` 约 1.5 MB，候选集合计几十 MB —— 必须缓存。

### 4.2 声称值（用于交叉验证，见 §5）

| 来源 | 给出什么 | 怎么做 |
| --- | --- | --- |
| **包反查** | `(ecosystem, 包名, 版本)` | `dpkg -S <path>` / `rpm -qf` / `apk info --who-owns`，再取版本 |
| 二进制自报 | 上游版本 | `version_probe`（白名单，见下） |
| 镜像 tag | 容器场景 | `container_runtime.image_ref` |

包反查实测输出：

```bash
$ dpkg -S /usr/lib/postgresql/16/bin/postgres
postgresql-16: /usr/lib/postgresql/16/bin/postgres
$ dpkg-query -W -f='${Version}' postgresql-16
16.15-1.pgdg13+2
```

**它给的是发行版版本号** —— 而这正是漏洞区间用的口径：

```
包反查   → nginx-1.27.5-r1
nginx -v → nginx/1.27.5        ← 丢了 -r1，而 Alpine 的安全修复常常就是 bump rN
```

### 4.3 不执行未知二进制

只读文件，不 `exec`。实测 `rabbitmq-server --version` **会真的把服务起起来**。

> 包反查会执行 `dpkg-query` 这类只读命令。agentd 本来就在执行外部命令
> （`discovery/process.rs` 自己就调 `ps`），这不是新的能力面，但应挂进
> **能力协商**：`pkg_query:dpkg | rpm | apk`。

---

## 5. 核心：交叉验证矩阵

**「声称的身份」和「验证的身份」必须分开记**。

|  | hash 命中可信源 | hash 不命中 |
| --- | --- | --- |
| **有声称**（包反查 / 探测说是 X） | ✅ **原厂**：身份与文件一致 | 🔴 **声称 X，文件却不是官方那个** |
| **无声称** | ✅ **指纹补上了身份** | ⚪ 未知 |

右上角是整套机制最值钱的一格：

```text
包管理器说：nginx 1.27.5-r1
官方 r1 指纹：0145bbac…
本机文件：    d3f1c9e2…          ← 对不上
```

单看包版本匹配不出来（它说自己是 r1），单看 hash 也匹配不出来（只是一段未知指纹）——
**只有两边交叉才发现**。

> 这张矩阵要在中心侧成立，前提是**比对结果（`status`）随指纹一起上报**（§6.6）。
> 只在客户端本地比完不上报，矩阵对中心永远是空的。

> 这也说明了包反查的第二个价值：它不是「版本的唯一来源」（指纹命中也会给版本），
> 而是**提供可交叉验证的声称值**。

---

## 6. 现场上报什么：指纹即身份

**一条铁律：身份由字节定，不由名字定。**

现场上传的 `sha256` 就是这台主机上这个软件实例的**唯一权威身份 ID**。
产品名、版本、发行版、架构都是**属性**，用来描述这份字节 —— 它们可以缺、可以错，
但不能反过来替代字节做身份。

```text
现场：读 /proc/<pid>/exe → sha256   ← 权威身份 ID
      + 坐标与声称值                ← 属性（可能错，也可能没有）
   ↓
中心：artifact_id = "sha256:<hex>" 作主键
      命中可信源库 → official；命中不了 → observed（ID 仍然有效）
   ↓
可信源库：按坐标下载官方制品 → 提取目标二进制 → sha256
          与现场 hash 对上 → 建立身份；对不上 → 这份构建还没有主
```

为什么必须是字节，四条依据都在本文里：

| 理由 | 依据 |
| --- | --- |
| 名字和版本会说谎 | §5 右上角：包管理器说 `nginx 1.27.5-r1`，文件却不是官方那份 |
| 有一半目标产品根本给不出名字 | §2 实测：6 个里 5 个不打包自己 |
| 坐标定位不到构建 | §4.2 实测：`16.15-1.pgdg13+2` 来自 pgdg，不在 Debian 官方仓库 |
| 同一版本的字节因构建而异 | §6.3：alpine/x86_64 与 alpine/aarch64 是两个 hash |

**指纹不是敏感数据，这个口径不接受「隐私」作为降级理由。** 我们的目标就是准确知道客户主机上
跑着什么软件；要谈泄露，atlas 本身就不该建。sha256 不可逆、不含文件内容，
它和「产品 + 版本 + 发行版 + 架构」是同一量级的信息 —— 后四项能传，它就能传。

因此：**不做哈希盐化、不做能力降级、不设「客户不同意」分支。** 需要隔离的只有**授权**
（哪个租户能看哪些主机），不是身份本身（见 §6.7）。

### 6.1 三种「身份」不要混用

| 层 | 回答的问题 | 键 | 稳定性 |
| --- | --- | --- | --- |
| **product** | 这是什么产品 | `canonical_id`（KB 人写，见 `software-identity.md` §2.2） | 极稳 |
| **artifact** | 这是哪一份字节 | `sha256` ← **本次定的权威 ID** | 升级即变 |
| **instance** | 哪台机的哪个部署位上跑着它 | `(host_id, anchor)` | 跨升级稳定 |

`anchor` 取第一个拿得到的：systemd unit → 容器 ID → 监听 socket → `ExecStart` 的 argv[0] → 安装根目录。

**一个内容寻址，一个位置寻址，两个都要：**

- 只有 `artifact`：升级后台账里多出一个「新资产」，历史断链，§8 失去基线；
- 只有 `instance`：无法回答「这台机跑的是不是原厂那份」，§5 矩阵永远空着。

关联关系是 `instance --当前--> artifact @ [first_seen, last_seen]`，见 §10。

### 6.2 一个实例只能有一个权威 ID

同一个安装里往往有多个二进制（`postgres` / `initdb` / `pg_ctl`），
若都算，同一实例每轮采样可能给出不同 ID，§8 全是噪声。

选定规则（按序取第一个命中的）：

| # | 判据 | 适用 |
| --- | --- | --- |
| 1 | **JVM 应用**：从 `cmdline` 的 `-jar` / `-cp` + 主类定位应用 jar；退而用 `/proc/<pid>/maps` 里已加载的 jar；再退而用 `cwd` + 已知目录规则 | java 进程 |
| 2 | 对外监听进程的可执行 | 通用 |
| 3 | systemd `ExecStart` 的 argv[0] | 通用 |
| 4 | 包元数据的 main binary | 通用 |
| 5 | 同目录下最大的可执行 | 兜底 |

其余进 `sub_artifacts[]`，各带自己的 sha256，但**不作为实例 ID**。

> **JVM 必须排第一。** `/proc/<pid>/exe` 对 java 进程指向 `/usr/bin/java` —— 那是 **JDK**，不是应用。
> 不特殊处理，一台机上所有 JVM 产品（kafka / elasticsearch / 自研 java 服务）会**塌成同一个 ID**，
> 而那个 ID 是 JDK 的。
>
> 同理，主文件要选**带版本语义的那个**：Kafka 取 `libs/kafka_2.13-<ver>.jar`，
> 不是 `kafka-server-start.sh`（启动脚本几乎不变，区分不出版本）。
> 这条规则同时决定了 §13 库里 `main_file` 存哪个文件的 hash —— 两边不对齐，命中率直接归零。

### 6.3 库的键是「构建」，不是「版本」

可信源库的一条记录 = 一次构建：

```text
(product, version, distro_id, distro_version, component, arch, libc)  →  sha256
```

同一个 `nginx 1.27.5-r1`：alpine/x86_64 是一个 hash，alpine/aarch64 是另一个。

> 坐标取自**制品元数据**（包记录 / 镜像 manifest），不是宿主 `/etc/os-release`。
> 在 Debian 12 上跑官方 tarball 的 Kafka，宿主 distro 指向的是一条不存在的构建。

### 6.4 拿不到 hash 的情况：ID 允许缺失

| 场景 | 表现 |
| --- | --- |
| 无读权限（非 root） | 读不到 `/proc/<pid>/exe` |
| 进程还在、文件已删 | `/proc/<pid>/exe` 指向 `(deleted)` |
| 内存加载 / 脚本 | `memfd`、解释器脚本，没有稳定字节 |
| 容器内文件 | agentd 在宿主，要经容器运行时接口 |
| 超过大小上限 | 跳过并注明 |

这些实例落 `identity_missing`，并**记录原因**（与 `report.limits` 同一条纪律）。
**绝不能用声称值伪造一个 ID** —— 那是把 §5 的可信度偷换成猜测。

### 6.5 覆盖边界

| 能覆盖 | 现场落到 |
| --- | --- |
| 发行版仓库（deb/rpm/apk） | `official` |
| 官方容器镜像 | `official`（文件来自镜像层） |
| 官方 tarball（kafka、elasticsearch） | `official` |
| 商业软件（需登录 / 许可） | `observed`：ID 有效，中心建不了库 |
| **客户自编译** | `observed`：任何可信源都对不上 |
| 内网私有仓库 | `observed`：中心取不到原厂制品 |

**「建不了库」不等于「没有身份」。** `observed` 的 hash 仍是权威 ID：能去重、能做跨机同源、
能进变化检测；等有人补上「这份字节是什么」，身份自动回填，**不需要重采**。

> 这也是 §2 那 5 个产品的唯一出路：既无包记录、又不能 exec 自报版本，
> **除了 hash 没有任何身份来源**。

### 6.6 上送口径

**必传**（构成权威 ID 与交叉验证）：

```text
artifact_id (sha256) · size_bytes · build_id · anchor · 声称值 · status · version_running
```

**默认只落本机报告，按需拉取**：

- 文件绝对路径、inode、mtime —— 不进摘要通道。理由不是敏感，而是**体积与抖动**：
  一台机几十条路径、容器里路径每轮会变，进摘要只会把去重打散；
- 包元数据的其余细节。

**例外：`claimed_mismatch` 必须同时上传 path。** 否则中心只能信客户端的结论、无法复查
「到底哪个文件不对」，§5 右上角那格的价值会折掉一半。

### 6.7 跨租户：身份全局，授权隔离

`artifact_id` 是内容寻址，所以**同一份字节在任何租户下都是同一个 ID** —— 这是要的，不是风险：

| 数据 | 范围 |
| --- | --- |
| 「这份字节是什么」（atlas `software_artifact`） | **全局共享**，KB 的增殖来源 |
| 资产归属、`host_count`、跨机 / 跨租户关联 | **全局可算**，这是横向排查的基础 |
| 谁能看哪些主机 / 哪条关联 | **按租户授权**，不是切断数据 |

**不做哈希盐化。** 盐化会让同一份字节在不同租户下变成不同 ID，直接毁掉「这个东西到底是什么」
这个问题 —— 而那是我们建 atlas 的唯一目的。需要隔离的是**访问权**（谁有权限看），不是**身份**。

### 6.8 每条库记录必须留证

| 字段 | 为什么 |
| --- | --- |
| `url` | 下载地址（可复查） |
| `fetched_at` | 抓取时间 |
| `artifact_sha256` | **制品本身**的摘要（不是文件） |
| `signature` | 仓库签名能验就验（Debian / Alpine 都签名） |

没有这一层，「可信源」只是我们自己说它可信 —— 这条链一断，上面所有结论都塌。

### 6.9 成本

```
20 产品 × 5 发行版 × 2 架构 × 最近 5 个版本 ≈ 1000 个制品
每个 5–50 MB → 一次性约 20 GB，之后增量
```

---

## 7. 结论分级

| 状态 | 含义 | 能驱动漏洞匹配 |
| --- | --- | --- |
| `official` | hash 命中可信源 | ✅ |
| `claimed_mismatch` | 有声称值但 hash 不符 | ❌ 先按可疑处理 |
| `ours` | 我们自己的构建产物（CI 算好） | ✅ |
| `human_confirmed` | 现场学到 + 人工确认 | ✅ |
| `ai_suspected` | AI 推断达阈值，未确认 | ❌ 只展示 |
| `observed` | 未知（自研/自编译/私有） | ❌ 但计数 |
| `identity_missing` | 算不出 hash（无权限 / 已删除 / 内存加载），**没有权威 ID** | ❌ 但计数 + 记原因 |

> 与 KB 的 `provenance` 同一条纪律：结论要能说出处，说不出的不许当事实用。

---

## 8. 变化检测与归因

「同一实例的 artifact 变了」**本身不是危险信号** —— 绝大多数是打补丁。
关键是有没有**原因**。

> 基线挂在 `(host_id, anchor)` 上（§6.1 的 instance），不是挂在 `sha256` 上：
> hash 变了正是被检测的事件，不能拿事件本身当锚点。

| hash | 包版本 | 变更日志 | 判定 |
| --- | --- | --- | --- |
| 变 | 变 | 有 | ✅ 正常升级，不报 |
| 变 | 不变 | 有（重装） | ⚠️ 同版本重装，值得看 |
| 变 | 不变 | **无** | 🔴 高可疑 |
| 变 | 查不到包 | 无 | ⚠️ 无法归因（容器/自编译） |
| 变回原值 | — | — | 🔴 极高可疑 |

**归因数据已经有了**：`catalog.toml` 的 `SoftwareChange` 面在采
`/var/log/dpkg.log`、`/var/log/apt/history.log`、`/var/log/dnf.log`。

### 8.1 两个实现细节

1. **时间对齐**：指纹变化时间与日志时间要落在同一窗口（如 ±10 分钟），
   否则「先升级再重启」会被误判成篡改。
2. **升级窗口内跳过**：包管理器升级过程中会短暂删/写文件，采样会看到中间态。

### 8.2 告警文案必须区分能力不足与风险

```text
🟡 指纹变化，本机未采集变更日志，无法判断原因    ← 我们能力不足
🔴 指纹变化，变更日志已采集且无对应记录          ← 真可疑
```

不分这两者，就会出现「我们没采」被当成「客户有风险」。

> 这是相对普通 FIM（Tripwire / OSSEC / auditd）的差异点：它们只能报「文件变了」，
> 噪声大到被关掉；我们同时有**身份 + 版本 + 变更日志**，能区分「预期变化」和「无归因变化」。

---

## 9. 运行版本 vs 安装版本

只采运行中的软件 ⇒ 我们看的是**内存里的进程**，而包反查给的是**磁盘上的包**。
升级后没重启时两者不同：

```text
version_installed  1.24（已修）
version_running    1.22（有洞）   ← 当前暴露
```

- **漏洞命中用 `version_running`** —— 回答「现在有没有暴露」；
- `version_installed` 回答「重启之后会变成什么」。

**两者在模型里是两个现成的字段，不需要额外列**：

| | 字段 | 来源 |
| --- | --- | --- |
| `version_running` | `current_artifact_id → software_artifact → version` | 内存里那份字节 |
| `version_installed` | `claimed_version` | `dpkg-query -W` / `apk info --who-owns` |

两个不同就是「升级了没重启」。这也是不另设 installation 表的原因之一（§10.1 末）。

只有「只采运行中」这个前提才需要这个区分。

---

## 10. 数据模型

### 10.1 客户域（现场观测）

```sql
-- ① 构件观测（内容寻址）—— artifact_id 即「唯一权威身份 ID」
CREATE TABLE software_fingerprint (
    tenant_id      UUID NOT NULL,
    host_id        UUID NOT NULL,
    artifact_id    TEXT NOT NULL,          -- 'sha256:<hex>'，self-describing
    size_bytes     BIGINT NOT NULL,
    build_id       TEXT,                   -- ELF build-id；重新链接仍稳定
    first_seen_at  TIMESTAMPTZ NOT NULL,
    last_seen_at   TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (tenant_id, host_id, artifact_id)
);

-- ② 实例（位置寻址）——跨升级稳定，是 §8 的基线锚点
CREATE TABLE software_instance (
    instance_id     UUID PRIMARY KEY,
    tenant_id       UUID NOT NULL,
    host_id         UUID NOT NULL,
    anchor_kind     TEXT NOT NULL,         -- systemd_unit|container|socket|argv0|install_root|process
    anchor_value    TEXT NOT NULL,
    current_artifact_id TEXT,              -- NULL ⇔ identity_missing
    identity_missing_reason TEXT,
    -- 声称值（来自包反查 / 探测 / 镜像）
    claimed_package_name TEXT,             -- 'postgresql-16'（包名 ≠ 产品名，别合并）
    claimed_product_id   TEXT,             -- 归一后引用 KB
    claimed_version      TEXT,             -- 原样保留；来自包元数据时即 version_installed
    claimed_source       TEXT,             -- path_package|probe|image_tag
    -- 入库凭据：解释「这条为什么在图上」
    role            TEXT[] NOT NULL DEFAULT '{}',  -- exposed-service|business-runtime|middleware|runtime|agent
    reason          TEXT[] NOT NULL DEFAULT '{}',  -- listener|service-binding|governance-class
    status          TEXT NOT NULL,         -- official|claimed_mismatch|ours|human_confirmed|ai_suspected|observed|identity_missing
    first_seen_at   TIMESTAMPTZ NOT NULL,
    last_seen_at    TIMESTAMPTZ NOT NULL,
    stale_at        TIMESTAMPTZ,
    UNIQUE (host_id, anchor_kind, anchor_value)
);

-- ③ 观测时间线 —— 回答「哪天升的、升到哪份字节」
CREATE TABLE software_instance_observation (
    instance_id      UUID NOT NULL REFERENCES software_instance,
    artifact_id      TEXT NOT NULL,
    observed_at      TIMESTAMPTZ NOT NULL,
    version_running  TEXT,
    version_installed TEXT,
    PRIMARY KEY (instance_id, artifact_id, observed_at)
);

-- ④ 本机报告（不进摘要通道）；`claimed_mismatch` 时才随证据上报
CREATE TABLE software_artifact_path (
    instance_id  UUID NOT NULL REFERENCES software_instance,
    path         TEXT NOT NULL,
    role         TEXT NOT NULL,            -- primary|sub_artifact
    size_bytes   BIGINT NOT NULL,
    mtime        TIMESTAMPTZ NOT NULL,
    inode        BIGINT NOT NULL,
    PRIMARY KEY (instance_id, path)
);
```

> **为什么不另设 `software_installation`（2026-11-08 定）**：`software-normalization-and-vuln-enrichment.md`
> 早期在客户域放了 `software_installation`（包 × 主机），只有包视角。本设计撤掉它，理由三条：
>
> 1. **它独占的信息在当前范围里为零** —— `version_installed` 就是 `claimed_version`（同一次 `dpkg -S` 的产物）、
>    `install_source` 就是 `claimed_source`、`install_path` 在 `software_artifact_path`、`role[]`/`reason[]` 已搬到上面；
> 2. **`scope` 已把「装了但没跑」划出图谱**（[`software-asset-scope.md`](../../foundation/software-asset-scope.md) §3
>    硬规则：没有活进程不算运行资产），所以 installation 唯一的独占场景本就不在范围内；
> 3. **它在最重要的目标上会是空表** —— 6 个官方镜像里 5 个不打包自己（§2），tarball / 容器 / 自编译根本没有包记录。
>
> 反过来，`anchor` / `current_artifact_id` / `status` / `identity_missing_reason` 这四个东西它一个都装不下，
> 而它们正是「图谱节点」与「可信度」的载体。包世界仍然存在，只是落在 `software_product` / `software_version` /
> `software_artifact`（KB）与 instance 的 `claimed_*` 上，不再单独成一张客户域表。
>
> 代价是「装了没跑」不可见。将来真要做合规/取证，它是**证据侧的一次包清单查询**，不是图谱资产，
> 那时再加表也不迟（同 ③ 号表口径）。

### 10.2 中心域（可信源事实）

**不新建「可信源库」表。** 这份事实已经是 atlas 的
`wist-atlas/doc/model/unified-topology-schema.md` §3.14 `software_artifact`（一次构建，含 `sha256`）
+ `artifact_verification`（证据：来源、时间、签名）；再建一张 `fingerprint_knowledge` 就是第二个真值源。

本设计只补两张 atlas 缺的表：

```sql
-- 构建坐标：atlas 存了「哪个产品的哪个版本」，没存「哪次构建」
CREATE TABLE software_artifact_coordinate (
    artifact_id  TEXT PRIMARY KEY REFERENCES software_artifact,
    coordinate   JSONB NOT NULL            -- {distro_id, distro_version, component, arch, libc}
);

-- 流行度：按租户一行，便于回答「你有几台」；全局聚合允许，按授权展示
CREATE TABLE software_artifact_popularity (
    tenant_id    UUID NOT NULL,
    artifact_id  TEXT NOT NULL,
    host_count   INTEGER NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (tenant_id, artifact_id)
);
```

**需要跟 atlas 对齐的唯一一处**：`software_artifact.artifact_id` 采用内容寻址 `sha256:<hex>`，
与现场上报同值。若保留内部 UUID，中心就要多一层翻译，两个 ID 迟早会漂 ——
而“漂了”正好会本设计最想防的那类错（同一份字节两个身份）。

### 10.3 三条约束

1. **客户域引用 atlas 的 `artifact_id`，并带 `tenant_id`** —— 全球一个字典、一个 ID；
   `tenant_id` 只用于归属与授权，**不参与 ID 派生**。
2. **`current_artifact_id` 可为 NULL，且必须带 `identity_missing_reason`** —— 允许“没有 ID”，
   但不允许“假装有 ID”（§6.4）。
3. **`software_artifact_path` 与摘要通道分开** —— 路径只在 `claimed_mismatch` 时随证据上送（§6.6）。

---

## 11. 分阶段

| 阶段 | 范围 | 验收 |
| --- | --- | --- |
| **P0** | 候选集算 hash 上传作 `artifact_id` + 包反查声称值 + `software_fingerprint` / `software_instance` 落库 + 图谱可见 | 一台机上能报出：候选数 / 原厂数 / 声称不符数 / 未知数 / `identity_missing` 数 |
| **P1** | 可信源库填充管线（构建坐标 → 下载 → 提取 → hash）+ 匹配 + 身份回填 | 命中率从 0 提升到可量化水平；已上报的 `observed` 自动转为 `official` |
| **P2** | 变化检测归因（对 `SoftwareChange` 日志）+ 告警 | 能区分「预期升级」与「无归因变化」 |

**P0 不依赖可信源库**（库为空时全部落到 `observed`），但**身份从第一天就成立** ——
这正是把 hash 定为主键的收益：不用等库建好才能去重与关联。

---

## 12. 包的边界与托管

### 12.1 三个包，三种写入

| 包 | 内容 | 消费方 | 写入方式 |
| --- | --- | --- | --- |
| `wist-software-kb` | 定义层 7 表（product / recognize / bundled / profile / advisory / affected / state） | atlas | 单事务 `TRUNCATE` + `COPY`，`kb_state` 切 active |
| `wist-artifact-hash` | 事实层：`software_artifact` + `artifact_verification` + `software_artifact_coordinate` | **只有 atlas** | **增量 upsert**，按 `artifact_id` 幂等 |
| `wist-software-kb-bulk` | OSV / NVD / 发行版分片 | atlas | 同 KB |

`wist-artifact-hash` 与 KB **必须分成两个包**，五条理由：

| # | 理由 | 依据 |
| --- | --- | --- |
| 1 | **节奏差一个数量级** | KB 周更（`/var/lib/wist-kb/*.tar.gz`，运维独立更新）；hash 跟着上游发版，天级甚至小时级 |
| 2 | **失败语义不能共享** | KB 失败 = 沿用上一版，可接受；hash 抓取失败是**常态**（404、签名换了、tag 挪了）。合包 = 一次抓取失败把整个 KB 拖回上一版 |
| 3 | **分发对象不同** | KB 要给 gateway + atlas；hash 库**只有 atlas 需要** —— 网关不回答「这份字节是什么」。合包等于让每个网关多下几十 MB 却永不读 |
| 4 | **可审性不同** | KB 有 curated 层（一对象一文件、PR 可审）；hash 机器抓、**永远不可能逐条人审**，只能靠 §6.8 的留证链说话 |
| 5 | **增长曲线不同** | KB ~10⁴–10⁵（漏洞条目，线性）；hash 是**乘积** —— 产品 × 版本 × `distro_id` × `distro_version` × `component` × arch × libc，多接一个发行版就翻一倍 |

### 12.2 存储不分离，外键必须弱

**同一个 atlas、同一套 schema。** 拆独立库会立刻遇到三件事：每次「这个 hash 是什么」都要跨库 join；
漏洞命中要 `artifact → version → advisory`，拿不到一致快照；`stale` 语义要求两边同时感知 `kb_version`。

**但外键方向必须是弱的：**

> `software_artifact` 不对 `software_version` 加 `ON DELETE CASCADE`（用 `SET NULL` 或干脆不设）。

否则 **KB 整表替换会级联删掉客户上报的全部资产事实** —— 换一次 KB 就清空 hash 库，客户侧只能重采。

配套的解析是**延迟**的：

```text
写入：artifact_id(sha256) + 坐标 + 声称值   →  直接落库，不等 KB
查询：artifact_id → 尝试 join software_version
      命中 → official（product / version 由 KB 给）
      未命中 → observed（ID 仍有效）
```

KB 后到时，历史 `observed` 自动回填为 `official`，**不需要重采**（§11 P1）。

### 12.3 包内格式：文本、分片 JSONL

**是文本，但不是「一对象一文件的 TOML」。**

为什么仍然是文本：

| 理由 | 说明 |
| --- | --- |
| 省不了体积 | hash 是不可压缩的高熵内容，hex 戳 gzip 后约等于原始 32 字节；换二进制几乎不省，却要额外写工具 |
| 现场要能 `rg` | 客户报一个 hash，工程师要能在包里直接搜到「它是什么、从哪下的」 |
| 复用现成校验链 | `manifest.json` + 逐文件 sha256 + Ed25519（签 sha256 十六进制文本），与 `wist-knowledge` 的 `package.sh`、`kb-import` §4 完全一致，零新增代码 |
| 可 diff | 换版前能一眼看出「多了 300 条是不是某个发行版被全量重抓」 |

为什么不是 TOML per-object：

| | curated KB | artifact hash |
| --- | --- | --- |
| 作者 | 人 | 机器 |
| 审 | PR 逐条 | 不可能 |
| 量级 | 10²–10³ 个文件 | 10⁴–10⁶ 行 |
| 粒度 | 一对象一文件 | **一产品一片** |

10 万个小文件会把 tar 打包、git 操作、以及「逐文件验 sha256」全部拖死 —— 而后者是导入前的必做步骤。

```text
wist-artifact-hash-0.3.0/
  manifest.json          # name / version / schema_version / files[{path, sha256, rows}]
  artifacts/
    kafka.jsonl
    postgresql.jsonl
    nginx.jsonl
  .sig                   # Ed25519，签 manifest 的 sha256 文本
```

一行一条构建：

```json
{"artifact_id":"sha256:0145bbac…","size_bytes":123456,"build_id":"a1b2…",
 "version":"1.27.5-r1",
 "coordinate":{"distro_id":"alpine","distro_version":"3.20","component":"main","arch":"x86_64","libc":"musl"},
 "source_url":"https://dl-cdn.alpinelinux.org/…/nginx-1.27.5-r1.apk",
 "artifact_sha256":"sha256:9f3c…","fetched_at":"2026-11-08T02:11:00Z","signature_ok":true}
```

用 JSONL 而不是 TSV/CSV：`coordinate` 是要长的对象（后面还会加 `variant`）。TSV 每加一列就要改 `COPY`
列序并重排全表；JSONL 加字段不影响旧行。也不用 `pg_dump` / SQLite 文件：包是跨机器、跨版本的
交付物，dump 会把 PG 版本与表结构焊死在包里。

### 12.4 导入是 upsert，不是 TRUNCATE

`software_artifact` 有**两个写入方**：可信源包（机器抓的 `official`）与现场学习 / 人工确认
（`ours` / `human_confirmed`，§7）。整表替换会把后者删掉 —— 和 §12.2 的 cascade 是同一个坑的另一种形态。

| 情况 | 行为 |
| --- | --- |
| 包里有、库里没有 | `INSERT` |
| 包里有、库里也有 | `ON CONFLICT (artifact_id) DO UPDATE`，只更新来源字段 |
| 库里有、包里没有 | **不删** —— 可能来自现场，也可能上一版仍有效 |
| 「这次删掉了什么」 | 用 `manifest.files[].rows` 与上次导入对比，**不靠删数据反推** |

### 12.5 托管：GitHub 承担哪一段

**可以放 GitHub，而且比 KB 更适合放** —— 但要分清角色：

| 角色 | 放 GitHub | 理由 |
| --- | --- | --- |
| 抓取清单 + 抓取脚本 | ✅ | 可 PR 审、可复现 |
| 生成结果（`artifacts/*.jsonl`） | ✅ | 上游重新发版会产生**必须人看**的 diff（见下） |
| CI 构建 + 签名 | ✅ | Actions 能出网，正好补「计算区无外网」这一环 |
| 打包产物（`.tar.gz` + `.sig`） | ✅ 作为 release asset | 与 `wist-knowledge` 一致 |
| **运行时下载** | ❌ | atlas 在计算区无外网；gateway 也不该依赖 GitHub |
| **信任锚** | ❌ | release asset 对有写权限的人可替换 |

**为什么要放 GitHub（而不只放 COS）**：hash 库有一类 diff 必须人看 ——

```diff
- {"artifact_id":"sha256:0145bbac…","version":"1.27.5-r1","fetched_at":"2026-10-01T…"}
+ {"artifact_id":"sha256:d3f1c9e2…","version":"1.27.5-r1","fetched_at":"2026-11-08T…"}
```

**同一坐标、同一版本号，hash 变了 = 上游重新发版**（补了安全修复，或仓库被篡改）。只有 diff 视图能便宜
地暴露它，正好接上 §5 与 §8。

**提交粒度随量级调整：**

| 量级 | 提交什么 | 全量快照放哪 |
| --- | --- | --- |
| 现在（10⁴ 行 / 几 MB） | `targets.toml` + `artifacts/*.jsonl` 全量 | 同仓 |
| 10⁵ 行以上 | `targets.toml` + `changes.jsonl`（只记变化） | release asset |

**public 仓只放 `official`。** `ours` / `human_confirmed` 绝不进 public —— 那是客户资产，与
`software-knowledge-repo.md` 的「私有 overlay 只进不出」同一条纪律：

```text
public  wist-artifact-hash      ← official，CI 抓取，任何人可独立复核
private overlay（不进 Git）      ← ours / human_confirmed，按租户
```

**GitHub 不能当信任锚，必须双源交叉**：`pack_sha256` 同时出现在 (1) `.sig` 里；(2) 导入侧的期望值配置里
（像 `AgentInstallPackageAddress.package_sha256` 那样是**必填项**，不是可选项）。

**CI 跑不动 20 GB**：§6.9 的 20 GB 是制品本体，GitHub 免费 runner 可用磁盘约 14 GB。
按产品分片跑（一产品一个 job、各自干净 runner），最后合并 manifest。Debian / Alpine / ghcr 都有速率
限制，CI 要配镜源与缓存，否则每天都会有一片红。

### 12.6 什么量级再改

按 §6.9 估（20 产品 × 5 发行版 × 2 架构 × 最近 5 版 ≈ 1000 条），现在的分片 JSONL 远超需求。
到几十万条以上再评估：按 `distro_id` 再分一层片（客户只拉关心的发行版），或 `.jsonl.gz` 单文件分片
（流式解压后 `COPY`）。Parquet 不考虑 —— atlas 用 PG，列存在这里换不来收益，只多一个依赖。

---

## 13. 构建程序

库怎么建、怎么发、怎么维护，已独立成篇：
[`software-artifact-hash-library.md`](software-artifact-hash-library.md)。

本节只留三条与本篇直接相关、且容易漏的约束：

1. **采集源是三个**（GitHub Releases / 上游官网 / 发行版仓库），不是 GitHub 一个 ——
   客户装的多是发行版重编译的包，hash 与上游 tarball 完全不同；
2. **`main_file` 规则必须与 §6.2 的实例侧判据对齐**，否则命中率静默归零
   （表现为大量 `observed`，不报错）；
3. **事实与清单分权**：人能改 `targets.toml`，hash 行只能由 bot 写。

---

## 14. 待定

1. 容器场景：镜像内文件与发行版包不一致（镜像构建时可能改写），`anchor` 取容器 ID 还是镜像 digest。
2. 告警的默认档位：`claimed_mismatch` 是否默认进告警列表；`identity_missing` 是否要提示提权。
3. 已有 `observed` 存量在新库入库后如何批量回填（一次性重算 vs 下次上报时懒回填）。
