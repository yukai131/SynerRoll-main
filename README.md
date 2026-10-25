# 新能源发电系统灵活性量化评估软件

综合能源系统建模、滚动仿真、灵活性分析、经济评价与容量规划工作台。前端使用 Nuxt/Vue，计算后端使用 Julia/JuMP，Windows 桌面壳使用 Electron。

## 安装与使用

从 [Releases](https://github.com/yukai131/SynerRoll-main/releases) 下载并运行 `PSFA-Setup-1.0.0-x64.exe`。安装包包含 Electron、Node.js、Julia 和 HiGHS，用户无需额外安装这些环境。COPT 需用户自行安装及配置许可。每次启动使用原有离线许可证 Key 验证，发布单位为龙源（北京）新能源工程技术有限公司。详细说明见 [使用说明](packaging/README.md)。

随附文档：[软件使用说明](docs/PSFA新能源发电系统灵活性量化评估软件使用说明.docx)、[测试报告](docs/测试报告.docx)、[灵活性计算过程示例](docs/灵活性计算过程示例.pdf)。

## 开发与构建

需要 Windows x64、Node.js 22.22.2、Julia 1.12.7。

```powershell
npm ci
julia --startup-file=no --project=backend -e 'using Pkg; Pkg.instantiate()'
# 分别启动计算后端与开发前端
julia --startup-file=no --project=backend backend/server.jl
npm run dev
# 生成 Windows 安装器
npm run dist:win
```

构建规则和核验方式见 [打包说明](docs/packaging.md)。`backend/Manifest.toml` 与 `package-lock.json` 应一并维护，确保构建使用固定依赖。开发产生的数据位于 `backend/data` 和 `server/data`，不会进入安装包。

## 检查

```powershell
npm test
julia --startup-file=no --project=backend backend/test_capacity_planning.jl
julia --startup-file=no --project=backend backend/test_simulation_performance.jl
```

保留的测试用于检验真实功能回归；一次性修复脚本、历史开发笔记和废弃模型入口已清理。

实际安装、求解及卸载结果见 [验收报告](docs/验收报告.md)，后续业务口径见 [需求确认](docs/待确认事项.md)。
