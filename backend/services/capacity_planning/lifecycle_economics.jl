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
    流动资金 = 装机 × 流动资金率（元/kW）；人员费 = 人数 × 单人年度薪酬。

金额约定：内部一律用万元（与 Excel 基准表一致），边界处换算为元（×10^4）。
"""

# ── 财务参数 ──────────────────────────────────────────────

Base.@kwdef struct LifecycleFinancialParams
    operation_years::Int = 20                    # 运营期（年），IRR 表示例为 20
    discount_rate::Float64 = 0.08                # 基准折现率（NPV/折现回收期/LCOE）
    income_tax_rate::Float64 = 0.15              # 企业所得税率（两表均为 15%）
    tax_holiday_years::Int = 3                   # 三免：运营期第 1..N 年免税
    tax_half_years::Int = 3                      # 三减半：紧随其后的 N 年减半征收
    output_vat_rate::Float64 = 0.13              # 销项增值税率（IRR 表收入税金表）
    input_vat_rate::Float64 = 0.13               # 成本进项增值税率（IRR 表收入税金表）
    construction_vat_rate::Float64 = 0.10        # 建设投资增值税率（投资测算.xlsx F4）
    surcharge_rate::Float64 = 0.12               # 营业税金及附加 = 增值税 × 12%
                                                 # （城建 7% + 教育费附加 5%，IRR 表口径；
                                                 #   投资测算.xlsx 为 6%，此处以 IRR 表为准，
                                                 #   差异已在开发记录中标注，可用 config 覆盖）
    working_capital_rate::Float64 = 30.0         # 流动资金 = 装机(kW) × 30 元/kW（IRR 表 K 列）
    salvage_rate_default::Float64 = 0.05         # 默认残值率（IRR 表：发电/储能设备 5%）
    input_vat_deductible_ratio::Float64 = 1.0    # 经营成本中可抵扣进项的比例（近似口径）
    staff_salary_wan::Float64 = 15.0             # 单人年度薪酬（万元/人·年，两表一致）
end

"""设备类型 → 残值率覆盖表（IRR 表：电解槽、储氢罐 3%，其余 5%）。"""
const LIFECYCLE_SALVAGE_OVERRIDES = Dict{String,Float64}(
    "ELY" => 0.03,   # 电解槽
    "HS" => 0.03,    # 储氢（罐）
)

# ── CAPEX 项 ──────────────────────────────────────────────

Base.@kwdef struct LifecycleCapexItem
    node_id::String
    name::String
    comp_type::String
    capacity_kw::Float64
    unit_capex_yuan_per_kw::Float64   # commonEconomicParams.initial_cost
    capex_wan::Float64                # 新增投资原值（万元）；退役型为 0
    existing_capacity_kw::Float64     # 现有容量（候选前）
    existing_capex_wan::Float64       # 现有设备原值（万元）= 现有容量 × 单价
    change_kind::String               # new / replace / retire（C-401 第二增量）
    depreciation_years::Int           # depreciation_year，缺省 life_year
    salvage_rate::Float64
end

"""
    lifecycle_params_from_config(config) -> LifecycleFinancialParams

economics config 中 `lifecycle` 子字典可覆盖任一参数字段（snake_case 键名）。
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
        kwargs[field] = default_value isa Integer ? round(Int, raw) : Float64(raw)
    end
    return LifecycleFinancialParams(; kwargs...)
end

"""
    extract_lifecycle_capex(project_snapshot, capacities, original_capacities, change_kinds, units, params)
    -> (items::Vector{LifecycleCapexItem}, warnings::Vector{String})

从候选快照的 `commonEconomicParams` 提取设备级 CAPEX：
- new：新增投资 = 候选容量 × initial_cost；
- replace（C-401②）：新设备全额投资，旧设备残值处置回收在第 0 年（existing_capex × 残值率）；
- retire（C-401②）：无新增投资，退役部分（现有 − 候选）残值回收在第 0 年。
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

        capacity_kw = get(capacities, node_id, NaN)
        if !isfinite(capacity_kw) || capacity_kw < 0
            push!(warnings, "组件 $(name) 无有效容量，CAPEX 按 0 处理")
            continue
        end
        unit_capex = get(costs, "initial_cost", NaN)
        if !isfinite(unit_capex) || unit_capex <= 0
            push!(warnings, "组件 $(name) 缺 initial_cost，CAPEX 按 0 处理")
            continue
        end

        dep_years_f = get(costs, "depreciation_year", get(costs, "life_year", NaN))
        dep_years = isfinite(dep_years_f) && dep_years_f > 0 ? max(1, round(Int, dep_years_f)) : params.operation_years
        salvage_rate = get(LIFECYCLE_SALVAGE_OVERRIDES, comp_type, params.salvage_rate_default)
        change_kind = string(get(change_kinds, node_id, "new"))
        existing_capacity_kw = get(original_capacities, node_id, 0.0)
        existing_capex_wan = existing_capacity_kw / 1.0e4 * unit_capex
        # 退役型无新增投资；new/replace 按候选容量全额计新设备投资
        new_capex_wan = change_kind == "retire" ? 0.0 : capacity_kw / 1.0e4 * unit_capex

        push!(items, LifecycleCapexItem(
            node_id=node_id,
            name=name,
            comp_type=comp_type,
            capacity_kw=capacity_kw,
            unit_capex_yuan_per_kw=unit_capex,
            capex_wan=new_capex_wan,
            existing_capacity_kw=existing_capacity_kw,
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
    working_capital = sum(item.capacity_kw for item in capex_items; init=0.0) *
                      params.working_capital_rate / 1.0e4
    salvage_total = sum(item.capex_wan * item.salvage_rate for item in capex_items; init=0.0)
    # C-401② 第 0 年处置回收：替换=旧设备残值，退役=退役部分残值
    disposal_recovery = sum(
        item.change_kind == "replace" ? item.existing_capex_wan * item.salvage_rate :
        item.change_kind == "retire" ?
        max(0.0, item.existing_capacity_kw - item.capacity_kw) / 1.0e4 *
        item.unit_capex_yuan_per_kw * item.salvage_rate : 0.0
        for item in capex_items; init=0.0)
    capex_total <= 0 && push!(warnings, "CAPEX 合计为 0，生命周期指标无意义")

    # 折旧计划（万元/年）：各设备在自身折旧年限内直线折旧
    depreciation = zeros(Float64, n)
    for item in capex_items
        annual_dep = item.capex_wan * (1.0 - item.salvage_rate) / item.depreciation_years
        for t in 1:min(item.depreciation_years, n)
            depreciation[t] += annual_dep
        end
    end

    # 价税分离（万元）
    revenue_incl_vat = annual_revenue_yuan / 1.0e4
    revenue_excl_vat = revenue_incl_vat / (1.0 + params.output_vat_rate)
    output_vat = revenue_incl_vat - revenue_excl_vat
    opex_wan = annual_opex_yuan / 1.0e4
    input_vat = opex_wan * params.input_vat_rate * params.input_vat_deductible_ratio

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
        outflow = opex_wan + input_vat + vat_payable + surcharge
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
        warnings=warnings,
    )
end
