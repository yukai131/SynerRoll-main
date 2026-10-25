# Windows 安装包构建

构建机需要 Windows 10 1903+/11 x64、Node.js 22.22.2、Julia 1.12.7。首次获取依赖和 PackageCompiler 工具链需联网；用户安装无需联网。

```powershell
npm ci
julia --startup-file=no --project=backend -e 'using Pkg; Pkg.instantiate()'
npm run dist:win
# 仅后端应用代码或包装变动时复用已验证的运行时、镜像和前端
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/scripts/build.ps1 -SkipRuntime -SkipSysimage -SkipFrontend
```

构建脚本先构建 Nuxt，按白名单复制后端、模板及配置，导出 Manifest 中固定版本的 Julia 包和 Windows artifacts；再用独立的 `packaging/compiler` 环境构建通用 x64 依赖镜像，最后生成 NSIS 安装器和 SHA256。COPT SDK、许可、测试、开发数据及编译工具链不进入安装包。`packaging/release-stage` 为构建缓存。

输出为 `dist/PSFA-Setup-1.0.0-x64.exe` 和 `dist/psfa/win-unpacked/PSFA.exe`。品牌由 `config/brand.json` 维护。源代码改动不写入系统镜像，避免冻结开发机路径和用户数据目录；镜像中只包含固定版本依赖，需与随包 Julia/Manifest 同步重建。

NSIS 解压后同步运行内置 Node 的 `prepare-runtime.cjs`，使用内置 Julia 检查 HiGHS 求解、SQLite 读写及缓存。本步骤失败不报告安装完成，可以重试，日志位于用户目录。Electron 和安装准备共用 `runtime.cjs` 的启动参数、depot 策略及系统镜像。

全部用户持久数据位于 `%APPDATA%\PSFA`，升级和卸载保留。服务只监听本机，使用动态端口。单层、多层仿真与容量规划各自使用独立 Julia 工作进程；应用退出时停止整个子进程树。构建时以 rcedit 保留 Julia 原有清单并加入 UTF-8 activeCodePage；原签名可执行文件保存在 julia-original.exe，原生 DLL 不修改。此应用级设置解决中文路径下镜像加载和原生缓存写入，不更改系统区域配置。

容量规划预算在 worker 内扣除 Julia 编译时间；在场景之间检查预算，并将剩余预算设置为原生求解时限。取消由 HTTP 父进程直接终止相应 worker。自定义测试 worker 无编译时钟，测试注入命令仍使用父进程墙钟看门狗。

验收需覆盖离线及无 COPT 启动、中文安装和数据路径、新用户目录、单层/多层及灵活性、经济性、容量规划、取消、WebSocket、退出清理、升级和卸载数据保留。`SYNERROLL_USER_DATA` 可指向隔离测试目录。

构建结束后运行 `node packaging/scripts/audit-package.mjs`，核对打包文件与当前源码、前端产物和校验和一致，检查必要运行时以及 HiGHS/COPT 分发边界。验收已安装的软件可运行 `node packaging/scripts/verify-services.mjs <安装目录> <隔离用户目录>`；它仅使用随包运行时，在最小 PATH、无开发机 Julia depot 的环境下执行完整业务链路，检查 SQLite 并清理测试任务，最后结束自己启动的进程。该脚本会创建测试项目并删除其中的测试计算任务，必须使用专用用户目录。

预编译镜像方案依据 [PackageCompiler 系统镜像文档](https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html)；安装钩子依据 [electron-builder NSIS 文档](https://www.electron.build/nsis/)。当前未配置签名证书。
UTF-8 进程清单依据 [Microsoft 文档](https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page)。支持基线为 Windows 10 1903+/11；Julia 可执行文件资源编辑后需纳入项目方后续的发布签名流程。

正式品牌由 displayName（中文显示名称）和 productName（PSFA 文件/数据目录标识）分离维护。Electron 的 author 元数据使用含 name 的对象，确保 NSIS 发布单位正确；afterPack 同步写入可执行文件的公司名、产品名、图标和版本资源。所有窗口均移除菜单栏，许可证与启动页面位于 packaging/electron/ui，Key 校验值由项目方提供的旧软件迁入；许可校验失败或取消时不启动计算服务。
