using JSON3, CSV, DataFrames, Statistics
include("utils/server_utils.jl")
include("utils/fitting_curve.jl")
include("services/fitting_service.jl")

wind_path = joinpath(homedir(), "Desktop", "风机拟合测试数据.csv")
if isfile(wind_path)
    df = CSV.read(wind_path, DataFrame)
    r = fit_wind_curve(df.wind_speed, df.power)
    println("WIND params: ", r["params"])
    println(r["formulaText"])
    println("WIND stats: ", r["stats"])
else
    println("skip wind, no file: ", wind_path)
end

pv_path = joinpath(homedir(), "Desktop", "光伏拟合测试数据.csv")
if isfile(pv_path)
    df = CSV.read(pv_path, DataFrame)
    r = fit_pv_curve(df.irradiance, df.temperature, df.power)
    println("PV formula: ", r["formulaText"])
    println("PV stats: ", r["stats"])
end
println("OK")
