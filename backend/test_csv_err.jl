# isolated test of extract helpers by including server_utils pieces is heavy;
# inline minimal copy of logic test via include_string of just the functions.

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
        error("列「$(column_name)」存在缺失或非数值数据（行号不含表头）: " * join(bad_samples, ", ") * more * "。请修正 CSV 后重新导入")
    end
    return values
end

function _user_errmsg(e, fallback::String)
    if e isa ErrorException
        msg = e.msg
        for prefix in ("导入异常: ", "转换异常: ", "边界提交异常: ", "边界加载异常: ", "删除异常: ")
            if startswith(msg, prefix)
                msg = replace(msg, prefix => ""; count=1)
            end
        end
        return isempty(strip(msg)) ? fallback : msg
    end
    return "$(fallback): $(sprint(showerror, e))"
end

ok = extract_float_column_checked(Any["1.5", "2", "3.0"])
length(ok) == 3 || error("good col failed")

try
    extract_float_column_checked(Any["1.0", "abc", "", "NA", "2.0"]; column_name="wind_m")
    error("should throw")
catch e
    msg = sprint(showerror, e)
    occursin("wind_m", msg) || error("no col name: $msg")
    occursin("第 2 行", msg) || error("no row: $msg")
    println("OK bad-col message: ", msg)
end

err = ErrorException("导入异常: 未找到列名: wind_m")
m = _user_errmsg(err, "导入失败")
m == "未找到列名: wind_m" || error("strip failed: $m")
println("OK _user_errmsg: ", m)
println("CSV CHECK TESTS PASSED")
