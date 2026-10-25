# 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?# combined_heat_power/model-common.jl 鈥?鍏变韩鍑芥暟
#
# 参数解析与辅助函数。
# 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
function resolve_chp_params(component::CombinedHeatPower, ctx::BuildContext)
    layer_settings = layer_config(component, ctx.layer["id"])
    time_step_hours = step_hours(ctx.layer)
    paras = component_paras(component)

    capacity = paras["capacity"]
    β = paras["β"]

    return (
        layer_settings=layer_settings,
        status=layer_settings["status"],
        capacity=capacity,
        η_e=paras["η_e"],
        β=β,
        ramp_ratio=ramp_per_min_to_per_hour(paras["ramp"]) * time_step_hours,
        min_output_ratio=paras["min"],
        min_on_steps=Int(round(paras["T_min_on"] / time_step_hours)),
        min_off_steps=Int(round(paras["T_min_off"] / time_step_hours)),
        om_cost=component_costs(component)["om_cost"] * time_step_hours,
        on_off_cost=component_costs(component)["on_off_cost"],  # 元/次，不按步长缩放
        adjust_limit=layer_settings["paras"]["adjust_limit"],
        adjust_cost=layer_settings["costs"]["adjust_cost"] * time_step_hours,
        ramp_constraint_on=layer_settings["constraints"]["ramp_constraint_on"],
        min_constraint_on=layer_settings["constraints"]["min_constraint_on"],
        on_off_constraint_on=layer_settings["constraints"]["on_off_constraint_on"],
        adjust_constraint_on=layer_settings["constraints"]["adjust_constraint_on"],
        fuel_price=resolve_fuel_price_vector(component, ctx),
        fuel_objective_on=get(layer_settings["objectives"], "fuel_objective_on", true),
        om_objective_on=layer_settings["objectives"]["om_objective_on"],
        adjust_objective_on=layer_settings["objectives"]["adjust_objective_on"],
        on_off_objective_on=layer_settings["objectives"]["on_off_objective_on"],
    )
end
