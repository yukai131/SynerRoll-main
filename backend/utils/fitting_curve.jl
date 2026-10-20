# fitting_curve.jl — 机型拟合曲线求值
#
# 风机：四段（0 / 三次多项式 / 额定平台 / 0）
# 光伏：P = a·G² + b·G + c·T + d·G·T + e
#
# 拟合曲线默认输出「测试样本量级」的整场绝对功率。仿真建模时需要
# 保留曲线形状，并缩放到组件装机容量（capacity），见
# scale_fitting_power_to_capacity。

"""
    evaluate_wind_fitting_curve(wind_speed, params) -> Vector{Float64}

对风速向量求分段功率（测试样本量级的整场绝对功率，已含高度/效率换算）。
"""
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

"""
    evaluate_pv_fitting_curve(irradiance, temperature, params) -> Vector{Float64}

对辐照度/温度向量求光伏整场功率（测试样本量级的绝对功率）。
"""
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

"""
    wind_fitting_reference_power(params) -> Float64

风机拟合曲线的满量程参考功率，取 params.p_rated（额定平台）。
"""
function wind_fitting_reference_power(params::AbstractDict)
    return Float64(get(params, "p_rated", 0.0))
end

"""
    pv_fitting_reference_power(params) -> Float64

光伏拟合曲线的满量程参考功率：
- 优先取 params.p_rated（拟合时写入的满量程）；
- 否则取曲线在辐照域 [0, 1500] W/m²、T=25℃ 上的最大值。
"""
function pv_fitting_reference_power(params::AbstractDict)
    explicit = get(params, "p_rated", nothing)
    if explicit !== nothing
        ref = Float64(explicit)
        ref > 0 && return ref
    end

    best = 0.0
    for G in 0.0:10.0:1500.0
        p = evaluate_pv_fitting_curve([G], [25.0], params)[1]
        best = max(best, Float64(p))
    end
    return best
end

"""
    scale_fitting_power_to_capacity(power, capacity, reference_power) -> Vector{Float64}

保留拟合曲线形状，按装机容量缩放（满量程对齐装机）：

    P_scaled = P_fit * (capacity / reference_power)

并钳位到 [0, capacity]，避免高资源时段超过装机。
reference_power 非正时抛错（拟合参数无效）。
"""
function scale_fitting_power_to_capacity(
    power::AbstractVector,
    capacity::Real,
    reference_power::Real,
)
    cap = Float64(capacity)
    ref = Float64(reference_power)
    cap > 0 || error("capacity must be positive to scale fitting curve, got $(cap)")
    ref > 0 || error("fitting reference power must be positive to scale by capacity, got $(ref)")

    ratio = cap / ref
    return [clamp(Float64(p) * ratio, 0.0, cap) for p in power]
end
