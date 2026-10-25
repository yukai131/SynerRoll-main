# ═══════════════════════════════════════════════════════════════════════════
# power_grid/model-common.jl — 共享函数
#
# 参数解析与辅助函数。
# ═══════════════════════════════════════════════════════════════════════════

function resolve_power_grid_params(component::PowerGrid, ctx::BuildContext)
    layer_settings = layer_config(component, ctx.layer["id"])
    paras = component_paras(component)
    costs = component_costs(component)
    time_step_hours = step_hours(ctx.layer)
    capacity = paras["capacity"]

    grid_buy_prices, grid_sell_prices = resolve_grid_price_vectors(component, ctx)

    return (
        layer_settings=layer_settings,
        status=layer_settings["status"],
        # 接口容量是交换功率基准（kW），上送/购入上限分别由两个比例折算。
        capacity=capacity,
        maximum_sell_power_kw=paras["sell_ratio"] * capacity,
        maximum_buy_power_kw=paras["buy_ratio"] * capacity,
        buy_price=grid_buy_prices,
        sell_price=grid_sell_prices,
        exchange_objective_on=layer_settings["objectives"]["exchange_objective_on"],
    )
end
