# 语法检查脚本：解析经济性相关 Julia 文件
files = [
    "backend/utils/economy_calculator.jl",
    "backend/utils/prediction_utils.jl",
    "backend/services/economy_evaluation_service.jl",
    "backend/routes/task.jl",
    "backend/components/coal_power/model-common.jl",
    "backend/components/coal_power/model-base.jl",
    "backend/components/coal_power/model.jl",
    "backend/components/gas_power/model-common.jl",
    "backend/components/gas_power/model-base.jl",
    "backend/components/gas_power/model.jl",
    "backend/components/combined_heat_power/model-common.jl",
    "backend/components/combined_heat_power/model-base.jl",
    "backend/components/combined_heat_power/model.jl",
    "backend/components/power_grid/model-common.jl",
    "backend/components/power_grid/model-base.jl",
    "backend/components/power_grid/model.jl",
    "backend/components/electrolyzer/model-common.jl",
]
for f in files
    try
        src = read(f, String)
        ex = Meta.parseall(src)
        if ex.head === :error || (ex.head === :toplevel && any(x -> x isa Expr && x.head === :error, ex.args))
            println("FAIL $f")
            show(stdout, MIME"text/plain"(), ex)
            println()
        else
            println("OK   $f  ($(length(src)) bytes)")
        end
    catch e
        println("ERR  $f: $e")
    end
end
