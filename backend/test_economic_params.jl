using Test
using JSON3
const TEST_DATA_ROOT = mktempdir(; cleanup=false)
ENV["SYNERROLL_DATA_DIR"] = TEST_DATA_ROOT
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "server.jl"))

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
            "construction_vat_rate" => 10.0,
            "output_vat_rate" => 13.0,
            "input_vat_rate" => 13.0,
            "surcharge_rate" => 12.0,
            "salvage_rate_default" => 5.0,
        ),
    )
    cfg = _normalize_economics_config(raw)
    @test cfg["economicConstraints"]["targetIrrPercent"]["enabled"] == true
    @test cfg["economicConstraints"]["interestRatePercent"]["enabled"] == true
    @test cfg["economicConstraints"]["lifecycleYears"]["threshold"] == 25
    @test cfg["lifecycle"]["tax_holiday_years"] == 2
    @test cfg["lifecycle"]["fixed_om_ratio"] == 1.5

    # 2) 参数覆盖生命周期模型；税率/比例百分数写法归一为小数
    params = lifecycle_params_from_config(cfg)
    params = _apply_economic_constraints!(params, cfg)
    @test params.operation_years == 25
    @test params.discount_rate ≈ 0.06
    @test params.income_tax_rate ≈ 0.20
    @test params.tax_holiday_years == 2
    @test params.fixed_om_ratio ≈ 0.015          # UI 1.5% → 0.015
    @test params.construction_vat_rate ≈ 0.10    # UI 10% → 0.10
    @test params.output_vat_rate ≈ 0.13
    @test params.input_vat_rate ≈ 0.13
    @test params.surcharge_rate ≈ 0.12
    @test params.salvage_rate_default ≈ 0.05     # UI 5% → 0.05

    # 2b) 已是小数的写法不被二次缩放
    decimal_cfg = Dict{String,Any}(
        "lifecycle" => Dict{String,Any}(
            "construction_vat_rate" => 0.10,
            "salvage_rate_default" => 0.05,
            "fixed_om_ratio" => 0.015,
            "income_tax_rate" => 0.25,
        ),
    )
    decimal_params = lifecycle_params_from_config(decimal_cfg)
    @test decimal_params.construction_vat_rate ≈ 0.10
    @test decimal_params.salvage_rate_default ≈ 0.05
    @test decimal_params.fixed_om_ratio ≈ 0.015
    @test decimal_params.income_tax_rate ≈ 0.25

    # 2c) 残值率夹紧，避免 capex×(1-salvage) 出现负折旧
    clamp_params = lifecycle_params_from_config(Dict{String,Any}(
        "lifecycle" => Dict{String,Any}("salvage_rate_default" => 500.0),
    ))
    @test clamp_params.salvage_rate_default ≈ 1.0

    # 2d) UI「1%」不能被当成 100%
    one_pct = lifecycle_params_from_config(Dict{String,Any}(
        "lifecycle" => Dict{String,Any}(
            "construction_vat_rate" => 1.0,
            "salvage_rate_default" => 1.0,
            "fixed_om_ratio" => 1.0,
        ),
    ))
    @test one_pct.construction_vat_rate ≈ 0.01
    @test one_pct.salvage_rate_default ≈ 0.01
    @test one_pct.fixed_om_ratio ≈ 0.01

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
