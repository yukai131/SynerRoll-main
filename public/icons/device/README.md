# 图标资源说明

你只需要替换本目录下的 PNG 文件，**文件名保持不变**即可。

## 规格建议

- 正方形，主体居中
- 建议 ≥512×512
- 透明底或统一浅色纯色底
- 风格尽量统一（光比、裁切、色调）
- 不要烧字 / 水印

## 文件映射

| 文件 | 对应组件 | 中文 |
|------|----------|------|
| wind-turbine.png | WT | 风机 |
| solar-panel.png | PV | 光伏 |
| hydro.png | HYDRO | 常规水电 |
| grid.png | GRID | 电网 |
| gas-plant.png | GP | 气电机组 |
| coal-plant.png | CP | 燃煤机组 |
| chp.png | CHP | 热电联产 |
| battery.png | ES | 电化学储能 |
| fuel-storage.png | FS | 飞轮储能（沿用历史文件名） |
| air-storage.png | CS | 压缩空气储能 |
| water-storage.png | PS | 抽水蓄能 |
| hydrogen-storage.png | HS | 储氢罐 |
| electrolyzer.png | ET | 电解槽 |
| load.png | ELOAD | 分时电负荷 |
| hydrogen-load.png | HLOAD | 分时氢负荷 |
| heat-load.png | QLOAD | 分时热负荷 |
| bus-electric.png | ELEC_BUS | 电总线 |
| bus-thermal.png | THERMAL_BUS | 热总线 |
| bus-hydrogen.png | H2_BUS | 氢总线 |

## 其他 PNG

| 路径 | 用途 |
|------|------|
| `public/logo.png` | 顶栏 Logo（建议 ≥256） |
| `packaging/resources/icon-256.png` | 桌面应用图标 |
| `public/favicon.ico` | 浏览器标签图标（可选替换） |

2026-10-19：已按组件中文名称替换为用户提供的全部 19 张新图例（含补充的“压缩空气储能”），保留原始 PNG。
侧栏和画布中的设备图标共用这些资源；总线图例用于组件库，总线在画布中继续以可连接的线条显示。
