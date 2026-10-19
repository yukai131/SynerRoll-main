# Unit tests for seed helpers (pure) + include parse tests
using Random, Statistics, Dates

include("utils/timestr_utils.jl")

struct TimeSeries
    timestamps::Vector{String}
    values::Vector{Float64}
    function TimeSeries(timestamps::Vector{String}, values::Vector{<:Real})
        length(timestamps) == length(values) || error("len mismatch")
        new(timestamps, convert(Vector{Float64}, values))
    end
end

src = read("services/boundary_service.jl", String)
cut = findfirst("function preprocess_boundary_data", src)
include_string(Main, src[1:cut.start-1], "boundary_parse.jl")

# extract seed helpers
h0 = findfirst("function _cycle_pad_values", src)
h1 = findfirst("function seed_task_boundary_data", src)
include_string(Main, src[h0.start:h1.start-1], "seed_helpers.jl")

function assert_true(cond, msg)
    cond || error("FAIL: $msg")
    println("OK: $msg")
end

# cycle pad
p = _cycle_pad_values([1.0, 2.0, 3.0], 5)
assert_true(p == [1.0, 2.0, 3.0, 1.0, 2.0], "cycle pad 5")

# append lookahead from source
src_min = collect(0:60:1380)  # 0..1380 min = 24 points 1h
src_val = Float64.(1:24)
win_min = collect(0:60:660)   # 12 points = 12h window
win_val = Float64.(1:12)
# window_end = 12*60 = 720; lookahead 6h = 360min → 6 points from source 720..1080
ts, vals = _append_lookahead(win_min, win_val, src_min, src_val, 720, 360, 60)
assert_true(length(ts) == 18, "lookahead 6 pts, got $(length(ts))")
assert_true(vals[13:18] == Float64.(13:18), "real source lookahead")
assert_true(ts[end] == 17*60, "ts continuous end=$(ts[end])")

# look-ahead beyond source → cycle pad
ts2, vals2 = _append_lookahead(win_min, win_val, src_min, src_val, 720, 24*60, 60)
assert_true(length(ts2) == 12 + 24, "pad 24h beyond source, got $(length(ts2))")
assert_true(vals2[13] == 1.0, "cycle restarts from window[1]")
assert_true(vals2[end] == 12.0, "cycle ends at window last")

# zero lookahead is no-op
ts3, vals3 = _append_lookahead(win_min, win_val, src_min, src_val, 720, 0, 60)
assert_true(length(ts3) == 12, "zero lookahead unchanged")

# 日历：源为绝对分钟，窗口结束后取真实 look-ahead
src_min2 = collect(0:60:60*48-60)  # 2 days hourly
src_val2 = Float64.(1:48)
# task day1 only: window local 0..1380, absolute source_start=0, source_end=1440
win2_min = collect(0:60:1380)
win2_val = Float64.(1:24)
ts4, vals4 = _append_lookahead(win2_min, win2_val, src_min2, src_val2, 1440, 6*60, 60)
assert_true(length(ts4) == 24 + 6, "calendar la len $(length(ts4))")
assert_true(vals4[25:30] == Float64.(25:30), "calendar la uses day2 real points")
assert_true(ts4[end] == 29*60, "calendar la local ts continuous")

println("SEED HELPER TESTS PASSED")
