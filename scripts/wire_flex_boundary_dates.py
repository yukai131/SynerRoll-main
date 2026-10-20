"""
Wire AGC / user-defined flexibility curves through date-bound boundary series.

Config may reference boundary IDs; evaluation reads values from the task
timeseries DB after seed_task_boundary_data has already sliced by sim dates.
"""
from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

# ============================================================
# 1) flexibility_evaluation_service.jl
# ============================================================
p = root / "backend" / "services" / "flexibility_evaluation_service.jl"
text = p.read_text(encoding="utf-8")

# --- struct ---
old_struct = """struct FlexibilityEvaluationConfig
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
end"""
new_struct = """struct FlexibilityEvaluationConfig
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
end"""
assert old_struct in text, "struct not found"
text = text.replace(old_struct, new_struct, 1)

# --- normalize: accept boundary ids ---
old_norm = """    target_poi_power_kw = nothing
    upward_requirement_kw = nothing
    downward_requirement_kw = nothing
    if requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        haskey(raw, "targetPoiPowerKw") || throw(
            ArgumentError(
                "flexibility.targetPoiPowerKw is required for agc_or_schedule.",
            ),
        )
        target_poi_power_kw = _normalize_flexibility_value_spec(
            raw["targetPoiPowerKw"],
            "targetPoiPowerKw";
            nonnegative=false,
        )
    elseif requirement_source == FLEXIBILITY_REQUIREMENT_USER_DEFINED
        for field in ("upwardRequirementKw", "downwardRequirementKw")
            haskey(raw, field) || throw(
                ArgumentError(
                    "flexibility.$(field) is required for user_defined.",
                ),
            )
        end
        upward_requirement_kw = _normalize_flexibility_value_spec(
            raw["upwardRequirementKw"],
            "upwardRequirementKw";
            nonnegative=true,
        )
        downward_requirement_kw = _normalize_flexibility_value_spec(
            raw["downwardRequirementKw"],
            "downwardRequirementKw";
            nonnegative=true,
        )
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
    )
end"""
new_norm = """    target_poi_power_kw = nothing
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
        has_target_boundary = target_poi_power_boundary_id !== nothing
        has_target_value = haskey(raw, "targetPoiPowerKw")
        (has_target_boundary || has_target_value) || throw(
            ArgumentError(
                "flexibility.targetPoiPowerBoundaryId or targetPoiPowerKw " *
                "is required for agc_or_schedule.",
            ),
        )
        if !has_target_boundary
            target_poi_power_kw = _normalize_flexibility_value_spec(
                raw["targetPoiPowerKw"],
                "targetPoiPowerKw";
                nonnegative=false,
            )
        end
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

""" + """
\"\"\"灵活性需求引用的边界 ID 列表（用于 seed 并入画布边界）。\"\"\"
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

\"\"\"从任务时序库读取已按日期截取的边界需求值。\"\"\"
function _read_flexibility_boundary_value(
    db_path::String,
    boundary_id::String,
    meaning::String,
    layer_id::String,
    timestamp::String,
    field_name::String,
)
    data_key = "$(boundary_id)|$(meaning)|planned#$(layer_id)"
    value = get_ts_exact(db_path, data_key, timestamp)
    value === nothing && (value = get_ts_floor(db_path, data_key, timestamp))
    value === nothing && error(
        "Flexibility boundary $(field_name)=$(boundary_id) has no value for " *
        "timestamp=$(timestamp) (meaning=$(meaning), layer=$(layer_id)). " *
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
"""

# The above embeds triple quotes wrong for Julia - write helpers as plain text after the function
# Fix: replace the broken approach - we'll insert helpers as raw text without Python docstring escapes

text = text.replace(old_norm, new_norm.split('"""灵活性需求引用')[0].rstrip() + "\nend\n", 1)

# Insert helpers after _resolve_flexibility_value_spec function
helper_block = '''
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
'''

# find end of _resolve_flexibility_value_spec
m = re.search(r"function _resolve_flexibility_value_spec\(value_spec, timestamp::String, field_name::String\)\n[\s\S]*?\nend\n", text)
assert m, "_resolve_flexibility_value_spec not found"
insert_at = m.end()
text = text[:insert_at] + helper_block + text[insert_at:]

# --- config dict export boundary ids ---
old_dict = """    if config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        row["targetPoiPowerKw"] = config.target_poi_power_kw
    elseif config.requirement_source == FLEXIBILITY_REQUIREMENT_USER_DEFINED
        row["upwardRequirementKw"] = config.upward_requirement_kw
        row["downwardRequirementKw"] = config.downward_requirement_kw
    end
    return row
end"""
new_dict = """    if config.requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE
        if config.target_poi_power_boundary_id !== nothing
            row["targetPoiPowerBoundaryId"] = config.target_poi_power_boundary_id
        else
            row["targetPoiPowerKw"] = config.target_poi_power_kw
        end
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
end"""
assert old_dict in text, "config dict not found"
text = text.replace(old_dict, new_dict, 1)

# --- requirement input builder ---
old_agc = """        return AgcScheduleRequirementInput(
            baseline_poi_power_kw=grid_context.operating_point["poi_power_kw"],
            target_poi_power_kw=_resolve_flexibility_value_spec(
                config.target_poi_power_kw,
                next_timestamp,
                "targetPoiPowerKw",
            ),
        )
    end

    return UserDefinedRequirementInput(
        upward_requirement_kw=_resolve_flexibility_value_spec(
            config.upward_requirement_kw,
            timestamp,
            "upwardRequirementKw",
        ),
        downward_requirement_kw=_resolve_flexibility_value_spec(
            config.downward_requirement_kw,
            timestamp,
            "downwardRequirementKw",
        ),
    )
end"""
new_agc = """        target_kw = _flexibility_requirement_value(
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
end"""
assert old_agc in text, "requirement builder not found"
text = text.replace(old_agc, new_agc, 1)

p.write_text(text, encoding="utf-8")
print("flexibility_evaluation_service.jl OK")

# ============================================================
# 2) simulation_runner.jl — seed includes flexibility boundary ids
# ============================================================
p = root / "backend" / "services" / "simulation_runner.jl"
text = p.read_text(encoding="utf-8")

old_seed = """            boundary_ids=_canvas_boundary_ids(project_json, string(task["canvas_id"])),
        )
        end
        boundary_result === nothing && return nothing"""
new_seed = """            boundary_ids=unique(vcat(
                _canvas_boundary_ids(project_json, string(task["canvas_id"])),
                flexibility_config === nothing ? String[] : flexibility_boundary_ids(flexibility_config),
            )),
        )
        end
        boundary_result === nothing && return nothing"""
assert old_seed in text, "seed call not found"
text = text.replace(old_seed, new_seed, 1)

# single-layer path around line 483 if present
text2 = text.replace(
    'boundary_ids=_canvas_boundary_ids(project_json, string(task["canvas_id"])),',
    'boundary_ids=unique(vcat(_canvas_boundary_ids(project_json, string(task["canvas_id"])), flexibility_config === nothing ? String[] : flexibility_boundary_ids(flexibility_config))),',
)
# may have replaced the already-replaced one too; check
if text2.count("flexibility_boundary_ids") >= 1:
    text = text2

p.write_text(text, encoding="utf-8")
print("simulation_runner.jl OK, flexibility_boundary_ids count:", text.count("flexibility_boundary_ids"))
