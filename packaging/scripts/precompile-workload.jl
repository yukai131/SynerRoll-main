# 此脚本在独立临时进程中执行，只为记录依赖方法的编译签名。
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
ENV["SYNERROLL_DISABLE_COPT"] = "1"
ENV["SYNERROLL_DATA_DIR"] = mktempdir()
include(joinpath(@__DIR__, "..", "..", "backend", "server.jl"))
warmup_backend(; strict=true)
