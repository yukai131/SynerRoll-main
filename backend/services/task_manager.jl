# 计算任务生命周期管理
# 负责：CRUD、协程调度、Channel 信号、WS 订阅广播
# 文档：docs/compute-task-architecture.md

using Dates

# ───── 任务状态常量 ─────
const TASK_PENDING     = "pending"
const TASK_PARSING     = "parsing"
const TASK_BUILDING    = "building"
const TASK_SOLVING     = "solving"
const TASK_COMPLETED   = "completed"
const TASK_FAILED      = "failed"
const TASK_CANCELLED   = "cancelled"

# ───── 任务信号常量 ─────
const SIGNAL_CANCEL   = "cancel"

# ───── tasks.db 单例 ─────
# 路径集中在 utils/server_utils.jl 的 BACKEND_DATA_DIR，避免跟 Julia 启动目录耦合
const TASKS_DB_PATH = joinpath(BACKEND_DATA_DIR, "tasks.db")
# 每任务的 timeseries.db 存在这里
const TASKS_DATA_ROOT = joinpath(BACKEND_DATA_DIR, "tasks")

# 任务元数据管理句柄
mutable struct TaskStore
    db::SQLite.DB
end

function TaskStore()
    mkpath(dirname(TASKS_DB_PATH))
    db = SQLite.DB(TASKS_DB_PATH)
    # 与 BFF 只读轮询并存：WAL + busy_timeout，避免 "database is locked"
    for pragma in (
        "PRAGMA journal_mode=WAL",
        "PRAGMA busy_timeout=10000",
        "PRAGMA synchronous=NORMAL",
        "PRAGMA temp_store=MEMORY",
    )
        try
            DBInterface.execute(db, pragma)
        catch e
            @warn "TaskStore: PRAGMA failed" pragma exception=e
        end
    end
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS tasks (
            id              TEXT PRIMARY KEY,
            project_id      TEXT NOT NULL,
            canvas_id       TEXT NOT NULL,
            layer_id        TEXT NOT NULL,
            mode            TEXT NOT NULL,
            name            TEXT,
            status          TEXT NOT NULL,
            params_hash     TEXT NOT NULL,
            sim_start_time  TEXT NOT NULL,
            sim_end_time    TEXT,
            sim_start_date  TEXT,
            sim_end_date    TEXT,
            cur_time        TEXT,
            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            started_at      TEXT,
            finished_at     TEXT,
            error_message   TEXT,
            extra_json      TEXT
        )
    """)
    # 迁移：旧版 current_time 列 → cur_time（current_time 在 SQLite.jl 中有写入 bug）
    cols = DBInterface.execute(db, "PRAGMA table_info(tasks)") |> columntable
    col_names = [String(cols[2][i]) for i in 1:length(cols[1])]
    if "current_time" in col_names && !("cur_time" in col_names)
        DBInterface.execute(db, "ALTER TABLE tasks RENAME COLUMN current_time TO cur_time")
        @info "TaskStore: 已迁移 current_time → cur_time"
    end
    if !("sim_start_date" in col_names)
        DBInterface.execute(db, "ALTER TABLE tasks ADD COLUMN sim_start_date TEXT")
    end
    if !("sim_end_date" in col_names)
        DBInterface.execute(db, "ALTER TABLE tasks ADD COLUMN sim_end_date TEXT")
    end
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_tasks_status  ON tasks(status)")
    return TaskStore(db)
end

const TASK_STORE = Ref{Union{TaskStore, Nothing}}(nothing)
function get_task_store()
    if isnothing(TASK_STORE[])
        TASK_STORE[] = TaskStore()
    end
    return TASK_STORE[]
end

# ───── 任务运行时上下文 ─────
# 每个 task_id 对应一个 TaskContext：协程 handle + signal Channel + WS 订阅者列表
mutable struct TaskContext
    id::String
    signal_ch::Channel{String}         # "pause" | "resume" | "cancel"
    subscribers::Vector{Channel{Dict{String, Any}}}  # WS 订阅者
    julia_task::Union{Task, Nothing}     # 协程 handle
    store_path::String                  # 任务 DB 路径 data/tasks/<id>/timeseries.db
    mode::String                        # "online" | "offline"
    sim_end_time::Union{String, Nothing}
    created_at::Float64
end

# 全局 task context 字典
const TASK_CONTEXTS = Dict{String, TaskContext}()
const TASK_CONTEXTS_LOCK = ReentrantLock()

# 订阅者列表的锁（每个 ctx 自己的锁，但用一个全局简单点）
const SUBSCRIBERS_LOCK = ReentrantLock()
const TASK_EVENT_BUFFER = 32

"""
    broadcast_event(ctx::TaskContext, event::Dict)

向该任务的所有 WS 订阅者广播事件。无订阅者时是 no-op。

若某个订阅者 channel 缓冲区已满（前端消费跟不上），直接丢弃该事件，
避免求解主循环被慢订阅者阻塞。
"""
function broadcast_event(ctx::TaskContext, event::Dict)
    # 同时保护容量检查与发布，多个发布者不能在检查后把队列填满。
    lock(SUBSCRIBERS_LOCK) do
        for ch in ctx.subscribers
            try
                # isbuffered 未导出，Channel 也不支持 length；旧写法被 catch 静默吞掉了。
                if !isopen(ch) || Base.n_avail(ch) >= TASK_EVENT_BUFFER
                    continue
                end
                put!(ch, event)
            catch error
                error isa InvalidStateException || @warn "Task event delivery failed" task_id=ctx.id exception=error
            end
        end
    end
    return nothing
end

"""
    subscribe(ctx::TaskContext) -> Channel

新建一个订阅 channel，加入 ctx.subscribers 列表。订阅者关闭 channel 时自动从列表移除。
"""
function subscribe(ctx::TaskContext)::Channel
    ch = Channel{Dict{String, Any}}(TASK_EVENT_BUFFER)
    lock(SUBSCRIBERS_LOCK) do
        push!(ctx.subscribers, ch)
    end
    return ch
end

"""
    unsubscribe(ctx::TaskContext, ch::Channel)

订阅者主动取消订阅。安全（即使 channel 已关）。
"""
function unsubscribe(ctx::TaskContext, ch::Channel)
    lock(SUBSCRIBERS_LOCK) do
        filter!(c -> c !== ch, ctx.subscribers)
    end
    try
        close(ch)
    catch
    end
    return nothing
end

"""
    get_or_create_context(task_id::String, mode::String, sim_end_time, store_path::String) -> TaskContext

获取或创建任务运行时上下文。已存在则返回（用于 resume），不存在则创建。
"""
function get_or_create_context(task_id::String, mode::String,
                              sim_end_time::Union{String, Nothing},
                              store_path::String)::TaskContext
    lock(TASK_CONTEXTS_LOCK) do
        if haskey(TASK_CONTEXTS, task_id)
            ctx = TASK_CONTEXTS[task_id]
            ctx.mode = mode
            ctx.sim_end_time = sim_end_time
            ctx.store_path = store_path
            return ctx
        end
        ctx = TaskContext(
            task_id,
            Channel{String}(4),
            Channel{Dict{String, Any}}[],
            nothing,
            store_path,
            mode,
            sim_end_time,
            time()
        )
        TASK_CONTEXTS[task_id] = ctx
        return ctx
    end
end

"""
    remove_context(task_id::String)

清理任务上下文（ctx 关闭、所有订阅者关闭）。调用后 task_id 不可再 subscribe。
"""
function remove_context(task_id::String)
    lock(TASK_CONTEXTS_LOCK) do
        if !haskey(TASK_CONTEXTS, task_id)
            return
        end
        ctx = TASK_CONTEXTS[task_id]
        # 关闭所有订阅者
        lock(SUBSCRIBERS_LOCK) do
            for ch in ctx.subscribers
                try close(ch) catch end
            end
            empty!(ctx.subscribers)
        end
        # 关闭 signal channel
        try close(ctx.signal_ch) catch end
        delete!(TASK_CONTEXTS, task_id)
    end
    return nothing
end

# ───── 任务元数据 CRUD（基于 tasks.db）──

function now_iso()
    return Dates.format(Dates.now(), Dates.ISODateTimeFormat)
end

"""
    insert_task!(; id, project_id, canvas_id, layer_id, mode, name, sim_start_time,
                 sim_end_time, params_hash, extra_json=nothing)

向 tasks.db 插入一条新记录（status=pending）。
"""
function insert_task!(; id::String, project_id::String, canvas_id::String,
                      layer_id::String, mode::String, name::Union{String, Nothing},
                      sim_start_time::String, sim_end_time::Union{String, Nothing},
                      params_hash::String,
                      sim_start_date::Union{String, Nothing}=nothing,
                      sim_end_date::Union{String, Nothing}=nothing,
                      extra_json::Union{String,Nothing}=nothing)
    store = get_task_store()
    now_s = now_iso()
    DBInterface.execute(store.db, """
        INSERT INTO tasks (id, project_id, canvas_id, layer_id, mode, name,
                           status, params_hash, sim_start_time, sim_end_time,
                           sim_start_date, sim_end_date, cur_time, created_at,
                           updated_at, extra_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [id, project_id, canvas_id, layer_id, mode, name,
          TASK_PENDING, params_hash, sim_start_time, sim_end_time,
          sim_start_date, sim_end_date, nothing, now_s, now_s, extra_json])
    return nothing
end

"""
    get_task(task_id::String) -> Union{Dict, Nothing}

按 id 查任务元数据。
"""
# SQLite NULL → Julia missing，统一转为 nothing
_n(v) = ismissing(v) ? nothing : v

function get_task(task_id::String)
    store = get_task_store()
    rows = DBInterface.execute(store.db, """
        SELECT id, project_id, canvas_id, layer_id, mode, name, status,
               params_hash, sim_start_time, sim_end_time, cur_time,
               sim_start_date, sim_end_date, created_at, updated_at,
               started_at, finished_at, error_message, extra_json
        FROM tasks WHERE id=?
    """, [task_id]) |> columntable
    isempty(rows[1]) && return nothing
    return Dict(
        "id" => rows[1][1], "project_id" => rows[2][1], "canvas_id" => rows[3][1],
        "layer_id" => rows[4][1], "mode" => rows[5][1], "name" => _n(rows[6][1]),
        "status" => rows[7][1], "params_hash" => rows[8][1],
        "sim_start_time" => rows[9][1], "sim_end_time" => _n(rows[10][1]),
        "cur_time" => _n(rows[11][1]), "sim_start_date" => _n(rows[12][1]),
        "sim_end_date" => _n(rows[13][1]), "created_at" => rows[14][1],
        "updated_at" => rows[15][1], "started_at" => _n(rows[16][1]),
        "finished_at" => _n(rows[17][1]), "error_message" => _n(rows[18][1]),
        "extra_json" => _n(rows[19][1])
    )
end

function list_tasks(; project_id::Union{String, Nothing}=nothing,
                    status::Union{String, Nothing}=nothing)
    store = get_task_store()
    sql = "SELECT id, project_id, canvas_id, layer_id, mode, name, status, cur_time, sim_start_time, sim_end_time, sim_start_date, sim_end_date, created_at, updated_at, finished_at, error_message FROM tasks WHERE 1=1"
    params = String[]
    if project_id !== nothing
        sql *= " AND project_id=?"
        push!(params, project_id)
    end
    if status !== nothing
        sql *= " AND status=?"
        push!(params, status)
    end
    sql *= " ORDER BY created_at DESC"
    rows = DBInterface.execute(store.db, sql, params) |> columntable
    isempty(rows[1]) && return Dict[]
    return [Dict(
        "id" => rows[1][i], "project_id" => rows[2][i], "canvas_id" => rows[3][i],
        "layer_id" => rows[4][i], "mode" => rows[5][i], "name" => _n(rows[6][i]),
        "status" => rows[7][i], "cur_time" => _n(rows[8][i]),
        "sim_start_time" => rows[9][i], "sim_end_time" => _n(rows[10][i]),
        "sim_start_date" => _n(rows[11][i]), "sim_end_date" => _n(rows[12][i]),
        "created_at" => rows[13][i], "updated_at" => rows[14][i],
        "finished_at" => _n(rows[15][i]), "error_message" => _n(rows[16][i])
    ) for i in 1:length(rows[1])]
end

function update_task_status!(task_id::String, status::String;
                            error_message::Union{String, Nothing}=nothing)
    store = get_task_store()
    now_s = now_iso()
    em = error_message === nothing ? missing : String(error_message)
    _tasks_exec_with_retry(store.db) do
        if status in (TASK_COMPLETED, TASK_FAILED, TASK_CANCELLED)
            DBInterface.execute(store.db,
                "UPDATE tasks SET status=?, error_message=?, finished_at=?, updated_at=? WHERE id=?",
                [String(status), em, now_s, now_s, String(task_id)])
        else
            DBInterface.execute(store.db,
                "UPDATE tasks SET status=?, error_message=?, updated_at=? WHERE id=?",
                [String(status), em, now_s, String(task_id)])
        end
        nothing
    end
    return nothing
end

"""短重试：BFF 只读轮询或 checkpoint 偶发占锁时，避免整个求解被 database is locked 打死。"""
function _tasks_exec_with_retry(f, db=nothing; attempts::Int=5)
    local last_err
    for i in 1:attempts
        try
            return f()
        catch e
            last_err = e
            msg = sprint(showerror, e)
            if !occursin("locked", msg) && !occursin("busy", msg)
                rethrow(e)
            end
            i < attempts && sleep(0.05 * i)
        end
    end
    throw(last_err)
end

"""更新任务当前仿真时刻（前端增量水位/进度条依赖此字段）"""
function update_task_current_time!(task_id::String, sim_time::Union{String,Nothing})
    store = get_task_store()
    now_s = now_iso()
    _tasks_exec_with_retry(store.db) do
        if sim_time === nothing
            DBInterface.execute(store.db,
                "UPDATE tasks SET cur_time=NULL, updated_at=? WHERE id=?",
                [now_s, String(task_id)])
        else
            DBInterface.execute(store.db,
                "UPDATE tasks SET cur_time=?, updated_at=? WHERE id=?",
                [String(sim_time), now_s, String(task_id)])
        end
        nothing
    end
    return nothing
end


"""
    delete_task!(task_id::String)

从 tasks.db 物理删除一条记录（不删磁盘上的 timeseries.db，由调用方处理）。
"""
function delete_task!(task_id::String)
    store = get_task_store()
    DBInterface.execute(store.db, "DELETE FROM tasks WHERE id=?", [task_id])
    return nothing
end

# ───── 启动恢复（服务重启时调用）──

"""
    reconcile_running_tasks!()

服务启动时调用：把 status=solving 的任务改为 cancelled（进程死了，不能继续）。
"""
function reconcile_running_tasks!()
    store = get_task_store()
    DBInterface.execute(store.db,
        "UPDATE tasks SET status=?, updated_at=? WHERE status=?",
        [TASK_CANCELLED, now_iso(), TASK_SOLVING])
    return nothing
end
