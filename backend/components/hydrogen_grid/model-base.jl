# hydrogen_grid/model-base.jl — 数学原理蓝图
#
# 本文件是氢网接口模型的原始实现，变量名无后缀，用于：
#   - 单实例场景的数学功能验证
#   - 理解模型的数学原理
# 共享函数（resolve_hydrogen_grid_params 等）见 model-common.jl
# 对应的元编程追踪版本见 model.jl
# ────────────────────────────────────────────────────────────

function build_component_model!(model, component::HydrogenGrid, ctx::BuildContext)
    params = resolve_hydrogen_grid_params(component, ctx)
    return build_hydrogen_grid_status_model!(model, component, params, ctx, Val(Symbol(params.status)))
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext, ::Val{:stand_alone})
    time_index = generate_timespan(ctx.layer)

    # H_HGRID_in：向氢网上送（售氢）；H_HGRID_out：从氢网购入（购氢）。
    # 氢网交换流量 P_H2 = H_HGRID_in − H_HGRID_out，正表示上送、负表示购入。
    # 默认 buy_ratio=0，因此 H_HGRID_out 上界为 0，禁止购入只能卖出。
    @variable(model, H_HGRID_in[t in time_index], lower_bound = 0.0, upper_bound = params.maximum_sell_power_kgph)
    @variable(model, H_HGRID_out[t in time_index], lower_bound = 0.0, upper_bound = params.maximum_buy_power_kgph)

    objective_expr = @expression(model, 0.0)
    if params.exchange_objective_on
        objective_expr += define_hydrogen_grid_exchange_cost!(model, time_index, H_HGRID_in, H_HGRID_out,
            params.buy_price, params.sell_price)
    end

    return objective_expr
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext, ::Val{:disabled})
    time_index = generate_timespan(ctx.layer)
    # 停用即离网：P_H2 = 0，缺额必须由本地资源或平衡松弛承担。
    @variable(model, H_HGRID_in[t in time_index], lower_bound = 0.0, upper_bound = 0.0)
    @variable(model, H_HGRID_out[t in time_index], lower_bound = 0.0, upper_bound = 0.0)
    return @expression(model, 0.0)
end

function build_hydrogen_grid_status_model!(model, component::HydrogenGrid, params, ctx::BuildContext, status)
    error("HydrogenGrid status $(params.status) is not supported.")
end

# ────────────────────────────────────────────────────────────
# 辅助函数
# ────────────────────────────────────────────────────────────
# 购售氢成本：购氢为正成本、售氢为负成本（收益）。
# buy_price/sell_price 为分时向量（元/kg·步）。
# 购氢价不低于售氢价时最优解不会同时购售，因此不引入购售互斥二元变量。
function define_hydrogen_grid_exchange_cost!(model, time_index, sell_power, buy_power, buy_price, sell_price)
    return @expression(model, C_hgrid_exchange, sum((buy_power[t] * buy_price[t] - sell_power[t] * sell_price[t]) for t in time_index))
end
