# economy_calculator 单元冒烟测试
include(joinpath(@__DIR__, "utils", "economy_calculator.jl"))

using Test

@testset "economy_calculator" begin
    # 运维成本：ΣP × rate
    p = [100.0, 200.0, 0.0]
    @test calc_cp_om_cost(p, 0.5) ≈ 150.0

    # 启停：0,1,1,0 → 2 次跳变
    st = [0.0, 1.0, 1.0, 0.0]
    @test count_on_off_transitions(st) == 2
    @test calc_cp_on_off_cost(st, 10000.0) ≈ 20000.0

    # 出力推导状态
    @test derive_on_off_status([0.0, 10.0, 0.0]) == [0.0, 1.0, 0.0]

    # 调整成本
    @test calc_cp_adjust_cost([10.0, 20.0], [12.0, 18.0], 2.0) ≈ 8.0

    # 火电完整项（on_off 不缩放已在 params 侧体现）
    params = (
        om_cost = 0.5,
        on_off_cost = 10000.0,
        adjust_cost = 1.0,
        layer_settings = Dict(
            "objectives" => Dict(
                "om_objective_on" => true,
                "on_off_objective_on" => true,
                "adjust_objective_on" => false,
            ),
        ),
    )
    items = calc_thermal_costs(
        "CP", "n1", "机组1", [100.0, 0.0, 100.0], params, "1";
        status_vector=[1.0, 0.0, 1.0],
        planned_power=[100.0, 100.0, 100.0],
    )
    @test length(items) == 3
    om = only(filter(i -> i.cost_type == "om_cost", items))
    onoff = only(filter(i -> i.cost_type == "on_off_cost", items))
    adj = only(filter(i -> i.cost_type == "adjust_cost", items))
    @test om.value ≈ 100.0  # 200 * 0.5
    @test om.in_objective
    @test onoff.value ≈ 20000.0  # 2 次 × 10000
    @test onoff.in_objective
    @test adj.value ≈ 100.0  # |0-100| * 1
    @test !adj.in_objective  # 未选入目标
    @test adj.objective_flag == "adjust_objective_on"
    @test !isempty(adj.formula)

    # 电网
    gparams = (
        buy_price = 0.5,
        sell_price = 0.4,
        layer_settings = Dict("objectives" => Dict("exchange_objective_on" => true)),
    )
    gitems = calc_grid_costs("g1", "电网", [100.0], [50.0], gparams, "1")
    @test length(gitems) == 2
    buy = only(filter(i -> i.cost_type == "purchase_cost", gitems))
    sell = only(filter(i -> i.cost_type == "sell_revenue", gitems))
    @test buy.value ≈ 25.0
    @test sell.value ≈ -40.0
    @test sell.is_revenue

    # 风光
    rparams = (
        om_cost = 0.1,
        cut_cost = 0.9,
        layer_settings = Dict("objectives" => Dict("om_objective_on" => true, "cut_objective_on" => true)),
    )
    ritems = calc_renewable_costs("WT", "w1", "风机1", [100.0], [10.0], rparams, "1")
    @test length(ritems) == 2
    @test only(filter(i -> i.cost_type == "om_cost", ritems)).value ≈ 10.0
    @test only(filter(i -> i.cost_type == "cut_cost", ritems)).value ≈ 9.0

    # 储能
    sparams = (
        om_cost = 0.2,
        adjust_cost = 1.0,
        layer_settings = Dict("objectives" => Dict("om_objective_on" => true, "adjust_objective_on" => true)),
    )
    sitems = calc_storage_costs(
        "ES", "s1", "储能1", [10.0, 20.0], [5.0, 0.0], sparams, "1";
        planned_input=[10.0, 10.0], planned_output=[5.0, 5.0],
    )
    @test only(filter(i -> i.cost_type == "om_cost", sitems)).value ≈ 7.0  # (10+5+20+0)*0.2
    @test only(filter(i -> i.cost_type == "adjust_cost", sitems)).value ≈ 15.0  # 0+10 + 0+5

    # 松弛
    slack = calc_slack_penalty("b1", "总线", [1.0, 2.0], [0.0], 100.0, 50.0, "1")
    @test length(slack) == 1
    @test slack[1].value ≈ 300.0
    @test slack[1].is_slack

    # 浮点噪声不得记为松弛（否则 hasSlack 误报能量不平衡）
    noise = calc_slack_penalty("b1", "总线", [0.0], [6.4e-18, 2.1e-23], 100.0, 50.0, "1")
    @test isempty(noise)
    @test !is_meaningful_slack(9.1e-17)
    @test is_meaningful_slack(1.0e-3)
    # 真实松弛仍入账
    real = calc_slack_penalty("b1", "总线", [0.0], [0.5], 100.0, 50.0, "1")
    @test length(real) == 1
    @test real[1].value ≈ 0.5 * 50.0
    @test !slack[1].in_objective

    # HYDRO 走 thermal
    hitems = calc_component_cost("HYDRO", "h1", "水电", Dict("power" => [100.0]), 
        (om_cost=0.05, on_off_cost=0.0, adjust_cost=0.0, layer_settings=Dict("objectives"=>Dict())), "1")
    @test length(hitems) >= 1
    @test hitems[1].value ≈ 5.0
end


@testset "fuel and grid tou" begin
    params = (
        om_cost = 0.1,
        on_off_cost = 0.0,
        adjust_cost = 0.0,
        fuel_price = 0.25,  # 元/kW·步
        layer_settings = Dict(
            "objectives" => Dict(
                "om_objective_on" => true,
                "fuel_objective_on" => true,
                "on_off_objective_on" => false,
                "adjust_objective_on" => false,
            ),
        ),
    )
    # fuel = E/η，η=0.5 → F=2E
    items = calc_thermal_costs(
        "CP", "n1", "煤机", [100.0, 50.0], params, "1";
        fuel_values=[200.0, 100.0],
        fuel_price=params.fuel_price,
    )
    fuel = only(filter(i -> i.cost_type == "fuel_cost", items))
    @test fuel.value ≈ 300.0 * 0.25
    @test fuel.in_objective
    @test fuel.objective_flag == "fuel_objective_on"

    # 分时燃料价向量
    items2 = calc_thermal_costs(
        "CP", "n1", "煤机", [100.0, 50.0], params, "1";
        fuel_values=[200.0, 100.0],
        fuel_price=[0.2, 0.3],
    )
    fuel2 = only(filter(i -> i.cost_type == "fuel_cost", items2))
    @test fuel2.value ≈ 200.0 * 0.2 + 100.0 * 0.3

    # 未选入目标
    params_off = merge(params, (
        layer_settings = Dict("objectives" => Dict("fuel_objective_on" => false, "om_objective_on" => true)),
    ))
    items3 = calc_thermal_costs(
        "CP", "n1", "煤机", [100.0], params_off, "1";
        fuel_values=[200.0], fuel_price=0.25,
    )
    fuel3 = only(filter(i -> i.cost_type == "fuel_cost", items3))
    @test !fuel3.in_objective

    # GRID 分时购电价
    gparams = (
        buy_price = [0.5, 0.8],
        sell_price = [0.4, 0.4],
        layer_settings = Dict("objectives" => Dict("exchange_objective_on" => true)),
    )
    gitems = calc_grid_costs("g1", "电网", [10.0, 10.0], [5.0, 5.0], gparams, "1")
    buy = only(filter(i -> i.cost_type == "purchase_cost", gitems))
    sell = only(filter(i -> i.cost_type == "sell_revenue", gitems))
    @test buy.value ≈ 5.0 * 0.5 + 5.0 * 0.8
    @test sell.value ≈ -(10.0 * 0.4 + 10.0 * 0.4)
end
println("ALL ECONOMY CALCULATOR TESTS PASSED")
