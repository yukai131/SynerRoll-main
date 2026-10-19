# SynerRoll 打包与交付全流程

> 目标读者：开发者。改完代码后，跑一条命令即可产出可交付 zip，不操心打包细节。

---

## TL;DR — 日常出包

```powershell
# 1. 改完代码后，一键出包（约 3-5 分钟）
.\packaging\scripts\release.ps1 -Version 0.2.0

# 2. 产物在：
#    dist\SynerRoll-win64-v0.2.0.zip   ← 发给用户
```

如需跳过耗时步骤：

```powershell
.\packaging\scripts\release.ps1 -Version 0.2.0 -SkipJuliaCopy    # 不重拷 Julia runtime（首次已拷过）
.\packaging\scripts\release.ps1 -Version 0.2.0 -SkipElectron     # 不重装 Electron（已装过）
.\packaging\scripts\release.ps1 -Version 0.2.0 -NoZip            # 只更新 dist 目录，不压缩
```

---

## 一、系统架构（打包视角）

```
用户双击「启动 SynerRoll.bat」
        │
        ▼
┌─────────────────────────────────────────────┐
│  Electron 主进程 (main.js)                  │
│  ├─ 读 config/synerroll.json                │
│  ├─ 拉起 Julia + BFF 子进程                 │
│  ├─ 轮询健康检查 → 开窗                     │
│  └─ 托盘菜单 / 优雅退出                     │
└──────┬──────────────────┬───────────────────┘
       │                  │
       ▼                  ▼
┌──────────────┐   ┌──────────────────┐
│ Julia 计算   │   │ Nuxt BFF         │
│ :8080        │◄──│ :3000            │
│ JuMP/COPT    │   │ 纯 HTTP 转发     │
│ HiGHS        │   │ + 健康检查       │
└──────────────┘   └──────────────────┘
       │
       ▼
   SQLite (data/)
```

**三层运行时**：Electron（壳）→ Node（BFF）→ Julia（计算）。打包 = 把这三者 + 依赖 + 配置组装到一个目录，再压缩。

---

## 二、发行包目录结构

```
SynerRoll-win64/
├── 启动 SynerRoll.bat          ← 用户主入口
├── 启动-命令行模式.bat          ← 备用（图形界面异常时）
├── 停止服务.bat / 导出诊断日志.bat
├── main.js / preload.js        ← Electron 主进程
├── package.json                ← Electron 应用描述
├── README.md                   ← 用户手册
├── config/
│   ├── synerroll.json          ← 运行配置（端口/求解器/目录）
│   └── synerroll.schema.json
├── app/
│   ├── .output/                ← Nuxt standalone（BFF）
│   ├── backend/                ← Julia 源码 + Project/Manifest
│   ├── config/component-library.json
│   └── templates/
├── runtime/
│   ├── julia/                  ← Julia 1.12.x portable
│   └── julia-depot/            ← 最小依赖 + 预编译缓存
├── node_modules/               ← Electron + 少量依赖
├── data/                       ← 用户数据（项目/任务/SQLite）
├── logs/                       ← 运行日志
└── resources/                  ← 图标
```

---

## 三、完整打包流程（自动化脚本内部做了什么）

### 3.1 前置准备（仅首次）

| 步骤 | 命令/操作 | 说明 |
|---|---|---|
| Julia 环境 | `julia --project=backend -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'` | 生成 Manifest.toml |
| 生成图标 | `packaging/resources/icon.ico` | 已生成，可替换 |
| 拷贝 Julia runtime | `robocopy` 系统 Julia → `dist/.../runtime/julia/` | 约 700 MB |
| 生成 depot | `packaging/scripts/gen-depot.ps1` | 独立 depot，约 885 MB |
| 安装 Electron | `npm install electron` | 需 `ELECTRON_MIRROR` 加速 |

### 3.2 每次出包（`release.ps1` 自动执行）

```
[1] nuxt build
     └─ 产出 .output/（Nuxt standalone + BFF 路由）

[2] 组装 dist 目录
     ├─ .output → app/.output/
     ├─ backend 源码 → app/backend/（不含 data/tools/test）
     ├─ component-library.json + templates → app/
     ├─ packaging/config/ → config/
     ├─ packaging/electron/ → 根目录
     ├─ bat 脚本 + README + icon
     └─ （可选）拷贝 julia runtime / depot

[3] 体积裁剪
     ├─ 删除 share/doc, include, uninstall
     ├─ 删除 depot registries/logs/scratchspaces
     ├─ 删除 Pkg/REPL/Test/Profile 等无用预编译缓存
     ├─ 删除 Electron 多余 locales（保留 en/zh）
     └─ 删除 .output source maps

[4] 压缩
     └─ tar zip → SynerRoll-win64-v{版本}.zip
```

### 3.3 裁剪规则详解

| 删除项 | 体积 | 原因 |
|---|---|---|
| `share/julia/compiled/Pkg` | 157 MB | 运行时不用 Pkg |
| `share/julia/compiled/REPL*` | 86 MB | 无交互 REPL |
| `share/julia/compiled/Profile` | 14 MB | 不做性能分析 |
| `depot/compiled/Pkg+REPL+Test` | 135 MB | 同上 |
| `share/julia/doc` | 18 MB | 文档 |
| Electron locales（非中英） | 28 MB | 用户不需要 |
| `depot/registries` | 11 MB | 仅 Pkg 安装需要 |
| **合计** | **~450 MB** | |

**保留 `share/julia/test/`**！REPL 预编译依赖其中的 `testhelpers/FakePTYs.jl`，删了会崩。

**保留 `.output/server/chunks/build/`**！SSR 页面渲染依赖。

---

## 四、改动代码后的出包决策

| 你改了什么 | 需要跑什么 | 耗时 |
|---|---|---|
| 前端 Vue/CSS/TS | `release.ps1` | ~3 分钟 |
| BFF (`server/`) | `release.ps1` | ~3 分钟 |
| Julia 计算 (`backend/`) | `release.ps1` | ~3 分钟 |
| Julia 依赖 (`Project.toml`) | 先跑 `gen-depot.ps1`，再 `release.ps1` | ~10 分钟 |
| Electron 壳 (`packaging/electron/`) | `release.ps1` | ~3 分钟 |
| 配置 schema | `release.ps1` | ~3 分钟 |
| 仅文档 | 手动拷贝 `README.md` 到 dist，重打 zip | ~1 分钟 |

**日常改功能代码 = 只跑 `release.ps1`。**

---

## 五、自动化脚本：`release.ps1`

### 用法

```powershell
# 基本用法（推荐）
.\packaging\scripts\release.ps1 -Version 0.2.0

# 跳过已就绪的重量级步骤（二次打包加速）
.\packaging\scripts\release.ps1 -Version 0.2.1 -SkipJuliaCopy -SkipElectron

# 只更新 dist，不打 zip（本地测试用）
.\packaging\scripts\release.ps1 -Version 0.2.1 -NoZip

# 自定义输出目录
.\packaging\scripts\release.ps1 -Version 0.2.0 -DistDir "D:\Releases\SynerRoll"
```

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Version` | `0.0.0` | 版本号，写入 zip 文件名 |
| `-DistDir` | `<项目>/dist/SynerRoll-win64` | 输出目录 |
| `-SkipJuliaCopy` | false | 跳过 Julia runtime 拷贝 |
| `-SkipElectron` | false | 跳过 Electron npm install |
| `-NoZip` | false | 不打压缩包 |
| `-Clean` | false | 先清空 dist 再组装 |

### 产物

```
dist/
├── SynerRoll-win64/                 ← 完整安装目录（可直接测试）
└── SynerRoll-win64-v{版本}.zip      ← 分发包（发给用户）
```

---

## 六、验证清单（出包后自检）

```powershell
# 1. 起服务
cd dist\SynerRoll-win64
.\启动\ SynerRoll.bat

# 2. 等 ~20 秒，检查健康
Invoke-RestMethod http://127.0.0.1:3000/api/v1/health
# 期望: ready=True, solvers 包含 COPT/HiGHS

# 3. 浏览器打开 http://127.0.0.1:3000 手工点一遍核心流程
#    建模 → 导入边界 → 创建任务 → 看结果

# 4. 停止
.\停止服务.bat
```

### 发给用户前确认

- [ ] `启动 SynerRoll.bat` 能正常拉起
- [ ] 健康检查 `ready: true`
- [ ] 核心业务流程可走通
- [ ] `logs/` 不含开发性能日志（`performance-*.txt`）
- [ ] `data/` 不含你的开发测试数据
- [ ] zip 大小合理（约 490 MB ± 50）

---

## 七、用户使用流程（README.md 里已有，这里是摘要）

```
解压 zip
   │
   ▼
双击「启动 SynerRoll.bat」
   │
   ▼  等待 20-40 秒（首次）/ 20 秒（后续）
   │
主界面自动打开
   │
   ▼
建模 → 配边界 → 跑仿真 → 看结果
   │
   ▼
关窗 = 最小化到托盘；托盘菜单「退出」= 完全退出
```

用户侧辅助入口：
- `启动-命令行模式.bat` — 图形界面打不开时
- `停止服务.bat` — 进程残留时
- `导出诊断日志.bat` — 反馈问题时打包日志

---

## 八、配置文件速查（`config/synerroll.json`）

```json
{
  "juliaPort": 8080,
  "bffPort": 3000,
  "host": "127.0.0.1",
  "solver": "HiGHS",
  "dataDir": "data",
  "logDir": "logs",
  "julia": { "heapSizeHintMB": 0, "startupTimeoutSec": 120 },
  "ui": { "openDevTools": false, "windowWidth": 1440, "windowHeight": 900 }
}
```

改配置后**重启 SynerRoll** 生效。端口占用时自动 +1。

---

## 九、常见问题

### 出包后启动很慢 / 卡在启动画面

首次冷启动 20-40 秒正常（Julia 加载）。超过 2 分钟查 `logs/launcher.log` + `logs/julia.log`。

### `Pkg`/`REPL` 相关报错

预编译缓存被裁掉了但某依赖间接引用。把出错包名加入 `trim-portable.ps1` 的**排除列表**（即不删它的 compiled 缓存），重新出包。

### 想加回某个被裁掉的包

```powershell
# 用系统 Julia 重新预编译到 dist 的 depot
$env:JULIA_DEPOT_PATH = "D:\...\dist\SynerRoll-win64\runtime\julia-depot"
julia --project="D:\...\dist\SynerRoll-win64\app\backend" -e "using Pkg; Pkg.precompile()"
```

### Electron 二进制下载失败

```powershell
$env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
npm install
```

### zip 太大 / 想更小

考虑用 7-Zip 极限压缩（`7z a -mx=9`），约可再降 10-15%。或进一步裁剪 `depot/compiled` 中非核心包。

---

## 十、文件索引

| 文件 | 用途 |
|---|---|
| `packaging/scripts/release.ps1` | **一键出包**（日常唯一入口） |
| `packaging/scripts/build-portable.ps1` | 组装 dist（release 内部调用） |
| `packaging/scripts/trim-portable.ps1` | 体积裁剪（release 内部调用） |
| `packaging/scripts/gen-depot.ps1` | 生成最小 Julia depot |
| `packaging/scripts/test-full-chain.ps1` | 全链路启动验证 |
| `packaging/electron/main.js` | Electron 主进程 |
| `packaging/config/synerroll.json` | 默认配置 |
| `packaging/README.md` | 用户手册（复制到 dist） |
| `docs/exe-packaging-research.md` | 技术选型研究 |
| `docs/exe-packaging-plan.md` | 实施方案 |
| `docs/packaging-exclude.md` | 发行包排除清单 |
| `docs/packaging-guide.md` | **本文** |
