# economy_calculator.jl — 经济性评价纯数值计算
#
# 职责：
#   - 提供纯数值成本公式（不依赖 JuMP、不依赖数据库）
#   - 被评价服务层调用（后验计算）
#   - 公式与 model-base.jl 中的目标项保持同一口径
#
# 单位约定（与 config/component-library.json 一致）：
#   - om_cost / cut_cost / adjust_cost / buy_price / sell_price：元/kWh（在参数解析时 × time_step_hours）
#   - on_off_cost：元/次（启停事件，不按步长缩放）
#   - slack penalty：元/单位松弛量

# ─── 数据结构 ────────────────────────────────────────────────────────────────

"""单项成本计算结果"""
struct CostItem
    component_id::String       # 组件标识 (如 "node-7e8a")
    component_type::String     # 组件类型 (如 "CP")
    component_name::String     # 组件名称
    cost_type::String          # 成本类型 (如 "om_cost")
    cost_label::String         # 显示标签
    layer_id::String           # 时层ID
    value::Float64             # 成本值（元），可为负（售电收益）
    in_objective::Bool         # 是否进入目标函数
    is_slack::Bool             # 是否为松弛变量成本
    is_revenue::Bool           # 是否为收益项（负成本）
    formula::String            # 计算公式说明
    objective_flag::String     # 目标函数开关名（如 "om_objective_on"），松弛项为空
end

# 兼容旧构造：默认补 formula / objective_flag
function CostItem(
    component_id::String, component_type::String, component_name::String,
    cost_type::String, cost_label::String, layer_id::String, value::Float64,
    in_objective::Bool, is_slack::Bool, is_revenue::Bool;
    formula::String="", objective_flag::String="",
)
    return CostItem(
        component_id, component_type, component_name,
        cost_type, cost_label, layer_id, value,
        in_objective, is_slack, is_revenue,
        formula, objective_flag,
    )
end

# ─── 成本标签映射 ────────────────────────────────────────────────────────────

const COST_LABELS = Dict{String,String}(
    "om_cost"          => "运维成本",
    "fuel_cost"        => "燃料成本",
    "on_off_cost"      => "启停成本",
    "adjust_cost"      => "调整成本",
    "cut_cost"         => "弃风/弃光成本",
    "purchase_cost"    => "购电成本",
    "sell_revenue"     => "售电收益",
    "shortage_penalty" => "短缺惩罚",
    "excess_penalty"   => "过剩惩罚",
)

cost_label(cost_type::String) = get(COST_LABELS, cost_type, cost_type)

# ─── 公式说明（前端展示 / 文档对齐）──────────────────────────────────────────

const COST_FORMULAS = Dict{String,String}(
    "om_cost"          => "Σ(出力 × 运维成本率 × Δt)",
    "fuel_cost"        => "Σ(燃料投入 × 燃料价格 × Δt)",
    "on_off_cost"      => "启停次数 × 单次启停成本",
    "adjust_cost"      => "Σ|实际出力 - 计划出力| × 调整成本率 × Δt",
    "cut_cost"         => "Σ(弃风/弃光功率 × 成本率 × Δt)",
    "purchase_cost"    => "Σ(购电功率 × 购电价 × Δt)",
    "sell_revenue"     => "-Σ(售电功率 × 售电价 × Δt)",
    "shortage_penalty" => "Σ(短缺量 × 松弛惩罚系数)",
    "excess_penalty"   => "Σ(过剩量 × 松弛惩罚系数)",
)

cost_formula(cost_type::String) = get(COST_FORMULAS, cost_type, cost_type)

# ─── 启停状态工具 ────────────────────────────────────────────────────────────

"""
    derive_on_off_status(power_values) -> Vector{Float64}

从出力序列推导 0/1 启停状态。
功率 > 功率阈值视为开机。用于后验计算：
结果库通常只持久化出力，不持久化 γ 启停变量。
"""
function derive_on_off_status(power_values::Vector{Float64}; eps::Float64=1e-6)
    return Float64[p > eps ? 1.0 : 0.0 for p in power_values]
end

"""
    count_on_off_transitions(status_vector) -> Int

统计启停状态跳变次数（0↔1 各计一次，不区分启动/停机）。
输入须为 0/1 序列；连续量请先 derive_on_off_status。
"""
function count_on_off_transitions(status_vector::Vector{Float64})
    length(status_vector) < 2 && return 0
    transitions = 0
    for i in 2:length(status_vector)
        if status_vector[i] != status_vector[i-1]
            transitions += 1
        end
    end
    return transitions
end

# ─── 煤电 (CP) / 热电机组成本计算 ────────────────────────────────────────────

"""
    calc_cp_om_cost(power_values, om_cost_rate) -> Float64

运维成本 = Σ(出力) × 成本率。
om_cost_rate 已在参数解析时乘过 time_step_hours，单位为 元/kW·步。
"""
function calc_cp_om_cost(power_values::Vector{Float64}, om_cost_rate::Float64)
    return sum(power_values) * om_cost_rate
end

"""
    calc_cp_on_off_cost(status_vector, on_off_cost_rate) -> Float64

启停成本 = 状态跳变次数 × 单次成本。
on_off_cost_rate 单位为 元/次，不按时间步长缩放。
"""
function calc_cp_on_off_cost(status_vector::Vector{Float64}, on_off_cost_rate::Float64)
    return Float64(count_on_off_transitions(status_vector)) * on_off_cost_rate
end

"""
    calc_cp_adjust_cost(actual_power, planned_power, adjust_cost_rate) -> Float64

调整成本 = Σ|实际-计划| × 成本率。
adjust_cost_rate 已含 time_step_hours。
"""
function calc_cp_adjust_cost(actual_power::Vector{Float64}, planned_power::Vector{Float64}, adjust_cost_rate::Float64)
    n = min(length(actual_power), length(planned_power))
    total = 0.0
    for i in 1:n
        total += abs(actual_power[i] - planned_power[i])
    end
    return total * adjust_cost_rate
end

"""从 layer_settings 解析目标函数开关，默认 true"""
function objective_enabled(params, flag::String; default::Bool=true)
    layer_settings = get(params, :layer_settings, Dict())
    objectives = get(layer_settings, "objectives", Dict())
    return Bool(get(objectives, flag, default))
end

"""
    calc_fuel_cost(fuel_values, fuel_price) -> Float64

燃料成本 = Σ(燃料投入功率 × 价格)。
fuel_price 可为与 fuel_values 等长的向量（已×Δt 的 元/kW·步），
或标量（元/kW·步）。fuel_values 单位为 kW 燃料（F = E/η）。
"""
function calc_fuel_cost(fuel_values::Vector{Float64}, fuel_price::Union{Vector{Float64},Float64})
    if fuel_price isa Float64
        return sum(fuel_values) * fuel_price
    end
    n = min(length(fuel_values), length(fuel_price))
    total = 0.0
    for i in 1:n
        total += fuel_values[i] * fuel_price[i]
    end
    return total
end
"""
    calc_thermal_costs(comp_type, component_id, component_name, power_values, params, layer_id;
                       status_vector=nothing, planned_power=nothing) -> Vector{CostItem}

煤电/气电/热电联产/电解槽/水电等机组成本：
  - om_cost：Σ(出力 × 率)
  - on_off_cost：启停次数 × 单次成本（有状态序列时）
  - adjust_cost：Σ|实际-计划| × 率（有计划序列时）
"""
function calc_thermal_costs(
    comp_type::String, component_id::String, component_name::String,
    power_values::Vector{Float64}, params, layer_id::String;
    status_vector::Union{Vector{Float64},Nothing}=nothing,
    planned_power::Union{Vector{Float64},Nothing}=nothing,
    fuel_values::Union{Vector{Float64},Nothing}=nothing,
    fuel_price::Union{Vector{Float64},Float64,Nothing}=nothing,
)
    items = CostItem[]

    # 运维成本
    om_on = objective_enabled(params, "om_objective_on")
    om_val = calc_cp_om_cost(power_values, params.om_cost)
    push!(items, CostItem(
        component_id, comp_type, component_name, "om_cost", cost_label("om_cost"),
        layer_id, om_val, om_on, false, false;
        formula=cost_formula("om_cost"), objective_flag="om_objective_on",
    ))

    # 燃料成本：Σ(F × 价)；价为元/kW·步（已×Δt）或元/kWh 标量
    if fuel_values !== nothing && fuel_price !== nothing
        fuel_on = objective_enabled(params, "fuel_objective_on")
        fuel_val = calc_fuel_cost(fuel_values, fuel_price)
        push!(items, CostItem(
            component_id, comp_type, component_name, "fuel_cost", cost_label("fuel_cost"),
            layer_id, fuel_val, fuel_on, false, false;
            formula=cost_formula("fuel_cost"), objective_flag="fuel_objective_on",
        ))
    end

    # 启停成本：状态序列优先；若无则从出力推导
    if status_vector === nothing && !isempty(power_values)
        status_vector = derive_on_off_status(power_values)
    end
    if status_vector !== nothing && length(status_vector) >= 2
        on_off_on = objective_enabled(params, "on_off_objective_on")
        on_off_val = calc_cp_on_off_cost(status_vector, params.on_off_cost)
        push!(items, CostItem(
            component_id, comp_type, component_name, "on_off_cost", cost_label("on_off_cost"),
            layer_id, on_off_val, on_off_on, false, false;
            formula=cost_formula("on_off_cost"), objective_flag="on_off_objective_on",
        ))
    end

    # 调整成本（需计划曲线）
    if planned_power !== nothing
        adjust_on = objective_enabled(params, "adjust_objective_on")
        adjust_val = calc_cp_adjust_cost(power_values, planned_power, params.adjust_cost)
        push!(items, CostItem(
            component_id, comp_type, component_name, "adjust_cost", cost_label("adjust_cost"),
            layer_id, adjust_val, adjust_on, false, false;
            formula=cost_formula("adjust_cost"), objective_flag="adjust_objective_on",
        ))
    end

    return items
end

# 兼容旧名
function calc_cp_costs(
    component_id::String, component_name::String,
    power_values::Vector{Float64}, params, layer_id::String;
    status_vector::Union{Vector{Float64},Nothing}=nothing,
    planned_power::Union{Vector{Float64},Nothing}=nothing,
    fuel_values::Union{Vector{Float64},Nothing}=nothing,
    fuel_price::Union{Vector{Float64},Float64,Nothing}=nothing,
)
    return calc_thermal_costs("CP", component_id, component_name, power_values, params, layer_id;
        status_vector=status_vector, planned_power=planned_power,
        fuel_values=fuel_values, fuel_price=fuel_price)
end

function calc_thermal_gen_costs(
    comp_type::String, component_id::String, component_name::String,
    power_values::Vector{Float64}, params, layer_id::String;
    status_vector::Union{Vector{Float64},Nothing}=nothing,
    planned_power::Union{Vector{Float64},Nothing}=nothing,
)
    return calc_thermal_costs(comp_type, component_id, component_name, power_values, params, layer_id;
        status_vector=status_vector, planned_power=planned_power)
end

# ─── 风电 (WT) / 光伏 (PV) 成本计算 ──────────────────────────────────────────

"""
    calc_renewable_costs(comp_type, ..., power_values, cut_values, params, layer_id)

  - om_cost：Σ(出力 × 率)
  - cut_cost：Σ(弃风/弃光 × 率)
"""
function calc_renewable_costs(
    comp_type::String, component_id::String, component_name::String,
    power_values::Vector{Float64}, cut_values::Vector{Float64},
    params, layer_id::String,
)
    items = CostItem[]

    om_on = objective_enabled(params, "om_objective_on")
    om_val = sum(power_values) * params.om_cost
    push!(items, CostItem(
        component_id, comp_type, component_name, "om_cost", cost_label("om_cost"),
        layer_id, om_val, om_on, false, false;
        formula=cost_formula("om_cost"), objective_flag="om_objective_on",
    ))

    cut_on = objective_enabled(params, "cut_objective_on")
    cut_val = sum(cut_values) * params.cut_cost
    push!(items, CostItem(
        component_id, comp_type, component_name, "cut_cost", cost_label("cut_cost"),
        layer_id, cut_val, cut_on, false, false;
        formula=cost_formula("cut_cost"), objective_flag="cut_objective_on",
    ))

    return items
end

# 兼容旧名
function calc_wt_om_cost(power_values::Vector{Float64}, om_cost_rate::Float64)
    return sum(power_values) * om_cost_rate
end

function calc_wt_cut_cost(cut_power::Vector{Float64}, cut_cost_rate::Float64)
    return sum(cut_power) * cut_cost_rate
end

# ─── 储能 (ES/HS/FS/CS/PS) 成本计算 ──────────────────────────────────────────

"""
    calc_storage_costs(...)

  - om_cost：Σ(充电 + 放电) × 率
  - adjust_cost：Σ(|Δ充| + |Δ放|) × 率（有计划时）
"""
function calc_storage_costs(
    comp_type::String, component_id::String, component_name::String,
    input_power::Vector{Float64}, output_power::Vector{Float64},
    params, layer_id::String;
    planned_input::Union{Vector{Float64},Nothing}=nothing,
    planned_output::Union{Vector{Float64},Nothing}=nothing,
)
    items = CostItem[]

    om_on = objective_enabled(params, "om_objective_on")
    n = min(length(input_power), length(output_power))
    throughput = 0.0
    for i in 1:n
        throughput += (input_power[i] + output_power[i])
    end
    om_val = throughput * params.om_cost
    push!(items, CostItem(
        component_id, comp_type, component_name, "om_cost", cost_label("om_cost"),
        layer_id, om_val, om_on, false, false;
        formula="Σ(充电功率+放电功率) × 运维成本率 × Δt", objective_flag="om_objective_on",
    ))

    if planned_input !== nothing && planned_output !== nothing
        adjust_on = objective_enabled(params, "adjust_objective_on")
        m = min(length(input_power), length(planned_input))
        total = 0.0
        for i in 1:m
            total += abs(input_power[i] - planned_input[i]) + abs(output_power[i] - planned_output[i])
        end
        adjust_val = total * params.adjust_cost
        push!(items, CostItem(
            component_id, comp_type, component_name, "adjust_cost", cost_label("adjust_cost"),
            layer_id, adjust_val, adjust_on, false, false;
            formula=cost_formula("adjust_cost"), objective_flag="adjust_objective_on",
        ))
    end

    return items
end

function calc_es_om_cost(input_power::Vector{Float64}, output_power::Vector{Float64}, om_cost_rate::Float64)
    n = min(length(input_power), length(output_power))
    total = 0.0
    for i in 1:n
        total += (input_power[i] + output_power[i])
    end
    return total * om_cost_rate
end

# ─── 电网 (GRID) 成本计算 ────────────────────────────────────────────────────

"""
    calc_grid_costs(...)

  - purchase_cost：Σ(购电 × 买价)，正成本
  - sell_revenue：-Σ(售电 × 卖价)，负成本（收益）
"""
function calc_grid_costs(
    component_id::String, component_name::String,
    sell_power::Vector{Float64}, buy_power::Vector{Float64},
    params, layer_id::String,
)
    items = CostItem[]
    exchange_on = objective_enabled(params, "exchange_objective_on")

    purchase_val = calc_fuel_cost(buy_power, params.buy_price)  # 同构：Σ(P×价)
    push!(items, CostItem(
        component_id, "GRID", component_name, "purchase_cost", cost_label("purchase_cost"),
        layer_id, purchase_val, exchange_on, false, false;
        formula=cost_formula("purchase_cost"), objective_flag="exchange_objective_on",
    ))

    sell_val = -calc_fuel_cost(sell_power, params.sell_price)
    push!(items, CostItem(
        component_id, "GRID", component_name, "sell_revenue", cost_label("sell_revenue"),
        layer_id, sell_val, exchange_on, false, true;
        formula=cost_formula("sell_revenue"), objective_flag="exchange_objective_on",
    ))

    return items
end

function calc_grid_purchase_cost(purchase_power::Vector{Float64}, buy_price::Float64)
    return sum(purchase_power) * buy_price
end

function calc_grid_sell_revenue(sell_power::Vector{Float64}, sell_price::Float64)
    return -sum(sell_power) * sell_price
end

# ─── 松弛变量成本 ────────────────────────────────────────────────────────────

"""
    calc_slack_penalty(...)

松弛惩罚单独列出，不进入目标函数展示（目标值已扣除松弛）。
"""
function calc_slack_penalty(
    bus_id::String, bus_name::String,
    shortage::Vector{Float64}, excess::Vector{Float64},
    penalty_rate::Float64, layer_id::String,
)
    items = CostItem[]

    shortage_val = sum(shortage) * penalty_rate
    if shortage_val > 0.0
        push!(items, CostItem(
            bus_id, "BUS", bus_name, "shortage_penalty", cost_label("shortage_penalty"),
            layer_id, shortage_val, false, true, false;
            formula=cost_formula("shortage_penalty"), objective_flag="",
        ))
    end

    excess_val = sum(excess) * penalty_rate
    if excess_val > 0.0
        push!(items, CostItem(
            bus_id, "BUS", bus_name, "excess_penalty", cost_label("excess_penalty"),
            layer_id, excess_val, false, true, false;
            formula=cost_formula("excess_penalty"), objective_flag="",
        ))
    end

    return items
end

# ─── 统一入口 ────────────────────────────────────────────────────────────────

"""
    calc_component_cost(comp_type, component_id, component_name, power_data, params, layer_id)

按组件类型分发成本计算。
power_data 约定键：
  - 火电/水电：power[, status][, planned_power]
  - 风光：power, cut
  - 储能：input, output[, planned_input, planned_output]
  - 电网：buy, sell
"""
function calc_component_cost(
    comp_type::String, component_id::String, component_name::String,
    power_data::Dict{String,Vector{Float64}}, params, layer_id::String,
)
    if comp_type in ("CP", "GP", "CHP", "ET", "HYDRO")
        return calc_thermal_costs(
            comp_type, component_id, component_name,
            get(power_data, "power", Float64[]), params, layer_id;
            status_vector=get(power_data, "status", nothing),
            planned_power=get(power_data, "planned_power", nothing),
            fuel_values=get(power_data, "fuel", nothing),
            fuel_price=haskey(params, :fuel_price) ? params.fuel_price : nothing,
        )
    elseif comp_type in ("WT", "PV")
        return calc_renewable_costs(
            comp_type, component_id, component_name,
            get(power_data, "power", Float64[]), get(power_data, "cut", Float64[]),
            params, layer_id,
        )
    elseif comp_type in ("ES", "HS", "FS", "CS", "PS")
        return calc_storage_costs(
            comp_type, component_id, component_name,
            get(power_data, "input", Float64[]), get(power_data, "output", Float64[]),
            params, layer_id;
            planned_input=get(power_data, "planned_input", nothing),
            planned_output=get(power_data, "planned_output", nothing),
        )
    elseif comp_type == "GRID"
        return calc_grid_costs(
            component_id, component_name,
            get(power_data, "sell", Float64[]), get(power_data, "buy", Float64[]),
            params, layer_id,
        )
    else
        @warn "未知组件类型: $(comp_type)，跳过经济性计算"
        return CostItem[]
    end
end
