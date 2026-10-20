# 经济性评价模块 — 当前已支持内容与代码位置

> 本文档说明截至当前代码版本，经济性评价模块已支持的设备类型、成本项、公式口径、动态刷新与派生指标。

---

## 一、设计要点

1. **后验统计**：基于覆盖模式 `timeseries.db` 中的物理量曲线计算，不依赖 JuMP 目标值。
2. **目标函数口径明确**：每条 `CostItem` 带 `inObjective` 与 `objectiveFlag`，与组件 `objectives.*_objective_on` 开关一致。
3. **动态刷新**：任务运行中也可调用（`GET /api/task/{id}/economy`），按 `[sim_start, covered_end)` 截取已覆盖数据。
4. **派生指标**：累计成本、日均、月均估算、年化估算（日均 × 365 粗估）。

---

## 二、已支持的设备类型

| 设备类型 | 代码 | 读取物理量 | 时序 key 示例 |
|---------|-----|-----------|--------------|
| 燃煤机组 | `CP` | 出力 `power` | `CP\|E_CP_{code}\|power#{layer}` |
| 风机 | `WT` | 出力、弃风 | `WT\|E_WT_{code}\|power#`、`WT\|E_WT_cut_{code}\|cut#` |
| 光伏 | `PV` | 出力、弃光 | `PV\|E_PV_{code}\|power#`、`PV\|E_PV_cut_{code}\|cut#` |
| 电化学储能 | `ES` | 能量、充、放 | `ES\|E_ES_*` |
| 气电 | `GP` | 出力 | `GP\|E_GP_{code}\|power#` |
| 热电联产 | `CHP` | 出力 | `CHP\|E_CHP_{code}\|power#` |
| 电解槽 | `ET` | 制氢功率 | `ET\|E_ET_{code}\|power#` |
| 电网 | `GRID` | 售电 `sell`、购电 `buy` | `GRID\|E_GRID_in_*`（上送）、`GRID\|E_GRID_out_*`（购入） |
| 储氢/飞轮/压缩空气/抽蓄 | `HS/FS/CS/PS` | 能量、充、放 | 同 ES 模式 |
| 常规水电 | `HYDRO` | 出力 | `HYDRO\|E_HYDRO_{code}\|power#` |

> 负荷类 `ELOAD/HLOAD/QLOAD` 不参与经济性计算。

**启停状态**：结果库不持久化 γ 启停变量。后验计算**不使用 `F_*`（燃料/辅助功率）当状态**（连续量会造成伪跳变），改为从出力推导：`status[t] = power[t] > ε`。

---

## 三、成本项与公式

| 设备 | cost_type | 公式 | 目标开关 | 单位口径 |
|------|-----------|------|---------|---------|
| CP/GP/CHP/ET/HYDRO | `om_cost` | Σ(出力 × 率 × Δt) | `om_objective_on` | 率：元/kWh，参数侧 × step_hours |
| 同上 | `on_off_cost` | 启停次数 × 单次成本 | `on_off_objective_on` | **元/次，不乘 Δt** |
| 同上 | `adjust_cost` | Σ\|实际-计划\| × 率 × Δt | `adjust_objective_on` | 率：元/kWh |
| WT/PV | `om_cost` | Σ(出力 × 率 × Δt) | `om_objective_on` | |
| WT/PV | `cut_cost` | Σ(弃风/光 × 率 × Δt) | `cut_objective_on` | |
| ES/HS/FS/CS/PS | `om_cost` | Σ(充+放) × 率 × Δt | `om_objective_on` | |
| 储能 | `adjust_cost` | Σ(\|Δ充\|+\|Δ放\|) × 率 × Δt | `adjust_objective_on` | |
| GRID | `purchase_cost` | Σ(购电 × 买价 × Δt) | `exchange_objective_on` | 正成本 |
| GRID | `sell_revenue` | -Σ(售电 × 卖价 × Δt) | `exchange_objective_on` | 负成本 |
| BUS | `shortage_penalty` / `excess_penalty` | Σ(松弛) × 惩罚系数 | **不进目标** | 单独标注可行性 |

### 口径说明

- **`inObjective`**：该成本项在对应时层是否勾选进入目标函数。未勾选仍统计展示（灰色 `[未选入目标]`）。
- **松弛惩罚**：单独列出；`objectiveValue` / `totalCost` 均不含松弛。
- **售电收益**：负成本，单独列出，可抵扣购电。
- **时间步长**：能量类成本率在参数解析时 × `time_step_hours`；`on_off_cost` 为事件成本，**不缩放**（与 `model-common.jl` 一致）。

---

## 四、动态评价（仿真进行中）

| 点 | 行为 |
|----|------|
| API | `GET /api/task/{id}/economy` 不再要求 `status=completed` |
| 统计范围 | `[sim_start_time, covered_end)`；运行中 `covered_end = cur_time` |
| 前端 | 与运行总览一并轮询（约 2s 节流），显示「运行中 · 截至 xx:xx」 |
| `isPartial` | true 表示未完成，按已覆盖时段统计 |

---

## 五、派生指标（metrics）

```json
{
  "coveredStart": "0:00",
  "coveredEnd": "18:00",
  "elapsedHours": 18.0,
  "elapsedDays": 0.75,
  "dayBasis": "hours | calendar",
  "isPartial": true,
  "progressRatio": 0.75,
  "netCost": 12345.67,
  "layerCount": 3,
  "aggregation": "mean",
  "objectiveValue": 12000.0,
  "dailyAvgCost": 16460.89,
  "monthlyEstimateCost": 493826.7,
  "annualEstimateCost": 6008226.0,
  "byCostType": {
    "om_cost": { "total": 1000, "daily": 1333, "monthly": 40000, "annual": 486666 }
  }
}
```

换算规则：

- 日均 = 平均净成本 / 已覆盖天数
- 多时层总览：各时层为同一时段的并行求解，`metrics` 取有效时层数学平均（空层不计入分母），不再跨层累加
- 月均估算 = 日均 × 30
- 年化估算 = 日均 × 365（粗估，非财务全生命周期）
- 多日任务优先用日历天数（`sim_start_date` / `sim_end_date`）；否则按小时 / 24

---

## 六、前端展示字段映射

| 前端 | 后端字段 |
|------|---------|
| 运行中徽标 | `isPartial` + `coveredEnd` |
| 平均净成本 | `metrics.netCost` |
| 日均 / 月均 / 年化 | `metrics.dailyAvgCost` / `monthlyEstimateCost` / `annualEstimateCost` |
| 覆盖进度 | `metrics.progressRatio` |
| 分项年化表 | `metrics.byCostType` |
| 目标/未选标注 | `allCostItems[].inObjective` |
| 公式说明 | `allCostItems[].formula` |
| 目标开关名 | `allCostItems[].objectiveFlag` |

代码位置：

- 类型定义：`types/api.ts`（`CostItem` / `EconomyMetrics` / `EconomyEvaluationResult`）
- 前端展示：`app/pages/tasks/index.vue`「经济性分析」
- API 封装：`composables/api/useTaskApi.ts` → `getEconomy`
- BFF：`server/api/v1/task/[id]/economy.get.ts`
- Julia 路由：`backend/routes/task.jl` `GET /api/task/{id}/economy`
- 评价服务：`backend/services/economy_evaluation_service.jl`
- 纯计算：`backend/utils/economy_calculator.jl`

---

## 七、与优化模型的一致性

| 成本 | 模型（model-base） | 后验评价 |
|------|-------------------|---------|
| 运维 | `sum(P) * om_cost`（om_cost 已 ×Δt） | 同左 |
| 启停 | `sum(γ_start+γ_stop) * on_off_cost`（**不 ×Δt**） | 跳变次数 × on_off_cost |
| 调整 | `sum\|P-P_plan\| * adjust_cost` | 同左 |
| 购售电 | `sum(buy*bp - sell*sp)` | 购电正、售电负 |
| 松弛 | 目标内惩罚 | 单独列出，不进目标展示 |

> 2026-09 修正：`on_off_cost` 不再乘 `time_step_hours`（单位为元/次）；启停状态不再误用 `F_*` 序列。

---

## 八、燃料价格与 GRID 分时电价（2026-09）

### 8.1 数据来源

| 设备 | 边界 | 含义 | 单位 | 兜底参数 |
|------|------|------|------|----------|
| CP / GP / CHP | 组件绑定的 `price` 边界 | 燃料价格曲线 | 元/kWh燃料 | `commonEconomicParams.fuel_price` |
| GRID | meaning=`buy_price` 的边界 | **仅**购电分时电价 | 元/kWh电 | `buy_price` |
| GRID | meaning=`sell_price` 的边界 | **仅**售电分时电价 | 元/kWh电 | `sell_price` |
| CP/GP/CHP | meaning=`fuel_price` 的边界 | 燃料分时价 | 元/kWh | `fuel_price` |

> **电价按边界 meaning 识别**（与仿真建模 `resolve_grid_price_vectors` 同口径）：
> 优先精确匹配 `buy_price` / `sell_price` / `fuel_price`；找不到时 generic 回退到该组件绑定的第一条价格类曲线（购/售可共用同一条）；完全没有价格边界时用组件标量。不再依赖 boundaryIds 绑定顺序。购/售电价不同请分别绑定对应 meaning。

边界配置页「价格配置」栏目录入；在编辑器中把组件关联到对应边界。

### 8.2 计算公式

燃料投入 `F[t] = E[t] / η`（与模型 C1 约束一致；结果库有 `F_*` 时优先用之）：

```text
fuel_cost = Σ F[t] × fuel_price[t] × Δt
```

- `fuel_price[t]`：边界曲线；缺边界时用标量 `fuel_price`
- 目标开关：`fuel_objective_on`（新增）
- 后验评价：`cost_type = "fuel_cost"`，口径与模型目标一致

GRID：

```text
purchase_cost = Σ buy[t] × buy_price[t] × Δt
sell_revenue  = -Σ sell[t] × sell_price[t] × Δt
```

### 8.3 与 `om_cost` 的关系

`om_cost` 仍为「运维成本」（元/kWh电）。接入燃料价后请将其视为**纯运维**，避免与 `fuel_cost` 重复计费。

### 8.4 相关代码

- 价格序列解析：`backend/utils/prediction_utils.jl`（`resolve_price_series` / `resolve_fuel_price_vector` / `resolve_grid_price_vectors`）
- 模型目标：`components/{coal,gas,combined_heat_power}/model-base.jl`、`model.jl`
- GRID 分时价：`components/power_grid/model-common.jl`
- 后验评价：`economy_evaluation_service.jl` + `economy_calculator.jl`
- 组件字段：`config/component-library.json`（`fuel_price`、`fuel_objective_on`、GRID `boundaryKey`）