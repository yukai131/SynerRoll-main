# 本地求解器可用性检查（业务无关，仅环境探测）
# 用法: julia backend/tools/check_solvers.jl
# 退出码: 0 = HiGHS 可用；COPT/SCIP 仅报告不阻断

println("SynerRoll solver check")
println("="^40)

function try_solver(name::String, f)
    t = time()
    try
        opt = f()
        m = JuMP.Model(opt)
        JuMP.set_silent(m)
        elapsed = round((time() - t) * 1000; digits=1)
        println("[OK]   $name  (construct in $(elapsed)ms)")
        return true
    catch e
        println("[FAIL] $name  $(sprint(showerror, e))")
        return false
    end
end

using JuMP

has_highs = try
    using HiGHS
    try_solver("HiGHS", () -> HiGHS.Optimizer)
catch e
    println("[FAIL] HiGHS not loadable: ", sprint(showerror, e))
    false
end

has_copt = try
    using COPT
    try_solver("COPT", () -> COPT.Optimizer)
catch e
    println("[FAIL] COPT not loadable: ", sprint(showerror, e))
    println("       需要安装 COPT 本体并配置许可证（COPT_LICENSE / license 文件）")
    false
end

has_scip = try
    using SCIP
    try_solver("SCIP", () -> SCIP.Optimizer)
catch e
    println("[FAIL] SCIP not loadable: ", sprint(showerror, e))
    println("       可执行: julia --project=backend -e 'using Pkg; Pkg.add(\"SCIP\")'")
    false
end

println("="^40)
println("HiGHS=$(has_highs) COPT=$(has_copt) SCIP=$(has_scip)")
println("默认求解器: HiGHS")
exit(has_highs ? 0 : 1)
