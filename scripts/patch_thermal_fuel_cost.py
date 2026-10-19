# -*- coding: utf-8 -*-
"""为 CP/GP/CHP 的 model-base.jl 与 model.jl 注入燃料成本目标项。"""
from pathlib import Path
import re

THERMAL = {
    "coal_power": {
        "prefix": "cp",
        "fuel_var_base": "F_CP",
        "var_label": "F_CP",
    },
    "gas_power": {
        "prefix": "gp",
        "fuel_var_base": "F_GP",
        "var_label": "F_GP",
    },
    "combined_heat_power": {
        "prefix": "chp",
        "fuel_var_base": "F_CHP",
        "var_label": "F_CHP",
    },
}

BASE_HELPER = '''
function define_{p}_fuel_cost!(model, time_index, fuel_power, fuel_price::AbstractVector)
    return @expression(model, C_{p}_fuel, sum(fuel_power[t] * fuel_price[t] for t in time_index))
end
'''

TRACKED_HELPER = '''
function define_{p}_fuel_cost_tracked!(model, tracer, time_index, fuel_power, params, code::String)
    fuel_price = params.fuel_price
    expr = sum(fuel_power[t] * fuel_price[t] for t in time_index)
    add_tracked_expression!(model, tracer, "C_{p}_fuel_$(code)",
        "@expression(model, C_{p}_fuel_$(code), sum({fv}_$(code)[t] * $(format_val(fuel_price)) for t in $(format_val(time_index))))",
        expr; to_objective=true)
    return expr
end
'''

FUEL_CALL_BASE = '''    if params.fuel_objective_on
        objective_expr += define_{p}_fuel_cost!(model, time_index, {fv}, params.fuel_price)
    end
'''

FUEL_CALL_TRACKED = '''    if params.fuel_objective_on
        objective_expr += define_{p}_fuel_cost_tracked!(model, tracer, time_index, {fv}, params, code)
    end
'''


def insert_fuel_calls(text: str, call_block: str):
    """在每个 `objective_expr += define_*_om_cost` 之后插入燃料成本块（若未插入）。"""
    if "params.fuel_objective_on" in text:
        return text, 0
    pattern = re.compile(
        r"(objective_expr \+= define_\w+_om_cost!?\([^\n]+\)\n)"
    )
    def repl(m):
        return m.group(1) + call_block
    new, n = pattern.subn(repl, text)
    return new, n


def patch_base(path: Path, prefix: str, fuel_var: str):
    text = path.read_text(encoding="utf-8")
    if f"define_{prefix}_fuel_cost!" in text:
        print(f"skip base {path}")
        return
    helper = BASE_HELPER.format(p=prefix)
    # 插在 define_*_om_cost! 函数定义之前
    om_def = f"function define_{prefix}_om_cost!"
    idx = text.find(om_def)
    if idx < 0:
        print(f"OM DEF MISS {path}")
        return
    text = text[:idx] + helper + "\n" + text[idx:]
    call = FUEL_CALL_BASE.format(p=prefix, fv=fuel_var)
    text, n = insert_fuel_calls(text, call)
    path.write_text(text, encoding="utf-8")
    print(f"base {path}: inserted helper + {n} calls")


def patch_tracked(path: Path, prefix: str, fuel_var: str):
    text = path.read_text(encoding="utf-8")
    if f"define_{prefix}_fuel_cost_tracked!" in text:
        print(f"skip tracked {path}")
        return
    helper = TRACKED_HELPER.format(p=prefix, fv=fuel_var)
    om_def = f"function define_{prefix}_om_cost_tracked!"
    idx = text.find(om_def)
    if idx < 0:
        print(f"TRACKED OM MISS {path}")
        return
    text = text[:idx] + helper + "\n" + text[idx:]
    call = FUEL_CALL_TRACKED.format(p=prefix, fv=fuel_var)
    # tracked 中两种写法：
    #   objective_expr += define_*_om_cost_tracked!(...)
    #   om = define_*_om_cost_tracked!(...)\n    objective_expr += om
    pattern = re.compile(
        r"(objective_expr \+= define_\w+_om_cost_tracked!\([^\n]+\)\n)"
        r"|(objective_expr \+= om\n)"
    )
    def repl(m):
        if m.group(1):
            return m.group(1) + call
        return m.group(2) + call
    text, n = pattern.subn(repl, text)
    path.write_text(text, encoding="utf-8")
    print(f"tracked {path}: inserted helper + {n} calls")


root = Path("backend/components")
for folder, meta in THERMAL.items():
    base = root / folder / "model-base.jl"
    tracked = root / folder / "model.jl"
    patch_base(base, meta["prefix"], meta["fuel_var_base"])
    patch_tracked(tracked, meta["prefix"], meta["fuel_var_base"])

print("done")
