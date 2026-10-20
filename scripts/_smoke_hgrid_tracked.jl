# HGRID tracked 模型冒烟（model.jl + CodeTracer）
using JSON3
using JuMP

const _ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(_ROOT, "backend", "core", "types.jl"))
include(joinpath(_ROOT, "backend", "core", "component_framework.jl"))
include(joinpath(_ROOT, "backend", "core", "schema.jl"))
include(joinpath(_ROOT, "backend", "core", "validation.jl"))
include(joinpath(_ROOT, "backend", "utils", "timestr_utils.jl"))
include(joinpath(_ROOT, "backend", "utils", "model_builder_utils.jl"))

function step_hours(layer::Dict{String,Any})
    return time_str_to_minutes(string(layer["step"])) / 60.0
end
function generate_timespan(layer::Dict{String,Any})
    return 1:parse(Int, string(layer["length"]))
end
function resolve_grid_price_vectors(component, ctx)
    n = length(generate_timespan(ctx.layer))
    dt = step_hours(ctx.layer)
    costs = component_costs(component)
    buy_fb = Float64(get(costs, "buy_price", 0.0)) * dt
    sell_fb = Float64(get(costs, "sell_price", 0.0)) * dt
    return fill(buy_fb, n), fill(sell_fb, n)
end

load_component_library(joinpath(_ROOT, "config", "component-library.json"))
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "component.jl"))
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "validation.jl"))
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "model-common.jl"))
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "model.jl"))

layer = Dict{String,Any}("id" => "1", "step" => "1h", "length" => "4")
ctx = BuildContext(layer, "2026-01-01 00:00", Dict{String,Any}(), "", 3)

comp_dict = Dict{String,Any}(
    "type" => "HGRID",
    "code" => "a1b2",
    "layer" => Dict{String,Any}(
        "1" => Dict{String,Any}(
            "status" => "stand_alone",
            "paras" => Dict{String,Any}(),
            "costs" => Dict{String,Any}(),
            "constraints" => Dict{String,Any}(),
            "objectives" => Dict{String,Any}("exchange_objective_on" => true),
        ),
    ),
    "paras" => Dict{String,Any}("capacity" => 10000.0, "sell_ratio" => 1.0, "buy_ratio" => 0.0),
    "costs" => Dict{String,Any}("sell_price" => 30.0, "buy_price" => 0.0),
    "boundaryIds" => String[],
)

hgrid = HydrogenGrid(comp_dict)
model = Model()
tracer = CodeTracer()
obj = build_component_model!(model, hgrid, ctx, tracer)

code = get_code(tracer)
println("--- generated code ---")
println(code)
println("--- end ---")

for name in ["H_HGRID_in_a1b2", "H_HGRID_out_a1b2", "C_hgrid_exchange_a1b2"]
    @assert occursin(name, code) "generated code missing $(name)"
end
@assert haskey(object_dictionary(model), :H_HGRID_in_a1b2)
@assert haskey(object_dictionary(model), :H_HGRID_out_a1b2)
@assert haskey(object_dictionary(model), :C_hgrid_exchange_a1b2)

ub_out = upper_bound.(model[:H_HGRID_out_a1b2])
@assert all(ub_out .== 0.0)
println("TRACKED_SMOKE_OK")
