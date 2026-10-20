# flexibility_evaluation_service.jl — 灵活性任务配置与全链路计算编排

using JSON3

struct FlexibilityEvaluationConfig
    layer_id::String
    application_type::String
    operation_mode::String
    boundary_condition::String
    network_mode::String
    poi_id::Union{Nothing,String}
    requirement_source::String
    target_poi_power_kw::Any
    upward_requirement_kw::Any
    downward_requirement_kw::Any
    # 边界引用：与 targetPoiPowerKw / 上下调 value spec 二选一，优先边界
    # （边界从 1/1 起连续存储，seed 时按仿真日期截取）
    target_poi_power_boundary_id::Union{Nothing,String}
    upward_requirement_boundary_id::Union{Nothing,String}
    downward_requirement_boundary_id::Union{Nothing,String}
end

const FLEXIBILITY_NETWORK_AUTO = "auto"
const FLEXIBILITY_NETWORK_GRID_CONNECTED = "grid_connected"
const FLEXIBILITY_NETWORK_ISLANDED = "islanded"
const FLEXIBILITY_NETWORK_MODES = (
    FLEXIBILITY_NETWORK_AUTO,
    FLEXIBILITY_NETWORK_GRID_CONNECTED,
    FLEXIBILITY_NETWORK_ISLANDED,
)

struct SystemFlexibilityEvaluationResult
    component_results::Vector{ComponentFlexibilityResult}
    supply_results::Vector{SystemFlexibilitySupplyResult}
    requirement_results::Vector{SystemFlexibilityRequirementResult}
    margin_results::Vector{SystemFlexibilityMarginResult}
end

function _flexibility_config_text(raw::AbstractDict, key::String; default=nothing)
    value = get(raw, key, default)
    value === nothing && throw(ArgumentError("flexibility.$(key) is required."))
    value isa AbstractString ||
        throw(ArgumentError("flexibility.$(key) must be a string."))
    result = String(value)
    isempty(strip(result)) &&
        throw(ArgumentError("flexibility.$(key) cannot be empty."))
    return result
end

function _normalize_flexibility_value_spec(
    value,
    field_name::String;
    nonnegative::Bool,
)
    normalize_number = function (raw_value)
        raw_value isa Real ||
            throw(ArgumentError("flexibility.$(field_name) values must be numeric."))
        result = Float64(raw_value)
        isfinite(result) ||
            throw(ArgumentError("flexibility.$(field_name) values must be finite."))
        nonnegative && result < 0.0 && throw(
            ArgumentError("flexibility.$(field_name) values must be non-negative."),
        )
        return result
    end

    value isa Real && return normalize_number(value)
    value isa AbstractDict || throw(
        ArgumentError(
            "flexibility.$(field_name) must be a number or timestamp-to-number object.",
        ),
    )
    isempty(value) &&
        throw(ArgumentError("flexibility.$(field_name) cannot be an empty object."))
    return Dict{String,Float64}(
        string(timestamp) => normalize_number(raw_value)
        for (timestamp, raw_value) in pairs(value)
    )
end

"""
    normalize_flexibility_evaluation_config(raw; default_layer_id)

校验并规范化任务请求中的 `flexibility` 配置。未提供配置或显式设置
`enabled=false` 时返回 `nothing`。时间变化值可以是一个常数，也可以是以
时间标签为键、可包含 `default` 的数值对象。
"""
function normalize_flexibility_evaluation_config(
    raw;
    default_layer_id::String,
)
    raw === nothing && return nothing
    raw isa AbstractDict ||
        throw(ArgumentError("flexibility must be an object."))
    enabled = get(raw, "enabled", true)
    enabled isa Bool ||
        throw(ArgumentError("flexibility.enabled must be boolean."))
    enabled || return nothing

    layer_id = _flexibility_config_text(raw, "layerId"; default=default_layer_id)
    # 系统类型只用于项目创建模板，不再要求用户在计算任务中重复选择。
    application_type = _flexibility_config_text(
        raw,
        "applicationType";
        default="configured_project",
    )
    operation_mode = _flexibility_config_text(raw, "operationMode")
    network_mode = _flexibility_config_text(raw, "networkMode"; default=FLEXIBILITY_NETWORK_AUTO)
    network_mode in FLEXIBILITY_NETWORK_MODES || throw(
        ArgumentError(
            "flexibility.networkMode must be auto, grid_connected or islanded.",
        ),
    )
    # 网络边界以 GRID 的容量、上送比例和购入比例为唯一数值来源。
    boundary_condition = _flexibility_config_text(
        raw,
        "boundaryCondition";
        default=network_mode == FLEXIBILITY_NETWORK_ISLANDED ?
            "islanded_local_balance" : "grid_component_limits",
    )
    raw_poi_id = get(raw, "poiId", nothing)
    poi_id = if raw_poi_id === nothing
        nothing
    else
        raw_poi_id isa AbstractString ||
            throw(ArgumentError("flexibility.poiId must be a string or null."))
        result = String(raw_poi_id)
        isempty(strip(result)) &&
            throw(ArgumentError("flexibility.poiId cannot be empty."))
        result
    end
    network_mode == FLEXIBILITY_NETWORK_ISLANDED && poi_id !== nothing && throw(
        ArgumentError("flexibility.poiId must be null for islanded evaluation."),
    )

    requirement_source = _flexibility_config_text(raw, "requirementSource")
    requirement_source in FLEXIBILITY_REQUIREMENT_SOURCES || throw(
        ArgumentError(
            "flexibility.requirementSource must be net_load_change, " *
            "agc_or_schedule or user_defined.",
        ),
    )
    network_mode == FLEXIBILITY_NETWORK_ISLANDED &&
        requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE && throw(
            ArgumentError(
                "Islanded flexibility evaluation cannot use an AGC/POI schedule target.",
            ),
        )

    target_poi_power_kw = nothing
    upward_requirement_kw = nothing
    downward_requirement_kw = nothing
    target_poi_power_boundary_id = nothing
    upward_requirement_boundary_id = nothing
    downward_requirement_boundary_id = nothing

    _optional_boundary_id = function (key::String)
        !haskey(raw, key) && return nothing
        value = raw[key]
        value === nothing && return nothing
        value isa AbstractString ||
            throw(ArgumentError("flexibility.$(key) must be a string or null."))
        result = String(value)
        isempty(strip(result)) && return nothing
        return result
    end

    if requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        target_poi_power_boundary_id = _optional_boundary_id("targetPoiPowerBoundaryId")
        target_poi_power_boundary_id === nothing && throw(
            ArgumentError(
                "flexibility.targetPoiPowerBoundaryId is required for agc_or_schedule " *
                "(boundary series from Jan 1, sliced by simulation dates).",
            ),
        )
    elseif requirement_source == FLEXIBILITY_REQUIREMENT_USER_DEFINED
        upward_requirement_boundary_id = _optional_boundary_id("upwardRequirementBoundaryId")
        downward_requirement_boundary_id = _optional_boundary_id("downwardRequirementBoundaryId")
        has_up_boundary = upward_requirement_boundary_id !== nothing
        has_down_boundary = downward_requirement_boundary_id !== nothing
        has_up_value = haskey(raw, "upwardRequirementKw")
        has_down_value = haskey(raw, "downwardRequirementKw")
        (has_up_boundary || has_up_value) || throw(
            ArgumentError(
                "flexibility.upwardRequirementBoundaryId or upwardRequirementKw " *
                "is required for user_defined.",
            ),
        )
        (has_down_boundary || has_down_value) || throw(
            ArgumentError(
                "flexibility.downwardRequirementBoundaryId or downwardRequirementKw " *
                "is required for user_defined.",
            ),
        )
        if !has_up_boundary
            upward_requirement_kw = _normalize_flexibility_value_spec(
                raw["upwardRequirementKw"],
                "upwardRequirementKw";
                nonnegative=true,
            )
        end
        if !has_down_boundary
            downward_requirement_kw = _normalize_flexibility_value_spec(
                raw["downwardRequirementKw"],
                "downwardRequirementKw";
                nonnegative=true,
            )
        end
    end

    return FlexibilityEvaluationConfig(
        layer_id,
        application_type,
        operation_mode,
        boundary_condition,
        network_mode,
        poi_id,
        requirement_source,
        target_poi_power_kw,
        upward_requirement_kw,
        downward_requirement_kw,
        target_poi_power_boundary_id,
        upward_requirement_boundary_id,
        downward_requirement_boundary_id,
    )
end


function flexibility_evaluation_config_dict(config::FlexibilityEvaluationConfig)
    row = StringAnyDict(
        "enabled" => true,
        "layerId" => config.layer_id,
        "applicationType" => config.application_type,
        "operationMode" => config.operation_mode,
        "boundaryCondition" => config.boundary_condition,
        "networkMode" => config.network_mode,
        "poiId" => config.poi_id,
        "requirementSource" => config.requirement_source,
    )
    if config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        row["targetPoiPowerBoundaryId"] = config.target_poi_power_boundary_id
    elseif config.requirement_source == FLEXIBILITY_REQUIREMENT_USER_DEFINED
        if config.upward_requirement_boundary_id !== nothing
            row["upwardRequirementBoundaryId"] = config.upward_requirement_boundary_id
        else
            row["upwardRequirementKw"] = config.upward_requirement_kw
        end
        if config.downward_requirement_boundary_id !== nothing
            row["downwardRequirementBoundaryId"] = config.downward_requirement_boundary_id
        else
            row["downwardRequirementKw"] = config.downward_requirement_kw
        end
    end
    return row
end

function flexibility_evaluation_config_from_task(task::AbstractDict)
    raw_extra = get(task, "extra_json", nothing)
    raw_extra === nothing && return nothing
    extra = raw_extra isa AbstractString ?
        JSON3.read(String(raw_extra), Dict{String,Any}) : raw_extra
    extra isa AbstractDict || return nothing
    return normalize_flexibility_evaluation_config(
        get(extra, "flexibility", nothing);
        default_layer_id=string(task["layer_id"]),
    )
end

function _resolve_flexibility_value_spec(value_spec, timestamp::String, field_name::String)
    value_spec isa Real && return Float64(value_spec)
    value_spec isa AbstractDict || error(
        "Flexibility configuration field $(field_name) does not contain a usable value.",
    )
    value = if haskey(value_spec, timestamp)
        value_spec[timestamp]
    elseif haskey(value_spec, "default")
        value_spec["default"]
    else
        error(
            "Flexibility configuration field $(field_name) has no value for " *
            "timestamp=$(timestamp) and no default.",
        )
    end
    return Float64(value)
end

# ---------------------------------------------------------------------------
# 边界引用：seed 后从任务时序库按截取结果取值（日期语义与风速/负荷一致）
# ---------------------------------------------------------------------------

"""灵活性需求引用的边界 ID 列表（用于 seed 并入画布边界）。"""
function flexibility_boundary_ids(config::FlexibilityEvaluationConfig)::Vector{String}
    ids = String[]
    for value in (
        config.target_poi_power_boundary_id,
        config.upward_requirement_boundary_id,
        config.downward_requirement_boundary_id,
    )
        value === nothing && continue
        isempty(strip(String(value))) && continue
        push!(ids, String(value))
    end
    return unique(ids)
end

"""从任务时序库读取已按日期截取的边界需求值。"""
function _read_flexibility_boundary_value(
    db_path::String,
    boundary_id::String,
    meaning::String,
    layer_id::String,
    timestamp::String,
    field_name::String,
)
    data_key = boundary_id * "|" * meaning * "|planned#" * layer_id
    value = get_ts_exact(db_path, data_key, timestamp)
    value === nothing && (value = get_ts_floor(db_path, data_key, timestamp))
    value === nothing && error(
        "Flexibility boundary " * field_name * "=" * boundary_id *
        " has no value for timestamp=" * timestamp *
        " (meaning=" * meaning * ", layer=" * layer_id * "). " *
        "Ensure the boundary covers the simulation date range.",
    )
    return Float64(value)
end

function _flexibility_requirement_value(
    config::FlexibilityEvaluationConfig,
    db_path::String,
    timestamp::String;
    boundary_id::Union{Nothing,String},
    meaning::String,
    value_spec,
    field_name::String,
)
    if boundary_id !== nothing && !isempty(strip(String(boundary_id)))
        return _read_flexibility_boundary_value(
            db_path,
            String(boundary_id),
            meaning,
            config.layer_id,
            timestamp,
            field_name,
        )
    end
    return _resolve_flexibility_value_spec(value_spec, timestamp, field_name)
end

function _read_exact_flexibility_baseline_value(
    db_path::String,
    data_key::String,
    timestamp::String,
)
    return get_ts_exact(db_path, data_key, timestamp)
end

function _select_flexibility_components(
    components::Vector{<:AbstractComponent},
    config::FlexibilityEvaluationConfig,
)
    grid_components = [component for component in components if component_type(component) == "GRID"]
    islanded = config.network_mode == FLEXIBILITY_NETWORK_ISLANDED ||
        (config.network_mode == FLEXIBILITY_NETWORK_AUTO && isempty(grid_components))

    if islanded
        isempty(grid_components) || error(
            "Islanded flexibility evaluation requires a canvas without GRID components.",
        )
        config.poi_id === nothing || error(
            "Islanded flexibility evaluation cannot select a POI.",
        )
        return components, nothing, nothing, true
    end

    isempty(grid_components) && error(
        "Grid-connected flexibility evaluation requires one GRID component.",
    )

    selected_grid = if length(grid_components) == 1
        only(grid_components)
    else
        config.poi_id === nothing && error(
            "Multiple GRID components require flexibility.poiId to select one boundary.",
        )
        matching = [
            component for component in grid_components
            if component_code(component) == config.poi_id
        ]
        length(matching) == 1 || error(
            "flexibility.poiId must match exactly one GRID component code.",
        )
        only(matching)
    end
    poi_id = something(config.poi_id, component_code(selected_grid))
    selected_components = [
        component for component in components
        if component_type(component) != "GRID" ||
           component_code(component) == component_code(selected_grid)
    ]
    return selected_components, selected_grid, poi_id, false
end

function _load_flexibility_context(
    component::AbstractComponent,
    db_path::String,
    layer::AbstractDict,
    timestamp::String,
    case_id::String,
    config::FlexibilityEvaluationConfig,
    poi_id::Union{Nothing,String};
    value_reader::Function,
)
    return load_component_flexibility_context(
        component,
        db_path;
        layer=layer,
        timestamp=timestamp,
        case_id=case_id,
        application_type=config.application_type,
        operation_mode=config.operation_mode,
        boundary_condition=poi_id === nothing ?
            "islanded_local_balance" : config.boundary_condition,
        poi_id=poi_id,
        value_reader=value_reader,
    )
end

function _requirement_baseline_power(
    component::AbstractComponent,
    db_path::String,
    layer_id::String,
    timestamp::String,
    variable_prefix::String;
    value_reader::Function,
)
    result_values = read_component_baseline_result(
        component,
        db_path,
        layer_id,
        timestamp;
        value_reader=value_reader,
    )
    return _nonnegative_baseline_result(
        component,
        result_values,
        variable_prefix,
        1e-6,
    )
end

function _aggregate_net_load_requirement_values(
    components::Vector{<:AbstractComponent},
    db_path::String,
    layer::AbstractDict,
    timestamp::String,
    case_id::String,
    config::FlexibilityEvaluationConfig,
    poi_id::Union{Nothing,String};
    value_reader::Function,
)
    layer_id = string(layer["id"])
    rigid_load_kw = 0.0
    flexible_load_kw = 0.0
    wind_available_power_kw = 0.0
    pv_available_power_kw = 0.0

    for component in components
        _component_available(component, layer_id) || continue
        component_kind = component_type(component)
        if component_kind == "ELOAD"
            rigid_load_kw += _requirement_baseline_power(
                component,
                db_path,
                layer_id,
                timestamp,
                "E_ELOAD";
                value_reader=value_reader,
            )
        elseif component_kind == "ET"
            flexible_load_kw += _requirement_baseline_power(
                component,
                db_path,
                layer_id,
                timestamp,
                "E_ET";
                value_reader=value_reader,
            )
        elseif component_kind == "WT" || component_kind == "PV"
            context = _load_flexibility_context(
                component,
                db_path,
                layer,
                timestamp,
                case_id,
                config,
                poi_id;
                value_reader=value_reader,
            )
            available_power_kw = Float64(context.operating_point["available_power_kw"])
            if component_kind == "WT"
                wind_available_power_kw += available_power_kw
            else
                pv_available_power_kw += available_power_kw
            end
        end
    end
    return (
        rigid_load_kw=rigid_load_kw,
        flexible_load_kw=flexible_load_kw,
        wind_available_power_kw=wind_available_power_kw,
        pv_available_power_kw=pv_available_power_kw,
    )
end

function _build_system_flexibility_requirement_input(
    components::Vector{<:AbstractComponent},
    selected_grid::Union{Nothing,AbstractComponent},
    db_path::String,
    layer::AbstractDict,
    timestamp::String,
    next_timestamp::String,
    case_id::String,
    config::FlexibilityEvaluationConfig,
    poi_id::Union{Nothing,String};
    value_reader::Function,
)
    if config.requirement_source == FLEXIBILITY_REQUIREMENT_NET_LOAD
        current_values = _aggregate_net_load_requirement_values(
            components,
            db_path,
            layer,
            timestamp,
            case_id,
            config,
            poi_id;
            value_reader=value_reader,
        )
        next_values = _aggregate_net_load_requirement_values(
            components,
            db_path,
            layer,
            next_timestamp,
            case_id,
            config,
            poi_id;
            value_reader=value_reader,
        )
        return NetLoadRequirementInput(
            current_rigid_load_kw=current_values.rigid_load_kw,
            next_rigid_load_kw=next_values.rigid_load_kw,
            current_flexible_load_kw=current_values.flexible_load_kw,
            next_flexible_load_kw=next_values.flexible_load_kw,
            current_wind_available_power_kw=current_values.wind_available_power_kw,
            next_wind_available_power_kw=next_values.wind_available_power_kw,
            current_pv_available_power_kw=current_values.pv_available_power_kw,
            next_pv_available_power_kw=next_values.pv_available_power_kw,
        )
    elseif config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        selected_grid === nothing && error(
            "Islanded flexibility evaluation cannot use an AGC/POI schedule target.",
        )
        grid_context = _load_flexibility_context(
            selected_grid,
            db_path,
            layer,
            next_timestamp,
            case_id,
            config,
            poi_id;
            value_reader=value_reader,
        )
        target_kw = _flexibility_requirement_value(
            config,
            db_path,
            next_timestamp;
            boundary_id=config.target_poi_power_boundary_id,
            meaning="power",
            value_spec=config.target_poi_power_kw,
            field_name="targetPoiPowerKw",
        )
        return AgcScheduleRequirementInput(
            baseline_poi_power_kw=grid_context.operating_point["poi_power_kw"],
            target_poi_power_kw=target_kw,
        )
    end

    upward_kw = _flexibility_requirement_value(
        config,
        db_path,
        timestamp;
        boundary_id=config.upward_requirement_boundary_id,
        meaning="flex_up",
        value_spec=config.upward_requirement_kw,
        field_name="upwardRequirementKw",
    )
    downward_kw = _flexibility_requirement_value(
        config,
        db_path,
        timestamp;
        boundary_id=config.downward_requirement_boundary_id,
        meaning="flex_down",
        value_spec=config.downward_requirement_kw,
        field_name="downwardRequirementKw",
    )
    return UserDefinedRequirementInput(
        upward_requirement_kw=upward_kw,
        downward_requirement_kw=downward_kw,
    )
end

function evaluate_system_flexibility_period(
    components::Vector{<:AbstractComponent},
    db_path::String;
    layer::AbstractDict,
    timestamp::String,
    case_id::String,
    config::FlexibilityEvaluationConfig,
    value_reader::Function=_read_exact_flexibility_baseline_value,
)
    string(layer["id"]) == config.layer_id || throw(
        ArgumentError("Evaluation layer does not match flexibility.layerId."),
    )
    selected_components, selected_grid, poi_id, islanded = _select_flexibility_components(
        components,
        config,
    )
    next_timestamp = time_label_add(timestamp, string(layer["step"]))

    component_results = ComponentFlexibilityResult[]
    for component in selected_components
        context = _load_flexibility_context(
            component,
            db_path,
            layer,
            timestamp,
            case_id,
            config,
            poi_id;
            value_reader=value_reader,
        )
        append!(component_results, calculate_component_flexibility(component, context))
    end
    supply_results = islanded ?
        aggregate_islanded_system_flexibility_supply(component_results) :
        aggregate_system_flexibility_supply(component_results)

    requirement_context = SystemFlexibilityRequirementContext(
        timestamp=timestamp,
        next_timestamp=next_timestamp,
        time_step=string(layer["step"]),
        case_id=case_id,
        application_type=config.application_type,
        operation_mode=config.operation_mode,
        boundary_condition=islanded ? "islanded_local_balance" : config.boundary_condition,
        poi_id=poi_id,
    )
    requirement_input = _build_system_flexibility_requirement_input(
        selected_components,
        selected_grid,
        db_path,
        layer,
        timestamp,
        next_timestamp,
        case_id,
        config,
        poi_id;
        value_reader=value_reader,
    )
    requirement_results = calculate_system_flexibility_requirement(
        requirement_context,
        requirement_input,
    )
    margin_results = calculate_system_flexibility_margin(
        supply_results,
        requirement_results,
    )
    return SystemFlexibilityEvaluationResult(
        component_results,
        supply_results,
        requirement_results,
        margin_results,
    )
end

"""
    evaluate_system_flexibility(components, db_path; layer, timestamps, case_id, config)

对一组时间戳执行完整的“组件能力—系统供给—系统需求—裕度”计算链，并返回
合并后的结果。输入时间戳按数值时间排序且不得重复。
"""
function evaluate_system_flexibility(
    components::Vector{<:AbstractComponent},
    db_path::String;
    layer::AbstractDict,
    timestamps::AbstractVector,
    case_id::String,
    config::FlexibilityEvaluationConfig,
    value_reader::Function=_read_exact_flexibility_baseline_value,
)
    normalized_timestamps = String[string(timestamp) for timestamp in timestamps]
    length(unique(normalized_timestamps)) == length(normalized_timestamps) ||
        throw(ArgumentError("Flexibility evaluation timestamps must be unique."))
    sort!(normalized_timestamps; by=time_label_to_minutes)

    component_results = ComponentFlexibilityResult[]
    supply_results = SystemFlexibilitySupplyResult[]
    requirement_results = SystemFlexibilityRequirementResult[]
    margin_results = SystemFlexibilityMarginResult[]
    for timestamp in normalized_timestamps
        period_result = evaluate_system_flexibility_period(
            components,
            db_path;
            layer=layer,
            timestamp=timestamp,
            case_id=case_id,
            config=config,
            value_reader=value_reader,
        )
        append!(component_results, period_result.component_results)
        append!(supply_results, period_result.supply_results)
        append!(requirement_results, period_result.requirement_results)
        append!(margin_results, period_result.margin_results)
    end
    return SystemFlexibilityEvaluationResult(
        component_results,
        supply_results,
        requirement_results,
        margin_results,
    )
end
