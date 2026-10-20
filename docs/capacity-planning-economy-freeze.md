# 容量规划经济口径（冻结）

> 状态：2026 业务拍板冻结，实现与本文一致。变更须改本文并回归 `test_capacity_planning.jl`。

## 已冻结口径

| 项 | 口径 | 实现位置 |
|----|------|----------|
| **B6 LCOE 分母** | **上网电量**（发电类组件正功率时序积分 × 步长，年化后） | `lifecycle_economics.jl` / `evaluate_scenario_operating_cost.energy_kwh` |
| **B7 价税** | 售电收益按**含税**做 13% 价税分离；经营成本按**不含税**并全额计提进项（可抵扣比例可配） | `evaluate_lifecycle` |
| **B8 营业税金及附加** | **12%**（城建 7% + 教育附加 5%），`economics.lifecycle.surcharge_rate` 可覆盖 | `LifecycleFinancialParams.surcharge_rate` |

**不与运行经济面板强行统一价税**——规划生命周期与任务经济面板口径独立，对比时需注明。

## 工程化补充（B9–B12）

| 项 | 默认 | 配置键（`economics.lifecycle.*`） | 说明 |
|----|------|----------------------------------|------|
| **B9 固定运维** | 0 | `fixed_om_ratio`（×CAPEX/年）、`fixed_om_wan`（万元/年） | 并入年经营成本 |
| **B10 替换重购** | 按 `depreciation_years` 整数倍年末追加设备原值 | `replace_cycle_years`（0=用折旧年限） | 现金流出；不重提折旧（保守） |
| **B11 补贴 / 容量补偿** | 0 | `subsidy_yuan_per_kwh`、`capacity_compensation_yuan_per_kw_year` | 计入年收益（含税后价税分离） |
| **B12 IRR 约束惩罚** | 权重 1.0 = 短差×CAPEX | `irr_penalty_weight` | 进 `constraintPenalty` |
| slack 单价 | `algorithm.slackPenalty` | 项目算法配置 | 运行成本项，不进 K-306 |

## 不做（范围外）

- 方案比较碳 / 可靠性 / 灵活性列  
- 在线预测 / 控制  
- 多目标 Pareto（本阶段）  
- 亚小时典型日、k 线时间窗聚类（待数据线）  

## 与仿真的业务差异（保留）

时间窗（代表日 24h）、技术指标仅规划侧、优化目标口径、窗口截断 — 与仿真计算不同属业务需要，不在本文件对齐。
