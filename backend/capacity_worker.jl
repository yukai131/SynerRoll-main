# A planning worker owns all of its solver resources. The HTTP parent can stop
# this process even while optimize! is blocked in native code.
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
include("server.jl")

function capacity_worker_main(planning_id::String)
    planning_task_dir(planning_id) # validate before writing any task files
    ctx = PlanningContext(Channel{Symbol}(1), nothing)
    try
        perf_start("planning", planning_id; meta=Dict{String,Any}(
            "pid" => getpid(),
            "julia" => string(VERSION),
            "perfEnabled" => PERF_ENABLED,
        ))
        perf_record("planning", planning_id, "worker_ready", 0.0, 0, 0, 0, "ok",
            Dict{String,Any}("pid" => getpid()))
        run_capacity_optimization!(planning_id, ctx)
    catch error
        if error isa PlanningTimeLimit
            try
                complete_planning_from_evaluations!(planning_id;
                    stop_reason="已达到规划总时限（不含启动和编译），返回已完整评价候选中的最佳方案。")
            catch
                set_planning_status!(planning_id, "failed"; error_code="PLANNING_TIME_LIMIT",
                    error_message="已达到规划总时限（不含启动和编译）且尚无完整可行候选。")
            end
        elseif error isa PlanningCancelled
            set_planning_status!(planning_id, "cancelled")
        else
            code = error isa CapacityPlanningError ? error.code : "PLANNING_FAILED"
            message = error isa CapacityPlanningError ? error.message : sprint(showerror, error)
            set_planning_status!(planning_id, "failed"; error_code=code, error_message=message)
            @error "capacity worker failed" planning_id exception=(error, catch_backtrace())
        end
    finally
        finish_planning_budget!()
        perf_finish("planning", planning_id)
    end
end

length(ARGS) == 1 || error("capacity_worker requires a planningId")
capacity_worker_main(ARGS[1])
