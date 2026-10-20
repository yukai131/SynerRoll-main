# hydrogen_grid/model.jl — 元编程框架版本
#
# 设计：
#   - 使用 JuMP 直接 API + CodeTracer 构建模型并记录代码
#   - 所有参数在代码追踪中内联为硬值
#   - 原始数学原理见 model-base.jl
# ────────────────────────────────────────────────────────────

function build_component_model!(model, component::HydrogenGrid, ctx::BuildContext, tracer::CodeTracer)
    params = resolve_hydrogen_grid_params(component, ctx)
    code = component_code(component)
    return build_hydrogen_grid_status_model!(model, component, params, ctx, code, tracer, Val(Symbol(params.status)))
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext,
    code::String, tracer::CodeTracer, ::Val{:stand_alone})
    time_index = generate_timespan(ctx.layer)
    c = code

    # ─── 变量 ────────────────────────────────────────────────
    # H_HGRID_in：向氢网上送（售氢）；H_HGRID_out：从氢网购入（购氢）。
    # 氢网交换流量 P_H2 = H_HGRID_in − H_HGRID_out，正表示上送、负表示购入。
    # 默认 buy_ratio=0，H_HGRID_out 上界为 0，禁止购入只能卖出。
    H_HGRID_in = add_tracked_variable!(model, tracer, "H_HGRID_in_$(c)", time_index;
        lower_bound=0.0, upper_bound=params.maximum_sell_power_kgph)
    H_HGRID_out = add_tracked_variable!(model, tracer, "H_HGRID_out_$(c)", time_index;
        lower_bound=0.0, upper_bound=params.maximum_buy_power_kgph)

    # ─── 目标函数 ────────────────────────────────────────────
    objective_expr = @expression(model, 0.0)
    if params.exchange_objective_on
        objective_expr += define_hydrogen_grid_exchange_cost_tracked!(model, tracer, time_index, H_HGRID_in, H_HGRID_out, params, c)
    end

    return objective_expr
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext,
    code::String, tracer::CodeTracer, ::Val{:disabled})
    time_index = generate_timespan(ctx.layer)
    c = code
    # 停用即离网：P_H2 = 0，缺额必须由本地资源或平衡松弛承担。
    add_tracked_variable!(model, tracer, "H_HGRID_in_$(c)", time_index; lower_bound=0.0, upper_bound=0.0)
    add_tracked_variable!(model, tracer, "H_HGRID_out_$(c)", time_index; lower_bound=0.0, upper_bound=0.0)
    return @expression(model, 0.0)
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext,
    code::String, tracer::CodeTracer, status)
    error("HydrogenGrid status $(params.status) is not supported.")
end

# ────────────────────────────────────────────────────────────
# 辅助函数（tracked 版本）
# ────────────────────────────────────────────────────────────
function define_hydrogen_grid_exchange_cost_tracked!(model, tracer, time_index, sell_power, buy_power, params, c::String)
    expr = sum((buy_power[t] * params.buy_price[t] - sell_power[t] * params.sell_price[t]) for t in time_index)
    add_tracked_expression!(model, tracer, "C_hgrid_exchange_$(c)",
        "@expression(model, C_hgrid_exchange_$(c), sum((H_HGRID_out_$(c)[t] * $(format_val(params.buy_price))[t] - H_HGRID_in_$(c)[t] * $(format_val(params.sell_price))[t]) for t in $(format_val(time_index))))",
        expr; to_objective=true)
    return expr
end
