# 校验 _tasks_exec_with_retry 可被 do-block + db 两种写法调用
# 最小复现签名（与 task_manager.jl 保持一致）
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
            i < attempts && sleep(0.01 * i)
        end
    end
    throw(last_err)
end

# 调用方式与 task_manager 中一致
dummy_db = "fake-db"
n = 0
_tasks_exec_with_retry(dummy_db) do
    global n += 1
    n
end
@assert n == 1

# 无 db 也可用
_tasks_exec_with_retry() do
    42
end

# 重试逻辑
tries = 0
try
    _tasks_exec_with_retry(nothing; attempts=3) do
        global tries += 1
        error("database is locked")
    end
catch e
    @assert occursin("locked", sprint(showerror, e))
end
@assert tries == 3

println("TASK MANAGER RETRY SIGNATURE OK")
