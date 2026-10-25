struct OperatingObjectiveEvaluator <: AbstractEconomicEvaluator end

const OPERATING_OBJECTIVE_EVALUATOR_VERSION = "operating-objective-v1"

"""后验运行成本评价器版本：fitness 来自场景 timeseries.db 的运行成本加权（最小经济约定 §6）。"""
const TIMESERIES_OPERATING_COST_EVALUATOR_VERSION = "timeseries-operating-cost-v1"

"""新建任务未显式指定评价器时的默认版本（后验运行成本口径）。"""
const DEFAULT_CAPACITY_EVALUATOR_VERSION = TIMESERIES_OPERATING_COST_EVALUATOR_VERSION

"""
    evaluate_economics(::OperatingObjectiveEvaluator, input)

在财务参数口径尚未确认前，只使用模型真实返回的年度加权运行目标参与优化。
CAPEX、NPV、IRR、LCOE 不填占位数字，结果中明确返回 `nothing` 和 warning。
"""
function evaluate_economics(
    ::OperatingObjectiveEvaluator,
    input::EconomicEvaluationInput,
)::EconomicEvaluationResult
    input.simulation.feasible || throw(CapacityPlanningError("INFEASIBLE", "不可行仿真不能进入经济评价"))
    operating = input.simulation.operating_objective
    isfinite(operating) || throw(CapacityPlanningError("NON_FINITE_FITNESS", "运行目标不是有限数值"))

    return EconomicEvaluationResult(
        fitness=operating,
        breakdown=Dict(
            "weightedOperatingObjective" => operating,
            "annualizedCapex" => 0.0,
            "penalty" => 0.0,
        ),
        indicators=Dict{String,Union{Float64,Nothing}}(
            "npv" => nothing,
            "irr" => nothing,
            "lcoe" => nothing,
        ),
        warnings=[
            "当前使用 operating-objective-v1，仅优化模型运行目标；CAPEX 及 NPV/IRR/LCOE 未参与计算。",
            "确认 initial_cost、replace_cost、life_year 等字段口径后可替换经济评价器，无需修改优化任务和场景数据结构。",
        ],
        evaluator_version=OPERATING_OBJECTIVE_EVALUATOR_VERSION,
    )
end

function economic_evaluator_from_config(config::AbstractDict)
    evaluator = string(get(config, "evaluator", DEFAULT_CAPACITY_EVALUATOR_VERSION))
    evaluator == OPERATING_OBJECTIVE_EVALUATOR_VERSION && return OperatingObjectiveEvaluator()
    evaluator == TIMESERIES_OPERATING_COST_EVALUATOR_VERSION && return TimeseriesOperatingCostEvaluator()
    throw(CapacityPlanningError(
        "ECONOMIC_EVALUATOR_UNSUPPORTED",
        "当前仅支持 $(OPERATING_OBJECTIVE_EVALUATOR_VERSION) 与 $(TIMESERIES_OPERATING_COST_EVALUATOR_VERSION)",
    ))
end

"""
    TimeseriesOperatingCostEvaluator

后验运行成本评价器：fitness = Σᵢ(场景 timeseries.db 运行成本ᵢ × weightDaysᵢ)，
单位为元。JuMP `operating_objective` 仅作为 breakdown 中的参照值保留，
用于两套口径的基线对比（C-001 待确认事项 4）。

C-404：fitness 按 economics.objective 七类正式目标切换（独立入口见
`_objective_fitness`）；economicConstraints 中启用的利率/税率/生命周期作为
财务参数覆盖，targetIrrPercent 作为约束惩罚（K-306 NumericPolicy 接入前的
比例惩罚近似，见 docs/c404-目标与约束实现记录.md）。
"""
struct TimeseriesOperatingCostEvaluator <: AbstractEconomicEvaluator end

"""各评价器版本号，用于候选 hash 与经济结果留痕。"""
economic_evaluator_version(::OperatingObjectiveEvaluator) = OPERATING_OBJECTIVE_EVALUATOR_VERSION
economic_evaluator_version(::TimeseriesOperatingCostEvaluator) = TIMESERIES_OPERATING_COST_EVALUATOR_VERSION

"""
    _slack_unstable_slots(db_path, layer_id, sim_start, sim_end) -> Int

统计窗口内出现缺额/过剩松弛的时段数（任一载能 slack > 0 即计为不稳定），
对应 c001 §6「供需达标率」的分子时段数。
"""
function _slack_unstable_slots(
    db_path::String,
    layer_id::String,
    sim_start::String,
    sim_end::Union{String,Nothing},
)
    counts = _slack_slot_counts(db_path, layer_id, sim_start, sim_end)
    return counts.unstable
end

"""按过剩/缺额拆分松弛时段，供前端双轴图展示稳定性构成。"""
function _slack_slot_counts(
    db_path::String,
    layer_id::String,
    sim_start::String,
    sim_end::Union{String,Nothing},
)
    start_min = time_label_to_minutes(sim_start)
    end_min = sim_end !== nothing ? time_label_to_minutes(sim_end) : nothing
    excess = Set{Int}()
    shortage = Set{Int}()
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT id, layer_id, var_name FROM time_series_meta WHERE var_name LIKE '%SHORTAGE%' OR var_name LIKE '%EXCESS%'")
        isempty(rows[1]) && return
        for i in 1:length(rows[1])
            String(rows[2][i]) != layer_id && continue
            series_id = rows[1][i]
            var_name = String(rows[3][i])
            is_shortage = occursin("SHORTAGE", uppercase(var_name))
            sql = "SELECT ts_min, value FROM time_series_data WHERE series_id=? AND ts_min>=?"
            params = Any[series_id, start_min]
            if end_min !== nothing
                sql *= " AND ts_min<?"
                push!(params, end_min)
            end
            data_rows = _query(store.db, sql, params)
            isempty(data_rows[1]) && continue
            for (slot_min, val) in zip(data_rows[1], data_rows[2])
                is_meaningful_slack(val) || continue
                if is_shortage
                    push!(shortage, Int(slot_min))
                else
                    push!(excess, Int(slot_min))
                end
            end
        end
    end
    union_slots = union(excess, shortage)
    return (
        excess = length(excess),
        shortage = length(shortage),
        unstable = length(union_slots),
    )
end

"""
    evaluate_scenario_operating_cost(db_path, project_snapshot, layer_id) -> NamedTuple

从单个典型场景的 timeseries.db 后验计算运行成本（元），复用经济运行成本服务的组件成本、
松弛惩罚与参数解析口径，与 `evaluate_task_economy` 单层口径一致
（见 docs/capacity-planning-minimal-economy-design.md §6.1）。

同时后验汇总技术指标（消纳率/绿电占比/购电占比/稳定性），供技术约束软惩罚使用。

返回 `(total_cost, cost_breakdown, revenue_yuan, energy_kwh, technical_metrics)`；
成本为正、收益为负（CostItem 口径）。
"""
function evaluate_scenario_operating_cost(
    db_path::String,
    project_snapshot::AbstractDict,
    layer_id::String,
)
    isfile(db_path) || throw(CapacityPlanningError(
        "SCENARIO_DB_MISSING", "典型场景数据库不存在: $(db_path)"))

    # ── 规划时层与步长（快照内提取，AbstractDict 安全）──
    layer_config = get(project_snapshot, "layerConfig", Dict{String,Any}())
    layer = nothing
    for item in get(layer_config, "layers", [])
        if string(get(item, "id", "")) == layer_id
            layer = item
            break
        end
    end
    layer === nothing && throw(CapacityPlanningError(
        "PLANNING_LAYER_MISSING", "规划时层 $(layer_id) 不在快照的时层配置中"))
    time_step_hours = _parse_duration_hours(string(get(layer, "step", "1h")))
    # Layer 1 stores a second day for rolling look-ahead. Only the representative
    # day's half-open [0:00, 24:00) window belongs in its daily economic cost.
    scenario_end = "24:00"

    # ── 组件清单与松弛惩罚（与 evaluate_task_economy 同口径）──
    workspace = get(project_snapshot, "workspace", Dict{String,Any}())
    nodes = Any[]
    for canvas in get(workspace, "canvases", [])
        string(get(canvas, "id", "")) == string(get(workspace, "activeCanvasId", "")) || continue
        append!(nodes, get(canvas, "nodes", []))
    end
    component_dicts, _, _ = _parse_component_nodes(nodes)
    algorithm_cfg = get(project_snapshot, "algorithm", Dict{String,Any}())
    _, shortage_penalty, excess_penalty = get_slack_config(algorithm_cfg)

    collected = collect_layer_cost_items(
        db_path, component_dicts, layer_id, time_step_hours,
        "0:00", scenario_end, shortage_penalty, excess_penalty,
    )
    cost_items = collected.cost_items
    energy_kwh = collected.energy_kwh
    tech = collected.tech

    total_cost = sum(item.value for item in cost_items if item.in_objective || item.is_slack; init=0.0)
    # 全量会计口径（含未勾选进目标的成本项），便于对照，不进 fitness
    cost_breakdown = Dict{String,Float64}()
    for item in cost_items
        cost_breakdown[item.cost_type] = get(cost_breakdown, item.cost_type, 0.0) + item.value
    end
    # 售电收益（负成本 → 正收益额，元）；生命周期经济价税分离需要
    revenue_yuan = -sum(item.value for item in cost_items
                        if item.cost_type == "sell_revenue" && item.value < 0; init=0.0)

    # ── 技术指标（c001 §6 + 消纳/绿电/购电占比）──
    re_used, re_avail = tech.re_used, tech.re_avail
    hydro_gen, thermal_gen, buy_e = tech.hydro_gen, tech.thermal_gen, tech.buy_e
    tech_slots = tech.tech_slots
    slack_counts = _slack_slot_counts(db_path, layer_id, "0:00", scenario_end)
    unstable_slots = slack_counts.unstable
    if tech_slots <= 0
        tech_slots = max(1, round(Int, 24.0 / max(time_step_hours, 1.0e-9)))
    end
    green_gen = re_used + hydro_gen
    total_supply = green_gen + thermal_gen + buy_e
    technical_metrics = Dict{String,Float64}(
        # 新能源消纳率 = 已调度风光 / (已调度 + 弃电)；无风光时记 100
        "renewableConsumptionRate" => re_avail > 0 ? 100.0 * re_used / re_avail : 100.0,
        # 绿电占比 = (风光+水电) / 总供电量；总供电 = 绿电 + 常规 + 购电
        "greenPowerShare" => total_supply > 0 ? 100.0 * green_gen / total_supply : 100.0,
        # 购电占比 = 购电 / 总供电量（与绿电同分母，便于对照）
        "purchasedPowerShare" => total_supply > 0 ? 100.0 * buy_e / total_supply : 0.0,
        # 稳定性 = 供需达标率 = 1 − 不稳定时段 / 总时段（c001 §6）
        "stability" => tech_slots > 0 ? 100.0 * (1.0 - unstable_slots / tech_slots) : 100.0,
        # 稳定性拆分：过剩/缺额时段占比（%），供双轴图展示
        "stabilityExcessShare" => tech_slots > 0 ? 100.0 * slack_counts.excess / tech_slots : 0.0,
        "stabilityShortageShare" => tech_slots > 0 ? 100.0 * slack_counts.shortage / tech_slots : 0.0,
    )
    return (total_cost=total_cost, cost_breakdown=cost_breakdown,
            revenue_yuan=revenue_yuan, energy_kwh=energy_kwh,
            technical_metrics=technical_metrics)
end

"""C-404 七类正式目标（与 types/capacity-planning.ts CapacityPlanObjective 对齐）。"""
const CAPACITY_OBJECTIVES = (
    "total-cost-min", "operating-cost-min", "initial-investment-min",
    "npv-max", "lcoe-min", "payback-period-min", "irr-max",
)

"""
    _objective_fitness(objective, lifecycle, total_cost_yuan) -> (fitness, reason)

七类正式目标的独立计算入口（C-404）。返回 (fitness, reason)；
目标不可计算时 fitness = 1.0e18 并给出 reason（优化器哨兵惩罚口径，
见 c001 第 5 节：不可计算原因必须可解释）。金额类目标单位统一为元。
"""
function _objective_fitness(objective::String, lifecycle, total_cost_yuan::Float64)
    penalty = 1.0e18
    if objective == "operating-cost-min"
        return (total_cost_yuan, "ok")
    elseif objective == "total-cost-min"
        # 生命周期总成本现值（CAPEX+增值税+流动资金−处置回收+运营期折现流出与税）
        return (lifecycle.discounted_cost_wan * 1.0e4, "ok")
    elseif objective == "initial-investment-min"
        return ((lifecycle.total_capex_wan + lifecycle.construction_vat_wan) * 1.0e4, "ok")
    elseif objective == "npv-max"
        return (-lifecycle.npv_after_tax_wan * 1.0e4, "ok")
    elseif objective == "lcoe-min"
        value = lifecycle.lcoe_yuan_per_kwh
        value === nothing && return (penalty, "LCOE 不可计算（缺少年度上网电量）")
        return (value, "ok")
    elseif objective == "payback-period-min"
        value = lifecycle.discounted_payback_years
        value === nothing && return (penalty, "回收期不可计算（现金流恒负，项目不可回收）")
        return (value, "ok")
    elseif objective == "irr-max"
        value = lifecycle.irr_after_tax
        value === nothing && return (penalty, "IRR 不可计算（$(lifecycle.irr_after_tax_reason)）")
        return (-value, "ok")
    end
    return (penalty, "未知目标 $(objective)")
end

const TECHNICAL_CONSTRAINT_KEYS = (
    "renewableConsumptionRate", "greenPowerShare", "purchasedPowerShare", "stability",
)

"""目标量纲类别：money（元）/ intensity（元/kWh）/ time（年）/ rate（无量纲）"""
function _objective_unit(objective::String)::String
    objective == "lcoe-min" && return "intensity"
    objective == "payback-period-min" && return "time"
    objective == "irr-max" && return "rate"
    return "money"
end

"""
    _penalty_in_objective_unit(objective, penalty_yuan, lifecycle, annual_energy_kwh, annual_opex_yuan)

方案 B：把「元」惩罚换算到与目标相同量纲。
- money：原样返回
- lcoe：penalty / 年上网电量
- payback：penalty / 年现金流尺度（CAPEX/n 与 |年运行成本| 的较大者）
- irr：penalty / CAPEX

分母无效时返回 `nothing`，调用方走方案 C 归一化兜底。
"""
function _penalty_in_objective_unit(
    objective::String,
    penalty_yuan::Float64,
    lifecycle,
    annual_energy_kwh::Float64,
    annual_opex_yuan::Float64,
)::Union{Float64,Nothing}
    unit = _objective_unit(objective)
    unit == "money" && return penalty_yuan
    if unit == "intensity"
        (isfinite(annual_energy_kwh) && annual_energy_kwh > 0) || return nothing
        return penalty_yuan / annual_energy_kwh
    end
    lifecycle === nothing && return nothing
    capex_yuan = lifecycle.total_capex_wan * 1.0e4
    if unit == "rate"
        (isfinite(capex_yuan) && capex_yuan > 0) || return nothing
        return penalty_yuan / capex_yuan
    end
    # unit == "time"
    n = max(1.0, Float64(length(lifecycle.after_tax_cashflow) - 1))
    cf_ref = max(capex_yuan / n, abs(annual_opex_yuan), 1.0)
    isfinite(cf_ref) && cf_ref > 0 || return nothing
    return penalty_yuan / cf_ref
end

"""
    _objective_scale_for_normalize(objective, lifecycle, total_cost_yuan, annual_energy_kwh)

方案 C 兜底：估计目标上界尺度，用于把目标与惩罚压到同阶无量纲再相加。
"""
function _objective_scale_for_normalize(
    objective::String,
    lifecycle,
    total_cost_yuan::Float64,
    annual_energy_kwh::Float64,
)::Float64
    unit = _objective_unit(objective)
    if unit == "money"
        scale = abs(total_cost_yuan)
        lifecycle !== nothing && (scale = max(scale, abs(lifecycle.discounted_cost_wan) * 1.0e4))
        return max(scale, 1.0)
    elseif unit == "intensity"
        if lifecycle !== nothing && lifecycle.lcoe_yuan_per_kwh !== nothing
            return max(abs(lifecycle.lcoe_yuan_per_kwh), 1.0e-6)
        end
        return max(abs(total_cost_yuan) / max(annual_energy_kwh, 1.0), 1.0e-6)
    elseif unit == "time"
        if lifecycle !== nothing && lifecycle.discounted_payback_years !== nothing
            return max(abs(lifecycle.discounted_payback_years), 1.0)
        end
        return max(Float64(lifecycle === nothing ? 20 : length(lifecycle.after_tax_cashflow) - 1), 1.0)
    end
    # rate：IRR 已是 0~1 量级
    return 1.0
end

"""
    _penalty_yuan_scale(penalty_yuan, objective, lifecycle, annual_opex_yuan)

方案 C 兜底：惩罚（元）的尺度，用于与目标同阶归一化。
"""
function _penalty_yuan_scale(
    penalty_yuan::Float64,
    objective::String,
    lifecycle,
    annual_opex_yuan::Float64,
)::Float64
    base = abs(penalty_yuan)
    lifecycle !== nothing && (base = max(base, abs(lifecycle.total_capex_wan) * 1.0e4))
    base = max(base, abs(annual_opex_yuan), 1.0)
    # 保证即使当前惩罚为 0，尺度也覆盖满惩罚量级
    return max(base, 1.0)
end

"""
    _technical_constraint_penalty(constraints, metrics, penalty_per_point) -> (penalty, details)

技术约束软惩罚（消纳率/绿电占比/购电占比/稳定性）：
对启用项按阈值偏差（百分点）× `penalty_per_point`（元/百分点）加性计入 fitness。
`gte` 取 max(0, threshold − value)，`lte` 取 max(0, value − threshold)。
"""
function _technical_constraint_penalty(
    constraints::AbstractDict,
    metrics::AbstractDict,
    penalty_per_point::Float64,
)
    penalty = 0.0
    details = Dict{String,Any}[]
    for key in TECHNICAL_CONSTRAINT_KEYS
        raw = get(constraints, key, nothing)
        raw isa AbstractDict || continue
        get(raw, "enabled", false) == true || continue
        haskey(metrics, key) || continue
        value = Float64(metrics[key])
        operator = string(get(raw, "operator", "gte"))
        threshold = Float64(get(raw, "threshold", 0.0))
        shortfall = operator == "lte" ? max(0.0, value - threshold) : max(0.0, threshold - value)
        item_penalty = penalty_per_point * shortfall
        penalty += item_penalty
        push!(details, Dict{String,Any}(
            "key" => key,
            "value" => round(value; digits=4),
            "operator" => operator,
            "threshold" => threshold,
            "shortfall" => round(shortfall; digits=4),
            "penalty" => item_penalty,
        ))
    end
    return penalty, details
end

"""C-404：economicConstraints 启用的参数覆盖生命周期财务参数。"""
function _with_lifecycle_params(params::LifecycleFinancialParams; kwargs...)
    fields = Dict{Symbol,Any}(field => getfield(params, field) for field in fieldnames(LifecycleFinancialParams))
    merge!(fields, Dict{Symbol,Any}(kwargs))
    return LifecycleFinancialParams(; fields...)
end

function _apply_economic_constraints!(params::LifecycleFinancialParams, config::AbstractDict)
    constraints = get(config, "economicConstraints", Dict{String,Any}())
    constraints isa AbstractDict || return params
    # 经济性参数始终生效（前端无勾选）；enabled 仅作兼容字段
    rate = get(constraints, "interestRatePercent", nothing)
    if rate isa AbstractDict
        threshold = Float64(get(rate, "threshold", params.discount_rate * 100))
        params = _with_lifecycle_params(params; discount_rate=max(threshold, 0.0) / 100)
    end
    tax = get(constraints, "taxRatePercent", nothing)
    if tax isa AbstractDict
        threshold = Float64(get(tax, "threshold", params.income_tax_rate * 100))
        params = _with_lifecycle_params(params; income_tax_rate=max(threshold, 0.0) / 100)
    end
    years = get(constraints, "lifecycleYears", nothing)
    if years isa AbstractDict
        params = _with_lifecycle_params(params;
            operation_years=max(1, round(Int, Float64(get(years, "threshold", params.operation_years)))))
    end
    return params
end

function evaluate_economics(
    ::TimeseriesOperatingCostEvaluator,
    input::EconomicEvaluationInput,
)::EconomicEvaluationResult
    input.simulation.feasible || throw(CapacityPlanningError("INFEASIBLE", "不可行仿真不能进入经济评价"))
    work_dir = input.work_dir
    work_dir === nothing && throw(CapacityPlanningError(
        "WORK_DIR_MISSING", "后验运行成本评价缺少候选工作目录"))
    snapshot = input.project_snapshot
    snapshot === nothing && throw(CapacityPlanningError(
        "SNAPSHOT_MISSING", "后验运行成本评价缺少候选快照"))

    total_cost = 0.0
    total_weight_days = 0
    scenario_costs = Dict{String,Float64}()
    # 先按代表天数加权，再按 365/总代表天数折算生命周期年度输入。
    annual_revenue_yuan = 0.0
    annual_opex_yuan = 0.0
    annual_energy_kwh = 0.0
    tech_weighted = Dict{String,Float64}()
    for metric in input.simulation.scenario_metrics
        get(metric, "feasible", false) == true || throw(CapacityPlanningError(
            "SCENARIO_INFEASIBLE",
            "典型场景 $(get(metric, "scenarioId", "?")) 不可行，不能进入后验经济评价"))
        scenario_id = string(metric["scenarioId"])
        weight_days = Int(metric["weightDays"])
        db_path = joinpath(work_dir, "scenarios", scenario_id, "timeseries.db")
        scenario = try
            evaluate_scenario_operating_cost(db_path, snapshot, input.layer_id)
        finally
            close_store(db_path)
        end
        total_cost += scenario.total_cost * weight_days
        total_weight_days += weight_days
        scenario_costs["scenarioCost:$(scenario_id)"] = scenario.total_cost * weight_days
        annual_revenue_yuan += scenario.revenue_yuan * weight_days
        # 经营成本 = 总成本 + 售电收益（收益项为负值），含松弛惩罚
        annual_opex_yuan += (scenario.total_cost + scenario.revenue_yuan) * weight_days
        annual_energy_kwh += scenario.energy_kwh * weight_days
        for (key, value) in scenario.technical_metrics
            tech_weighted[key] = get(tech_weighted, key, 0.0) + value * weight_days
        end
        # Release cached SQLite handles before candidate cleanup (Windows file locks).
    end
    total_weight_days > 0 || throw(CapacityPlanningError(
        "SCENARIOS_MISSING", "没有可用的典型场景评价结果"))
    for key in keys(tech_weighted)
        tech_weighted[key] /= total_weight_days
    end
    annual_factor = 365.0 / total_weight_days
    annual_revenue_yuan *= annual_factor
    annual_opex_yuan *= annual_factor
    annual_energy_kwh *= annual_factor
    isfinite(total_cost) || throw(CapacityPlanningError(
        "NON_FINITE_FITNESS", "加权运行成本不是有限数值"))

    # ── 生命周期经济（C-403，全投资口径，公式见 lifecycle_economics.jl）──
    lifecycle_warnings = String[]
    lifecycle = nothing
    indicators = Dict{String,Union{Float64,Nothing}}(
        "npv" => nothing, "irr" => nothing, "lcoe" => nothing,
    )
    if snapshot !== nothing && !isempty(input.capacities)
        params = lifecycle_params_from_config(input.config)
        # C-404：启用的经济约束覆盖财务参数（利率→折现率、税率→所得税率、生命周期→评价年限）
        params = _apply_economic_constraints!(params, input.config)
        capex_items, capex_warnings = extract_lifecycle_capex(
            snapshot, input.capacities, input.original_capacities,
            input.change_kinds, input.units, params)
        append!(lifecycle_warnings, capex_warnings)
        lifecycle = evaluate_lifecycle(;
            capex_items=capex_items,
            annual_revenue_yuan=annual_revenue_yuan,
            annual_opex_yuan=annual_opex_yuan,
            annual_energy_kwh=annual_energy_kwh > 0 ? annual_energy_kwh : nothing,
            params=params,
        )
        append!(lifecycle_warnings, lifecycle.warnings)
        # 指标单位统一为元（NPV）与小数（IRR、LCOE 元/kWh）
        indicators["npv"] = lifecycle.npv_after_tax_wan * 1.0e4
        indicators["irr"] = lifecycle.irr_after_tax
        indicators["lcoe"] = lifecycle.lcoe_yuan_per_kwh
        if lifecycle.irr_after_tax === nothing
            push!(lifecycle_warnings, "税后 IRR 未求解（$(lifecycle.irr_after_tax_reason)）")
        end
    else
        push!(lifecycle_warnings, "候选快照或容量缺失，生命周期指标未计算")
    end

    # ── C-404：目标 fitness 与约束惩罚 ──
    objective = string(get(input.config, "objective", "operating-cost-min"))
    objective in CAPACITY_OBJECTIVES ||
        throw(CapacityPlanningError("OBJECTIVE_UNSUPPORTED", "不支持的目标 $(objective)"))
    objective_fitness = total_cost
    objective_reason = "ok"
    constraint_penalty = 0.0
    technical_penalty = 0.0
    technical_details = Dict{String,Any}[]
    if lifecycle !== nothing
        objective_fitness, objective_reason = _objective_fitness(objective, lifecycle, total_cost)
        # targetIrrPercent：默认最低内部收益率约束（始终生效），IRR 低于阈值按差额 × CAPEX 惩罚
        constraints = get(input.config, "economicConstraints", Dict{String,Any}())
        target = get(constraints, "targetIrrPercent", nothing)
        if target isa AbstractDict && lifecycle.irr_after_tax !== nothing
            threshold_rate = Float64(get(target, "threshold", 0.0)) / 100
            shortfall = max(0.0, threshold_rate - lifecycle.irr_after_tax)
            # B12：可配置权重，默认 1.0（= 短差 × CAPEX）
            irr_weight = Float64(get(get(input.config, "lifecycle", Dict{String,Any}()), "irr_penalty_weight", 1.0))
            constraint_penalty = shortfall * lifecycle.total_capex_wan * 1.0e4 * max(irr_weight, 0.0)
        end
    elseif objective != "operating-cost-min"
        throw(CapacityPlanningError("LIFECYCLE_MISSING", "生命周期指标缺失，无法评价目标 $(objective)"))
    end
    # 技术约束软惩罚：消纳率/绿电占比/购电占比/稳定性
    # 惩罚系数优先取任务配置，否则取项目算法配置（建模页「算法配置」弹窗），默认 1e5 元/百分点
    tech_constraints = get(input.config, "technicalConstraints", Dict{String,Any}())
    algo_cfg = snapshot isa AbstractDict ? get(snapshot, "algorithm", Dict{String,Any}()) : Dict{String,Any}()
    tech_penalty_per_point = if haskey(input.config, "technicalPenalty")
        Float64(input.config["technicalPenalty"])
    else
        Float64(get(algo_cfg, "technicalPenalty", 1.0e7))
    end
    technical_penalty, technical_details = _technical_constraint_penalty(
        tech_constraints, tech_weighted, tech_penalty_per_point)
    constraint_penalty += technical_penalty

    # ── 量纲统一：方案 B 为主（惩罚换算到目标单位），方案 C 兜底（尺度归一化）──
    penalty_mode = "same-unit"
    penalty_in_obj_unit = _penalty_in_objective_unit(
        objective, constraint_penalty, lifecycle, annual_energy_kwh, annual_opex_yuan)
    if penalty_in_obj_unit !== nothing && isfinite(penalty_in_obj_unit)
        evaluation_fitness = objective_fitness + penalty_in_obj_unit
    else
        penalty_mode = "normalized"
        obj_scale = _objective_scale_for_normalize(objective, lifecycle, total_cost, annual_energy_kwh)
        pen_scale = _penalty_yuan_scale(constraint_penalty, objective, lifecycle, annual_opex_yuan)
        penalty_in_obj_unit = constraint_penalty / pen_scale
        evaluation_fitness = objective_fitness / obj_scale + penalty_in_obj_unit
    end
    isfinite(evaluation_fitness) || (evaluation_fitness = 1.0e18)
    objective_reason != "ok" && push!(lifecycle_warnings, "目标 $(objective): $(objective_reason)")

    breakdown = merge(Dict{String,Any}(
        "weightedOperatingCost" => total_cost,
        "weightedOperatingObjective" => input.simulation.operating_objective,
        "objectiveFitness" => objective_fitness,
        "constraintPenalty" => constraint_penalty,
        "constraintPenaltyInObjectiveUnit" => penalty_in_obj_unit,
        "fitnessPenaltyMode" => penalty_mode,
        "technicalConstraintPenalty" => technical_penalty,
        "technicalMetrics" => Dict{String,Any}(tech_weighted),
        "technicalConstraintDetails" => technical_details,
    ), scenario_costs)
    if lifecycle !== nothing
        breakdown["lifecycleCapexWan"] = lifecycle.total_capex_wan
        breakdown["lifecycleConstructionVatWan"] = lifecycle.construction_vat_wan
        breakdown["lifecycleWorkingCapitalWan"] = lifecycle.working_capital_wan
        breakdown["lifecycleDisposalRecoveryWan"] = lifecycle.disposal_recovery_wan
        breakdown["lifecycleAnnualDepreciationWan"] = lifecycle.annual_depreciation_wan
        breakdown["lifecycleAnnualAdjustedTaxWan"] = lifecycle.annual_adjusted_tax_wan
        breakdown["lifecycleNpvAfterTaxWan"] = lifecycle.npv_after_tax_wan
        breakdown["lifecycleDiscountedCostWan"] = lifecycle.discounted_cost_wan
        breakdown["lifecyclePaybackYears"] = lifecycle.payback_years
        breakdown["lifecycleDiscountedPaybackYears"] =
            lifecycle.discounted_payback_years
        # C-405 方案比较：逐年税后净现金流（万元，下标 0=建设年），供候选级现金流查看
        breakdown["lifecycleAfterTaxCashflowWan"] = round.(lifecycle.after_tax_cashflow; digits=4)
        breakdown["lifecycleAnnualFixedOmWan"] = lifecycle.annual_fixed_om_wan
        breakdown["lifecycleAnnualSubsidyWan"] = lifecycle.annual_subsidy_wan
        breakdown["lifecycleAnnualCapacityCompensationWan"] = lifecycle.annual_capacity_compensation_wan
        breakdown["lifecycleReplaceCapexTotalWan"] = lifecycle.replace_capex_total_wan
    end

    warnings = [
        "当前使用 $(TIMESERIES_OPERATING_COST_EVALUATOR_VERSION)，fitness = 目标[$(objective)] + 约束惩罚；breakdown.objectiveFitness/constraintPenalty 可拆解。",
        "breakdown.weightedOperatingObjective 为 JuMP 目标函数参照值，仅供与运行成本口径对比。",
        "NPV/IRR/LCOE 为 C-403 全投资口径生命周期指标（公式见 lifecycle_economics.jl 头注释），随所选目标参与 fitness。",
        "技术约束（消纳率/绿电占比/购电占比/稳定性）为软惩罚，见 breakdown.technicalMetrics / technicalConstraintDetails。",
    ]
    append!(warnings, lifecycle_warnings)

    return EconomicEvaluationResult(
        fitness=evaluation_fitness,
        breakdown=breakdown,
        indicators=indicators,
        warnings=warnings,
        evaluator_version=TIMESERIES_OPERATING_COST_EVALUATOR_VERSION,
    )
end
