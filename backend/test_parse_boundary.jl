# Minimal unit test for parse_boundary_data (no SQLite)
using Random, Statistics, Dates

# stubs matching backend utils
include("utils/timestr_utils.jl")

struct TimeSeries
    timestamps::Vector{String}
    values::Vector{Float64}
    function TimeSeries(timestamps::Vector{String}, values::Vector{<:Real})
        length(timestamps) == length(values) || error("len mismatch")
        new(timestamps, convert(Vector{Float64}, values))
    end
end

# load only the pure parse helpers by evaluating boundary_service up to preprocess
src = read("services/boundary_service.jl", String)
# cut at preprocess to avoid SQLite deps
cut = findfirst("function preprocess_boundary_data", src)
pure = src[1:cut.start-1]
include_string(Main, pure, "boundary_service_parse.jl")

function assert_true(cond, msg)
    cond || error("FAIL: $msg")
    println("OK: $msg")
end

# 1) insufficient data → error
try
    parse_boundary_data(Any[1.0 for _ in 1:168], "1h", Dict("length"=>"8760h","step"=>"1h"))
    error("should have thrown")
catch e
    msg = sprint(showerror, e)
    assert_true(occursin("长度不足", msg), "insufficient length errors: $msg")
end

# 2) 24h 1h → 24h 5min with noise: anchors exact
rng = MersenneTwister(42)
src_vals = Any[Float64(i) for i in 1:24]
ts = parse_boundary_data(src_vals, "1h", Dict("length"=>"24h","step"=>"5m");
    interpolate_type="linear", noise_level=0.5, noise_distribution="normal", rng=rng)
assert_true(length(ts.values) == 288, "24h@5m = 288 points, got $(length(ts.values))")
# anchors at 0,60,...,1380 min → indices 1,13,25,...
for (k, hv) in enumerate(src_vals)
    idx = (k-1)*12 + 1
    assert_true(ts.values[idx] == hv, "anchor $(k) exact: $(ts.values[idx]) vs $hv")
end
# non-anchors should differ from pure linear at least sometimes
has_noise = any(abs(ts.values[i] - ts.values[1 + div(i-1,12)*12]) > 1e-12 for i in 2:12)
# weaker check: some intermediate != linear interp
println("  sample non-anchor around 5min: ", ts.values[2], " (linear base ~ ", 1.0 + (1.0/12)*(2-1), ")")

# 3) same scale preserves values even with noise (all anchors)
ts2 = parse_boundary_data(src_vals, "1h", Dict("length"=>"24h","step"=>"1h");
    interpolate_type="linear", noise_level=0.9, rng=MersenneTwister(1))
assert_true(ts2.values == Float64.(src_vals), "same-scale keeps anchors exact")

# 4) longer data keeps full length (no truncate to layer.length)
ts3 = parse_boundary_data(Any[Float64(i) for i in 1:48], "1h", Dict("length"=>"24h","step"=>"1h"))
assert_true(length(ts3.values) == 48, "full-length output, got $(length(ts3.values))")
assert_true(ts3.values == Float64.(1:48), "full-length values preserved")

# 5) cubic works
ts4 = parse_boundary_data(src_vals, "1h", Dict("length"=>"24h","step"=>"5m");
    interpolate_type="cubic", noise_level=0.0)
assert_true(length(ts4.values) == 288, "cubic 288 points")

# 6) boundary_length shorter than layer → error
try
    parse_boundary_data(src_vals, "1h", Dict("length"=>"48h","step"=>"1h"); boundary_length="24h")
    error("should have thrown")
catch e
    assert_true(occursin("小于时层需求", sprint(showerror, e)), "boundary_length short errors")
end

# 7) 0~100 归一
ts5 = parse_boundary_data(src_vals, "1h", Dict("length"=>"24h","step"=>"5m");
    interpolate_type="linear", noise_level=50.0, rng=MersenneTwister(7))
assert_true(length(ts5.values) == 288, "noise 50 accepted")
# 与 0.5 等价强度
ts5b = parse_boundary_data(src_vals, "1h", Dict("length"=>"24h","step"=>"5m");
    interpolate_type="linear", noise_level=0.5, rng=MersenneTwister(7))
assert_true(ts5.values == ts5b.values, "50 == 0.5 after normalize")

# 8) 默认非负限位
neg = Any[-5.0, -1.0, 0.0, 2.0, -0.5, 3.0, -2.0, 1.0, -0.1, 4.0, -3.0, 2.0,
          -1.5, 0.5, -4.0, 1.5, -0.2, 2.5, -2.5, 0.2, -1.0, 3.5, -0.3, 5.0]
ts6 = parse_boundary_data(neg, "1h", Dict("length"=>"24h","step"=>"5m"); interpolate_type="linear", noise_level=0.0)
assert_true(all(x -> x >= 0.0, ts6.values), "default clamp >= 0")
# 锚点若为负也应被限到 0（输出统一非负）
assert_true(ts6.values[1] == 0.0, "negative anchor clamped to 0")

# 9) 温度例外
ts7 = parse_boundary_data(neg, "1h", Dict("length"=>"24h","step"=>"1h");
    interpolate_type="linear", noise_level=0.0, allow_negative=true)
assert_true(any(x -> x < 0.0, ts7.values), "allow_negative keeps negatives")

println("ALL TESTS PASSED")
