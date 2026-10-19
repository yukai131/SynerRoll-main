using Random
using Statistics
using Dates

const DEFAULT_BOUNDARY_START_DATE = "2026-01-01"

# ───── 边界重采样 / 加噪插值 ─────
#
# 业务约定：
# 1. 目标长度以 layer["length"] 为准（时层硬需求）。原始数据必须完整覆盖该长度，
#    否则向前端报错；数据更长时截断，兼容。
# 2. 原始采样点落在目标网格上的点为“锚点”，输出值严格等于原始值。
# 3. 非锚点按 interpolate_type 插值；若 noise_level > 0，在插值结果上叠加噪声，
#    且噪声在锚点处衰减为 0（样条/分段曲线上的加噪，不破坏给定采样点）。
# 4. noise_level 为 0%~100% 的模糊强度（0.0~1.0，兼容传入 0~100 自动归一），
#    用户不关心具体数学含义；内部映射到“明显可感”的扰动幅度。
# 5. noise_distribution: "normal" | "uniform"（与前端选项一致）
# 6. 默认输出 ≥0；allow_negative=true 时不限位（温度例外）

const INTERPOLATE_TYPES = ("copy", "linear", "cubic", "spline")
const NOISE_DISTRIBUTIONS = ("normal", "uniform", "exponential", "lognormal")

function _parse_boundary_values(data_array::AbstractVector)::Vector{Float64}
    isempty(data_array) && error("边界数据为空，请先导入数据")
    values = Vector{Float64}(undef, length(data_array))
    for i in eachindex(data_array)
        v = data_array[i]
        if v === nothing || v === missing
            error("边界数据第 $(i) 个点缺失")
        end
        fv = try
            Float64(v)
        catch
            error("边界数据第 $(i) 个点不是数值: $(v)")
        end
        isfinite(fv) || error("边界数据第 $(i) 个点不是有限数值: $(fv)")
        values[i] = fv
    end
    return values
end

# 将用户输入归一到 0~1（0%~100% 模糊强度）
function _normalize_noise_level(noise_level::Float64)::Float64
    noise_level < 0.0 && error("噪声水平不能为负数")
    # 兼容前端滑杆传 0~100
    level = noise_level > 1.0 ? noise_level / 100.0 : noise_level
    level > 1.0 && error("噪声水平应在 0%~100% 之间")
    return level
end

"""
内部把 0%~100% 模糊强度映射为振幅。
100% ≈ 数据波动幅度的 30%（主观“很明显”）；常数序列退化到微小相对量。
用户无需理解 std / 峰峰值等数学量。
"""
function _noise_amplitude(values::Vector{Float64}, strength::Float64)::Float64
    strength <= 0.0 && return 0.0
    n = length(values)
    n == 0 && return 0.0
    vmin, vmax = extrema(values)
    range = vmax - vmin
    scale = if range > 1e-12
        range
    else
        max(abs(values[1]) * 0.2, 1e-6)
    end
    return strength * 0.3 * scale
end

function _sample_noise(rng::AbstractRNG, distribution::String, amplitude::Float64)::Float64
    amplitude <= 0.0 && return 0.0
    if distribution == "normal"
        return randn(rng) * amplitude
    elseif distribution == "uniform"
        # 方差与 normal 对齐意义下的均匀：[-√3, √3] * amplitude / √3 → [-A, A]
        return (2.0 * rand(rng) - 1.0) * amplitude
    elseif distribution == "exponential"
        # 中心化指数：均值为 0，尺度 = amplitude
        return (randexp(rng) - 1.0) * amplitude
    elseif distribution == "lognormal"
        # 中心化对数正态扰动
        return (exp(0.5 * randn(rng)) - 1.0) * amplitude
    else
        error("不支持的随机分布: $(distribution)")
    end
end

# 噪声包络：锚点处为 0，段中点最大，保证“给定点位 = 给定值”
function _noise_envelope(u::Float64)::Float64
    (u <= 0.0 || u >= 1.0) && return 0.0
    return 4.0 * u * (1.0 - u)
end

function _catmull_rom(p0::Float64, p1::Float64, p2::Float64, p3::Float64, t::Float64)::Float64
    t2 = t * t
    t3 = t2 * t
    return 0.5 * (
        2.0 * p1 +
        (-p0 + p2) * t +
        (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
        (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
    )
end

"""
    _interpolate_source(values, data_step_minutes, t_minutes, interpolate_type) -> (value, is_anchor, u)

在均匀采样的原始序列上求 t_minutes 处的插值。
返回 (插值结果, 是否锚点, 段内相对位置 u∈[0,1])。
"""
function _interpolate_source(
    values::Vector{Float64},
    data_step_minutes::Int,
    t_minutes::Float64,
    interpolate_type::String,
)
    n = length(values)
    n == 1 && return values[1], true, 0.0

    # 原始网格：0, d, 2d, ...
    pos = t_minutes / data_step_minutes
    left = floor(Int, pos)
    # 锚点判定：t 恰好落在原始采样时刻
    if abs(pos - left) < 1e-9 && 0 <= left <= n - 1
        return values[left + 1], true, 0.0
    end

    left < 0 && return values[1], true, 0.0
    left >= n - 1 && return values[n], true, 0.0

    # left 对应 values[left+1]，right 对应 values[left+2]
    v1 = values[left + 1]
    v2 = values[left + 2]
    u = pos - left

    base = if interpolate_type == "copy"
        v1
    elseif interpolate_type == "linear"
        v1 + u * (v2 - v1)
    else
        # cubic / spline：Catmull-Rom，端点复制
        v0 = left >= 1 ? values[left] : v1
        v3 = left + 3 <= n ? values[left + 3] : v2
        _catmull_rom(v0, v1, v2, v3, u)
    end
    return base, false, u
end

"""
    parse_boundary_data(data_array, time_step, layer; ...) -> TimeSeries

将原始边界时序重采样到目标时层步长。输出覆盖**源数据全长**，不按 layer.length 截断。

# 参数
- `data_array`: 原始数值序列（从 0:00 起、步长 `time_step` 均匀采样）
- `time_step`: 原始步长，如 "15m" / "1h"
- `layer`: 至少含 `length`（时层需求下限，须为 24h 整数倍）与 `step`（目标步长）
- `interpolate_type`: `copy` | `linear` | `cubic` | `spline`（后两者等价，Catmull-Rom）
- `noise_level`: 模糊噪声强度 0%~100%（0.0~1.0，兼容 0~100）；越大扰动越明显
- `noise_distribution`: `normal` | `uniform` | `exponential` | `lognormal`
- `boundary_length`: 可选；若提供且短于 layer 长度则报错（不得缩短时层需求）
- `allow_negative`: 默认 false，输出限位到 ≥0；温度等可负物理量由上层传 true
- `rng`: 可选随机源（测试可注入）

# 输出长度
点数 = 源数据总时长 ÷ layer.step（向下取整）。例如 8760h 数据 + 时层 step=15m → 35040 点；
layer.length=24h 只校验“数据至少够用”，不会把结果裁成 24h。

# 报错
数据覆盖不足、参数非法时抛出带中文说明的 ErrorException，由路由层转成前端 message。
"""
function parse_boundary_data(
    data_array::AbstractVector,
    time_step::String,
    layer::AbstractDict;
    start_time::String="0:00",
    interpolate_type::String="linear",
    noise_level::Float64=0.0,
    noise_distribution::String="normal",
    boundary_length::Union{String,Nothing}=nothing,
    allow_negative::Bool=false,
    rng::Union{AbstractRNG,Nothing}=nothing,
)
    interpolate_type in INTERPOLATE_TYPES ||
        error("插值方式无效: $(interpolate_type)，可选: $(join(INTERPOLATE_TYPES, ", "))")
    noise_distribution in NOISE_DISTRIBUTIONS ||
        error("随机分布无效: $(noise_distribution)，可选: $(join(NOISE_DISTRIBUTIONS, ", "))")
    noise_strength = _normalize_noise_level(noise_level)
    haskey(layer, "length") || error("时层配置缺少 length")
    haskey(layer, "step") || error("时层配置缺少 step")

    values = _parse_boundary_values(data_array)

    layer_length_minutes = time_str_to_minutes(layer["length"])
    layer_step_minutes = time_str_to_minutes(layer["step"])
    data_step_minutes = time_str_to_minutes(time_step)

    layer_length_minutes > 0 || error("时层 length 必须为正")
    layer_step_minutes > 0 || error("时层 step 必须为正")
    data_step_minutes > 0 || error("数据 time_step 必须为正")
    layer_length_minutes % (24 * 60) == 0 ||
        error("时层 length 必须是 24h 的整数倍，当前: $(layer["length"])")
    layer_length_minutes % layer_step_minutes == 0 ||
        error("时层 length($(layer["length"])) 必须能被 step($(layer["step"])) 整除")
    layer_step_minutes >= 1 || error("时层 step 至少为 1 分钟")
    layer_step_minutes <= 4 * 60 || error("时层 step 不能超过 4h，当前: $(layer["step"])")

    # boundary_length 不得缩短时层需求；仅在更长时用于提示性校验
    if boundary_length !== nothing && !isempty(boundary_length)
        boundary_length_minutes = time_str_to_minutes(boundary_length)
        boundary_length_minutes < layer_length_minutes && error(
            "边界长度 $(boundary_length) 小于时层需求 $(layer["length"])，数据长度不足",
        )
    end

    data_total_minutes = length(values) * data_step_minutes
    if data_total_minutes < layer_length_minutes
        data_hours = round(data_total_minutes / 60; digits=2)
        need_hours = round(layer_length_minutes / 60; digits=2)
        error(
            "边界数据长度不足：时层需要 $(need_hours)h，实际仅有 $(data_hours)h，请补充数据或缩短时层范围",
        )
    end

    # start_time 历史上做循环平移，语义混乱且调用方恒为 0:00；现要求从 0:00 起
    start_minutes = time_label_to_minutes(start_time)
    start_minutes == 0 ||
        error("边界数据须从 0:00 起对齐，不支持 start_time=$(start_time)")

    # 输出覆盖源数据全长，按 layer.step 重采样；layer.length 只作下限校验，不截断
    # 尾部不足一个 step 的部分向下取整丢弃
    point_count = data_total_minutes ÷ layer_step_minutes
    point_count >= 1 || error("时层 step($(layer["step"])) 大于边界数据总长，无法采样")

    amplitude = _noise_amplitude(values, noise_strength)
    effective_rng = rng === nothing ? Random.MersenneTwister() : rng

    timestamps = generate_timestamps("0:00", layer["step"], "$(point_count * layer_step_minutes)m")
    final_values = Vector{Float64}(undef, point_count)

    for index in 0:point_count - 1
        t = Float64(index * layer_step_minutes)
        base, is_anchor, u = _interpolate_source(values, data_step_minutes, t, interpolate_type)
        if is_anchor || amplitude <= 0.0
            final_values[index + 1] = base
        else
            noise = _sample_noise(effective_rng, noise_distribution, amplitude) * _noise_envelope(u)
            final_values[index + 1] = base + noise
        end
    end

    # 默认非负限位：大多数边界（出力/风速/辐照/价格/负荷…）物理上 ≥0，
    # 样条过冲和噪声也可能压到负值。温度等例外由调用方传 allow_negative=true。
    if !allow_negative
        for i in eachindex(final_values)
            final_values[i] < 0.0 && (final_values[i] = 0.0)
        end
    end

    return TimeSeries(timestamps, final_values)
end


"""
    preprocess_boundary_data(data_array, time_step) -> Dict

预处理边界数据：截断到24h的倍数（最少24h）。返回截断后的数据和元信息。
# Arguments
- `data_array::Vector{Any}`: 原始数据数组
- `time_step::String`: 时间步长，如 "1h", "15m", "30m"

# Returns
Dict包含：
- `values`: 截断后的数据数组
- `timestamps`: 对应的时间戳
- `pointCount`: 数据点个数
- `totalHours`: 总小时数
- `dayCount`: 天数
- `timeStep`: 时间步长
"""
function preprocess_boundary_data(
    data_array::AbstractVector,
    time_step::String,
    ;
    time_mode::String="calendar",
    calendar_start_date::Union{String,Nothing}=DEFAULT_BOUNDARY_START_DATE,
)
    time_mode == "calendar" || error("边界数据必须绑定日期")
    # 解析时间步长（分钟）
    data_step_minutes = time_str_to_minutes(time_step)
    data_step_minutes > 0 || error("时间步长必须大于0")

    # 计算原始数据的总时长（小时）
    raw_count = length(data_array)
    raw_total_minutes = raw_count * data_step_minutes
    raw_total_hours = raw_total_minutes / 60

    # 至少24h，截断到24h的倍数
    raw_total_hours >= 24 || error("边界数据不足24小时（当前 $(round(raw_total_hours; digits=1))h），请补充数据")

    # 计算截断后的天数和点数
    day_count = floor(Int, raw_total_hours / 24)
    truncate_point_count = day_count * 24 * 60 ÷ data_step_minutes

    # 截断数据
    truncated_values = Float64.(data_array[1:truncate_point_count])

    # 生成时间戳
    total_minutes = truncate_point_count * data_step_minutes
    timestamps = generate_timestamps("0:00", time_step, "$(total_minutes)m")

    effective_start_date = calendar_start_date === nothing ? DEFAULT_BOUNDARY_START_DATE : calendar_start_date
    start_date = try
        Date(effective_start_date, dateformat"yyyy-mm-dd")
    catch
        error("起始日期格式错误，请使用 YYYY-MM-DD")
    end
    calendar_start = Dates.format(start_date, dateformat"yyyy-mm-dd")
    calendar_end = Dates.format(start_date + Day(day_count - 1), dateformat"yyyy-mm-dd")

    return Dict(
        "values" => truncated_values,
        "timestamps" => timestamps,
        "pointCount" => truncate_point_count,
        "totalHours" => day_count * 24,
        "dayCount" => day_count,
        "timeStep" => time_step,
        "timeMode" => time_mode,
        "calendarStartDate" => calendar_start,
        "calendarEndDate" => calendar_end,
    )
end

# ───── boundary_config 表：存储 boundary 元信息 ─────

"""
    ensure_boundary_config_table!(db_path::String)

确保 boundary.db 中存在 boundary_config 表，用于存储 boundary 的长度和尺度元信息。
"""
function ensure_boundary_config_table!(db_path::String)
    store = get_store(db_path)
    lock(store.write_lock) do
        _exec(store.db, """
            CREATE TABLE IF NOT EXISTS boundary_config (
                boundary_id     TEXT PRIMARY KEY,
                boundary_length TEXT NOT NULL,
                boundary_step   TEXT NOT NULL,
                day_count       INTEGER NOT NULL,
                point_count     INTEGER NOT NULL,
                time_mode       TEXT NOT NULL DEFAULT 'calendar',
                calendar_start_date TEXT,
                calendar_end_date   TEXT,
                created_at      TEXT DEFAULT (datetime('now')),
                updated_at      TEXT DEFAULT (datetime('now'))
            )
        """)
        columns = _query(store.db, "PRAGMA table_info(boundary_config)")
        column_names = Set(String(columns[2][i]) for i in eachindex(columns[1]))
        if !("time_mode" in column_names)
            _exec(store.db, "ALTER TABLE boundary_config ADD COLUMN time_mode TEXT NOT NULL DEFAULT 'calendar'")
        end
        if !("calendar_start_date" in column_names)
            _exec(store.db, "ALTER TABLE boundary_config ADD COLUMN calendar_start_date TEXT")
        end
        if !("calendar_end_date" in column_names)
            _exec(store.db, "ALTER TABLE boundary_config ADD COLUMN calendar_end_date TEXT")
        end
        # 历史的仅时长记录统一迁移为日历语义；缺少日期时以 2026-01-01 为首日。
        _exec(store.db, """
            UPDATE boundary_config
            SET time_mode = 'calendar',
                calendar_start_date = COALESCE(NULLIF(calendar_start_date, ''), ?),
                calendar_end_date = COALESCE(
                    NULLIF(calendar_end_date, ''),
                    date(COALESCE(NULLIF(calendar_start_date, ''), ?), '+' || max(day_count - 1, 0) || ' days')
                )
            WHERE time_mode IS NULL OR time_mode <> 'calendar'
               OR calendar_start_date IS NULL OR calendar_start_date = ''
               OR calendar_end_date IS NULL OR calendar_end_date = ''
        """, (DEFAULT_BOUNDARY_START_DATE, DEFAULT_BOUNDARY_START_DATE))
    end
    return nothing
end

"""
    save_boundary_config(db_path, boundary_id, boundary_length, boundary_step, day_count, point_count)

保存 boundary 的元信息到 boundary_config 表。
"""
function save_boundary_config(
    db_path::String,
    boundary_id::String,
    boundary_length::String,
    boundary_step::String,
    day_count::Int,
    point_count::Int,
    time_mode::String="calendar",
    calendar_start_date::Union{String,Nothing}=DEFAULT_BOUNDARY_START_DATE,
    calendar_end_date::Union{String,Nothing}=nothing,
)
    time_mode == "calendar" || error("边界数据必须绑定日期")
    calendar_start_date === nothing && error("日历边界缺少起始日期")
    calendar_end_date === nothing && error("日历边界缺少终止日期")
    ensure_boundary_config_table!(db_path)
    store = get_store(db_path)
    lock(store.write_lock) do
        _exec(store.db, """
            INSERT OR REPLACE INTO boundary_config
                (boundary_id, boundary_length, boundary_step, day_count, point_count,
                 time_mode, calendar_start_date, calendar_end_date, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        """, (boundary_id, boundary_length, boundary_step, day_count, point_count,
               time_mode, calendar_start_date, calendar_end_date))
    end
    return nothing
end

"""
    get_boundary_config(db_path, boundary_id) -> Dict 或 nothing

从 boundary_config 表获取 boundary 的元信息。
"""
function get_boundary_config(db_path::String, boundary_id::String)
    ensure_boundary_config_table!(db_path)
    store = get_store(db_path)
    return lock(store.write_lock) do
        rows = _query(store.db, """
            SELECT boundary_length, boundary_step, day_count, point_count,
                   time_mode, calendar_start_date, calendar_end_date
            FROM boundary_config WHERE boundary_id=?
        """, [boundary_id])
        isempty(rows[1]) && return nothing
        return Dict(
            "boundaryLength" => String(rows[1][1]),
            "boundaryStep" => String(rows[2][1]),
            "dayCount" => Int(rows[3][1]),
            "pointCount" => Int(rows[4][1]),
            "timeMode" => "calendar",
            "calendarStartDate" => String(rows[6][1]),
            "calendarEndDate" => String(rows[7][1]),
        )
    end
end

"""
    get_all_boundary_configs(db_path) -> Dict{String, Dict}

获取 boundary.db 中所有 boundary 的元信息。
返回 Dict{boundary_id => config_dict}。
"""
function get_all_boundary_configs(db_path::String)
    ensure_boundary_config_table!(db_path)
    store = get_store(db_path)
    return lock(store.write_lock) do
        rows = _query(store.db, """
            SELECT boundary_id, boundary_length, boundary_step, day_count, point_count,
                   time_mode, calendar_start_date, calendar_end_date
            FROM boundary_config
        """)
        result = Dict{String, Dict}()
        if !isempty(rows[1])
            for i in eachindex(rows[1])
                bid = String(rows[1][i])
                result[bid] = Dict(
                    "boundaryLength" => String(rows[2][i]),
                    "boundaryStep" => String(rows[3][i]),
                    "dayCount" => Int(rows[4][i]),
                    "pointCount" => Int(rows[5][i]),
                    "timeMode" => "calendar",
                    "calendarStartDate" => String(rows[7][i]),
                    "calendarEndDate" => String(rows[8][i]),
                )
            end
        end
        return result
    end
end

"""
    get_all_boundary_ids(project_id::String) -> Vector{String}

从 boundary.db 获取所有有数据的边界ID（source_id）。
"""
function get_all_boundary_ids(project_id::String)
    db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")
    isfile(db_path) || return String[]

    store = get_store(db_path)
    return lock(store.write_lock) do
        rows = _query(store.db, """
            SELECT DISTINCT source_id FROM time_series_meta
            WHERE remark='planned'
            ORDER BY source_id
        """)
        isempty(rows[1]) ? String[] : String.(rows[1])
    end
end

"""
    prepare_boundaries_for_clustering(project_id, boundary_ids) -> Dict

预处理所有边界数据，用于聚类计算。
- 以最短的 boundaryLength 为准，截断到24h的倍数
- 先截断再统一尺度到1h

返回 Dict：
- `data`: Dict{boundary_id => Vector{Float64}} （1h尺度的数据）
- `totalHours`: 统一后的总小时数
- `dayCount`: 天数
- `warnings`: 提示信息
"""
function prepare_boundaries_for_clustering(project_id::String, boundary_ids::Vector{String})
    isempty(boundary_ids) && error("至少需要一个边界")

    db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")
    isfile(db_path) || error("项目边界数据库不存在: $(db_path)")

    # 1. 获取所有边界的配置信息
    configs = get_all_boundary_configs(db_path)
    store = get_store(db_path)

    # 2. 读取每个边界的数据和配置
    boundary_data = Dict{String, Dict{String, Any}}()
    warnings = String[]

    for bid in boundary_ids
        config = get(configs, bid, nothing)
        if config === nothing
            # 如果没有配置信息，尝试从数据推断
            push!(warnings, "边界 $(bid) 缺少配置信息，将从数据推断")
            # 读取数据
            lock(store.write_lock) do
                meta_rows = _query(store.db, """
                    SELECT id, var_name FROM time_series_meta
                    WHERE source_id=? AND remark='planned'
                    ORDER BY CAST(layer_id AS INTEGER) ASC LIMIT 1
                """, [bid])
                isempty(meta_rows[1]) && error("边界 $(bid) 没有数据")

                series_id = Int(meta_rows[1][1])
                data_rows = _query(store.db,
                    "SELECT ts, value FROM time_series_data WHERE series_id=?",
                    [series_id])
                isempty(data_rows[1]) && error("边界 $(bid) 没有时序数据点")

                timestamps = Vector{String}(data_rows[1])
                values = Vector{Float64}(data_rows[2])
                perm = sortperm(timestamps; lt=time_label_less_than)
                sorted_ts = timestamps[perm]
                sorted_vals = values[perm]

                # 推断分辨率
                point_count = length(sorted_vals)
                resolution_min = if point_count >= 288
                    5
                elseif point_count >= 96
                    15
                else
                    60
                end

                # 计算总时长（小时）
                total_hours = point_count * resolution_min / 60
                # 截断到24h的倍数
                day_count = floor(Int, total_hours / 24)
                truncate_count = day_count * 24 * 60 ÷ resolution_min

                boundary_data[bid] = Dict(
                    "values" => Float64.(sorted_vals[1:truncate_count]),
                    "resolutionMin" => resolution_min,
                    "totalHours" => day_count * 24,
                    "dayCount" => day_count,
                    "boundaryStep" => "$(resolution_min)m",
                )
            end
        else
            # 有配置信息
            boundary_length = config["boundaryLength"]
            boundary_step = config["boundaryStep"]

            # 解析长度（小时）
            length_match = match(r"^(\d+)h$", boundary_length)
            length_match === nothing && error("边界 $(bid) 的长度格式错误: $(boundary_length)")
            total_hours = parse(Int, length_match[1])

            # 解析尺度（分钟）
            step_minutes = time_str_to_minutes(boundary_step)

            # 截断到24h的倍数
            day_count = floor(Int, total_hours / 24)
            actual_hours = day_count * 24

            # 读取数据
            lock(store.write_lock) do
                meta_rows = _query(store.db, """
                    SELECT id FROM time_series_meta
                    WHERE source_id=? AND remark='planned'
                    ORDER BY CAST(layer_id AS INTEGER) ASC LIMIT 1
                """, [bid])
                isempty(meta_rows[1]) && error("边界 $(bid) 没有数据")

                series_id = Int(meta_rows[1][1])
                data_rows = _query(store.db,
                    "SELECT ts, value FROM time_series_data WHERE series_id=?",
                    [series_id])
                isempty(data_rows[1]) && error("边界 $(bid) 没有时序数据点")

                timestamps = Vector{String}(data_rows[1])
                values = Vector{Float64}(data_rows[2])
                perm = sortperm(timestamps; lt=time_label_less_than)
                sorted_ts = timestamps[perm]
                sorted_vals = values[perm]

                # 截断到实际需要的点数
                truncate_count = actual_hours * 60 ÷ step_minutes
                truncate_count = min(truncate_count, length(sorted_vals))

                boundary_data[bid] = Dict(
                    "values" => Float64.(sorted_vals[1:truncate_count]),
                    "resolutionMin" => step_minutes,
                    "totalHours" => actual_hours,
                    "dayCount" => day_count,
                    "boundaryStep" => boundary_step,
                )
            end
        end
    end

    # 3. 以最短的长度为准
    min_day_count = minimum(d["dayCount"] for d in values(boundary_data))
    min_day_count < 1 && error("边界数据不足24小时，无法进行聚类")

    # 统一截断到最短长度
    processed = Dict{String, Vector{Float64}}()
    for (bid, data) in boundary_data
        values = data["values"]
        step_min = data["resolutionMin"]
        target_points = min_day_count * 24 * 60 ÷ step_min
        target_points = min(target_points, length(values))

        if step_min == 60
            # 已经是1h尺度
            processed[bid] = values[1:target_points]
        else
            # 需要重采样到1h
            layer = Dict{String,Any}("length" => "$(min_day_count * 24)h", "step" => "1h")
            ts = parse_boundary_data(
                Vector{Any}(values[1:target_points]),
                "$(step_min)m",
                layer;
                start_time="0:00",
                interpolate_type="linear",
            )
            processed[bid] = ts.values
        end
    end

    # 检查是否所有边界长度一致
    lengths = [length(v) for v in values(processed)]
    if length(unique(lengths)) > 1
        push!(warnings, "警告：统一后边界长度不一致，将截断到最短长度")
        min_len = minimum(lengths)
        for bid in keys(processed)
            processed[bid] = processed[bid][1:min_len]
        end
    end

    return Dict(
        "data" => processed,
        "totalHours" => min_day_count * 24,
        "dayCount" => min_day_count,
        "warnings" => warnings,
    )
end

"""
    delete_ts_by_source_id(; db_path, source_id, var_name, remark) -> Int

按 (source_id, var_name, remark) 组合删除所有匹配的 series（不限 layer_id）。
返回被删除的 series 数量（包含其下全部 data 点）。
至少需要提供一个过滤维度，否则报错。
"""
function delete_ts_by_source_id(;
    db_path::String,
    source_id::Union{String,Nothing}=nothing,
    var_name::Union{String,Nothing}=nothing,
    remark::Union{String,Nothing}=nothing,
)
    source_id !== nothing || var_name !== nothing || remark !== nothing ||
        error("delete_ts_by_source_id requires at least one of source_id/var_name/remark")

    store = get_store(db_path)

    where_clauses = String[]
    params = String[]
    source_id !== nothing && (push!(where_clauses, "source_id=?"); push!(params, source_id))
    var_name !== nothing && (push!(where_clauses, "var_name=?"); push!(params, var_name))
    remark !== nothing && (push!(where_clauses, "remark=?"); push!(params, remark))
    where_sql = join(where_clauses, " AND ")

    t0 = time()
    lock(store.write_lock) do
        wait_s = time() - t0
        if wait_s > 0.05
            @warn "[LOCK] delete_ts_by_source_id: lock wait" source_id wait_s=round(wait_s, digits=3)
        end
        # 1) 先把命中的 series_id 都查出来
        rows = _query(store.db,
            "SELECT id FROM time_series_meta WHERE $where_sql", params)
        isempty(rows[1]) && return 0
        n = length(rows[1])

        # 2) 事务内删除：先删 data（子表），再删 meta（父表）
        #    外键 ON DELETE CASCADE 保证一致性，但显式删更安全（SQLite 默认可能未开 FK）
        _exec(store.db, "BEGIN IMMEDIATE")
        try
            _exec(store.db,
                "DELETE FROM time_series_data WHERE series_id IN (SELECT id FROM time_series_meta WHERE $where_sql)",
                params)
            _exec(store.db, "DELETE FROM time_series_meta WHERE $where_sql", params)
            _exec(store.db, "COMMIT")
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end

        return n
    end
end

# 计算任务边界注入
# 任务启动时，把项目级 boundary DB 里的 planned 边界数据，按 layer_id 过滤后
# 复制到任务自己的 DB。
# 文档：docs/compute-task-architecture.md § 9
#
# 业务约定（整天仿真 + 只读最细层）：
# 1. 日历任务按自然日整段截取，并向前垫 look-ahead（滚动优化视野），避免最后一天越界。
# 2. 画布引用的边界必须有数据，否则 fail-fast，禁止静默跳过。
# 3. look-ahead 优先用源数据中任务结束后的真实点；不够时按窗口循环补齐。

"""
    _cycle_pad_values(window_vals, need_count) -> Vector{Float64}

把窗口内数值按周期重复到 need_count 个点（不足时循环，够则截断）。
"""
function _cycle_pad_values(window_vals::Vector{Float64}, need_count::Int)
    need_count <= 0 && return Float64[]
    isempty(window_vals) && error("无法补齐 look-ahead：窗口内没有数据")
    out = Vector{Float64}(undef, need_count)
    n = length(window_vals)
    for i in 1:need_count
        out[i] = window_vals[mod1(i, n)]
    end
    return out
end

"""
    _append_lookahead(ts_min, vals, window_end_min, lookahead_minutes, step_minutes)

在已选出的窗口后追加 look-ahead：
- 优先从 src_ts_min/src_vals 取 [window_end, window_end+lookahead) 的真实点
- 不够则用窗口值循环补齐到 lookahead 对应点数
返回 (ts_min, vals)，时间戳连续（窗口末点 + step * k）。
"""
function _append_lookahead(
    ts_min::Vector{Int},
    vals::Vector{Float64},
    src_ts_min::Vector{Int},
    src_vals::Vector{Float64},
    window_end_min::Int,
    lookahead_minutes::Int,
    step_minutes::Int,
)
    lookahead_minutes <= 0 && return ts_min, vals
    step_minutes > 0 || error("时间步长无效")
    need_points = cld(lookahead_minutes, step_minutes)
    need_points <= 0 && return ts_min, vals

    # 真实后续点（严格落在 look-ahead 窗）
    extra_vals = Float64[]
    for i in eachindex(src_ts_min)
        t = src_ts_min[i]
        if window_end_min <= t < window_end_min + need_points * step_minutes
            push!(extra_vals, src_vals[i])
        end
    end

    if length(extra_vals) >= need_points
        append_vals = extra_vals[1:need_points]
    else
        # 窗口值循环补齐（保持天/窗口形态，避免末值恒定导致模型失真）
        base = isempty(vals) ? extra_vals : vals
        append_vals = _cycle_pad_values(base, need_points)
    end

    last_t = isempty(ts_min) ? window_end_min - step_minutes : ts_min[end]
    append_ts = Int[last_t + k * step_minutes for k in 1:length(append_vals)]
    return vcat(ts_min, append_ts), vcat(vals, append_vals)
end

"""
    seed_task_boundary_data(task_id, project_id, layer_id;
                            sim_start_time, sim_end_time, sim_start_date, sim_end_date,
                            boundary_ids, lookahead_minutes)

从 `data/projects/<project_id>/boundary.db` 读所有
`(source_id, var_name, layer_id, remark="planned")` 的元数据和数据，
写入 `data/tasks/<task_id>/timeseries.db`。

日历任务按 `sim_start_date`、`sim_end_date` 截取自然日期范围并重标为任务局部时间；
未提供日期范围的历史任务按 `sim_start_time`、`sim_end_time` 截断。
`boundary_ids` 非空时只注入当前画布引用的边界，且引用缺失会报错。
`lookahead_minutes`：在仿真范围之后向前垫的视野（滚动优化用），优先用源数据真实点。
"""

# 边界物理含义 → 中文标签（与前端 BOUNDARY_MEANING_LABELS 对齐）
const BOUNDARY_MEANING_LABELS = Dict(
    "wind_speed" => "风速",
    "irradiance" => "辐照度",
    "temperature" => "温度",
    "factor" => "转化因子",
    "power" => "输出功率",
    "price" => "价格",
    "load" => "负荷",
)

_meaning_label(meaning::AbstractString) =
    get(BOUNDARY_MEANING_LABELS, String(meaning), String(meaning))

"""从任务快照 project.json 读边界 id → 可读标签（名称（含义）[id]）。"""
function _load_boundary_labels(task_id::String)::Dict{String,String}
    labels = Dict{String,String}()
    project_path = joinpath(BACKEND_DATA_DIR, "tasks", task_id, "project.json")
    isfile(project_path) || return labels
    try
        project_json = JSON3.read(read(project_path, String), Dict)
        boundaries = get(project_json, "boundaries", [])
        boundaries isa AbstractVector || return labels
        for b in boundaries
            b isa AbstractDict || continue
            bid = string(get(b, "id", get(b, "boundaryId", "")))
            isempty(bid) && continue
            name = strip(string(get(b, "name", "")))
            meaning = strip(string(get(b, "meaning", "")))
            if !isempty(name) && !isempty(meaning)
                labels[bid] = "$(name)（$(_meaning_label(meaning))）[$(bid)]"
            elseif !isempty(name)
                labels[bid] = "$(name)[$(bid)]"
            elseif !isempty(meaning)
                labels[bid] = "$(_meaning_label(meaning))[$(bid)]"
            else
                labels[bid] = bid
            end
        end
    catch e
        @warn "boundary_labels: 读取 project.json 失败，退回原始 id" project_path exception=e
    end
    return labels
end

_bd(labels::Dict{String,String}, id::AbstractString) = get(labels, String(id), String(id))

function _format_boundary_list(labels::Dict{String,String}, ids::Vector{String})
    return join((_bd(labels, id) for id in ids), "\n  - ")
end

function seed_task_boundary_data(
    task_id::String,
    project_id::String,
    layer_id::String;
    sim_start_time::Union{String,Nothing}=nothing,
    sim_end_time::Union{String,Nothing}=nothing,
    sim_start_date::Union{String,Nothing}=nothing,
    sim_end_date::Union{String,Nothing}=nothing,
    boundary_ids::Vector{String}=String[],
    lookahead_minutes::Int=24 * 60,
)
    src_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")
    dst_path = joinpath(BACKEND_DATA_DIR, "tasks", task_id, "timeseries.db")
    bd_labels = _load_boundary_labels(task_id)

    if !isfile(src_path)
        # 画布明确引用了边界却无源库：必须失败
        if isempty(boundary_ids)
            @warn "boundary_seeder: 源 DB 不存在" src_path
            return 0
        end
        error("项目边界库不存在: $(src_path)。请先在边界配置中提交数据后再运行任务。")
    end

    lookahead_minutes < 0 && error("lookahead_minutes 不能为负")

    # 计算仿真时间范围（分钟）
    sim_start_minutes = sim_start_time !== nothing ? time_label_to_minutes(sim_start_time) : nothing
    sim_end_minutes = sim_end_time !== nothing ? time_label_to_minutes(sim_end_time) : nothing
    sim_duration_minutes = if sim_start_minutes !== nothing && sim_end_minutes !== nothing
        sim_end_minutes - sim_start_minutes
    else
        nothing
    end
    has_calendar_range = sim_start_date !== nothing || sim_end_date !== nothing
    has_calendar_range && (sim_start_date === nothing || sim_end_date === nothing) &&
        error("仿真起始日期和终止日期必须同时提供")
    task_start_date = has_calendar_range ? Date(sim_start_date, dateformat"yyyy-mm-dd") : nothing
    task_end_date = has_calendar_range ? Date(sim_end_date, dateformat"yyyy-mm-dd") : nothing
    has_calendar_range && task_end_date < task_start_date && error("仿真终止日期不能早于起始日期")

    # boundary_id 集合（SQL 过滤）
    filter_ids = isempty(boundary_ids) ? String[] : unique(String.(boundary_ids))

    src_store = get_store(src_path)
    # config 按 source_id 缓存，避免每条序列重复 ensure_table + 查库
    config_cache = Dict{String,Any}()

    meta_rows = lock(src_store.write_lock) do
        if isempty(filter_ids)
            _query(src_store.db, """
                SELECT id, source_id, var_name
                FROM time_series_meta
                WHERE layer_id=? AND remark='planned'
            """, [layer_id])
        else
            placeholders = join(("?" for _ in filter_ids), ",")
            _query(src_store.db, """
                SELECT id, source_id, var_name
                FROM time_series_meta
                WHERE layer_id=? AND remark='planned' AND source_id IN ($placeholders)
            """, [layer_id, filter_ids...])
        end
    end

    seen_ids = Set{String}()
    pairs = Tuple{String,TimeSeries}[]

    for i in 1:length(meta_rows[1])
        sid = meta_rows[1][i]
        source_id = String(meta_rows[2][i])
        var_name = String(meta_rows[3][i])
        push!(seen_ids, source_id)

        data_rows = lock(src_store.write_lock) do
            _query(src_store.db,
                "SELECT ts, value FROM time_series_data WHERE series_id=?",
                [sid])
        end
        if isempty(data_rows[1])
            error("边界 $(_bd(bd_labels, source_id)) 没有时序数据点，请重新提交边界配置")
        end

        # 时间轴一次性解析为整数分钟，后续排序/截取不再走正则
        n = length(data_rows[1])
        src_ts_min = Vector{Int}(undef, n)
        src_vals = Vector{Float64}(undef, n)
        for k in 1:n
            src_ts_min[k] = time_label_to_minutes(String(data_rows[1][k]))
            src_vals[k] = Float64(data_rows[2][k])
        end
        perm = sortperm(src_ts_min)
        src_ts_min = src_ts_min[perm]
        src_vals = src_vals[perm]

        boundary_config = get!(config_cache, source_id) do
            get_boundary_config(src_path, source_id)
        end

        out_ts_min = Int[]
        out_vals = Float64[]

        if has_calendar_range
            boundary_config === nothing && error("边界 $(_bd(bd_labels, source_id)) 缺少日期元信息，请重新提交边界配置")
            boundary_config["timeMode"] == "calendar" || error(
                "边界 $(_bd(bd_labels, source_id)) 未绑定日期，不能用于日期范围仿真"
            )
            boundary_start_date = Date(boundary_config["calendarStartDate"], dateformat"yyyy-mm-dd")
            boundary_end_date = Date(boundary_config["calendarEndDate"], dateformat"yyyy-mm-dd")
            (task_start_date < boundary_start_date || task_end_date > boundary_end_date) && error(
                "仿真日期 $(sim_start_date) 至 $(sim_end_date) 超出边界 $(_bd(bd_labels, source_id)) 覆盖范围 " *
                "$(boundary_config["calendarStartDate"]) 至 $(boundary_config["calendarEndDate"])"
            )

            length(src_ts_min) >= 2 || error("边界 $(_bd(bd_labels, source_id)) 数据点不足，无法按日期截取")
            step_minutes = src_ts_min[2] - src_ts_min[1]
            step_minutes > 0 || error("边界 $(_bd(bd_labels, source_id)) 的时间步长无效")

            source_start_minutes = Dates.value(task_start_date - boundary_start_date) * 24 * 60
            calendar_duration_minutes = (Dates.value(task_end_date - task_start_date) + 1) * 24 * 60
            source_end_minutes = source_start_minutes + calendar_duration_minutes

            selected = findall(src_ts_min) do t
                t >= source_start_minutes && t < source_end_minutes
            end
            expected_count = calendar_duration_minutes ÷ step_minutes
            length(selected) == expected_count || error(
                "边界 $(_bd(bd_labels, source_id)) 在所选日期范围内应有 $(expected_count) 个点，实际为 $(length(selected)) 个点"
            )

            out_ts_min = [src_ts_min[j] - source_start_minutes for j in selected]
            out_vals = src_vals[selected]

            # look-ahead：窗口结束之后继续取源点，不够则循环窗口
            # 源侧绝对时间：任务窗结束点之后才是 look-ahead 真实点
            out_ts_min, out_vals = _append_lookahead(
                out_ts_min, out_vals,
                src_ts_min, src_vals,
                source_end_minutes,
                lookahead_minutes,
                step_minutes,
            )

        elseif sim_duration_minutes !== nothing
            if boundary_config !== nothing
                boundary_length_minutes = time_str_to_minutes(boundary_config["boundaryLength"])
                sim_duration_minutes > boundary_length_minutes && error(
                    "仿真时间范围（$(sim_duration_minutes)分钟）大于边界 $(_bd(bd_labels, source_id)) 数据长度（$(boundary_length_minutes)分钟），请缩短仿真范围或补充边界数据"
                )
            end

            if length(src_ts_min) >= 2
                step_minutes = src_ts_min[2] - src_ts_min[1]
                truncate_count = min(cld(sim_duration_minutes, step_minutes), length(src_ts_min))
                out_ts_min = src_ts_min[1:truncate_count]
                out_vals = src_vals[1:truncate_count]
                window_end = truncate_count * step_minutes
                out_ts_min, out_vals = _append_lookahead(
                    out_ts_min, out_vals,
                    src_ts_min, src_vals,
                    window_end,
                    lookahead_minutes,
                    step_minutes,
                )
            else
                out_ts_min = copy(src_ts_min)
                out_vals = copy(src_vals)
            end
        else
            # 无时间范围：垫到 覆盖长度+lookahead（循环），替代旧的固定翻倍
            step_minutes = length(src_ts_min) >= 2 ? src_ts_min[2] - src_ts_min[1] : 60
            cover = src_ts_min[end] + step_minutes
            target_end = cover + max(lookahead_minutes, 0)
            need = max(0, cld(target_end, step_minutes) - length(src_ts_min))
            out_ts_min = copy(src_ts_min)
            out_vals = copy(src_vals)
            if need > 0
                pad_vals = _cycle_pad_values(out_vals, need)
                last_t = out_ts_min[end]
                append!(out_ts_min, [last_t + k * step_minutes for k in 1:need])
                append!(out_vals, pad_vals)
            end
            @debug "[SEED] padded boundary (no sim range)" source_id var_name original=length(src_ts_min) total=length(out_vals) lookahead_minutes
        end

        timestamps = [minutes_to_time_label(t) for t in out_ts_min]
        push!(pairs, ( "$(source_id)|$(var_name)|planned#$(layer_id)", TimeSeries(timestamps, out_vals) ))
    end

    # fail-fast：画布引用但未找到的边界
    if !isempty(filter_ids)
        missing = sort!(collect(setdiff(Set(filter_ids), seen_ids)))
        isempty(missing) || error(
            "以下边界缺少 planned 数据，请先在边界配置中提交后再运行任务（任务层 $(layer_id)）:\n  - " *
            _format_boundary_list(bd_labels, missing)
        )
    end

    isempty(pairs) && return 0

    t_seed_start = time()
    # 单事务批量写入（write_timeseries_batch!）；perf 口径仍由外层 boundary_seed 计时
    write_timeseries_batch!(dst_path, pairs; overlay=false)
    @info "[SEED] boundary seed done" n_series=length(pairs) elapsed_s=round(time()-t_seed_start, digits=3)
    return length(pairs)
end
