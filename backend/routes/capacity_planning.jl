# 容量规划变量表单与配置校验路由。
# 规划任务、聚类和优化执行会在后续阶段沿用这里的服务端 schema 契约。

@post "/api/capacity-planning/form-schema" function (req)
    try
        body = JSON3.read(req.body, Dict)
        canvas_id = require_string(body, "canvasId")
        project_json = get(body, "projectJson", nothing)
        project_json isa AbstractDict || return json_error("缺少 projectJson（项目快照）")

        data = detect_capacity_variables(project_json, canvas_id)
        return json_success(data = data)
    catch e
        return json_error("生成容量变量表单异常: $(sprint(showerror, e))")
    end
end

@post "/api/capacity-planning/validate" function (req)
    try
        body = JSON3.read(req.body, Dict)
        canvas_id = require_string(body, "canvasId")
        project_json = get(body, "projectJson", nothing)
        project_json isa AbstractDict || return json_error("缺少 projectJson（项目快照）")
        variables = get(body, "variables", nothing)
        variables isa AbstractVector || return json_error("variables 必须是数组")

        normalized = validate_capacity_variables(project_json, canvas_id, variables)
        return json_success(data = Dict(
            "canvasId" => canvas_id,
            "projectUpdatedAt" => string(get(project_json, "updateTime", "")),
            "variables" => normalized,
        ))
    catch e
        return json_error("容量变量配置校验失败: $(sprint(showerror, e))")
    end
end

@post "/api/capacity-planning/scenarios/preview" function (req)
    try
        body = JSON3.read(req.body, Dict)
        canvas_id = require_string(body, "canvasId")
        project_json = get(body, "projectJson", nothing)
        project_json isa AbstractDict || return json_error("缺少 projectJson（项目快照）")
        data = reduce_boundary_scenarios(body, canvas_id, project_json)
        return json_success(data = data)
    catch e
        @error "典型场景聚类失败" exception=(e, catch_backtrace())
        return json_error("典型场景聚类失败: $(sprint(showerror, e))")
    end
end

# ───── 规划任务 ─────

@post "/api/capacity-planning" function (req)
    try
        task = create_capacity_planning!(JSON3.read(req.body, Dict))
        return json_success(data = task)
    catch e
        return json_error("创建容量规划任务失败: $(sprint(showerror, e))")
    end
end

@get "/api/capacity-planning" function (req)
    try
        params = request_query_params(req)
        project_id_raw = get(params, "projectId", nothing)
        project_id = project_id_raw === nothing ? nothing : String(project_id_raw)
        tasks = list_planning_tasks(project_id=project_id)
        return json_success(data = Dict("tasks" => tasks))
    catch e
        return json_error("查询容量规划任务失败: $(sprint(showerror, e))")
    end
end

@post "/api/capacity-planning/{id}/start" function (req, id)
    try
        task = start_capacity_planning!(String(id))
        return json_success(data = task)
    catch e
        return json_error("启动容量规划任务失败: $(sprint(showerror, e))")
    end
end

@post "/api/capacity-planning/{id}/cancel" function (req, id)
    try
        task = cancel_capacity_planning!(String(id))
        return json_success(data = task)
    catch e
        return json_error("取消容量规划任务失败: $(sprint(showerror, e))")
    end
end

@get "/api/capacity-planning/{id}/result" function (req, id)
    try
        task = get_planning_task(String(id))
        task === nothing && return json_error("容量规划任务不存在: $(id)")
        result = get_planning_result(String(id))
        result === nothing && return json_error("容量规划结果尚未生成")
        return json_success(data = result)
    catch e
        return json_error("查询容量规划结果失败: $(sprint(showerror, e))")
    end
end

@get "/api/capacity-planning/{id}/scenarios" function (req, id)
    try
        planning_id = String(id)
        task = get_planning_task(planning_id)
        task === nothing && return json_error("容量规划任务不存在: $(planning_id)")
        scenario_path = joinpath(planning_task_dir(planning_id), "scenarios.json")
        isfile(scenario_path) || return json_error("典型场景结果尚未生成")
        scenario_set = JSON3.read(read(scenario_path, String), Dict{String,Any})
        return json_success(data = scenario_set)
    catch e
        return json_error("查询典型场景结果失败: $(sprint(showerror, e))")
    end
end

@get "/api/capacity-planning/{id}/comparison" function (req, id)
    try
        return json_success(data = build_planning_comparison(String(id)))
    catch error
        return json_error("生成方案比较失败: $(sprint(showerror, error))")
    end
end

@get "/api/capacity-planning/{id}" function (req, id)
    try
        task = get_planning_task(String(id))
        task === nothing && return json_error("容量规划任务不存在: $(id)")
        return json_success(data = task)
    catch e
        return json_error("查询容量规划任务失败: $(sprint(showerror, e))")
    end
end

@delete "/api/capacity-planning/{id}" function (req, id)
    try
        planning_id = String(id)
        task = get_planning_task(planning_id)
        task === nothing && error("规划任务不存在: $(planning_id)")
        task["status"] in PLANNING_DELETABLE_STATUSES ||
            error("只能清理草稿、已完成、失败或已取消的规划任务")
        # 终态刚发布时 supervisor 可能仍在关闭日志/进程句柄，等待其完整退出后再删目录。
        ctx = lock(PLANNING_CONTEXTS_LOCK) do
            get(PLANNING_CONTEXTS, planning_id, nothing)
        end
        ctx !== nothing && ctx.julia_task !== nothing && wait(ctx.julia_task)
        delete_planning_record!(planning_id)
        return json_success(
            data = Dict("planningId" => planning_id),
            message = "容量规划任务及计算数据已清理",
        )
    catch e
        return json_error("清理容量规划任务失败: $(sprint(showerror, e))")
    end
end

@put "/api/capacity-planning/{id}/config" function (req, id)
    try
        planning_id = String(id)
        task = get_planning_task(planning_id)
        task === nothing && return json_error("容量规划任务不存在: $(planning_id)")
        task["status"] == "draft" || return json_error("只能修改草稿状态的任务配置")

        body = JSON3.read(req.body, Dict)
        config = get(task, "config", Dict{String,Any}())
        new_config = Dict{String,Any}(string(key) => value for (key, value) in config)

        # 更新聚类配置
        if haskey(body, "clustering")
            clustering = get(body, "clustering", nothing)
            if clustering isa AbstractDict
                new_config["clustering"] = _normalize_clustering_config(clustering, task["projectId"], task["canvasId"])
            end
        end

        # 更新变量配置
        if haskey(body, "variables")
            variables = get(body, "variables", nothing)
            if variables isa AbstractVector
                new_config["variables"] = validate_capacity_variables(
                    JSON3.read(read(joinpath(planning_task_dir(planning_id), "project_snapshot.json"), String), Dict{String,Any}),
                    task["canvasId"],
                    variables
                )
            end
        end


        # 更新方案目标、技术性约束和经济性约束
        if haskey(body, "economics")
            new_config["economics"] = _normalize_economics_config(get(body, "economics", Dict{String,Any}()))
        end

        update_planning_config!(planning_id, new_config)
        return json_success(data = get_planning_task(planning_id))
    catch e
        return json_error("更新任务配置失败: $(sprint(showerror, e))")
    end
end
