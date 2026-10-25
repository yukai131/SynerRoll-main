# 新能源发电系统灵活性量化评估软件 Windows 使用说明

支持 Windows 10 1903 及更新版本、Windows 11 x64。运行 `PSFA-Setup-1.0.0-x64.exe`，选择安装位置，等待计算环境准备完成，然后从桌面或开始菜单打开“新能源发电系统灵活性量化评估软件”。每次启动输入与龙源旧软件相同的许可证 Key；本地校验，不联网、不记住 Key，普通和特殊 Key 均可进入完整业务。安装准备期间请不要关闭安装器。

软件内置 Electron、Node.js、Julia、HiGHS 和通用 x64 预编译镜像。用户侧安装及 HiGHS 求解无需下载运行环境。安装器会同步检查 Julia/HiGHS 并准备本机缓存，详细日志为 `%APPDATA%\PSFA\logs\installation-prepare.log`。安装准备失败可重试。新设备模型或首次使用的运算路径仍可能触发少量编译。

数据、日志、设置与 Julia 缓存位于 `%APPDATA%\PSFA`。可通过软件内“系统设置”的数据目录、日志目录和启动设置按钮打开。主窗口默认最大化，保留 Windows 标题栏，无文件/视图菜单，支持 F11 全屏、Esc 退出全屏，正式版禁用开发者工具。首次改名升级时，若 PSFA 尚无数据目录，会复制旧 `%APPDATA%\SynerRoll\data`，保留原数据。升级、卸载均保留用户数据。关闭窗口会停止应用及其仿真、规划工作进程，运行中的任务会中断。

默认使用 HiGHS。需要 COPT 时请自行安装 COPT，配置有效许可及 `COPT_HOME`，使 `%COPT_HOME%\bin\copt.dll` 存在，然后重新启动 PSFA。软件仅含 COPT Julia 接口，不含 COPT 原生库和许可。许可在实际求解时检查，出错不会自动更换求解器。求解器高级参数当前仅保存设置，实际使用求解器默认值。

单层、多层仿真均可启用灵活性评价；单层评价层须与仿真目标层一致。普通仿真和容量规划均在独立进程运行，取消会停止相应工作进程。容量规划最长计算时间不含工作进程启动和 Julia 编译；经济指标阈值按软惩罚参与评价。

启动失败请查看 `%APPDATA%\PSFA\logs` 的 `launcher.log`、`julia.log`、`bff.log`。服务只监听本机并自动选择空闲端口。设置文件为 `%APPDATA%\PSFA\settings.json`，默认 Julia 启动超时为 900 秒。随包 Julia 使用应用级 UTF-8 清单，支持中文安装目录、中文用户目录和原生预编译缓存，无需更改系统区域设置。

第三方许可见 `resources/THIRD-PARTY-NOTICES.txt`、Electron 和 Julia 自带许可。品牌维护见源码 `docs/品牌信息填写.md`。