# C-405 方案比较汇总：从 planning_evaluations 统一组装候选指标、基准差异、
# 输入版本与可解释排名，供 GET /api/capacity-planning/{id}/comparison 使用。
# 数字口径全部来自各候选 breakdown（economic_evaluator.jl 落库），不重新计算。

"""方案比较统一指标清单（metric key 与前端展示列一一对应）。"""
const COMPARISON_METRICS = (
    ("fitness",                "适应度",          "asc",  "fitness = objectiveFitness + constraintPenalty（C-404）"),
    ("objectiveFitness",       "目标项",          "asc",  "breakdown.objectiveFitness（七类目标独立入口 _objective_fitness）"),
    ("constraintPenalty",      "约束惩罚",        "asc",  "breakdown.constraintPenalty（targetIrr 差额×CAPEX + 技术约束软惩罚 technicalPenalty×偏差百分点）"),
    ("operatingCostYuan",      "年运行成本(万元)", "asc",  "breakdown.weightedOperatingCost ÷ 1e4（Σ 场景运行成本 × weightDays 的年加权值）"),
    ("investmentYuan",         "初始投资(万元)",  "asc",  "(lifecycleCapexWan + lifecycleConstructionVatWan)（万元），口径同 initial-investment-min"),
    ("npvYuan",                "NPV(万元)",       "desc", "breakdown.indicators.npv ÷ 1e4（C-403 全投资税后口径）"),
    ("irr",                    "IRR(%)",          "desc", "breakdown.indicators.irr（C-403 全投资税后口径）"),
    ("lcoe",                   "LCOE(元/kWh)",    "asc",  "breakdown.indicators.lcoe（C-403 全投资折现口径，分母=上网电量）"),
    ("paybackYears",           "回收期(年)",      "asc",  "breakdown.lifecyclePaybackYears（税后简单回收期）"),
    ("discountedPaybackYears", "折现回收期(年)",  "asc",  "breakdown.lifecycleDiscountedPaybackYears"),
    # C-404 技术约束软惩罚四项：便于迭代过程回溯对比（越高越好 / 购电越低越好）
    ("renewableConsumptionRate", "新能源消纳率(%)", "desc", "breakdown.technicalMetrics.renewableConsumptionRate"),
    ("greenPowerShare",          "绿电占比(%)",     "desc", "breakdown.technicalMetrics.greenPowerShare"),
    ("purchasedPowerShare",      "购电占比(%)",     "asc",  "breakdown.technicalMetrics.purchasedPowerShare"),
    ("stability",                "稳定性(%)",       "desc", "breakdown.technicalMetrics.stability"),
)

function _comparison_number(value)
    value isa Real || return nothing
    number = Float64(value)
    return isfinite(number) ? number : nothing
end

function _comparison_metric_value(breakdown::AbstractDict, key::String)
    indicators = get(breakdown, "indicators", nothing)
    if key == "operatingCostYuan"
        total = _comparison_number(get(breakdown, "weightedOperatingCost", nothing))
        return total === nothing ? nothing : total / 1.0e4
    elseif key == "investmentYuan"
        capex = _comparison_number(get(breakdown, "lifecycleCapexWan", nothing))
        vat = _comparison_number(get(breakdown, "lifecycleConstructionVatWan", nothing))
        (capex === nothing || vat === nothing) && return nothing
        return capex + vat
    elseif key == "npvYuan"
        if indicators isa AbstractDict
            npv = _comparison_number(get(indicators, "npv", nothing))
            return npv === nothing ? nothing : npv / 1.0e4
        end
        return nothing
    elseif key == "irr"
        value = indicators isa AbstractDict ? _comparison_number(get(indicators, "irr", nothing)) : nothing
        return value === nothing ? nothing : value * 100
    elseif key == "lcoe"
        return indicators isa AbstractDict ? _comparison_number(get(indicators, "lcoe", nothing)) : nothing
    elseif key == "paybackYears"
        return _comparison_number(get(breakdown, "lifecyclePaybackYears", nothing))
    elseif key == "discountedPaybackYears"
        return _comparison_number(get(breakdown, "lifecycleDiscountedPaybackYears", nothing))
    elseif key in ("renewableConsumptionRate", "greenPowerShare", "purchasedPowerShare", "stability")
        tech = get(breakdown, "technicalMetrics", nothing)
        tech isa AbstractDict || return nothing
        return _comparison_number(get(tech, key, nothing))
    else
        return _comparison_number(get(breakdown, key, nothing))
    end
end

"""
    build_planning_comparison(planning_id::String) -> Dict{String,Any}

C-405 方案比较汇总：
- 统一指标（适应度/目标/惩罚/运行成本/投资/NPV/LCOE/IRR/回收期），全部来自候选 breakdown；
- 基准差异：可行候选以排名第 1 者（同 bestEvaluationId 口径）为基准，逐项做差；
- 输入版本：项目快照 hash、场景集 hash、评价器版本随响应下发；
- 排名规则可解释：fitness 升序（同值按评价次序），不可行候选不隐藏、排在最后并带失败原因；
- 每个汇总值可通过 metricSources 追到 breakdown 明细键与公式版本。
"""
function build_planning_comparison(planning_id::String)
    task = get_planning_task(planning_id)
    task === nothing && error("规划任务不存在: $(planning_id)")
    evaluations = list_planning_evaluations(planning_id)

    economics_config = get(task["config"], "economics", Dict{String,Any}())
    objective = string(get(economics_config, "objective", "operating-cost-min"))
    evaluator = string(get(economics_config, "evaluator", DEFAULT_CAPACITY_EVALUATOR_VERSION))

    # 变量标签（候选 payload 只有 id，补充名称供前端展示）
    variable_labels = Dict{String,Dict{String,Any}}()
    for variable in get(task["config"], "variables", [])
        variable_labels[string(variable["componentId"])] = Dict{String,Any}(
            "componentName" => string(get(variable, "componentName", variable["componentId"])),
            "componentKey" => string(get(variable, "componentKey", "")),
            "unit" => string(get(variable, "unit", "")),
            "currentValue" => _comparison_number(get(variable, "currentValue", nothing)),
        )
    end

    # 排名：可行候选按 fitness 升序（同值按 ordinal，保证可重复排序）；不可行排最后
    feasible_items = sort(
        [item for item in evaluations if item["feasible"]],
        by = item -> (Float64(item["fitness"]), Int(item["ordinal"])),
    )
    infeasible_items = [item for item in evaluations if !item["feasible"]]
    rank_by_id = Dict{Int,Int}()
    for (rank, item) in enumerate(feasible_items)
        rank_by_id[Int(item["id"])] = rank
    end
    ordered = vcat(feasible_items, infeasible_items)
    baseline_id = isempty(feasible_items) ? nothing : Int(feasible_items[1]["id"])

    # 基准差异：对每个统一指标做差（候选值 − 基准值）
    metric_values = Dict{Int,Dict{String,Union{Float64,Nothing}}}()
    for item in ordered
        breakdown = item["breakdown"]
        breakdown isa AbstractDict || (breakdown = Dict{String,Any}())
        values = Dict{String,Union{Float64,Nothing}}(
            key => _comparison_metric_value(breakdown, key) for (key, _, _, _) in COMPARISON_METRICS
        )
        metric_values[Int(item["id"])] = values
    end
    baseline_values = baseline_id === nothing ? Dict{String,Union{Float64,Nothing}}() :
                      get(metric_values, baseline_id, Dict{String,Union{Float64,Nothing}}())

    # 多指标排名（排序对目标选择的敏感性）：可行候选内按各指标方向排名
    ranks_by_metric = Dict{String,Dict{Int,Union{Int,Nothing}}}()
    for (key, _, direction, _) in COMPARISON_METRICS
        ranked = sort(
            [item for item in feasible_items if metric_values[Int(item["id"])][key] !== nothing],
            by = item -> begin
                value = metric_values[Int(item["id"])][key]
                direction == "asc" ? (value, Int(item["ordinal"])) : (-value, Int(item["ordinal"]))
            end,
        )
        metric_ranks = Dict{Int,Union{Int,Nothing}}(
            Int(item["id"]) => nothing for item in feasible_items
        )
        for (rank, item) in enumerate(ranked)
            metric_ranks[Int(item["id"])] = rank
        end
        ranks_by_metric[key] = metric_ranks
    end

    candidates = Dict{String,Any}[]
    for item in ordered
        evaluation_id = Int(item["id"])
        breakdown = item["breakdown"]
        breakdown isa AbstractDict || (breakdown = Dict{String,Any}())
        values = metric_values[evaluation_id]

        # 典型场景贡献：scenarioCost:<id> 键，占加权运行成本比重
        contributions = Dict{String,Float64}()
        for (key, value) in breakdown
            startswith(string(key), "scenarioCost:") || continue
            number = _comparison_number(value)
            number === nothing && continue
            contributions[string(key)[length("scenarioCost:") + 1:end]] = number
        end
        # 运行成本可能因售电收益大于购能/运维支出而为负。此时仍然有完整的
        # 场景成本数据，不能因为年度净成本 <= 0 就把占比全部置空。
        # “贡献占比”按各场景加权净成本的绝对值归一化；带符号的原始金额仍由
        # weightedCostYuan 下发，前端可同时表达该场景是成本还是净收益。
        contribution_scale = sum(abs(cost) for (_, cost) in contributions)
        scenario_contributions = [
            Dict{String,Any}(
                "scenarioId" => scenario_id,
                "weightedCostYuan" => cost,
                "share" => contribution_scale <= 0 ? nothing : abs(cost) / contribution_scale,
            )
            for (scenario_id, cost) in sort(collect(contributions); by = pair -> -abs(pair[2]))
        ]

        diff = Dict{String,Float64}()
        if baseline_id !== nothing
            for (key, _, _, _) in COMPARISON_METRICS
                candidate_value = values[key]
                baseline_value = get(baseline_values, key, nothing)
                (candidate_value === nothing || baseline_value === nothing) && continue
                diff[key] = candidate_value - baseline_value
            end
        end

        candidate_metrics = Dict{String,Any}(
            "values" => Dict(key => values[key] for (key, _, _, _) in COMPARISON_METRICS),
            "diffBaseline" => diff,
            "ranksByMetric" => Dict(
                key => get(ranks_by_metric[key], evaluation_id, nothing)
                for (key, _, _, _) in COMPARISON_METRICS
            ),
            "detail" => Dict{String,Any}(
                "lifecycleCapexWan" => _comparison_number(get(breakdown, "lifecycleCapexWan", nothing)),
                "lifecycleConstructionVatWan" => _comparison_number(get(breakdown, "lifecycleConstructionVatWan", nothing)),
                "lifecycleWorkingCapitalWan" => _comparison_number(get(breakdown, "lifecycleWorkingCapitalWan", nothing)),
                "lifecycleDisposalRecoveryWan" => _comparison_number(get(breakdown, "lifecycleDisposalRecoveryWan", nothing)),
                "lifecycleAnnualDepreciationWan" => _comparison_number(get(breakdown, "lifecycleAnnualDepreciationWan", nothing)),
                "lifecycleAnnualAdjustedTaxWan" => _comparison_number(get(breakdown, "lifecycleAnnualAdjustedTaxWan", nothing)),
                "lifecycleNpvAfterTaxWan" => _comparison_number(get(breakdown, "lifecycleNpvAfterTaxWan", nothing)),
                "lifecycleDiscountedCostWan" => _comparison_number(get(breakdown, "lifecycleDiscountedCostWan", nothing)),
                "cashflowWan" => let raw = get(breakdown, "lifecycleAfterTaxCashflowWan", nothing)
                    raw isa AbstractVector ? [_comparison_number(v) for v in raw] : nothing
                end,
            ),
            "scenarioContributions" => scenario_contributions,
        )

        push!(candidates, Dict{String,Any}(
            "evaluationId" => evaluation_id,
            "ordinal" => Int(item["ordinal"]),
            "rank" => get(rank_by_id, evaluation_id, nothing),
            "isBest" => evaluation_id == baseline_id,
            "feasible" => item["feasible"] == true,
            "fitness" => Float64(item["fitness"]),
            "failureReason" => item["feasible"] == true ? nothing :
                               (item["errorMessage"] === nothing ? "仿真/评价失败" : string(item["errorMessage"])),
            "durationMs" => Int(item["durationMs"]),
            "capacities" => Dict{String,Any}(string(key) => value for (key, value) in item["candidate"]),
            "metrics" => candidate_metrics,
        ))
    end

    return Dict{String,Any}(
        "planningId" => planning_id,
        "projectId" => task["projectId"],
        "canvasId" => task["canvasId"],
        "objective" => objective,
        "inputVersion" => Dict{String,Any}(
            "projectSnapshotHash" => task["projectSnapshotHash"],
            "scenarioSetHash" => task["scenarioSetHash"],
            "economicEvaluatorVersion" => evaluator,
            "simulationEvaluatorVersion" => CAPACITY_EVALUATOR_VERSION,
        ),
        "rankingRule" =>
            "fitness = 目标[$(objective)] 目标值(objectiveFitness) + 经济约束惩罚(constraintPenalty)；" *
            "可行候选按 fitness 升序排名（同值按评价次序，可重复排序）；不可行候选不参与排名，" *
            "按评价次序排在最后并显示失败原因。",
        "baselineEvaluationId" => baseline_id,
        "candidates" => candidates,
        "variableLabels" => variable_labels,
        "metricSources" => [
            Dict{String,Any}("key" => key, "label" => label, "direction" => direction, "source" => source)
            for (key, label, direction, source) in COMPARISON_METRICS
        ],
    )
end
