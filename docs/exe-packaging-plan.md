# SynerRoll Windows 便携包 — 实施方案

> 已确认决策（2026-09）：
> - 交付形态：**便携 zip 解压即用**
> - 界面：**Electron 壳**
> - 求解器：**HiGHS 默认 + COPT 可选**
> - 目标环境：**仅 Windows x64，内网离线**

---

## 1. 目标产物

```
SynerRoll-win64-x.y.z.zip          约 900MB–1.4GB（压缩后）
└── SynerRoll/
    ├── SynerRoll.exe              Electron 主进程入口
    ├── resources/
    │   ├── app.asar               前端构建产物 + Electron 主进程代码
    │   ├── app.asar.unpacked/     需要原生文件的资源
    │   └── icons/
    ├── runtime/
    │   ├── node/                  可选：若 Electron 已带 Node，可省略
    │   ├── julia/                 portable Julia 1.12.x
    │   │   ├── bin/julia.exe
    │   │   └── ...                精简 stdlib
    │   └── julia-depot/           最小依赖（预编译 sysimage）
    │       ├── packages/          JuMP, HiGHS, COPT, Oxygen, SQLite, ...
    │       ├── artifacts/         仅必要 JLL
    │       └── compiled/          sysimage
    ├── app/
    │   ├── .output/               Nuxt Nitro standalone（BFF）
    │   └── backend/               Julia 源码 + Project.toml + Manifest.toml
    ├── data/                      用户数据（项目、任务、SQLite）— 可写
    ├── logs/                      运行日志
    └── config/
        └── synerroll.json         端口、求解器、数据目录等
```

## 2. 进程与通信架构

```
┌─────────────────────────────────────────┐
│  SynerRoll.exe  (Electron Main)         │
│  ├─ 托盘 / 菜单 / 启动画面               │
│  ├─ 进程管理（拉起/守护/优雅退出）        │
│  └─ BrowserWindow                       │
│       │                                 │
│       │  加载 http://127.0.0.1:PORT     │
│       ▼                                 │
│  ┌──────────────┐   ┌────────────────┐  │
│  │ Nuxt Nitro   │──▶│ Julia Backend  │  │
│  │ BFF :3000    │   │ Oxygen :8080   │  │
│  └──────────────┘   └────────────────┘  │
└─────────────────────────────────────────┘
```

Electron 主进程职责：
1. 启动时读 `config/synerroll.json`（端口、求解器、数据目录）。
2. 健康检查 → 拉起 Julia（`julia --project=app/backend app/backend/server.jl`）。
3. 拉起 Nitro（`node app/.output/server/index.mjs`，或由 Electron 内嵌 http 服务托管静态资源 + 反代 API）。
4. 轮询 `/api/v1/health` 就绪后 `BrowserWindow.loadURL`。
5. 托盘菜单：打开界面 / 查看日志 / 重启计算引擎 / 退出。
6. 退出时 SIGTERM 子进程，等待落盘后再退。

端口策略：配置文件指定，占用则自动 +1 并写回；Electron 把最终端口注入前端（`window.__SYNERROLL_CONFIG__` 或 query）。

## 3. 求解器策略

| 场景 | 行为 |
|---|---|
| 默认 | `algorithm.solver = "HiGHS"`，开箱即用 |
| 用户有 COPT 许可 | 配置页选择 COPT；启动时检测许可，失败则回退 HiGHS 并提示 |
| 许可文件位置 | `data/licenses/copt/` 或环境变量 `COPT_LICENSE_DIR` |

代码侧（`backend/utils/model_utils.jl`）已支持 `"HiGHS"|"COPT"`，只需保证：
- 发行包**不捆绑** COPT 许可文件；
- 启动健康检查探测 COPT 是否可用；
- UI 明确标注「COPT 需自备许可」。

## 4. 体积与内存预算

| 项 | 目标 | 手段 |
|---|---|---|
| Electron + asar | 180–250 MB | 不 bundle node_modules 里的 dev 依赖 |
| Julia runtime | 250–400 MB | 裁剪未用 stdlib / docs |
| Julia depot + sysimage | 400–800 MB | 仅必要包 + 预编译 sysimage |
| Nitro .output | 20–40 MB | |
| 业务源码 backend | 5–15 MB | 剔除 data/文档 |
| **zip 合计** | **900MB–1.4GB** | 7z 极限压缩可再降 |
| **安装后占用** | **1.5–2.2 GB** | |

| 场景 | 内存 |
|---|---|
| 空闲（Electron+Node+Julia） | 0.8–1.5 GB |
| 编辑画布 | 1–2 GB |
| 单任务求解 | 2–4 GB |
| 多任务 | 4–8 GB+（需限并发） |

最低 8 GB / 推荐 16 GB。

## 5. 启动性能

| 阶段 | 现状 | 目标 |
|---|---|---|
| Electron 主进程 | — | < 1 s |
| Julia 加载模块 | 5–20 s | **3–8 s**（sysimage） |
| Nitro 就绪 | 2–5 s | 2–4 s |
| 首次任务 JIT | 30 s–数分钟 | 保留预热任务或 sysimage 吸收 |
| **开窗可交互** | — | **≤ 15 s** |

手段：
1. `PackageCompiler.create_sysimage` 预编译 JuMP/HiGHS/COPT/Oxygen/JSON3/SQLite/DataFrames 等到一个 sysimage。
2. Electron 启动画面（原生 `BrowserWindow` 加载本地 splash HTML）直到健康检查通过。
3. 可选「预热一次空模型」在后台跑，吸收 JIT。

## 6. P0 必做项（打包前置）

| # | 项 | 具体动作 | 产出 |
|---|---|---|---|
| 1 | 修复 Julia 环境 | 改写 `backend/Project.toml` 为合法 UUID；`Pkg.resolve` + 生成 `Manifest.toml` | 可复现环境 |
| 2 | 配置化后端地址 | 新增 `config/synerroll.json` + 读取逻辑；替换 20+ 处 `localhost:8080` 硬编码；`nuxt.config.ts` 的 `juliaWsBase` 改运行时注入 | 可换端口 |
| 3 | 剥离性能探针 | 删除 `utils/perf_probe.jl`、`server.jl` include、所有 `perf_*` 调用 | 合规发行 |
| 4 | 清理运行数据 | 移出 `backend/data/tasks|projects`、`projects-旧.json`、开发 PDF/脚本 | 体积与合规 |
| 5 | 健康检查接口 | 增加 `GET /api/v1/health`（BFF）与 `GET /api/health`（Julia） | 启动器依赖 |
| 6 | 求解器探测 | 启动时检测 HiGHS/COPT 可用性 | UI 提示 |

## 7. 分阶段计划

### 阶段 0 — 环境与配置（0.5–1 周）
- [ ] 修复 `Project.toml`，锁定 `Manifest.toml`
- [ ] 配置文件 + 端口/求解器可配置
- [ ] 剥离 `perf_probe`
- [ ] 清理数据与开发残留
- [ ] 健康检查 API

### 阶段 1 — 便携包 MVP（1–2 周）
- [ ] `nuxt build` → `.output` standalone
- [ ] 精简 Julia runtime + depot
- [ ] sysimage 预编译脚本
- [ ] Electron 主进程：进程管理 + 启动画面 + BrowserWindow + 托盘
- [ ] 组装 zip 结构，干净 Win10/11 虚拟机验证
- [ ] README（解压即用、COPT 许可说明、故障排查）

### 阶段 2 — 体验与稳定（1–2 周）
- [ ] 端口冲突自动递增
- [ ] 日志落盘 + 一键导出诊断包
- [ ] 数据备份/迁移说明
- [ ] 杀软白名单说明；可选代码签名
- [ ] 内存/并发限制配置

### 阶段 3 — 可选增强
- [ ] 自动更新（内网文件服务器）
- [ ] COPT 许可管理 UI
- [ ] 多实例/远程只读（若需要）

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Julia sysimage 与 COPT 动态库冲突 | 启动失败 | 分场景构建 sysimage；COPT 可选加载 |
| 杀软误报（无签名 Electron/启动器） | 用户无法运行 | 代码签名；发布哈希；白名单文档 |
| 内网无法下载 Julia 包 | 首次安装失败 | depot 全量离线打包；`Pkg.offline` |
| 内存不足杀进程 | 任务失败 | 并发上限；OOM 提示；任务续跑（远期） |
| Electron 版本漏洞 | 安全 | 固定已验证版本，出包后扫描 |

## 9. 与开发环境的差异

| | 开发 | 发行包 |
|---|---|---|
| 前端 | `nuxt dev` | `.output` Nitro |
| Julia | 系统 Julia + 全局 depot | 内置 runtime + 最小 depot |
| 数据 | `backend/data`、`server/data` | `data/`（可配置） |
| 端口 | 硬编码 8080 | 配置文件 |
| 求解器 | COPT/HiGHS | HiGHS 默认，COPT 可选 |
| 性能探针 | 可开 | 移除 |
| 入口 | 手动两条命令 | `SynerRoll.exe` |
