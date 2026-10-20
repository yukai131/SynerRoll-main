files = [
    "backend/utils/prediction_utils.jl",
    "backend/services/economy_evaluation_service.jl",
    "backend/services/model_service.jl",
    "backend/utils/economy_calculator.jl",
    "backend/components/power_grid/model-common.jl",
    "backend/components/hydrogen_grid/model-common.jl",
    "backend/components/coal_power/model-common.jl",
    "backend/components/gas_power/model-common.jl",
    "backend/components/combined_heat_power/model-common.jl",
]
all_ok = true
for f in files
    src = read(f, String)
    ex = Meta.parseall(src)
    ok = !(ex isa Expr && ex.head === :error)
    println(rpad(f, 65), " parse_ok=", ok)
    if !ok
        global all_ok = false
        show(stdout, MIME"text/plain"(), ex)
        println()
    end
end
println("ALL_OK=", all_ok)
