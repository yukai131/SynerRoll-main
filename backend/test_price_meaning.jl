using Test
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "server.jl"))

@testset "price series are selected by physical meaning" begin
    path = joinpath(mktempdir(), "ts.db")
    times = ["$(h):00" for h in 0:23]
    set_ts(path, "b_sell|sell_price|planned#1", TimeSeries(times, fill(0.4, 24)))
    set_ts(path, "b_buy|buy_price|planned#1", TimeSeries(times, fill(0.8, 24)))
    set_ts(path, "b_fuel|fuel_price|planned#1", TimeSeries(times, fill(0.2, 24)))
    set_ts(path, "b_load|load|planned#1", TimeSeries(times, fill(1.0, 24)))
    ids = ["b_sell", "b_buy", "b_fuel", "b_load"]
    try
        buy = load_boundary_price_series_by_meaning(path, ids, "buy_price", "0:00", "24:00")
        sell = load_boundary_price_series_by_meaning(path, ids, "sell_price", "0:00", "24:00")
        @test buy == fill(0.8, 24)
        @test sell == fill(0.4, 24)
        @test load_boundary_price_series(path, ids, "0:00", "24:00") == fill(0.2, 24)
        @test load_boundary_price_series_by_meaning(path, ["b_buy"], "sell_price", "0:00", "24:00") === nothing
        @test load_boundary_price_series_by_meaning(path, ["b_load"], "buy_price", "0:00", "24:00") === nothing
        @test load_boundary_price_series_by_meaning(path, ids, "buy_price", "1:00", "2:00") == [0.8]
    finally
        close_store(path)
    end
end
