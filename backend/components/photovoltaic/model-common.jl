# ═══════════════════════════════════════════════════════════════════════════
# photovoltaic/model-common.jl — 共享函数
#
# model-base.jl 和 model.jl 共用的参数解析与辅助函数
# ═══════════════════════════════════════════════════════════════════════════

function resolve_photovoltaic_params(component::Photovoltaic, ctx::BuildContext)
    layer_settings = layer_config(component, ctx.layer["id"])
    paras = component_paras(component)
    time_step_hours = step_hours(ctx.layer)
    ramp_rate_kw_per_hour = paras["ramp"] * paras["capacity"]

    return (
        layer_settings=layer_settings,
        status=layer_settings["status"],
        max_cut_ratio=layer_settings["paras"]["max_cut_ratio"],
        curtailment_constraint_on=layer_settings["constraints"]["curtailment_constraint_on"],
        ramp_constraint_on=layer_settings["constraints"]["ramp_constraint_on"],
        ramp_rate_kw_per_hour=ramp_rate_kw_per_hour,
        ramp_limit_kw=ramp_rate_kw_per_hour * time_step_hours,
        om_objective_on=layer_settings["objectives"]["om_objective_on"],
        cut_objective_on=layer_settings["objectives"]["cut_objective_on"],
        om_cost=component_costs(component)["om_cost"] * step_hours(ctx.layer),
        cut_cost=component_costs(component)["cut_cost"] * step_hours(ctx.layer),
    )
end

"""
    generate_photovoltaic_max_power(component, ctx) -> Vector{Float64}

根据组件关联的边界数据计算光伏可用功率。
遍历 component 的 boundaryIds，从任务时序库中查询边界数据，
按 boundary 的物理意义（factor / irradiance / temperature / power）转换为可用功率。

若组件关联了机型拟合曲线（paras["fitting"]），则完全覆盖默认公式：
P(G,T) 为整场拟合关系，不再乘 capacity/efficiency；温度序列缺失时按 25℃ 处理。
"""
function generate_photovoltaic_max_power(component::Photovoltaic, ctx::BuildContext)
    boundary_ids = component_boundary_ids(component)
    isempty(boundary_ids) && error("Photovoltaic $(component_type(component)) has no boundaryIds configured")

    paras = component_paras(component)
    fitting = get(paras, "fitting", nothing)
    use_fitting = fitting isa AbstractDict && string(get(fitting, "type", "")) == "pv"

    if use_fitting
        irr = nothing
        temp = nothing
        power_direct = nothing
        for boundary_id in boundary_ids
            data, label = resolve_prediction_series(
                ctx;
                source_id=boundary_id,
                algorithm_key="photovoltaicPrediction",
            )
            var_name = parse_ts_label(label)["var_name"]
            if var_name == "irradiance"
                irr = data
            elseif var_name == "temperature"
                temp = data
            elseif var_name == "power"
                power_direct = abs.(data)
            end
        end
        power_direct !== nothing && return power_direct
        irr === nothing && error("PV fitting requires an irradiance boundary — checked: $(boundary_ids)")
        temp_vec = temp === nothing ? fill(25.0, length(irr)) : temp
        return evaluate_pv_fitting_curve(irr, temp_vec, get(fitting, "params", Dict{String,Any}()))
    end

    for boundary_id in boundary_ids
        data, label = resolve_prediction_series(
            ctx;
            source_id=boundary_id,
            algorithm_key="photovoltaicPrediction",
        )
        var_name = parse_ts_label(label)["var_name"]

        if var_name == "factor"
            return clamp.(data, 0.0, 1.0) .* paras["capacity"]
        elseif var_name == "irradiance"
            # 辐照度转功率: P = G / G_ref * η * capacity
            # G_ref 为标准测试条件辐照度 1000 W/m²
            G_ref = 1000.0
            efficiency = get(paras, "efficiency", 0.95)
            return clamp.(data ./ G_ref, 0.0, 1.0) .* efficiency .* paras["capacity"]
        elseif var_name == "power"
            return abs.(data)
        end
    end

    error("No valid boundary data found for Photovoltaic — checked boundaryIds: $(boundary_ids)")
end
