# 开发期可选探针：默认关闭；缓冲写 JSONL，不在每个采样点重写历史日志。
using Dates, JSON3

const PERF_ENABLED = lowercase(get(ENV, "SYNERROLL_PERF", "0")) in ("1", "true", "yes")
const PERF_STATES = Dict{Tuple{String,String},Dict{String,Any}}()
const PERF_LOCK = ReentrantLock()

function perf_log_path(kind::String, id::String)
    root = isdefined(@__MODULE__, :BACKEND_DATA_DIR) ? BACKEND_DATA_DIR : normpath(joinpath(@__DIR__, "..", "data"))
    return joinpath(root, kind == "planning" ? "capacity-planning" : "tasks", id, "logs", "performance.jsonl")
end

function _perf_flush!(state; force=false)
    now = time()
    if force || now - state["last_flush"] >= 2 || length(state["buffer"]) >= 256
        isempty(state["buffer"]) && return
        path = state["path"]
        mkpath(dirname(path))
        open(path, "a") do io
            for line in state["buffer"]
                println(io, line)
            end
        end
        empty!(state["buffer"])
        state["last_flush"] = now
    end
end

function perf_start(kind::String, id::String; meta=Dict{String,Any}())
    PERF_ENABLED || return nothing
    lock(PERF_LOCK) do
        PERF_STATES[(kind, id)] = Dict{String,Any}(
            "path" => perf_log_path(kind, id), "buffer" => String[],
            "stats" => Dict{String,Dict{String,Float64}}(), "last_flush" => time(),
        )
    end
    perf_record(kind, id, "start", 0.0, 0, 0, 0, "ok", meta)
    return nothing
end

function perf_record(kind::String, id::String, phase::String, duration_ms,
    alloc_bytes, current_rss_before_bytes, current_rss_after_bytes,
    status::String, meta=Dict{String,Any}())
    PERF_ENABLED || return nothing
    try
        lock(PERF_LOCK) do
            state = get(PERF_STATES, (kind, id), nothing)
            state === nothing && return nothing
            stats = get!(state["stats"], phase, Dict("count"=>0.0, "total_ms"=>0.0, "max_ms"=>0.0, "alloc_bytes"=>0.0))
            stats["count"] += 1
            stats["total_ms"] += duration_ms
            stats["max_ms"] = max(stats["max_ms"], duration_ms)
            stats["alloc_bytes"] += alloc_bytes
            push!(state["buffer"], JSON3.write(Dict(
                "time_utc" => string(Dates.now(Dates.UTC)), "kind" => kind, "id" => id,
                "phase" => phase, "duration_ms" => duration_ms, "alloc_bytes" => alloc_bytes,
                "status" => status, "meta" => meta,
            )))
            _perf_flush!(state)
        end
    catch error
        @warn "Performance log unavailable" exception=error
    end
    return nothing
end

function perf_measure(f::Function, kind::String, id::String, phase::String; meta=Dict{String,Any}())
    PERF_ENABLED || return f()
    started = time_ns()
    try
        sample = @timed f()
        perf_record(kind, id, phase, sample.time * 1000, sample.bytes, 0, 0, "ok", meta)
        return sample.value
    catch error
        perf_record(kind, id, phase, (time_ns() - started) / 1e6, 0, 0, 0, "error", meta)
        rethrow(error)
    end
end

"""从任意深度的 db 路径解析 (kind, id)：capacity-planning/<id>/... 或 tasks/<id>/..."""
function perf_owner_from_db_path(db_path::String)
    parts = split(normpath(abspath(db_path)), Base.Filesystem.path_separator)
    for i in eachindex(parts)
        if parts[i] == "capacity-planning" && i < length(parts)
            return ("planning", String(parts[i + 1]))
        elseif parts[i] == "tasks" && i < length(parts)
            return ("task", String(parts[i + 1]))
        end
    end
    folder = dirname(db_path)
    return ("task", basename(folder))
end

function perf_measure_db(f::Function, db_path::String, phase::String; meta=Dict{String,Any}())
    PERF_ENABLED || return f()
    kind, id = perf_owner_from_db_path(db_path)
    return perf_measure(f, kind, id, phase; meta)
end

function perf_finish(kind::String, id::String)
    PERF_ENABLED || return nothing
    try
        lock(PERF_LOCK) do
            state = pop!(PERF_STATES, (kind, id), nothing)
            state === nothing && return nothing
            _perf_flush!(state; force=true)
            path = joinpath(dirname(state["path"]), "performance-summary.txt")
            open(path, "w") do io
                println(io, "阶段耗时（包含子阶段的 total 项不可与子阶段求和；alloc 为累计分配量）")
                println(io, "phase\tcount\ttotal_ms\tmean_ms\tmax_ms\talloc_bytes")
                for (phase, stats) in sort!(collect(state["stats"]); by=x -> -x[2]["total_ms"])
                    count = stats["count"]
                    println(io, join((phase, Int(count), round(stats["total_ms"]; digits=2),
                        round(stats["total_ms"] / max(1, count); digits=2),
                        round(stats["max_ms"]; digits=2), Int(stats["alloc_bytes"])), '\t'))
                end
            end
        end
    catch error
        @warn "Performance summary unavailable" exception=error
    end
    return nothing
end

# 保留兼容入口；本版探针只统计分阶段耗时和分配量，不把进程峰值伪装成阶段 RSS。
perf_current_rss() = 0
