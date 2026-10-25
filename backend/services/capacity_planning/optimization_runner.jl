using BlackBoxOptim
using JSON3
using Random
using SHA

const CAPACITY_OPTIMIZER_METHODS = Set([
    "adaptive_de_rand_1_bin_radiuslimited",
    "adaptive_de_rand_1_bin",
    "separable_nes",
    "dxnes",
    "xnes",
    "generating_set_search",
    "probabilistic_descent",
    "random_search",
])
const CAPACITY_EVALUATOR_VERSION = "simulation-evaluator-v1"
const PLANNING_OPTIMIZER_LOCK = ReentrantLock()

"""
    _auto_failure_penalty_base(optimizer, objective, variables) -> Float64

失败惩罚基数：optimizer.failurePenalty > 0 时作为用户覆盖；
否则按目标量纲与变量上界自动估算，保证不可行解永远劣于可行解。
"""
function _auto_failure_penalty_base(optimizer::AbstractDict, objective::String, variables)::Float64
    user = Float64(get(optimizer, "failurePenalty", 0.0))
    if isfinite(user) && user > 0
        return user
    end
    capacity_scale = 0.0
    for item in variables
        string(get(item, "mode", "")) == "optimize" || continue
        ub = Float64(get(item, "upperBound", 0.0))
        isfinite(ub) && (capacity_scale += max(ub, 0.0))
    end
    # 元量级粗估：容量上界 × 1e4 元/单位，再取 10 倍隔离带
    money_scale = max(capacity_scale * 1.0e4, 1.0e8)
    unit = _objective_unit(objective)
    if unit == "money"
        return 10.0 * money_scale
    elseif unit == "intensity"
        return 100.0
    elseif unit == "time"
        return 100.0
    end
    return 10.0
end

"""失败适应度：基数与「当前最优可行 × 10 + 基数」取大，隔离可行解。"""
function _failure_fitness(base::Float64, best_fitness::Float64)::Float64
    if isfinite(best_fitness)
        return max(base, abs(best_fitness) * 10.0 + base)
    end
    return base
end

"""进度用最优 breakdown 摘要：只保留前端展示所需字段，避免 progress 膨胀。"""
function _best_breakdown_summary(breakdown::Union{Nothing,AbstractDict})
    breakdown === nothing && return nothing
    tech_metrics = get(breakdown, "technicalMetrics", nothing)
    tech_details = get(breakdown, "technicalConstraintDetails", nothing)
    objective = get(breakdown, "objectiveFitness", nothing)
    weighted = get(breakdown, "weightedOperatingCost", objective)
    ind = get(breakdown, "indicators", nothing)
    return Dict{String,Any}(
        "objectiveFitness" => objective,
        "weightedOperatingCost" => weighted,
        "constraintPenalty" => get(breakdown, "constraintPenalty", nothing),
        "constraintPenaltyInObjectiveUnit" => get(breakdown, "constraintPenaltyInObjectiveUnit", nothing),
        "technicalConstraintPenalty" => get(breakdown, "technicalConstraintPenalty", nothing),
        "fitnessPenaltyMode" => get(breakdown, "fitnessPenaltyMode", nothing),
        "technicalMetrics" => tech_metrics isa AbstractDict ? Dict{String,Any}(tech_metrics) : nothing,
        "technicalConstraintDetails" => tech_details isa AbstractVector ? collect(tech_details) : nothing,
        "indicators" => ind isa AbstractDict ? Dict{String,Any}(ind) : nothing,
    )
end

"""收敛曲线/指标卡用的单次评价指标摘要（含技术指标与惩罚标记）。"""
function _evaluation_chart_metrics(breakdown::AbstractDict, feasible::Bool, fitness=nothing)
    tech = get(breakdown, "technicalMetrics", nothing)
    tech_dict = tech isa AbstractDict ? tech : Dict{String,Any}()
    details = get(breakdown, "technicalConstraintDetails", nothing)
    has_tech_penalty = false
    if details isa AbstractVector
        for item in details
            item isa AbstractDict || continue
            penalty = get(item, "penalty", 0.0)
            (penalty isa Real && penalty > 0) && (has_tech_penalty = true)
        end
    end
    technical_penalty = get(breakdown, "technicalConstraintPenalty", 0.0)
    constraint_penalty = get(breakdown, "constraintPenalty", 0.0)
    indicators = get(breakdown, "indicators", nothing)
    ind = indicators isa AbstractDict ? indicators : Dict{String,Any}()
    num(key) = begin
        v = get(tech_dict, key, nothing)
        v isa Real ? Float64(v) : nothing
    end
    return Dict{String,Any}(
        "feasible" => feasible,
        "fitness" => fitness isa Real && isfinite(fitness) ? Float64(fitness) : nothing,
        "hasPenalty" => feasible && (has_tech_penalty || (constraint_penalty isa Real && constraint_penalty > 0)),
        "renewableConsumptionRate" => num("renewableConsumptionRate"),
        "greenPowerShare" => num("greenPowerShare"),
        "purchasedPowerShare" => num("purchasedPowerShare"),
        "stability" => num("stability"),
        "stabilityExcessShare" => num("stabilityExcessShare"),
        "stabilityShortageShare" => num("stabilityShortageShare"),
        "objectiveFitness" => get(breakdown, "objectiveFitness", nothing),
        "weightedOperatingCost" => get(breakdown, "weightedOperatingCost", nothing),
        "lifecycleCapexWan" => get(breakdown, "lifecycleCapexWan", nothing),
        "irr" => get(ind, "irr", nothing),
        "lcoe" => get(ind, "lcoe", nothing),
        "npv" => get(ind, "npv", nothing),
        "constraintPenalty" => constraint_penalty,
    )
end

function _quantize_candidate(values, variables)
    quantized = Float64[]
    optimize_variables = [item for item in variables if item["mode"] == "optimize"]
    length(values) == length(optimize_variables) || throw(CapacityPlanningError(
        "CANDIDATE_DIMENSION_MISMATCH", "优化器返回的候选维度不正确",
    ))
    for (value, variable) in zip(values, optimize_variables)
        lower = Float64(variable["lowerBound"])
        upper = Float64(variable["upperBound"])
        number = Float64(value)
        isfinite(number) || throw(CapacityPlanningError("NON_FINITE_CANDIDATE", "优化器返回非有限容量"))
        kind = string(get(variable, "valueKind", "continuous"))
        if kind == "integer"
            # C-401：整数台数量化（吸附到界内整数网格，避免下界带小数时候选出现小数）
            lo = ceil(lower)
            hi = floor(upper)
            lo <= hi || throw(CapacityPlanningError("INTEGER_RANGE_EMPTY", "容量范围内没有整数"))
            number = clamp(round(number), lo, hi)
        elseif kind == "tier"
            # C-401：离散档位量化（吸附到最近档位）
            tiers = Float64.(get(variable, "tiers", nothing) isa AbstractVector ?
                            variable["tiers"] : [lower, upper])
            tiers = filter(tier -> lower <= tier <= upper, tiers)
            isempty(tiers) && throw(CapacityPlanningError("TIER_RANGE_EMPTY", "容量范围内没有合法档位"))
            number = tiers[argmin(abs.(tiers .- number))]
        else
            raw_step = get(variable, "step", nothing)
            step = raw_step isa Real ? Float64(raw_step) : 0.0
            if step > 0
                # C-401：吸附到 step 的整数倍网格（0 对齐），候选恒为整数；
                # 不再锚在下界上——下界 = 当前值×系数，常带小数，会传染给全部候选
                k_lo = ceil(lower / step)
                k_hi = floor(upper / step)
                k = round(number / step)
                number = k_lo <= k_hi ? clamp(k, k_lo, k_hi) * step : clamp(number, lower, upper)
            else
                number = clamp(number, lower, upper)
            end
            number = clamp(number, lower, upper)
        end
        push!(quantized, number)
    end
    return quantized
end

"""
    _variable_constraint_violation(variables, optimized_values) -> Union{Nothing,String}

C-401 结构约束后验检查（优化器只支持盒约束，成组/互斥在量化后校验）：
- 互斥组：同组至多一个变量（含 fixed）偏离现有容量；
- 成组比例：以组内 ratio 最大者为基准，其余成员按 ratio 等比联动，容差取成员 step 的一半。
违约返回原因字符串，否则返回 nothing。
"""
function _variable_constraint_violation(variables, optimized_values)
    optimized_index = 0
    assigned = Dict{String,Float64}()
    for variable in variables
        value = if variable["mode"] == "optimize"
            optimized_index += 1
            Float64(optimized_values[optimized_index])
        else
            Float64(variable["fixedValue"])
        end
        assigned[string(variable["componentId"])] = value
    end

    # 互斥：同组至多一个偏离现有容量
    mutex_seen = Dict{String,String}()
    for variable in variables
        mutex = get(variable, "mutexGroup", nothing)
        mutex === nothing && continue
        component_id = string(variable["componentId"])
        abs(get(assigned, component_id, 0.0) - Float64(variable["currentValue"])) <= 1.0e-9 && continue
        mutex = string(mutex)
        if haskey(mutex_seen, mutex)
            return "互斥组 $(mutex)：$(mutex_seen[mutex]) 与 $(component_id) 同时偏离现有容量"
        end
        mutex_seen[mutex] = component_id
    end

    # 成组：v_i / v_base = ratio_i / ratio_base（基准取 ratio 最大者）
    groups = Dict{String,Vector{Any}}()
    for variable in variables
        gid = get(variable, "groupId", nothing)
        gid === nothing && continue
        push!(get!(groups, string(gid), Any[]), variable)
    end
    for (gid, members) in groups
        base = members[argmax([Float64(m["groupRatio"]) for m in members])]
        base_id = string(base["componentId"])
        base_value = get(assigned, base_id, 0.0)
        for member in members
            member === base && continue
            expected = base_value / Float64(base["groupRatio"]) * Float64(member["groupRatio"])
            raw_step = get(member, "step", 0.0)
            step = raw_step isa Real ? abs(Float64(raw_step)) : 0.0
            tolerance = max(step * 0.5, abs(expected) * 1.0e-6)
            actual = get(assigned, string(member["componentId"]), 0.0)
            abs(actual - expected) > tolerance &&
                return "成组 $(gid)：$(member["componentId"]) 取 $(actual)，按基准 $(base_id)=$(base_value) 的比例应为 $(expected)"
        end
    end
    return nothing
end

function _candidate_payload(variables, optimized_values)
    result = Dict{String,Any}()
    optimized_index = 0
    for variable in variables
        value = if variable["mode"] == "optimize"
            optimized_index += 1
            optimized_values[optimized_index]
        else
            Float64(variable["fixedValue"])
        end
        result[string(variable["componentId"])] = Dict(
            "value" => value,
            "unit" => string(variable["unit"]),
            "mode" => string(variable["mode"]),
        )
    end
    return result
end

"""
    _original_capacities(project_snapshot, canvas_id, variables) -> Dict{String,Float64}

C-401 第二增量：从（变更前）项目快照读取各规划组件的原始容量，
供生命周期经济计算退役/替换的处置回收。
"""
function _original_capacities(project_snapshot::AbstractDict, canvas_id::String, variables)
    _, canvas = _candidate_canvas(project_snapshot, canvas_id)
    nodes_by_id = Dict{String,Any}()
    for node in get(canvas, "nodes", [])
        nodes_by_id[string(get(node, "id", ""))] = node
    end
    capacities = Dict{String,Float64}()
    for item in variables
        component_id = string(get(item, "componentId", ""))
        node = get(nodes_by_id, component_id, nothing)
        node === nothing && continue
        business = get(get(node, "data", Dict{String,Any}()), "business", Dict{String,Any}())
        params = get(business, "commonTechParams", Dict{String,Any}())
        raw = get(params, "capacity", nothing)
        if raw isa Real
            number = Float64(raw)
            isfinite(number) && (capacities[component_id] = number)
        end
    end
    return capacities
end

function _candidate_hash(task, scenario_set, values, economic_version)
    payload = Dict(
        "projectSnapshotHash" => task["projectSnapshotHash"],
        "scenarioSetHash" => scenario_set["scenarioSetHash"],
        "candidate" => values,
        "evaluatorVersion" => CAPACITY_EVALUATOR_VERSION,
        "economicModelVersion" => economic_version,
    )
    return bytes2hex(SHA.sha256(Vector{UInt8}(codeunits(JSON3.write(payload)))))
end

"""
    _safe_rm_workdir(path) -> Bool

清理候选工作目录（BUG-005）：Windows 下场景 timeseries.db 的 SQLite 句柄可能
尚未 finalize，直接 rm 会 EBUSY 并把整个规划任务拖死。改为失败时 GC 促一次
finalize 后重试，仍失败仅告警跳过并保留残留目录——清理失败不影响结果正确性，
绝不向上抛出。
"""
function _safe_rm_workdir(path::String)
    isdir(path) || return true
    for attempt in 1:3
        try
            rm(path; recursive=true, force=true)
            return true
        catch error
            if attempt < 3
                # 促使未 finalize 的 SQLite.DB 句柄释放文件锁
                GC.gc(true)
                sleep(0.5)
            else
                @warn "候选工作目录清理失败，保留残留目录（不影响规划结果）" path exception=(error, catch_backtrace())
                return false
            end
        end
    end
    return false
end

function _planning_cancelled(ctx)
    ctx.cancel_requested[] && return true
    if isready(ctx.signal_ch) && take!(ctx.signal_ch) == :cancel
        ctx.cancel_requested[] = true
    end
    ctx.cancel_requested[] || planning_remaining_seconds()
    return ctx.cancel_requested[]
end

function _planning_phase_progress!(planning_id, phase, started_ns; kwargs...)
    task = get_planning_task(planning_id)
    progress = task === nothing ? Dict{String,Any}() : task["progress"]
    progress["phase"] = phase
    progress["elapsedMs"] = round(Int, planning_elapsed_seconds() * 1000)
    progress["wallElapsedMs"] = round(Int, (time_ns() - started_ns) / 1_000_000)
    for (key, value) in kwargs
        progress[string(key)] = value
    end
    update_planning_progress!(planning_id, progress)
    return progress
end

function _planning_result_variables(variables, best_candidate)
    result = Dict{String,Any}[]
    for variable in variables
        component_id = string(variable["componentId"])
        optimal = Float64(best_candidate[component_id]["value"])
        current = Float64(variable["currentValue"])
        change_rate = abs(current) <= eps(Float64) ? nothing : (optimal - current) / current
        push!(result, Dict{String,Any}(
            "componentId" => component_id,
            "componentKey" => variable["componentKey"],
            "componentName" => variable["componentName"],
            "mode" => variable["mode"],
            "unit" => variable["unit"],
            "currentValue" => current,
            "optimalValue" => optimal,
            "changeRate" => change_rate,
        ))
    end
    return result
end

"""Finalize only committed, fully evaluated candidates (also used after a hard deadline)."""
function complete_planning_from_evaluations!(planning_id::String; stop_reason::Union{Nothing,String}=nothing)
    task = get_planning_task(planning_id)
    evaluations = list_planning_evaluations(planning_id)
    feasible = filter(item -> item["feasible"] && isfinite(item["fitness"]), evaluations)
    isempty(feasible) && throw(CapacityPlanningError("NO_FEASIBLE_CANDIDATE", "评价预算内没有找到可行容量方案"))
    best = first(sort(feasible; by=item -> (item["fitness"], item["ordinal"])))
    directory = planning_task_dir(planning_id)
    scenarios = JSON3.read(read(joinpath(directory, "scenarios.json"), String), Dict{String,Any})
    history = Dict{String,Any}[]
    running_best = Inf
    for item in evaluations
        item["feasible"] && (running_best = min(running_best, Float64(item["fitness"])))
        item_breakdown = item["breakdown"]
        item_bd = item_breakdown isa AbstractDict ? item_breakdown : Dict{String,Any}()
        push!(history, Dict(
            "ordinal"=>item["ordinal"], "fitness"=>item["fitness"],
            "feasible"=>item["feasible"], "bestSoFar"=>isfinite(running_best) ? running_best : nothing,
            "metrics"=>_evaluation_chart_metrics(item_bd, Bool(item["feasible"]), item["fitness"]),
        ))
    end
    warnings = String.(get(best["breakdown"], "warnings", String[]))
    stop_reason !== nothing && push!(warnings, stop_reason)
    result = Dict{String,Any}(
        "planningId"=>planning_id, "projectId"=>task["projectId"], "canvasId"=>task["canvasId"],
        "projectUpdatedAt"=>task["projectUpdatedAt"], "scenarioSetHash"=>scenarios["scenarioSetHash"],
        "fitness"=>best["fitness"], "breakdown"=>best["breakdown"], "warnings"=>warnings,
        "economicEvaluatorVersion"=>get(task["config"]["economics"], "evaluator", DEFAULT_CAPACITY_EVALUATOR_VERSION),
        "simulationEvaluatorVersion"=>CAPACITY_EVALUATOR_VERSION,
        "variables"=>_planning_result_variables(task["config"]["variables"], best["candidate"]),
        "bestCandidate"=>best["candidate"], "evaluationCount"=>length(evaluations),
        "failedEvaluationCount"=>count(item -> !item["feasible"], evaluations), "convergence"=>history,
        "scenarioSummary"=>Dict("config"=>scenarios["config"], "quality"=>scenarios["quality"],
            "scenarios"=>[Dict(key=>item[key] for key in ("scenarioId","representativeDate","weightDays","probability")) for item in scenarios["scenarios"]]),
    )
    set_best_planning_evaluation!(planning_id, best["id"])
    save_planning_result!(planning_id, result)
    write(joinpath(directory, "result.json"), JSON3.write(result))
    progress = Dict{String,Any}(task["progress"])
    merge!(progress, Dict("phase"=>"completed", "completedEvaluations"=>length(evaluations),
        "failedEvaluations"=>result["failedEvaluationCount"], "bestFitness"=>best["fitness"],
        "bestCandidate"=>best["candidate"], "convergence"=>history, "cancellationRequested"=>false,
        "bestBreakdown"=>_best_breakdown_summary(best["breakdown"]),
        "currentScenario"=>nothing, "stopReason"=>stop_reason))
    update_planning_progress!(planning_id, progress)
    set_planning_status!(planning_id, "completed")
    return result
end

"""运行一个已冻结的规划任务。调用方负责捕获异常并更新终态。"""
function run_capacity_optimization!(planning_id::String, ctx)
    lock(PLANNING_OPTIMIZER_LOCK) do
        task = get_planning_task(planning_id)
        task === nothing && error("规划任务不存在: $(planning_id)")
        start_planning_budget!(Float64(get(task["config"]["optimizer"], "maxTimeSeconds", 86400.0)))
        try
            return _run_capacity_optimization!(planning_id, ctx)
        finally
            finish_planning_budget!()
        end
    end
end

function _run_capacity_optimization!(planning_id::String, ctx)
    lock(PLANNING_OPTIMIZER_LOCK) do
        started_ns = time_ns()
        task = get_planning_task(planning_id)
        task === nothing && error("规划任务不存在: $(planning_id)")
        config = task["config"]
        planning_dir = planning_task_dir(planning_id)
        snapshot = JSON3.read(read(joinpath(planning_dir, "project_snapshot.json"), String), Dict{String,Any})

        set_planning_status!(planning_id, "validating")
        _planning_phase_progress!(planning_id, "validating", started_ns)
        _planning_cancelled(ctx) && throw(PlanningCancelled("规划任务已取消"))
        variables = perf_measure("planning", planning_id, "planning_validate") do
            validate_capacity_variables(snapshot, task["canvasId"], config["variables"])
        end
        config["variables"] = variables
        update_planning_config!(planning_id, config)

        set_planning_status!(planning_id, "clustering")
        _planning_phase_progress!(planning_id, "clustering", started_ns)
        _planning_cancelled(ctx) && throw(PlanningCancelled("规划任务已取消"))
        scenario_set = perf_measure("planning", planning_id, "scenario_reduce") do
            reduce_boundary_scenarios(config["clustering"], string(task["canvasId"]), snapshot)
        end
        # C-402：预览与运行同版本校验——边界数据在预览后被修改时给出明确告警
        preview_hash = get(get(config, "clustering", Dict{String,Any}()), "scenarioPreviewHash", nothing)
        if preview_hash !== nothing && string(preview_hash) != string(scenario_set["scenarioSetHash"])
            push!(get!(scenario_set["quality"], "warnings", String[]),
                "场景集与预览时不一致（边界数据可能在预览后被修改），预览 hash=$(preview_hash)，当前 hash=$(scenario_set["scenarioSetHash"])")
        end
        save_planning_scenarios!(planning_id, scenario_set)
        save_scenario_set_series!(planning_id, scenario_set["scenarios"])
        write(joinpath(planning_dir, "scenarios.json"), JSON3.write(scenario_set))

        optimizer = config["optimizer"]
        economics_config = config["economics"]
        economic_evaluator = economic_evaluator_from_config(economics_config)
        economic_version = economic_evaluator_version(economic_evaluator)
        objective = string(get(economics_config, "objective", "operating-cost-min"))
        failure_penalty_base = _auto_failure_penalty_base(optimizer, objective, variables)
        max_evaluations = Int(optimizer["maxFuncEvals"])
        variables_optimized = [item for item in variables if item["mode"] == "optimize"]
        suggested = Float64[item["suggestedValue"] for item in variables_optimized]
        search_range = [(Float64(item["lowerBound"]), Float64(item["upperBound"])) for item in variables_optimized]
        units = Dict(string(item["componentId"]) => string(item["unit"]) for item in variables)

        original_capacities = _original_capacities(snapshot, string(task["canvasId"]), variables)

        # 任务级 COPT 环境：整个优化循环复用同一个 Env；任务结束后在 finally 中强制释放，
        # 避免残留句柄/内存影响下一次任务，否则第二次运行易出现 COPT_CreateEnv ReadOnlyMemoryError。
        copt_env = nothing
        optimizer_factory = nothing
        try
            solver_name = get_solver_name(Dict{String,Any}(get(snapshot, "algorithm", Dict())))
            if solver_name == "COPT"
                require_copt()
                copt_env = COPT.Env()
                optimizer_factory = () -> COPT.Optimizer(copt_env)
            else
                optimizer_factory = solver_optimizer(solver_name)
            end

            set_planning_status!(planning_id, "optimizing")
            progress = _planning_phase_progress!(
                planning_id, "optimizing", started_ns;
                maxFuncEvals=max_evaluations,
                completedEvaluations=0,
                failedEvaluations=0,
                bestFitness=nothing,
                bestCandidate=nothing,
                convergence=Any[],
            )

            completed = Ref(0)
            failed = Ref(0)
            consecutive_failed = Ref(0)
            best_fitness = Ref(Inf)
            best_candidate = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
            best_breakdown = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
            best_warnings = Ref(String[])
            best_work_dir = Ref{Union{Nothing,String}}(nothing)
            live_history = Dict{String,Any}[]

            function fitness(raw_values)
                _planning_cancelled(ctx) && throw(PlanningCancelled("规划任务已取消"))
                # 主动回收上一轮迭代残留的 JuMP/COPT 资源，缓解长循环中的内存/GC 压力
                perf_measure("planning", planning_id, "candidate_gc") do
                    GC.gc(false)
                end
                perf_measure("planning", planning_id, "candidate_throttle_wait") do
                    sleep(0.2)
                end
                values = perf_measure("planning", planning_id, "candidate_quantize") do
                    _quantize_candidate(raw_values, variables)
                end
                candidate = _candidate_payload(variables, values)
                candidate_hash = _candidate_hash(task, scenario_set, values, economic_version)
                cached = cached_planning_evaluation(planning_id, candidate_hash)
                if cached !== nothing
                    perf_record("planning", planning_id, "candidate_cache_hit", 0.0, 0, 0, 0, "ok",
                        Dict{String,Any}("hash" => candidate_hash, "fitness" => cached["fitness"]))
                    return Float64(cached["fitness"])
                end

                if completed[] >= max_evaluations
                    return isfinite(best_fitness[]) ? best_fitness[] : failure_penalty_base
                end

                evaluation_started = time_ns()
                ordinal = completed[] + 1
                feasible = false
                evaluation_fitness = _failure_fitness(failure_penalty_base, best_fitness[])
                breakdown = Dict{String,Any}()
                error_code = nothing
                error_message = nothing
                warnings = String[]
                work_dir = joinpath(planning_dir, "work", candidate_hash[1:16])
                candidate_meta = Dict{String,Any}(
                    "ordinal" => ordinal,
                    "hash" => candidate_hash,
                    "scenarioCount" => length(scenario_set["scenarios"]),
                    "optimizeDim" => length(variables_optimized),
                )

                try
                    violation = perf_measure("planning", planning_id, "candidate_constraint_check";
                        meta=candidate_meta) do
                        _variable_constraint_violation(variables, values)
                    end
                    violation === nothing || throw(CapacityPlanningError("VARIABLE_CONSTRAINT_VIOLATION", violation))
                    candidate_snapshot, capacities = perf_measure("planning", planning_id, "candidate_snapshot";
                        meta=Dict("ordinal" => ordinal)) do
                        apply_capacity_candidate(snapshot, task["canvasId"], variables, values)
                    end
                    simulation = perf_measure("planning", planning_id, "candidate_simulation";
                        meta=Dict("ordinal" => ordinal, "scenario_count" => length(scenario_set["scenarios"]))) do
                        evaluate_snapshot(
                        candidate_snapshot,
                        task["canvasId"],
                        scenario_set,
                        work_dir;
                        options=EvaluationOptions(layer_id=string(config["planningLayerId"]),
                            scenario_time_limit_seconds=min(60.0, Float64(get(optimizer, "maxTimeSeconds", 60.0)))),
                        planning_id=planning_id,
                        optimizer_factory=optimizer_factory,
                        cancel_check=() -> _planning_cancelled(ctx),
                        progress_callback=info -> _planning_phase_progress!(planning_id, "optimizing", started_ns;
                            currentEvaluation=ordinal, currentScenario=info),
                    )
                    end
                    if simulation.feasible
                        economic = perf_measure("planning", planning_id, "candidate_economics";
                            meta=Dict("ordinal" => ordinal)) do
                            evaluate_economics(
                            economic_evaluator,
                            EconomicEvaluationInput(
                                capacities=capacities,
                                units=units,
                                simulation=simulation,
                                config=economics_config,
                                layer_id=string(config["planningLayerId"]),
                                work_dir=work_dir,
                                project_snapshot=candidate_snapshot,
                                change_kinds=Dict{String,String}(string(item["componentId"]) => string(get(item, "changeKind", "new")) for item in variables),
                                original_capacities=original_capacities,
                            ),
                        )
                        end
                        evaluation_fitness = economic.fitness
                        breakdown = Dict{String,Any}(economic.breakdown)
                        breakdown["scenarioMetrics"] = simulation.scenario_metrics
                        breakdown["indicators"] = Dict{String,Any}(economic.indicators)
                        breakdown["warnings"] = economic.warnings
                        warnings = economic.warnings
                        if any(!get(metric, "optimal", true) for metric in simulation.scenario_metrics)
                            push!(warnings, "部分典型场景达到单场景时限，使用已有可行解参与评价，尚未证明场景最优。")
                        end
                        feasible = true
                        consecutive_failed[] = 0
                    else
                        error_code = simulation.error_code
                        error_message = simulation.error_message
                    end
                catch error
                    (error isa PlanningCancelled || error isa PlanningTimeLimit) && rethrow()
                    error_code = error isa CapacityPlanningError ? error.code : "EVALUATION_ERROR"
                    error_message = error isa CapacityPlanningError ? error.message : sprint(showerror, error)
                end

                if !feasible
                    failed[] += 1
                    consecutive_failed[] += 1
                    evaluation_fitness = _failure_fitness(failure_penalty_base, best_fitness[])
                    breakdown = Dict("failurePenalty" => evaluation_fitness)
                end
                isfinite(evaluation_fitness) ||
                    (evaluation_fitness = max(failure_penalty_base, 1.0e18))
                duration_ms = round(Int, (time_ns() - evaluation_started) / 1_000_000)
                perf_record("planning", planning_id, "candidate_total", duration_ms, 0, 0, 0,
                    feasible ? "ok" : "failed", merge(candidate_meta, Dict{String,Any}(
                        "feasible" => feasible,
                        "fitness" => evaluation_fitness,
                        "errorCode" => error_code,
                    )))
                evaluation_id = perf_measure("planning", planning_id, "candidate_eval_insert";
                    meta=candidate_meta) do
                    insert_planning_evaluation!(
                    planning_id=planning_id,
                    ordinal=ordinal,
                    candidate_hash=candidate_hash,
                    candidate=candidate,
                    feasible=feasible,
                    fitness=evaluation_fitness,
                    breakdown=breakdown,
                    duration_ms=duration_ms,
                    error_code=error_code,
                    error_message=error_message,
                )
                end
                completed[] += 1

                if feasible && evaluation_fitness < best_fitness[]
                    previous_best_dir = best_work_dir[]
                    if previous_best_dir !== nothing && previous_best_dir != work_dir && isdir(previous_best_dir)
                        perf_measure("planning", planning_id, "candidate_cleanup") do
                            _safe_rm_workdir(previous_best_dir)
                        end
                    end
                    best_fitness[] = evaluation_fitness
                    best_candidate[] = candidate
                    best_breakdown[] = breakdown
                    best_warnings[] = warnings
                    best_work_dir[] = work_dir
                    set_best_planning_evaluation!(planning_id, evaluation_id)
                elseif isdir(work_dir)
                    perf_measure("planning", planning_id, "candidate_cleanup") do
                        _safe_rm_workdir(work_dir)
                    end
                end

                push!(live_history, Dict{String,Any}(
                    "ordinal" => ordinal,
                    "fitness" => evaluation_fitness,
                    "feasible" => feasible,
                    "bestSoFar" => isfinite(best_fitness[]) ? best_fitness[] : nothing,
                    "metrics" => _evaluation_chart_metrics(breakdown, feasible, evaluation_fitness),
                ))

                progress = _planning_phase_progress!(
                    planning_id, "optimizing", started_ns;
                    maxFuncEvals=max_evaluations,
                    completedEvaluations=completed[],
                    failedEvaluations=failed[],
                    bestFitness=isfinite(best_fitness[]) ? best_fitness[] : nothing,
                    bestCandidate=best_candidate[],
                    bestBreakdown=_best_breakdown_summary(best_breakdown[]),
                    convergence=live_history,
                    currentScenario=nothing,
                )
                consecutive_failed[] >= 1000 && throw(CapacityPlanningError(
                    "TOO_MANY_FAILED_EVALUATIONS", "连续 1000 个候选评价失败，请检查边界数据和容量范围",
                ))
                return evaluation_fitness
            end

            # 先评价建议值，保证即使种群初始化失败也有基线
            fitness(suggested)
            _planning_cancelled(ctx) && throw(PlanningCancelled("规划任务已取消"))

            remaining = max_evaluations - completed[]
            if remaining > 0
                # 随机种子对业务无意义：缺省/非正数时自动生成，保证可复现但不由用户填写
                seed_value = try
                    Int(optimizer["seed"])
                catch
                    0
                end
                if seed_value <= 0
                    seed_value = Int(time_ns() % 2_147_483_647)
                    optimizer["seed"] = seed_value
                end
                Random.seed!(seed_value)
                method = Symbol(string(optimizer["method"]))
                kwargs = Dict{Symbol,Any}(
                    :SearchRange => search_range,
                    :NumDimensions => length(search_range),
                    :Method => method,
                    :MaxFuncEvals => remaining,
                    :PopulationSize => Int(optimizer["populationSize"]),
                    :TraceMode => :silent,
                )
                # bboptimize 的墙钟会包含 JIT；统一由排除编译的预算时钟控制。
                perf_measure("planning", planning_id, "bboptimize"; meta=Dict{String,Any}(
                    "maxFuncEvals" => max_evaluations,
                    "populationSize" => Int(optimizer["populationSize"]),
                    "optimizeDim" => length(variables_optimized),
                    "scenarioCount" => length(scenario_set["scenarios"]),
                    "method" => string(get(optimizer, "method", "")),
                )) do
                    BlackBoxOptim.bboptimize(fitness, suggested; kwargs...)
                end
            end

            return complete_planning_from_evaluations!(planning_id)
        finally
            # 任务结束后强制释放 COPT 环境，避免残留句柄/内存影响下一次任务
            optimizer_factory = nothing
            if copt_env !== nothing
                try
                    finalize(copt_env)
                catch e
                    @warn "释放 COPT 环境失败" exception=e
                end
                copt_env = nothing
            end
            GC.gc(true)
            sleep(0.5)
        end
    end
end
