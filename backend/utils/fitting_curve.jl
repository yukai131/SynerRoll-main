# ═══════════════════════════════════════════════════════════════════════════
# fitting_curve.jl — 机型拟合曲线求值（整场功率）
#
# 风机：四段（0 / 三次多项式 / 额定平台 / 0）
# 光伏：P = a·G² + b·G + c·T + d·G·T + e
# ═══════════════════════════════════════════════════════════════════════════

"""对风速向量求分段功率（整场，已含高度/效率换算）"""
function evaluate_wind_fitting_curve(wind_speed::AbstractVector, params::AbstractDict)
    v_in = Float64(get(params, "v_in", 0.0))
    v_r = Float64(get(params, "v_r", 0.0))
    v_out = Float64(get(params, "v_out", 0.0))
    a3 = Float64(get(params, "a3", 0.0))
    a2 = Float64(get(params, "a2", 0.0))
    a1 = Float64(get(params, "a1", 0.0))
    a0 = Float64(get(params, "a0", 0.0))
    p_rated = Float64(get(params, "p_rated", 0.0))

    result = Vector{Float64}(undef, length(wind_speed))
    for (i, raw) in enumerate(wind_speed)
        v = Float64(raw)
        if !isfinite(v)
            result[i] = 0.0
        elseif v < v_in
            result[i] = 0.0
        elseif v < v_r
            p = a3 * v^3 + a2 * v^2 + a1 * v + a0
            result[i] = max(p, 0.0)
        elseif v < v_out
            result[i] = max(p_rated, 0.0)
        else
            result[i] = 0.0
        end
    end
    return result
end

"""对辐照度/温度向量求光伏整场功率"""
function evaluate_pv_fitting_curve(
    irradiance::AbstractVector,
    temperature::AbstractVector,
    params::AbstractDict,
)
    a = Float64(get(params, "a", 0.0))
    b = Float64(get(params, "b", 0.0))
    c = Float64(get(params, "c", 0.0))
    d = Float64(get(params, "d", 0.0))
    e = Float64(get(params, "e", 0.0))

    n = min(length(irradiance), length(temperature))
    result = Vector{Float64}(undef, n)
    for i in 1:n
        G = Float64(irradiance[i])
        T = Float64(temperature[i])
        if !isfinite(G) || !isfinite(T)
            result[i] = 0.0
        else
            result[i] = a * G^2 + b * G + c * T + d * G * T + e
        end
    end
    return result
end
