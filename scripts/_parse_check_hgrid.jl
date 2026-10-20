files = [
    "backend/components/hydrogen_grid/component.jl",
    "backend/components/hydrogen_grid/validation.jl",
    "backend/components/hydrogen_grid/model-common.jl",
    "backend/components/hydrogen_grid/model-base.jl",
    "backend/components/hydrogen_grid/model.jl",
    "backend/components/hydrogen_grid/flexibility.jl",
    "backend/services/model_service.jl",
    "backend/services/economy_evaluation_service.jl",
    "backend/utils/economy_calculator.jl",
    "backend/services/flexibility_baseline_adapter.jl",
]
all_ok = true
for f in files
    src = read(f, String)
    ex = Meta.parseall(src)
    ok = !(ex isa Expr && ex.head === :error)
    println(rpad(f, 70), " parse_ok=", ok)
    if !ok
        all_ok = false
        show(stdout, MIME"text/plain"(), ex)
        println()
    end
end
println("ALL_OK=", all_ok)
