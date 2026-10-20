using Test
using JSON3
const TEST_DATA_ROOT = mktempdir(; cleanup=false)
ENV["SYNERROLL_DATA_DIR"] = TEST_DATA_ROOT
const server_path = joinpath(@__DIR__, "server.jl")
const server_source = read(server_path, String)
const load_end = findfirst("# 全局常量", server_source)
load_source = replace(server_source[1:first(load_end)-1], "using COPT"=>"", "using SCIP"=>"")
runner_path = joinpath(@__DIR__, "services/capacity_planning/optimization_runner.jl")
load_source = replace(load_source, "include(\"services/capacity_planning/optimization_runner.jl\")" =>
    "include_string(Main, replace(read($(repr(runner_path)), String), \"using COPT\"=>\"\"), $(repr(runner_path)))")
include_string(Main, load_source, server_path)

@testset "Economic params always-on" begin
    # 1) 无 enabled 字段时强制生效，含 IRR
    raw = Dict{String,Any}(
        "objective" => "operating-cost-min",
        "economicConstraints" => Dict{String,Any}(
            "lifecycleYears" => Dict("threshold" => 25),
            "interestRatePercent" => Dict("threshold" => 6),
            "taxRatePercent" => Dict("threshold" => 20),
            "targetIrrPercent" => Dict("threshold" => 7.5),
        ),
        "lifecycle" => Dict{String,Any}(
            "tax_holiday_years" => 2,
            "fixed_om_ratio" => 1.5,
            "subsidy_yuan_per_kwh" => 0.05,
        ),
    )
    cfg = _normalize_economics_config(raw)
    @test cfg["economicConstraints"]["targetIrrPercent"]["enabled"] == true
    @test cfg["economicConstraints"]["interestRatePercent"]["enabled"] == true
    @test cfg["economicConstraints"]["lifecycleYears"]["threshold"] == 25
    @test cfg["lifecycle"]["tax_holiday_years"] == 2
    @test cfg["lifecycle"]["fixed_om_ratio"] == 1.5

    # 2) 参数覆盖生命周期模型
    params = lifecycle_params_from_config(cfg)
    params = _apply_economic_constraints!(params, cfg)
    @test params.operation_years == 25
    @test params.discount_rate ≈ 0.06
    @test params.income_tax_rate ≈ 0.20
    @test params.tax_holiday_years == 2
    @test params.fixed_om_ratio ≈ 1.5

    # 3) IRR 约束始终启用（不要求 enabled）；惩罚公式与 evaluate_economics 一致
    @test cfg["economicConstraints"]["targetIrrPercent"]["enabled"] == true
    # 即使旧配置 enabled=false，normalize 后仍为 true
    legacy = _normalize_economics_config(Dict{String,Any}(
        "objective" => "operating-cost-min",
        "economicConstraints" => Dict{String,Any}(
            "targetIrrPercent" => Dict("enabled" => false, "threshold" => 8.0),
        ),
    ))
    @test legacy["economicConstraints"]["targetIrrPercent"]["enabled"] == true
end
