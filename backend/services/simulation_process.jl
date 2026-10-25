# 每个仿真独占 Julia/原生求解器资源，HTTP 进程仅管理生命周期和转发事件。
const SIMULATION_TERMINAL_STATUSES = (TASK_COMPLETED, TASK_FAILED, TASK_CANCELLED)
const SIMULATION_WORKER_SLOTS = Base.Semaphore(1)

function simulation_worker_command(task_id::String)
    script = normpath(joinpath(@__DIR__, "..", "simulation_worker.jl"))
    project = dirname(Base.active_project())
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project --threads=1 $script $task_id`
    return addenv(Cmd(command; windows_hide=true),
        "SYNERROLL_DATA_DIR" => BACKEND_DATA_DIR,
        "SYNERROLL_SIMULATION_WORKER" => "1")
end

function _forward_worker_events!(ctx::TaskContext, io::IO)
    seek(io, position(io)) # 刷新上次到达 EOF 的流状态，读取外部进程追加的数据。
    while !eof(io)
        offset = position(io)
        line = readline(io; keep=true)
        if !endswith(line, '\n')
            seek(io, offset) # 等待子进程写完一行，避免丢失截断的 JSON/中文。
            break
        end
        broadcast_event(ctx, JSON3.read(line, Dict{String,Any}))
    end
end

function supervise_simulation!(ctx::TaskContext, command::Cmd)
    process = nothing
    events = nothing
    log = nothing
    Base.acquire(SIMULATION_WORKER_SLOTS)
    try
        ctx.launching = true
        ctx.cancel_requested && return
        directory = dirname(ctx.store_path)
        log = open(joinpath(directory, "worker.log"), "a")
        # 由父进程创建，始终从零水位开始转发；只用于此任务的新进程。
        events = open(joinpath(directory, "events.jsonl"), "w+")
        process = run(pipeline(command; stdout=log, stderr=log); wait=false)
        ctx.process = process
        while process_running(process)
            if ctx.cancel_requested
                terminate_worker_process!(process)
                break
            end
            _forward_worker_events!(ctx, events)
            sleep(0.1)
        end
        wait(process)
        _forward_worker_events!(ctx, events)
        task = get_task(ctx.id)
        if ctx.cancel_requested && task !== nothing && !(task["status"] in SIMULATION_TERMINAL_STATUSES)
            update_task_status!(ctx.id, TASK_CANCELLED)
            broadcast_event(ctx, Dict("type"=>"cancelled", "taskId"=>ctx.id, "currentTime"=>task["cur_time"]))
        elseif task !== nothing && !(task["status"] in SIMULATION_TERMINAL_STATUSES)
            _fail_task!(ctx, ctx.id, "仿真工作进程提前退出（退出码 $(process.exitcode)），详情见任务 worker.log。")
        end
    catch error
        task = get_task(ctx.id)
        if task !== nothing && !(task["status"] in SIMULATION_TERMINAL_STATUSES)
            _fail_task!(ctx, ctx.id, sprint(showerror, error))
        end
    finally
        if process !== nothing && process_running(process)
            terminate_worker_process!(process)
            wait(process)
        end
        events !== nothing && close(events)
        log !== nothing && close(log)
        ctx.launching = false
        remove_context(ctx.id)
        Base.release(SIMULATION_WORKER_SLOTS)
    end
    return nothing
end

function spawn_task(task_id::String, task::Dict; worker_command::Union{Nothing,Cmd}=nothing)
    ctx = get_or_create_context(task_id, task["mode"], get(task, "sim_end_time", nothing),
        joinpath(TASKS_DATA_ROOT, task_id, "timeseries.db"))
    mkpath(dirname(ctx.store_path))
    # sim_mode/target_layer_id 不是 tasks.db 列，传递完整启动快照。
    write(joinpath(dirname(ctx.store_path), "request.json"), JSON3.write(task))
    command = worker_command === nothing ? simulation_worker_command(task_id) : worker_command
    ctx.julia_task = @async supervise_simulation!(ctx, command)
    return ctx.julia_task
end

function cancel_simulation!(task_id::String)
    task = get_task(task_id)
    task === nothing && error("任务不存在: $task_id")
    task["status"] in SIMULATION_TERMINAL_STATUSES && return task
    ctx = lock(TASK_CONTEXTS_LOCK) do
        get(TASK_CONTEXTS, task_id, nothing)
    end
    if ctx === nothing
        update_task_status!(task_id, TASK_CANCELLED)
    else
        ctx.cancel_requested = true
        # 排队任务尚未启动，无需等前一个任务释放槽位。
        if ctx.process === nothing
            update_task_status!(task_id, TASK_CANCELLED)
            broadcast_event(ctx, Dict("type"=>"cancelled", "taskId"=>task_id, "currentTime"=>task["cur_time"]))
        end
    end
    return get_task(task_id)
end
