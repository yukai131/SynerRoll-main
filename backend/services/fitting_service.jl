# ═══════════════════════════════════════════════════════════════════════════
# fitting_service.jl — 设备参数拟合（风机 / 光伏）
#
# 从本地 CSV 运行数据拟合「气象条件 → 最大出力」关系：
#   风机：四段功率曲线（0 / 三次多项式 / 额定平台 / 0），不强制约束端点
#   光伏：P = a·G² + b·G + c·T + d·G·T + e
# 依赖：utils/server_utils.jl、utils/fitting_curve.jl
# ═══════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# 通用
# ─────────────────────────────────────────────────────────────────────────────

function _finite_pairs(v::AbstractVector, p::AbstractVector)
    n = min(length(v), length(p))
    xs = Float64[]
    ys = Float64[]
    for i in 1:n
        x = try Float64(v[i]) catch; NaN end
        y = try Float64(p[i]) catch; NaN end
        if isfinite(x) && isfinite(y)
            push!(xs, x)
            push!(ys, y)
        end
    end
    return xs, ys
end

function _r2_rmse(y_true::Vector{Float64}, y_pred::Vector{Float64})
    n = length(y_true)
    n == 0 && return (r2=NaN, rmse=NaN)
    y_bar = sum(y_true) / n
    ss_tot = sum((y_true .- y_bar) .^ 2)
    ss_res = sum((y_true .- y_pred) .^ 2)
    r2 = ss_tot <= 0 ? NaN : 1.0 - ss_res / ss_tot
    rmse = sqrt(ss_res / n)
    return (r2=r2, rmse=rmse)
end

function _fmt_num(x::Real; digits::Int=6)
    v = Float64(x)
    if abs(v) >= 1e6 || (abs(v) > 0 && abs(v) < 1e-3)
        return string(round(v; sigdigits=digits))
    end
    s = string(round(v; digits=min(digits, 6)))
    return s
end

function _downsample_xy(x::Vector{Float64}, y::Vector{Float64}; max_points::Int=2000)
    n = length(x)
    n <= max_points && return collect(zip(x, y))
    step = max(1, n ÷ max_points)
    return collect(zip(x[1:step:end], y[1:step:end]))
end

# ─────────────────────────────────────────────────────────────────────────────
# 风机：四段曲线
# ─────────────────────────────────────────────────────────────────────────────

function _wind_formula_text(params::Dict{String,Any})
    v_in = params["v_in"]
    v_r = params["v_r"]
    v_out = params["v_out"]
    a3, a2, a1, a0 = params["a3"], params["a2"], params["a1"], params["a0"]
    p_rated = params["p_rated"]

    parts = String[]
    for (coef, mono) in ((a3, "v³"), (a2, "v²"), (a1, "v"), (a0, ""))
        c = Float64(coef)
        abs(c) < 1e-12 && continue
        body = isempty(mono) ? _fmt_num(abs(c)) : "$(_fmt_num(abs(c)))·$(mono)"
        if c < 0
            push!(parts, isempty(parts) ? "-$(body)" : " - $(body)")
        else
            push!(parts, isempty(parts) ? body : " + $(body)")
        end
    end
    cubic_body = isempty(parts) ? "P(v) = 0" : "P(v) = " * join(parts)

    return """
P(v) = 0,                              v < $(_fmt_num(v_in)) m/s
$(cubic_body),   $(_fmt_num(v_in)) ≤ v < $(_fmt_num(v_r)) m/s
P(v) = $(_fmt_num(p_rated)),            $(_fmt_num(v_r)) ≤ v < $(_fmt_num(v_out)) m/s
P(v) = 0,                              v ≥ $(_fmt_num(v_out)) m/s
"""
end

"""
    fit_wind_curve(wind_speed, power) -> Dict

估计切入/额定/切出风速，并对上升段做三次最小二乘（不强制端点约束）。

分段识别策略（抗噪声）：
1. 按风速分箱，用箱内中位数代替原始点；
2. 额定功率用「高功率箱」的稳健估计，而不是 noisy max；
3. 切入/切出/额定分界由分箱中位数序列判定；
4. 上升段三次拟合落在分箱中心+中位数上，避免被平台噪声拉弯。
"""
function fit_wind_curve(wind_speed::AbstractVector, power::AbstractVector)
    v, p = _finite_pairs(wind_speed, power)
    n = length(v)
    n < 8 && error("有效样本过少（$(n)），至少需要 8 个点")

    p_min_raw, p_max_raw = extrema(p)
    p_max_raw <= 0 && error("功率列全为非正数，无法拟合")

    v_lo0, v_hi0 = extrema(v)
    bin_w = 0.5
    span = max(v_hi0 - v_lo0, bin_w)
    nbins = max(4, ceil(Int, span / bin_w))
    edges = range(v_lo0, v_hi0; length=nbins + 1)

    bin_center = Float64[]
    bin_median = Float64[]
    bin_n = Int[]
    for b in 1:nbins
        lo, hi = edges[b], edges[b + 1]
        mask = (v .>= lo) .& (b == nbins ? (v .<= hi) : (v .< hi))
        n_bin = count(mask)
        n_bin == 0 && continue
        vals = p[mask]
        push!(bin_center, (lo + hi) / 2)
        push!(bin_median, _median(vals))
        push!(bin_n, n_bin)
    end
    isempty(bin_median) && error("无法建立风速分箱")

    max_bin = maximum(bin_median)
    max_bin <= 0 && error("分箱功率全为非正数")

    # 额定功率稳健估计：取「高功率箱」（≥70% 峰值箱中位数）的中位数
    high_mask = bin_median .>= 0.70 * max_bin
    p_rated_est = any(high_mask) ? _median(bin_median[high_mask]) : max_bin

    thr = max(0.01 * p_rated_est, 1e-9)
    active = findall(m -> m > thr, bin_median)
    isempty(active) && error("未找到有效出力分箱")

    v_in = bin_center[active[1]] - bin_w / 2
    v_out = bin_center[active[end]] + bin_w / 2
    if v_out <= v_in
        error("有效风速范围退化：v_in=$(v_in), v_out=$(v_out)")
    end

    # 额定平台起点：中位数首次稳定达到额定水平
    rated_thr = 0.92 * p_rated_est
    v_r = v_out
    for b in active
        if bin_median[b] >= rated_thr
            v_r = max(bin_center[b] - bin_w / 2, v_in + 1e-6)
            break
        end
    end

    # 若未检出平台，用斜率变缓处作为拐点
    if v_r >= v_out - 1e-6 && length(active) >= 3
        for i in 2:(length(active) - 1)
            b0, b1, b2 = active[i - 1], active[i], active[i + 1]
            slope_left = (bin_median[b1] - bin_median[b0]) / max(bin_center[b1] - bin_center[b0], 1e-9)
            slope_right = (bin_median[b2] - bin_median[b1]) / max(bin_center[b2] - bin_center[b1], 1e-9)
            if bin_median[b1] >= 0.75 * p_rated_est && slope_right < 0.25 * abs(slope_left) + 1e-9
                v_r = max(bin_center[b1] - bin_w / 2, v_in + 1e-6)
                break
            end
        end
    end

    # 上升段：用分箱中位数做三次拟合（按箱内样本数加权）
    rise_bins = [b for b in active if bin_center[b] < v_r - 1e-9]
    if length(rise_bins) < 4
        rise_bins = [b for b in active if bin_center[b] < v_out - 1e-9]
    end
    length(rise_bins) < 4 && error("上升段分箱不足，无法做三次拟合（$(length(rise_bins))）")

    cx = bin_center[rise_bins]
    cy = bin_median[rise_bins]
    w = Float64[bin_n[b] for b in rise_bins]
    # 加权最小二乘：sqrt(w) * X \ sqrt(w) * y
    sw = sqrt.(w)
    X = [cx .^ 3 cx .^ 2 cx ones(length(cx))]
    coef = (X .* sw) \ (cy .* sw)
    a3, a2, a1, a0 = coef[1], coef[2], coef[3], coef[4]

    # 额定平台功率：平台分箱中位数的稳健均值
    plateau_bins = [b for b in active if bin_center[b] >= v_r - 1e-9 && bin_center[b] <= v_out + 1e-9]
    if isempty(plateau_bins)
        p_rated = p_rated_est
    else
        p_rated = _median(bin_median[plateau_bins])
    end

    params = Dict{String,Any}(
        "v_in" => v_in,
        "v_r" => v_r,
        "v_out" => v_out,
        "a3" => a3,
        "a2" => a2,
        "a1" => a1,
        "a0" => a0,
        "p_rated" => p_rated,
    )

    y_pred_all = evaluate_wind_fitting_curve(v, params)
    r2, rmse = _r2_rmse(p, y_pred_all)

    # 图表曲线
    curve_x = collect(range(minimum(v), maximum(v); length=200))
    curve_y = evaluate_wind_fitting_curve(curve_x, params)
    curve = [Dict{String,Any}("x" => curve_x[i], "y" => curve_y[i]) for i in eachindex(curve_x)]

    scatter_pairs = _downsample_xy(v, p)
    scatter = [Dict{String,Any}("x" => x, "y" => y) for (x, y) in scatter_pairs]

    return Dict{String,Any}(
        "type" => "wind",
        "params" => params,
        "formulaText" => _wind_formula_text(params),
        "scatter" => scatter,
        "curve" => curve,
        "stats" => Dict{String,Any}("n" => n, "r2" => r2, "rmse" => rmse),
    )
end

function _median(vals::AbstractVector{<:Real})
    isempty(vals) && return NaN
    s = sort(Float64.(collect(vals)))
    m = length(s)
    return isodd(m) ? s[(m + 1) ÷ 2] : (s[m ÷ 2] + s[m ÷ 2 + 1]) / 2
end

# ─────────────────────────────────────────────────────────────────────────────
# 光伏：P = a·G² + b·G + c·T + d·G·T + e
# ─────────────────────────────────────────────────────────────────────────────

function _pv_formula_text(params::Dict{String,Any})
    a, b, c, d, e = params["a"], params["b"], params["c"], params["d"], params["e"]
    parts = String[]
    for (coef, mono) in ((a, "G²"), (b, "G"), (c, "T"), (d, "G·T"), (e, ""))
        k = Float64(coef)
        abs(k) < 1e-12 && continue
        body = isempty(mono) ? _fmt_num(abs(k)) : "$(_fmt_num(abs(k)))·$(mono)"
        if k < 0
            push!(parts, isempty(parts) ? "-$(body)" : " - $(body)")
        else
            push!(parts, isempty(parts) ? body : " + $(body)")
        end
    end
    return "P(G, T) = " * (isempty(parts) ? "0" : join(parts))
end

function fit_pv_curve(
    irradiance::AbstractVector,
    temperature::AbstractVector,
    power::AbstractVector,
)
    n0 = min(length(irradiance), length(temperature), length(power))
    g = Float64[]
    t = Float64[]
    p = Float64[]
    for i in 1:n0
        gi = try Float64(irradiance[i]) catch; NaN end
        ti = try Float64(temperature[i]) catch; NaN end
        pi = try Float64(power[i]) catch; NaN end
        if isfinite(gi) && isfinite(ti) && isfinite(pi)
            push!(g, gi)
            push!(t, ti)
            push!(p, pi)
        end
    end
    n = length(g)
    n < 5 && error("有效样本过少（$(n)），至少需要 5 个点")

    X = [g .^ 2 g t (g .* t) ones(n)]
    coef = X \ p
    a, b, c, d, e = coef[1], coef[2], coef[3], coef[4], coef[5]

    params = Dict{String,Any}(
        "a" => a,
        "b" => b,
        "c" => c,
        "d" => d,
        "e" => e,
    )

    y_pred = evaluate_pv_fitting_curve(g, t, params)
    r2, rmse = _r2_rmse(p, y_pred)

    t_mean = sum(t) / n
    g_min, g_max = extrema(g)
    curve_x = collect(range(g_min, g_max; length=200))
    curve_t = fill(t_mean, length(curve_x))
    curve_y = evaluate_pv_fitting_curve(curve_x, curve_t, params)
    curve = [Dict{String,Any}("x" => curve_x[i], "y" => curve_y[i]) for i in eachindex(curve_x)]

    # 散点降采样（保留温度用于着色）
    step = max(1, n ÷ 2000)
    scatter = Dict{String,Any}[]
    for i in 1:step:n
        push!(scatter, Dict{String,Any}("x" => g[i], "y" => p[i], "t" => t[i]))
    end

    return Dict{String,Any}(
        "type" => "pv",
        "params" => params,
        "formulaText" => _pv_formula_text(params),
        "scatter" => scatter,
        "curve" => curve,
        "stats" => Dict{String,Any}("n" => n, "r2" => r2, "rmse" => rmse),
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# 路由入口
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_fitting(body) -> Dict

body:
- type: "wind" | "pv"
- filePath
- powerColumn
- inputColumns: wind=["windSpeedCol"] / pv=["irradianceCol","temperatureCol"]
"""
function run_fitting(body::Dict)
    fitting_type = require_string(body, "type")
    file_path = require_string(body, "filePath")
    power_column = require_string(body, "powerColumn")
    input_columns_raw = get(body, "inputColumns", String[])
    input_columns = String[string(c) for c in input_columns_raw]

    if fitting_type == "wind"
        length(input_columns) >= 1 || error("风机拟合需要风速列名")
        wind_col = input_columns[1]
        wind_data, _ = read_csv_column(file_path, wind_col)
        power_data, _ = read_csv_column(file_path, power_column)
        wind_vals = Float64[Float64(x) for x in extract_float_column(wind_data)]
        power_vals = Float64[Float64(x) for x in extract_float_column(power_data)]
        return fit_wind_curve(wind_vals, power_vals)
    elseif fitting_type == "pv"
        length(input_columns) >= 2 || error("光伏拟合需要辐照度列名和温度列名")
        irr_col, temp_col = input_columns[1], input_columns[2]
        irr_data, _ = read_csv_column(file_path, irr_col)
        temp_data, _ = read_csv_column(file_path, temp_col)
        power_data, _ = read_csv_column(file_path, power_column)
        irr_vals = Float64[Float64(x) for x in extract_float_column(irr_data)]
        temp_vals = Float64[Float64(x) for x in extract_float_column(temp_data)]
        power_vals = Float64[Float64(x) for x in extract_float_column(power_data)]
        return fit_pv_curve(irr_vals, temp_vals, power_vals)
    else
        error("未知拟合类型: $(fitting_type)")
    end
end
