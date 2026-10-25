using Clustering
using Dates
using JSON3
using Random
using SHA
using Statistics
using TimeZones

# ───── 数据读取与预处理 ─────

"""
    load_ts_boundary_features(project_id, feature_ids, all_boundary_ids) -> (metadata, processed_data, warnings)

从 boundary.db 读取并预处理边界数据。
- 如果 feature_ids 为空，自动从 boundary.db 获取所有有数据的边界ID
- 以最短的 boundaryLength 为准，截断到24h的倍数
- 先截断再统一尺度到1h

返回：
- metadata: 包含 series 信息的元数据
- processed_data: Dict{boundary_id => Vector{Float64}} （1h尺度的数据）
- warnings: 提示信息
"""
function load_ts_boundary_features(
    project_id::String,
    feature_ids::Vector{String},
    all_boundary_ids::Vector{String},
)
    # 始终处理所有边界（特征+跟随），确保后续能提取完整数据
    isempty(all_boundary_ids) && error("项目 $(project_id) 没有配置任何边界")

    # 验证特征边界ID存在于项目中
    for fid in feature_ids
        fid in all_boundary_ids || error("边界 $(fid) 不存在于项目中")
    end

    # 调用预处理函数，始终处理所有边界
    prepared = prepare_boundaries_for_clustering(project_id, all_boundary_ids)

    # 构建 metadata：从 time_series_meta 读取 var_name
    db_path = joinpath(BACKEND_DATA_DIR, "projects", project_id, "boundary.db")
    store = get_store(db_path)

    series_info = Dict{String,Any}[]
    lock(store.write_lock) do
        for fid in all_boundary_ids
            meta_rows = _query(store.db, """
                SELECT var_name, layer_id FROM time_series_meta
                WHERE source_id=? AND remark='planned'
                ORDER BY CAST(layer_id AS INTEGER) ASC LIMIT 1
            """, [fid])
            var_name = isempty(meta_rows[1]) ? fid : String(meta_rows[1][1])
            layer_id = isempty(meta_rows[2]) ? "1" : String(meta_rows[2][1])
            push!(series_info, Dict{String,Any}(
                "boundaryId" => fid,
                "name" => var_name,
                "meaning" => var_name,
                "unit" => "",
                "layerId" => layer_id,
            ))
        end
    end

    metadata = Dict{String,Any}(
        "id" => "ts-$(project_id)",
        "name" => "项目边界数据",
        "resolutionMinutes" => 60,
        "timezone" => "Asia/Shanghai",
        "contentHash" => _boundary_content_hash(prepared["data"]),
        "series" => series_info,
    )

    return metadata, prepared["data"], prepared["warnings"]
end

# ───── 辅助函数 ─────

"""C-402：对预处理后的边界实际内容计算稳定哈希（可复现性的数据版本指纹）。"""
function _boundary_content_hash(processed_data::Dict{String,Vector{Float64}})
    parts = String[]
    for bid in sort(collect(keys(processed_data)))
        digest = bytes2hex(SHA.sha256(reinterpret(UInt8, processed_data[bid])))
        push!(parts, "$(bid):$(digest)")
    end
    return bytes2hex(SHA.sha256(Vector{UInt8}(codeunits(join(parts, ";")))))
end

function _normalize_scenario_matrix!(
    matrix::Matrix{Float64},
    feature_ids::Vector{String},
    points_per_day::Int,
    normalize::String,
    warnings::Vector{String},
)
    parameters = Dict{String,Any}()
    for (feature_index, feature_id) in enumerate(feature_ids)
        row_range = ((feature_index-1)*points_per_day+1):(feature_index*points_per_day)
        values = vec(matrix[row_range, :])

        if normalize == "zscore"
            center = mean(values)
            scale = std(values; corrected=false)
            if scale <= eps(Float64)
                scale = 1.0
                push!(warnings, "$(feature_id) 为零方差序列，zscore 标准差按 1 处理")
            end
            matrix[row_range, :] .= (matrix[row_range, :] .- center) ./ scale
            parameters[feature_id] = Dict("method" => normalize, "mean" => center, "std" => scale)
        elseif normalize == "minmax"
            minimum = Base.minimum(values)
            maximum = Base.maximum(values)
            scale = maximum - minimum
            if scale <= eps(Float64)
                scale = 1.0
                push!(warnings, "$(feature_id) 为零方差序列，minmax 极差按 1 处理")
            end
            matrix[row_range, :] .= (matrix[row_range, :] .- minimum) ./ scale
            parameters[feature_id] = Dict("method" => normalize, "min" => minimum, "max" => maximum, "scale" => scale)
        elseif normalize == "none"
            parameters[feature_id] = Dict("method" => normalize)
        else
            error("normalize 只能是 zscore、minmax 或 none")
        end
    end
    return parameters
end

function _pairwise_squared_distances(matrix::Matrix{Float64})
    point_count = size(matrix, 2)
    dimension_count = size(matrix, 1)
    distances = zeros(Float64, point_count, point_count)
    @inbounds for left in 1:(point_count-1)
        for right in (left+1):point_count
            distance = 0.0
            for dimension in 1:dimension_count
                delta = matrix[dimension, left] - matrix[dimension, right]
                distance += delta * delta
            end
            distances[left, right] = distance
            distances[right, left] = distance
        end
    end
    return distances
end

# ───── 主函数 ─────

"""
    _planning_canvas_boundary_ids(project_json, canvas_id) -> Set{String}

从项目快照中提取目标画布所有节点 `data.business.boundaryIds` 的并集。
画布不存在时报错；节点未引用任何边界时返回空集合（由调用方决定报错或继续）。
"""
function _planning_canvas_boundary_ids(project_json::AbstractDict, canvas_id::String)
    workspace = get(project_json, "workspace", Dict{String,Any}())
    canvases = get(workspace, "canvases", [])
    canvas = nothing
    for item in canvases
        if string(get(item, "id", "")) == canvas_id
            canvas = item
            break
        end
    end
    canvas === nothing && error("画布 $(canvas_id) 不存在于项目快照中")
    ids = Set{String}()
    for node in get(canvas, "nodes", [])
        data = get(node, "data", Dict{String,Any}())
        business = get(data, "business", Dict{String,Any}())
        for bid in get(business, "boundaryIds", [])
            push!(ids, string(bid))
        end
    end
    return ids
end

"""
    reduce_boundary_scenarios(config, canvas_id, project_json) -> Dict

从 boundary.db 读取边界数据，预处理后执行聚类，返回典型场景。
聚类输入严格限制在目标画布节点引用的边界集合内（C-101/BUG-003），
同项目其他画布引用的边界不会进入聚类特征或跟随边界。

config 字段：
- projectId: 项目ID（必填）
- featureIds: 聚类特征边界ID数组（可选，为空时使用目标画布引用的全部边界；
  显式给出的边界必须被目标画布组件引用，否则报错）
- clusterCount: 场景数（必填，但会被限制为可用天数）
- algorithm: "kmeans" 或 "kmedoids"（默认 "kmeans"）
- normalize: "zscore"、"minmax" 或 "none"（默认 "zscore"）
- missingDayThreshold: 缺失天数阈值（0~1，默认 0.05；任一边界当天缺失比例超阈值即剔除该天）
- seed: 随机种子（默认 20260828）
- representative: 代表场景选择方式（默认 "nearest-observation"）
- preserveExtremes: 极端日保留开关（默认 true；峰荷日/低可再生日不进聚类池，
  各自成为权重 1 天的独立场景，避免被聚类平均掉）
"""
function reduce_boundary_scenarios(config::AbstractDict, canvas_id::AbstractString, project_json::AbstractDict)
    project_id = string(get(config, "projectId", ""))
    raw_feature_ids = get(config, "featureIds", nothing)
    feature_ids = raw_feature_ids === nothing ? String[] : String.(collect(raw_feature_ids))
    cluster_count = Int(get(config, "clusterCount", 0))
    algorithm = string(get(config, "algorithm", "kmeans"))
    normalize = string(get(config, "normalize", "zscore"))
    missing_threshold = Float64(get(config, "missingDayThreshold", 0.05))
    seed = Int(get(config, "seed", 20260828))
    representative = string(get(config, "representative", "nearest-observation"))

    isempty(project_id) && error("缺少 projectId")
    isempty(canvas_id) && error("缺少 canvasId")
    algorithm in ("kmeans", "kmedoids") || error("algorithm 只能是 kmeans 或 kmedoids")
    0.0 <= missing_threshold <= 1.0 || error("missingDayThreshold 必须在 0 到 1 之间")
    representative == "nearest-observation" || error("MVP 仅支持 nearest-observation 代表场景")
    cluster_count >= 2 || error("聚类场景数至少为 2")

    # 1. 合法边界全集 = 目标画布节点 business.boundaryIds 的并集 ∩ 项目已配置边界（C-101/BUG-003）
    canvas_boundary_ids = _planning_canvas_boundary_ids(project_json, String(canvas_id))
    isempty(canvas_boundary_ids) &&
        error("画布 $(canvas_id) 的组件未引用任何边界，无法生成典型场景")
    # 显式选择的聚类特征必须被目标画布组件引用，否则拒绝，防止跨画布串扰
    for fid in feature_ids
        fid in canvas_boundary_ids ||
            error("边界 $(fid) 未被画布 $(canvas_id) 的组件引用，已拒绝")
    end
    project_boundary_ids = get_all_boundary_ids(project_id)
    isempty(project_boundary_ids) && error("项目 $(project_id) 没有配置任何边界")
    all_boundary_ids = filter(bid -> bid in canvas_boundary_ids, project_boundary_ids)
    isempty(all_boundary_ids) &&
        error("画布 $(canvas_id) 引用的边界均不在项目边界库中，无法生成典型场景")

    # 2. 读取并预处理边界数据
    metadata, processed_data, preprocess_warnings = load_ts_boundary_features(
        project_id, feature_ids, all_boundary_ids
    )

    warnings = String[]
    append!(warnings, preprocess_warnings)
    timezone = TimeZone(String(metadata["timezone"]))

    # 确定实际使用的边界ID（特征边界）
    # 排序保证同集合不同传入顺序 → 相同矩阵列序 → 相同 scenarioSetHash
    actual_feature_ids = isempty(feature_ids) ? all_boundary_ids : sort(unique(feature_ids))
    # 跟随边界：画布内边界中不在 feature_ids 中的
    follow_ids = setdiff(all_boundary_ids, actual_feature_ids)

    # 3. 按24h切分为天
    points_per_day = 24  # 1h分辨率
    first_data = first(values(processed_data))
    day_count = length(first_data) ÷ points_per_day

    day_data = Dict{String,Dict{String,Vector{Float64}}}()
    for day_index in 1:day_count
        day_label = "day-$(day_index)"
        day_slices = Dict{String,Vector{Float64}}()
        for bid in keys(processed_data)
            start_idx = (day_index - 1) * points_per_day + 1
            end_idx = day_index * points_per_day
            day_slices[bid] = processed_data[bid][start_idx:end_idx]
        end
        day_data[day_label] = day_slices
    end

    # 4. C-402 数据质量检查
    all_day_keys = sort(collect(keys(day_data)); by=key -> parse(Int, String(key)[5:end]))

    # 4a. 缺失日剔除：任一边界当天缺失比例 > missingDayThreshold 即剔除
    excluded_days = String[]
    excluded_reasons = Dict{String,String}()
    for day_key in all_day_keys
        worst_ratio = 0.0
        worst_bid = ""
        for bid in all_boundary_ids
            values = day_data[day_key][bid]
            ratio = count(isnan, values) / max(length(values), 1)
            if ratio > worst_ratio
                worst_ratio = ratio
                worst_bid = bid
            end
        end
        if worst_ratio > missing_threshold
            push!(excluded_days, day_key)
            excluded_reasons[day_key] = "$(worst_bid) 缺失 $(round(worst_ratio * 100; digits=1))%"
        end
    end
    !isempty(excluded_days) &&
        push!(warnings, "按缺失阈值 $(missing_threshold) 剔除 $(length(excluded_days)) 天: $(join(excluded_days, ", "))")
    valid_days = setdiff(all_day_keys, excluded_days)
    isempty(valid_days) && error("缺失日剔除后没有可用天数，请提高 missingDayThreshold 或检查边界数据")

    # 4b. 剩余缺失值按该边界整体均值填充（阈值允许的部分缺失日）
    nan_filled_points = 0
    for bid in all_boundary_ids
        finite_values = Float64[]
        for day_key in valid_days
            append!(finite_values, filter(!isnan, day_data[day_key][bid]))
        end
        isempty(finite_values) && error("边界 $(bid) 有效天数内全部缺失，无法聚类")
        fill_value = mean(finite_values)
        for day_key in valid_days
            values = day_data[day_key][bid]
            for index in eachindex(values)
                if isnan(values[index])
                    values[index] = fill_value
                    nan_filled_points += 1
                end
            end
        end
    end
    nan_filled_points > 0 &&
        push!(warnings, "缺失值填充 $(nan_filled_points) 个点（按各边界整体均值），缺失日阈值 $(missing_threshold)")

    # 4c. 重复日检测：完全相同的多边界日曲线仅告警，不排除（可能为真实重复天气）
    seen_day_hashes = Set{String}()
    duplicate_day_count = 0
    for day_key in valid_days
        buffer = IOBuffer()
        for bid in all_boundary_ids
            write(buffer, reinterpret(UInt8, day_data[day_key][bid]))
        end
        digest = bytes2hex(SHA.sha256(take!(buffer)))
        digest in seen_day_hashes ? (duplicate_day_count += 1) : push!(seen_day_hashes, digest)
    end
    duplicate_day_count > 0 &&
        push!(warnings, "发现 $(duplicate_day_count) 个完全重复的边界日（保留参与聚类，请确认数据无意外复制）")

    # 4d. 异常日检测：特征日总量偏离 |z|>6 仅告警保留
    anomaly_day_count = 0
    for fid in all_boundary_ids
        daily_energy = [sum(day_data[day_key][fid]) for day_key in valid_days]
        energy_mean = mean(daily_energy)
        energy_std = std(daily_energy; corrected=false)
        energy_std <= eps(Float64) && continue
        for (day_key, energy) in zip(valid_days, daily_energy)
            z_score = abs(energy - energy_mean) / energy_std
            if z_score > 6.0
                anomaly_day_count += 1
                push!(warnings, "异常日 $(day_key): $(fid) 日总量偏离均值 $(round(z_score; digits=1))σ（保留参与聚类）")
            end
        end
    end

    # 5. C-402 极端日保留：峰荷日 / 低可再生日直接成场景，不进聚类池
    preserve_extremes = Bool(get(config, "preserveExtremes", true))
    series_meanings = Dict{String,String}()
    for info in metadata["series"]
        series_meanings[string(info["boundaryId"])] = lowercase(string(get(info, "meaning", "")))
    end
    load_features = [fid for fid in actual_feature_ids
                     if occursin(r"load|负荷", get(series_meanings, fid, ""))]
    renew_features = [fid for fid in actual_feature_ids
                      if occursin(r"wind|solar|irr|风|光|辐照", get(series_meanings, fid, ""))]
    preserved_days = String[]
    if preserve_extremes
        if !isempty(load_features)
            daily_load = [sum(sum(day_data[day_key][fid]) for fid in load_features)
                          for day_key in valid_days]
            push!(preserved_days, valid_days[argmax(daily_load)])
        else
            push!(warnings, "未识别到负荷类特征边界（meaning 含 load/负荷），跳过峰荷日保留")
        end
        if !isempty(renew_features)
            daily_renew = [sum(sum(day_data[day_key][fid]) for fid in renew_features)
                           for day_key in valid_days]
            push!(preserved_days, valid_days[argmin(daily_renew)])
        else
            push!(warnings, "未识别到可再生类特征边界（meaning 含 wind/solar/irr/风/光/辐照），跳过低可再生日保留")
        end
        unique!(preserved_days)
    end
    cluster_pool = setdiff(valid_days, preserved_days)

    # 6. 聚类场景数与池大小
    if length(cluster_pool) < cluster_count
        push!(warnings, "缺失剔除与极端日保留后剩余 $(length(cluster_pool)) 天，不足 $(cluster_count) 个聚类场景，将限制为 $(length(cluster_pool))")
        cluster_count = length(cluster_pool)
    end

    # 7. 构建聚类矩阵（仅使用特征边界，仅聚类池天数）
    raw_matrix = Matrix{Float64}(undef, points_per_day * length(actual_feature_ids), length(cluster_pool))
    for (day_index, day_key) in enumerate(cluster_pool)
        for (feature_index, fid) in enumerate(actual_feature_ids)
            row_range = ((feature_index-1)*points_per_day+1):(feature_index*points_per_day)
            raw_matrix[row_range, day_index] = day_data[day_key][fid]
        end
    end

    # 8. 归一化
    normalized_matrix = copy(raw_matrix)
    normalization = isempty(cluster_pool) ? Dict{String,Any}() : _normalize_scenario_matrix!(
        normalized_matrix, actual_feature_ids, points_per_day, normalize, warnings
    )
    # 9. 聚类
    result = if isempty(cluster_pool)
        (assignments=Int[], costs=Float64[], totalcost=0.0, iterations=0, converged=true)
    elseif algorithm == "kmeans"
        kmeans(
            normalized_matrix,
            cluster_count;
            init=:kmpp,
            maxiter=300,
            tol=1.0e-8,
            display=:none,
            rng=MersenneTwister(seed),
        )
    else
        distance_matrix = _pairwise_squared_distances(normalized_matrix)
        initial_medoids = initseeds_by_costs(
            :kmpp,
            distance_matrix,
            cluster_count;
            rng=MersenneTwister(seed),
        )
        kmedoids(
            distance_matrix,
            cluster_count;
            init=initial_medoids,
            maxiter=300,
            tol=1.0e-8,
            display=:none,
        )
    end
    algorithm_label = algorithm == "kmeans" ? "K-means" : "K-medoids"
    result.converged || push!(warnings, "$(algorithm_label) 达到最大迭代次数但未声明收敛")

    # 10. 构建场景记录：聚类簇 + 保留极端日
    timestamps_1h = generate_timestamps("0:00", "1h", "$(points_per_day)h")

    scenario_records = Dict{String,Any}[]
    for cluster in 1:cluster_count
        member_indices = findall(==(cluster), result.assignments)
        isempty(member_indices) && error("$(algorithm_label) 产生空簇: $(cluster)")
        representative_index = member_indices[argmin(result.costs[member_indices])]
        representative_day = cluster_pool[representative_index]
        weight_days = length(member_indices)

        # 提取所有边界的数据（特征+跟随）
        all_series = Dict{String,Vector{Float64}}()
        for bid in all_boundary_ids
            all_series[bid] = day_data[representative_day][bid]
        end

        push!(scenario_records, Dict{String,Any}(
            "representativeDate" => representative_day,
            "weightDays" => weight_days,
            "probability" => weight_days / length(valid_days),
            "memberDates" => cluster_pool[member_indices],
            "distanceToCenter" => result.costs[representative_index],
            "series" => all_series,
            "preserved" => false,
        ))
    end
    # 保留极端日各自成场景（权重 1 天），不被聚类平均掉
    for day_key in preserved_days
        all_series = Dict{String,Vector{Float64}}()
        for bid in all_boundary_ids
            all_series[bid] = day_data[day_key][bid]
        end
        push!(scenario_records, Dict{String,Any}(
            "representativeDate" => day_key,
            "weightDays" => 1,
            "probability" => 1 / length(valid_days),
            "memberDates" => [day_key],
            "distanceToCenter" => 0.0,
            "series" => all_series,
            "preserved" => true,
        ))
    end
    sort!(scenario_records; by=item -> item["representativeDate"])
    for (index, item) in enumerate(scenario_records)
        item["scenarioId"] = "scenario-$(index)"
    end

    # 11. 质量统计
    weighted_mean_error = Dict{String,Any}()
    for fid in actual_feature_ids
        original_mean = mean(vcat([day_data[dk][fid] for dk in valid_days]...))
        representative_mean = sum(
            mean(item["series"][fid]) * item["weightDays"] for item in scenario_records
        ) / length(valid_days)
        denominator = max(abs(original_mean), eps(Float64))
        weighted_mean_error[fid] = Dict(
            "originalMean" => original_mean,
            "representativeMean" => representative_mean,
            "relativeError" => (representative_mean - original_mean) / denominator,
        )
    end

    scenario_hash_payload = Dict(
        "featureIds" => sort(collect(actual_feature_ids)),
        "clusterCount" => cluster_count,
        "algorithm" => algorithm,
        "normalize" => normalize,
        "seed" => seed,
        "preserveExtremes" => preserve_extremes,
        "missingDayThreshold" => missing_threshold,
        "scenarios" => scenario_records,
    )
    scenario_set_hash = bytes2hex(SHA.sha256(Vector{UInt8}(codeunits(JSON3.write(scenario_hash_payload)))))

    config_echo = Dict(
        "canvasId" => string(canvas_id),
        "featureIds" => actual_feature_ids,
        "followIds" => follow_ids,
        "allBoundaryIds" => all_boundary_ids,
        "resolutionMinutes" => 60,
        "clusterCount" => cluster_count,
        "algorithm" => algorithm,
        "normalize" => normalize,
        "missingDayThreshold" => missing_threshold,
        "seed" => seed,
        "representative" => representative,
        "preserveExtremes" => preserve_extremes,
    )

    result_dict = Dict{String,Any}(
        "scenarioSetHash" => scenario_set_hash,
        "dataset" => metadata,
        "config" => config_echo,
        "scenarios" => scenario_records,
        "quality" => Dict(
            "validDayCount" => length(valid_days),
            "excludedDayCount" => length(excluded_days),
            "excludedDays" => excluded_reasons,
            "duplicateDayCount" => duplicate_day_count,
            "anomalyDayCount" => anomaly_day_count,
            "nanFilledPoints" => nan_filled_points,
            "preservedDays" => preserved_days,
            "sse" => result.totalcost,
            "iterations" => result.iterations,
            "converged" => result.converged,
            "normalization" => normalization,
            "weightedMeanError" => weighted_mean_error,
            "warnings" => warnings,
        ),
        "manifest" => Dict{String,Any}(
            "createdAt" => string(Dates.now()),
            "projectId" => project_id,
            "projectUpdatedAt" => string(get(project_json, "updateTime", "")),
            "canvasId" => string(canvas_id),
            "scenarioSetHash" => scenario_set_hash,
            "boundaryContentHash" => metadata["contentHash"],
            "config" => config_echo,
        ),
        "timestamps" => timestamps_1h,
    )
    return result_dict
end
