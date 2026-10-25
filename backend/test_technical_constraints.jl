# Focused check: technical metrics + soft penalty without full planning suite.
using Test
using JSON3
const TEST_DATA_ROOT = mktempdir(; cleanup=false)
ENV["SYNERROLL_DATA_DIR"] = TEST_DATA_ROOT
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "server.jl"))

const library = JSON3.read(read(joinpath(@__DIR__, "../config/component-library.json"), String), Dict{String,Any})["components"]
function fixture_node(id, key; capacity=100.0, boundaries=String[])
    schema = library[key]
    defaults(section) = Dict{String,Any}(field["key"] => get(field, "defaultValue", nothing) for field in get(schema, section, []))
    tech = defaults("commonTechFields")
    haskey(tech, "capacity") && (tech["capacity"] = capacity)
    business = Dict{String,Any}("componentKey" => key, "commonTechParams" => tech,
        "commonEconomicParams" => defaults("commonEconomicFields"), "boundaryIds" => boundaries,
        "layerConfigs" => Dict("1" => Dict{String,Any}("status" => "stand_alone",
            "techParams" => defaults("layerTechFields"), "economicParams" => defaults("layerEconomicFields"),
            "constraints" => defaults("constraintFields"), "objectives" => defaults("objectiveFields"))))
    return Dict{String,Any}("id" => id, "data" => Dict{String,Any}("label" => key, "componentKey" => key, "business" => business))
end
function fixture_project(nodes)
    Dict{String,Any}("id" => "capacity-test", "name" => "容量测试", "updateTime" => "2026-10-19T00:00:00Z",
        "workspace" => Dict{String,Any}("activeCanvasId" => "A", "canvases" => [
            Dict{String,Any}("id" => "A", "name" => "A", "nodes" => nodes, "edges" => Any[])]),
        "boundaries" => Any[], "algorithm" => Dict{String,Any}("solver" => "HiGHS", "slackEnabled" => false),
        "layerConfig" => Dict("layers" => [Dict{String,Any}("id" => "1", "name" => "日层", "length" => "24h", "step" => "1h")] ))
end

@testset "Technical constraint soft penalty" begin
    project = fixture_project([fixture_node("node-wind", "WT"), fixture_node("node-grid", "GRID")])
    work = joinpath(TEST_DATA_ROOT, "tech-candidate")
    timestamps = ["$(hour):00" for hour in 0:23]
    # 10 units available, 8 used, 2 cut → 消纳率 80%
    path = joinpath(work, "scenarios", "scenario-1", "timeseries.db")
    set_ts(path, "WT|E_WT_wind|power#1", TimeSeries(timestamps, fill(8.0, 24)))
    set_ts(path, "WT|E_WT_cut_wind|power#1", TimeSeries(timestamps, fill(2.0, 24)))
    # 买 2，卖 0 → 总供电 = 8 + 2 = 10；绿电 80%，购电 20%
    set_ts(path, "GRID|E_GRID_in_grid|power#1", TimeSeries(timestamps, zeros(24)))
    set_ts(path, "GRID|E_GRID_out_grid|power#1", TimeSeries(timestamps, fill(2.0, 24)))
    # 前 12 小时有缺额 → 稳定性 50%
    set_ts(path, "BUS|E_SHORTAGE_test|slack#1", TimeSeries(timestamps, vcat(fill(1.0, 12), zeros(12))))
    close_store(path)
    metrics = [Dict{String,Any}("scenarioId"=>"scenario-1", "weightDays"=>30, "feasible"=>true)]
    simulation = EvaluationResult(feasible=true, operating_objective=0.0, metrics=Dict{String,Float64}(), scenario_metrics=metrics)

    #1) 指标口径
    scenario = evaluate_scenario_operating_cost(path, project, "1")
    tech = scenario.technical_metrics
    @test tech["renewableConsumptionRate"] ≈ 80.0
    @test tech["greenPowerShare"] ≈ 80.0
    @test tech["purchasedPowerShare"] ≈ 20.0
    @test tech["stability"] ≈ 50.0

    # 2) 约束关闭时零惩罚
    config_off = Dict{String,Any}(
        "objective" => "operating-cost-min",
        "technicalPenalty" => 1000.0,
        "technicalConstraints" => Dict{String,Any}(
            "renewableConsumptionRate" => Dict("enabled"=>false, "operator"=>"gte", "threshold"=>90.0, "unit"=>"%"),
            "greenPowerShare" => Dict("enabled"=>false, "operator"=>"gte", "threshold"=>50.0, "unit"=>"%"),
            "purchasedPowerShare" => Dict("enabled"=>false, "operator"=>"lte", "threshold"=>30.0, "unit"=>"%"),
            "stability" => Dict("enabled"=>false, "operator"=>"gte", "threshold"=>95.0, "unit"=>"%"),
        ),
    )
    input_off = EconomicEvaluationInput(capacities=Dict("node-wind"=>100.0), units=Dict("node-wind"=>"kW"),
        simulation=simulation, config=config_off, work_dir=work, project_snapshot=project)
    eval_off = evaluate_economics(TimeseriesOperatingCostEvaluator(), input_off)
    @test eval_off.breakdown["technicalConstraintPenalty"] == 0.0
    @test eval_off.breakdown["technicalMetrics"]["renewableConsumptionRate"] ≈ 80.0

    # 3) 启用后按偏差百分点惩罚：(90-80)+(50-50)+(20-30 for lte? wait purchased 20<=30 ok)+(95-50)
    # renewable shortfall 10, green 0, purchased 0, stability 45 → 55 * 1000 = 55000
    config_on = deepcopy(config_off)
    config_on["technicalConstraints"] = Dict{String,Any}(
        "renewableConsumptionRate" => Dict("enabled"=>true, "operator"=>"gte", "threshold"=>90.0, "unit"=>"%"),
        "greenPowerShare" => Dict("enabled"=>true, "operator"=>"gte", "threshold"=>50.0, "unit"=>"%"),
        "purchasedPowerShare" => Dict("enabled"=>true, "operator"=>"lte", "threshold"=>30.0, "unit"=>"%"),
        "stability" => Dict("enabled"=>true, "operator"=>"gte", "threshold"=>95.0, "unit"=>"%"),
    )
    input_on = EconomicEvaluationInput(capacities=Dict("node-wind"=>100.0), units=Dict("node-wind"=>"kW"),
        simulation=simulation, config=config_on, work_dir=work, project_snapshot=project)
    eval_on = evaluate_economics(TimeseriesOperatingCostEvaluator(), input_on)
    @test eval_on.breakdown["technicalConstraintPenalty"] ≈ 55000.0
    @test eval_on.breakdown["constraintPenalty"] ≈ 55000.0
    # 量纲统一后：money 目标下惩罚仍为元，fitness = objective + penalty
    @test eval_on.breakdown["fitnessPenaltyMode"] == "same-unit"
    @test eval_on.fitness ≈ eval_off.fitness + 55000.0
    @test length(eval_on.breakdown["technicalConstraintDetails"]) == 4

    # 4) 任务配置未带 technicalPenalty 时，回退读项目 algorithm（建模页「算法配置」）
    project_algo = deepcopy(project)
    project_algo["algorithm"] = merge(Dict{String,Any}(project_algo["algorithm"]), Dict("technicalPenalty" => 2000.0))
    config_from_project = deepcopy(config_on)
    delete!(config_from_project, "technicalPenalty")
    input_project = EconomicEvaluationInput(capacities=Dict("node-wind"=>100.0), units=Dict("node-wind"=>"kW"),
        simulation=simulation, config=config_from_project, work_dir=work, project_snapshot=project_algo)
    eval_project = evaluate_economics(TimeseriesOperatingCostEvaluator(), input_project)
    # 偏差 55 百分点 × 2000 = 110000
    @test eval_project.breakdown["technicalConstraintPenalty"] ≈ 110000.0
end
