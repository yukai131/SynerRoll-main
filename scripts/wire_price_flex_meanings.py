"""Wire buy/sell/fuel_price and flex_up/flex_down through prediction + task UI."""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- prediction_utils.jl ----------
p = root / "backend" / "utils" / "prediction_utils.jl"
text = p.read_text(encoding="utf-8")

# helper + rewrite resolve functions
old = text
# Replace resolve_price_series body matching logic
text = text.replace(
    '''        if var_name == "price" || occursin("price", lowercase(var_name)) || occursin("价", label)
            return Float64.(data)
        end
    end
    return nothing
end''',
    '''        if _is_price_meaning(var_name, label)
            return Float64.(data)
        end
    end
    return nothing
end''',
    1,
)

text = text.replace(
    '''        if var_name == "price" || occursin("price", lowercase(var_name)) || occursin("价", label)
            result[slot] = Float64.(data)
            slot += 1
        end
    end
    return result
end''',
    '''        if _is_price_meaning(var_name, label)
            result[slot] = Float64.(data)
            slot += 1
        end
    end
    return result
end''',
    1,
)

# Insert helper before resolve_price_series
helper = '''
"""是否为价格类边界含义（含旧 price）。"""
function _is_price_meaning(var_name::AbstractString, label::AbstractString="")
    name = lowercase(String(var_name))
    name in ("price", "buy_price", "sell_price", "fuel_price") && return true
    occursin("price", name) && return true
    occursin("价", label) && return true
    return false
end

"""按精确含义取价格曲线：优先 meaning，找不到再退回通用价格类。"""
function _resolve_price_series_by_meaning(
    component::AbstractComponent,
    ctx::BuildContext;
    meaning::String,
    algorithm_key::String="pricePrediction",
)
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && return nothing

    fallback = nothing
    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(ctx; source_id=boundary_id, algorithm_key=algorithm_key)
        var_name = parse_ts_label(label)["var_name"]
        _is_price_meaning(var_name, label) || continue
        if var_name == meaning
            return Float64.(data)
        end
        # 旧 price 边界：购电取第一条，售电取第二条，燃料沿用通用解析
        if var_name == "price" || fallback === nothing
            fallback = Float64.(data)
            if meaning == "buy_price"
                return fallback
            end
        elseif meaning == "sell_price"
            return Float64.(data)
        end
    end
    return fallback
end

'''

marker = '"""\n    resolve_price_series(component, ctx; algorithm_key="pricePrediction")'
idx = text.find(marker)
assert idx > 0, "resolve_price_series docstring not found"
text = text[:idx] + helper + text[idx:]

# Rewrite resolve_fuel_price_vector to prefer fuel_price
text, n = re.subn(
    r'function resolve_fuel_price_vector\(component::AbstractComponent, ctx::BuildContext; fallback_key::String="fuel_price"\)\n    n = length\(generate_timespan\(ctx\.layer\)\)\n    dt = step_hours\(ctx\.layer\)\n    fallback = Float64\(get\(component_costs\(component\), fallback_key, 0\.0\)\)\n    series = resolve_price_series\(component, ctx\)\n    series === nothing && return fill\(fallback \* dt, n\)\n    return scale_price_series\(series, dt, n\)\nend',
    '''function resolve_fuel_price_vector(component::AbstractComponent, ctx::BuildContext; fallback_key::String="fuel_price")
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    fallback = Float64(get(component_costs(component), fallback_key, 0.0))
    series = _resolve_price_series_by_meaning(component, ctx; meaning="fuel_price")
    series === nothing && return fill(fallback * dt, n)
    return scale_price_series(series, dt, n)
end''',
    text,
    count=1,
)
assert n == 1, f"fuel_price resolve replace failed: {n}"

# Rewrite resolve_grid_price_vectors
text, n = re.subn(
    r'function resolve_grid_price_vectors\(component::AbstractComponent, ctx::BuildContext\)\n    n = length\(generate_timespan\(ctx\.layer\)\)\n    dt = step_hours\(ctx\.layer\)\n    costs = component_costs\(component\)\n    buy_fb = Float64\(get\(costs, "buy_price", 0\.0\)\) \* dt\n    sell_fb = Float64\(get\(costs, "sell_price", 0\.0\)\) \* dt\n    prices = resolve_price_series_multi\(component, ctx; n=2\)\n    buy = prices\[1\] === nothing \? fill\(buy_fb, n\) : scale_price_series\(prices\[1\], dt, n\)\n    sell = prices\[2\] === nothing \? fill\(sell_fb, n\) : scale_price_series\(prices\[2\], dt, n\)\n    return buy, sell\nend',
    '''function resolve_grid_price_vectors(component::AbstractComponent, ctx::BuildContext)
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    costs = component_costs(component)
    buy_fb = Float64(get(costs, "buy_price", 0.0)) * dt
    sell_fb = Float64(get(costs, "sell_price", 0.0)) * dt
    buy_series = _resolve_price_series_by_meaning(component, ctx; meaning="buy_price")
    sell_series = _resolve_price_series_by_meaning(component, ctx; meaning="sell_price")
    # 旧 price 边界：第一条仅购电、第二条仅售电（与历史行为一致）
    if buy_series === nothing && sell_series === nothing
        legacy = resolve_price_series_multi(component, ctx; n=2)
        buy_series = legacy[1]
        sell_series = legacy[2]
    end
    buy = buy_series === nothing ? fill(buy_fb, n) : scale_price_series(buy_series, dt, n)
    sell = sell_series === nothing ? fill(sell_fb, n) : scale_price_series(sell_series, dt, n)
    return buy, sell
end''',
    text,
    count=1,
)
assert n == 1, f"grid price resolve replace failed: {n}"

# Update docstrings lightly
text = text.replace(
    "优先 price 边界分时曲线；否则用组件标量 fuel_price 兜底。",
    "优先 fuel_price 边界分时曲线；其次旧 price 边界；否则用组件标量 fuel_price 兜底。",
)
text = text.replace(
    """- 第 1 条 price 边界 → 仅购电价；缺失则用组件 buy_price 标量
- 第 2 条 price 边界 → 仅售电价；缺失则用组件 sell_price 标量
- 只绑定 1 条边界时：该曲线只作用于购电，售电仍用 sell_price""",
    """- buy_price 边界 → 购电价；缺失则用组件 buy_price 标量
- sell_price 边界 → 售电价；缺失则用组件 sell_price 标量
- 旧 price 边界兼容：第 1 条→购电、第 2 条→售电""",
)

p.write_text(text, encoding="utf-8")
print("prediction_utils.jl OK")

# ---------- tasks/index.vue: split boundary candidates by meaning ----------
p = root / "app" / "pages" / "tasks" / "index.vue"
text = p.read_text(encoding="utf-8")
old_block = """const boundarySeriesCandidates = computed(() =>
  (creationProject.value?.boundaries ?? []).filter(boundary =>
    boundary.meaning === 'power' || /计划|AGC|目标|调度/i.test(boundary.name)
  )
)"""
new_block = """const boundarySeriesCandidates = computed(() => {
  const boundaries = creationProject.value?.boundaries ?? []
  const source = newTask.requirementSource
  if (source === 'user_defined') {
    // 自定义需求：上调/下调各用 flex_up / flex_down 曲线
    return boundaries.filter(boundary =>
      boundary.meaning === 'flex_up' ||
      boundary.meaning === 'flex_down' ||
      boundary.meaning === 'price' ||
      /上调|下调|灵活性|需求/i.test(boundary.name)
    )
  }
  // AGC 目标计划：目标并网功率（power）或计划/AGC 命名
  return boundaries.filter(boundary =>
    boundary.meaning === 'power' ||
    boundary.meaning === 'buy_price' ||
    boundary.meaning === 'sell_price' ||
    /计划|AGC|目标|调度/i.test(boundary.name)
  )
})

/** 自定义需求时按方向过滤边界选项 */
const boundarySeriesOptionsFor = (direction: 'target' | 'up' | 'down') => {
  const options = boundarySeriesOptions.value
  if (newTask.requirementSource !== 'user_defined') return options
  const want = direction === 'up' ? 'flex_up' : direction === 'down' ? 'flex_down' : null
  if (!want) return options
  return options.filter(option => {
    const boundary = creationProject.value?.boundaries.find(item => option.value.startsWith(`${item.id}:`))
    return !boundary || boundary.meaning === want || boundary.meaning === 'price'
  })
}"""
if old_block not in text:
    # try with possible whitespace differences
    m = re.search(
        r"const boundarySeriesCandidates = computed\(\(\) =>\n  \(creationProject\.value\?\.boundaries \?\? \[\]\)\.filter\(boundary =>\n    boundary\.meaning === 'power' \|\| /计划\|AGC\|目标\|调度/i\.test\(boundary\.name\)\n  \)\n\)",
        text,
    )
    assert m, "boundarySeriesCandidates block not found"
    text = text[: m.start()] + new_block + text[m.end() :]
else:
    text = text.replace(old_block, new_block, 1)

# Use filtered options in template for up/down/target editors
text = text.replace(
    'v-model="newTask.targetPoiPowerSeries"\n                  :mode="newTask.flexibilityValueMode"\n                  label="目标并网功率"\n                  :boundary-options="boundarySeriesOptions"',
    'v-model="newTask.targetPoiPowerSeries"\n                  :mode="newTask.flexibilityValueMode"\n                  label="目标并网功率"\n                  :boundary-options="boundarySeriesOptionsFor(\'target\')"',
    1,
)
text = text.replace(
    'v-model="newTask.upwardRequirementSeries"\n                    :mode="newTask.flexibilityValueMode"\n                    label="上调需求"\n                    :nonnegative="true"\n                    :boundary-options="boundarySeriesOptions"',
    'v-model="newTask.upwardRequirementSeries"\n                    :mode="newTask.flexibilityValueMode"\n                    label="上调需求"\n                    :nonnegative="true"\n                    :boundary-options="boundarySeriesOptionsFor(\'up\')"',
    1,
)
text = text.replace(
    'v-model="newTask.downwardRequirementSeries"\n                    :mode="newTask.flexibilityValueMode"\n                    label="下调需求"\n                    :nonnegative="true"\n                    :boundary-options="boundarySeriesOptions"',
    'v-model="newTask.downwardRequirementSeries"\n                    :mode="newTask.flexibilityValueMode"\n                    label="下调需求"\n                    :nonnegative="true"\n                    :boundary-options="boundarySeriesOptionsFor(\'down\')"',
    1,
)

p.write_text(text, encoding="utf-8")
print("tasks/index.vue OK")
