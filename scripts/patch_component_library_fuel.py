# -*- coding: utf-8 -*-
"""为组件库补充 fuel_price / fuel_objective_on，并为 GRID 声明 price 边界。"""
import json
from pathlib import Path

path = Path("config/component-library.json")
raw = path.read_text(encoding="utf-8")
data = json.loads(raw)

FUEL_PRICE_FIELD = {
    "key": "fuel_price",
    "label": "燃料价格",
    "type": "number",
    "defaultValue": 0.2,
    "unit": "元/kWh",
    "step": 0.01,
    "min": 0.0,
}

FUEL_OBJECTIVE_FIELD = {
    "key": "fuel_objective_on",
    "label": "启用燃料成本目标",
    "type": "boolean",
    "defaultValue": True,
}

THERMAL = ("CP", "GP", "CHP")

for key in THERMAL:
    comp = data["components"][key]
    econ = comp.setdefault("commonEconomicFields", [])
    if not any(f.get("key") == "fuel_price" for f in econ):
        # 插在 om_cost / on_off_cost 之后、投资类字段之前
        insert_at = 0
        for i, f in enumerate(econ):
            if f.get("key") in ("om_cost", "on_off_cost"):
                insert_at = i + 1
        econ.insert(insert_at, dict(FUEL_PRICE_FIELD))
        print(f"{key}: added fuel_price at {insert_at}")
    else:
        print(f"{key}: fuel_price already present")

    obj = comp.setdefault("objectiveFields", [])
    if not any(f.get("key") == "fuel_objective_on" for f in obj):
        # 挂在 om_objective_on 附近
        insert_at = 0
        for i, f in enumerate(obj):
            if f.get("key") == "om_objective_on":
                insert_at = i + 1
        obj.insert(insert_at, dict(FUEL_OBJECTIVE_FIELD))
        print(f"{key}: added fuel_objective_on at {insert_at}")
    else:
        print(f"{key}: fuel_objective_on already present")

# GRID：声明可绑定价格边界（分时购/售电价）
grid = data["components"]["GRID"]
if "boundaryKey" not in grid:
    # 插在 tags 之后
    # dict 顺序：Python 3.7+ 保持插入序，重建以保证 boundaryKey 在合理位置
    new_grid = {}
    for k, v in grid.items():
        new_grid[k] = v
        if k == "tags":
            new_grid["boundaryKey"] = ["price"]
    if "boundaryKey" not in new_grid:
        new_grid["boundaryKey"] = ["price"]
    data["components"]["GRID"] = new_grid
    print("GRID: added boundaryKey=['price']")
else:
    print("GRID: boundaryKey already", grid["boundaryKey"])

# 说明：GRID 兜底仍用 buy_price / sell_price；不再新增 fuel_price

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("done")
