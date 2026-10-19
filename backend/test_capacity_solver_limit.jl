using Test
ENV["SYNERROLL_CAPACITY_WORKER"] = "1"
ENV["SYNERROLL_DATA_DIR"] = mktempdir(; cleanup=false)
include("server.jl")

function limited_model(primal_status)
    optimizer = MOI.Utilities.MockOptimizer(MOI.Utilities.Model{Float64}())
    MOI.Utilities.set_mock_optimize!(optimizer, mock ->
        MOI.Utilities.mock_optimize!(mock, MOI.TIME_LIMIT, (primal_status, [2.0])))
    model = Model(() -> optimizer)
    @variable(model, x >= 0)
    @objective(model, Min, x)
    return model
end

@testset "Solver time limit acceptance is restricted to planning feasible solutions" begin
    layer = Dict{String,Any}("id"=>"1", "length"=>"24h", "step"=>"1h")
    database = joinpath(ENV["SYNERROLL_DATA_DIR"],"mock.db")
    @test solve_model(limited_model(MOI.FEASIBLE_POINT), AbstractComponent[], layer, "0:00", database) === nothing
    result = solve_model(limited_model(MOI.FEASIBLE_POINT), AbstractComponent[], layer, "0:00", database;
        allow_time_limit_solution=true)
    @test result !== nothing
    @test result[1] == 2.0
    @test solve_model(limited_model(MOI.NO_SOLUTION), AbstractComponent[], layer, "0:00", database;
        allow_time_limit_solution=true) === nothing
end
for path in collect(keys(STORE_REGISTRY)); close_store(path); end
