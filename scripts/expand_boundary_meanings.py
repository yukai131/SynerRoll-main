"""Expand BoundaryMeaning: buy/sell/fuel price + flex up/down; keep legacy price."""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ---------- types/boundary.ts ----------
p = root / "types" / "boundary.ts"
text = p.read_text(encoding="utf-8")

text, n = re.subn(
    r"export type BoundaryMeaning =[\s\S]*?\| 'load'[^\n]*\n",
    """export type BoundaryMeaning =
  | 'wind_speed'     // 风速
  | 'irradiance'     // 辐照度
  | 'temperature'    // 温度
  | 'factor'         // 转化因子
  | 'power'          // 输出功率
  | 'load'           // 负荷
  | 'buy_price'      // 购电价格
  | 'sell_price'     // 售电价格
  | 'fuel_price'     // 燃料价格
  | 'flex_up'        // 上调灵活性
  | 'flex_down'      // 下调灵活性
  | 'price'          // 价格（旧）：已由 buy/sell/fuel_price 替代，仅兼容历史数据
""",
    text,
    count=1,
)
assert n == 1, f"meaning type replace failed: {n}"

text, n = re.subn(
    r"export const BOUNDARY_MEANING_LABELS: Record<BoundaryMeaning, string> = \{[\s\S]*?\n\}",
    """export const BOUNDARY_MEANING_LABELS: Record<BoundaryMeaning, string> = {
  wind_speed: '风速',
  irradiance: '辐照度',
  temperature: '温度',
  factor: '转化因子',
  power: '输出功率',
  load: '负荷',
  buy_price: '购电价格',
  sell_price: '售电价格',
  fuel_price: '燃料价格',
  flex_up: '上调灵活性',
  flex_down: '下调灵活性',
  price: '价格（旧）'
}""",
    text,
    count=1,
)
assert n == 1, f"labels replace failed: {n}"

text, n = re.subn(
    r"export const BOUNDARY_MODULE_MEANINGS: Record<BoundaryModuleKey, BoundaryMeaning\[\]> = \{[\s\S]*?\n\}",
    """export const BOUNDARY_MODULE_MEANINGS: Record<BoundaryModuleKey, BoundaryMeaning[]> = {
  'device-fitting': ['factor'],
  weather: ['wind_speed', 'irradiance', 'temperature', 'factor', 'power'],
  load: ['load'],
  price: ['buy_price', 'sell_price', 'fuel_price'],
  agc: ['power', 'flex_up', 'flex_down']
}""",
    text,
    count=1,
)
assert n == 1, f"module meanings replace failed: {n}"

text, n = re.subn(
    r"export const BOUNDARY_MEANING_UNITS: Record<BoundaryMeaning, string> = \{[\s\S]*?\n\}",
    """export const BOUNDARY_MEANING_UNITS: Record<BoundaryMeaning, string> = {
  wind_speed: 'm/s',
  irradiance: 'W/m²',
  temperature: '℃',
  factor: '',
  power: 'kW',
  load: 'kW',
  buy_price: '元/kWh',
  sell_price: '元/kWh',
  fuel_price: '元/kWh',
  flex_up: 'kW',
  flex_down: 'kW',
  price: '元/kWh'
}""",
    text,
    count=1,
)
assert n == 1, f"units replace failed: {n}"

text, n = re.subn(
    r"  if \(meaning === 'price' \|\| /价格\|电价\|price/i\.test\(name\)\) return 'price'",
    """  if (
    meaning === 'buy_price' ||
    meaning === 'sell_price' ||
    meaning === 'fuel_price' ||
    meaning === 'price' ||
    /购电|售电|燃料|价格|电价|price/i.test(name)
  ) return 'price'
  if (meaning === 'flex_up' || meaning === 'flex_down' || /上调|下调|灵活性/i.test(name)) return 'agc'""",
    text,
    count=1,
)
assert n == 1, f"resolve module replace failed: {n}"

p.write_text(text, encoding="utf-8")
print("types/boundary.ts OK")

# ---------- backend labels ----------
p = root / "backend" / "services" / "boundary_service.jl"
text = p.read_text(encoding="utf-8")
text, n = re.subn(
    r'const BOUNDARY_MEANING_LABELS = Dict\([\s\S]*?\n\)',
    '''const BOUNDARY_MEANING_LABELS = Dict(
    "wind_speed" => "风速",
    "irradiance" => "辐照度",
    "temperature" => "温度",
    "factor" => "转化因子",
    "power" => "输出功率",
    "load" => "负荷",
    "buy_price" => "购电价格",
    "sell_price" => "售电价格",
    "fuel_price" => "燃料价格",
    "flex_up" => "上调灵活性",
    "flex_down" => "下调灵活性",
    "price" => "价格（旧）",
)''',
    text,
    count=1,
)
assert n == 1, f"backend labels replace failed: {n}"
p.write_text(text, encoding="utf-8")
print("boundary_service.jl labels OK")

# ---------- component-library.json ----------
p = root / "config" / "component-library.json"
text = p.read_text(encoding="utf-8")
# CP/GP/CHP: "boundaryKey": ["price"] near fuel_price → fuel_price
# Do precise replacements by unique surrounding context
replacements = [
    # CP, GP, CHP share the pattern; replace all remaining ["price"] that are boundaryKey
]
# Replace each boundaryKey:["price"] occurrence carefully with a counter for GRID last
count_price = text.count('"boundaryKey": [\n        "price"\n      ]')
print("boundaryKey price blocks:", count_price)
# There are 4: CP, GP, CHP, GRID. First 3 → fuel_price, last (GRID) → buy/sell
parts = text.split('"boundaryKey": [\n        "price"\n      ]')
assert len(parts) == 5, f"expected 4 blocks, got {len(parts)-1}"
text = (
    parts[0]
    + '"boundaryKey": [\n        "fuel_price"\n      ]'
    + parts[1]
    + '"boundaryKey": [\n        "fuel_price"\n      ]'
    + parts[2]
    + '"boundaryKey": [\n        "fuel_price"\n      ]'
    + parts[3]
    + '"boundaryKey": [\n        "buy_price",\n        "sell_price"\n      ]'
    + parts[4]
)
p.write_text(text, encoding="utf-8")
print("component-library.json OK")
