# hydrogen_grid/model-common.jl — 共享函数
#
# 参数解析与辅助函数。
# 氢网功率单位统一为 kg/h，价格单位为 元/kg（× time_step_hours 后为 元/kg·步）

function resolve_hydrogen_grid_params(component::HydrogenGrid, ctx::BuildContext)
    layer_settings = layer_config(component, ctx.layer["id"])
    paras = component_paras(component)
    costs = component_costs(component)
    time_step_hours = step_hours(ctx.layer)
    capacity = paras["capacity"]

    # 氢价专用含义：h2_buy_price / h2_sell_price（元/kg）
    buy_prices, sell_prices = resolve_grid_price_vectors(component, ctx;
        buy_meaning="h2_buy_price", sell_meaning="h2_sell_price")

    return (
        layer_settings=layer_settings,
        status=layer_settings["status"],
        # 接口容量是交换流量基准（kg/h），上送/购入上限分别由两个比例折算
        capacity=capacity,
        maximum_sell_power_kgph=paras["sell_ratio"] * capacity,
        maximum_buy_power_kgph=paras["buy_ratio"] * capacity,
        buy_price=buy_prices,
        sell_price=sell_prices,
        exchange_objective_on=layer_settings["objectives"]["exchange_objective_on"],
    )
end
