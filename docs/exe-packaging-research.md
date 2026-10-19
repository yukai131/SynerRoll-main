# SynerRoll EXE 打包与部署研究报告

> 日期：2026-09  
> 范围：性能、使用体验、内存占用、部署难度  
> 基线：当前仓库源码 + 本机 Julia 1.12.6 / Node v24 实测

---

## 1. 系统形态与打包约束

### 1.1 实际运行拓扑

```
用户浏览器
    │ HTTP :3000 (或随机端口)
    ▼
Nuxt 4 前端 + BFF (Node / Nitro)
    │ HTTP :8080          │ ws://:8080
    ▼                     ▼
Julia 后端 (Oxygen.jl)  ← 任务状态 WebSocket
    │
    ├── JuMP 模型构建
    ├── COPT / HiGHS 求解
    └── SQLite (tasks.db / timeseries.db / boundary.db)
```

三个必须随包交付的运行时：

| 组件 | 技术 | 打包难度 |
|---|---|---|
| 前端 + BFF | Nuxt 4 → Nitro standalone Node 服务 | 低（node + .output） |
| 计算后端 | Julia 1.12 + 20+ 包（JuMP/COPT/HiGHS/Oxygen…） | **高** |
| 求解器 | COPT（商业闭源）+ HiGHS（开源） | **许可风险** |

### 1.2 源码现状问题（打包前必须处理）

| 问题 | 位置 | 影响 |
|---|---|---|
| `Project.toml` 依赖写成版本号而非 UUID | `backend/Project.toml` | 无法 `Pkg.instantiate`，无法复现环境 |
| 无 `Manifest.toml` | `backend/` | 依赖版本不可锁定 |
| 后端地址硬编码 `localhost:8080` | `server/api/**` 全部路由 | 无法配置端口/远程 |
| WS 地址硬编码 `ws://localhost:8080` | `nuxt.config.ts` | 同上 |
| 性能探针未剥离 | `utils/perf_probe.jl` + `server.jl` include | 文档明确要求打包前移除 |
| 无 lint/test/typecheck 脚本 | `package.json` | 无法做发行门禁 |
| `server/data/projects-旧.json` 28MB 残留 | 源码树 | 污染发行包 |
| `backend/data/` 内含 113MB 任务数据 | 源码树 | 不应进安装包 |

---

## 2. 体积测算（Windows x64）

| 部分 | 实测/估算 | 说明 |
|---|---|---|
| Julia 运行时 | ~1030 MB | 官方安装目录整包 |
| Julia 包 + 预编译缓存 | ~1940 MB | packages 106 + artifacts 1636 + compiled 2222，可裁剪 |
| Node 运行时（portable） | ~40–50 MB | node.exe + 必要 DLL |
| Nuxt `.output` (standalone) | ~20–40 MB | 估，构建后确认 |
| 业务源码（剔除数据/文档） | ~5–15 MB | 含 component-library.json 等 |
| 启动器 / 壳程序 | 5–30 MB | 取决于方案 |
| **合计（粗裁剪后）** | **1.5–2.5 GB** | 压缩分发 zip 约 800MB–1.2GB |
| **合计（不裁剪）** | **~3.5 GB** | 不推荐 |

裁剪建议：
- 不打包 `~/.julia/compiled` 中未使用的预编译缓存（或打包后现场一次 `Pkg.precompile`）。
- 不打包 `backend/data/tasks/`、`backend/data/projects/` 运行数据。
- 不打包开发文档、PDF、Python 开发脚本。
- Julia artifacts 仅保留 JuMP/HiGHS/COPT/SQLite/HTTP 等实际用到的 JLL。

---

## 3. 打包方案对比

### 方案 A：便携式三件套 + 启动器（推荐起步）

```
SynerRoll/
├── SynerRoll.exe          # 启动器（Go/C#/Python+PyInstaller 均可）
├── runtime/
│   ├── node/              # portable Node
│   ├── julia/             # portable Julia + 最小 depot
│   └── app/
│       ├── .output/       # Nuxt standalone
│       └── backend/       # Julia 源码 + Project/Manifest
├── data/                  # 用户可写数据（项目、任务、SQLite）
└── logs/
```

启动器职责：
1. 健康检查（端口占用、磁盘可写、求解器许可）。
2. 启动 `julia --project=runtime/app/backend runtime/app/backend/server.jl`。
3. 启动 `node runtime/app/.output/server/index.mjs`。
4. 打开默认浏览器（或内嵌 WebView）。
5. 托盘图标 / 一键退出 / 日志入口。

| 维度 | 评价 |
|---|---|
| 部署难度 | 中。用户解压即用，无安装器；或再包一层 Inno Setup |
| 使用体验 | 中高。有窗口感需加壳；纯浏览器体验一般 |
| 性能 | 取决于 Julia 首次编译（见 §4） |
| 内存 | 见 §5 |
| 体积 | 1.5–2.5 GB |
| 维护成本 | 低。与开发环境结构一致，出问题好定位 |

### 方案 B：单 EXE / 单安装包（Tauri / Electron 外壳）

前端 SPA 化（关闭 SSR）+ Tauri 窗口加载本地 HTTP；Julia 仍以子进程存在。

| 维度 | 评价 |
|---|---|
| 部署难度 | 高。需改造 Nuxt 为纯 SPA 或 Nuxt static；Julia 仍无法进 EXE |
| 使用体验 | **最好**。原生窗口、图标、菜单 |
| 性能 | 前端相当；多一层 WebView 内存 |
| 内存 | Electron ~150–300MB 额外；Tauri ~50–100MB |
| 体积 | 仍 1.5GB+（Julia 不变） |
| 风险 | "单 EXE"是错觉，实际是 EXE + 巨大 sidecar |

### 方案 C：PackageCompiler.jl 打成 Julia 可执行文件

用 `PackageCompiler.create_executable` 把 `server.jl` 编成独立 EXE。

| 维度 | 评价 |
|---|---|
| 部署难度 | **很高**。编译耗时数小时；COPT 原生库链接困难；运行时动态加载易碎 |
| 使用体验 | 启动稍快（若 sysimage 成功） |
| 性能 | 首次启动可能更快；但预编译质量决定一切 |
| 体积 | 仍很大（sysimage + 运行时） |
| 风险 | Julia 版本敏感；COPT/HiGHS 二进制兼容；Windows 杀软误报 |

**结论：A → 可在 1–2 周内交付；B 作为体验升级；C 不建议作为首发路径。**

---

## 4. 性能分析

### 4.1 启动性能

| 阶段 | 预估 | 说明 |
|---|---|---|
| Julia 进程拉起 | 1–3 s | |
| 加载全部 include + 包 | 5–20 s | 冷启动；`using COPT/JuMP/DataFrames` 较重 |
| 首次 JIT / 预编译 | **30 s – 数分钟** | 首次任务求解时可能卡顿 |
| Nuxt Nitro 启动 | 2–5 s | |
| 首屏可交互 | **10–30 s（冷） / 5–10 s（热）** | 用户可感知 |

优化手段：
1. **打包时预编译 sysimage**（`PackageCompiler.create_sysimage` 只做 sysimage，不做 executable），可把首次加载从 20s+ 降到 3–8s。
2. 启动器做「服务就绪」轮询，就绪后再开浏览器，避免白屏。
3. 首页骨架屏 + 后端健康接口。

### 4.2 运行期性能

- 求解本身由 COPT/HiGHS 完成，与打包无关。
- 文档记录：每步求解后主动 `sleep(0.2)` 节流——**打包版应保留或做成配置**，否则 UI 刷新压力大。
- 大边界数据导入（CSV/Excel）与 BFF↔Julia JSON 转发是潜在瓶颈，与网络无关（localhost）但序列化开销在。
- `projects.json` 单文件存储：项目多时会变大（现有旧文件 28MB），建议发行前改为分片或按项目目录（文档 §4.4 已规划）。

### 4.3 性能日志（正式打包前移除）

文档明确：`utils/perf_probe.jl`、`server.jl` 中 include 及所有 `perf_*` 调用必须移除。发行包不得含性能日志与开发文档。

---

## 5. 内存占用

| 进程 | 空闲 | 轻负载 | 单任务求解中 | 多任务并发 |
|---|---|---|---|---|
| Node (Nuxt BFF) | 80–150 MB | 100–200 MB | 120–200 MB | 略增 |
| Julia 后端 | 300–600 MB | 400–800 MB | **1–3 GB** | **2–6 GB+** |
| 浏览器标签 | 150–400 MB | 200–500 MB | 300–600 MB | — |
| **合计** | **0.5–1.2 GB** | **0.7–1.5 GB** | **1.5–4 GB** | **3–8 GB+** |

关键风险：
- 文档指出当前任务与 HTTP 服务**同进程**，已规划改为 supervisor + 独立 worker。打包版若不改，大任务会拖垮 API。
- COPT 环境释放问题已有 GC/等待节流——说明内存峰值已知敏感。
- **建议最低配置：8GB 内存；推荐 16GB；专业多任务 32GB。**

可做的内存治理：
1. Julia 进程设置 `--heap-size-hint` 或定期 `GC.gc()` 策略（已有部分）。
2. 限制并发任务数（按物理内存动态）。
3. 时序结果写 SQLite 而非全内存（当前架构已基本如此）。
4. 任务终态及时关闭 DB 句柄（文档 §8.4 已要求）。

---

## 6. 使用体验

### 6.1 当前形态

- 纯浏览器访问 `localhost:3000`，无安装/桌面集成。
- 无统一启动脚本，需手动起 Julia + `npm run dev`。
- 错误分类体系设计完整（文档 §10.3），但未确认 UI 是否全部落地。

### 6.2 发行版 UX 目标（建议）

1. **双击 `SynerRoll.exe` → 进度条/启动画面 → 浏览器自动打开**。
2. 托盘菜单：打开界面、查看日志、重启后端、退出。
3. 健康状态角标：后端在线/离线/求解中。
4. 端口冲突自动递增，并把最终地址写入本地配置。
5. 首次运行引导：数据目录选择、求解器选择（COPT 需许可 / HiGHS 免费）。
6. 卸载/重装不删用户数据目录。

### 6.3 杀软误报

Python/Go 打包的启动器、无签名 EXE、脚本解压行为可能触发 Windows Defender / 360。  
缓解：代码签名证书、发布说明、或用 C#/.NET 原生编译启动器。

---

## 7. 部署难度清单（按阻塞级排序）

### P0 — 不解决无法发行

| # | 项 | 建议 |
|---|---|---|
| 1 | **COPT 商业许可** | 明确能否随产品分发；无许可时默认 HiGHS；安装器检测许可文件 |
| 2 | **Julia Project.toml 非法** | 改为正确 UUID + 生成并锁定 Manifest.toml |
| 3 | **后端地址硬编码** | 改为环境变量/配置文件（`JULIA_URL`、`PORT`） |
| 4 | **一键启动** | 启动器 + 健康检查 + 自动开浏览器 |

### P1 — 影响稳定与体验

| # | 项 | 建议 |
|---|---|---|
| 5 | 性能探针剥离 | 按开发文档执行 |
| 6 | 数据目录与程序目录分离 | `data/` 用户可写、可备份 |
| 7 | 端口冲突处理 | 自动探测 + 配置持久化 |
| 8 | 日志与诊断包 | 统一 `logs/`，一键导出 |
| 9 | 启动时间优化 | Julia sysimage 预编译 |
| 10 | `projects.json` 单文件膨胀 | 改为 per-project 存储 |

### P2 — 后续迭代

| # | 项 |
|---|---|
| 11 | 自动更新（可选） |
| 12 | 代码签名 |
| 13 | 多语言安装器 |
| 14 | 求解器线程/CPU 配置 UI |

---

## 8. 推荐落地路线

```
阶段 0（本周）     环境可复现
  ├─ 修复 Project.toml + 生成 Manifest.toml
  ├─ 抽出 backend URL / PORT 配置
  ├─ 剥离 perf_probe
  └─ 清理运行数据与旧文件

阶段 1（1–2 周）   便携包 MVP
  ├─ portable Node + portable Julia + 最小 depot
  ├─ nuxt build → .output
  ├─ 启动器 EXE（健康检查 + 拉起双服务 + 开浏览器）
  └─ 干净虚拟机安装验证

阶段 2（2–4 周）   体验与体积
  ├─ Julia sysimage 预编译（启动提速）
  ├─ 数据目录分离 + 备份
  ├─ 托盘 / 启动画面
  └─ Inno Setup 安装包（可选）

阶段 3（可选）     壳升级
  ├─ Tauri 窗口壳
  └─ 自动更新 / 签名
```

---

## 9. 决策点（需你拍板）

1. **交付形态**：便携 zip（解压即用）还是安装器（Inno Setup）？
2. **窗口形态**：浏览器打开，还是 Tauri/Electron 原生窗口？
3. **求解器策略**：  
   - A. 仅 HiGHS（开源、无许可、体积小、部分 MILP 慢）  
   - B. HiGHS 默认 + COPT 可选（需用户自备许可）  
   - C. 强制捆绑 COPT（需商务确认许可条款）
4. **目标用户环境**：仅 Windows x64？是否需要离线内网部署？
5. **最低硬件**：8GB 还是 16GB 起？
6. **是否需要同时支持远程/多人**（影响端口绑定 0.0.0.0 的安全策略）？

---

## 10. 附录：本机实测数据摘要

```
Julia 1.12.6 安装目录     1030 MB
Julia depot 总计           3984 MB
  ├─ packages               106 MB
  ├─ artifacts             1636 MB
  └─ compiled              2222 MB
node_modules               257 MB
backend/data               113 MB (projects 22 + tasks 91)
server/data/projects-旧     28 MB
源码树（含数据）            142 MB
```

开发机已具备：julia 1.12.6、node v24.18.0。无既有打包脚本。
