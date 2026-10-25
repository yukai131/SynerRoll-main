using Oxygen
using JSON3
using HTTP
using Dates
using JuMP
using CSV
using DataFrames
using SHA
using HiGHS
include("utils/optional_copt.jl")

# ─────────────────────────────────────────────────────────────────────────────
# 模块加载
# ─────────────────────────────────────────────────────────────────────────────
begin
    # 解析服务（画布 JSON → component/connection/mapping JSON）
    include("services/parse_service.jl")

    # 核心模块
    include("core/types.jl")
    include("core/component_framework.jl")
    include("core/schema.jl")
    include("core/validation.jl")
    include("core/flexibility.jl")
    include("core/system_flexibility.jl")

    # 容量规划类型和检测模块（不依赖 utils）
    include("services/capacity_planning/types.jl")
    include("services/capacity_planning/budget.jl")
    include("services/capacity_planning/variable_detector.jl")
    include("services/capacity_planning/candidate_snapshot.jl")

    # 工具模块
    include("utils/timestr_utils.jl")
    include("utils/timeseries_utils.jl")
    include("utils/layer_utils.jl")
    include("utils/model_utils.jl")
    include("utils/model_builder_utils.jl")
    include("utils/prediction_utils.jl")
    include("utils/server_utils.jl")
    include("utils/process_utils.jl")
    include("utils/fitting_curve.jl")
    include("services/fitting_service.jl")
    include("utils/perf_probe.jl")
    include("utils/flexibility_utils.jl")
    include("utils/economy_calculator.jl")

    # 容量规划存储和服务模块（依赖 utils 中的 get_store/_query/_exec）


    # 服务模块（需在utils和components之前加载，prediction_utils.jl依赖TimeSeries）
    include("services/boundary_service.jl")

    # 聚类模块（依赖 utils + boundary_service 中的 parse_boundary_data）
    include("services/capacity_planning/scenario_reducer.jl")

    # 组件模块
    include("components/wind_turbine/component.jl")
    include("components/wind_turbine/validation.jl")
    include("components/wind_turbine/model-common.jl")
    include("components/wind_turbine/flexibility.jl")
    include("components/wind_turbine/model.jl")

    include("components/photovoltaic/component.jl")
    include("components/photovoltaic/validation.jl")
    include("components/photovoltaic/model-common.jl")
    include("components/photovoltaic/flexibility.jl")
    include("components/photovoltaic/model.jl")

    include("components/coal_power/component.jl")
    include("components/coal_power/validation.jl")
    include("components/coal_power/model-common.jl")
    include("components/coal_power/flexibility.jl")
    include("components/coal_power/model.jl")

    include("components/gas_power/component.jl")
    include("components/gas_power/validation.jl")
    include("components/gas_power/model-common.jl")
    include("components/gas_power/flexibility.jl")
    include("components/gas_power/model.jl")

    include("components/combined_heat_power/component.jl")
    include("components/combined_heat_power/validation.jl")
    include("components/combined_heat_power/model-common.jl")
    include("components/combined_heat_power/flexibility.jl")
    include("components/combined_heat_power/model.jl")

    include("components/electrolyzer/component.jl")
    include("components/electrolyzer/validation.jl")
    include("components/electrolyzer/model-common.jl")
    include("components/electrolyzer/flexibility.jl")
    include("components/electrolyzer/model.jl")

    include("components/electricity_load/component.jl")
    include("components/electricity_load/validation.jl")
    include("components/electricity_load/model-common.jl")
    include("components/electricity_load/flexibility.jl")
    include("components/electricity_load/model.jl")

    include("components/hydrogen_load/component.jl")
    include("components/hydrogen_load/validation.jl")
    include("components/hydrogen_load/model-common.jl")
    include("components/hydrogen_load/flexibility.jl")
    include("components/hydrogen_load/model.jl")

    include("components/electricity_storage/component.jl")
    include("components/electricity_storage/validation.jl")
    include("components/electricity_storage/model-common.jl")
    include("components/electricity_storage/flexibility.jl")
    include("components/electricity_storage/model.jl")

    include("components/hydrogen_storage/component.jl")
    include("components/hydrogen_storage/validation.jl")
    include("components/hydrogen_storage/model-common.jl")
    include("components/hydrogen_storage/flexibility.jl")
    include("components/hydrogen_storage/model.jl")

    include("components/flywheel_storage/component.jl")
    include("components/flywheel_storage/validation.jl")
    include("components/flywheel_storage/model-common.jl")
    include("components/flywheel_storage/flexibility.jl")
    include("components/flywheel_storage/model.jl")

    include("components/compressed_air_storage/component.jl")
    include("components/compressed_air_storage/validation.jl")
    include("components/compressed_air_storage/model-common.jl")
    include("components/compressed_air_storage/flexibility.jl")
    include("components/compressed_air_storage/model.jl")

    include("components/pumped_storage/component.jl")
    include("components/pumped_storage/validation.jl")
    include("components/pumped_storage/model-common.jl")
    include("components/pumped_storage/flexibility.jl")
    include("components/pumped_storage/model.jl")

    include("components/heat_load/component.jl")
    include("components/heat_load/validation.jl")
    include("components/heat_load/model-common.jl")
    include("components/heat_load/flexibility.jl")
    include("components/heat_load/model.jl")

    include("components/power_grid/component.jl")
    include("components/power_grid/validation.jl")
    include("components/power_grid/model-common.jl")
    include("components/power_grid/flexibility.jl")
    include("components/power_grid/model.jl")

    include("components/hydrogen_grid/component.jl")
    include("components/hydrogen_grid/validation.jl")
    include("components/hydrogen_grid/model-common.jl")
    include("components/hydrogen_grid/flexibility.jl")
    include("components/hydrogen_grid/model.jl")

    include("components/hydro_power/component.jl")
    include("components/hydro_power/validation.jl")
    include("components/hydro_power/model-common.jl")
    include("components/hydro_power/flexibility.jl")
    include("components/hydro_power/model.jl")

    include("services/model_service.jl")

    # 经济性评价服务
    include("services/economy_evaluation_service.jl")

    # 灵活性评价服务
    include("services/flexibility_baseline_adapter.jl")
    include("services/flexibility_supply_service.jl")
    include("services/flexibility_requirement_service.jl")
    include("services/flexibility_margin_service.jl")
    include("services/flexibility_evaluation_service.jl")
    include("services/flexibility_result_service.jl")

    # 容量规划服务（后期加载，依赖 services）
    include("services/capacity_planning/lifecycle_economics.jl")
    include("services/capacity_planning/simulation_evaluator.jl")
    include("services/capacity_planning/economic_evaluator.jl")
    include("services/capacity_planning/comparison_summary.jl")
    include("services/capacity_planning/planning_store.jl")
    include("services/capacity_planning/optimization_runner.jl")
    include("services/capacity_planning/planning_manager.jl")

    # 计算任务模块（计算任务方案：阶段 1-4）
    include("services/task_manager.jl")
    include("services/simulation_runner.jl")
    include("services/simulation_process.jl")
    include("routes/task.jl")
    include("routes/ingest.jl")
    include("routes/capacity_planning.jl")

    const _COMPONENT_LIB_PATH = joinpath(@__DIR__, "..", "config", "component-library.json")
    load_component_library(_COMPONENT_LIB_PATH)
end
# ─────────────────────────────────────────────────────────────────────────────
# 全局常量
# ─────────────────────────────────────────────────────────────────────────────

const PORT = parse(Int, get(ENV, "PORT", "8080"))

# 边界业务下 TS 库的 source_id 字段 = 边界在 projects.json 中的 BoundaryID
# 每条边界拥有独立 source_id，因此即使 meaning 相同也不互覆盖；
# 「哪个节点用了哪个边界」的关联只存于 projects.json。

const CORS_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "*",
    "Access-Control-Allow-Methods" => "POST, GET, OPTIONS"
]

"""CORS 中间件：追加 CORS 头，保留原始 status code"""
function CorsMiddleware(handler)
    return function (req::HTTP.Request)
        response = handler(req)
        for (k, v) in CORS_HEADERS
            HTTP.setheader(response, k => v)
        end
        return response
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 1. 解析服务  POST /api/parse
# 接收前端项目JSON，解析生成: component.json / connection.json / mapping.json
# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════

# 业务错误信息提取：优先 ErrorException.msg（已是中文原因），去掉路由包装前缀
function _user_errmsg(e, fallback::String)
    if e isa ErrorException
        msg = e.msg
        for prefix in ("导入异常: ", "转换异常: ", "边界提交异常: ", "边界加载异常: ", "删除异常: ")
            if startswith(msg, prefix)
                msg = replace(msg, prefix => ""; count=1)
            end
        end
        return isempty(strip(msg)) ? fallback : msg
    end
    return "$(fallback): $(sprint(showerror, e))"
end

# 1.5. 边界导入服务  POST /api/boundary/import
# 接收文件路径、列名等信息，读取CSV文件并返回截断后的数据
# 截断到24h的倍数（最少24h）
# ══════════════════════════════════════════════════════════════════════════════
@post "/api/boundary/import" function (req)
    try
        body = JSON3.read(req.body, Dict)

        file_path = require_string(body, "filePath")
        column_name = require_string(body, "columnName")
        time_step = optional_string(body, "timeStep", "1h")
        calendar_start_date_raw = optional_string(body, "calendarStartDate", DEFAULT_BOUNDARY_START_DATE)
        calendar_start_date = isempty(calendar_start_date_raw) ? DEFAULT_BOUNDARY_START_DATE : calendar_start_date_raw

        col_data, _ = read_csv_column(file_path, column_name)
        raw_values = extract_float_column_checked(col_data; column_name=column_name)

        # 调用预处理函数：截断到24h的倍数
        result = preprocess_boundary_data(
            Vector{Any}(raw_values),
            time_step;
            time_mode="calendar",
            calendar_start_date=calendar_start_date,
        )

        return json_success(data=Dict(
            "values" => result["values"],
            "timestamps" => result["timestamps"],
            "xAxisLabel" => "时间",
            "yAxisLabel" => column_name,
            "pointCount" => result["pointCount"],
            "totalHours" => result["totalHours"],
            "dayCount" => result["dayCount"],
            "timeStep" => result["timeStep"],
            "timeMode" => result["timeMode"],
            "calendarStartDate" => result["calendarStartDate"],
            "calendarEndDate" => result["calendarEndDate"],
        ))
    catch e
        return json_error(_user_errmsg(e, "导入失败"))
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 1.6. 边界转换服务  POST /api/boundary/transform
# 按 filePath 读取本地文件，转换为各层的时间序列后返回
# 不查库也不入库，结果通过 submit 正式写入 TS 库
# 输出长度 = 边界数据全长（按各层 step 重采样），不按 layer.length 截断；
# layer.length 只校验“数据至少够用”，boundaryLength 仅作提示性校验。
# ══════════════════════════════════════════════════════════════════════════════
@post "/api/boundary/transform" function (req)
    try
        body = JSON3.read(req.body, Dict)

        file_path = require_string(body, "filePath")
        column_name = require_string(body, "columnName")
        time_step = optional_string(body, "timeStep", "1h")
        interpolate_type = optional_string(body, "interpolateType", "linear")
        noise_level = Float64(get(body, "noiseLevel", 0.0))
        noise_distribution = optional_string(body, "randomDistribution", "normal")
        layer_config = get(body, "layerConfig", nothing)
        boundary_length = optional_string(body, "boundaryLength", "")
        # 默认非负；温度例外可由 allowNegative 或 meaning=temperature 开启
        allow_negative = let
            if haskey(body, "allowNegative")
                Bool(body["allowNegative"])
            else
                optional_string(body, "meaning", "") == "temperature"
            end
        end

        layer_config === nothing && error("缺少 layerConfig")

        col_data, _ = read_csv_column(file_path, column_name)
        raw_values = extract_float_column_checked(col_data; column_name=column_name)

        layers_array = get(layer_config, "layers", [])
        isempty(layers_array) && error("layerConfig.layers 不能为空")

        # length 仅作时层下限校验；输出长度跟随边界数据全长
        layer_length = get(layers_array[1], "length", nothing)
        layer_length === nothing && error("layers[1] 缺少 length 字段")

        result_layers = []
        for layer_info in sort(layers_array; by=x -> parse(Int, get(x, "id", "1")))
            layer_id = string(get(layer_info, "id", "1"))
            ts = parse_boundary_data(
                raw_values,
                time_step,
                Dict{String,Any}(
                    "length" => layer_length,
                    "step" => layer_info["step"]
                );
                interpolate_type=interpolate_type,
                noise_level=noise_level,
                noise_distribution=noise_distribution,
                boundary_length=isempty(boundary_length) ? nothing : boundary_length,
                allow_negative=allow_negative,
            )

            push!(result_layers, Dict(
                "layerId" => layer_id,
                "layerName" => "时层$(layer_id)：$(layer_length)长度 / $(layer_info["step"])尺度",
                "values" => ts.values,
                "timestamps" => ts.timestamps,
            ))
        end

        return json_success(data=Dict("layers" => result_layers))
    catch e
        return json_error(_user_errmsg(e, "转换失败"))
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 2. 边界提交服务  POST /api/boundary/submit
# 将前端计算好的转换后数据写入 TS 库，同时存储 boundary 元信息
# ══════════════════════════════════════════════════════════════════════════════
@post "/api/boundary/submit" function (req)
    try
        t_submit_start = time()
        body = JSON3.read(req.body, Dict)

        project_id = require_string(body, "projectId")
        db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")

        boundaries = get(body, "boundaries", [])
        @info "[SUBMIT] received boundaries count=$(length(boundaries)) db_path=$db_path"
        isempty(boundaries) && error("缺少 boundaries 数据")

        # 先按 source_id + remark="planned" 清除该边界的所有旧数据，
        # 避免 meaning 变更后 UNIQUE 约束不匹配导致重复行。
        seen_ids = Set{String}()
        for boundary in boundaries
            bid = optional_string(boundary, "boundaryId", "")
            isempty(bid) && continue
            bid in seen_ids && continue
            push!(seen_ids, bid)
            t_del = time()
            delete_ts_by_source_id(db_path=db_path, source_id=bid, remark="planned")
            @info "[SUBMIT] deleted old data" bid elapsed_s=round(time()-t_del, digits=3)
        end

        stored_keys = String[]
        for boundary in boundaries
            layer_id = optional_string(boundary, "layerId", "1")
            boundary_id = optional_string(boundary, "boundaryId", "")
            meaning = get(boundary, "meaning", nothing)
            values = get(boundary, "values", [])
            timestamps = get(boundary, "timestamps", [])

            # 保留 lenient：缺 meaning / boundaryId 的 entry 静默跳过
            meaning === nothing && continue
            isempty(boundary_id) && continue

            ts = TimeSeries(convert(Vector{String}, timestamps), convert(Vector{Float64}, values))
            label = "$(boundary_id)|$(meaning)|planned#$(layer_id)"
            t_set = time()
            set_ts(db_path, label, ts)
            @info "[SUBMIT] set_ts done" label points=length(values) elapsed_s=round(time()-t_set, digits=3)
            push!(stored_keys, label)
        end

        # 存储 boundary 元信息（长度和尺度）
        # 从 boundaries 中提取第一个 boundary 的元信息（所有 layer 共用）
        if !isempty(boundaries)
            first_boundary = boundaries[1]
            bid = optional_string(first_boundary, "boundaryId", "")
            if !isempty(bid)
                boundary_length = optional_string(first_boundary, "boundaryLength", "")
                boundary_step = optional_string(first_boundary, "boundaryStep", "")
                day_count = get(first_boundary, "dayCount", 0)
                point_count = get(first_boundary, "pointCount", 0)
                time_mode = "calendar"
                calendar_start_raw = optional_string(first_boundary, "calendarStartDate", DEFAULT_BOUNDARY_START_DATE)
                calendar_end_raw = optional_string(first_boundary, "calendarEndDate", "")
                calendar_start_date = isempty(calendar_start_raw) ? DEFAULT_BOUNDARY_START_DATE : calendar_start_raw
                calendar_end_date = if isempty(calendar_end_raw)
                    start_date = Date(calendar_start_date, dateformat"yyyy-mm-dd")
                    Dates.format(start_date + Day(max(Int(day_count) - 1, 0)), dateformat"yyyy-mm-dd")
                else
                    calendar_end_raw
                end

                if !isempty(boundary_length) && !isempty(boundary_step)
                    save_boundary_config(
                        db_path,
                        bid,
                        boundary_length,
                        boundary_step,
                        day_count,
                        point_count,
                        time_mode,
                        calendar_start_date,
                        calendar_end_date,
                    )
                    @info "boundary config saved: bid=$bid length=$boundary_length step=$boundary_step"
                end
            end
        end

        @info "[SUBMIT] total done" stored_count=length(stored_keys) total_s=round(time()-t_submit_start, digits=3)

        return json_success(
            data=Dict("storedKeys" => stored_keys),
            message="边界数据提交完成，共 $(length(stored_keys)) 条",
        )
    catch e
        return json_error(_user_errmsg(e, "边界提交失败"))
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 2.1. 边界加载服务  POST /api/boundary/load
# 根据 boundary 元信息从 TS 库加载已存储的转换后数据
# ══════════════════════════════════════════════════════════════════════════════
@post "/api/boundary/load" function (req)
    try
        body = JSON3.read(req.body, Dict)

        project_id = require_string(body, "projectId")
        db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")

        boundaries = get(body, "boundaries", [])
        isempty(boundaries) && error("缺少 boundaries 数据")

        loaded_boundaries = []
        all_found = true

        for boundary in boundaries
            layer_id = optional_string(boundary, "layerId", "1")
            meaning = get(boundary, "meaning", nothing)
            boundary_id = optional_string(boundary, "boundaryId", "")
            config = isempty(boundary_id) ? nothing : get_boundary_config(db_path, boundary_id)

            # 保留 lenient：缺 meaning / boundaryId 的 entry 标 found=false
            if meaning === nothing || isempty(boundary_id)
                push!(loaded_boundaries, Dict(
                    "boundaryId" => boundary_id,
                    "layerId" => layer_id,
                    "found" => false,
                    "config" => config,
                ))
                all_found = false
                continue
            end

            ts, _ = query_ts(db_path;
                source_id=boundary_id,
                var_name=meaning,
                remark="planned",
                layer_id=layer_id
            )

            if ts !== nothing
                push!(loaded_boundaries, Dict(
                    "boundaryId" => boundary_id,
                    "layerId" => layer_id,
                    "found" => true,
                    "values" => ts.values,
                    "timestamps" => ts.timestamps,
                    "config" => config,
                ))
            else
                push!(loaded_boundaries, Dict(
                    "boundaryId" => boundary_id,
                    "layerId" => layer_id,
                    "found" => false,
                    "config" => config,
                ))
                all_found = false
            end
        end

        return json_success(
            data=Dict("allFound" => all_found, "boundaries" => loaded_boundaries),
        )
    catch e
        return json_error(_user_errmsg(e, "边界加载失败"))
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# 2.2. 边界删除服务  POST /api/boundary/delete
# 按 boundaryId（即 TS 库 source_id）删除该边界在 TS 库中的全部层数据
# ══════════════════════════════════════════════════════════════════════════════
@post "/api/boundary/delete" function (req)
    try


        
        body = JSON3.read(req.body, Dict)

        project_id = require_string(body, "projectId")
        db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")
        boundary_id = require_string(body, "boundaryId")

        n = delete_ts_by_source_id(; db_path=db_path, source_id=boundary_id)

        return json_success(
            data=Dict("deletedLayers" => n),
            message="边界数据已删除，共 $(n) 层",
        )
    catch e
        return json_error(_user_errmsg(e, "删除失败"))
    end
end

# 2.2.1 边界入库状态  POST /api/boundary/status
# 返回 boundary.db（time_series_meta, remark='planned') 中已有数据的边界 ID 列表
# 供前端判断「已关联且有数据 / 空数据 / 未关联」
@post "/api/boundary/status" function (req)
    try
        body = JSON3.read(req.body, Dict)
        project_id = require_string(body, "projectId")
        boundary_ids = get_all_boundary_ids(project_id)
        return json_success(data=Dict("boundaryIds" => boundary_ids))
    catch e
        return json_error(_user_errmsg(e, "查询边界状态失败"))
    end
end

# 2.3. 设备参数拟合  POST /api/fitting/fit
# 读取本地 CSV，拟合风机功率曲线或光伏 P(G,T) 关系
@post "/api/fitting/fit" function (req)
    try
        body = JSON3.read(req.body, Dict)
        result = run_fitting(body)
        return json_success(data=result, message="拟合完成")
    catch e
        return json_error("拟合异常: $(sprint(showerror, e))")
    end
end

# # ══════════════════════════════════════════════════════════════════════════════
# # 3. 模型构建服务  POST /api/model/build
# # 构建优化模型(不求解)
# # ══════════════════════════════════════════════════════════════════════════════
# # ══════════════════════════════════════════════════════════════════════════════
# # 4. 模型求解服务  POST /api/model/solve
# # 求解已构建的优化模型，支持滚动
# # ══════════════════════════════════════════════════════════════════════════════
# # ══════════════════════════════════════════════════════════════════════════════
# # 5. 数据可视化服务  POST /api/results
# # 查询优化结果用于可视化
# # ══════════════════════════════════════════════════════════════════════════════
# # ══════════════════════════════════════════════════════════════════════════════
# # 辅助路由
# # ══════════════════════════════════════════════════════════════════════════════
@get "/health" function (req)
    solvers = Dict{String,Any}()
    try
        # 轻量探测：仅确认优化器可构造（COPT 无许可时可能失败）
        m = Model(HiGHS.Optimizer)
        solvers["HiGHS"] = true
    catch e
        solvers["HiGHS"] = false
        solvers["HiGHS_error"] = sprint(showerror, e)
    end
    solvers["COPT"] = COPT_AVAILABLE
    solvers["COPT_license_checked"] = false
    COPT_AVAILABLE || (solvers["COPT_error"] = COPT_LOAD_ERROR[])
    return JSON3.write(Dict(
        "status" => "ok",
        "service" => "synerroll-backend",
        "version" => string(VERSION),
        "port" => PORT,
        "solvers" => solvers,
        "default_solver" => "HiGHS",
        "timestamp" => Dates.now()
    ))
end

# ══════════════════════════════════════════════════════════════════════════════
# 启动服务
# ══════════════════════════════════════════════════════════════════════════════

println("Starting on port $PORT...")

# ───── 启动预热：避免首次点开/建任务时 JIT 卡顿 ─────
function warmup_backend(; strict::Bool=false)
    t0 = time()
    try
        m = Model(HiGHS.Optimizer)
        set_silent(m)
        @variable(m, x >= 0)
        @constraint(m, x <= 1.0)
        @objective(m, Max, x)
        optimize!(m)
        if strict && (termination_status(m) != MOI.OPTIMAL || !isapprox(value(x), 1.0))
            error("HiGHS 安装检查未得到预期最优解。")
        end
    catch e
        @warn "warmup: HiGHS mini-model failed" exception=e
        strict && rethrow()
    end
    try
        tmp = joinpath(mktempdir(), "warmup_timeseries.db")
        store = get_store(tmp)
        set_ts(tmp, "WARMUP|V|power#1", TimeSeries(["0:00"], [1.0]))
        installed_value = get_ts_exact(tmp, "WARMUP|V|power#1", "0:00")
        strict && installed_value != 1.0 && error("SQLite 安装检查读写结果不一致。")
        get_ts_floor(tmp, "WARMUP|V|power#1", "0:00")
        write_timeseries_batch!(tmp, [("WARMUP|V|power#1", TimeSeries(["1:00"], [2.0]))])
        query_ts(tmp; source_id="WARMUP", var_name="V", layer_id="1")
        close_store(tmp)
    catch e
        @warn "warmup: timeseries path failed" exception=e
        strict && rethrow()
    end
    try
        JSON3.write(Dict("ok" => true))
    catch e
        @warn "warmup: JSON3 failed" exception=e
        strict && rethrow()
    end
    @info "warmup_backend done" elapsed_s=round(time()-t0; digits=3)
    return nothing
end

# 容量规划 worker 只跑优化，不启动 HTTP/任务路由，避免与父进程争用 tasks.db
if get(ENV, "SYNERROLL_CAPACITY_WORKER", "") != "1" && get(ENV, "SYNERROLL_SIMULATION_WORKER", "") != "1"
    init_task_routes!()
    init_ingest_routes!()
    get(ENV, "PSFA_SKIP_STARTUP_WARMUP", "") == "1" || warmup_backend()
    serve(host=get(ENV, "SYNERROLL_HOST", "127.0.0.1"), port=PORT, async=false, middleware=[CorsMiddleware])
end
