# Price series resolution: meaning-first (aligned with resolve_grid_price_vectors)
using Test
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
const server_path = joinpath(@__DIR__, "server.jl")
const server_source = read(server_path, String)
const load_end = findfirst("# 全局常量", server_source)
load_source = replace(server_source[1:first(load_end)-1], "using COPT"=>"", "using SCIP"=>"")
include_string(Main, load_source, server_path)

@testset "price series meaning-first" begin
    path = joinpath(mktempdir(), "ts.db")
    t24 = ["$(h):00" for h in 0:23]
    # 绑定顺序故意反了：先 sell 后 buy，且数据不同
    set_ts(path, "b_sell|sell_price|planned#1", TimeSeries(t24, fill(0.4, 24)))
    set_ts(path, "b_buy|buy_price|planned#1", TimeSeries(t24, fill(0.8, 24)))
    set_ts(path, "b_fuel|fuel_price|planned#1", TimeSeries(t24, fill(0.2, 24)))
    set_ts(path, "b_load|load|planned#1", TimeSeries(t24, fill(1.0, 24)))
    close_store(path)

    # multi: slot1=buy, slot2=sell — 与绑定顺序无关
    prices = load_boundary_price_series_multi(path, ["b_sell", "b_buy", "b_fuel", "b_load"], "0:00", "24:00"; n=2)
    @test prices[1] !== nothing && all(x -> x ≈ 0.8, prices[1])
    @test prices[2] !== nothing && all(x -> x ≈ 0.4, prices[2])

    # fuel 单序列
    fuel = load_boundary_price_series(path, ["b_sell", "b_buy", "b_fuel"], "0:00", "24:00")
    @test fuel !== nothing && all(x -> x ≈ 0.2, fuel)

    # generic 回退：只绑 buy，购售共用该曲线
    prices2 = load_boundary_price_series_multi(path, ["b_buy"], "0:00", "24:00"; n=2)
    @test prices2[1] !== nothing && all(x -> x ≈ 0.8, prices2[1])
    @test prices2[2] !== nothing && all(x -> x ≈ 0.8, prices2[2])

    # 无价格边界
    prices3 = load_boundary_price_series_multi(path, ["b_load"], "0:00", "24:00"; n=2)
    @test prices3[1] === nothing
    @test prices3[2] === nothing
end
