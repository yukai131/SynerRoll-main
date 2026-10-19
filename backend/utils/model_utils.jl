const BIG_M = 1e10
const DEFAULT_SOLVER = "HiGHS"
const SUPPORTED_SOLVERS = ("HiGHS", "COPT", "SCIP")

function get_solver_name(algorithms::Dict{String,Any})
    raw_name = strip(string(get(algorithms, "solver", DEFAULT_SOLVER)))
    solver_name = lowercase(raw_name) == "highs" ? "HiGHS" : uppercase(raw_name)
    solver_name in SUPPORTED_SOLVERS || error(
        "Unsupported solver $(raw_name). Supported solvers: $(join(SUPPORTED_SOLVERS, ", ")).",
    )
    return solver_name
end

function solver_optimizer(solver_name::String)
    solver_name == "HiGHS" && return HiGHS.Optimizer
    solver_name == "COPT" && return COPT.Optimizer
    solver_name == "SCIP" && return _scip_optimizer()
    error("Unsupported solver $(solver_name).")
end

function _scip_optimizer()
    if isdefined(Main, :SCIP)
        return Main.SCIP.Optimizer
    end
    try
        @eval using SCIP
        return SCIP.Optimizer
    catch e
        error("SCIP solver is not available. Install with Pkg.add(\"SCIP\") and ensure artifacts downloaded. $(sprint(showerror, e))")
    end
end

function generate_timespan(layer::Dict{String, Any})
    span_value = Int(time_str_divide(layer["length"], layer["step"]))
    return 1:span_value
end

step_hours(layer::Dict{String, Any}) = time_str_divide(layer["step"], "1h")

function create_jump_model(algorithms::Dict{String, Any}; optimizer_factory=nothing)
    model = if optimizer_factory === nothing
        Model(solver_optimizer(get_solver_name(algorithms)))
    else
        Model(optimizer_factory)
    end
    set_silent(model)
    return model
end

duplicate_values(values::Vector{Float64}) = vcat(values, values)

function build_result_timestamps(layer::Dict{String, Any}, time::String)
    if layer["id"] == "1"
        return generate_timestamps(time, layer["step"], time_str_multiply(layer["length"], 2))
    end

    return generate_timestamps(time, layer["step"], layer["length"])
end

function generate_result_ts(model, timestamps::Vector{String}, var_name::Symbol, layer::Dict{String, Any})
    values = value.(model[var_name]).data
    if layer["id"] == "1"
        return TimeSeries(timestamps, duplicate_values(values))
    end
    return TimeSeries(timestamps, values)
end

function upper_layer_values(ctx::BuildContext, var_name::String, code::String)
    full_var_name = isempty(code) ? var_name : "$(var_name)_$(code)"
    timestamps = generate_timestamps(ctx.time, ctx.layer["step"], ctx.layer["length"])
    # 点查：按 var_name + 上层 layer 定位序列，逐时刻 floor，不整读历史
    vals = get_ts_values_at_meta(ctx.db_path;
        var_name=full_var_name,
        layer_id=get_upper_layer_id(ctx.layer["id"]),
        times=timestamps)
    return vals
end

# 兼容旧签名（model-base.jl 使用）
upper_layer_values(ctx::BuildContext, var_name::String) = upper_layer_values(ctx, var_name, "")

"""
读取当前时层在本次滚动窗口之前一个时间步的已保存结果。

这里必须使用“同一时层 + 精确时间戳”，不能使用 `get_value` 的 floor 回退：
若上一点尚未实际形成，宁可不添加首点衔接约束，也不能误拿更早时刻或其他
时层的值作为滚动初值。
"""
function previous_layer_result_value(
    ctx::BuildContext,
    source_id::String,
    var_prefix::String,
    code::String,
)
    current_minutes = time_label_to_minutes(ctx.time)
    step_minutes = time_str_to_minutes(string(ctx.layer["step"]))
    previous_minutes = current_minutes - step_minutes
    previous_minutes >= 0 || return nothing

    var_name = isempty(code) ? var_prefix : "$(var_prefix)_$(code)"
    previous_timestamp = minutes_to_time_label(previous_minutes)
    # 精确时刻点查（原语义：同一时层 + 精确 ts，不做 floor）
    return query_ts_exact(ctx.db_path;
        source_id=source_id,
        var_name=var_name,
        layer_id=string(ctx.layer["id"]),
        ts=previous_timestamp)
end

"""
查询储能组件上一层的存储值时序数据。
source_id: 组件类型标识（如 "ES", "HS", "PS"）
var_prefix: 变量名前缀（如 "E_ES", "H_HS", "E_PS"）
"""
function current_layer_storage_value(ctx::BuildContext, code::String, source_id::String, var_prefix::String)
    var_name = isempty(code) ? var_prefix : "$(var_prefix)_$(code)"
    db_path = ctx.db_path
    t = ctx.time
    max_lid = ctx.max_layer_id

    # 策略1：精确时刻，跨层取最高层（点查）
    for lid in max_lid:-1:1
        v = query_ts_exact(db_path; source_id=source_id, var_name=var_name, layer_id=string(lid), ts=t)
        if v !== nothing
            return TimeSeries([t], [v])
        end
    end

    # 策略2：floor 回退，从高层往下（点查）
    for lid in max_lid:-1:1
        pair = nothing
        key = _query_unique_data_key(db_path; source_id=source_id, var_name=var_name, layer_id=string(lid))
        key === nothing && continue
        pair = get_ts_floor_pair(db_path, key, t)
        pair === nothing && continue
        ts_label, val = pair
        return TimeSeries([ts_label], [val])
    end

    return nothing
end

current_layer_storage_value(ctx::BuildContext) = current_layer_storage_value(ctx, "", "ES", "E_ES")
current_layer_storage_value(ctx::BuildContext, code::String) = current_layer_storage_value(ctx, code, "ES", "E_ES")
