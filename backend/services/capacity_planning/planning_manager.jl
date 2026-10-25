using JSON3
using SHA

mutable struct PlanningContext
    signal_ch::Channel{Symbol}
    julia_task::Union{Task,Nothing}
    process::Union{Base.Process,Nothing}
    cancel_requested::Threads.Atomic{Bool}
    launching::Threads.Atomic{Bool}
end
PlanningContext(signal_ch::Channel{Symbol}, julia_task::Union{Task,Nothing}) =
    PlanningContext(signal_ch, julia_task, nothing, Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false))

const PLANNING_CONTEXTS = Dict{String,PlanningContext}()
const PLANNING_CONTEXTS_LOCK = ReentrantLock()
const PLANNING_WORKER_SLOTS = Base.Semaphore(1)

function _planning_dict(value, field::String)
    value isa AbstractDict || error("$(field) 必须是对象")
    return Dict{String,Any}(string(key) => item for (key, item) in value)
end

function _normalize_optimizer_config(raw)
    config = _planning_dict(raw, "optimizer")
    method = string(get(config, "method", "adaptive_de_rand_1_bin_radiuslimited"))
    method in CAPACITY_OPTIMIZER_METHODS || error("不支持的优化方法: $(method)")
    max_evals = Int(get(config, "maxFuncEvals", 20))
    2 <= max_evals <= 10_000 || error("maxFuncEvals 必须在 2 到 10000 之间")
    population = Int(get(config, "populationSize", min(10, max_evals)))
    2 <= population <= 500 || error("populationSize 必须在 2 到 500 之间")
    # 0 = 按目标量纲自动估算失败惩罚（optimization_runner._auto_failure_penalty_base）
    failure_penalty = Float64(get(config, "failurePenalty", 0.0))
    isfinite(failure_penalty) && failure_penalty >= 0 || error("failurePenalty 必须是非负有限数值（0=自动）")
    technical_penalty = Float64(get(config, "technicalPenalty", 1.0e7))
    isfinite(technical_penalty) && technical_penalty >= 0 || error("technicalPenalty 必须是非负有限数值")
    result = Dict{String,Any}(
        "method" => method,
        "maxFuncEvals" => max_evals,
        "populationSize" => population,
        "seed" => Int(get(config, "seed", 20260828)),
        "failurePenalty" => failure_penalty,
        "technicalPenalty" => technical_penalty,
    )
    if haskey(config, "maxTimeSeconds") && config["maxTimeSeconds"] !== nothing
        max_time = Float64(config["maxTimeSeconds"])
        1 <= max_time <= 86_400 || error("maxTimeSeconds 必须在 1 到 86400 之间")
        result["maxTimeSeconds"] = max_time
    end
    return result
end

const CAPACITY_PLAN_OBJECTIVES = Set([
    "total-cost-min",
    "operating-cost-min",
    "initial-investment-min",
    "npv-max",
    "lcoe-min",
    "payback-period-min",
    "irr-max",
])

function _normalize_percent(value, field::String)
    number = Float64(value)
    isfinite(number) && 0 <= number <= 100 || error("$(field) 必须在 0 到 100 之间")
    return number
end

function _normalize_economics_config(raw)
    config = _planning_dict(raw, "economics")
    evaluator = string(get(config, "evaluator", DEFAULT_CAPACITY_EVALUATOR_VERSION))
    objective = string(get(config, "objective", "operating-cost-min"))
    objective in CAPACITY_PLAN_OBJECTIVES || error("不支持的方案目标: $(objective)")

    constraint_defaults = Dict(
        "renewableConsumptionRate" => ("gte", 90.0),
        "greenPowerShare" => ("gte", 50.0),
        "purchasedPowerShare" => ("lte", 30.0),
        "stability" => ("gte", 95.0),
    )
    raw_constraints = get(config, "technicalConstraints", Dict{String,Any}())
    raw_constraints isa AbstractDict || error("economics.technicalConstraints 必须是对象")
    constraints = Dict{String,Any}()
    for (key, (default_operator, default_threshold)) in constraint_defaults
        raw_constraint = get(raw_constraints, key, Dict{String,Any}())
        raw_constraint isa AbstractDict || error("economics.technicalConstraints.$(key) 必须是对象")
        operator = string(get(raw_constraint, "operator", default_operator))
        operator in ("gte", "lte") || error("economics.technicalConstraints.$(key).operator 无效")
        constraints[key] = Dict(
            "enabled" => get(raw_constraint, "enabled", false) == true,
            "operator" => operator,
            "threshold" => _normalize_percent(get(raw_constraint, "threshold", default_threshold), "$(key).threshold"),
            "unit" => "%",
        )
    end

    economic_constraint_defaults = Dict(
        "lifecycleYears" => ("gte", 20.0, "年"),
        "interestRatePercent" => ("lte", 8.0, "%"),
        "taxRatePercent" => ("lte", 25.0, "%"),
        "targetIrrPercent" => ("gte", 8.0, "%"),
    )
    raw_economic_constraints = get(config, "economicConstraints", nothing)
    legacy_financial = get(config, "financialParameters", Dict{String,Any}())
    legacy_financial isa AbstractDict || error("economics.financialParameters 必须是对象")
    if raw_economic_constraints === nothing
        raw_economic_constraints = Dict{String,Any}(
            key => Dict("enabled" => true, "threshold" => get(legacy_financial, key, default_threshold))
            for (key, (_, default_threshold, _)) in economic_constraint_defaults
        )
    end
    raw_economic_constraints isa AbstractDict || error("economics.economicConstraints 必须是对象")
    economic_constraints = Dict{String,Any}()
    for (key, (default_operator, default_threshold, unit)) in economic_constraint_defaults
        raw_constraint = get(raw_economic_constraints, key, Dict{String,Any}())
        raw_constraint isa AbstractDict || error("economics.economicConstraints.$(key) 必须是对象")
        operator = string(get(raw_constraint, "operator", default_operator))
        operator in ("gte", "lte") || error("economics.economicConstraints.$(key).operator 无效")
        threshold = Float64(get(raw_constraint, "threshold", default_threshold))
        if key == "lifecycleYears"
            isfinite(threshold) && 1 <= threshold <= 100 || error("lifecycleYears.threshold 必须在 1 到 100 之间")
        else
            threshold = _normalize_percent(threshold, "$(key).threshold")
        end
        # 经济性参数始终生效；targetIrrPercent 为默认最低收益率约束（前端不再提供勾选）
        economic_constraints[key] = Dict(
            "enabled" => true,
            "operator" => operator,
            "threshold" => threshold,
            "unit" => unit,
        )
    end

    # 生命周期财务参数（lifecycle_economics.jl 字段名，snake_case）；可选覆盖
    raw_lifecycle = get(config, "lifecycle", Dict{String,Any}())
    raw_lifecycle isa AbstractDict || error("economics.lifecycle 必须是对象")
    lifecycle = Dict{String,Any}()
    for (key, value) in raw_lifecycle
        value isa Real || error("economics.lifecycle.$(key) 必须是数值")
        lifecycle[string(key)] = value
    end

    raw_extensions = get(config, "extensions", Dict{String,Any}())
    raw_extensions isa AbstractDict || error("economics.extensions 必须是对象")
    technical_penalty = Float64(get(config, "technicalPenalty", 1.0e7))
    isfinite(technical_penalty) && technical_penalty >= 0 || error("technicalPenalty 必须是非负有限数值")
    result = Dict{String,Any}(
        "evaluator" => evaluator,
        "currency" => string(get(config, "currency", "CNY")),
        "schemaVersion" => "capacity-objective-config-v2",
        "objective" => objective,
        "technicalConstraints" => constraints,
        "technicalPenalty" => technical_penalty,
        "economicConstraints" => economic_constraints,
        "lifecycle" => lifecycle,
        "extensions" => Dict{String,Any}(string(key) => value for (key, value) in raw_extensions),
    )
    economic_evaluator_from_config(result)
    return result
end

function _normalize_clustering_config(raw, project_id::String, canvas_id::String="")
    config = _planning_dict(raw, "clustering")
    dataset_id = String(strip(string(get(config, "datasetId", ""))))
    # 允许 datasetId 为空（草稿状态，后续步骤中补充）
    feature_ids_raw = get(config, "featureIds", nothing)
    feature_ids = feature_ids_raw isa AbstractVector ? String.(feature_ids_raw) : String[]
    algorithm = string(get(config, "algorithm", "kmeans"))
    algorithm in ("kmeans", "kmedoids") || error("clustering.algorithm 只能是 kmeans 或 kmedoids")
    return Dict{String,Any}(
        "projectId" => project_id,
        "canvasId" => canvas_id,
        "preserveExtremes" => get(config, "preserveExtremes", true) == true,
        "scenarioPreviewHash" => get(config, "scenarioPreviewHash", nothing),
        # 打开任务时对比边界是否已更新；savedScenarioPreview 供回显、不自动重算
        "boundariesVersion" => get(config, "boundariesVersion", nothing),
        "savedScenarioPreview" => get(config, "savedScenarioPreview", nothing),
        "datasetId" => isempty(dataset_id) ? nothing : dataset_id,
        "featureIds" => feature_ids,
        "clusterCount" => Int(get(config, "clusterCount", 0)),
        "algorithm" => algorithm,
        "normalize" => string(get(config, "normalize", "zscore")),
        "missingDayThreshold" => Float64(get(config, "missingDayThreshold", 0.05)),
        "seed" => Int(get(config, "seed", 20260828)),
        "representative" => string(get(config, "representative", "nearest-observation")),
    )
end

"""
    _planning_computable_snapshot(snapshot) -> Dict{String,Any}

提取参与计算的快照子集，用于 params_hash：
仅保留画布 id/nodes/edges 与 boundaries、layerConfig、algorithm、solverConfig 等计算字段，
剔除 viewport、display、画布名称、updateTime 等 UI/非计算字段，
保证相同计算输入得到唯一 snapshotHash（画布视口拖动、重命名不再使 hash 变化）。
"""
function _planning_computable_snapshot(snapshot::AbstractDict)
    workspace_src = get(snapshot, "workspace", Dict{String,Any}())
    canvases = Dict{String,Any}[]
    for canvas in get(workspace_src, "canvases", [])
        push!(canvases, Dict{String,Any}(
            "id" => get(canvas, "id", ""),
            "nodes" => get(canvas, "nodes", []),
            "edges" => get(canvas, "edges", []),
        ))
    end
    return Dict{String,Any}(
        "id" => get(snapshot, "id", ""),
        "schemaVersion" => get(snapshot, "schemaVersion", ""),
        "workspace" => Dict{String,Any}("canvases" => canvases),
        "boundaries" => get(snapshot, "boundaries", []),
        "layerConfig" => get(snapshot, "layerConfig", Dict{String,Any}()),
        "algorithm" => get(snapshot, "algorithm", Dict{String,Any}()),
        "solverConfig" => get(snapshot, "solverConfig", Dict{String,Any}()),
        "fittingModels" => get(snapshot, "fittingModels", []),
    )
end

function create_capacity_planning!(request::AbstractDict)
    project_id = String(strip(string(get(request, "projectId", ""))))
    canvas_id = String(strip(string(get(request, "canvasId", ""))))
    isempty(project_id) && error("缺少 projectId")
    isempty(canvas_id) && error("缺少 canvasId")
    snapshot = get(request, "projectJson", nothing)
    snapshot isa AbstractDict || error("缺少 projectJson（项目快照）")
    string(get(snapshot, "id", "")) == project_id || error("projectId 与项目快照不一致")
    variables_raw = get(request, "variables", nothing)
    variables_raw isa AbstractVector || error("variables 必须是数组")
    variables = validate_capacity_variables(snapshot, canvas_id, variables_raw)
    clustering = _normalize_clustering_config(get(request, "clustering", nothing), project_id, canvas_id)
    optimizer = _normalize_optimizer_config(get(request, "optimizer", Dict()))
    economics = _normalize_economics_config(get(request, "economics", Dict("evaluator" => DEFAULT_CAPACITY_EVALUATOR_VERSION)))
    # 技术约束惩罚系数：任务未显式配置时，取项目算法配置（建模页「算法配置」弹窗）
    request_optimizer = get(request, "optimizer", Dict())
    if request_optimizer isa AbstractDict && haskey(request_optimizer, "technicalPenalty")
        economics["technicalPenalty"] = optimizer["technicalPenalty"]
    else
        snapshot_algo = get(snapshot, "algorithm", Dict{String,Any}())
        economics["technicalPenalty"] = Float64(get(snapshot_algo, "technicalPenalty", optimizer["technicalPenalty"]))
    end
    planning_layer_id = string(get(request, "planningLayerId", "1"))
    _planning_layer(snapshot, planning_layer_id)

    project_updated_at = string(get(snapshot, "updateTime", ""))
    isempty(project_updated_at) && error("项目快照缺少 updateTime")
    snapshot_json = JSON3.write(snapshot)
    snapshot_hash = bytes2hex(SHA.sha256(Vector{UInt8}(codeunits(JSON3.write(_planning_computable_snapshot(snapshot))))))
    config = Dict{String,Any}(
        "variables" => variables,
        "clustering" => clustering,
        "optimizer" => optimizer,
        "economics" => economics,
        "planningLayerId" => planning_layer_id,
    )
    planning_id = create_planning_record!(
        project_id=project_id,
        canvas_id=canvas_id,
        name=String(strip(string(get(request, "name", "")))),
        project_updated_at=project_updated_at,
        snapshot_hash=snapshot_hash,
        config=config,
    )
    directory = planning_task_dir(planning_id)
    try
        mkpath(directory)
        write(joinpath(directory, "project_snapshot.json"), snapshot_json)
        write(joinpath(directory, "config.json"), JSON3.write(config))
    catch error
        set_planning_status!(planning_id, "failed"; error_code="SNAPSHOT_WRITE_FAILED", error_message=sprint(showerror, error))
        rethrow()
    end
    return get_planning_task(planning_id)
end

function planning_worker_command(planning_id::String)
    script = normpath(joinpath(@__DIR__, "..", "..", "capacity_worker.jl"))
    project = Base.active_project()
    command = project === nothing ?
        `$(Base.julia_cmd()) --startup-file=no --threads=1 $script $planning_id` :
        `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(project)) --threads=1 $script $planning_id`
    env = Dict{String,String}(
        "SYNERROLL_DATA_DIR" => BACKEND_DATA_DIR,
        "SYNERROLL_CAPACITY_WORKER" => "1",
    )
    # 性能探针必须显式传给独立 worker：父进程 SYNERROLL_PERF 不会被 Julia const 读取以外的方式继承到已 include 的模块。
    perf_flag = get(ENV, "SYNERROLL_PERF", "")
    if !isempty(perf_flag)
        env["SYNERROLL_PERF"] = perf_flag
    end
    return addenv(Cmd(command; windows_hide=true), env...)
end

function _mark_planning_cancelled!(planning_id::String)
    task = get_planning_task(planning_id)
    progress = Dict{String,Any}(task["progress"])
    merge!(progress, Dict("phase"=>"cancelled", "cancellationRequested"=>false, "currentScenario"=>nothing))
    update_planning_progress!(planning_id, progress)
    set_planning_status!(planning_id, "cancelled")
end

function _supervise_planning_worker!(planning_id::String, ctx::PlanningContext, command::Cmd, timeout_seconds::Real; compile_aware::Bool=true)
    process = nothing
    log = nothing
    timed_out = false
    Base.acquire(PLANNING_WORKER_SLOTS)
    try
        ctx.launching[] = true
        ctx.cancel_requested[] && return _mark_planning_cancelled!(planning_id)
        directory = joinpath(planning_task_dir(planning_id), "logs")
        mkpath(directory)
        log = open(joinpath(directory, "worker.log"), "a")
        process = run(pipeline(command; stdout=log, stderr=log); wait=false)
        lock(PLANNING_CONTEXTS_LOCK) do
            ctx.process = process
        end
        launched_at = time()
        # 正式 worker 使用排除 JIT 的预算时钟并把剩余预算传给原生求解器。
        # 自定义外部 worker 无 Julia 编译计时协议，仍由父进程作墙钟看门狗。
        deadline = compile_aware ? Inf : launched_at + timeout_seconds
        heartbeat_at = launched_at
        while process_running(process)
            if ctx.cancel_requested[] || time() >= deadline
                timed_out = !ctx.cancel_requested[]
                terminate_worker_process!(process)
                break
            end
            if time() - heartbeat_at >= 1.0
                if !compile_aware
                    update_planning_elapsed!(planning_id, round(Int, (time() - launched_at)*1000))
                end
                heartbeat_at = time()
            end
            sleep(0.1)
        end
        wait(process) # release all native solver/file handles before publishing a terminal state
        if ctx.cancel_requested[]
            _mark_planning_cancelled!(planning_id)
        elseif timed_out
            current = get_planning_task(planning_id)
            if current["status"] != "completed"
                try
                    complete_planning_from_evaluations!(planning_id;
                        stop_reason="已达到规划总时限，停止未完成求解，返回已完整评价候选中的最佳方案。")
                catch error
                    set_planning_status!(planning_id, "failed"; error_code="PLANNING_TIME_LIMIT",
                        error_message="已达到规划总时限且尚无完整可行候选；未完成场景已终止。")
                end
            end
        else
            current = get_planning_task(planning_id)
            if !(current["status"] in PLANNING_TERMINAL_STATUSES)
                set_planning_status!(planning_id, "failed"; error_code="WORKER_EXITED",
                    error_message="容量规划工作进程提前退出，详情见任务 logs/worker.log（退出码 $(process.exitcode)）。")
            end
        end
    catch error
        if ctx.cancel_requested[]
            _mark_planning_cancelled!(planning_id)
        else
            set_planning_status!(planning_id, "failed"; error_code="WORKER_FAILED", error_message=sprint(showerror, error))
        end
    finally
        if process !== nothing && process_running(process)
            terminate_worker_process!(process)
            wait(process)
        end
        log !== nothing && close(log)
        lock(PLANNING_CONTEXTS_LOCK) do
            get(PLANNING_CONTEXTS, planning_id, nothing) === ctx && pop!(PLANNING_CONTEXTS, planning_id)
        end
        Base.release(PLANNING_WORKER_SLOTS)
    end
end

function start_capacity_planning!(planning_id::String; worker_command::Union{Nothing,Cmd}=nothing)
    ctx = PlanningContext(Channel{Symbol}(1), nothing)
    task = lock(PLANNING_CONTEXTS_LOCK) do
        task = get_planning_task(planning_id)
        task === nothing && error("规划任务不存在: $(planning_id)")
        task["status"] == "draft" || error("只有 draft 状态可以启动，当前为 $(task["status"])")
        set_planning_status!(planning_id, "queued")
        PLANNING_CONTEXTS[planning_id] = ctx
        task
    end
    timeout_seconds = Float64(get(task["config"]["optimizer"], "maxTimeSeconds", 86400.0))
    command = worker_command === nothing ? planning_worker_command(planning_id) : worker_command
    worker = @async _supervise_planning_worker!(planning_id, ctx, command, timeout_seconds;
        compile_aware=worker_command === nothing)
    ctx.julia_task = worker
    return get_planning_task(planning_id)
end

function cancel_capacity_planning!(planning_id::String)
    task = get_planning_task(planning_id)
    task === nothing && error("规划任务不存在: $(planning_id)")
    task["status"] in PLANNING_TERMINAL_STATUSES && return task
    if task["status"] == "draft"
        set_planning_status!(planning_id, "cancelled")
        return get_planning_task(planning_id)
    end
    ctx = lock(PLANNING_CONTEXTS_LOCK) do
        ctx = get(PLANNING_CONTEXTS, planning_id, nothing)
        ctx === nothing && return nothing
        ctx.cancel_requested[] = true
        return ctx
    end
    ctx === nothing && error("该任务没有可控的工作进程，请重启旧版后端以终止遗留求解")
    progress = Dict{String,Any}(get_planning_task(planning_id)["progress"])
    progress["cancellationRequested"] = true
    update_planning_progress!(planning_id, progress)
    if ctx.process === nothing && !ctx.launching[]
        _mark_planning_cancelled!(planning_id)
    end
    # The supervisor observes the atomic request within its 100 ms polling loop;
    # it is the sole owner of kill/wait, avoiding double-kill and exit races.
    return get_planning_task(planning_id)
end

function reconcile_planning_tasks!()
    db = get_planning_store()
    timestamp = _planning_now()
    lock(PLANNING_STORE_LOCK) do
        _exec(db, """
            UPDATE planning_tasks
            SET status='failed', error_code='BACKEND_RESTARTED',
                error_message='后端重启导致规划中断，请新建规划任务重试',
                finished_at=?, updated_at=?
            WHERE status IN ('queued', 'validating', 'clustering', 'optimizing')
        """, (timestamp, timestamp))
    end
    return nothing
end
