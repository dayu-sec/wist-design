# 软件指纹与可信源校验

> 状态：**决策草案**（2026-11-07）。
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

> 这也说明了包反查的第二个价值：它不是「版本的唯一来源」（指纹命中也会给版本），
> 而是**提供可交叉验证的声称值**。

---

## 6. 可信源库怎么填

```text
现场：上报坐标  (product, version, distro, arch)      ← 只有四个字段
   ↓
中心：按坐标下载官方制品 → 提取目标二进制 → sha256 → 入库
   ↓
任意主机：读文件算 hash → 匹配
```

**客户不需要上传任何指纹** —— 只报「我们跑着这些产品的这些版本」。这比导出一堆哈希干净得多。

### 6.1 库的键是「构建」，不是「版本」

一条记录 = 一次构建：

```
(product, version, distro, arch)  →  sha256
```

同一个 `nginx 1.27.5-r1`：alpine/x86_64 是一个 hash，alpine/aarch64 是另一个。

### 6.2 每条记录必须留证

| 字段 | 为什么 |
| --- | --- |
| `url` | 下载地址（可复查） |
| `fetched_at` | 抓取时间 |
| `artifact_sha256` | **制品本身**的摘要（不是文件） |
| `signature` | 仓库签名能验就验（Debian / Alpine 都签名） |

没有这一层，「可信源」只是我们自己说它可信 —— 这条链一断，上面所有结论都塌。

### 6.3 覆盖边界

| 能覆盖 | 不能覆盖 |
| --- | --- |
| 发行版仓库（deb/rpm/apk） | 商业软件（需登录/许可） |
| 官方容器镜像 | **客户自编译** |
| 官方 tarball（kafka、elasticsearch） | 内网私有仓库 |

拿不到的永远停在 `observed`，不做猜测。

### 6.4 成本

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

> 与 KB 的 `provenance` 同一条纪律：结论要能说出处，说不出的不许当事实用。

---

## 8. 变化检测与归因

「同一路径 hash 变了」**本身不是危险信号** —— 绝大多数是打补丁。
关键是有没有**原因**。

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

只有「只采运行中」这个前提才需要这个区分。

---

## 10. 数据模型

```sql
-- 客户域：指纹与识别结果
CREATE TABLE software_fingerprint (
    host_id        UUID NOT NULL,
    sha256         TEXT NOT NULL,
    size_bytes     BIGINT NOT NULL,
    build_id       TEXT,
    path           TEXT NOT NULL,          -- 只在计算区内
    -- 声称值（来自包反查 / 探测 / 镜像）
    claimed_product_id TEXT,
    claimed_version    TEXT,
    claimed_source     TEXT,               -- path_package|probe|image_tag
    -- 验证结果
    verified_product_id TEXT,
    verified_version    TEXT,
    status         TEXT NOT NULL,          -- official|claimed_mismatch|ours|human_confirmed|ai_suspected|observed
    first_seen_at  TIMESTAMPTZ NOT NULL,
    last_seen_at   TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_id, sha256)
);

-- 中心侧：从可信源构建的库（不含任何现场字段）
CREATE TABLE fingerprint_knowledge (
    sha256          TEXT PRIMARY KEY,
    size_bytes      BIGINT,
    build_id        TEXT,
    product_id      TEXT REFERENCES software_product(product_id),
    version         TEXT,
    coordinate      JSONB,                 -- {distro, arch, variant}
    artifact_sha256 TEXT,                  -- 制品本身
    source_url      TEXT NOT NULL,
    fetched_at      TIMESTAMPTZ NOT NULL,
    signature_ok    BOOLEAN,
    status          TEXT NOT NULL,         -- official|ours|human_confirmed|ai_suspected
    host_count      INTEGER NOT NULL DEFAULT 0,
    last_seen_at    TIMESTAMPTZ
);
```

---

## 11. 分阶段

| 阶段 | 范围 | 验收 |
| --- | --- | --- |
| **P0** | 采集候选集指纹 + 包反查声称值 + `software_fingerprint` 落库 + 图谱可见 | 一台机上能报出：候选数 / 原厂数 / 声称不符数 / 未知数 |
| **P1** | 可信源库填充管线（坐标 → 下载 → hash）+ 匹配 | 命中率从 0 提升到可量化水平 |
| **P2** | 变化检测归因（对 `SoftwareChange` 日志）+ 告警 | 能区分「预期升级」与「无归因变化」 |

**P0 不依赖可信源库**（库为空时全部落到 `observed`），但能把采集和建模跑通。

---

## 12. 待定

1. 指纹库进 KB 包还是独立包（条目上万后再说）。
2. 现场坐标怎么带出来：走 `observed` 导出包，还是单独的「软硬件清单」通道。
3. 容器场景：镜像内的文件与发行版包不一致（镜像构建时可能改写），需单独验证。
4. 告警的默认档位：`claimed_mismatch` 是否默认进告警列表。
