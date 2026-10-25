using PackageCompiler
ENV["JULIA_IMAGE_THREADS"] = get(ENV, "JULIA_IMAGE_THREADS", "1")

root = normpath(joinpath(@__DIR__, "..", ".."))
backend = joinpath(root, "backend")
stage = get(ENV, "PSFA_STAGE_DIR", joinpath(root, "packaging", "release-stage"))
output = joinpath(stage, "runtime", "psfa-sysimage.dll")
mkpath(dirname(output))
# COPT 保持运行时加载，镜像不嵌入外部 SDK 或开发机许可。
packages = [:Oxygen, :JSON3, :HTTP, :Dates, :JuMP, :CSV, :DataFrames, :SHA,
    :HiGHS, :SQLite, :DBInterface, :Tables, :Clustering, :BlackBoxOptim, :TimeZones]
PackageCompiler.create_sysimage(packages;
    project=backend, sysimage_path=output, cpu_target="generic",
    precompile_execution_file=joinpath(@__DIR__, "precompile-workload.jl"),
    sysimage_build_args=`--threads=1`, incremental=true)
