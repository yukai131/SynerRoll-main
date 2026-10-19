using SQLite
using DBInterface
using Tables

function parse_ts_label(label::String)
    parts = split(label, "#"; limit=2)
    length(parts) == 2 || error("Invalid time-series label: $(label)")

    main_part, layer_id = parts
    main_fields = split(main_part, "|")
    length(main_fields) == 3 || error("Invalid time-series label: $(label)")

    return Dict(
        "source_id" => main_fields[1],
        "var_name" => main_fields[2],
        "remark" => main_fields[3],
        "layer_id" => layer_id,
    )
end

struct TimeSeries
    timestamps::Vector{String}
    values::Vector{Float64}

    function TimeSeries(timestamps::Vector{String}, values::Vector{<:Real})
        length(timestamps) == length(values) || error("TimeSeries timestamps and values must have the same length.")
        return new(timestamps, convert(Vector{Float64}, values))
    end

    function TimeSeries()
        return new(String[], Float64[])
    end
end

function merge_timeseries(ts1::TimeSeries, ts2::TimeSeries)
    merged = Dict{String,Float64}()

    for (timestamp, value) in zip(ts1.timestamps, ts1.values)
        merged[timestamp] = value
    end

    for (timestamp, value) in zip(ts2.timestamps, ts2.values)
        merged[timestamp] = value
    end

    sorted_timestamps = sort(collect(keys(merged)); lt=time_label_less_than)
    sorted_values = [merged[timestamp] for timestamp in sorted_timestamps]
    return TimeSeries(sorted_timestamps, sorted_values)
end

function get_value(ts::TimeSeries, time::String)
    exact_index = findfirst(==(time), ts.timestamps)
    if exact_index !== nothing
        return ts.values[exact_index]
    end

    target_minutes = time_label_to_minutes(time)
    closest_index = nothing
    closest_minutes = -1

    for (index, timestamp) in enumerate(ts.timestamps)
        current_minutes = time_label_to_minutes(timestamp)
        if current_minutes < target_minutes && current_minutes > closest_minutes
            closest_minutes = current_minutes
            closest_index = index
        end
    end

    closest_index === nothing && error("Time $(time) does not exist in the series and no earlier fallback is available.")
    return ts.values[closest_index]
end

function get_values(ts::TimeSeries, times::Vector{String})
    return [get_value(ts, time) for time in times]
end

"""
    truncate_timeseries(ts::TimeSeries, sim_start::String, sim_end::Union{String,Nothing})

按仿真范围 [sim_start, sim_end) 截取时序数据。
sim_end 为 nothing 时表示无上界，保留 sim_start 之后的全部数据。
"""
function truncate_timeseries(ts::TimeSeries, sim_start::String, sim_end::Union{String,Nothing})
    start_min = time_label_to_minutes(sim_start)
    end_min = sim_end !== nothing ? time_label_to_minutes(sim_end) : nothing

    mask = map(ts.timestamps) do t
        m = time_label_to_minutes(t)
        m >= start_min && (end_min === nothing || m < end_min)
    end
    return TimeSeries(ts.timestamps[mask], ts.values[mask])
end

# ── 读写探测计数（前端卡顿排查）──
# 仅累计耗时/次数，不写文件；由 /api/task/{id}/data 的 probe 一并返回
const TS_PROBE_LOCK = ReentrantLock()
const TS_PROBE = Dict{String,Float64}(
    "write_count" => 0.0,
    "write_ms" => 0.0,
    "merge_count" => 0.0,
    "merge_ms" => 0.0,
    "read_count" => 0.0,
    "read_ms" => 0.0,
    "lock_wait_ms" => 0.0,
    "max_lock_wait_ms" => 0.0,
)

function ts_probe_add!(key::String, ms::Float64)
    lock(TS_PROBE_LOCK) do
        TS_PROBE[key] = get(TS_PROBE, key, 0.0) + ms
    end
    return nothing
end

function ts_probe_note_lock_wait!(ms::Float64)
    lock(TS_PROBE_LOCK) do
        TS_PROBE["lock_wait_ms"] = get(TS_PROBE, "lock_wait_ms", 0.0) + ms
        TS_PROBE["max_lock_wait_ms"] = max(get(TS_PROBE, "max_lock_wait_ms", 0.0), ms)
    end
    return nothing
end

function ts_probe_snapshot()::Dict{String,Float64}
    lock(TS_PROBE_LOCK) do
        return copy(TS_PROBE)
    end
end

function ts_probe_reset!()
    lock(TS_PROBE_LOCK) do
        empty!(TS_PROBE)
    end
    return nothing
end

mutable struct SQLiteTimeSeriesStore
    db::SQLite.DB
    write_lock::ReentrantLock
    db_path::String
    flexibility_initialized::Bool
end

"""
    SQLiteTimeSeriesStore(db_path::String)

打开（或创建）指定路径的 SQLite 时序库文件。
注意：`db_path` 必传；老版本的无参调用已废弃。
"""
function SQLiteTimeSeriesStore(db_path::String)
    mkpath(dirname(db_path))
    db = SQLite.DB(db_path)

    # 开启 WAL 模式，支持并发读 + 单写者（计算任务方案要求第三方 ingest 与任务自身写不冲突）
    # 注意：这里不能用 _exec，因为 _exec 在 store 创建之前还不可用
    # 直接用 DBInterface.prepare + close! 确保 stmt 被 finalize
    function _safe_exec(d, sql)
        s = DBInterface.prepare(d, sql)
        try
            DBInterface.execute(s)
        finally
            DBInterface.close!(s)
        end
    end

    try
        _safe_exec(db, "PRAGMA journal_mode=WAL")
        _safe_exec(db, "PRAGMA busy_timeout=5000")
    catch
        # PRAGMA 失败不致命（如只读场景），但 WAL 还是要尽量开
    end

    _safe_exec(db, """
    CREATE TABLE IF NOT EXISTS time_series_meta (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id   TEXT NOT NULL,
        var_name    TEXT NOT NULL,
        remark      TEXT NOT NULL,
        layer_id    TEXT NOT NULL,
        created_at  TEXT DEFAULT (datetime('now')),
        updated_at  TEXT DEFAULT (datetime('now')),
        UNIQUE(source_id, var_name, remark, layer_id)
    )
""")

    _safe_exec(db, """
    CREATE TABLE IF NOT EXISTS time_series_data (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        series_id   INTEGER NOT NULL REFERENCES time_series_meta(id) ON DELETE CASCADE,
        ts          TEXT NOT NULL,
        value       REAL NOT NULL
    )
""")

    _safe_exec(db, "CREATE INDEX IF NOT EXISTS idx_data_series ON time_series_data(series_id)")
    # 点查/范围查：series_id + ts；覆盖 get_value/previous/upper 的按时刻读取
    _safe_exec(db, "CREATE INDEX IF NOT EXISTS idx_data_series_ts ON time_series_data(series_id, ts)")
    # ts_min：整数分钟，floor 点查走索引；不改业务，仅加速
    try
        col_rows = _query(db, "PRAGMA table_info(time_series_data)")
        has_tsmin = false
        if !isempty(col_rows[1])
            for i in 1:length(col_rows[1])
                if String(col_rows[2][i]) == "ts_min"
                    has_tsmin = true
                    break
                end
            end
        end
        if !has_tsmin
            _safe_exec(db, "ALTER TABLE time_series_data ADD COLUMN ts_min INTEGER")
        end
        _safe_exec(db, "CREATE INDEX IF NOT EXISTS idx_data_series_tsmin ON time_series_data(series_id, ts_min)")
        _safe_exec(db, "UPDATE time_series_data SET ts_min = (CAST(substr(ts, 1, instr(ts, ':') - 1) AS INTEGER) * 60 + CAST(substr(ts, instr(ts, ':') + 1) AS INTEGER)) WHERE ts_min IS NULL")
    catch
    end
    try
        _safe_exec(db, "PRAGMA mmap_size=268435456")
        _safe_exec(db, "PRAGMA cache_size=-65536")
        _safe_exec(db, "PRAGMA temp_store=MEMORY")
    catch
    end

    # ── 回溯模式：按求解步记录完整快照 ──────────────────────────────
    _safe_exec(db, """
    CREATE TABLE IF NOT EXISTS solve_trace_meta (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id      TEXT NOT NULL,
        step         INTEGER NOT NULL,
        layer_id     TEXT NOT NULL,
        sim_time     TEXT NOT NULL,
        created_at   TEXT DEFAULT (datetime('now')),
        UNIQUE(task_id, step)
    )
""")

    _safe_exec(db, """
    CREATE TABLE IF NOT EXISTS solve_trace_data (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        trace_id     INTEGER NOT NULL REFERENCES solve_trace_meta(id) ON DELETE CASCADE,
        data_key     TEXT NOT NULL,
        ts           TEXT NOT NULL,
        value        REAL NOT NULL
    )
""")

    _safe_exec(db, "CREATE INDEX IF NOT EXISTS idx_trace_data ON solve_trace_data(trace_id)")
    _safe_exec(db, "CREATE INDEX IF NOT EXISTS idx_trace_meta_task ON solve_trace_meta(task_id, step)")

    return SQLiteTimeSeriesStore(db, ReentrantLock(), db_path, false)
end

"""
    STORE_REGISTRY

按 db_path 缓存已打开的 SQLiteTimeSeriesStore，避免每个请求都重新打开/建表。
key = 完整 db_path 字符串（绝对路径或相对 backend/ 的路径都按字符串存）。
"""
const STORE_REGISTRY = Dict{String,SQLiteTimeSeriesStore}()
const STORE_REGISTRY_LOCK = ReentrantLock()

"""
    get_store(db_path::String) -> SQLiteTimeSeriesStore

按 db_path 取/建 TS 库句柄。同一个 db_path 多次调用复用同一个 handle。
"""
function get_store(db_path::String)
    lock(STORE_REGISTRY_LOCK) do
        return get!(STORE_REGISTRY, db_path) do
            SQLiteTimeSeriesStore(db_path)
        end
    end
end

"""
    close_store(db_path::String)

从 registry 移除 db_path 对应的句柄（项目级 boundary DB 删除时调用，释放 handle）。
下次 get_store 会重新打开。
"""
function close_store(db_path::String)
    clear_series_id_cache!(db_path)
    snapshot_clear!(db_path)
    store = lock(STORE_REGISTRY_LOCK) do
        pop!(STORE_REGISTRY, db_path, nothing)
    end
    if store !== nothing
        try
            DBInterface.close!(store.db)
        catch
            # 已关闭或不可关闭时忽略
        end
    end
    return nothing
end

function _key_to_meta_params(data_key::String)
    # key format: "source_id|var_name|remark#layer_id"
    # 对边界业务：source_id = projects.json 中的 BoundaryID
    # 对组件结果：source_id = projects.json 中的 nodeID
    main_part, layer_id = split(data_key, "#"; limit=2)
    length(main_part) == 0 && error("Invalid key: $data_key")
    main_fields = split(main_part, "|")
    length(main_fields) == 3 || error("Invalid key: $data_key, got main_fields=$(main_fields)")
    source_id, var_name, remark = main_fields[1], main_fields[2], main_fields[3]
    return source_id, var_name, remark, layer_id
end

"""
    _query(db, sql, params) -> columntable result

查询辅助函数。prepare → execute → columntable → close!(stmt)。
使用 DBInterface.close!(stmt::Stmt) = _close_stmt! = sqlite3_finalize，
确保 stmt 被彻底释放（而非仅 sqlite3_reset）。
"""
function _query(db::SQLite.DB, sql::String, params=())
    stmt = DBInterface.prepare(db, sql)
    try
        result = DBInterface.execute(stmt, params) |> columntable
        return result
    finally
        DBInterface.close!(stmt)   # → sqlite3_finalize，彻底销毁 stmt
    end
end

"""
    _exec(db, sql, params)

DML/DDL 辅助函数。prepare → execute → close!(stmt)。
使用 DBInterface.close!(stmt::Stmt) = _close_stmt! = sqlite3_finalize，
确保 stmt 在执行完毕后被彻底释放，不留活跃 stmt 给事务 COMMIT。

注意：不要用 SQLite.execute(db, sql, params)，它创建的临时 Stmt
在某些 Julia/SQLite.jl 版本中 finalize 时机不可靠。
"""
function _exec(db::SQLite.DB, sql::String, params=())
    stmt = DBInterface.prepare(db, sql)
    try
        DBInterface.execute(stmt, params)
    finally
        DBInterface.close!(stmt)   # → sqlite3_finalize
    end
    return nothing
end

function get_ts(db_path::String, data_key::String;
    min_minutes::Union{Nothing,Int}=nothing, max_minutes::Union{Nothing,Int}=nothing)
    store = get_store(db_path)
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)

    t0 = time()
    lock(store.write_lock) do
        wait_ms = (time() - t0) * 1000
        ts_probe_note_lock_wait!(wait_ms)
        if wait_ms > 50
            @warn "[LOCK] get_ts: lock wait" data_key wait_s=round(wait_ms / 1000, digits=3)
        end
        meta_rows = _query(store.db,
            "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
            [source_id, var_name, remark, layer_id])

        isempty(meta_rows[1]) && return nothing
        series_id = meta_rows[1][1]

        sql = "SELECT ts, value FROM time_series_data WHERE series_id=?"
        params = Any[series_id]
        if min_minutes !== nothing
            sql *= " AND ts_min>=?"
            push!(params, min_minutes)
        end
        if max_minutes !== nothing
            sql *= " AND ts_min<?"
            push!(params, max_minutes)
        end
        data_rows = _query(store.db, sql * " ORDER BY ts_min", params)

        isempty(data_rows[1]) && return TimeSeries()
        timestamps = Vector{String}(data_rows[1])
        values = Vector{Float64}(data_rows[2])
        return TimeSeries(timestamps, values)
    end
end

"""
    _write_ts(store, data_key, ts)

内部写入原语，调用方必须已持有 store.write_lock。
在一个事务内完成 meta upsert + data DELETE + 批量 INSERT。
"""
function _write_ts(store::SQLiteTimeSeriesStore, data_key::String, ts::TimeSeries)
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)

    # 使用手动 BEGIN/COMMIT/ROLLBACK，不走 DBInterface.transaction（避免 savepoint 问题）
    _exec(store.db, "BEGIN IMMEDIATE")
    try
        # 插入或更新 meta
        _exec(store.db,
            "INSERT INTO time_series_meta (source_id, var_name, remark, layer_id, updated_at)
             VALUES (?, ?, ?, ?, datetime('now'))
             ON CONFLICT(source_id, var_name, remark, layer_id)
             DO UPDATE SET updated_at = datetime('now')",
            [source_id, var_name, remark, layer_id])

        # 查询 series_id
        meta_rows = _query(store.db,
            "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
            [source_id, var_name, remark, layer_id])
        series_id = meta_rows[1][1]

        # 删除旧数据
        _exec(store.db, "DELETE FROM time_series_data WHERE series_id=?", [series_id])

        # 按时间数值排序后用 prepared statement 批量插入
        perm = sortperm(ts.timestamps; lt=time_label_less_than)
        sorted_ts = ts.timestamps[perm]
        sorted_vals = ts.values[perm]

        insert_stmt = DBInterface.prepare(store.db,
            "INSERT INTO time_series_data (series_id, ts, value, ts_min) VALUES (?, ?, ?, ?)")
        try
            for (t, v) in zip(sorted_ts, sorted_vals)
                DBInterface.execute(insert_stmt, [series_id, t, v, time_label_to_minutes(t)])
            end
        finally
            DBInterface.close!(insert_stmt)
        end

        _exec(store.db, "COMMIT")
    catch e
        try; _exec(store.db, "ROLLBACK"); catch; end
        rethrow(e)
    end
    snapshot_publish_if_loaded!(store.db_path, data_key, ts; overlay=false)
    # 刷新 series_id 缓存，避免新建 meta 后反复查
    try
        resolve_series_id(store.db_path, source_id, var_name, remark, layer_id)
    catch
    end
    return nothing
end

function set_ts(db_path::String, data_key::String, ts::TimeSeries)
    store = get_store(db_path)
    t0 = time()
    lock(store.write_lock) do
        t_locked = time()
        wait_ms = (t_locked - t0) * 1000
        ts_probe_note_lock_wait!(wait_ms)
        if wait_ms > 50
            @warn "[LOCK] set_ts: lock wait" data_key wait_s=round(wait_ms / 1000, digits=3)
        end
        tw = time()
        _write_ts(store, data_key, ts)
        ts_probe_add!("write_ms", (time() - tw) * 1000)
        ts_probe_add!("write_count", 1.0)
    end
    return nothing
end

"""
    set_ts_merge(db_path, data_key, new_ts)

合并写入：new_ts 覆盖重叠时刻，保留旧数据中不重叠的时刻。
性能优化：只删除/写入 new_ts 覆盖的时间点，不整条读出再重写。
调用方不必持有 write_lock。
"""
function set_ts_merge(db_path::String, data_key::String, new_ts::TimeSeries)
    store = get_store(db_path)
    t0 = time()
    lock(store.write_lock) do
        wait_ms = (time() - t0) * 1000
        ts_probe_note_lock_wait!(wait_ms)
        source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
        isempty(new_ts.timestamps) && return nothing

        tw = time()
        _exec(store.db, "BEGIN IMMEDIATE")
        try
            _exec(store.db,
                "INSERT INTO time_series_meta (source_id, var_name, remark, layer_id, updated_at)
                 VALUES (?, ?, ?, ?, datetime('now'))
                 ON CONFLICT(source_id, var_name, remark, layer_id)
                 DO UPDATE SET updated_at = datetime('now')",
                [source_id, var_name, remark, layer_id])

            meta_rows = _query(store.db,
                "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
                [source_id, var_name, remark, layer_id])
            series_id = meta_rows[1][1]

            # 只覆盖 new_ts 涉及的时刻，避免 DELETE 全量 + 重插
            placeholders = join(("?" for _ in eachindex(new_ts.timestamps)), ",")
            _exec(store.db,
                "DELETE FROM time_series_data WHERE series_id=? AND ts IN ($placeholders)",
                [series_id, new_ts.timestamps...])

            perm = sortperm(new_ts.timestamps; lt=time_label_less_than)
            insert_stmt = DBInterface.prepare(store.db,
                "INSERT INTO time_series_data (series_id, ts, value, ts_min) VALUES (?, ?, ?, ?)")
            try
                for i in perm
                    DBInterface.execute(insert_stmt,
                        [series_id, new_ts.timestamps[i], new_ts.values[i], time_label_to_minutes(new_ts.timestamps[i])])
                end
            finally
                DBInterface.close!(insert_stmt)
            end

            _exec(store.db, "COMMIT")
            snapshot_publish_if_loaded!(store.db_path, data_key, new_ts)
            ts_probe_add!("merge_ms", (time() - tw) * 1000)
            ts_probe_add!("merge_count", 1.0)
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end
    end
    return nothing
end

function delete_ts(db_path::String, data_key::String)
    store = get_store(db_path)
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)

    lock(store.write_lock) do
        meta_rows = _query(store.db,
            "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
            [source_id, var_name, remark, layer_id])
        isempty(meta_rows[1]) && return nothing
        series_id = meta_rows[1][1]

        _exec(store.db, "BEGIN IMMEDIATE")
        try
            _exec(store.db, "DELETE FROM time_series_data WHERE series_id=?", [series_id])
            _exec(store.db, "DELETE FROM time_series_meta WHERE id=?", [series_id])
            _exec(store.db, "COMMIT")
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end
    end
    return nothing
end

function list_all_keys(db_path::String)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT source_id, var_name, remark, layer_id FROM time_series_meta")
        isempty(rows[1]) && return String[]
        return ["$(rows[1][i])|$(rows[2][i])|$(rows[3][i])#$(rows[4][i])" for i in 1:length(rows[1])]
    end
end

function query_ts(db_path::String;
    source_id::Union{String,Nothing}=nothing,
    var_name::Union{String,Nothing}=nothing,
    remark::Union{String,Nothing}=nothing,
    layer_id::Union{String,Nothing}=nothing,
)

    store = get_store(db_path)
    t0 = time()
    lock(store.write_lock) do
        t_locked = time()
        wait_s = t_locked - t0
        if wait_s > 0.05
            @warn "[LOCK] query_ts: lock wait" source_id wait_s=round(wait_s, digits=3)
        end
        sql = "SELECT id, source_id, var_name, remark, layer_id FROM time_series_meta WHERE 1=1"
        params = String[]
        if source_id !== nothing
            sql *= " AND source_id=?"
            push!(params, source_id)
        end
        if var_name !== nothing
            sql *= " AND var_name=?"
            push!(params, var_name)
        end
        if remark !== nothing
            sql *= " AND remark=?"
            push!(params, remark)
        end
        if layer_id !== nothing
            sql *= " AND layer_id=?"
            push!(params, layer_id)
        end
        rows = _query(store.db, sql, params)
        if isempty(rows[1])
            @debug "query_ts: 未找到匹配的时序记录" source_id var_name remark layer_id
            return nothing, nothing
        end
        if length(rows[1]) > 1
            @error "query_ts: 匹配到多条记录（期望唯一）" source_id var_name remark layer_id count=length(rows[1])
            return nothing, nothing
        end

        series_id = rows[1][1]
        label = "$(rows[2][1])|$(rows[3][1])|$(rows[4][1])#$(rows[5][1])"

        data_rows = _query(store.db,
            "SELECT ts, value FROM time_series_data WHERE series_id=?", [series_id])
        if isempty(data_rows[1])
            return TimeSeries(), label
        end
        timestamps = Vector{String}(data_rows[1])
        values = Vector{Float64}(data_rows[2])
        perm = sortperm(timestamps; lt=time_label_less_than)
        return TimeSeries(timestamps[perm], values[perm]), label
    end
end

function clear_cache(db_path::String)
    store = get_store(db_path)
    lock(store.write_lock) do
        _exec(store.db, "BEGIN IMMEDIATE")
        try
            _exec(store.db, "DELETE FROM time_series_data")
            _exec(store.db, "DELETE FROM time_series_meta")
            _exec(store.db, "COMMIT")
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end
    end
    return nothing
end

function get_all_series_meta(db_path::String)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT id, source_id, var_name, remark, layer_id, created_at, updated_at FROM time_series_meta")
        if isempty(rows[1])
            return []
        end
        return [Dict(
            "id" => rows[1][i],
            "source_id" => rows[2][i],
            "var_name" => rows[3][i],
            "remark" => rows[4][i],
            "layer_id" => rows[5][i],
            "created_at" => rows[6][i],
            "updated_at" => rows[7][i]
        ) for i in 1:length(rows[1])]
    end
end

function get_series_data(db_path::String, series_id::Int)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT ts, value FROM time_series_data WHERE series_id=?", [series_id])
        isempty(rows[1]) && return TimeSeries()
        timestamps = Vector{String}(rows[1])
        values = Vector{Float64}(rows[2])
        perm = sortperm(timestamps; lt=time_label_less_than)
        return TimeSeries(timestamps[perm], values[perm])
    end
end

# ════════════════════════════════════════════════════════════════
# 回溯模式（Trace）函数
# ════════════════════════════════════════════════════════════════

"""
    save_solve_trace!(db_path, task_id, step, layer_id, sim_time, results)

保存一次求解步的完整快照到回溯表。
`results` 为 `Vector{Tuple{String, TimeSeries}}`，每项为 (data_key, timeseries)。
"""
function save_solve_trace!(db_path::String, task_id::String, step::Int,
    layer_id::String, sim_time::String,
    results::Vector{Tuple{String,TimeSeries}})

    store = get_store(db_path)

    lock(store.write_lock) do
        _exec(store.db, "BEGIN IMMEDIATE")
        try
            # 插入 trace_meta（step 冲突时更新）
            _exec(store.db,
                """INSERT INTO solve_trace_meta (task_id, step, layer_id, sim_time)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(task_id, step) DO UPDATE SET layer_id=?, sim_time=?, created_at=datetime('now')""",
                [task_id, step, layer_id, sim_time, layer_id, sim_time])

            meta_rows = _query(store.db,
                "SELECT id FROM solve_trace_meta WHERE task_id=? AND step=?",
                [task_id, step])
            trace_id = meta_rows[1][1]

            # 删除旧 trace_data（step 冲突场景）
            _exec(store.db, "DELETE FROM solve_trace_data WHERE trace_id=?", [trace_id])

            # 用 prepared statement 批量插入所有数据点
            insert_stmt = DBInterface.prepare(store.db,
                "INSERT INTO solve_trace_data (trace_id, data_key, ts, value) VALUES (?, ?, ?, ?)")
            try
                for (data_key, ts) in results
                    perm = sortperm(ts.timestamps; lt=time_label_less_than)
                    for i in perm
                        DBInterface.execute(insert_stmt,
                            [trace_id, data_key, ts.timestamps[i], ts.values[i]])
                    end
                end
            finally
                DBInterface.close!(insert_stmt)
            end

            _exec(store.db, "COMMIT")
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end
    end

    return nothing
end

"""
    get_solve_trace_steps(db_path, task_id)

返回任务的所有求解步列表：`Vector{Dict}`，每项含 step, layer_id, sim_time。
"""
function get_solve_trace_steps(db_path::String, task_id::String)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT step, layer_id, sim_time FROM solve_trace_meta WHERE task_id=? ORDER BY step",
            [task_id])
        isempty(rows[1]) && return Dict{String,Any}[]
        return [Dict(
            "step" => rows[1][i],
            "layerId" => rows[2][i],
            "simTime" => rows[3][i],
        ) for i in 1:length(rows[1])]
    end
end

"""
    get_solve_trace_data(db_path, task_id, step)

返回指定求解步的全部数据：`Dict{String, TimeSeries}`，key 为 data_key。
"""
function get_solve_trace_data(db_path::String, task_id::String, step::Int)
    store = get_store(db_path)
    lock(store.write_lock) do
        meta_rows = _query(store.db,
            "SELECT id FROM solve_trace_meta WHERE task_id=? AND step=?",
            [task_id, step])
        isempty(meta_rows[1]) && return Dict{String,TimeSeries}()
        trace_id = meta_rows[1][1]

        data_rows = _query(store.db,
            "SELECT data_key, ts, value FROM solve_trace_data WHERE trace_id=?",
            [trace_id])
        isempty(data_rows[1]) && return Dict{String,TimeSeries}()

        # 按 data_key 分组
        grouped = Dict{String,Vector{Tuple{String,Float64}}}()
        for i in 1:length(data_rows[1])
            key = String(data_rows[1][i])
            ts_val = (String(data_rows[2][i]), Float64(data_rows[3][i]))
            if haskey(grouped, key)
                push!(grouped[key], ts_val)
            else
                grouped[key] = [ts_val]
            end
        end

        # 转为 TimeSeries
        result = Dict{String,TimeSeries}()
        for (key, pairs) in grouped
            perm = sortperm([p[1] for p in pairs]; lt=time_label_less_than)
            sorted_pairs = pairs[perm]
            result[key] = TimeSeries(
                [p[1] for p in sorted_pairs],
                [p[2] for p in sorted_pairs],
            )
        end
        return result
    end
end


# ═══════════════════════════════════════════════════════════════════════════
# 结果内存快照（性能）：API 只读快照，避免与求解写库抢锁/全表扫
# ═══════════════════════════════════════════════════════════════════════════

const RESULT_SNAPSHOT = Dict{String,Dict{String,Dict{String,Float64}}}()
const RESULT_SNAPSHOT_LOCK = ReentrantLock()

"""用整段 TimeSeries 覆盖快照中的一条序列"""
function snapshot_put!(db_path::String, data_key::String, ts::TimeSeries)
    lock(RESULT_SNAPSHOT_LOCK) do
        series_map = get!(RESULT_SNAPSHOT, db_path, Dict{String,Dict{String,Float64}}())
        series_map[data_key] = Dict(zip(ts.timestamps, ts.values))
    end
    return nothing
end

"""增量合并到快照（new_ts 覆盖重叠时刻）"""
function snapshot_merge!(db_path::String, data_key::String, new_ts::TimeSeries)
    isempty(new_ts.timestamps) && return nothing
    lock(RESULT_SNAPSHOT_LOCK) do
        series_map = get!(RESULT_SNAPSHOT, db_path, Dict{String,Dict{String,Float64}}())
        points = get!(series_map, data_key, Dict{String,Float64}())
        for (timestamp, value) in zip(new_ts.timestamps, new_ts.values)
            points[timestamp] = value
        end
    end
    return nothing
end

"""BFF 直读库时不维护重复快照；仅给已使用 Julia /data 的订阅者发布已提交数据。"""
function snapshot_publish_if_loaded!(db_path::String, data_key::String, ts::TimeSeries; overlay::Bool=true)
    lock(RESULT_SNAPSHOT_LOCK) do
        haskey(RESULT_SNAPSHOT, db_path) || return nothing
        overlay ? snapshot_merge!(db_path, data_key, ts) : snapshot_put!(db_path, data_key, ts)
    end
    return nothing
end

function snapshot_clear!(db_path::String)
    lock(RESULT_SNAPSHOT_LOCK) do
        delete!(RESULT_SNAPSHOT, db_path)
    end
    return nothing
end

"""
    snapshot_rows(db_path; min_minutes=0, skip_boundary=false)

从内存快照组装 rows；快照为空时从 SQLite 加载一次。
返回 (rows::Vector{Dict}, probe::Dict)
"""
function snapshot_rows(db_path::String; min_minutes::Integer=0, skip_boundary::Bool=false)
    t0 = time()
    loaded = false
    # 快照空则从 DB 灌一次
    need_load = lock(RESULT_SNAPSHOT_LOCK) do
        !haskey(RESULT_SNAPSHOT, db_path) || isempty(RESULT_SNAPSHOT[db_path])
    end
    if need_load
        t_load = time()
        store = get_store(db_path)
        lock(store.write_lock) do
            data_rows = _query(store.db, """
                SELECT m.source_id, m.var_name, m.remark, m.layer_id, d.ts, d.value
                FROM time_series_data d
                JOIN time_series_meta m ON d.series_id = m.id
            """)
            n = isempty(data_rows[1]) ? 0 : length(data_rows[1])
            tmp = Dict{String,Dict{String,Float64}}()
            for i in 1:n
                key = "$(String(data_rows[1][i]))|$(String(data_rows[2][i]))|$(String(data_rows[3][i]))#$(String(data_rows[4][i]))"
                ts = String(data_rows[5][i])
                val = Float64(data_rows[6][i])
                slot = get!(tmp, key, Dict{String,Float64}())
                slot[ts] = val
            end
            lock(RESULT_SNAPSHOT_LOCK) do
                RESULT_SNAPSHOT[db_path] = tmp
            end
        end
        loaded = true
        t_load_ms = (time() - t_load) * 1000
    else
        t_load_ms = 0.0
    end

    t_build = time()
    all_rows = Dict{String,Any}[]
    series_set = Set{String}()
    max_ts_min = 0
    max_ts_label = ""
    raw_points = 0
    snapshot = lock(RESULT_SNAPSHOT_LOCK) do
        Dict(key => copy(points) for (key, points) in RESULT_SNAPSHOT[db_path])
    end
    for (data_key, points) in snapshot
        source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
        if skip_boundary && startswith(source_id, "b_")
            continue
        end
        for tlabel in sort!(collect(keys(points)); lt=time_label_less_than)
            raw_points += 1
            m = 0
            try
                m = time_label_to_minutes(tlabel)
            catch
                continue
            end
            if min_minutes > 0 && m < min_minutes
                continue
            end
            push!(series_set, "$(source_id)|$(var_name)|$(layer_id)")
            if m > max_ts_min && !startswith(source_id, "b_")
                max_ts_min = m
                max_ts_label = tlabel
            end
            push!(all_rows, Dict(
                "sourceId" => source_id,
                "varName" => var_name,
                "remark" => remark,
                "layerId" => layer_id,
                "ts" => tlabel,
                "value" => points[tlabel],
            ))
        end
    end
    build_ms = (time() - t_build) * 1000
    probe = Dict{String,Any}(
        "from_snapshot" => true,
        "snapshot_loaded" => loaded,
        "snapshot_load_ms" => t_load_ms,
        "query_ms" => t_load_ms,
        "build_ms" => build_ms,
        "series_count" => length(series_set),
        "row_count" => length(all_rows),
        "raw_point_count" => raw_points,
        "max_device_ts" => max_ts_label,
        "max_device_min" => max_ts_min,
        "min_minutes" => min_minutes,
        "skip_boundary" => skip_boundary,
        "total_ms" => (time() - t0) * 1000,
    )
    return all_rows, probe
end


# ═══════════════════════════════════════════════════════════════════════════
# 点查/窄查询（避免“查一点读全序列”导致越跑越慢）
# ts 格式 "H:MM"，SQL 内解析为分钟以便索引过滤
# ═══════════════════════════════════════════════════════════════════════════

const TS_MIN_EXPR = "(CAST(substr(ts, 1, instr(ts, ':') - 1) AS INTEGER) * 60 + CAST(substr(ts, instr(ts, ':') + 1) AS INTEGER))"

# series_id 解析缓存：db_path => (meta_key => series_id)
const SERIES_ID_CACHE = Dict{String,Dict{String,Int}}()
const SERIES_ID_CACHE_LOCK = ReentrantLock()

function _meta_cache_key(source_id, var_name, remark, layer_id)
    return string(source_id, "|", var_name, "|", remark, "#", layer_id)
end

function resolve_series_id(db_path::String, source_id, var_name, remark, layer_id)::Union{Int,Nothing}
    ck = _meta_cache_key(source_id, var_name, remark, layer_id)
    cached = lock(SERIES_ID_CACHE_LOCK) do
        get(get(SERIES_ID_CACHE, db_path, Dict{String,Int}()), ck, nothing)
    end
    cached !== nothing && return cached

    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
            [source_id, var_name, remark, layer_id])
        isempty(rows[1]) && return nothing
        sid = Int(rows[1][1])
        lock(SERIES_ID_CACHE_LOCK) do
            m = get!(SERIES_ID_CACHE, db_path, Dict{String,Int}())
            m[ck] = sid
        end
        return sid
    end
end

function clear_series_id_cache!(db_path::String)
    lock(SERIES_ID_CACHE_LOCK) do
        delete!(SERIES_ID_CACHE, db_path)
    end
    return nothing
end

"""
    get_ts_exact(db_path, data_key, ts)

精确时刻点查。找不到返回 nothing（不读整条序列）。
"""
function get_ts_exact(db_path::String, data_key::String, ts::String)::Union{Float64,Nothing}
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
    sid = resolve_series_id(db_path, source_id, var_name, remark, layer_id)
    sid === nothing && return nothing
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT value FROM time_series_data WHERE series_id=? AND ts=? LIMIT 1",
            [sid, ts])
        isempty(rows[1]) && return nothing
        return Float64(rows[1][1])
    end
end

"""
    get_ts_floor(db_path, data_key, ts)

取 <= ts 的最近一点（与 get_value 的 floor 回退一致）。
"""
function get_ts_floor(db_path::String, data_key::String, ts::String)::Union{Float64,Nothing}
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
    sid = resolve_series_id(db_path, source_id, var_name, remark, layer_id)
    sid === nothing && return nothing
    target = time_label_to_minutes(ts)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT value FROM time_series_data WHERE series_id=? AND ts_min <= ?
             ORDER BY ts_min DESC LIMIT 1",
            [sid, target])
        isempty(rows[1]) && return nothing
        return Float64(rows[1][1])
    end
end

"""
    get_ts_floor_pair(db_path, data_key, ts)

返回 (时间标签, 数值) 的 floor 点；无则 nothing。
"""
function get_ts_floor_pair(db_path::String, data_key::String, ts::String)::Union{Tuple{String,Float64},Nothing}
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
    sid = resolve_series_id(db_path, source_id, var_name, remark, layer_id)
    sid === nothing && return nothing
    target = time_label_to_minutes(ts)
    store = get_store(db_path)
    lock(store.write_lock) do
        rows = _query(store.db,
            "SELECT ts, value FROM time_series_data WHERE series_id=? AND ts_min <= ?
             ORDER BY ts_min DESC LIMIT 1",
            [sid, target])
        isempty(rows[1]) && return nothing
        return (String(rows[1][1]), Float64(rows[1][2]))
    end
end

"""
    get_ts_values_at(db_path, data_key, times)

对多个时刻做 floor 点查，返回 Vector{Float64}。语义同 get_values∘get_ts。
"""
function get_ts_values_at(db_path::String, data_key::String, times::Vector{String})
    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)
    sid = resolve_series_id(db_path, source_id, var_name, remark, layer_id)
    sid === nothing && error("series not found for $(data_key)")
    store = get_store(db_path)
    out = Vector{Float64}(undef, length(times))
    lock(store.write_lock) do
        stmt = DBInterface.prepare(store.db,
            "SELECT value FROM time_series_data WHERE series_id=? AND ts_min <= ?
             ORDER BY ts_min DESC LIMIT 1")
        try
            for (i, t) in enumerate(times)
                target = time_label_to_minutes(t)
                rows = DBInterface.execute(stmt, [sid, target]) |> columntable
                if isempty(rows[1])
                    error("Time $(t) does not exist in the series and no earlier fallback is available.")
                end
                out[i] = Float64(rows[1][1])
            end
        finally
            DBInterface.close!(stmt)
        end
    end
    return out
end

"""
    query_ts_exact / query_ts_floor

按 meta 条件定位序列后做单点读取。
"""
function query_ts_exact(db_path::String;
    source_id=nothing, var_name=nothing, remark=nothing, layer_id=nothing, ts::String="")

    key = _query_unique_data_key(db_path; source_id=source_id, var_name=var_name, remark=remark, layer_id=layer_id)
    key === nothing && return nothing
    return get_ts_exact(db_path, key, ts)
end

function query_ts_floor(db_path::String;
    source_id=nothing, var_name=nothing, remark=nothing, layer_id=nothing, ts::String="")

    key = _query_unique_data_key(db_path; source_id=source_id, var_name=var_name, remark=remark, layer_id=layer_id)
    key === nothing && return nothing
    return get_ts_floor(db_path, key, ts)
end

"""按条件找唯一 data_key；无匹配或不唯一返回 nothing"""
function _query_unique_data_key(db_path::String;
    source_id=nothing, var_name=nothing, remark=nothing, layer_id=nothing, strict::Bool=false)

    store = get_store(db_path)
    return lock(store.write_lock) do
        sql = "SELECT id, source_id, var_name, remark, layer_id FROM time_series_meta WHERE 1=1"
        params = Any[]
        if source_id !== nothing
            sql *= " AND source_id=?"
            push!(params, source_id)
        end
        if var_name !== nothing
            sql *= " AND var_name=?"
            push!(params, var_name)
        end
        if remark !== nothing
            sql *= " AND remark=?"
            push!(params, remark)
        end
        if layer_id !== nothing
            sql *= " AND layer_id=?"
            push!(params, layer_id)
        end
        rows = _query(store.db, sql, params)
        isempty(rows[1]) && return nothing
        if length(rows[1]) > 1
            strict && return nothing
            # 多条时优先 remark=planned（上层计划曲线）
            for i in 1:length(rows[1])
                if String(rows[4][i]) == "planned"
                    return "$(rows[2][i])|$(rows[3][i])|$(rows[4][i])#$(rows[5][i])"
                end
            end
            return nothing
        end
        return "$(rows[2][1])|$(rows[3][1])|$(rows[4][1])#$(rows[5][1])"
    end
end

"""
    get_ts_values_at_meta(db_path; var_name, source_id, remark, layer_id, times)

按 meta 条件定位唯一序列后，对 times 做 floor 点查。
语义等价于 query_ts(...)+get_values(...)，但不整读序列。
"""
function get_ts_values_at_meta(db_path::String;
    source_id=nothing, var_name=nothing, remark=nothing, layer_id=nothing,
    times::Vector{String}=String[])

    key = _query_unique_data_key(db_path; source_id=source_id, var_name=var_name, remark=remark, layer_id=layer_id)
    key === nothing && return nothing
    return get_ts_values_at(db_path, key, times)
end

"""
    query_ts_has_exact(...)

序列在 ts 上是否有精确点。用于 storage 的策略1。
"""
function query_ts_has_exact(db_path::String;
    source_id=nothing, var_name=nothing, remark=nothing, layer_id=nothing, ts::String="")

    key = _query_unique_data_key(db_path; source_id=source_id, var_name=var_name, remark=remark, layer_id=layer_id)
    key === nothing && return false
    return get_ts_exact(db_path, key, ts) !== nothing
end


"""
    write_timeseries_batch!(db_path, pairs; overlay=true)

一步结果批量落盘：单事务写入多条 (data_key, TimeSeries)。
overlay=true 时只覆盖 new 点并保留旧点（同 set_ts_merge）；
overlay=false 时整段替换（同 set_ts）。
调用方不必持有 write_lock。
"""
function write_timeseries_batch!(
    db_path::String,
    pairs::Vector{Tuple{String,TimeSeries}};
    overlay::Bool=true,
)
    isempty(pairs) && return nothing
    store = get_store(db_path)
    t0 = time()
    lock(store.write_lock) do
        wait_ms = (time() - t0) * 1000
        ts_probe_note_lock_wait!(wait_ms)
        tw = time()
        _exec(store.db, "BEGIN IMMEDIATE")
        try
            insert_stmt = DBInterface.prepare(store.db,
                "INSERT INTO time_series_data (series_id, ts, value, ts_min) VALUES (?, ?, ?, ?)")
            try
                for (data_key, ts) in pairs
                    isempty(ts.timestamps) && continue
                    source_id, var_name, remark, layer_id = _key_to_meta_params(data_key)

                    _exec(store.db,
                        "INSERT INTO time_series_meta (source_id, var_name, remark, layer_id, updated_at)
                         VALUES (?, ?, ?, ?, datetime('now'))
                         ON CONFLICT(source_id, var_name, remark, layer_id)
                         DO UPDATE SET updated_at = datetime('now')",
                        [source_id, var_name, remark, layer_id])

                    meta_rows = _query(store.db,
                        "SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=? AND layer_id=?",
                        [source_id, var_name, remark, layer_id])
                    isempty(meta_rows[1]) && continue
                    series_id = Int(meta_rows[1][1])

                    if overlay
                        placeholders = join(("?" for _ in eachindex(ts.timestamps)), ",")
                        _exec(store.db,
                            "DELETE FROM time_series_data WHERE series_id=? AND ts IN ($placeholders)",
                            [series_id, ts.timestamps...])
                    else
                        _exec(store.db,
                            "DELETE FROM time_series_data WHERE series_id=?", [series_id])
                    end

                    perm = sortperm(ts.timestamps; lt=time_label_less_than)
                    for i in perm
                        DBInterface.execute(insert_stmt,
                            [series_id, ts.timestamps[i], ts.values[i], time_label_to_minutes(ts.timestamps[i])])
                    end

                end
            finally
                DBInterface.close!(insert_stmt)
            end
            _exec(store.db, "COMMIT")
        catch e
            try; _exec(store.db, "ROLLBACK"); catch; end
            rethrow(e)
        end
        # 发布发生在 COMMIT 之后；回滚不会污染缓存，且不在事务内重建历史序列。
        for (data_key, ts) in pairs
            snapshot_publish_if_loaded!(store.db_path, data_key, ts; overlay)
        end
        if isdefined(@__MODULE__, :PERF_ENABLED) && PERF_ENABLED
            cursor = Int(_query(store.db, "SELECT COALESCE(MAX(id), 0) FROM time_series_data")[1][1])
            perf_record("task", basename(dirname(db_path)), "result_committed", 0.0, 0, 0, 0, "ok",
                Dict("result_cursor" => cursor, "committed_at_ms" => round(Int, time() * 1000)))
        end
        ts_probe_add!("batch_ms", (time() - tw) * 1000)
        ts_probe_add!("batch_count", 1.0)
    end
    return nothing
end
