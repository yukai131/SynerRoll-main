# 发行包排除清单

打包 Windows 便携 zip 时，以下内容**不得**进入发行包。

## 运行时数据（用户机器上生成，不随包分发）

| 路径 | 原因 |
|---|---|
| `backend/data/projects/` | 用户项目与边界 SQLite |
| `backend/data/tasks/` | 任务快照、时序库、generated 代码 |
| `backend/data/tasks.db` | 任务索引 |
| `backend/data/capacity-planning/` | 规划产物 |
| `server/data/projects.json` | 项目索引（发行版应写到 `data/` 目录） |
| `data/`（打包后的用户数据目录） | 运行时生成 |

## 开发残留

| 路径 | 原因 |
|---|---|
| `开发阶段性能日志说明.md` | 开发文档；含 perf 探针使用说明 |
| `灵活性计算过程示例.pdf` | 开发/研究文档，体积大 |
| `灵活性计算过程示例.md` | 同上 |
| `监听.py` | 开发调试脚本 |
| `统计行数.py` | 开发统计脚本 |
| `prompt_for_ai.md` | AI 协作提示词 |
| `01-开发文档/` | 开发文档（可选：随包提供精简用户手册） |
| `02-修复文档/` | 内部 Bug 修复记录 |
| `docs/` | 打包研究文档等 |
| `backend/tools/` | 开发辅助脚本（lookup_uuids、test_perf_stub） |
| `backend/test.jl` | 测试入口 |
| `server/data/projects-旧.json` | 已删除 |

## 构建缓存

| 路径 | 原因 |
|---|---|
| `node_modules/` | 用 `.output` 替代 |
| `.nuxt/` | 构建缓存 |
| `.output/` 若打到源码包 | 发行包单独放 `app/.output/` |
| `__pycache__/` | Python 缓存 |
| `.claude/` `.vscode/` `.idea/` | IDE 配置 |

## 性能探针

- `backend/utils/perf_probe.jl`：发行版已为空实现（不写日志）。
- 确认打包产物中**不存在** `performance-summary.txt` / `performance.jsonl`。
- `SYNERROLL_PERF` 环境变量不再产生任何日志。

## 保留项

| 路径 | 原因 |
|---|---|
| `backend/Project.toml` | 依赖声明 |
| `backend/Manifest.toml` | **必须保留**，锁定依赖版本 |
| `config/component-library.json` | 组件库 schema |
| `templates/` | 容量规划模板 CSV |
| `app/` `server/` `composables/` `state/` `types/` `utils/` `assets/` `public/` | 业务源码/构建输入 |
| `backend/components/` `backend/core/` `backend/services/` `backend/routes/` `backend/utils/` | Julia 计算核心 |

## 发行包体积目标

| 部分 | 目标 |
|---|---|
| Julia runtime + 最小 depot + sysimage | 600–1200 MB |
| Electron + asar | 180–250 MB |
| Nitro `.output` | 20–40 MB |
| 业务源码（不含数据） | 5–15 MB |
| **zip 合计** | **900 MB – 1.4 GB** |
