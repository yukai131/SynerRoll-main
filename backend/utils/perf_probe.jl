# 性能探针空实现（发行版）。
# 正式打包不再采集或写入性能日志；保留 API 签名以兼容既有调用点。
# 开发期如需性能日志，用 git 历史中的 perf_probe 完整实现替换本文件。

const PERF_ENABLED = false

function perf_measure(f::Function, kind::String, id::String, phase::String; meta=Dict{String,Any}())
    return f()
end

function perf_measure_db(f::Function, db_path::String, phase::String; meta=Dict{String,Any}())
    return f()
end

function perf_start(kind::String, id::String; meta=Dict{String,Any}())
    return nothing
end

function perf_finish(kind::String, id::String)
    return nothing
end

function perf_record(kind::String, id::String, phase::String, duration_ms,
                     alloc_bytes, current_rss_before_bytes, current_rss_after_bytes,
                     status::String, meta=Dict{String,Any}())
    return nothing
end

function perf_current_rss()
    return 0
end

function perf_log_path(kind::String, id::String)
    return ""
end
