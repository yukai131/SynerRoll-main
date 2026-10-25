<script setup lang="ts">
import * as echarts from 'echarts'

const props = defineProps<{
  values: Array<number | null>
}>()

const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null

const renderChart = () => {
  if (!chartRef.value) return
  if (!chart) chart = echarts.init(chartRef.value)

  let runningTotal = 0
  const cashflow = props.values.map(value => value == null ? null : Number(value))
  const cumulative = cashflow.map((value) => {
    if (value == null || !Number.isFinite(value)) return null
    runningTotal += value
    return runningTotal
  })
  const years = cashflow.map((_, index) => index === 0 ? '建设年' : `第${index}年`)

  chart.setOption({
    animationDuration: 350,
    color: ['#10b981', '#165DFF'],
    tooltip: {
      trigger: 'axis',
      confine: true,
      valueFormatter: (value: unknown) => {
        const number = Number(value)
        return Number.isFinite(number)
          ? `${new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 2 }).format(number)} 万元`
          : '—'
      }
    },
    legend: {
      top: 0,
      right: 4,
      itemWidth: 12,
      itemHeight: 8,
      textStyle: { color: '#667085', fontSize: 10 }
    },
    grid: { left: 12, right: 12, top: 32, bottom: 12, containLabel: true },
    xAxis: {
      type: 'category',
      name: '年份',
      nameLocation: 'middle',
      nameGap: 26,
      data: years,
      axisLine: { lineStyle: { color: '#D0D5DD' } },
      axisTick: { show: false },
      axisLabel: { color: '#667085', fontSize: 10, interval: 'auto', hideOverlap: true }
    },
    yAxis: {
      type: 'value',
      name: '万元',
      nameTextStyle: { color: '#667085', fontSize: 10, align: 'right' },
      scale: true,
      axisLabel: { color: '#667085', fontSize: 10 },
      splitLine: { lineStyle: { color: '#EAECF0', type: 'dashed' } }
    },
    series: [
      {
        name: '当年净现金流',
        type: 'bar',
        barMaxWidth: 18,
        data: cashflow.map(value => ({
          value,
          itemStyle: {
            color: (value ?? 0) >= 0 ? '#10b981' : '#f59e0b',
            borderRadius: (value ?? 0) >= 0 ? [2, 2, 0, 0] : [0, 0, 2, 2]
          }
        })),
        markLine: {
          silent: true,
          symbol: 'none',
          label: { show: false },
          lineStyle: { color: '#98A2B3', width: 1 },
          data: [{ yAxis: 0 }]
        }
      },
      {
        name: '累计净现金流',
        type: 'line',
        data: cumulative,
        showSymbol: false,
        smooth: 0.2,
        lineStyle: { width: 2 }
      }
    ]
  }, true)
}

const handleResize = () => chart?.resize()

watch(() => props.values, async () => {
  await nextTick()
  renderChart()
}, { deep: true })

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
</script>

<template>
  <div ref="chartRef" class="h-[220px] w-full" role="img" aria-label="税后净现金流与累计净现金流图" />
</template>
