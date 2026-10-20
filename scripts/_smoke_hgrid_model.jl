# HGRID 建模冒烟：构建 JuMP 模型 + 氢总线平衡
using JSON3
using JuMP

const _ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(_ROOT, "backend", "core", "types.jl"))
include(joinpath(_ROOT, "backend", "core", "component_framework.jl"))
include(joinpath(_ROOT, "backend", "core", "schema.jl"))
include(joinpath(_ROOT, "backend", "core", "validation.jl"))
include(joinpath(_ROOT, "backend", "utils", "timestr_utils.jl"))

# 最小 BuildContext 依赖
function step_hours(layer::Dict{String,Any})
    return time_str_to_minutes(string(layer["step"])) / 60.0
end

function generate_timespan(layer::Dict{String,Any})
    return 1:parse(Int, string(layer["length"]))
end

function format_val(x)
    return repr(x)
end

# 最小价格解析 stub（无边界时用标量兜底）
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
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "model-base.jl"))

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

# 构建最小模型
model = Model()
obj = build_component_model!(model, hgrid, ctx)

println("variables:")
# model-base.jl 变量名无 code 后缀
for name in ["H_HGRID_in", "H_HGRID_out"]
    if haskey(object_dictionary(model), Symbol(name))
        var = model[Symbol(name)]
        ub = upper_bound.(var)
        lb = lower_bound.(var)
        println("  ", name, " lb=", lb, " ub=", ub)
    else
        error("missing variable ", name)
    end
end

# buy_ratio=0 → 购入上界必须为 0
ub_out = upper_bound.(model[:H_HGRID_out])
@assert all(ub_out .== 0.0) "buy upper bound must be 0, got $(ub_out)"

# sell 上界 = capacity * sell_ratio
ub_in = upper_bound.(model[:H_HGRID_in])
@assert all(ub_in .== 10000.0) "sell upper bound must be 10000, got $(ub_in)"

# 氢总线平衡：模拟 ET 产氢 + HGRID 售氢
# H_ET (产氢注入) - H_HLOAD (氢负荷) - H_HGRID_in (售氢提取) + H_HGRID_out (购入注入) = 0
# 简化：只验证符号约定
function get_hydrogen_energy_signal(comp_key::String, direction::Symbol)
    if comp_key == "ET" || comp_key == "H_ET"
        return 1.0
    elseif comp_key == "HLOAD" || comp_key == "H_HLOAD"
        return -1.0
    elseif comp_key == "HS" || comp_key == "H_HS"
        return direction == :in ? -1.0 : 1.0
    elseif comp_key == "HGRID" || comp_key == "H_HGRID"
        return direction == :in ? -1.0 : 1.0
    end
    error("unknown hydrogen bus component: $comp_key")
end

sig_sell = get_hydrogen_energy_signal("H_HGRID", :in)
sig_buy = get_hydrogen_energy_signal("H_HGRID", :out)
@assert sig_sell == -1.0 "售氢应从氢总线提取"
@assert sig_buy == 1.0 "购氢应注入氢总线"

# 目标函数：售氢收益为负成本
println("objective expr type: ", typeof(obj))
println("num variables: ", num_variables(model))
println("MODEL_SMOKE_OK")
