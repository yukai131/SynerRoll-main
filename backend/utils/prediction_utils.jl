function predict(predict_ts::TimeSeries, actual_ts::TimeSeries, planned_ts::TimeSeries, ::Val{:LSTM})
    # TODO: keep the original placeholder until the prediction logic is finalized.
end

function resolve_prediction_series(ctx::BuildContext; source_id::String, algorithm_key::String)
    timestamps = generate_timestamps(ctx.time, ctx.layer["step"], ctx.layer["length"])
    planned_ts, planned_label = query_ts(ctx.db_path; source_id=source_id, remark="planned")
    planned_data = get_values(planned_ts, timestamps)

    algorithm_name = get(ctx.algorithms, algorithm_key, "None")
    if ctx.layer["id"] == "1" || algorithm_name == "None"
        return planned_data, planned_label
    end

    predict_ts, _ = query_ts(ctx.db_path; source_id=source_id, remark="predict")
    actual_ts, _ = query_ts(ctx.db_path; source_id=source_id, remark="actual")
    return predict(predict_ts, actual_ts, planned_ts, Val(Symbol(algorithm_name))), planned_label
end


"""
    resolve_price_series(component, ctx; algorithm_key="pricePrediction") -> Union{Vector{Float64},Nothing}

从组件绑定的 price 边界读取分时价格序列（元/kWh，原始值，未按步长缩放）。
返回与当前滚动窗口等长的向量；未绑定价格边界时返回 nothing。
"""
function resolve_price_series(component::AbstractComponent, ctx::BuildContext; algorithm_key::String="pricePrediction")
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        # 仅接受价格类边界；其他含义继续找
        if var_name == "price" || occursin("price", lowercase(var_name)) || occursin("价", label)
            return Float64.(data)
        end
    end
    return nothing
end

"""
    resolve_price_series_multi(component, ctx; n=2, algorithm_key) -> Vector{Union{Vector{Float64},Nothing}}

解析多条价格边界（例如 GRID 购电价、售电价）。
按 boundaryIds 顺序取前 n 条价格类序列；不足则补 nothing。
购/售各自占一个槽位，互不覆盖、互不复用。
"""
function resolve_price_series_multi(component::AbstractComponent, ctx::BuildContext; n::Int=2, algorithm_key::String="pricePrediction")
    boundary_ids = component_boundary_ids(component)
    result = Vector{Union{Vector{Float64},Nothing}}(nothing, n)
    isempty(boundary_ids) && return result

    slot = 1
    for boundary_id in boundary_ids
        slot > n && break
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        if var_name == "price" || occursin("price", lowercase(var_name)) || occursin("价", label)
            result[slot] = Float64.(data)
            slot += 1
        end
    end
    return result
end

"""
    scale_price_series(prices, time_step_hours, n) -> Vector{Float64}

将原始元/kWh 价格序列缩放为「元/kW·步」系数，并对齐长度 n。
`prices === nothing` 时返回零向量（调用方应改用标量兜底）。
"""
function scale_price_series(prices::Vector{Float64}, time_step_hours::Float64, n::Int)
    out = zeros(Float64, n)
    m = min(n, length(prices))
    for i in 1:m
        out[i] = prices[i] * time_step_hours
    end
    # 短序列用末值填充，保证窗口完整
    if m > 0 && m < n
        for i in (m+1):n
            out[i] = prices[m] * time_step_hours
        end
    end
    return out
end

"""
    resolve_fuel_price_vector(component, ctx; fallback_key="fuel_price") -> Vector{Float64}

燃料价格向量（元/kW·步，已 × time_step_hours），与滚动窗口等长。
优先 price 边界分时曲线；否则用组件标量 fuel_price 兜底。
"""
function resolve_fuel_price_vector(component::AbstractComponent, ctx::BuildContext; fallback_key::String="fuel_price")
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    fallback = Float64(get(component_costs(component), fallback_key, 0.0))
    series = resolve_price_series(component, ctx)
    series === nothing && return fill(fallback * dt, n)
    return scale_price_series(series, dt, n)
end

"""
    resolve_grid_price_vectors(component, ctx) -> (buy_price, sell_price)

GRID 分时购/售电价向量（元/kW·步）。

购电、售电价格曲线**严格独立**，不存在「一条曲线同时用于购/售」的逻辑：
  - 第 1 条 price 边界 → 仅购电价；缺失则用组件 buy_price 标量
  - 第 2 条 price 边界 → 仅售电价；缺失则用组件 sell_price 标量
  - 只绑定 1 条边界时：该曲线只作用于购电，售电仍用 sell_price
若两条曲线数值相同，请在边界页创建两个价格边界（可导入同一数据文件）再分别绑定。
"""
function resolve_grid_price_vectors(component::AbstractComponent, ctx::BuildContext)
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    costs = component_costs(component)
    buy_fb = Float64(get(costs, "buy_price", 0.0)) * dt
    sell_fb = Float64(get(costs, "sell_price", 0.0)) * dt
    prices = resolve_price_series_multi(component, ctx; n=2)
    buy = prices[1] === nothing ? fill(buy_fb, n) : scale_price_series(prices[1], dt, n)
    sell = prices[2] === nothing ? fill(sell_fb, n) : scale_price_series(prices[2], dt, n)
    return buy, sell
end