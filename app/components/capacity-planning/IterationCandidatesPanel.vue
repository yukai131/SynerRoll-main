<script setup lang="ts">
import * as echarts from 'echarts'
import CandidateCashflowChart from './CandidateCashflowChart.vue'
import type {
  CapacityComparisonCandidate,
  CapacityComparisonMetricKey,
  CapacityPlanningComparison
} from '~~/types/capacity-planning'

const props = defineProps<{
  comparison: CapacityPlanningComparison
}>()

/** 指标量纲 → 多 Y 轴分组（同单位一组轴） */
const METRIC_DIMENSION: Record<string, string> = {
  fitness: 'money',
  objectiveFitness: 'money',
  constraintPenalty: 'money',
  operatingCostYuan: 'money',
  investmentYuan: 'money',
  npvYuan: 'money',
  irr: 'percent',
  renewableConsumptionRate: 'percent',
  greenPowerShare: 'percent',
  purchasedPowerShare: 'percent',
  stability: 'percent',
  lcoe: 'intensity',
  paybackYears: 'year',
  discountedPaybackYears: 'year'
}
const DIMENSION_LABEL: Record<string, string> = {
  money: '金额（万元）',
  percent: '（%）',
  intensity: '价格（元/kWh）',
  year: '时间（年）'
}

const feasibleCandidates = computed(() =>
  props.comparison.candidates
    .filter(item => item.feasible && item.rank !== null)
    .slice()
    .sort((a, b) => (a.rank ?? 0) - (b.rank ?? 0))
)
const top5Ids = computed(() => feasibleCandidates.value.slice(0, 5).map(item => item.evaluationId))

/** 图表横轴：按评价次序的可行解（迭代过程） */
const timelineCandidates = computed(() =>
  props.comparison.candidates
    .filter(item => item.feasible)
    .slice()
    .sort((a, b) => a.ordinal - b.ordinal)
)

const defaultMetrics = computed<CapacityComparisonMetricKey[]>(() => {
  const keys = props.comparison.metricSources.map(item => item.key)
  const preferred: CapacityComparisonMetricKey[] = ['fitness', 'operatingCostYuan', 'renewableConsumptionRate', 'lcoe']
  return preferred.filter(key => keys.includes(key))
})

/** 只把至少有一个真实数值的指标交给图例，避免出现无法绘制的“假选项”。 */
const availableMetricKeys = computed<CapacityComparisonMetricKey[]>(() =>
  props.comparison.metricSources
    .map(item => item.key)
    .filter(key => timelineCandidates.value.some((candidate) => {
      const value = candidate.metrics.values[key]
      return value !== null && value !== undefined && Number.isFinite(Number(value))
    }))
)

/** 表格中展示的方案：默认 Top5，可点图加入；固定项置顶 */
const tableIds = ref<number[]>([])
const pinnedIds = ref<Set<number>>(new Set())
const expandedId = ref<number | null>(null)

const rebuildDefaultTable = () => {
  tableIds.value = [...top5Ids.value]
  pinnedIds.value = new Set()
  expandedId.value = top5Ids.value[0] ?? null
}
watch(
  () => props.comparison.planningId,
  () => rebuildDefaultTable(),
  { immediate: true }
)

const orderedTableIds = computed(() => {
  const pinned = tableIds.value.filter(id => pinnedIds.value.has(id))
  const rest = tableIds.value.filter(id => !pinnedIds.value.has(id))
  return [...pinned, ...rest]
})

const candidateById = computed(() => {
  const map = new Map<number, CapacityComparisonCandidate>()
  for (const item of props.comparison.candidates) map.set(item.evaluationId, item)
  return map
})

const tableCandidates = computed(() =>
  orderedTableIds.value
    .map(id => candidateById.value.get(id))
    .filter((item): item is CapacityComparisonCandidate => Boolean(item))
)

const ensureInTable = (evaluationId: number) => {
  if (!tableIds.value.includes(evaluationId)) {
    tableIds.value = [...tableIds.value, evaluationId]
  }
}

const removeFromTable = (evaluationId: number) => {
  tableIds.value = tableIds.value.filter(id => id !== evaluationId)
  if (pinnedIds.value.has(evaluationId)) {
    const next = new Set(pinnedIds.value)
    next.delete(evaluationId)
    pinnedIds.value = next
  }
  if (expandedId.value === evaluationId) expandedId.value = tableIds.value[0] ?? null
}

const togglePin = (evaluationId: number) => {
  const next = new Set(pinnedIds.value)
  if (next.has(evaluationId)) next.delete(evaluationId)
  else next.add(evaluationId)
  pinnedIds.value = next
}

const toggleExpand = (evaluationId: number) => {
  expandedId.value = expandedId.value === evaluationId ? null : evaluationId
}

const selectCandidate = async (evaluationId: number) => {
  ensureInTable(evaluationId)
  expandedId.value = evaluationId
  await nextTick()
  const el = document.getElementById(`cap-candidate-row-${evaluationId}`)
  el?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
}

// ── 图表 ──
const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null

const metricByKey = computed(() => {
  const map = new Map<string, { label: string; direction: string; source: string }>()
  for (const item of props.comparison.metricSources) {
    map.set(item.key, { label: item.label, direction: item.direction, source: item.source })
  }
  return map
})

const formatMetric = (key: CapacityComparisonMetricKey, value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return '—'
  const n = Number(value)
  if (key === 'irr' || key === 'renewableConsumptionRate' || key === 'greenPowerShare' || key === 'purchasedPowerShare' || key === 'stability') {
    return `${n.toFixed(1)}%`
  }
  if (key === 'lcoe') return `${n.toFixed(3)}`
  if (key === 'paybackYears' || key === 'discountedPaybackYears') return `${n.toFixed(1)} 年`
  return new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 2 }).format(n)
}

const renderChart = () => {
  if (!chartRef.value) return
  if (!chart) chart = echarts.init(chartRef.value)
  const xs = timelineCandidates.value.map(item => item.ordinal)
  const available = availableMetricKeys.value
  const legendNames = available.map(key => metricByKey.value.get(key)?.label ?? key)
  const legendSplitIndex = Math.ceil(legendNames.length / 2)
  const legendRows = [
    legendNames.slice(0, legendSplitIndex),
    legendNames.slice(legendSplitIndex)
  ].filter(row => row.length > 0)
  const legendSelected = Object.fromEntries(available.map(key => [
    metricByKey.value.get(key)?.label ?? key,
    defaultMetrics.value.includes(key)
  ]))
  const dimensions = [...new Set(available.map(key => METRIC_DIMENSION[key] ?? 'other'))]
  const axisIndexByDim = new Map(dimensions.map((dim, index) => [dim, index]))

  const series: any[] = available.map((key) => {
    const dim = METRIC_DIMENSION[key] ?? 'other'
    return {
      name: metricByKey.value.get(key)?.label ?? key,
      type: 'line',
      showSymbol: true,
      symbolSize: 6,
      yAxisIndex: axisIndexByDim.get(dim) ?? 0,
      data: timelineCandidates.value.map(item => item.metrics.values[key] ?? null),
      emphasis: { focus: 'series' }
    }
  })

  // Top5 背景带：按 rank 高亮对应评价次序点
  const top5 = feasibleCandidates.value.slice(0, 5)
  const markData = top5.map(item => ({
    xAxis: item.ordinal,
    itemStyle: item.rank === 1
      ? { color: 'rgba(22, 93, 255, 0.16)' }
      : { color: 'rgba(22, 93, 255, 0.08)' },
    label: {
      show: true,
      formatter: `Top${item.rank}`,
      position: 'top',
      color: '#165DFF',
      fontSize: 10
    }
  }))
  if (series[0]) {
    series[0].markArea = {
      silent: true,
      data: top5.map(item => [
        { xAxis: item.ordinal - 0.5, itemStyle: { color: item.rank === 1 ? 'rgba(22,93,255,0.14)' : 'rgba(22,93,255,0.07)' } },
        { xAxis: item.ordinal + 0.5 }
      ])
    }
    series[0].markPoint = {
      symbol: 'rect',
      symbolSize: [28, 16],
      data: markData.map(m => ({
        coord: [m.xAxis, timelineCandidates.value.find(c => c.ordinal === m.xAxis)?.metrics.values[available[0] ?? 'fitness'] ?? 0],
        label: m.label,
        itemStyle: m.itemStyle
      }))
    }
  }

  chart.setOption({
    color: ['#165DFF', '#12B76A', '#F79009', '#7A5AF8', '#0BA5EC', '#F04438', '#039855', '#DC6803'],
    tooltip: {
      trigger: 'axis',
      confine: true,
      formatter: (params: any) => {
        const ordinal = Number(params?.[0]?.axisValue)
        const candidate = timelineCandidates.value.find(item => item.ordinal === ordinal)
        const head = `评价 #${ordinal}　排名 ${candidate?.rank ?? '—'}${candidate?.isBest ? '　最优' : ''}`
        const lines = (params as any[]).map((p: any) => {
          const key = available.find(item => (metricByKey.value.get(item)?.label ?? item) === p.seriesName) ?? 'fitness'
          return `${p.marker} ${p.seriesName}: <b>${formatMetric(key, p.value)}</b>`
        })
        return [head, ...lines].join('<br/>')
      }
    },
    legend: legendRows.map((data, index) => ({
      type: 'scroll',
      data,
      top: 4 + index * 30,
      left: 64,
      right: 64,
      itemGap: 18,
      itemWidth: 20,
      itemHeight: 10,
      pageIconSize: 10,
      textStyle: { fontSize: 11, lineHeight: 16 },
      selected: legendSelected
    })),
    grid: { left: 56, right: 56, top: legendRows.length > 1 ? 78 : 48, bottom: 40, containLabel: true },
    xAxis: {
      type: 'category',
      name: '评价次数',
      nameLocation: 'middle',
      nameGap: 28,
      data: xs.map(String),
      axisLabel: { hideOverlap: true }
    },
    yAxis: dimensions.map((dim, index) => ({
      type: 'value',
      name: DIMENSION_LABEL[dim] ?? dim,
      nameLocation: 'end',
      nameGap: 12,
      position: index === 0 ? 'left' : 'right',
      offset: index <= 1 ? 0 : (index - 1) * 48,
      scale: true,
      axisLabel: { fontSize: 11 }
    })),
    series
  }, true)

  chart.off('click')
  chart.on('click', (params: any) => {
    if (params?.componentType !== 'series') return
    const ordinal = Number(params.name)
    const candidate = timelineCandidates.value.find(item => item.ordinal === ordinal)
    if (candidate) void selectCandidate(candidate.evaluationId)
  })
}

watch(
  [availableMetricKeys, () => props.comparison.planningId],
  async () => {
    await nextTick()
    renderChart()
  },
  { deep: true }
)

onMounted(async () => {
  await nextTick()
  renderChart()
  window.addEventListener('resize', handleResize)
})
onBeforeUnmount(() => {
  window.removeEventListener('resize', handleResize)
  chart?.dispose()
  chart = null
})
const handleResize = () => chart?.resize()

const formatContributionCost = (value: number) =>
  `${value < 0 ? '净收益 ' : '成本 '}${new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 1 }).format(Math.abs(value) / 10000)} 万元`
</script>

<template>
  <div class="space-y-4">
    <!-- 迭代过程回溯 -->
    <div class="overflow-hidden rounded-lg border border-app-border bg-white">
      <div class="flex items-center justify-between gap-3 border-b border-app-border px-5 py-3">
        <div>
          <h3 class="text-sm font-semibold text-app-text">迭代过程回溯</h3>
        </div>
        <span class="shrink-0 text-xs text-app-muted">{{ availableMetricKeys.length }} 个可用指标</span>
      </div>
      <div ref="chartRef" class="h-[430px] w-full px-2 py-2" />
    </div>

    <!-- 方案明细：默认 Top5 + 自选 -->
    <div class="overflow-hidden rounded-lg border border-app-border bg-white">
      <div class="flex items-center justify-between border-b border-app-border px-5 py-3">
        <div>
          <h3 class="text-sm font-semibold text-app-text">方案明细</h3>
        </div>
        <div class="flex items-center gap-2">
          <span class="rounded-full bg-primary-soft px-2.5 py-0.5 text-xs font-medium text-primary">表内 {{ tableCandidates.length }}</span>
        </div>
      </div>

      <div class="max-h-[520px] overflow-auto">
        <table class="w-full min-w-[1040px] table-fixed text-left text-sm">
          <colgroup>
            <col class="w-[8%]">
            <col class="w-[8%]">
            <col class="w-[14%]">
            <col class="w-[15%]">
            <col class="w-[18%]">
            <col class="w-[25%]">
            <col class="w-[12%]">
          </colgroup>
          <thead class="sticky top-0 z-10 bg-app-panel-soft text-xs text-app-muted">
            <tr>
              <th class="py-2.5 pl-5 pr-3 font-medium">排名</th>
              <th class="px-3 py-2.5 font-medium">评价 #</th>
              <th class="px-3 py-2.5 font-medium">适应度</th>
              <th class="px-3 py-2.5 font-medium">年运行成本</th>
              <th class="px-3 py-2.5 font-medium">NPV / IRR</th>
              <th class="px-3 py-2.5 font-medium">消纳 / 绿电 / 购电</th>
              <th class="px-3 py-2.5 font-medium">操作</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="candidate in tableCandidates" :key="candidate.evaluationId">
              <tr
                :id="`cap-candidate-row-${candidate.evaluationId}`"
                class="cursor-pointer border-t border-app-border"
                :class="[
                  candidate.isBest ? 'bg-blue-50/50' : '',
                  expandedId === candidate.evaluationId ? 'bg-app-panel-soft/40' : ''
                ]"
                @click="toggleExpand(candidate.evaluationId)"
              >
                <td class="py-2.5 pl-5 pr-3">
                  <span
                    class="inline-flex h-6 min-w-6 items-center justify-center rounded-full px-1.5 text-xs font-semibold"
                    :class="candidate.rank === 1 ? 'bg-primary text-white' : 'bg-app-panel-soft text-app-text'"
                  >{{ candidate.rank ?? '—' }}</span>
                  <span v-if="pinnedIds.has(candidate.evaluationId)" class="ml-1 rounded bg-amber-100 px-1 text-[10px] text-amber-700">固定</span>
                </td>
                <td class="px-3 py-2.5 text-app-muted">{{ candidate.ordinal }}</td>
                <td class="px-3 py-2.5 font-medium text-app-text">{{ formatMetric('fitness', candidate.metrics.values.fitness) }}</td>
                <td class="px-3 py-2.5 text-app-text">{{ formatMetric('operatingCostYuan', candidate.metrics.values.operatingCostYuan) }}</td>
                <td class="px-3 py-2.5 text-app-text">
                  {{ formatMetric('npvYuan', candidate.metrics.values.npvYuan) }}
                  <span class="text-app-muted">/</span>
                  {{ formatMetric('irr', candidate.metrics.values.irr) }}
                </td>
                <td class="px-3 py-2.5 text-app-text">
                  {{ formatMetric('renewableConsumptionRate', candidate.metrics.values.renewableConsumptionRate) }}
                  <span class="text-app-muted">/</span>
                  {{ formatMetric('greenPowerShare', candidate.metrics.values.greenPowerShare) }}
                  <span class="text-app-muted">/</span>
                  {{ formatMetric('purchasedPowerShare', candidate.metrics.values.purchasedPowerShare) }}
                </td>
                <td class="px-3 py-2.5">
                  <div class="flex items-center justify-end gap-1">
                    <button
                      type="button"
                      class="inline-flex h-7 w-7 items-center justify-center rounded-full text-app-muted transition-colors hover:bg-amber-50 hover:text-amber-700"
                      :class="pinnedIds.has(candidate.evaluationId) ? 'bg-amber-50 text-amber-700' : ''"
                      :title="pinnedIds.has(candidate.evaluationId) ? '取消固定' : '固定到表格顶部'"
                      :aria-label="pinnedIds.has(candidate.evaluationId) ? '取消固定' : '固定到表格顶部'"
                      @click.stop="togglePin(candidate.evaluationId)"
                    >
                      <svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                        <path d="M9 4h6l-1 5 3 3v2H7v-2l3-3-1-5Z" stroke-linecap="round" stroke-linejoin="round" />
                        <path d="M12 14v7" stroke-linecap="round" />
                      </svg>
                    </button>
                    <button
                      type="button"
                      class="inline-flex h-7 w-7 items-center justify-center rounded-full text-app-muted transition-colors hover:bg-red-50 hover:text-app-danger"
                      title="从表格中移除"
                      aria-label="从表格中移除"
                      @click.stop="removeFromTable(candidate.evaluationId)"
                    ><AppIcon name="delete" :size="16" /></button>
                    <button
                      type="button"
                      class="inline-flex h-7 w-7 items-center justify-center rounded-full text-primary transition-colors hover:bg-primary-soft"
                      :title="expandedId === candidate.evaluationId ? '收起方案明细' : '展开方案明细'"
                      :aria-label="expandedId === candidate.evaluationId ? '收起方案明细' : '展开方案明细'"
                      @click.stop="toggleExpand(candidate.evaluationId)"
                    >
                      <svg class="h-4 w-4 transition-transform" :class="expandedId === candidate.evaluationId ? 'rotate-180' : ''" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                        <path d="m6 9 6 6 6-6" stroke-linecap="round" stroke-linejoin="round" />
                      </svg>
                    </button>
                  </div>
                </td>
              </tr>
              <tr v-if="expandedId === candidate.evaluationId" class="border-t border-app-border bg-app-panel-soft/30">
                <td :colspan="7" class="px-5 py-4">
                  <div class="grid items-stretch gap-4 lg:grid-cols-3">
                    <div class="flex min-h-[250px] flex-col overflow-hidden rounded-md border border-app-border bg-white">
                      <h4 class="border-b border-app-border bg-app-panel-soft px-3 py-2.5 text-xs font-semibold text-app-text">容量配置方案</h4>
                      <table class="h-full w-full table-fixed text-left text-xs">
                        <thead class="bg-white text-app-muted">
                          <tr class="border-b border-app-border/70">
                            <th class="w-[44%] px-3 py-2 font-medium">设备名称</th>
                            <th class="w-[24%] px-2 py-2 text-right font-medium">原有容量</th>
                            <th class="w-[32%] px-3 py-2 text-right font-medium">当前容量</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr v-for="(item, componentId) in candidate.capacities" :key="componentId" class="border-b border-app-border/60">
                            <td class="px-3 py-2.5 text-app-muted">{{ comparison.variableLabels[componentId]?.componentName ?? componentId }}</td>
                            <td class="px-2 py-2.5 text-right">{{ comparison.variableLabels[componentId]?.currentValue ?? '—' }} {{ item.unit }}</td>
                            <td class="px-3 py-2.5 text-right font-medium" :class="item.value > (comparison.variableLabels[componentId]?.currentValue ?? 0) ? 'text-app-success' : item.value < (comparison.variableLabels[componentId]?.currentValue ?? 0) ? 'text-app-warning' : 'text-app-text'">
                              {{ item.value }} {{ item.unit }}
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                    <div class="min-h-[250px] rounded-md border border-app-border bg-white p-3">
                      <h4 class="mb-1 text-xs font-semibold text-app-text">典型场景成本贡献</h4>
                      <div v-if="candidate.metrics.scenarioContributions.length" class="space-y-2">
                        <div v-for="contribution in candidate.metrics.scenarioContributions" :key="contribution.scenarioId">
                          <div class="flex justify-between text-xs text-app-muted">
                            <span class="truncate pr-2" :title="contribution.scenarioId">{{ contribution.scenarioId }}</span>
                            <span class="shrink-0" :class="contribution.weightedCostYuan < 0 ? 'text-app-success' : 'text-app-text'">
                              {{ formatContributionCost(contribution.weightedCostYuan) }} , {{ contribution.share !== null ? (contribution.share * 100).toFixed(1) + '%' : '—' }}
                            </span>
                          </div>
                          <div class="mt-0.5 h-1.5 overflow-hidden rounded-full bg-app-border/50">
                            <div class="h-full rounded-full" :class="contribution.weightedCostYuan < 0 ? 'bg-app-success' : 'bg-primary'" :style="{ width: `${(contribution.share ?? 0) * 100}%` }" />
                          </div>
                        </div>
                      </div>
                      <p v-else class="text-xs text-app-muted">暂无场景贡献数据</p>
                    </div>
                    <div class="min-h-[250px] rounded-md border border-app-border bg-white p-3">
                      <h4 class="mb-1 text-xs font-semibold text-app-text">税后净现金流</h4>
                      <CandidateCashflowChart v-if="(candidate.metrics.detail.cashflowWan ?? []).length" :values="candidate.metrics.detail.cashflowWan ?? []" />
                      <p v-else class="text-xs text-app-muted">暂无现金流留痕</p>
                    </div>
                  </div>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
        <div v-if="!tableCandidates.length" class="px-5 py-8 text-center text-sm text-app-muted">
          表内暂无方案，可在上方迭代图中点击曲线点加入
        </div>
      </div>
    </div>
  </div>
</template>
