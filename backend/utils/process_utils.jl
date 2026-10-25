"""停止任务进程树，同时清理启动阶段可能派生的 Julia 预编译进程。"""
function terminate_worker_process!(process::Base.Process)
    process_running(process) || return nothing
    if Sys.iswindows()
        taskkill = joinpath(get(ENV, "SystemRoot", "C:\\Windows"), "System32", "taskkill.exe")
        command = Cmd(`$taskkill /PID $(getpid(process)) /T /F`; windows_hide=true)
        try
            result = run(pipeline(ignorestatus(command); stdout=devnull, stderr=devnull))
            # taskkill 已关闭原生句柄，libuv 的退出通知可能尚未被调度。
            result.exitcode == 0 && return nothing
            yield()
        catch error
            @warn "停止工作进程树失败，将终止主工作进程" exception=error
        end
    end
    process_running(process) && kill(process)
    return nothing
end
