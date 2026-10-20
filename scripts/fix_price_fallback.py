"""Fix legacy price fallback and expand economy price-meaning checks."""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- prediction_utils.jl ----------
p = root / "backend" / "utils" / "prediction_utils.jl"
text = p.read_text(encoding="utf-8")

old_fn_start = 'function _resolve_price_series_by_meaning('
idx = text.find(old_fn_start)
assert idx > 0
# find matching end of this function: next \nend\n after idx
end_idx = text.find("\nend\n", idx)
assert end_idx > 0
end_idx += len("\nend\n")

new_fn = '''function _resolve_price_series_by_meaning(
    component::AbstractComponent,
    ctx::BuildContext;
    meaning::String,
    algorithm_key::String="pricePrediction",
)
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    legacy_prices = Vector{Vector{Float64}}()
    generic = nothing
    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        _is_price_meaning(var_name, label) || continue
        series = Float64.(data)
        if var_name == meaning
            return series
        end
        if var_name == "price"
            push!(legacy_prices, series)
        elseif generic === nothing
            generic = series
        end
    end

    if meaning == "buy_price"
        isempty(legacy_prices) || return legacy_prices[1]
        return generic
    end
    if meaning == "sell_price"
        # 旧约定：仅 1 条 price 时只作用于购电，售电不用它
        length(legacy_prices) >= 2 && return legacy_prices[2]
        return nothing
    end
    # fuel_price 等：优先第一条旧 price，否则任一价格类
    isempty(legacy_prices) || return legacy_prices[1]
    return generic
end
'''
text = text[:idx] + new_fn + text[end_idx:]
p.write_text(text, encoding="utf-8")
print("prediction_utils.jl fallback fixed")

# ---------- economy_evaluation_service.jl ----------
p = root / "backend" / "services" / "economy_evaluation_service.jl"
text = p.read_text(encoding="utf-8")
text2 = text.replace(
    'parsed != "price" && !occursin("price", lowercase(parsed))',
    'parsed != "price" && parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed))',
)
text2 = text2.replace(
    'if !isempty(label_s) && !(occursin("price", lowercase(label_s)) || occursin("价", label_s))',
    'if !isempty(label_s) && !(occursin("price", lowercase(label_s)) || occursin("价", label_s))',
)
# also accept new meanings in the price-or-价 filter if it checks var == price only
text2 = text2.replace(
    'if parsed != "price" && !occursin("price", lowercase(parsed)) && !occursin("价", string(label))',
    'if parsed != "price" && parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed)) && !occursin("价", string(label))',
)
p.write_text(text2, encoding="utf-8")
print("economy_evaluation_service.jl OK, replacements:", text2 != text)

# ---------- tasks/index.vue: AGC candidates should NOT use buy/sell price ----------
p = root / "app" / "pages" / "tasks" / "index.vue"
text = p.read_text(encoding="utf-8")
text2 = text.replace(
    """  // AGC 目标计划：目标并网功率（power）或计划/AGC 命名
  return boundaries.filter(boundary =>
    boundary.meaning === 'power' ||
    boundary.meaning === 'buy_price' ||
    boundary.meaning === 'sell_price' ||
    /计划|AGC|目标|调度/i.test(boundary.name)
  )""",
    """  // AGC 目标计划：目标并网功率（power）或计划/AGC 命名
  return boundaries.filter(boundary =>
    boundary.meaning === 'power' ||
    /计划|AGC|目标|调度/i.test(boundary.name)
  )""",
    1,
)
assert text2 != text, "AGC filter not updated"
p.write_text(text2, encoding="utf-8")
print("tasks/index.vue AGC filter OK")
