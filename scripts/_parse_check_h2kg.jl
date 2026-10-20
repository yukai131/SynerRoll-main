files = [
    "backend/components/electrolyzer/model-common.jl",
    "backend/components/electrolyzer/model-base.jl",
    "backend/components/electrolyzer/model.jl",
    "backend/components/hydrogen_grid/model-common.jl",
    "backend/utils/prediction_utils.jl",
    "backend/services/economy_evaluation_service.jl",
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
