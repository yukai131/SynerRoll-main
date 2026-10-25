struct PlanningTimeLimit <: Exception end

mutable struct PlanningBudget
    started_ns::UInt64
    compiled_ns::UInt64
    limit_seconds::Float64
end
const ACTIVE_PLANNING_BUDGET = Ref{Union{Nothing,PlanningBudget}}(nothing)

function start_planning_budget!(seconds::Real)
    Base.cumulative_compile_timing(true)
    ACTIVE_PLANNING_BUDGET[] = PlanningBudget(time_ns(), first(Base.cumulative_compile_time_ns()), Float64(seconds))
end

function planning_elapsed_seconds()
    budget = ACTIVE_PLANNING_BUDGET[]
    budget === nothing && return 0.0
    # 固定随包 Julia 版本；总编译时间包含重编译，不能再减一次 recomp_time。
    compiled = first(Base.cumulative_compile_time_ns()) - budget.compiled_ns
    elapsed = time_ns() - budget.started_ns
    return max(0.0, (Float64(elapsed) - Float64(compiled)) / 1e9)
end

function planning_remaining_seconds()
    budget = ACTIVE_PLANNING_BUDGET[]
    budget === nothing && return Inf
    remaining = budget.limit_seconds - planning_elapsed_seconds()
    remaining > 0 || throw(PlanningTimeLimit())
    return remaining
end

function finish_planning_budget!()
    if ACTIVE_PLANNING_BUDGET[] !== nothing
        ACTIVE_PLANNING_BUDGET[] = nothing
        Base.cumulative_compile_timing(false)
    end
end
