"""Remove legacy meaning 'price' and its fallbacks entirely."""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- types/boundary.ts ----------
p = root / "types" / "boundary.ts"
text = p.read_text(encoding="utf-8")

text = text.replace(
    "  | 'flex_down'      // 下调灵活性\n  | 'price'          // 价格（旧）：已由 buy/sell/fuel_price 替代，仅兼容历史数据\n",
    "  | 'flex_down'      // 下调灵活性\n",
    1,
)
text = text.replace("  flex_down: '下调灵活性',\n  price: '价格（旧）'\n}", "  flex_down: '下调灵活性'\n}", 1)
text = text.replace("  flex_down: 'kW',\n  price: '元/kWh'\n}", "  flex_down: 'kW'\n}", 1)
text = text.replace(
    """  if (
    meaning === 'buy_price' ||
    meaning === 'sell_price' ||
    meaning === 'fuel_price' ||
    meaning === 'price' ||
    /购电|售电|燃料|价格|电价|price/i.test(name)
  ) return 'price'""",
    """  if (
    meaning === 'buy_price' ||
    meaning === 'sell_price' ||
    meaning === 'fuel_price' ||
    /购电|售电|燃料|价格|电价|price/i.test(name)
  ) return 'price'""",
    1,
)
assert "'price'" not in text.split("export type BoundaryMeaning")[1].split("export const")[0], "price still in type"
assert "价格（旧）" not in text
p.write_text(text, encoding="utf-8")
print("types/boundary.ts OK")

# ---------- backend labels ----------
p = root / "backend" / "services" / "boundary_service.jl"
text = p.read_text(encoding="utf-8")
text = text.replace('    "price" => "价格（旧）",\n', "")
text = text.replace('    "price" => "价格",\n', "")
assert '"price"' not in text.split("BOUNDARY_MEANING_LABELS")[1].split(")")[0]
p.write_text(text, encoding="utf-8")
print("boundary_service.jl OK")

# ---------- prediction_utils.jl: drop legacy price ----------
p = root / "backend" / "utils" / "prediction_utils.jl"
text = p.read_text(encoding="utf-8")

old_helper = '''"""是否为价格类边界含义（含旧 price）。"""
function _is_price_meaning(var_name::AbstractString, label::AbstractString="")
    name = lowercase(String(var_name))
    name in ("price", "buy_price", "sell_price", "fuel_price") && return true
    occursin("price", name) && return true
    occursin("价", label) && return true
    return false
end'''
new_helper = '''"""是否为价格类边界含义。"""
function _is_price_meaning(var_name::AbstractString, label::AbstractString="")
    name = lowercase(String(var_name))
    name in ("buy_price", "sell_price", "fuel_price") && return true
    occursin("price", name) && return true
    occursin("价", label) && return true
    return false
end'''
assert old_helper in text
text = text.replace(old_helper, new_helper, 1)

# replace _resolve_price_series_by_meaning body without legacy
start = text.find("function _resolve_price_series_by_meaning(")
assert start > 0
end = text.find("\nend\n", start)
assert end > 0
end += len("\nend\n")
new_fn = '''function _resolve_price_series_by_meaning(
    component::AbstractComponent,
    ctx::BuildContext;
    meaning::String,
    algorithm_key::String="pricePrediction",
)
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    generic = nothing
    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        _is_price_meaning(var_name, label) || continue
        series = Float64.(data)
        var_name == meaning && return series
        if generic === nothing
            generic = series
        end
    end
    return generic
end
'''
text = text[:start] + new_fn + text[end:]

# fuel / grid resolvers: remove legacy multi-slot path
text = text.replace(
    '''    series = _resolve_price_series_by_meaning(component, ctx; meaning="fuel_price")
    series === nothing && return fill(fallback * dt, n)
    return scale_price_series(series, dt, n)''',
    '''    series = _resolve_price_series_by_meaning(component, ctx; meaning="fuel_price")
    series === nothing && return fill(fallback * dt, n)
    return scale_price_series(series, dt, n)''',
)

old_grid = '''    buy_series = _resolve_price_series_by_meaning(component, ctx; meaning="buy_price")
    sell_series = _resolve_price_series_by_meaning(component, ctx; meaning="sell_price")
    # 旧 price 边界：第一条仅购电、第二条仅售电（与历史行为一致）
    if buy_series === nothing && sell_series === nothing
        legacy = resolve_price_series_multi(component, ctx; n=2)
        buy_series = legacy[1]
        sell_series = legacy[2]
    end
    buy = buy_series === nothing ? fill(buy_fb, n) : scale_price_series(buy_series, dt, n)
    sell = sell_series === nothing ? fill(sell_fb, n) : scale_price_series(sell_series, dt, n)
    return buy, sell'''
new_grid = '''    buy_series = _resolve_price_series_by_meaning(component, ctx; meaning="buy_price")
    sell_series = _resolve_price_series_by_meaning(component, ctx; meaning="sell_price")
    buy = buy_series === nothing ? fill(buy_fb, n) : scale_price_series(buy_series, dt, n)
    sell = sell_series === nothing ? fill(sell_fb, n) : scale_price_series(sell_series, dt, n)
    return buy, sell'''
assert old_grid in text, "grid legacy block not found"
text = text.replace(old_grid, new_grid, 1)

# docstring cleanup
text = text.replace(
    "优先 fuel_price 边界分时曲线；其次旧 price 边界；否则用组件标量 fuel_price 兜底。",
    "优先 fuel_price 边界分时曲线；否则用组件标量 fuel_price 兜底。",
)
text = text.replace(
    """- buy_price 边界 → 购电价；缺失则用组件 buy_price 标量
- sell_price 边界 → 售电价；缺失则用组件 sell_price 标量
- 旧 price 边界兼容：第 1 条→购电、第 2 条→售电""",
    """- buy_price 边界 → 购电价；缺失则用组件 buy_price 标量
- sell_price 边界 → 售电价；缺失则用组件 sell_price 标量""",
)

# resolve_price_series_multi may still mention price order; simplify if present
text = text.replace(
    'if var_name == "price" || occursin("price", lowercase(var_name)) || occursin("价", label)',
    'if _is_price_meaning(var_name, label)',
)

p.write_text(text, encoding="utf-8")
print("prediction_utils.jl OK")

# ---------- economy_evaluation_service.jl: drop "price" exact-match ----------
p = root / "backend" / "services" / "economy_evaluation_service.jl"
text = p.read_text(encoding="utf-8")
text = text.replace(
    'parsed != "price" && parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed))',
    'parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed))',
)
text = text.replace(
    'if parsed != "price" && parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed)) && !occursin("价", string(label))',
    'if parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" && !occursin("price", lowercase(parsed)) && !occursin("价", string(label))',
)
# also the check that compares parsed != "price" alone
text = text.replace('parsed != "price" &&', 'parsed != "buy_price" && parsed != "sell_price" && parsed != "fuel_price" &&')
p.write_text(text, encoding="utf-8")
print("economy_evaluation_service.jl OK")
