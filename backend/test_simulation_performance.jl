using Test, Dates, SQLite, DBInterface, Tables, JSON3

include(joinpath(@__DIR__, "utils", "timestr_utils.jl"))
include(joinpath(@__DIR__, "utils", "timeseries_utils.jl"))
include(joinpath(@__DIR__, "services", "flexibility_result_service.jl"))
include(joinpath(@__DIR__, "utils", "economy_calculator.jl"))
include(joinpath(@__DIR__, "services", "economy_evaluation_service.jl"))
const BACKEND_DATA_DIR = mktempdir()
include(joinpath(@__DIR__, "services", "task_manager.jl"))
ENV["SYNERROLL_PERF"] = "1"
include(joinpath(@__DIR__, "utils", "perf_probe.jl"))

@testset "Simulation storage performance regressions" begin
    path = joinpath(mktempdir(), "timeseries.db")
    key = "WT|P|power#1"
    try
        write_timeseries_batch!(path, [(key, TimeSeries(["0:00", "1:00", "8760:00"], [1., 2., 3.]))])
        @test !haskey(RESULT_SNAPSHOT, path) # normal BFF reads need no duplicate full-history cache
        @test get_ts_exact(path, key, "0:30") === nothing
        @test get_ts_floor(path, key, "0:30") == 1.
        @test get_ts_values_at(path, key, ["0:00", "0:30", "1:00"]) == [1., 1., 2.]
        @test get_ts(path, key; min_minutes=60, max_minutes=525600).values == [2.]
        @test_throws ErrorException get_ts_values_at(path, key, ["-1:00"])
        rows, _ = snapshot_rows(path)
        @test length(rows) == 3
        write_timeseries_batch!(path, [(key, TimeSeries(["1:00", "2:00"], [20., 30.]))])
        @test get_ts(path, key).values == [1., 20., 30., 3.]
        rows, _ = snapshot_rows(path)
        @test [row["value"] for row in rows] == [1., 20., 30., 3.]
        @test _safe_get_ts_values(path, key, "1:00", "8760:00") == [20., 30.]
        set_ts(path, "b_price|fuel_price|planned#3", TimeSeries(["0:00", "0:05", "8760:00"], [1., 2., 100.]))
        @test load_boundary_price_series(path, ["b_price"], "0:00", "1:00") == [1., 2.]
        @test_throws Exception write_timeseries_batch!(path, [
            (key, TimeSeries(["1:00"], [999.])),
            ("WT|INVALID|power#1", TimeSeries(["invalid-time"], [1.])),
        ])
        @test get_ts_exact(path, key, "1:00") == 20.
        rows, _ = snapshot_rows(path; skip_boundary=true)
        @test [row["value"] for row in rows] == [1., 20., 30., 3.]
        # Existing tasks are migrated lazily once per opened store.
        store = get_store(path)
        _exec(store.db, "CREATE TABLE flexibility_period_results(layer_id TEXT,timestamp TEXT,timestamp_minutes INTEGER,next_timestamp TEXT,case_id TEXT,application_type TEXT,operation_mode TEXT,boundary_condition TEXT,poi_id TEXT,direction TEXT,requirement_source TEXT,result_json TEXT,updated_at TEXT)")
        _ensure_flexibility_result_tables!(store)
        @test store.flexibility_initialized
        @test "revision" in String.(_query(store.db, "PRAGMA table_info(flexibility_period_results)")[2])
        @test Int(_query(store.db, "SELECT version FROM task_result_versions WHERE kind='flexibility'")[1][1]) == 0
        _ensure_flexibility_result_tables!(store)
    finally
        close_store(path)
    end
end

@testset "Opt-in phase profiler preserves return and error semantics" begin
    perf_start("task", "fixture")
    @test perf_measure(() -> 42, "task", "fixture", "optimizer") == 42
    @test_throws ErrorException perf_measure(() -> error("expected"), "task", "fixture", "error-path")
    perf_finish("task", "fixture")
    path = perf_log_path("task", "fixture")
    events = JSON3.read.(readlines(path))
    @test any(row -> row.phase == "optimizer" && row.status == "ok", events)
    @test any(row -> row.phase == "error-path" && row.status == "error", events)
    @test isfile(joinpath(dirname(path), "performance-summary.txt"))
end

@testset "WS events are delivered and a full subscriber never blocks the solver" begin
    ctx = get_or_create_context("ws-fixture", "offline", nothing, joinpath(BACKEND_DATA_DIR, "timeseries.db"))
    channel = subscribe(ctx)
    broadcast_event(ctx, Dict("type" => "flexibility", "revision" => 1))
    @test Base.n_avail(channel) == 1
    @test isready(channel) && take!(channel)["revision"] == 1
    for revision in 1:TASK_EVENT_BUFFER
        broadcast_event(ctx, Dict("type" => "flexibility", "revision" => revision))
    end
    pending = @async broadcast_event(ctx, Dict("type" => "flexibility", "revision" => 100))
    @test timedwait(() -> istaskdone(pending), 1.0) == :ok
    @test Base.n_avail(channel) == TASK_EVENT_BUFFER
    unsubscribe(ctx, channel)
    @test isempty(ctx.subscribers)
end
