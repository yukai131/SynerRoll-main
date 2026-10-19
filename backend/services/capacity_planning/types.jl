"""容量规划内部错误；`code` 用于向 API 返回稳定、可判断的失败原因。"""
struct CapacityPlanningError <: Exception
    code::String
    message::String
end

Base.showerror(io::IO, error::CapacityPlanningError) = print(io, "$(error.code): $(error.message)")

Base.@kwdef struct EvaluationOptions
    layer_id::String = "1"
    persist_timeseries::Bool = true
    generate_code::Bool = true
    stop_on_infeasible::Bool = true
    scenario_time_limit_seconds::Float64 = 60.0
end

Base.@kwdef struct EvaluationResult
    feasible::Bool
    operating_objective::Float64
    metrics::Dict{String,Float64}
    scenario_metrics::Vector{Dict{String,Any}}
    error_code::Union{Nothing,String} = nothing
    error_message::Union{Nothing,String} = nothing
end

abstract type AbstractEconomicEvaluator end

Base.@kwdef struct EconomicEvaluationInput
    capacities::Dict{String,Float64}
    units::Dict{String,String}
    simulation::EvaluationResult
    config::Dict{String,Any}
    # 后验运行成本评价（timeseries-operating-cost-v1）所需：
    # 候选工作目录（内含 scenarios/<id>/timeseries.db）与候选快照
    layer_id::String = "1"
    work_dir::Union{Nothing,String} = nothing
    project_snapshot::Union{Nothing,AbstractDict} = nothing
    # C-401 第二增量：组件容量变更方式（componentId => new/replace/retire），
    # 生命周期经济按变更方式计算处置回收与新增投资
    change_kinds::Dict{String,String} = Dict{String,String}()
    # C-401 第二增量：变更前原始容量（componentId => kW），退役/替换的处置回收依赖
    original_capacities::Dict{String,Float64} = Dict{String,Float64}()
end

Base.@kwdef struct EconomicEvaluationResult
    fitness::Float64
    breakdown::Dict{String,Any}
    indicators::Dict{String,Union{Float64,Nothing}}
    warnings::Vector{String}
    evaluator_version::String
end

struct PlanningCancelled <: Exception
    message::String
end

Base.showerror(io::IO, error::PlanningCancelled) = print(io, error.message)
