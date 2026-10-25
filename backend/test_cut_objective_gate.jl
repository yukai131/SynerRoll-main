# cut_objective_on must gate planning fitness (sync with JuMP objective)
using Test
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "server.jl"))

function _fixture_project(; cut_objective_on::Bool)
    library = JSON3.read(read(joinpath(@__DIR__, "../config/component-library.json"), String), Dict{String,Any})["components"]
    function node(id, key; capacity=100.0)
        schema = library[key]
        defaults(section) = Dict{String,Any}(field["key"] => get(field, "defaultValue", nothing) for field in get(schema, section, []))
        tech = defaults("commonTechFields")
        haskey(tech, "capacity") && (tech["capacity"] = capacity)
        business = Dict{String,Any}(
            "componentKey" => key, "commonTechParams" => tech,
            "commonEconomicParams" => defaults("commonEconomicFields"),
            "boundaryIds" => String[],
            "layerConfigs" => Dict("1" => Dict{String,Any}(
                "status" => "stand_alone",
                "techParams" => defaults("layerTechFields"),
                "economicParams" => defaults("layerEconomicFields"),
                "constraints" => defaults("constraintFields"),
                "objectives" => merge(defaults("objectiveFields"), Dict("cut_objective_on" => Dict("enabled" => cut_objective_on))),
            )),
        )
        return Dict{String,Any}("id" => id, "data" => Dict{String,Any}("label" => key, "componentKey" => key, "business" => business))
    end
    return Dict{String,Any}(
        "id" => "capacity-test", "name" => "t", "updateTime" => "2026-10-19T00:00:00Z",
        "workspace" => Dict{String,Any}("activeCanvasId" => "A", "canvases" => [
            Dict{String,Any}("id" => "A", "name" => "A",
                "nodes" => [node("node-wind", "WT"), node("node-pv", "PV"), node("node-grid", "GRID")], "edges" => Any[])]),
        "boundaries" => Any[],
        "algorithm" => Dict{String,Any}("solver" => "HiGHS", "slackEnabled" => false),
        "layerConfig" => Dict("layers" => [Dict{String,Any}("id" => "1", "name" => "日层", "length" => "24h", "step" => "1h")]),
    )
end

@testset "cut_objective_on gates planning fitness" begin
    path = joinpath(mktempdir(), "timeseries.db")
    timestamps = ["$(h):00" for h in 0:23]
    set_ts(path, "WT|E_WT_w1|power#1", TimeSeries(timestamps, fill(8.0, 24)))
    set_ts(path, "WT|E_WT_cut_w1|power#1", TimeSeries(timestamps, fill(2.0, 24)))
    set_ts(path, "GRID|E_GRID_in_g1|power#1", TimeSeries(timestamps, zeros(24)))
    set_ts(path, "GRID|E_GRID_out_g1|power#1", TimeSeries(timestamps, zeros(24)))
    close_store(path)

    # cut_cost 0.9 default from schema; 2*24*0.9 = 43.2
    proj_on = _fixture_project(cut_objective_on=true)
    proj_off = _fixture_project(cut_objective_on=false)
    # patch node codes to match set_ts
    for proj in (proj_on, proj_off)
        nodes = proj["workspace"]["canvases"][1]["nodes"]
        nodes[1]["id"] = "node-wind"
        # _parse_component_nodes derives code from id — use short codes matching keys
    end

    # Use evaluate_scenario_operating_cost with codes from _parse_component_nodes
    dicts, _, _ = _parse_component_nodes(proj_on["workspace"]["canvases"][1]["nodes"])
    wt = only(filter(d -> d["type"] == "WT", dicts))
    pv = only(filter(d -> d["type"] == "PV", dicts))
    grid = only(filter(d -> d["type"] == "GRID", dicts))
    wt_code, pv_code, grid_code = wt["code"], pv["code"], grid["code"]

    path2 = joinpath(mktempdir(), "ts2.db")
    # WT: 8 used + 2 cut；PV: 4 used + 6 cut；cut_cost 默认 0.9
    set_ts(path2, "WT|E_WT_$(wt_code)|power#1", TimeSeries(timestamps, fill(8.0, 24)))
    set_ts(path2, "WT|E_WT_cut_$(wt_code)|power#1", TimeSeries(timestamps, fill(2.0, 24)))
    set_ts(path2, "PV|E_PV_$(pv_code)|power#1", TimeSeries(timestamps, fill(4.0, 24)))
    set_ts(path2, "PV|E_PV_cut_$(pv_code)|power#1", TimeSeries(timestamps, fill(6.0, 24)))
    set_ts(path2, "GRID|E_GRID_in_$(grid_code)|power#1", TimeSeries(timestamps, zeros(24)))
    set_ts(path2, "GRID|E_GRID_out_$(grid_code)|power#1", TimeSeries(timestamps, zeros(24)))
    close_store(path2)

    on = evaluate_scenario_operating_cost(path2, proj_on, "1")
    off = evaluate_scenario_operating_cost(path2, proj_off, "1")

    # om = (8+4)*24*0.1 = 28.8
    # cut 风 2*24*0.9=43.2 + 光 6*24*0.9=129.6 → 合计 172.8
    om = 28.8
    cut_wt = 43.2
    cut_pv = 129.6
    @test on.total_cost ≈ om + cut_wt + cut_pv
    @test off.total_cost ≈ om
    @test off.cost_breakdown["cut_cost"] ≈ cut_wt + cut_pv
    @test on.total_cost - off.total_cost ≈ cut_wt + cut_pv
end
