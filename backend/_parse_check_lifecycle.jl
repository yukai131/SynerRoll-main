path = "C:/Users/Administrator/Desktop/SynerRoll-main/backend/services/capacity_planning/lifecycle_economics.jl"
src = read(path, String)
ex = Meta.parseall(src)
if ex.head == :error || (ex.head == :incomplete)
    println("PARSE FAIL: ", ex)
    exit(1)
end
println("lifecycle_economics.jl syntax OK, exprs=", length(ex.args))
