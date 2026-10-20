# Verify load_component_data reads production cut keys (remark=power).
using Test
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
const server_path = joinpath(@__DIR__, "server.jl")
const server_source = read(server_path, String)
const load_end = findfirst("# 全局常量", server_source)
load_source = replace(server_source[1:first(load_end)-1], "using COPT"=>"", "using SCIP"=>"")
include_string(Main, load_source, server_path)

@testset "cut series key (remark=power)" begin
    path = joinpath(mktempdir(), "timeseries.db")
    timestamps = ["$(h):00" for h in 0:23]
    # production ResultBinding remark
    set_ts(path, "WT|E_WT_w1|power#1", TimeSeries(timestamps, fill(8.0, 24)))
    set_ts(path, "WT|E_WT_cut_w1|power#1", TimeSeries(timestamps, fill(2.0, 24)))
    set_ts(path, "PV|E_PV_p1|power#1", TimeSeries(timestamps, fill(4.0, 24)))
    set_ts(path, "PV|E_PV_cut_p1|power#1", TimeSeries(timestamps, fill(6.0, 24)))
    close_store(path)

    wt = load_component_data(path, "w1", "WT", "1", "0:00", "24:00")
    @test sum(wt["power"]) ≈ 8.0 * 24
    @test sum(wt["cut"]) ≈ 2.0 * 24

    pv = load_component_data(path, "p1", "PV", "1", "0:00", "24:00")
    @test sum(pv["power"]) ≈ 4.0 * 24
    @test sum(pv["cut"]) ≈ 6.0 * 24

    # consumption rate should NOT be 100% when cut exists
    used = sum(wt["power"]) + sum(pv["power"])
    avail = used + sum(wt["cut"]) + sum(pv["cut"])
    @test 100 * used / avail ≈ 12.0 / 20.0 * 100

    # legacy remark=cut still accepted
    path2 = joinpath(mktempdir(), "timeseries2.db")
    set_ts(path2, "WT|E_WT_w2|power#1", TimeSeries(timestamps, fill(1.0, 24)))
    set_ts(path2, "WT|E_WT_cut_w2|cut#1", TimeSeries(timestamps, fill(3.0, 24)))
    close_store(path2)
    wt2 = load_component_data(path2, "w2", "WT", "1", "0:00", "24:00")
    @test sum(wt2["cut"]) ≈ 3.0 * 24
end

# Also verify against a real production timeseries.db if present
let real = joinpath(
        "C:/Users/Administrator/Desktop/SynerRoll-main/backend/data/capacity-planning",
        "cp-e20ff507-0ae5-46a8-a10e-40e0f57d17d1/work/eb26787efb535803/scenarios/scenario-1/timeseries.db")
    if isfile(real)
        @testset "production scenario-1 cut is non-empty" begin
            wt = load_component_data(real, "f530", "WT", "1", "0:00", "24:00")
            pv = load_component_data(real, "1037", "PV", "1", "0:00", "24:00")
            println("WT power=", sum(wt["power"]), " cut=", sum(wt["cut"]))
            println("PV power=", sum(pv["power"]), " cut=", sum(pv["cut"]))
            @test !isempty(wt["cut"])
            @test sum(wt["cut"]) > 0
            @test !isempty(pv["cut"])
            @test sum(pv["cut"]) > 0
            # old bug: consumption rate was 100; now should be << 100
            used = sum(wt["power"]) + sum(pv["power"])
            avail = used + sum(wt["cut"]) + sum(pv["cut"])
            rate = 100 * used / avail
            println("renewableConsumptionRate=", rate)
            @test rate < 50
        end
    end
end
