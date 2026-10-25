ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include(joinpath(@__DIR__, "backend", "server.jl"))
warmup_backend(; strict=true)
HiGHS.Optimizer() # 验证离线原生库可加载。
println("PSFA Julia/HiGHS runtime ready")
