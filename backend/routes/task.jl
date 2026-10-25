# 计算任务 REST + WebSocket 路由
# 依赖：utils/server_utils.jl（json_success / json_error / require_string / optional_string）
#        services/task_manager.jl（任务 CRUD + ctx）
#        services/simulation_runner.jl（spawn_task）

"""解析 query string。Oxygen/HTTP 下 req.url 可能不含 query，优先用 req.target。"""
function query_params(req)
    # HTTP.Request 不是 Dict，不能用 get(req, :key)；用属性安全读取
    for name in (:target, :url)
        local s
        try
            s = string(getproperty(req, name))
        catch
            continue
        end
        qidx = findfirst('?', s)
        qidx === nothing && continue
        qs = s[qidx+1:end]
        fidx = findfirst('#', qs)
        if fidx !== nothing
            qs = qs[1:fidx-1]
        end
        isempty(qs) && continue
        return HTTP.queryparams(HTTP.URI("http://local/?" * qs))
    end
    try
        return HTTP.queryparams(string(req.url))
    catch
        return Dict{String,String}()
    end
end

using UUIDs: uuid4

# ───── POST /api/task/create ─────
# 请求体必须包含 projectJson（前端画布完整 JSON），供 parse 阶段使用
@post "/api/task/create" function (req)
    try
        body = JSON3.read(req.body, Dict)

        project_id  = require_string(body, "projectId")
        canvas_id   = require_string(body, "canvasId")
        layer_id    = require_string(body, "layerId")
        mode        = get(body, "mode", "offline")
        sim_start   = require_string(body, "simStartTime")
        sim_end     = optional_string(body, "simEndTime", "")
        sim_start_date_raw = optional_string(body, "simStartDate", "")
        sim_end_date_raw = optional_string(body, "simEndDate", "")
        name        = optional_string(body, "name", "")
        params_json = JSON3.write(body)
        params_hash = bytes2hex(SHA.sha256(params_json))

        # projectJson 是前端传来的完整画布 JSON，parse 阶段需要
        project_json = get(body, "projectJson", nothing)
        if project_json === nothing
            return json_error("缺少 projectJson（前端画布数据）")
        end

        task_id = string(uuid4())
        sim_end_val = isempty(sim_end) ? nothing : sim_end
        sim_start_date = isempty(sim_start_date_raw) ? nothing : sim_start_date_raw
        sim_end_date = isempty(sim_end_date_raw) ? nothing : sim_end_date_raw
        (sim_start_date === nothing) != (sim_end_date === nothing) &&
            error("仿真起始日期和终止日期必须同时提供")
        if sim_start_date !== nothing
            start_date = Date(sim_start_date, dateformat"yyyy-mm-dd")
            end_date = Date(sim_end_date, dateformat"yyyy-mm-dd")
            end_date < start_date && error("仿真终止日期不能早于起始日期")
        end
        name_val = isempty(name) ? nothing : name
        flexibility_config = normalize_flexibility_evaluation_config(
            get(body, "flexibility", nothing);
            default_layer_id=layer_id,
        )
        flexibility_extra = flexibility_config === nothing ?
            StringAnyDict("enabled" => false) :
            flexibility_evaluation_config_dict(flexibility_config)
        extra_json = JSON3.write(StringAnyDict("flexibility" => flexibility_extra))

        # 存储 project.json 到任务目录（parse 阶段读取）
        task_dir = joinpath(TASKS_DATA_ROOT, task_id)
        mkpath(task_dir)
        write(joinpath(task_dir, "project.json"), JSON3.write(project_json))

        insert_task!(
            id              = task_id,
            project_id      = project_id,
            canvas_id       = canvas_id,
            layer_id        = layer_id,
            mode            = mode,
            name            = name_val,
            sim_start_time  = sim_start,
            sim_end_time    = sim_end_val,
            sim_start_date  = sim_start_date,
            sim_end_date    = sim_end_date,
            params_hash     = params_hash,
            extra_json      = extra_json,
        )

        task = get_task(task_id)
        if task === nothing
            return json_error("创建任务后查不到")
        end

        # 将前端传递的仿真模式参数添加到 task 字典
        task["sim_mode"] = get(body, "simMode", "multi_layer")
        task["target_layer_id"] = get(body, "targetLayerId", layer_id)

        spawn_task(task_id, task)
        return json_success(data = task)
    catch e
        return json_error("创建任务异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/list ─────
@get "/api/task/list" function (req)
    try
        q = query_params(req)
        project_id = get(q, "projectId", nothing)
        status     = get(q, "status", nothing)
        tasks = list_tasks(project_id = project_id, status = status)
        return json_success(data = Dict("tasks" => tasks))
    catch e
        return json_error("列任务异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/state ─────
@get "/api/task/{id}/state" function (req, id)
    try
        task = get_task(id)
        task === nothing && return json_error("任务不存在: $id")
        return json_success(data = task)
    catch e
        return json_error("查任务状态异常: $(sprint(showerror, e))")
    end
end

# ───── POST /api/task/{id}/cancel ─────
@post "/api/task/{id}/cancel" function (req, id)
    try
        cancel_simulation!(String(id))
        return json_success(message = "cancel signal sent")
    catch e
        return json_error("取消异常: $(sprint(showerror, e))")
    end
end

# ───── DELETE /api/task/{id}（清理：删任务 DB + tasks.db 记录）──
@delete "/api/task/{id}" function (req, id)
    try
        task_id = String(id)
        ctx = lock(TASK_CONTEXTS_LOCK) do
            get(TASK_CONTEXTS, task_id, nothing)
        end
        if ctx !== nothing
            cancel_simulation!(task_id)
            # 排队任务没有文件句柄；运行任务必须退出后再清理数据库。
            if (ctx.process !== nothing || ctx.launching) && ctx.julia_task !== nothing
                wait(ctx.julia_task)
            end
        end
        task_dir = joinpath(TASKS_DATA_ROOT, task_id)
        close_store(joinpath(task_dir, "timeseries.db"))
        remove_tree_with_retry(task_dir)
        # 磁盘数据确认清除后再删索引；若文件仍被占用，列表记录保留以便用户重试。
        delete_task!(task_id)
        remove_context(task_id)
        return json_success(data = Dict("taskId" => task_id), message = "任务及计算数据已清理")
    catch e
        return json_error("清理异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/connection（拉任务总线→变量映射）──
@get "/api/task/{id}/connection" function (req, id)
    try
        conn_path = joinpath(TASKS_DATA_ROOT, id, "connection.json")
        if !isfile(conn_path)
            return json_success(data = [])
        end
        conn_data = JSON3.read(read(conn_path, String))
        return json_success(data = conn_data)
    catch e
        return json_error("拉连接数据异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/data（拉任务 TS 数据，支持 minTs 增量）──
# probe 字段用于前端卡顿排查：锁等待 / 查询 / 组装 / 序列化耗时与数据规模
# minTs: 时间标签（如 "1080:00"），只返回 ts >= minTs 的点；缺省返回全部
@get "/api/task/{id}/data" function (req, id)
    try
        t_total0 = time()
        q = query_params(req)
        min_minutes = 0
        min_ts_label = ""
        if haskey(q, "minMinutes") && String(q["minMinutes"]) != ""
            min_minutes = parse(Int, String(q["minMinutes"]))
            min_ts_label = minutes_to_time_label(min_minutes)
        elseif haskey(q, "minTs") && String(q["minTs"]) != ""
            min_ts_label = String(q["minTs"])
            min_minutes = time_label_to_minutes(min_ts_label)
        end
        # 增量时跳过边界序列（b_* 全年铺开，minMinutes 几乎滤不掉）
        skip_boundary = haskey(q, "skipBoundary") && String(q["skipBoundary"]) in ("1", "true")

        store_path = joinpath(TASKS_DATA_ROOT, id, "timeseries.db")
        if !isfile(store_path)
            return json_success(data = Dict(
                "rows" => [],
                "probe" => Dict("total_ms" => 0.0, "row_count" => 0, "series_count" => 0),
            ))
        end

        # 性能：只读内存快照，不与求解写路径抢 write_lock / 全表扫
        rows_snap, snap_probe = snapshot_rows(store_path;
            min_minutes=min_minutes, skip_boundary=skip_boundary)
        result = Dict(
            "rows" => rows_snap,
            "probe" => merge(snap_probe, Dict{String,Any}(
                "min_ts" => min_ts_label,
                "q_keys" => join(sort(collect(keys(q))), ","),
            )),
        )

        payload = Dict{String,Any}(
            "rows" => result["rows"],
            "probe" => merge(
                result["probe"],
                Dict{String,Any}(
                    "total_ms" => (time() - t_total0) * 1000,
                    "task_id" => id,
                ),
            ),
        )
        p = payload["probe"]
        known = Float64(get(p, "lock_wait_ms", 0.0)) + Float64(get(p, "meta_ms", 0.0)) +
                Float64(get(p, "query_ms", 0.0)) + Float64(get(p, "build_ms", 0.0))
        p["serialize_est_ms"] = max(0.0, Float64(p["total_ms"]) - known)
        wr = ts_probe_snapshot()
        for (k, v) in wr
            p["ts_$(k)"] = v
        end
        return json_success(data = payload)
    catch e
        return json_error("拉数据异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/trace（拉回溯步列表）──
@get "/api/task/{id}/trace" function (req, id)
    try
        store_path = joinpath(TASKS_DATA_ROOT, id, "timeseries.db")
        isfile(store_path) || return json_success(data = Dict("steps" => []))
        steps = get_solve_trace_steps(store_path, id)
        return json_success(data = Dict("steps" => steps))
    catch e
        return json_error("拉回溯步列表异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/trace/{step}（拉某步全部数据）──
@get "/api/task/{id}/trace/{step}" function (req, id, step)
    try
        store_path = joinpath(TASKS_DATA_ROOT, id, "timeseries.db")
        isfile(store_path) || return json_success(data = Dict("rows" => []))
        step_num = parse(Int, String(step))
        data = get_solve_trace_data(store_path, id, step_num)
        # 转为 rows 格式，与 getData 保持一致风格
        rows = Dict{String,Any}[]
        for (data_key, ts) in data
            parsed = parse_ts_label(data_key)
            for i in 1:length(ts.timestamps)
                push!(rows, Dict(
                    "sourceId" => parsed["source_id"],
                    "varName"  => parsed["var_name"],
                    "remark"   => parsed["remark"],
                    "layerId"  => parsed["layer_id"],
                    "ts"       => ts.timestamps[i],
                    "value"    => ts.values[i],
                ))
            end
        end
        return json_success(data = Dict("rows" => rows))
    catch e
        return json_error("拉回溯数据异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/flexibility（拉灵活性逐时段与全时域结果）──
# probe 用于卡顿排查；minTs 可只拉较新的 period，减轻全量 JSON 解析
@get "/api/task/{id}/flexibility" function (req, id)
    try
        t0 = time()
        task = get_task(id)
        task === nothing && return json_error("任务不存在: $id")
        config = flexibility_evaluation_config_from_task(task)
        q = query_params(req)
        requested_layer_id = get(q, "layerId", nothing)
        layer_id = if requested_layer_id === nothing
            config === nothing ? String(task["layer_id"]) : config.layer_id
        else
            String(requested_layer_id)
        end
        store_path = joinpath(TASKS_DATA_ROOT, id, "timeseries.db")
        if !isfile(store_path)
            return json_success(data=Dict(
                "config" => config === nothing ? Dict("enabled" => false) :
                    flexibility_evaluation_config_dict(config),
                "periods" => Dict{String,Any}[],
                "summaries" => Dict{String,Any}[],
                "probe" => Dict("total_ms" => (time() - t0) * 1000),
            ))
        end

        min_minutes = 0
        min_ts_label = ""
        if haskey(q, "minMinutes") && String(q["minMinutes"]) != ""
            min_minutes = parse(Int, String(q["minMinutes"]))
            min_ts_label = minutes_to_time_label(min_minutes)
        elseif haskey(q, "minTs") && String(q["minTs"]) != ""
            min_ts_label = String(q["minTs"])
            min_minutes = time_label_to_minutes(min_ts_label)
        end

        periods, period_probe = read_system_flexibility_period_results(
            store_path;
            layer_id=layer_id,
            min_minutes=min_minutes,
        )
        summaries, summary_probe = read_system_flexibility_summary_results(
            store_path;
            layer_id=layer_id,
        )
        probe = Dict{String,Any}(
            "total_ms" => (time() - t0) * 1000,
            "period_lock_ms" => get(period_probe, "lock_wait_ms", 0.0),
            "period_query_ms" => get(period_probe, "query_ms", 0.0),
            "period_parse_ms" => get(period_probe, "parse_ms", 0.0),
            "period_count" => get(period_probe, "count", 0),
            "summary_count" => get(summary_probe, "count", 0),
            "min_ts" => min_ts_label,
            "min_minutes" => min_minutes,
        )
        return json_success(data=Dict(
            "config" => config === nothing ? Dict("enabled" => false) :
                flexibility_evaluation_config_dict(config),
            "periods" => periods,
            "summaries" => summaries,
            "probe" => probe,
        ))
    catch e
        return json_error("拉灵活性结果异常: $(sprint(showerror, e))")
    end
end

# ───── GET /api/task/{id}/economy（经济性评价）──
@get "/api/task/{id}/economy" function (req, id)
    try
        task = get_task(id)
        task === nothing && return json_error("任务不存在: $id")

        # 允许运行中动态评价：仅排除尚无任务记录的异常态
        status = string(get(task, "status", ""))
        status in ("failed", "cancelled", "interrupted") && get(task, "cur_time", nothing) === nothing &&
            return json_error("任务未产生有效结果，无法计算经济性指标")

        # 读取项目快照
        project_path = joinpath(TASKS_DATA_ROOT, id, "project.json")
        if !isfile(project_path)
            return json_error("项目快照不存在: project.json")
        end
        project_json = JSON3.read(read(project_path, String), Dict)

        result = evaluate_task_economy(
            id, project_json;
            sim_start_time=get(task, "sim_start_time", nothing),
            sim_end_time=get(task, "sim_end_time", nothing),
            task_status=status,
            cur_time=get(task, "cur_time", nothing),
            sim_start_date=get(task, "sim_start_date", nothing),
            sim_end_date=get(task, "sim_end_date", nothing),
        )
        return json_success(data = result)
    catch e
        return json_error("计算经济性指标异常: $(sprint(showerror, e))")
    end
end

# ───── WS /ws/task/{id}（实时双向）──
# Oxygen 的 parse_func_params 会把 ws 当查询参数，导致 KeyError
# 改用通配路由 + 手动匹配 req.target
@websocket "/ws/task/*" function (ws; request)
    m = match(r"^/ws/task/([^/]+)", String(request.target))
    task_id = m === nothing ? "" : String(m.captures[1])
    @debug "[TaskWS] handler entered: task_id=$task_id target=$(request.target)"

    # 任务不存在则关闭连接
    if get_task(task_id) === nothing
        @warn "[TaskWS] task not found: $task_id"
        try HTTP.WebSockets.send(ws, JSON3.write(Dict("type" => "error", "message" => "任务不存在"))) catch end
        return
    end

    # 取/建 ctx（resume 场景下 ctx 已存在，subscribe 拿 channel）
    ctx = lock(TASK_CONTEXTS_LOCK) do
        if haskey(TASK_CONTEXTS, task_id)
            TASK_CONTEXTS[task_id]
        else
            # 任务未运行（completed/failed/cancelled），订阅不到 live 事件
            nothing
        end
    end
    @debug "[TaskWS] ctx lookup: task_id=$task_id has_ctx=$(ctx !== nothing)"

    if ctx === nothing
        # 任务未运行：保持连接，定期推送状态（前端可能在等任务完成）
        # 用 for msg in ws 迭代检测客户端断开，辅助定时轮询
        @debug "[TaskWS] no ctx, entering poll loop: task_id=$task_id"
        last_status = ""
        connected = Ref(true)
        try
            # 启动后台轮询 task 状态
            poll_task = @async try
                while connected[]
                    task = get_task(task_id)
                    if task === nothing
                        try HTTP.WebSockets.send(ws, JSON3.write(Dict("type" => "error", "message" => "任务不存在"))) catch end
                        break
                    end
                    cur_status = task["status"]
                    if cur_status != last_status
                        HTTP.WebSockets.send(ws, JSON3.write(Dict(
                            "type" => "status",
                            "taskId" => task_id,
                            "status" => cur_status
                        )))
                        last_status = cur_status
                    end
                    # 如果任务重新开始运行（resume），结束轮询
                    if haskey(TASK_CONTEXTS, task_id)
                        break
                    end
                    sleep(1)
                end
            catch error
                @debug "[TaskWS] status polling stopped" task_id exception=error
            end
            # 前台：等待客户端消息（保持连接存活），收到任何消息忽略
            for msg in ws
                @debug "[TaskWS] poll-mode received client msg (ignored): $msg"
            end
        catch e
            @debug "[TaskWS] poll loop ended: task_id=$task_id err=$(sprint(showerror, e))"
        finally
            connected[] = false
            @isdefined(poll_task) && wait(poll_task)
            @debug "[TaskWS] exiting poll loop: task_id=$task_id"
        end
        return
    end

    ch = subscribe(ctx)
    @debug "[TaskWS] subscribed: task_id=$task_id"
    try
        # 立即推当前状态
        task = get_task(task_id)
        if task !== nothing
            try
                HTTP.WebSockets.send(ws, JSON3.write(Dict(
                    "type" => "status",
                    "taskId" => task_id,
                    "status" => task["status"],
                    "currentTime" => task["cur_time"]
                )))
            catch e
                @warn "[TaskWS] failed to send initial status" exception=(e, catch_backtrace())
            end
        end

        # 后台推：ctx 广播事件 → ws
        forward_task = @async begin
            try
                while true
                    evt = take!(ch)  # 阻塞直到有事件或 channel 关闭
                    HTTP.WebSockets.send(ws, JSON3.write(evt))
                end
            catch e
                if !(e isa InvalidStateException)
                    @warn "[TaskWS] forward error" exception=(e, catch_backtrace())
                end
            end
        end

        # 前台收：用 for msg in ws 迭代（HTTP.jl 推荐模式）
        # 连接关闭时自动结束迭代，不需要手动检查 isopen
        for msg in ws
            try
                data = JSON3.read(String(msg), Dict)
                sig = get(data, "type", "")
                if sig == "cancel"
                    cancel_simulation!(task_id)
                end
            catch e
                @warn "[TaskWS] msg parse error" exception=(e, catch_backtrace())
            end
        end

        @debug "[TaskWS] client disconnected: task_id=$task_id"
    catch e
        @warn "[TaskWS] handler error: task_id=$task_id" exception=(e, catch_backtrace())
    finally
        unsubscribe(ctx, ch)
        @debug "[TaskWS] unsubscribed: task_id=$task_id"
    end
    return
end

# ───── 启动恢复（register 到 server.jl 启动时）──
function init_task_routes!()
    reconcile_running_tasks!()
    @info "Task routes initialized: $(length(TASK_CONTEXTS)) active tasks recovered"
    return nothing
end
