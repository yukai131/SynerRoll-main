/**
 * 显示抽稀：把大时间窗的时间序列压到 maxPoints 量级。
 * - 窗口 ≤ 48h 或点数不多时返回原数组（全精度）
 * - 大窗用 min-max 分桶，保留首/末/最小/最大点，避免削峰
 * - 仅用于渲染；导出与业务统计仍用原始数据
 */
export function downsampleTimeSeries(
  data: Array<[number, number]>,
  startMin: number,
  endMin: number,
  maxPoints = 1200
): Array<[number, number]> {
  const span = Math.max(1, endMin - startMin)
  if (span <= 48 * 60 || data.length <= maxPoints) return data

  const bucketCount = Math.max(2, Math.floor(maxPoints / 4))
  const bucketSize = span / bucketCount
  const out: Array<[number, number]> = []

  let i = 0
  while (i < data.length && out.length < maxPoints) {
    let j = i
    let minP = data[i]
    let maxP = data[i]
    const bucketEnd = data[i][0] + bucketSize

    while (j < data.length && data[j][0] < bucketEnd) {
      const p = data[j]
      if (p[1] < minP[1]) minP = p
      if (p[1] > maxP[1]) maxP = p
      j++
    }

    const last = data[j - 1]
    for (const p of [data[i], minP, maxP, last]) {
      if (!out.length || out[out.length - 1][0] !== p[0]) out.push(p)
    }
    i = j
  }

  return out
}
