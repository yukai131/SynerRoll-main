# 预留预测扩展入口；当前产品使用 None，LSTM 后续实现。
function predict(predict_ts::TimeSeries, actual_ts::TimeSeries, planned_ts::TimeSeries, ::Val{:LSTM})
    error("LSTM 预测尚未实现，请在算法配置中使用 None。")
end

function predict(predict_ts, actual_ts, planned_ts, ::Val{algorithm}) where {algorithm}
    error("预测算法 $(algorithm) 尚未实现，请在算法配置中使用 None。")
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

从组件绑定的 fuel_price 边界读取分时燃料价格序列（元/kWh，原始值，未按步长缩放）。
兼容历史 `price` 含义。返回与当前滚动窗口等长的向量；未绑定价格边界时返回 nothing。
"""
function resolve_price_series(component::AbstractComponent, ctx::BuildContext; algorithm_key::String="pricePrediction")
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        if var_name == "fuel_price" || var_name == "price"
            return Float64.(data)
        end
    end
    return nothing
end

"""
    resolve_price_series_by_meaning(component, ctx, meaning; algorithm_key) -> Union{Vector{Float64},Nothing}

按物理含义精确匹配价格边界（var_name == meaning）。
`legacy_meaning` 用于兼容历史 `price` 含义。
"""
function resolve_price_series_by_meaning(
    component::AbstractComponent,
    ctx::BuildContext,
    meaning::String;
    legacy_meaning::Union{String,Nothing}=nothing,
    algorithm_key::String="pricePrediction",
)
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        if var_name == meaning || (legacy_meaning !== nothing && var_name == legacy_meaning)
            return Float64.(data)
        end
    end
    return nothing
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
优先 fuel_price 边界分时曲线（兼容历史 price 含义）；否则用组件标量 fuel_price 兜底。
"""
function resolve_fuel_price_vector(component::AbstractComponent, ctx::BuildContext; fallback_key::String="fuel_price")
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    fallback = Float64(get(component_costs(component), fallback_key, 0.0))
    series = resolve_price_series_by_meaning(component, ctx, "fuel_price"; legacy_meaning="price")
    series === nothing && return fill(fallback * dt, n)
    return scale_price_series(series, dt, n)
end

"""
    resolve_grid_price_vectors(component, ctx; buy_meaning="buy_price", sell_meaning="sell_price")
        -> (buy_price, sell_price)

GRID / HGRID 分时购/售价格向量（元/kW·步；氢侧为 元/kg·步）。

购、售价格曲线**按物理含义严格独立匹配**：
  - meaning=`buy_meaning` 的边界 → 购入价；缺失则用组件 buy_price 标量
  - meaning=`sell_meaning` 的边界 → 售出价；缺失则用组件 sell_price 标量
不存在「一条曲线同时用于购/售」或「按绑定顺序区分」的逻辑。

GRID 用默认 buy_price / sell_price（元/kWh）；
HGRID 传 h2_buy_price / h2_sell_price（元/kg）。
若两条曲线数值相同，请在边界页创建两个价格边界再分别绑定。
"""
function resolve_grid_price_vectors(
    component::AbstractComponent,
    ctx::BuildContext;
    buy_meaning::String="buy_price",
    sell_meaning::String="sell_price",
)
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    costs = component_costs(component)
    buy_fb = Float64(get(costs, "buy_price", 0.0)) * dt
    sell_fb = Float64(get(costs, "sell_price", 0.0)) * dt

    buy_series = resolve_price_series_by_meaning(component, ctx, buy_meaning)
    sell_series = resolve_price_series_by_meaning(component, ctx, sell_meaning)

    buy = buy_series === nothing ? fill(buy_fb, n) : scale_price_series(buy_series, dt, n)
    sell = sell_series === nothing ? fill(sell_fb, n) : scale_price_series(sell_series, dt, n)
    return buy, sell
end
