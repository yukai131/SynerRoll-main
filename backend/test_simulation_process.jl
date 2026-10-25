using Test
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
include("server.jl")

function process_fixture(id)
    insert_task!(id=id, project_id="process-test", canvas_id="A", layer_id="1", mode="offline",
        name=nothing, sim_start_time="0:00", sim_end_time="1:00", params_hash="test")
    return get_task(id)
end

@testset "Simulation processes and committed event forwarding" begin
    task = process_fixture("native-block")
    marker = joinpath(TASKS_DATA_ROOT, "native-ready")
    native_sleep = "ccall((:Sleep, \"kernel32\"), Cvoid, (UInt32,), 60000)"
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no -e $("write($(repr(marker)), \"ready\"); " * native_sleep)`; windows_hide=true)
    spawn_task(task["id"], task; worker_command=command)
    ctx = TASK_CONTEXTS[task["id"]]
    @test timedwait(() -> isfile(marker), 60.0) == :ok
    @test ctx.process !== nothing && process_running(ctx.process)
    queued = process_fixture("queued")
    spawn_task(queued["id"], queued; worker_command=command)
    queued_ctx = TASK_CONTEXTS[queued["id"]]
    @test cancel_simulation!(queued["id"])["status"] == TASK_CANCELLED
    before = time()
    cancel_simulation!(task["id"])
    @test timedwait(() -> istaskdone(ctx.julia_task), 5.0) == :ok
    @test time() - before < 5.0
    @test !process_running(ctx.process)
    @test get_task(task["id"])["status"] == TASK_CANCELLED
    @test timedwait(() -> istaskdone(queued_ctx.julia_task), 5.0) == :ok
    @test queued_ctx.process === nothing
    @test isempty(TASK_CONTEXTS)

    finished = process_fixture("finished")
    update_task_status!(finished["id"], TASK_COMPLETED)
    @test cancel_simulation!(finished["id"])["status"] == TASK_COMPLETED

    crash = process_fixture("crash")
    spawn_task(crash["id"], crash; worker_command=Cmd(`$(Base.julia_cmd()) --startup-file=no -e 'exit(7)'`; windows_hide=true))
    crash_ctx = TASK_CONTEXTS[crash["id"]]
    @test timedwait(() -> istaskdone(crash_ctx.julia_task), 60.0) == :ok
    @test get_task(crash["id"])["status"] == TASK_FAILED
    @test occursin("7", get_task(crash["id"])["error_message"])

    ctx = get_or_create_context("unicode-events", "offline", nothing, joinpath(TASKS_DATA_ROOT, "events", "timeseries.db"))
    channel = subscribe(ctx)
    io = IOBuffer()
    write(io, "{\"type\":\"status\",\"status\":\"中文\"}")
    seekstart(io)
    _forward_worker_events!(ctx, io)
    @test !isready(channel)
    @test position(io) == 0
    seekend(io); write(io, '\n'); seekstart(io)
    _forward_worker_events!(ctx, io)
    @test take!(channel)["status"] == "中文"
    mktemp() do path, reader
        _forward_worker_events!(ctx, reader)
        open(path, "a") do writer
            write(writer, "{\"type\":\"status\",\"status\":\"追加\"}\n")
        end
        _forward_worker_events!(ctx, reader)
        @test take!(channel)["status"] == "追加"
        @test eof(reader)
        open(path, "a") do writer
            write(writer, "{\"type\":\"completed\"}\n")
        end
        _forward_worker_events!(ctx, reader)
        @test take!(channel)["type"] == "completed"
    end
    remove_context(ctx.id)
end

@testset "Capacity budget excludes Julia compilation" begin
    start_planning_budget!(10.0)
    try
        before = time_ns()
        compile_before = first(Base.cumulative_compile_time_ns())
        @eval function budget_compile_fixture(x::Int)
            sum(sin(i * x) for i in 1:1000)
        end
        Base.invokelatest(budget_compile_fixture, 3)
        sleep(0.1)
        wall = (time_ns() - before) / 1e9
        compilation = (first(Base.cumulative_compile_time_ns()) - compile_before) / 1e9
        elapsed = planning_elapsed_seconds()
        @test compilation > 0
        @test elapsed >= 0.09
        @test elapsed <= wall - compilation + 0.1
    finally
        finish_planning_budget!()
    end
    @test ACTIVE_PLANNING_BUDGET[] === nothing
end
