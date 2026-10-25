using JSON3
using CSV
using DataFrames
using HTTP

# backend/data 绝对路径（不依赖 CWD）
# 所有 project / task / boundary DB 都建在这里
const BACKEND_DATA_DIR = abspath(get(ENV, "SYNERROLL_DATA_DIR", joinpath(@__DIR__, "..", "data")))

"""
    remove_tree_with_retry(path; attempts=4)

递归删除目录。Windows 上 SQLite/杀毒软件可能在句柄关闭后短暂保留文件锁，
因此在最终失败前触发 GC 并进行少量退避重试。最终失败仍向上抛出，避免调用方
误删任务索引、留下无法追踪的计算数据。
"""
function remove_tree_with_retry(path::String; attempts::Int=4)
    isdir(path) || return nothing
    attempts >= 1 || error("attempts 必须大于 0")
    for attempt in 1:attempts
        try
            rm(path; recursive=true, force=true)
            return nothing
        catch
            attempt == attempts && rethrow()
            GC.gc(true)
            sleep(0.1 * attempt)
        end
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# 请求参数解析
# ─────────────────────────────────────────────────────────────────────────────

"""从 HTTP 请求中解析查询参数"""
request_query_params(req) = HTTP.queryparams(HTTP.URI(String(req.target)))

# ─────────────────────────────────────────────────────────────────────────────
# JSON 响应辅助
# ─────────────────────────────────────────────────────────────────────────────

"""
    json_success(; kwargs...) -> HTTP.Response

成功响应 JSON：顶层带 `success=true`，把 kwargs 平铺到顶层。
例：`json_success(data=Dict("x"=>1), message="ok")`
     => `{"success":true,"data":{"x":1},"message":"ok"}`
"""
json_success(; kwargs...) = HTTP.Response(200,
    ["Content-Type" => "application/json; charset=utf-8"], JSON3.write(Dict(:success => true, kwargs...)))

"""
    json_error(message::AbstractString) -> HTTP.Response

错误响应 JSON：顶层带 `success=false` 和 `message`。
"""
json_error(message::AbstractString) = HTTP.Response(200,
    ["Content-Type" => "application/json; charset=utf-8"], JSON3.write(Dict("success" => false, "message" => message)))

# ─────────────────────────────────────────────────────────────────────────────
# 请求参数辅助
# ─────────────────────────────────────────────────────────────────────────────

"""
    require_string(body::Dict, field::AbstractString) -> String

从 body 取必填字符串字段。缺失 key / null / 空串 都抛 ErrorException，
由路由外层 catch 转成 json_error。
"""
function require_string(body::Dict, field::AbstractString)
    haskey(body, field) || error("缺少 $(field) 参数")
    value = body[field]
    value === nothing && error("缺少 $(field) 参数")
    s = string(value)
    isempty(s) && error("缺少 $(field) 参数")
    return s
end

"""
    optional_string(body::Dict, field::AbstractString, default::AbstractString) -> String

从 body 取可选字符串字段，缺失/空串/null 时返回 default。
"""
function optional_string(body::Dict, field::AbstractString, default::AbstractString)
    value = get(body, field, nothing)
    value === nothing && return default
    s = string(value)
    isempty(s) && return default
    return s
end

# ─────────────────────────────────────────────────────────────────────────────
# CSV 辅助（边界导入/转换共用）
# ─────────────────────────────────────────────────────────────────────────────

"""
    read_csv_column(file_path::String, column_name::String)
        -> (col_data, resolved_col_name)

读取 CSV（header=1），按 `column_name` 定位列；找不到时报错并附可用列名。
文件不存在 / CSV 解析失败 / 列找不到 均抛 ErrorException。

返回：
- `col_data`    该列的原始数据（Vector{Any} 之类的 DataFrame 列切片）
- `resolved_col_name` 实际命中的列名字符串
"""
function read_csv_column(file_path::String, column_name::String)
    isempty(strip(file_path)) && error("请填写导入文件路径")
    isempty(strip(column_name)) && error("请填写列名")
    isfile(file_path) || error("文件不存在或路径无效: $(file_path)")

    df = try
        CSV.read(file_path, DataFrame; header=1)
    catch e
        error("无法读取 CSV 文件，请检查格式是否正确（需含表头）: $(sprint(showerror, e))")
    end
    isempty(names(df)) && error("CSV 文件没有表头列，请检查文件内容")

    headers = String.(names(df))
    resolved = nothing
    for h in headers
        if string(h) == column_name
            resolved = string(h)
            break
        end
    end
    if resolved === nothing
        preview = length(headers) > 20 ? string(join(headers[1:20], ", "), ", …（共 $(length(headers)) 列）") : join(headers, ", ")
        error("未找到列名「$(column_name)」，可用列: $(preview)")
    end
    return df[:, resolved], resolved
end

"""
    extract_float_column(col_data) -> Vector{Any}

把 DataFrame 列数据转成 Vector{Any}。非数值/缺失填 0.0（兼容旧调用）。
需要严格校验时用 `extract_float_column_checked`。
"""
function extract_float_column(col_data)
    values = Vector{Any}()
    for val in col_data
        try
            push!(values, Float64(val))
        catch
            push!(values, 0.0)
        end
    end
    return values
end

"""
    extract_float_column_checked(col_data; column_name="") -> Vector{Float64}

严格解析数值列。缺失/空白/非数值/NaN/Inf 会报错，并给出行号提示（不含表头行）。
"""
function extract_float_column_checked(col_data; column_name::String="col")
    values = Float64[]
    bad_rows = Int[]
    bad_samples = String[]
    n = length(col_data)
    n == 0 && error("列「$(column_name)」没有数据行，请检查 CSV 文件")

    for (i, val) in enumerate(col_data)
        ok = false
        fv = 0.0
        if val === nothing || val === missing
            ok = false
        else
            s = strip(string(val))
            if isempty(s) || s == "NA" || s == "NaN" || s == "null" || s == "-"
                ok = false
            else
                try
                    fv = parse(Float64, s)
                    ok = isfinite(fv)
                catch
                    ok = false
                end
            end
        end
        if ok
            push!(values, fv)
        else
            push!(bad_rows, i)
            if length(bad_samples) < 5
                sample = val === nothing || val === missing ? "空" : string(val)
                push!(bad_samples, "第 $(i) 行=「$(sample)」")
            end
        end
    end

    if !isempty(bad_rows)
        more = length(bad_rows) > 5 ? " 等 $(length(bad_rows)) 处" : ""
        error(
            "列「$(column_name)」存在缺失或非数值数据（行号不含表头）: " *
            join(bad_samples, ", ") * more * "。请修正 CSV 后重新导入",
        )
    end
    return values
end
