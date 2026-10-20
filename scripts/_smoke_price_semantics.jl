# 价格语义匹配冒烟（独立逻辑验证，不 include prediction_utils）
const FAKE_DB = Dict{String,Tuple{String,Vector{Float64}}}()

function fake_resolve(source_id::String)
    haskey(FAKE_DB, source_id) || return nothing, ""
    vn, vals = FAKE_DB[source_id]
    return vals, "$(source_id)|$(vn)|planned#1"
end

function fake_parse_var(label::String)
    parts = split(label, "|")
    length(parts) < 2 && return ""
    return split(parts[2], "#")[1]
end

# 与 prediction_utils.resolve_price_series_by_meaning 同构
function match_by_meaning(boundary_ids, meaning; legacy_meaning=nothing)
    for bid in boundary_ids
        data, label = fake_resolve(bid)
        data === nothing && continue
        vn = fake_parse_var(label)
        if vn == meaning || (legacy_meaning !== nothing && vn == legacy_meaning)
            return data
        end
    end
    return nothing
end

# 模拟 resolve_grid_price_vectors 的匹配（电侧）
function resolve_buy_sell(boundary_ids)
    buy = match_by_meaning(boundary_ids, "buy_price")
    sell = match_by_meaning(boundary_ids, "sell_price")
    return buy, sell
end

# 模拟 resolve_grid_price_vectors 的匹配（氢侧）
function resolve_buy_sell_h2(boundary_ids)
    buy = match_by_meaning(boundary_ids, "h2_buy_price")
    sell = match_by_meaning(boundary_ids, "h2_sell_price")
    return buy, sell
end

FAKE_DB["b_sell"] = ("sell_price", [10.0, 11.0, 12.0])
FAKE_DB["b_buy"]  = ("buy_price",  [20.0, 21.0, 22.0])
FAKE_DB["b_fuel"] = ("fuel_price", [5.0, 5.5, 6.0])
FAKE_DB["b_legacy"] = ("price", [7.0, 7.5, 8.0])
FAKE_DB["b_load"] = ("load", [1.0, 2.0, 3.0])
FAKE_DB["b_h2_buy"] = ("h2_buy_price",  [30.0, 31.0, 32.0])
FAKE_DB["b_h2_sell"] = ("h2_sell_price", [25.0, 26.0, 27.0])

# 场景 1：顺序反了（sell 在前），语义匹配必须仍正确
buy, sell = resolve_buy_sell(["b_sell", "b_buy"])
println("scenario1 buy=", buy, " sell=", sell)
@assert buy == [20.0, 21.0, 22.0]
@assert sell == [10.0, 11.0, 12.0]

# 场景 2：只绑 sell → buy 为 nothing（调用方走标量兜底）
buy2, sell2 = resolve_buy_sell(["b_sell"])
println("scenario2 buy=", buy2, " sell=", sell2)
@assert buy2 === nothing
@assert sell2 == [10.0, 11.0, 12.0]

# 场景 3：绑了无关含义（load）→ 都不匹配
buy3, sell3 = resolve_buy_sell(["b_load"])
println("scenario3 buy=", buy3, " sell=", sell3)
@assert buy3 === nothing && sell3 === nothing

# 场景 4：fuel_price 精确匹配
fuel = match_by_meaning(["b_fuel", "b_sell"], "fuel_price")
println("scenario4 fuel=", fuel)
@assert fuel == [5.0, 5.5, 6.0]

# 场景 5：历史 price 兼容（legacy_meaning）
legacy = match_by_meaning(["b_legacy"], "fuel_price"; legacy_meaning="price")
println("scenario5 legacy=", legacy)
@assert legacy == [7.0, 7.5, 8.0]

# 场景 6：fuel_price 不会误匹配 buy_price（旧 occursin('price') 会误匹配）
fuel_wrong = match_by_meaning(["b_buy"], "fuel_price")
println("scenario6 fuel_wrong=", fuel_wrong)
@assert fuel_wrong === nothing

# 场景 7：h2_buy_price / h2_sell_price 独立匹配，不与电侧 buy/sell_price 串
h2_buy, h2_sell = resolve_buy_sell_h2(["b_h2_sell", "b_h2_buy", "b_buy", "b_sell"])
println("scenario7 h2_buy=", h2_buy, " h2_sell=", h2_sell)
@assert h2_buy == [30.0, 31.0, 32.0]
@assert h2_sell == [25.0, 26.0, 27.0]

# 场景 8：电侧 buy/sell 不会误吞 h2 边界
e_buy, e_sell = resolve_buy_sell(["b_h2_buy", "b_h2_sell", "b_buy", "b_sell"])
println("scenario8 e_buy=", e_buy, " e_sell=", e_sell)
@assert e_buy == [20.0, 21.0, 22.0]
@assert e_sell == [10.0, 11.0, 12.0]

println("SEMANTIC_MATCH_OK")
