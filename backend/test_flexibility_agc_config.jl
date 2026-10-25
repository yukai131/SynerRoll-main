using Test

ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "server.jl"))

function agc_config(; target=nothing, boundary_id=nothing)
    raw = Dict{String,Any}(
        "enabled" => true,
        "layerId" => "3",
        "operationMode" => "economic_operation",
        "networkMode" => "grid_connected",
        "poiId" => "grid-1",
        "requirementSource" => "agc_or_schedule",
    )
    target === nothing || (raw["targetPoiPowerKw"] = target)
    boundary_id === nothing || (raw["targetPoiPowerBoundaryId"] = boundary_id)
    return raw
end

@testset "AGC flexibility task configuration" begin
    constant = normalize_flexibility_evaluation_config(
        agc_config(target=-1200.0);
        default_layer_id="1",
    )
    @test constant.target_poi_power_kw == -1200.0
    @test constant.target_poi_power_boundary_id === nothing
    @test flexibility_evaluation_config_dict(constant)["targetPoiPowerKw"] == -1200.0

    series = normalize_flexibility_evaluation_config(
        agc_config(target=Dict("1:00" => 100.0, "2:00" => 150.0));
        default_layer_id="1",
    )
    @test series.target_poi_power_kw == Dict("1:00" => 100.0, "2:00" => 150.0)

    boundary = normalize_flexibility_evaluation_config(
        agc_config(boundary_id="agc-2026");
        default_layer_id="1",
    )
    @test boundary.target_poi_power_kw === nothing
    @test boundary.target_poi_power_boundary_id == "agc-2026"
    @test flexibility_boundary_ids(boundary) == ["agc-2026"]
    @test flexibility_evaluation_config_dict(boundary)["targetPoiPowerBoundaryId"] == "agc-2026"

    @test_throws ArgumentError normalize_flexibility_evaluation_config(
        agc_config();
        default_layer_id="1",
    )
    @test_throws ArgumentError normalize_flexibility_evaluation_config(
        agc_config(target=100.0, boundary_id="agc-2026");
        default_layer_id="1",
    )
end

@testset "AGC target deviation becomes directional demand" begin
    context = SystemFlexibilityRequirementContext(
        timestamp="0:00",
        next_timestamp="1:00",
        time_step="1h",
        case_id="agc-test",
        application_type="configured_project",
        operation_mode="economic_operation",
        boundary_condition="grid_component_limits",
        poi_id="grid-1",
    )

    upward = calculate_system_flexibility_requirement(
        context,
        AgcScheduleRequirementInput(
            baseline_poi_power_kw=100.0,
            target_poi_power_kw=130.0,
        ),
    )
    @test upward[1].requirement == 30.0
    @test upward[2].requirement == 0.0

    downward = calculate_system_flexibility_requirement(
        context,
        AgcScheduleRequirementInput(
            baseline_poi_power_kw=100.0,
            target_poi_power_kw=80.0,
        ),
    )
    @test downward[1].requirement == 0.0
    @test downward[2].requirement == 20.0
end
