# HGRID 冒烟测试：schema 加载 → 实例化 → 结果绑定 → 变量名解析
using JSON3
const _ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(_ROOT, "backend", "core", "types.jl"))
include(joinpath(_ROOT, "backend", "core", "component_framework.jl"))
include(joinpath(_ROOT, "backend", "core", "schema.jl"))
include(joinpath(_ROOT, "backend", "core", "validation.jl"))

# 加载组件库 schema
load_component_library(joinpath(_ROOT, "config", "component-library.json"))

include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "component.jl"))
include(joinpath(_ROOT, "backend", "components", "hydrogen_grid", "validation.jl"))

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
    "paras" => Dict{String,Any}(
        "capacity" => 10000.0,
        "sell_ratio" => 1.0,
        "buy_ratio" => 0.0,
    ),
    "costs" => Dict{String,Any}(
        "sell_price" => 30.0,
        "buy_price" => 0.0,
    ),
    "boundaryIds" => String[],
)

hgrid = HydrogenGrid(comp_dict)
println("instantiated: ", typeof(hgrid))
println("type=", component_type(hgrid), " code=", component_code(hgrid))

bindings = component_result_bindings(hgrid)
println("bindings:")
for b in bindings
    println("  ", b.component_label, " | ", b.var_name, " | ", b.remark)
end

# 变量名解析（与 parse_service.build_variable_name 产物对齐）
function parse_connection_variable(var_name::String)
    parts = split(var_name, "_")
    if length(parts) < 4
        return nothing
    end
    dir_str = parts[end-1]
    code = parts[end]
    prefix = parts[1]
    comp_word = join(parts[2:(end-2)], "_")
    comp_key = isempty(prefix) ? comp_word : "$(prefix)_$(comp_word)"
    direction = dir_str == "out" ? :out : :in
    return (comp_key=comp_key, base_comp=comp_word, direction=direction, code=code)
end

parsed = parse_connection_variable("H_HGRID_in_a1b2")
println("parsed H_HGRID_in_a1b2 -> ", parsed)
@assert parsed.comp_key == "H_HGRID"
@assert parsed.direction == :in

parsed2 = parse_connection_variable("H_HGRID_out_a1b2")
println("parsed H_HGRID_out_a1b2 -> ", parsed2)
@assert parsed2.comp_key == "H_HGRID"
@assert parsed2.direction == :out

# buy_ratio 默认 0 → 禁止购入
@assert hgrid.config.paras["buy_ratio"] == 0.0
@assert hgrid.config.paras["sell_ratio"] == 1.0

println("SMOKE_OK")
