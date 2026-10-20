
files = [
  "C:/Users/Administrator/Desktop/SynerRoll-main/backend/utils/model_utils.jl",
  "C:/Users/Administrator/Desktop/SynerRoll-main/backend/components/wind_turbine/model-common.jl",
  "C:/Users/Administrator/Desktop/SynerRoll-main/backend/components/electricity_storage/model-common.jl",
  "C:/Users/Administrator/Desktop/SynerRoll-main/backend/components/coal_power/model-common.jl",
  "C:/Users/Administrator/Desktop/SynerRoll-main/backend/components/coal_power/flexibility.jl",
  "C:/Users/Administrator/Desktop/SynerRoll-main/types/boundary.ts",
]
# only julia files for Meta.parseall
for f in files[1:end-1]
  src = read(f, String)
  ex = Meta.parseall(src)
  if ex.head == :error || ex.head == :incomplete
    println("FAIL ", f, " ", ex)
    exit(1)
  end
  println("OK ", f)
end
println("all julia files parse OK")
