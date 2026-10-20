using Test
using JSON3

# All databases and candidate directories are isolated from backend/data.
const TEST_DATA_ROOT = mktempdir(; cleanup=false)
ENV["SYNERROLL_DATA_DIR"] = TEST_DATA_ROOT
const server_path = joinpath(@__DIR__, "server.jl")
const server_source = read(server_path, String)
const load_end = findfirst("# 全局常量", server_source)
# Exercise the production include order with HiGHS; commercial COPT binaries and

load_source = replace(server_source[1:first(load_end)-1], "using COPT"=>"", ""=>"")
runner_path = joinpath(@__DIR__, "services/capacity_planning/optimization_runner.jl")
load_source = replace(load_source, "include(\"services/capacity_planning/optimization_runner.jl\")" =>
    "include_string(Main, replace(read($(repr(runner_path)), String), \"using COPT\"=>\"\"), $(repr(runner_path)))")
include_string(Main, load_source, server_path)

const library = JSON3.read(read(joinpath(@__DIR__, "../config/component-library.json"), String), Dict{String,Any})["components"]
function fixture_node(id, key; capacity=100.0, boundaries=String[])
    schema = library[key]
    defaults(section) = Dict{String,Any}(field["key"] => get(field, "defaultValue", nothing) for field in get(schema, section, []))
    tech = defaults("commonTechFields")
    haskey(tech, "capacity") && (tech["capacity"] = capacity)
    business = Dict{String,Any}("componentKey" => key, "commonTechParams" => tech,
        "commonEconomicParams" => defaults("commonEconomicFields"), "boundaryIds" => boundaries,
        "layerConfigs" => Dict("1" => Dict{String,Any}("status" => "stand_alone",
            "techParams" => defaults("layerTechFields"), "economicParams" => defaults("layerEconomicFields"),
            "constraints" => defaults("constraintFields"), "objectives" => defaults("objectiveFields"))))
    return Dict{String,Any}("id" => id, "data" => Dict{String,Any}("label" => key, "componentKey" => key, "business" => business))
end
function fixture_project(nodes)
    Dict{String,Any}("id" => "capacity-test", "name" => "容量测试", "updateTime" => "2026-10-19T00:00:00Z",
        "workspace" => Dict{String,Any}("activeCanvasId" => "A", "canvases" => [
            Dict{String,Any}("id" => "A", "name" => "A", "nodes" => nodes, "edges" => Any[]),
            Dict{String,Any}("id" => "B", "name" => "B", "nodes" => [fixture_node("node-wind", "WT"; capacity=999.0, boundaries=["other"])], "edges" => Any[])]),
        "boundaries" => Any[], "algorithm" => Dict{String,Any}("solver" => "HiGHS", "slackEnabled" => false),
        "layerConfig" => Dict("layers" => [Dict{String,Any}("id" => "1", "name" => "日层", "length" => "24h", "step" => "1h")] ))
end
function seed_boundary(id, meaning, daily)
    path = joinpath(TEST_DATA_ROOT, "projects", "capacity-test", "boundary.db")
    values = reduce(vcat, [fill(Float64(value), 24) for value in daily])
    timestamps = [minutes_to_time_label((index-1)*60) for index in eachindex(values)]
    set_ts(path, "$(id)|$(meaning)|planned#1", TimeSeries(timestamps, values))
    save_boundary_config(path, id, "$(length(values))h", "1h", length(daily), length(values),
        "calendar", "2026-01-01", Dates.format(Date(2026,1,1)+Day(length(daily)-1), dateformat"yyyy-mm-dd"))
end

@testset "Capacity planning integration" begin
    @testset "Continuous schema and legacy drafts" begin
        @test infer_julia_type(Dict{String,Any}("defaultValue"=>1000000, "step"=>10000)) === Float64
        @test infer_julia_type(Dict{String,Any}("defaultValue"=>2)) === Int64
        @test infer_julia_type(Dict{String,Any}("defaultValue"=>true, "step"=>1)) === Bool
        @test infer_julia_type(Dict{String,Any}("defaultValue"=>2, "step"=>1, "juliaType"=>"Int64")) === Int64
        project = fixture_project([fixture_node("node-wind", "WT")])
        variables = detect_capacity_variables(project, "A")["variables"]
        legacy = deepcopy(variables)
        for item in legacy
            delete!(item, "valueKind"); delete!(item, "changeKind")
        end
        @test length(validate_capacity_variables(project, "A", legacy)) == 1
        candidate, _ = apply_capacity_candidate(project, "A", variables, [150.0])
        @test candidate["workspace"]["canvases"][2] == project["workspace"]["canvases"][2]
        @test project["workspace"]["canvases"][1]["nodes"][1]["data"]["business"]["commonTechParams"]["capacity"] == 100
        @test _quantize_candidate([35437.5], [merge(variables[1], Dict("lowerBound"=>22437.5,"upperBound"=>89750.0,"step"=>1000.0))]) == [35000.0]
        @test _quantize_candidate([123.5], [merge(variables[1], Dict("step"=>nothing))]) == [123.5]
        @test _quantize_candidate([2.7], [merge(variables[1], Dict("valueKind"=>"integer","lowerBound"=>1.0,"upperBound"=>4.0))]) == [3.0]
        @test _quantize_candidate([2.8], [merge(variables[1], Dict("valueKind"=>"tier","tiers"=>[1.0,3.0,5.0],"lowerBound"=>2.0,"upperBound"=>4.0))]) == [3.0]
    end

    @testset "Canvas isolation, extreme days and reproducible scenario weights" begin
        seed_boundary("wind", "wind_speed", [9,8,7,6,5,4,3,2])
        seed_boundary("load", "load", [1,2,3,4,5,6,9,8])
        seed_boundary("other", "load", fill(999,8))
        project = fixture_project([fixture_node("node-wind", "WT"; boundaries=["wind","load"])])
        config = Dict{String,Any}("projectId"=>"capacity-test","featureIds"=>["wind","load"],
            "clusterCount"=>2,"preserveExtremes"=>true,"seed"=>42)
        for algorithm in ("kmeans", "kmedoids")
            config["algorithm"] = algorithm
            preview = reduce_boundary_scenarios(config,"A",project)
            @test sum(item["weightDays"] for item in preview["scenarios"]) == 8
            @test sum(item["probability"] for item in preview["scenarios"]) ≈ 1.0
            @test count(item["preserved"] for item in preview["scenarios"]) == 2
            @test all(!haskey(item["series"], "other") for item in preview["scenarios"])
            @test preview["scenarioSetHash"] == reduce_boundary_scenarios(config,"A",project)["scenarioSetHash"]
            @test preview["manifest"]["canvasId"] == "A"
        end
        @test_throws ErrorException reduce_boundary_scenarios(merge(config,Dict("featureIds"=>["other"])),"A",project)
        normalized = _normalize_clustering_config(merge(config,Dict("scenarioPreviewHash"=>"hash")),"capacity-test","A")
        @test normalized["canvasId"] == "A"
        @test normalized["scenarioPreviewHash"] == "hash"
        @test normalized["preserveExtremes"]
        seed_boundary("wind", "wind_speed", [9,1])
        seed_boundary("load", "load", [10,2])
        for algorithm in ("kmeans", "kmedoids")
            tiny = reduce_boundary_scenarios(merge(config,Dict("algorithm"=>algorithm)),"A",project)
            @test sum(item["weightDays"] for item in tiny["scenarios"]) == 2
        end
    end

    @testset "Lifecycle cash flows agree with hand calculation" begin
        item = LifecycleCapexItem(node_id="wind",name="WT",comp_type="WT",capacity=100.0,
            capacity_unit="kW",unit_capex_yuan_per_unit=1000.0,capex_wan=10.0,existing_capacity=0.0,existing_capex_wan=0.0,
            change_kind="new",depreciation_years=2,salvage_rate=0.0)
        params = LifecycleFinancialParams(operation_years=2,discount_rate=0.1,income_tax_rate=0.0,
            output_vat_rate=0.0,input_vat_rate=0.0,construction_vat_rate=0.0,working_capital_rate=0.0)
        economic = evaluate_lifecycle(capex_items=[item],annual_revenue_yuan=80000.0,annual_opex_yuan=20000.0,
            annual_energy_kwh=100000.0,params=params)
        @test economic.after_tax_cashflow == [-10.0,6.0,6.0]
        @test economic.npv_after_tax_wan ≈ -10+6/1.1+6/1.1^2
        @test economic.irr_after_tax ≈ (6+sqrt(276))/20-1 atol=1e-8
        @test economic.payback_years ≈ 1+4/6
        @test economic.discounted_payback_years ≈ 1+(10-6/1.1)/(6/1.1^2)
        @test economic.lcoe_yuan_per_kwh ≈ (10+2/1.1+2/1.1^2)/(10/1.1+10/1.1^2)
        for objective in CAPACITY_OBJECTIVES
            fitness, reason = _objective_fitness(objective,economic,123.0)
            @test isfinite(fitness)
            @test reason == "ok"
        end
        retire = fixture_project([fixture_node("node-wind","WT";capacity=0.0)])
        retire["workspace"]["canvases"][1]["nodes"][1]["data"]["business"]["commonEconomicParams"]["initial_cost"] = 1000.0
        items, _ = extract_lifecycle_capex(retire,Dict("node-wind"=>0.0),Dict("node-wind"=>100.0),Dict("node-wind"=>"retire"),Dict("node-wind"=>"kW"),params)
        retired = evaluate_lifecycle(capex_items=items,annual_revenue_yuan=0.0,annual_opex_yuan=0.0,params=params)
        @test retired.disposal_recovery_wan ≈ 0.5
    end

    @testset "Post-simulation costs, annualization and serialized cashflow" begin
        project = fixture_project([fixture_node("node-wind","WT"),fixture_node("node-grid","GRID")])
        business = project["workspace"]["canvases"][1]["nodes"][1]["data"]["business"]
        business["commonEconomicParams"]["initial_cost"] = 1000.0
        business["commonEconomicParams"]["om_cost"] = 0.1
        business["commonEconomicParams"]["cut_cost"] = 0.0
        project["workspace"]["canvases"][1]["nodes"][2]["data"]["business"]["commonEconomicParams"]["sell_price"] = 0.5
        work = joinpath(TEST_DATA_ROOT,"economic-candidate")
        metrics = Dict{String,Any}[]
        for (index, weight, output) in ((1,2,1.0),(2,6,3.0))
            path = joinpath(work,"scenarios","scenario-$(index)","timeseries.db")
            timestamps = ["$(hour):00" for hour in 0:47]
            values = vcat(fill(output,24),fill(1.0e6,24))
            set_ts(path,"WT|E_WT_wind|power#1",TimeSeries(timestamps,values))
            set_ts(path,"WT|E_WT_cut_wind|power#1",TimeSeries(timestamps,fill(100.0,48)))
            set_ts(path,"GRID|E_GRID_in_grid|power#1",TimeSeries(timestamps,values))
            set_ts(path,"GRID|E_GRID_out_grid|power#1",TimeSeries(timestamps,zeros(48)))
            set_ts(path,"BUS|Q_EXCESS_test|slack#1",TimeSeries(timestamps,vcat(zeros(24),fill(1.0e6,24))))
            close_store(path)
            push!(metrics,Dict("scenarioId"=>"scenario-$(index)","weightDays"=>weight,"feasible"=>true))
        end
        simulation = EvaluationResult(feasible=true,operating_objective=0.0,metrics=Dict{String,Float64}(),scenario_metrics=metrics)
        input = EconomicEvaluationInput(capacities=Dict("node-wind"=>100.0),units=Dict("node-wind"=>"kW"),
            simulation=simulation,config=Dict{String,Any}("objective"=>"operating-cost-min"),work_dir=work,project_snapshot=project)
        evaluated = evaluate_economics(TimeseriesOperatingCostEvaluator(),input)
        @test evaluated.fitness ≈ (0.1-0.5)*24*(2*1+6*3)
        @test evaluated.indicators["lcoe"] !== nothing
        @test evaluated.breakdown["lifecycleAfterTaxCashflowWan"] isa Vector
        @test !isempty(JSON3.write(evaluated.breakdown))
        expected = evaluate_lifecycle(capex_items=extract_lifecycle_capex(project,input.capacities,input.original_capacities,input.change_kinds,input.units,LifecycleFinancialParams()).items,
            annual_revenue_yuan=0.5*24*2.5*365,annual_opex_yuan=0.1*24*2.5*365,annual_energy_kwh=24*2.5*365)
        @test evaluated.indicators["npv"] ≈ expected.npv_after_tax_wan*1e4
        @test evaluated.indicators["lcoe"] ≈ expected.lcoe_yuan_per_kwh
    end

    @testset "Real solver, optimization persistence and comparison" begin
        seed_boundary("wind", "wind_speed", [9,8,7,6,5,4,3,2])
        project = fixture_project([fixture_node("node-wind","WT";capacity=100000.0,boundaries=["wind"])])
        variables = detect_capacity_variables(project,"A")["variables"]
        request = Dict{String,Any}("projectId"=>project["id"],"canvasId"=>"A","projectJson"=>project,
            "variables"=>variables,"planningLayerId"=>"1",
            "clustering"=>Dict{String,Any}("featureIds"=>["wind"],"clusterCount"=>2,"preserveExtremes"=>true),
            "optimizer"=>Dict{String,Any}("maxFuncEvals"=>2,"populationSize"=>4,"maxTimeSeconds"=>5))
        planning = create_capacity_planning!(request)
        @test planning["config"]["economics"]["evaluator"] == DEFAULT_CAPACITY_EVALUATOR_VERSION
        result = run_capacity_optimization!(planning["id"],PlanningContext(Channel{Symbol}(1),nothing))
        @test get_planning_task(planning["id"])["status"] == "completed"
        @test result["evaluationCount"] <= 2
        @test isfinite(result["fitness"])
        @test result["breakdown"]["lifecycleAfterTaxCashflowWan"] isa AbstractVector
        comparison = build_planning_comparison(planning["id"])
        @test !isempty(comparison["candidates"])
        @test comparison["candidates"][1]["rank"] == 1
        @test comparison["candidates"][1]["metrics"]["detail"]["cashflowWan"] isa AbstractVector
        @test isempty(list_tasks())
        # Exercise the actual worker entry point, not just in-process evaluation.
        request["optimizer"]["maxTimeSeconds"] = 180
        isolated = create_capacity_planning!(request)
        start_capacity_planning!(isolated["id"])
        ctx = PLANNING_CONTEXTS[isolated["id"]]
        @test timedwait(() -> istaskdone(ctx.julia_task), 240.0) == :ok
        isolated_status = get_planning_task(isolated["id"])
        if isolated_status["status"] != "completed"
            @info "isolated worker failed" status=isolated_status["status"] err=isolated_status["errorCode"] msg=isolated_status["errorMessage"]
            logp = joinpath(planning_task_dir(isolated["id"]), "logs", "worker.log")
            isfile(logp) && @info "worker.log" text=String(read(logp))
        end
        @test isolated_status["status"] == "completed"
        @test get_planning_result(isolated["id"]) !== nothing
        @test ctx.process !== nothing && !process_running(ctx.process)
        @test isempty(list_tasks())
    end

    @testset "Cancellation interrupts native blocking, queued work and respects total deadlines" begin
        function native_block_command(marker)
            native_sleep = Sys.iswindows() ? "ccall((:Sleep, \"kernel32\"), Cvoid, (UInt32,), 60000)" : "ccall(:sleep, Cuint, (Cuint,), 60)"
            script = "write($(repr(marker)), \"ready\"); " * native_sleep
            return Cmd(`$(Base.julia_cmd()) --startup-file=no -e $script`; windows_hide=true)
        end
        function blocking_record(seconds=60)
            create_planning_record!(project_id="capacity-test",canvas_id="A",name="cancel-test",
                project_updated_at="v1",snapshot_hash="test",
                config=Dict("optimizer"=>Dict("maxTimeSeconds"=>seconds)))
        end
        marker = joinpath(TEST_DATA_ROOT,"native-ready")
        unrelated = run(pipeline(native_block_command(joinpath(TEST_DATA_ROOT,"unrelated-ready")); stdout=devnull,stderr=devnull); wait=false)
        first_id = blocking_record()
        start_capacity_planning!(first_id;worker_command=native_block_command(marker))
        first_ctx = PLANNING_CONTEXTS[first_id]
        try
            @test timedwait(() -> isfile(marker),30.0) == :ok
            @test_throws ErrorException start_capacity_planning!(first_id;worker_command=native_block_command(marker))
            @test PLANNING_CONTEXTS[first_id] === first_ctx
            progress = get_planning_task(first_id)["progress"]
            progress["currentScenario"] = Dict("id"=>"blocking-scene", "stage"=>"solving")
            update_planning_progress!(first_id, progress)
            @test timedwait(() -> get_planning_task(first_id)["progress"]["elapsedMs"] > 0,3.0) == :ok
            @test get_planning_task(first_id)["progress"]["currentScenario"]["id"] == "blocking-scene"
            # Queue a second task, then cancel it before any worker is launched.
            second_id = blocking_record()
            second_marker = joinpath(TEST_DATA_ROOT,"queued-ready")
            start_capacity_planning!(second_id;worker_command=native_block_command(second_marker))
            second_ctx = PLANNING_CONTEXTS[second_id]
            @test cancel_capacity_planning!(second_id)["status"] == "cancelled"
            @test !isfile(second_marker)
            before = time()
            cancel_capacity_planning!(first_id)
            @test timedwait(() -> istaskdone(first_ctx.julia_task),5.0) == :ok
            @test time()-before < 5.0
            println("CAPACITY_NATIVE_CANCEL_MS=",round(Int,(time()-before)*1000))
            @test !process_running(first_ctx.process)
            @test get_planning_task(first_id)["status"] == "cancelled"
            @test cancel_capacity_planning!(first_id)["status"] == "cancelled"
            @test get_planning_result(first_id) === nothing
            @test process_running(unrelated)
            @test timedwait(() -> istaskdone(second_ctx.julia_task),5.0) == :ok
            @test second_ctx.process === nothing
        finally
            if first_ctx.process !== nothing && process_running(first_ctx.process)
                kill(first_ctx.process); wait(first_ctx.process)
            end
            if process_running(unrelated); kill(unrelated); wait(unrelated); end
        end
        timeout_id = blocking_record(1)
        start_capacity_planning!(timeout_id;worker_command=native_block_command(joinpath(TEST_DATA_ROOT,"timeout-ready")))
        timeout_ctx = PLANNING_CONTEXTS[timeout_id]
        @test timedwait(() -> istaskdone(timeout_ctx.julia_task),10.0) == :ok
        @test get_planning_task(timeout_id)["errorCode"] == "PLANNING_TIME_LIMIT"
        @test !process_running(timeout_ctx.process)
        # Hard timeouts may return a committed best candidate; explicit cancel
        # must remain cancelled even if such a candidate already exists.
        source = first(task for task in list_planning_tasks() if task["status"] == "completed")
        completed = first(item for item in list_planning_evaluations(source["id"]) if item["feasible"])
        for cancel in (false, true)
            config = deepcopy(source["config"])
            config["optimizer"]["maxTimeSeconds"] = cancel ? 60 : 1
            id = create_planning_record!(project_id="capacity-test",canvas_id="A",name="partial-test",
                project_updated_at="v1",snapshot_hash="test",config=config)
            mkpath(planning_task_dir(id))
            cp(joinpath(planning_task_dir(source["id"]),"scenarios.json"), joinpath(planning_task_dir(id),"scenarios.json"))
            insert_planning_evaluation!(planning_id=id,ordinal=1,candidate_hash="partial",candidate=completed["candidate"],
                feasible=true,fitness=completed["fitness"],breakdown=completed["breakdown"],duration_ms=1)
            marker = joinpath(TEST_DATA_ROOT, "partial-$(cancel)")
            start_capacity_planning!(id;worker_command=native_block_command(marker))
            ctx = PLANNING_CONTEXTS[id]
            if cancel
                @test timedwait(() -> isfile(marker),30.0) == :ok
                cancel_capacity_planning!(id)
            end
            @test timedwait(() -> istaskdone(ctx.julia_task),10.0) == :ok
            @test !process_running(ctx.process)
            @test get_planning_task(id)["status"] == (cancel ? "cancelled" : "completed")
            if cancel
                @test get_planning_result(id) === nothing
            else
                @test get_planning_result(id)["fitness"] == completed["fitness"]
                @test any(occursin("总时限",warning) for warning in get_planning_result(id)["warnings"])
            end
        end
    end
end

for path in collect(keys(STORE_REGISTRY)); close_store(path); end
if PLANNING_STORE_REF[] !== nothing; SQLite.close(PLANNING_STORE_REF[]); end
println("CAPACITY_TEST_DATA_ROOT=",TEST_DATA_ROOT)
