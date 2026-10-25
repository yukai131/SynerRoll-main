# economy_evaluation_service.jl — 经济性评价服务
#
# 职责：
#   - 从 timeseries.db 读取覆盖模式的物理量数据（支持仿真进行中部分数据）
#   - 调用 economy_calculator.jl 计算各项成本
#   - 汇总分层、分设备、分成本项结果
#   - 输出日均 / 月均估算 / 年化估算等派生指标
#
# 动态评价：任务未完成时也可调用，按 [sim_start, covered_end) 截取已有数据。

using Dates

# ─── 数据结构 ────────────────────────────────────────────────────────────────

"""时层经济性汇总"""
struct LayerEconomySummary
    layer_id::String
    layer_name::String
    total_cost::Float64                         # 总成本（含收益项负值，不含松弛）
    cost_breakdown::Dict{String, Float64}
    component_breakdown::Dict{String, Float64}
    objective_components::Vector{String}
    objective_value::Float64                    # 进入目标函数的项之和（不含松弛）
    slack_penalty::Float64
    has_slack::Bool
    revenue_items::Dict{String, Float64}
end

"""完整经济性评价结果（内部）"""
struct EconomyEvaluationResult
    task_id::String
    evaluation_time::String
    layers::Vector{LayerEconomySummary}
    all_cost_items::Vector{CostItem}
    objective_composition::Dict{String, Dict{String, Float64}}
end

# ─── 辅助：项目解析 ──────────────────────────────────────────────────────────

function _safe_get_ts_values(db_path::String, data_key::String, sim_start::String, sim_end::Union{String,Nothing})::Vector{Float64}
    ts = get_ts(db_path, data_key)
    ts === nothing && return Float64[]
    filtered = truncate_timeseries(ts, sim_start, sim_end)
    return filtered.values
end

function _get_layers(project_json::Dict)
    layer_config = get(project_json, "layerConfig", get(project_json, "layers", Dict()))
    layers_array = get(layer_config, "layers", [])
    if isempty(layers_array)
        layers = Dict{String,Any}[]
        for (lid, ldata) in layer_config
            if ldata isa Dict
                push!(layers, merge(ldata, Dict("id" => lid)))
            end
        end
        return sort(layers; by=x -> parse(Int, string(get(x, "id", "1"))))
    end
    return sort(collect(layers_array); by=x -> parse(Int, string(get(x, "id", "1"))))
end

_get_algorithms(project_json::Dict) = get(project_json, "algorithm", Dict{String,Any}())

function _get_nodes(project_json::Dict)
    workspace = get(project_json, "workspace", Dict())
    canvases = get(workspace, "canvases", [])
    nodes = []
    for canvas in canvases
        append!(nodes, get(canvas, "nodes", []))
    end
    return nodes
end

function _flatten_enabled(d::Dict{String,Any})
    result = Dict{String,Any}()
    for (k, v) in d
        if v isa Dict && haskey(v, "enabled")
            result[k] = v["enabled"]
        else
            result[k] = v
        end
    end
    return result
end

function node_id_to_code_from_node(node_id::String)::String
    prefix = "node-"
    if startswith(node_id, prefix)
        return node_id[length(prefix)+1:min(end, length(prefix)+4)]
    end
    return node_id[1:min(end, 4)]
end

function _parse_component_nodes(nodes::Vector)
    component_dicts = Dict{String,Any}[]
    node_id_to_code = Dict{String,String}()
    node_id_to_name = Dict{String,String}()

    for node in nodes
        is_bus_node(node) && continue
        data = get(node, "data", Dict())
        comp_key = get(data, "componentKey", "")
        isempty(comp_key) && continue

        node_id = get(node, "id", "")
        label = get(data, "label", comp_key)
        business = get(data, "business", Dict())
        code = node_id_to_code_from_node(node_id)

        node_id_to_code[node_id] = code
        node_id_to_name[node_id] = label

        paras = Dict{String,Any}()
        costs = Dict{String,Float64}()
        eco_params = get(business, "commonEconomicParams", get(business, "economicParams", Dict()))
        tech_params = get(business, "commonTechParams", get(business, "techParams", Dict()))
        for (k, v) in tech_params
            v isa Real && (paras[string(k)] = v)
        end
        for (k, v) in eco_params
            v isa Real && (costs[string(k)] = Float64(v))
        end

        raw_layer_configs = get(business, "layerConfigs", Dict{String,Any}())
        layer_configs = Dict{String,Any}()
        for (layer_id, layer_data) in raw_layer_configs
            layer_configs[layer_id] = Dict{String,Any}(
                "status" => get(layer_data, "status", "stand_alone"),
                "paras" => get(layer_data, "techParams", Dict{String,Any}()),
                "costs" => get(layer_data, "economicParams", Dict{String,Any}()),
                "constraints" => _flatten_enabled(get(layer_data, "constraints", Dict{String,Any}())),
                "objectives" => _flatten_enabled(get(layer_data, "objectives", Dict{String,Any}())),
            )
        end

        boundary_ids = String[string(id) for id in get(business, "boundaryIds", [])]

        push!(component_dicts, Dict{String,Any}(
            "type" => comp_key,
            "name" => label,
            "code" => code,
            "paras" => paras,
            "costs" => costs,
            "layer" => layer_configs,
            "boundaryIds" => boundary_ids,
            "nodeId" => node_id,
        ))
    end

    return component_dicts, node_id_to_code, node_id_to_name
end

# ─── 物理量读取 ──────────────────────────────────────────────────────────────

"""
    load_component_data(store_path, comp_code, comp_type, layer_id, sim_start, sim_end)

从覆盖模式 timeseries.db 读取组件物理量。

启停状态：结果库通常只存出力（E_*）与辅助量（F_*），不存 γ 启停变量。
  - 不把 F_* 当状态（F 是连续燃料/辅助功率，会造成伪跳变）
  - 有独立 status 序列则用之；否则由出力 derive_on_off_status 推导
"""
function load_component_data(store_path::String, comp_code::String, comp_type::String, layer_id::String, sim_start::String, sim_end::Union{String,Nothing})::Dict{String,Vector{Float64}}
    data = Dict{String,Vector{Float64}}()

    if comp_type == "CP"
        data["power"] = _safe_get_ts_values(store_path, "CP|E_CP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["fuel"] = _safe_get_ts_values(store_path, "CP|F_CP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "WT"
        data["power"] = _safe_get_ts_values(store_path, "WT|E_WT_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        # ResultBinding 落库 remark=power；兼容旧测试 remark=cut
        data["cut"] = _safe_get_ts_values(store_path, "WT|E_WT_cut_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        if isempty(data["cut"])
            data["cut"] = _safe_get_ts_values(store_path, "WT|E_WT_cut_$(comp_code)|cut#$(layer_id)", sim_start, sim_end)
        end
    elseif comp_type == "PV"
        data["power"] = _safe_get_ts_values(store_path, "PV|E_PV_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["cut"] = _safe_get_ts_values(store_path, "PV|E_PV_cut_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        if isempty(data["cut"])
            data["cut"] = _safe_get_ts_values(store_path, "PV|E_PV_cut_$(comp_code)|cut#$(layer_id)", sim_start, sim_end)
        end
    elseif comp_type == "ES"
        data["energy"] = _safe_get_ts_values(store_path, "ES|E_ES_$(comp_code)|energy#$(layer_id)", sim_start, sim_end)
        data["input"] = _safe_get_ts_values(store_path, "ES|E_ES_in_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["output"] = _safe_get_ts_values(store_path, "ES|E_ES_out_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "GP"
        data["power"] = _safe_get_ts_values(store_path, "GP|E_GP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["fuel"] = _safe_get_ts_values(store_path, "GP|F_GP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "CHP"
        data["power"] = _safe_get_ts_values(store_path, "CHP|E_CHP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["fuel"] = _safe_get_ts_values(store_path, "CHP|F_CHP_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "ET"
        data["power"] = _safe_get_ts_values(store_path, "ET|E_ET_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "GRID"
        # E_GRID_in = 上送（售电）；E_GRID_out = 购入（购电）
        data["sell"] = _safe_get_ts_values(store_path, "GRID|E_GRID_in_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["buy"] = _safe_get_ts_values(store_path, "GRID|E_GRID_out_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "HGRID"
        # H_HGRID_in = 上送（售氢）；H_HGRID_out = 购入（购氢）
        data["sell"] = _safe_get_ts_values(store_path, "HGRID|H_HGRID_in_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["buy"] = _safe_get_ts_values(store_path, "HGRID|H_HGRID_out_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type in ("HS", "FS", "CS", "PS")
        data["energy"] = _safe_get_ts_values(store_path, "$(comp_type)|E_$(comp_type)_$(comp_code)|energy#$(layer_id)", sim_start, sim_end)
        data["input"] = _safe_get_ts_values(store_path, "$(comp_type)|E_$(comp_type)_in_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
        data["output"] = _safe_get_ts_values(store_path, "$(comp_type)|E_$(comp_type)_out_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    elseif comp_type == "HYDRO"
        data["power"] = _safe_get_ts_values(store_path, "HYDRO|E_HYDRO_$(comp_code)|power#$(layer_id)", sim_start, sim_end)
    end

    return data
end

"""
    load_boundary_price_series(store_path, boundary_ids, sim_start, sim_end) -> Union{Vector{Float64},Nothing}

从任务时序库读取 fuel_price 边界的 planned 曲线，按仿真范围截断。
兼容历史 `price` 含义。
"""
function load_boundary_price_series(
    store_path::String,
    boundary_ids::Vector,
    sim_start::String,
    sim_end::Union{String,Nothing},
)
    isempty(boundary_ids) && return nothing
    for bid in boundary_ids
        bid_s = string(bid)
        try
            pair = query_ts(store_path; source_id=bid_s, remark="planned")
            ts = pair isa Tuple ? pair[1] : pair
            label = pair isa Tuple ? pair[2] : ""
            ts === nothing && continue
            parsed = try
                parse_ts_label(string(label))["var_name"]
            catch
                ""
            end
            # 仅接受燃料价格类边界（兼容历史 price）
            if parsed != "fuel_price" && parsed != "price"
                continue
            end
            filtered = truncate_timeseries(ts, sim_start, sim_end)
            return Float64.(filtered.values)
        catch
            continue
        end
    end
    return nothing
end

"""
    load_boundary_price_series_by_meaning(store_path, boundary_ids, meaning, sim_start, sim_end)

按物理含义精确匹配价格边界（var_name == meaning），兼容历史 `price`。
"""
function load_boundary_price_series_by_meaning(
    store_path::String,
    boundary_ids::Vector,
    meaning::String,
    sim_start::String,
    sim_end::Union{String,Nothing};
    legacy_meaning::Union{String,Nothing}=nothing,
)
    isempty(boundary_ids) && return nothing
    for bid in boundary_ids
        bid_s = string(bid)
        try
            pair = query_ts(store_path; source_id=bid_s, remark="planned")
            ts = pair isa Tuple ? pair[1] : pair
            label = pair isa Tuple ? pair[2] : ""
            ts === nothing && continue
            parsed = try
                parse_ts_label(string(label))["var_name"]
            catch
                ""
            end
            if parsed != meaning && !(legacy_meaning !== nothing && parsed == legacy_meaning)
                continue
            end
            filtered = truncate_timeseries(ts, sim_start, sim_end)
            return Float64.(filtered.values)
        catch
            continue
        end
    end
    return nothing
end
"""读取松弛变量并生成 CostItem"""
function load_slack_data(store_path::String, layer_id::String, shortage_penalty_rate::Float64, excess_penalty_rate::Float64, sim_start::String, sim_end::Union{String,Nothing})::Vector{CostItem}
    items = CostItem[]

    start_min = time_label_to_minutes(sim_start)
    end_min = sim_end !== nothing ? time_label_to_minutes(sim_end) : nothing

    store = get_store(store_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT id, source_id, var_name, remark, layer_id FROM time_series_meta WHERE var_name LIKE '%SHORTAGE%' OR var_name LIKE '%EXCESS%'")

        isempty(rows[1]) && return items

        for i in 1:length(rows[1])
            series_layer_id = String(rows[5][i])
            series_layer_id != layer_id && continue

            series_id = rows[1][i]
            var_name_str = String(rows[3][i])

            data_rows = _query(store.db,
                "SELECT ts, value FROM time_series_data WHERE series_id=?", [series_id])
            isempty(data_rows[1]) && continue

            values = Float64[]
            for (ts_label, val) in zip(data_rows[1], data_rows[2])
                m = time_label_to_minutes(ts_label)
                m >= start_min && (end_min === nothing || m < end_min) && push!(values, Float64(val))
            end

            if occursin("SHORTAGE", var_name_str)
                raw = sum(values)
                # 滤除求解器浮点噪声，避免 hasSlack 误报能量不平衡
                if raw > 0.0 && is_meaningful_slack(raw)
                    bus_code = replace(var_name_str, "E_SHORTAGE_" => "", "H_SHORTAGE_" => "", "Q_SHORTAGE_" => "")
                    push!(items, CostItem(
                        "BUS_$(bus_code)", "BUS", "总线($(bus_code))",
                        "shortage_penalty", cost_label("shortage_penalty"),
                        layer_id, raw * shortage_penalty_rate, false, true, false;
                        formula=cost_formula("shortage_penalty"), objective_flag="",
                    ))
                end
            elseif occursin("EXCESS", var_name_str)
                raw = sum(values)
                if raw > 0.0 && is_meaningful_slack(raw)
                    bus_code = replace(var_name_str, "E_EXCESS_" => "", "H_EXCESS_" => "", "Q_EXCESS_" => "")
                    push!(items, CostItem(
                        "BUS_$(bus_code)", "BUS", "总线($(bus_code))",
                        "excess_penalty", cost_label("excess_penalty"),
                        layer_id, raw * excess_penalty_rate, false, true, false;
                        formula=cost_formula("excess_penalty"), objective_flag="",
                    ))
                end
            end
        end
    end

    return items
end

# ─── 参数解析 ────────────────────────────────────────────────────────────────

"""
    resolve_component_params_economy_with_step(comp_dict, layer_id, time_step_hours)

经济性评价参数解析。与 model-common.jl 口径一致：
  - 能量类成本率（元/kWh）× time_step_hours
  - on_off_cost（元/次）不缩放
"""
function resolve_component_params_economy_with_step(comp_dict::Dict{String,Any}, layer_id::String, time_step_hours::Float64)
    comp_type = comp_dict["type"]
    costs = get(comp_dict, "costs", Dict{String,Any}())
    layer_configs = get(comp_dict, "layer", Dict{String,Any}())
    layer_cfg = get(layer_configs, layer_id, Dict{String,Any}())

    layer_objectives = get(layer_cfg, "objectives", Dict{String,Any}())

    layer_settings = Dict(
        "status" => get(layer_cfg, "status", "stand_alone"),
        "objectives" => layer_objectives,
        "paras" => get(layer_cfg, "paras", Dict{String,Any}()),
        "costs" => get(layer_cfg, "costs", Dict{String,Any}()),
        "constraints" => get(layer_cfg, "constraints", Dict{String,Any}()),
    )

    layer_costs = get(layer_cfg, "costs", Dict{String,Any}())

    if comp_type in ("CP", "GP", "CHP", "ET", "HYDRO")
        return (
            om_cost = get(costs, "om_cost", 0.0) * time_step_hours,
            on_off_cost = get(costs, "on_off_cost", 0.0),  # 元/次，不缩放
            adjust_cost = get(layer_costs, "adjust_cost", get(costs, "adjust_cost", 0.0)) * time_step_hours,
            fuel_price = get(costs, "fuel_price", 0.0) * time_step_hours,
            layer_settings = layer_settings,
        )
    elseif comp_type in ("WT", "PV")
        return (
            om_cost = get(costs, "om_cost", 0.0) * time_step_hours,
            cut_cost = get(costs, "cut_cost", 0.0) * time_step_hours,
            layer_settings = layer_settings,
        )
    elseif comp_type in ("ES", "HS", "FS", "CS", "PS")
        return (
            om_cost = get(costs, "om_cost", 0.0) * time_step_hours,
            adjust_cost = get(layer_costs, "adjust_cost", get(costs, "adjust_cost", 0.0)) * time_step_hours,
            layer_settings = layer_settings,
        )
    elseif comp_type == "GRID"
        return (
            buy_price = get(costs, "buy_price", 0.0) * time_step_hours,
            sell_price = get(costs, "sell_price", 0.0) * time_step_hours,
            layer_settings = layer_settings,
        )
    elseif comp_type == "HGRID"
        return (
            buy_price = get(costs, "buy_price", 0.0) * time_step_hours,
            sell_price = get(costs, "sell_price", 0.0) * time_step_hours,
            layer_settings = layer_settings,
        )
    else
        return (
            om_cost = get(costs, "om_cost", 0.0) * time_step_hours,
            layer_settings = layer_settings,
        )
    end
end

# 兼容旧名
function resolve_component_params_economy(comp_dict::Dict{String,Any}, layer_id::String)
    return resolve_component_params_economy_with_step(comp_dict, layer_id, 1.0)
end

function _parse_duration_hours(s::String)
    s = strip(s)
    if endswith(s, "h")
        return parse(Float64, s[1:end-1])
    elseif endswith(s, "m")
        return parse(Float64, s[1:end-1]) / 60.0
    elseif endswith(s, "s")
        return parse(Float64, s[1:end-1]) / 3600.0
    else
        return parse(Float64, s)
    end
end

# ─── 单层成本项收集（仿真经济与容量规划共用）────────────────────────────────

"""
    collect_layer_cost_items(db_path, component_dicts, layer_id, time_step_hours,
                             sim_start, sim_end, shortage_penalty, excess_penalty) -> NamedTuple

从 timeseries.db 汇总单层成本项。`evaluate_task_economy` 与
`evaluate_scenario_operating_cost` 共用。

返回：
- `cost_items`：含松弛惩罚的 CostItem 列表
- `energy_kwh`：发电类组件正功率电量（LCOE 分母）
- `tech`：技术指标累计量
"""
function collect_layer_cost_items(
    db_path::String,
    component_dicts::Vector,
    layer_id::String,
    time_step_hours::Float64,
    sim_start::String,
    sim_end::Union{String,Nothing},
    shortage_penalty::Float64,
    excess_penalty::Float64,
)
    cost_items = CostItem[]
    energy_kwh = 0.0
    re_used = 0.0
    re_avail = 0.0
    hydro_gen = 0.0
    thermal_gen = 0.0
    buy_e = 0.0
    tech_slots = 0

    for comp_dict in component_dicts
        comp_type = string(comp_dict["type"])
        comp_code = string(comp_dict["code"])
        comp_name = string(get(comp_dict, "name", comp_type))
        comp_node_id = string(get(comp_dict, "nodeId", ""))
        comp_type in ("ELOAD", "HLOAD", "QLOAD") && continue

        power_data = load_component_data(db_path, comp_code, comp_type, layer_id, sim_start, sim_end)
        has_data = false
        for series in values(power_data)
            if !isempty(series)
                has_data = true
                break
            end
        end
        !has_data && continue

        if comp_type in ("WT", "PV")
            p = max(sum(get(power_data, "power", Float64[]); init=0.0), 0.0)
            c = max(sum(get(power_data, "cut", Float64[]); init=0.0), 0.0)
            re_used += p
            re_avail += p + c
            tech_slots = max(tech_slots, length(get(power_data, "power", Float64[])), length(get(power_data, "cut", Float64[])))
        elseif comp_type == "HYDRO"
            hydro_gen += max(sum(get(power_data, "power", Float64[]); init=0.0), 0.0)
            tech_slots = max(tech_slots, length(get(power_data, "power", Float64[])))
        elseif comp_type in ("CP", "GP", "CHP")
            thermal_gen += max(sum(get(power_data, "power", Float64[]); init=0.0), 0.0)
            tech_slots = max(tech_slots, length(get(power_data, "power", Float64[])))
        elseif comp_type == "GRID"
            buy_e += max(sum(get(power_data, "buy", Float64[]); init=0.0), 0.0)
            tech_slots = max(tech_slots, length(get(power_data, "buy", Float64[])), length(get(power_data, "sell", Float64[])))
        end

        if comp_type in ("CP", "WT", "PV", "GP", "CHP", "ET", "HYDRO")
            series = get(power_data, "power", Float64[])
            energy_kwh += sum(max.(series, 0.0)) * time_step_hours
        end

        params = resolve_component_params_economy_with_step(comp_dict, layer_id, time_step_hours)
        boundary_ids = get(comp_dict, "boundaryIds", String[])

        if !haskey(power_data, "fuel") || isempty(power_data["fuel"])
            pw = get(power_data, "power", Float64[])
            paras = get(comp_dict, "paras", Dict{String,Any}())
            eff = get(paras, "η", get(paras, "η_e", get(paras, "efficiency", nothing)))
            if eff isa Real && Float64(eff) > 1.0e-9 && !isempty(pw)
                power_data["fuel"] = Float64[p / Float64(eff) for p in pw]
            end
        end

        # 价格：按物理含义匹配（与仿真建模一致）
        if comp_type in ("CP", "GP", "CHP")
            bprice = load_boundary_price_series(db_path, boundary_ids, sim_start, sim_end)
            if bprice !== nothing && !isempty(bprice)
                npts = max(length(get(power_data, "power", Float64[])), length(bprice), 1)
                params = merge(params, (fuel_price=scale_price_series(bprice, time_step_hours, npts),))
            end
        elseif comp_type in ("GRID", "HGRID")
            buy_meaning = comp_type == "HGRID" ? "h2_buy_price" : "buy_price"
            sell_meaning = comp_type == "HGRID" ? "h2_sell_price" : "sell_price"
            buy_series = load_boundary_price_series_by_meaning(
                db_path, boundary_ids, buy_meaning, sim_start, sim_end; legacy_meaning="price")
            sell_series = load_boundary_price_series_by_meaning(
                db_path, boundary_ids, sell_meaning, sim_start, sim_end; legacy_meaning="price")
            npts = max(length(get(power_data, "buy", Float64[])), length(get(power_data, "sell", Float64[])), 1)
            buy_vec = buy_series === nothing ? fill(params.buy_price, npts) : scale_price_series(buy_series, time_step_hours, npts)
            sell_vec = sell_series === nothing ? fill(params.sell_price, npts) : scale_price_series(sell_series, time_step_hours, npts)
            params = merge(params, (buy_price=buy_vec, sell_price=sell_vec))
        end

        append!(cost_items, calc_component_cost(comp_type, comp_node_id, comp_name, power_data, params, layer_id))
    end

    append!(cost_items, load_slack_data(db_path, layer_id, shortage_penalty, excess_penalty, sim_start, sim_end))
    return (
        cost_items=cost_items,
        energy_kwh=energy_kwh,
        tech=(re_used=re_used, re_avail=re_avail, hydro_gen=hydro_gen,
              thermal_gen=thermal_gen, buy_e=buy_e, tech_slots=tech_slots),
    )
end

# ─── 汇总 ────────────────────────────────────────────────────────────────────

function build_layer_summary(layer_id::String, layer_name::String, cost_items::Vector{CostItem})
    total_cost = 0.0
    objective_value = 0.0
    slack_penalty = 0.0
    has_slack = false
    cost_breakdown = Dict{String,Float64}()
    component_breakdown = Dict{String,Float64}()
    objective_components = String[]
    revenue_items = Dict{String,Float64}()

    for item in cost_items
        cost_breakdown[item.cost_type] = get(cost_breakdown, item.cost_type, 0.0) + item.value
        comp_key = "$(item.component_type)_$(item.component_id)"
        component_breakdown[comp_key] = get(component_breakdown, comp_key, 0.0) + item.value

        if item.is_slack
            slack_penalty += item.value
            has_slack = true
        else
            if item.is_revenue
                revenue_items[item.cost_type] = get(revenue_items, item.cost_type, 0.0) + item.value
            end
            if item.in_objective
                objective_value += item.value
                push!(objective_components, "$(item.component_id)|$(item.cost_type)")
            end
            total_cost += item.value
        end
    end

    return LayerEconomySummary(
        layer_id, layer_name,
        total_cost, cost_breakdown, component_breakdown,
        objective_components, objective_value,
        slack_penalty, has_slack, revenue_items,
    )
end

# ─── 派生指标（日均 / 月均 / 年化）────────────────────────────────────────────

"""
    build_economy_metrics(; ...)

根据已覆盖仿真时长做时间尺度换算：
  - elapsedHours / elapsedDays：已覆盖时长
  - dailyAvg*：日均
  - monthlyEstimate*：日均 × 30（粗估）
  - annualEstimate*：日均 × 365（粗估）

多日任务优先用日历天数；单日/跨日累计分钟用 elapsedHours/24。
"""
function build_economy_metrics(;
    sim_start::String,
    covered_end::String,
    sim_start_date::Union{String,Nothing}=nothing,
    sim_end_date::Union{String,Nothing}=nothing,
    total_cost::Float64,
    objective_value::Float64,
    slack_penalty::Float64,
    revenue_total::Float64,
    cost_breakdown::Dict{String,Float64},
    is_partial::Bool,
    progress_ratio::Float64,
    layer_count::Int=0,
    aggregation::String="mean",
)::Dict{String,Any}
    start_min = time_label_to_minutes(sim_start)
    end_min = time_label_to_minutes(covered_end)
    elapsed_hours = max(0.0, (end_min - start_min) / 60.0)

    elapsed_days = elapsed_hours / 24.0
    day_basis = "hours"  # "hours" | "calendar"

    # 有起止日期时用日历天数（更适合 23 天 → 年化）
    if sim_start_date !== nothing
        try
            d0 = Date(sim_start_date, dateformat"yyyy-mm-dd")
            # 覆盖终点：若有终止日期且已完成，用终止日期；否则按已覆盖小时数推算
            if sim_end_date !== nothing && !is_partial
                d1 = Date(sim_end_date, dateformat"yyyy-mm-dd")
                cal_days = Float64(Dates.value(d1 - d0) + 1)
                if cal_days > 0
                    elapsed_days = cal_days
                    day_basis = "calendar"
                end
            else
                cal_days = floor(elapsed_hours / 24.0)
                if cal_days >= 1
                    elapsed_days = cal_days + (elapsed_hours - cal_days * 24.0) / 24.0
                    day_basis = "calendar"
                end
            end
        catch
        end
    end

    # 至少按已覆盖小时折算，避免 0 除
    if elapsed_days <= 0 && elapsed_hours > 0
        elapsed_days = elapsed_hours / 24.0
    end

    net_cost = total_cost  # 已含收益负值

    function scale(base::Float64)
        if elapsed_days <= 0
            return Dict{String,Any}(
                "daily" => 0.0,
                "monthly" => 0.0,
                "annual" => 0.0,
            )
        end
        daily = base / elapsed_days
        return Dict{String,Any}(
            "daily" => round(daily; digits=2),
            "monthly" => round(daily * 30.0; digits=2),
            "annual" => round(daily * 365.0; digits=2),
        )
    end

    total_scale = scale(net_cost)
    objective_scale = scale(objective_value)

    by_type = Dict{String,Any}()
    for (k, v) in cost_breakdown
        s = scale(v)
        by_type[k] = Dict{String,Any}(
            "total" => round(v; digits=2),
            "daily" => s["daily"],
            "monthly" => s["monthly"],
            "annual" => s["annual"],
        )
    end

    return Dict{String,Any}(
        "coveredStart" => sim_start,
        "coveredEnd" => covered_end,
        "elapsedHours" => round(elapsed_hours; digits=2),
        "elapsedDays" => round(elapsed_days; digits=3),
        "dayBasis" => day_basis,
        "isPartial" => is_partial,
        "progressRatio" => round(progress_ratio; digits=4),
        "netCost" => round(net_cost; digits=2),
        "objectiveValue" => round(objective_value; digits=2),
        "slackPenalty" => round(slack_penalty; digits=2),
        "revenueTotal" => round(revenue_total; digits=2),
        "dailyAvgCost" => total_scale["daily"],
        "monthlyEstimateCost" => total_scale["monthly"],
        "annualEstimateCost" => total_scale["annual"],
        "dailyAvgObjective" => objective_scale["daily"],
        "annualEstimateObjective" => objective_scale["annual"],
        "byCostType" => by_type,
        "layerCount" => layer_count,
        "aggregation" => aggregation,
        "note" => is_partial ?
            "运行中/部分完成：按已覆盖时段统计；多时层同口径平均（空层不计入），年化=日均×365 粗估" :
            "按已覆盖时段统计；多时层同口径平均（空层不计入），年化=日均×365 粗估",
    )
end

# ─── 主入口 ──────────────────────────────────────────────────────────────────

"""
    evaluate_task_economy(task_id, project_json;
                          sim_start_time, sim_end_time,
                          covered_end_time, task_status, cur_time,
                          sim_start_date, sim_end_date) -> Dict

计算任务经济性指标。支持仿真进行中调用（动态刷新）。

- sim_start_time / sim_end_time：任务配置的仿真范围
- covered_end_time：实际统计终点（运行中传 cur_time，完成后传 sim_end_time）
- 返回可直接 JSON 序列化的 Dict
"""
function evaluate_task_economy(
    task_id::String,
    project_json::Dict;
    sim_start_time::Union{String,Nothing}=nothing,
    sim_end_time::Union{String,Nothing}=nothing,
    covered_end_time::Union{String,Nothing}=nothing,
    task_status::Union{String,Nothing}=nothing,
    cur_time::Union{String,Nothing}=nothing,
    sim_start_date::Union{String,Nothing}=nothing,
    sim_end_date::Union{String,Nothing}=nothing,
)
    store_path = joinpath(TASKS_DATA_ROOT, task_id, "timeseries.db")
    if !isfile(store_path)
        return Dict(
            "taskId" => task_id,
            "evaluationTime" => string(Dates.now()),
            "layers" => [],
            "allCostItems" => [],
            "objectiveComposition" => Dict(),
            "metrics" => nothing,
            "isPartial" => true,
            "message" => "时序数据尚未生成",
        )
    end

    sim_start = sim_start_time !== nothing ? sim_start_time : "0:00"

    # 统计终点：优先显式 covered_end；运行中用 cur_time；否则 sim_end
    effective_end = covered_end_time
    if effective_end === nothing
        if task_status !== nothing && task_status in ("solving", "building", "parsing", "pending") && cur_time !== nothing
            effective_end = cur_time
        else
            effective_end = sim_end_time
        end
    end

    # 仍无终点：尝试从 cur_time / 不截断
    is_partial = true
    if task_status == "completed" && sim_end_time !== nothing
        is_partial = false
        effective_end = sim_end_time
    elseif effective_end === nothing && cur_time !== nothing
        effective_end = cur_time
    end

    # 读取截断终点（求解中的 cur_time 可能刚好是当前步起点，往外放一个粒度由调用方决定）
    truncate_end = effective_end

    layers = _get_layers(project_json)
    algorithms = _get_algorithms(project_json)
    nodes = _get_nodes(project_json)
    component_dicts, node_id_to_code, node_id_to_name = _parse_component_nodes(nodes)

    _, shortage_penalty, excess_penalty = get_slack_config(algorithms)

    layer_step_hours = Dict{String,Float64}()
    for layer in layers
        lid = string(get(layer, "id", "1"))
        step_str = get(layer, "step", "1h")
        layer_step_hours[lid] = _parse_duration_hours(step_str)
    end

    all_cost_items = CostItem[]
    layer_summaries = LayerEconomySummary[]
    objective_composition = Dict{String,Dict{String,Float64}}()
    global_cost_breakdown = Dict{String,Float64}()

    for layer in layers
        layer_id = string(get(layer, "id", "1"))
        layer_name = get(layer, "name", "时层$(layer_id)")
        time_step_hours = get(layer_step_hours, layer_id, 1.0)

        layer_cost_items = CostItem[]

        for comp_dict in component_dicts
            comp_type = comp_dict["type"]
            comp_code = comp_dict["code"]
            comp_name = get(comp_dict, "name", comp_type)
            comp_node_id = get(comp_dict, "nodeId", "")

            comp_type in ("ELOAD", "HLOAD", "QLOAD") && continue

            power_data = load_component_data(store_path, comp_code, comp_type, layer_id, sim_start, truncate_end)

            has_data = false
            for (_, v) in power_data
                if !isempty(v)
                    has_data = true
                    break
                end
            end
            !has_data && continue

            params = resolve_component_params_economy_with_step(comp_dict, layer_id, time_step_hours)
            boundary_ids = get(comp_dict, "boundaryIds", String[])

            # 燃料投入：优先 F_* 序列；缺失时用 E/η 推导
            if !haskey(power_data, "fuel") || isempty(power_data["fuel"])
                pw = get(power_data, "power", Float64[])
                eff = nothing
                if haskey(comp_dict, "paras")
                    paras = comp_dict["paras"]
                    eff = get(paras, "η", get(paras, "η_e", get(paras, "efficiency", nothing)))
                end
                if eff !== nothing && Float64(eff) > 1e-9 && !isempty(pw)
                    power_data["fuel"] = Float64[p / Float64(eff) for p in pw]
                end
            end

            # 价格：边界优先，组件标量兜底
            if comp_type in ("CP", "GP", "CHP")
                bprice = load_boundary_price_series(store_path, boundary_ids, sim_start, truncate_end)
                if bprice !== nothing && !isempty(bprice)
                    npts = max(length(get(power_data, "power", Float64[])), length(bprice), 1)
                    params = merge(params, (fuel_price=scale_price_series(bprice, time_step_hours, npts),))
                end
            elseif comp_type in ("GRID", "HGRID")
                # 购/售价格按物理含义严格独立匹配
                # GRID: buy_price/sell_price（元/kWh）；HGRID: h2_buy_price/h2_sell_price（元/kg）
                buy_meaning = comp_type == "HGRID" ? "h2_buy_price" : "buy_price"
                sell_meaning = comp_type == "HGRID" ? "h2_sell_price" : "sell_price"
                buy_series = load_boundary_price_series_by_meaning(
                    store_path, boundary_ids, buy_meaning, sim_start, truncate_end)
                sell_series = load_boundary_price_series_by_meaning(
                    store_path, boundary_ids, sell_meaning, sim_start, truncate_end)
                npts = max(length(get(power_data, "buy", Float64[])), length(get(power_data, "sell", Float64[])), 1)
                buy_vec = buy_series === nothing ? fill(params.buy_price, npts) : scale_price_series(buy_series, time_step_hours, npts)
                sell_vec = sell_series === nothing ? fill(params.sell_price, npts) : scale_price_series(sell_series, time_step_hours, npts)
                params = merge(params, (buy_price=buy_vec, sell_price=sell_vec))
            end

            items = calc_component_cost(comp_type, comp_node_id, comp_name, power_data, params, layer_id)
            append!(layer_cost_items, items)
        end

        slack_items = load_slack_data(store_path, layer_id, shortage_penalty, excess_penalty, sim_start, truncate_end)
        append!(layer_cost_items, slack_items)

        summary = build_layer_summary(layer_id, layer_name, layer_cost_items)
        push!(layer_summaries, summary)

        obj_comp = Dict{String,Float64}()
        for item in layer_cost_items
            if item.in_objective
                obj_comp[item.cost_type] = get(obj_comp, item.cost_type, 0.0) + item.value
            end
            if !item.is_slack
                global_cost_breakdown[item.cost_type] =
                    get(global_cost_breakdown, item.cost_type, 0.0) + item.value
            end
        end
        objective_composition[layer_id] = obj_comp

        append!(all_cost_items, layer_cost_items)
    end

    # 全局汇总：多时层是同一时间段的并行求解，总览取各层平均而非累加；
    # 空层（尚无成本项）排除在平均分母之外，避免运行中进度拖低均值。
    active_summaries = [s for s in layer_summaries if !isempty(s.cost_breakdown)]
    n_active = max(length(active_summaries), 1)
    total_cost = sum(s.total_cost for s in active_summaries; init=0.0) / n_active
    objective_value = sum(s.objective_value for s in active_summaries; init=0.0) / n_active
    slack_total = sum(s.slack_penalty for s in active_summaries; init=0.0) / n_active
    revenue_total = sum(sum(values(s.revenue_items); init=0.0) for s in active_summaries; init=0.0) / n_active
    for (k, v) in global_cost_breakdown
        global_cost_breakdown[k] = v / n_active
    end

    covered_end_for_metrics = effective_end !== nothing ? effective_end :
        (cur_time !== nothing ? cur_time : sim_start)

    progress_ratio = 0.0
    if sim_end_time !== nothing
        try
            s0 = time_label_to_minutes(sim_start)
            s1 = time_label_to_minutes(sim_end_time)
            sc = time_label_to_minutes(covered_end_for_metrics)
            if s1 > s0
                progress_ratio = clamp((sc - s0) / (s1 - s0), 0.0, 1.0)
            elseif task_status == "completed"
                progress_ratio = 1.0
            end
        catch
        end
    elseif task_status == "completed"
        progress_ratio = 1.0
    end

    metrics = build_economy_metrics(;
        sim_start=sim_start,
        covered_end=covered_end_for_metrics,
        sim_start_date=sim_start_date,
        sim_end_date=sim_end_date,
        total_cost=total_cost,
        objective_value=objective_value,
        slack_penalty=slack_total,
        revenue_total=revenue_total,
        cost_breakdown=global_cost_breakdown,
        is_partial=is_partial,
        progress_ratio=progress_ratio,
        layer_count=length(active_summaries),
        aggregation="mean",
    )

    return Dict(
        "taskId" => task_id,
        "evaluationTime" => string(Dates.now()),
        "isPartial" => is_partial,
        "taskStatus" => task_status === nothing ? "" : task_status,
        "coveredEnd" => covered_end_for_metrics,
        "progressRatio" => round(progress_ratio; digits=4),
        "layers" => [Dict(
            "layerId" => s.layer_id,
            "layerName" => s.layer_name,
            "totalCost" => round(s.total_cost; digits=2),
            "costBreakdown" => Dict(k => round(v; digits=2) for (k, v) in s.cost_breakdown),
            "componentBreakdown" => Dict(k => round(v; digits=2) for (k, v) in s.component_breakdown),
            "objectiveComponents" => s.objective_components,
            "objectiveValue" => round(s.objective_value; digits=2),
            "slackPenalty" => round(s.slack_penalty; digits=2),
            "hasSlack" => s.has_slack,
            "revenueItems" => Dict(k => round(v; digits=2) for (k, v) in s.revenue_items),
        ) for s in layer_summaries],
        "allCostItems" => [Dict(
            "componentId" => item.component_id,
            "componentType" => item.component_type,
            "componentName" => item.component_name,
            "costType" => item.cost_type,
            "costLabel" => item.cost_label,
            "layerId" => item.layer_id,
            "value" => round(item.value; digits=2),
            "inObjective" => item.in_objective,
            "isSlack" => item.is_slack,
            "isRevenue" => item.is_revenue,
            "formula" => item.formula,
            "objectiveFlag" => item.objective_flag,
        ) for item in all_cost_items],
        "objectiveComposition" => Dict(
            lid => Dict(k => round(v; digits=2) for (k, v) in comp)
            for (lid, comp) in objective_composition
        ),
        "metrics" => metrics,
    )
end
