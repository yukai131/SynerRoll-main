"""
    lifecycle_economics.jl — C-403 生命周期经济（全投资口径）

公式来源（用户提供的两份基准表，见 docs/c403-生命周期经济实现记录.md）：
- 经济性评价/经济性评价/全投资内部收益率20240726.xlsx
  * 项目投资现金流量表：价税分离、调整所得税 = EBIT × 税率（三免三减半）、
    末年回收固定资产余值 + 回收流动资金、投资增值税留抵结转。
  * 总成本费用估算表：经营成本 = 总成本 − 折旧 − 无形/其他资产摊销 − 财务费用。
  * 计算 sheet：年折旧 = 原值 × (1 − 残值率) / 折旧年限。
- 经济性评价/经济性评价/投资测算.xlsx
  * 设备级：设备投资 = 装机 × 单位造价；投资增值税 = 设备投资 × 建设期增值税率；
    流动资金 = 装机 × 流动资金率（元/容量单位，随 kW/kWh/kg 口径）；人员费 = 人数 × 单人年度薪酬。

金额约定：内部一律用万元（与 Excel 基准表一致），边界处换算为元（×10^4）。
"""

# ── 财务参数 ──────────────────────────────────────────────

Base.@kwdef struct LifecycleFinancialParams
    operation_years::Int = 20                    # 运营期（年），IRR 表示例为 20
    discount_rate::Float64 = 0.08                # 基准折现率（NPV/折现回收期/LCOE）
    income_tax_rate::Float64 = 0.25              # 企业所得税率（行业通用法定税率；可配置覆盖）
    tax_holiday_years::Int = 3                   # 三免：运营期第 1..N 年免税
    tax_half_years::Int = 3                      # 三减半：紧随其后的 N 年减半征收
    output_vat_rate::Float64 = 0.13              # 销项增值税率（IRR 表收入税金表）
    input_vat_rate::Float64 = 0.13               # 成本进项增值税率（IRR 表收入税金表）
    construction_vat_rate::Float64 = 0.10        # 建设投资增值税率（投资测算.xlsx F4）
    surcharge_rate::Float64 = 0.12               # 营业税金及附加 = 增值税 × 12%
                                                 # （城建 7% + 教育费附加 5%，IRR 表口径；
                                                 #   投资测算.xlsx 为 6%，此处以 IRR 表为准，
                                                 #   差异已在开发记录中标注，可用 config 覆盖）
    working_capital_rate::Float64 = 30.0         # 流动资金 = 容量 × 30 元/容量单位
                                                 # （kW 设备为 元/kW；ES 为 元/kWh；HS 为 元/kg；
                                                 #   HGRID 为 元/(kg/h)。Excel 基准为 元/kW，
                                                 #   非 kW 设备按同一数值、各自单位解释）
    salvage_rate_default::Float64 = 0.05         # 默认残值率（IRR 表：发电/储能设备 5%）
    input_vat_deductible_ratio::Float64 = 1.0    # 经营成本中可抵扣进项的比例（近似口径）
    staff_salary_wan::Float64 = 15.0             # 单人年度薪酬（万元/人·年，两表一致）
    # ── B9–B12 工程化补充 ──
    fixed_om_ratio::Float64 = 0.0                # 固定运维：CAPEX原值 × 比例 / 年
    fixed_om_wan::Float64 = 0.0                  # 固定运维定额（万元/年）
    subsidy_yuan_per_kwh::Float64 = 0.0          # 电量补贴（元/kWh 年上网电量）
    capacity_compensation_yuan_per_kw_year::Float64 = 0.0  # 容量补偿（元/kW·年，仅 kW 口径设备）
    replace_cycle_years::Int = 0                 # 0=按 depreciation_years；>0 强制替换周期
    irr_penalty_weight::Float64 = 1.0            # IRR 约束惩罚权重（× 差额 × CAPEX）
end

"""设备类型 → 残值率覆盖表（IRR 表：电解槽、储氢罐 3%，其余 5%）。"""
const LIFECYCLE_SALVAGE_OVERRIDES = Dict{String,Float64}(
    "ET" => 0.03,   # 电解槽（组件 key 为 ET）
    "HS" => 0.03,   # 储氢（罐）
)

"""组件类型 → 默认容量单位（规划变量未给出 unit 时的回退）。"""
const LIFECYCLE_DEFAULT_CAPACITY_UNIT = Dict{String,String}(
    "WT" => "kW", "PV" => "kW", "CP" => "kW", "GP" => "kW", "CHP" => "kW",
    "HYDRO" => "kW", "PS" => "kW", "ET" => "kW", "GRID" => "kW",
    "ES" => "kWh", "FS" => "kWh", "CS" => "kWh",
    "HS" => "kg", "HLOAD" => "kg",
    "HGRID" => "kg/h",
)

# ── CAPEX 项 ──────────────────────────────────────────────

Base.@kwdef struct LifecycleCapexItem
    node_id::String
    name::String
    comp_type::String
    capacity::Float64
    capacity_unit::String                   # kW / kWh / kg / kg/h
    unit_capex_yuan_per_unit::Float64       # commonEconomicParams.initial_cost（元/容量单位）
    capex_wan::Float64                      # 新增投资原值（万元）；退役型为 0
    existing_capacity::Float64              # 现有容量（候选前）
    existing_capex_wan::Float64             # 现有设备原值（万元）= 现有容量 × 单价
    change_kind::String                     # new / replace / retire（C-401 第二增量）
    depreciation_years::Int                 # depreciation_year，缺省 life_year
    salvage_rate::Float64
end

"""
税率/比例类字段：数学口径为小数（0.10 = 10%），但 UI 与历史配置可能写百分数（10 = 10%）。
`working_capital_rate`（元/容量单位）、`staff_salary_wan`、年限、权重等不在此列。
"""
const LIFECYCLE_PERCENT_RATE_FIELDS = (
    :income_tax_rate,
    :output_vat_rate,
    :input_vat_rate,
    :construction_vat_rate,
    :surcharge_rate,
    :salvage_rate_default,
    :fixed_om_ratio,
    :discount_rate,
)

"""
    normalize_lifecycle_rate(field, value) -> Float64

把可能来自 UI 的百分数归一成小数。合法小数税率 < 1；≥ 1 视为百分数并 /100
（UI 上 1 表示 1%，不能当成 100%）。残值率额外夹紧到 [0, 1]，避免负折旧。
"""
function normalize_lifecycle_rate(field::Symbol, value::Real)::Float64
    v = Float64(value)
    if field in LIFECYCLE_PERCENT_RATE_FIELDS && v >= 1.0
        v /= 100.0
    end
    if field === :salvage_rate_default
        v = clamp(v, 0.0, 1.0)
    elseif field in LIFECYCLE_PERCENT_RATE_FIELDS
        v = max(v, 0.0)
    end
    return v
end

"""
    lifecycle_params_from_config(config) -> LifecycleFinancialParams

economics config 中 `lifecycle` 子字典可覆盖任一参数字段（snake_case 键名）。
税率/比例字段自动识别百分数写法并归一为小数（见 `normalize_lifecycle_rate`）。
"""
function lifecycle_params_from_config(config::AbstractDict)::LifecycleFinancialParams
    overrides = get(config, "lifecycle", Dict{String,Any}())
    kwargs = Dict{Symbol,Any}()
    defaults = LifecycleFinancialParams()
    for field in fieldnames(LifecycleFinancialParams)
        haskey(overrides, string(field)) || continue
        raw = overrides[string(field)]
        raw isa Real || continue
        default_value = getfield(defaults, field)
        if default_value isa Integer
            kwargs[field] = round(Int, raw)
        elseif field in LIFECYCLE_PERCENT_RATE_FIELDS
            kwargs[field] = normalize_lifecycle_rate(field, raw)
        else
            kwargs[field] = Float64(raw)
        end
    end
    return LifecycleFinancialParams(; kwargs...)
end

"""
    extract_lifecycle_capex(project_snapshot, capacities, original_capacities, change_kinds, units, params)
    -> (items::Vector{LifecycleCapexItem}, warnings::Vector{String})

从候选快照的 `commonEconomicParams` 提取设备级 CAPEX：
- new：新增投资 = 候选容量 × initial_cost（元/容量单位）；
- replace（C-401②）：新设备全额投资，旧设备残值处置回收在第 0 年（existing_capex × 残值率）；
- retire（C-401②）：无新增投资，退役部分（现有 − 候选）残值回收在第 0 年。

容量单位取自规划变量 `units[node_id]`（kW / kWh / kg / kg/h），缺失时按组件类型回退。
`initial_cost` 解释为「元/容量单位」，与该单位一一对应。
负荷（ELoad/HLoad/QLoad）、电网（GRID）与总线组件不产生 CAPEX。
缺 initial_cost / capacity 的组件记入 warnings，不抛错（C-001：不填占位数字）。
"""
function extract_lifecycle_capex(
    project_snapshot::AbstractDict,
    capacities::Dict{String,Float64},
    original_capacities::Dict{String,Float64},
    change_kinds::Dict{String,String},
    units::Dict{String,String},
    params::LifecycleFinancialParams,
)
    workspace = get(project_snapshot, "workspace", Dict{String,Any}())
    nodes = Any[]
    for canvas in get(workspace, "canvases", [])
        string(get(canvas, "id", "")) == string(get(workspace, "activeCanvasId", "")) || continue
        append!(nodes, get(canvas, "nodes", []))
    end
    component_dicts, _, _ = _parse_component_nodes(nodes)

    items = LifecycleCapexItem[]
    warnings = String[]
    for comp_dict in component_dicts
        comp_type = string(get(comp_dict, "type", ""))
        comp_type in ("ELOAD", "HLOAD", "QLOAD", "GRID", "BUS") && continue
        node_id = string(get(comp_dict, "nodeId", ""))
        name = string(get(comp_dict, "name", comp_type))
        costs = get(comp_dict, "costs", Dict{String,Float64}())

        capacity = get(capacities, node_id, NaN)
        if !isfinite(capacity) || capacity < 0
            push!(warnings, "组件 $(name) 无有效容量，CAPEX 按 0 处理")
            continue
        end
        unit_capex = get(costs, "initial_cost", NaN)
        if !isfinite(unit_capex) || unit_capex <= 0
            push!(warnings, "组件 $(name) 缺 initial_cost，CAPEX 按 0 处理")
            continue
        end

        capacity_unit = get(units, node_id, "")
        if isempty(capacity_unit)
            capacity_unit = get(LIFECYCLE_DEFAULT_CAPACITY_UNIT, comp_type, "kW")
        end

        dep_years_f = get(costs, "depreciation_year", get(costs, "life_year", NaN))
        dep_years = isfinite(dep_years_f) && dep_years_f > 0 ? max(1, round(Int, dep_years_f)) : params.operation_years
        salvage_rate = get(LIFECYCLE_SALVAGE_OVERRIDES, comp_type, params.salvage_rate_default)
        change_kind = string(get(change_kinds, node_id, "new"))
        existing_capacity = get(original_capacities, node_id, 0.0)
        existing_capex_wan = existing_capacity / 1.0e4 * unit_capex
        # 退役型无新增投资；new/replace 按候选容量全额计新设备投资
        new_capex_wan = change_kind == "retire" ? 0.0 : capacity / 1.0e4 * unit_capex

        push!(items, LifecycleCapexItem(
            node_id=node_id,
            name=name,
            comp_type=comp_type,
            capacity=capacity,
            capacity_unit=capacity_unit,
            unit_capex_yuan_per_unit=unit_capex,
            capex_wan=new_capex_wan,
            existing_capacity=existing_capacity,
            existing_capex_wan=existing_capex_wan,
            change_kind=change_kind,
            depreciation_years=dep_years,
            salvage_rate=salvage_rate,
        ))
    end
    return (items=items, warnings=warnings)
end

# ── 核心计算 ──────────────────────────────────────────────

"""
    _npv_at(cashflows, rate) -> Float64

NPV = Σ cf_t / (1+r)^t，t 从 0（建设期末/运营期前）起。
"""
function _npv_at(cashflows::AbstractVector{Float64}, rate::Float64)::Float64
    acc = 0.0
    discount = 1.0
    for cf in cashflows
        acc += cf / discount
        discount *= (1.0 + rate)
    end
    return acc
end

"""
    _irr_bisect(cashflows) -> (value::Union{Float64,Nothing}, reason::String)

在 [-0.99, 10.0] 内二分求解 NPV(r)=0（对齐 Excel IRR 的迭代法）。
无解 / 不变号时返回 (nothing, reason)，不填占位数字（C-001 口径）。
"""
function _irr_bisect(cashflows::AbstractVector{Float64})
    any(!isfinite, cashflows) && return (value=nothing, reason="现金流含非有限值")
    lo, hi = -0.99, 10.0
    f_lo = _npv_at(cashflows, lo)
    f_hi = _npv_at(cashflows, hi)
    if f_lo * f_hi > 0
        return (value=nothing, reason="现金流在 [-99%, 1000%] 内不变号，IRR 不存在或无意义")
    end
    for _ in 1:200
        mid = 0.5 * (lo + hi)
        f_mid = _npv_at(cashflows, mid)
        abs(f_mid) < 1.0e-10 && return (value=mid, reason="ok")
        if f_lo * f_mid <= 0
            hi = mid
            f_hi = f_mid
        else
            lo = mid
            f_lo = f_mid
        end
    end
    return (value=0.5 * (lo + hi), reason="ok")
end

"""累计现金流首次转正的年份（年内线性插值）；全程为负则返回 nothing。"""
function _payback_years(cashflows::AbstractVector{Float64})
    cumulative = 0.0
    for (t, cf) in enumerate(cashflows)
        # t=1 为建设期年末（现金流序列第 0 年），历年第 t-1 年末
        previous = cumulative
        cumulative += cf
        if cumulative >= 0.0 && previous < 0.0
            return (t - 2) + (-previous) / cf
        end
    end
    return nothing
end

"""折现累计现金流首次转正的年份；全程为负则返回 nothing。"""
function _discounted_payback_years(cashflows::AbstractVector{Float64}, rate::Float64)
    cumulative = 0.0
    for (t, cf) in enumerate(cashflows)
        previous = cumulative
        cumulative += cf / (1.0 + rate)^(t - 1)
        if cumulative >= 0.0 && previous < 0.0
            return (t - 2) + (-previous) / (cf / (1.0 + rate)^(t - 1))
        end
    end
    return nothing
end

"""
    evaluate_lifecycle(; capex_items, annual_revenue_yuan, annual_opex_yuan,
        annual_energy_kwh, params) -> NamedTuple

全投资口径项目投资现金流（万元）：

- 年 0（建设期）：流出 = Σ新增原值 + 建设投资增值税 + 流动资金；替换/退役旧设备残值处置回收计入流入
  （流动资金按容量×30 元/容量单位，单位随设备 kW/kWh/kg/kg/h）
- 年 t 流入 = 营业收入(不含税) + 销项税；末年另加 回收固定资产余值 + 回收流动资金
- 年 t 流出 = 经营成本 + 成本进项税 + 应缴增值税 + 营业税金及附加
- 应缴增值税 = max(0, 销项 − 进项 − 留抵)，留抵期初为建设投资增值税（投资测算口径）
- 调整所得税 = max(0, EBIT) × 有效税率；EBIT = 收入(不含税) − 经营成本 − 附加税 − 折旧
- 有效税率：前 tax_holiday_years 年 0，随后 tax_half_years 年减半，之后全率
- LCOE = 折现成本合计 / 折现电量（缺 annual_energy_kwh 时返回 nothing）

annual_revenue_yuan 视为含税收益（运行成本服务售电收益口径），annual_opex_yuan 视为
不含税经营成本（含松弛惩罚，已在开发记录中注明近似）。
"""
function evaluate_lifecycle(;
    capex_items::Vector{LifecycleCapexItem},
    annual_revenue_yuan::Float64,
    annual_opex_yuan::Float64,
    annual_energy_kwh::Union{Float64,Nothing} = nothing,
    params::LifecycleFinancialParams = LifecycleFinancialParams(),
)
    warnings = String[]
    n = params.operation_years

    capex_total = sum(item.capex_wan for item in capex_items; init=0.0)
    construction_vat = capex_total * params.construction_vat_rate
    # 流动资金：容量 × 单价率，单价按各自容量单位解释（kW/kWh/kg/kg/h）
    working_capital = sum(item.capacity * params.working_capital_rate for item in capex_items; init=0.0) /
                      1.0e4
    salvage_total = sum(item.capex_wan * item.salvage_rate for item in capex_items; init=0.0)
    # C-401② 第 0 年处置回收：替换=旧设备残值，退役=退役部分残值
    disposal_recovery = sum(
        item.change_kind == "replace" ? item.existing_capex_wan * item.salvage_rate :
        item.change_kind == "retire" ?
        max(0.0, item.existing_capacity - item.capacity) / 1.0e4 *
        item.unit_capex_yuan_per_unit * item.salvage_rate : 0.0
        for item in capex_items; init=0.0)
    capex_total <= 0 && push!(warnings, "CAPEX 合计为 0，生命周期指标无意义")

    # 折旧计划（万元/年）：各设备在自身折旧年限内直线折旧
    depreciation = zeros(Float64, n)
    for item in capex_items
        item.depreciation_years <= 0 && continue
        annual_dep = item.capex_wan * (1.0 - item.salvage_rate) / item.depreciation_years
        for t in 1:min(item.depreciation_years, n)
            depreciation[t] += annual_dep
        end
    end

    # B9 固定运维：CAPEX 比例 + 定额（并入年经营成本）
    # 容量补偿仅统计 kW 口径设备（电力装机），kg / kg/h / kWh 不并入 元/kW·年
    capacity_power_kw = sum(
        item.capacity for item in capex_items if item.capacity_unit == "kW"; init=0.0)
    fixed_om_wan = capex_total * params.fixed_om_ratio + params.fixed_om_wan
    # B11 补贴 / 容量补偿（年收益，万元）
    subsidy_wan = 0.0
    if annual_energy_kwh !== nothing && annual_energy_kwh > 0 && params.subsidy_yuan_per_kwh > 0
        subsidy_wan = annual_energy_kwh * params.subsidy_yuan_per_kwh / 1.0e4
    end
    capacity_comp_wan = capacity_power_kw * params.capacity_compensation_yuan_per_kw_year / 1.0e4

    # 价税分离（万元）
    revenue_incl_vat = (annual_revenue_yuan / 1.0e4) + subsidy_wan + capacity_comp_wan
    revenue_excl_vat = revenue_incl_vat / (1.0 + params.output_vat_rate)
    output_vat = revenue_incl_vat - revenue_excl_vat
    opex_wan = annual_opex_yuan / 1.0e4 + fixed_om_wan
    input_vat = opex_wan * params.input_vat_rate * params.input_vat_deductible_ratio

    # B10 设备替换重购：在寿命整数倍年末追加设备投资（不再叠加建设税；折旧不重提，口径偏保守）
    replace_outflow = zeros(Float64, n)
    for item in capex_items
        item.change_kind == "retire" && continue
        item.capex_wan <= 0 && continue
        life = params.replace_cycle_years > 0 ? params.replace_cycle_years : item.depreciation_years
        life <= 0 && continue
        t = life
        while t < n
            replace_outflow[t] += item.capex_wan
            t += life
        end
    end

    revenue_incl_vat <= 0 && push!(warnings, "年化收益为 0，IRR/NPV/回收期为负或无解属预期")

    pre_tax = zeros(Float64, n + 1)
    after_tax = zeros(Float64, n + 1)
    discounted_cost = capex_total + construction_vat + working_capital - disposal_recovery
    vat_credit = construction_vat
    adjusted_taxes = zeros(Float64, n)

    # 年 0：建设投资 + 增值税 + 流动资金，减处置回收（替换/退役的旧设备残值）
    pre_tax[1] = -(capex_total + construction_vat + working_capital) + disposal_recovery
    after_tax[1] = pre_tax[1]

    for t in 1:n
        vat_payable = max(0.0, output_vat - input_vat - vat_credit)
        vat_credit = max(0.0, vat_credit + input_vat - output_vat)
        surcharge = vat_payable * params.surcharge_rate

        ebit = revenue_excl_vat - opex_wan - surcharge - depreciation[t]
        effective_rate = t <= params.tax_holiday_years ? 0.0 :
                         t <= params.tax_holiday_years + params.tax_half_years ?
                         params.income_tax_rate * 0.5 : params.income_tax_rate
        adjusted_tax = max(0.0, ebit) * effective_rate
        adjusted_taxes[t] = adjusted_tax

        inflow = revenue_excl_vat + output_vat
        outflow = opex_wan + input_vat + vat_payable + surcharge + replace_outflow[t]
        if t == n
            inflow += salvage_total + working_capital
        end
        pre_tax[t + 1] = inflow - outflow
        after_tax[t + 1] = pre_tax[t + 1] - adjusted_tax

        discounted_cost += (outflow + adjusted_tax) / (1.0 + params.discount_rate)^t
    end

    npv_pre_tax = _npv_at(pre_tax, params.discount_rate)
    npv_after_tax = _npv_at(after_tax, params.discount_rate)
    irr_pre_tax = _irr_bisect(pre_tax)
    irr_after_tax = _irr_bisect(after_tax)
    payback = _payback_years(after_tax)
    discounted_payback = _discounted_payback_years(after_tax, params.discount_rate)

    lcoe = nothing
    if annual_energy_kwh !== nothing && annual_energy_kwh > 0
        energy_wan_kwh = annual_energy_kwh / 1.0e4
        discounted_energy = sum(energy_wan_kwh / (1.0 + params.discount_rate)^t for t in 1:n)
        discounted_energy > 0 && (lcoe = discounted_cost / discounted_energy)  # 元/kWh
    else
        push!(warnings, "缺少年度发电量，LCOE 未计算")
    end

    return (
        pre_tax_cashflow=pre_tax,
        after_tax_cashflow=after_tax,
        npv_pre_tax_wan=npv_pre_tax,
        npv_after_tax_wan=npv_after_tax,
        irr_pre_tax=irr_pre_tax.value,
        irr_pre_tax_reason=irr_pre_tax.reason,
        irr_after_tax=irr_after_tax.value,
        irr_after_tax_reason=irr_after_tax.reason,
        payback_years=payback,
        discounted_payback_years=discounted_payback,
        lcoe_yuan_per_kwh=lcoe,
        total_capex_wan=capex_total,
        construction_vat_wan=construction_vat,
        working_capital_wan=working_capital,
        disposal_recovery_wan=disposal_recovery,
        discounted_cost_wan=discounted_cost,
        annual_depreciation_wan=sum(depreciation; init=0.0) / n,
        annual_adjusted_tax_wan=sum(adjusted_taxes; init=0.0) / n,
        annual_fixed_om_wan=fixed_om_wan,
        annual_subsidy_wan=subsidy_wan,
        annual_capacity_compensation_wan=capacity_comp_wan,
        replace_capex_total_wan=sum(replace_outflow; init=0.0),
        warnings=warnings,
    )
end
