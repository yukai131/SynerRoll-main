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
    evaluate_scenario_operating_cost(db_path, project_snapshot, layer_id) -> NamedTuple

从单个典型场景的 timeseries.db 后验计算运行成本（元），复用经济运行成本服务的组件成本、
松弛惩罚与参数解析口径，与 `evaluate_task_economy` 单层口径一致
（见 docs/capacity-planning-minimal-economy-design.md §6.1）。

返回 `(total_cost, cost_breakdown)`；成本为正、收益为负（CostItem 口径）。
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
    slack_penalty = Float64(get(algorithm_cfg, "slackPenalty", SLACK_PENALTY_DEFAULT))

    cost_items = CostItem[]
    for comp_dict in component_dicts
        comp_type = string(comp_dict["type"])
        # 负荷类型不产生经济性成本，与运行经济服务一致
        comp_type in ("ELOAD", "HLOAD", "QLOAD") && continue
        power_data = load_component_data(
            db_path, string(comp_dict["code"]), comp_type, layer_id, "0:00", scenario_end)
        has_data = false
        for series in values(power_data)
            if !isempty(series)
                has_data = true
                break
            end
        end
        !has_data && continue
        params = resolve_component_params_economy_with_step(comp_dict, layer_id, time_step_hours)
        # Match main's runtime economy policy: time-varying prices take precedence.
        boundary_ids = get(comp_dict, "boundaryIds", String[])
        if !haskey(power_data, "fuel") || isempty(power_data["fuel"])
            power = get(power_data, "power", Float64[])
            paras = get(comp_dict, "paras", Dict{String,Any}())
            efficiency = get(paras, "η", get(paras, "η_e", get(paras, "efficiency", nothing)))
            if efficiency isa Real && efficiency > 1.0e-9 && !isempty(power)
                power_data["fuel"] = power ./ efficiency
            end
        end
        if comp_type in ("CP", "GP", "CHP")
            price = load_boundary_price_series(db_path, boundary_ids, "0:00", scenario_end)
            if price !== nothing && !isempty(price)
                count = max(length(get(power_data, "power", Float64[])), length(price), 1)
                params = merge(params, (fuel_price=scale_price_series(price, time_step_hours, count),))
            end
        elseif comp_type == "GRID"
            prices = load_boundary_price_series_multi(db_path, boundary_ids, "0:00", scenario_end; n=2)
            count = max(length(get(power_data, "buy", Float64[])), length(get(power_data, "sell", Float64[])), 1)
            buy = prices[1] === nothing ? fill(params.buy_price, count) : scale_price_series(prices[1], time_step_hours, count)
            sell = prices[2] === nothing ? fill(params.sell_price, count) : scale_price_series(prices[2], time_step_hours, count)
            params = merge(params, (buy_price=buy, sell_price=sell))
        end
        append!(cost_items, calc_component_cost(
            comp_type,
            string(get(comp_dict, "nodeId", "")),
            string(get(comp_dict, "name", comp_type)),
            power_data, params, layer_id))
    end
    append!(cost_items, load_slack_data(db_path, layer_id, slack_penalty, "0:00", scenario_end))

    total_cost = sum(item.value for item in cost_items; init=0.0)
    cost_breakdown = Dict{String,Float64}()
    for item in cost_items
        cost_breakdown[item.cost_type] = get(cost_breakdown, item.cost_type, 0.0) + item.value
    end
    # 售电收益（负成本 → 正收益额，元）；生命周期经济价税分离需要
    revenue_yuan = -sum(item.value for item in cost_items
                        if item.cost_type == "sell_revenue" && item.value < 0; init=0.0)

    # 上网电量（kWh）：发电类组件正功率 × 时层步长，用于 LCOE 分母
    energy_kwh = 0.0
    for comp_dict in component_dicts
        comp_type = string(comp_dict["type"])
        comp_type in ("CP", "WT", "PV", "GP", "CHP", "ET", "HYDRO") || continue
        power_data = load_component_data(
            db_path, string(comp_dict["code"]), comp_type, layer_id, "0:00", scenario_end)
        # Only electrical output contributes; fuel, heat and curtailment are separate series.
        series = get(power_data, "power", Float64[])
        energy_kwh += sum(max.(series, 0.0)) * time_step_hours
    end
    return (total_cost=total_cost, cost_breakdown=cost_breakdown,
            revenue_yuan=revenue_yuan, energy_kwh=energy_kwh)
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

"""C-404：economicConstraints 启用的参数覆盖生命周期财务参数。"""
function _with_lifecycle_params(params::LifecycleFinancialParams; kwargs...)
    fields = Dict{Symbol,Any}(field => getfield(params, field) for field in fieldnames(LifecycleFinancialParams))
    merge!(fields, Dict{Symbol,Any}(kwargs))
    return LifecycleFinancialParams(; fields...)
end

function _apply_economic_constraints!(params::LifecycleFinancialParams, config::AbstractDict)
    constraints = get(config, "economicConstraints", Dict{String,Any}())
    constraints isa AbstractDict || return params
    rate = get(constraints, "interestRatePercent", nothing)
    if rate isa AbstractDict && get(rate, "enabled", false) == true
        threshold = Float64(get(rate, "threshold", params.discount_rate * 100))
        params = _with_lifecycle_params(params; discount_rate=max(threshold, 0.0) / 100)
    end
    tax = get(constraints, "taxRatePercent", nothing)
    if tax isa AbstractDict && get(tax, "enabled", false) == true
        threshold = Float64(get(tax, "threshold", params.income_tax_rate * 100))
        params = _with_lifecycle_params(params; income_tax_rate=max(threshold, 0.0) / 100)
    end
    years = get(constraints, "lifecycleYears", nothing)
    if years isa AbstractDict && get(years, "enabled", false) == true
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
        # Release cached SQLite handles before candidate cleanup (Windows file locks).
    end
    total_weight_days > 0 || throw(CapacityPlanningError(
        "SCENARIOS_MISSING", "没有可用的典型场景评价结果"))
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
    if lifecycle !== nothing
        objective_fitness, objective_reason = _objective_fitness(objective, lifecycle, total_cost)
        # targetIrrPercent 约束：IRR 低于阈值按差额 × CAPEX 比例惩罚（K-306 NumericPolicy 前的近似）
        constraints = get(input.config, "economicConstraints", Dict{String,Any}())
        target = get(constraints, "targetIrrPercent", nothing)
        if target isa AbstractDict && get(target, "enabled", false) == true &&
                lifecycle.irr_after_tax !== nothing
            threshold_rate = Float64(get(target, "threshold", 0.0)) / 100
            shortfall = max(0.0, threshold_rate - lifecycle.irr_after_tax)
            constraint_penalty = shortfall * lifecycle.total_capex_wan * 1.0e4
        end
    elseif objective != "operating-cost-min"
        throw(CapacityPlanningError("LIFECYCLE_MISSING", "生命周期指标缺失，无法评价目标 $(objective)"))
    end
    evaluation_fitness = objective_fitness + constraint_penalty
    objective_reason != "ok" && push!(lifecycle_warnings, "目标 $(objective): $(objective_reason)")

    breakdown = merge(Dict{String,Any}(
        "weightedOperatingCost" => total_cost,
        "weightedOperatingObjective" => input.simulation.operating_objective,
        "objectiveFitness" => objective_fitness,
        "constraintPenalty" => constraint_penalty,
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
    end

    warnings = [
        "当前使用 $(TIMESERIES_OPERATING_COST_EVALUATOR_VERSION)，fitness = 目标[$(objective)] + 约束惩罚；breakdown.objectiveFitness/constraintPenalty 可拆解。",
        "breakdown.weightedOperatingObjective 为 JuMP 目标函数参照值，仅供与运行成本口径对比。",
        "NPV/IRR/LCOE 为 C-403 全投资口径生命周期指标（公式见 lifecycle_economics.jl 头注释），随所选目标参与 fitness。",
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
