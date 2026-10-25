ENV["SYNERROLL_SIMULATION_WORKER"] = "1"
include("server.jl")

length(ARGS) == 1 || error("simulation_worker requires a taskId")
task_id = ARGS[1]
task = JSON3.read(read(joinpath(TASKS_DATA_ROOT, task_id, "request.json"), String), Dict{String,Any})
execute_simulation_task(task_id, task)
