<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch, nextTick } from 'vue'
import type { FittingModel, FittingType, WindFittingParams } from '~~/types/fitting'
import { isWindFittingParams } from '~~/types/fitting'
import { useFittingApi } from '~~/composables/api/useFittingApi'
import { useToastCenter } from '~~/state/ui'
import PropertyText from '../PropertyText.vue'
import PropertyMultiSelect from '../PropertyMultiSelect.vue'
import AppButton from '../AppButton.vue'
import * as echarts from 'echarts'

const props = defineProps<{
  fitting: FittingModel
  availableNodes: Array<{ id: string; label: string }>
}>()

const emit = defineEmits<{
  (e: 'update:fitting', value: FittingModel): void
  (e: 'submit'): void
}>()

const { fit } = useFittingApi()
const { push } = useToastCenter()

const form = reactive({
  filePath: '',
  powerColumn: '',
  windColumn: '',
  irradianceColumn: '',
  temperatureColumn: '',
  relatedComponents: [] as string[]
})

const isWind = computed(() => props.fitting.type === 'wind')

const canFit = computed(() => {
  if (!form.filePath.trim() || !form.powerColumn.trim()) return false
  if (isWind.value) return !!form.windColumn.trim()
  return !!form.irradianceColumn.trim() && !!form.temperatureColumn.trim()
})

const chartRef = ref<HTMLDivElement | null>(null)
let chartInstance: echarts.ECharts | null = null

const loadFromModel = () => {
  const m = props.fitting
  form.filePath = m.filePath
  form.powerColumn = m.powerColumn
  form.windColumn = m.type === 'wind' ? (m.inputColumns[0] ?? '') : ''
  form.irradianceColumn = m.type === 'pv' ? (m.inputColumns[0] ?? '') : ''
  form.temperatureColumn = m.type === 'pv' ? (m.inputColumns[1] ?? '') : ''
  form.relatedComponents = [...(m.relatedComponents ?? [])]
}

watch(() => props.fitting.id, loadFromModel, { immediate: true })

const patchModel = (partial: Partial<FittingModel>) => {
  emit('update:fitting', { ...props.fitting, ...partial })
}

const syncFormToModel = () => {
  const inputColumns = isWind.value
    ? [form.windColumn.trim()]
    : [form.irradianceColumn.trim(), form.temperatureColumn.trim()]
  patchModel({
    filePath: form.filePath.trim(),
    powerColumn: form.powerColumn.trim(),
    inputColumns,
    relatedComponents: [...form.relatedComponents]
  })
}

watch(() => form.filePath, () => syncFormToModel())
watch(() => form.powerColumn, () => syncFormToModel())
watch(() => form.windColumn, () => { if (isWind.value) syncFormToModel() })
watch(() => form.irradianceColumn, () => { if (!isWind.value) syncFormToModel() })
watch(() => form.temperatureColumn, () => { if (!isWind.value) syncFormToModel() })

const handleRelatedChange = (value: string[]) => {
  form.relatedComponents = value
  patchModel({ relatedComponents: [...value] })
}

const fittingLoading = ref(false)

const runFit = async () => {
  if (!canFit.value || fittingLoading.value) return
  fittingLoading.value = true
  try {
    syncFormToModel()
    const result = await fit({
      type: props.fitting.type,
      filePath: form.filePath.trim(),
      powerColumn: form.powerColumn.trim(),
      inputColumns: isWind.value
        ? [form.windColumn.trim()]
        : [form.irradianceColumn.trim(), form.temperatureColumn.trim()]
    })
    patchModel({
      params: result.params,
      formulaText: result.formulaText,
      scatter: result.scatter,
      curve: result.curve,
      stats: result.stats
    })
    push({
      tone: 'success',
      title: '拟合完成',
      description: result.stats?.r2 !== undefined ? `R² = ${result.stats.r2.toFixed(4)}` : undefined
    })
    nextTick(() => updateChart())
  }
  catch (err) {
    push({ tone: 'danger', title: '拟合失败', description: String(err) })
  }
  finally {
    fittingLoading.value = false
  }
}

const submitFitting = () => {
  syncFormToModel()
  emit('submit')
}

const formulaText = computed(() => props.fitting.formulaText ?? '')
const stats = computed(() => props.fitting.stats)
const windParams = computed(() =>
  isWindFittingParams(props.fitting.params) ? props.fitting.params as WindFittingParams : null
)

const statsLine = computed(() => {
  if (!stats.value) return ''
  const bits = [`样本数 ${stats.value.n}`]
  if (stats.value.r2 !== undefined) bits.push(`R² ${stats.value.r2.toFixed(4)}`)
  if (stats.value.rmse !== undefined) bits.push(`RMSE ${stats.value.rmse.toFixed(2)}`)
  if (windParams.value) {
    bits.push(`切入 ${windParams.value.v_in.toFixed(2)} m/s`)
    bits.push(`额定 ${windParams.value.v_r.toFixed(2)} m/s`)
    bits.push(`切出 ${windParams.value.v_out.toFixed(2)} m/s`)
  }
  return bits.join(' ; ')
})

const updateChart = () => {
  if (!chartRef.value) return
  if (!chartInstance) {
    chartInstance = echarts.init(chartRef.value)
  }
  const scatter = props.fitting.scatter ?? []
  const curve = props.fitting.curve ?? []
  const wind = windParams.value

  // 标注线挂在拟合曲线上，避免单独图例项颜色错乱
  const markLineData: echarts.MarkLineComponentOption['data'] = []
  if (wind) {
    markLineData.push(
      {
        xAxis: wind.v_in,
        label: { formatter: `切入 ${wind.v_in.toFixed(2)}`, position: 'insideEndTop', fontSize: 11 },
        lineStyle: { type: 'dashed', width: 1 }
      },
      {
        xAxis: wind.v_out,
        label: { formatter: `切出 ${wind.v_out.toFixed(2)}`, position: 'insideEndTop', fontSize: 11 },
        lineStyle: { type: 'dashed', width: 1 }
      }
    )
    if (wind.v_r > wind.v_in + 1e-6 && wind.v_r < wind.v_out - 1e-6) {
      markLineData.push({
        xAxis: wind.v_r,
        label: { formatter: `额定 ${wind.v_r.toFixed(2)}`, position: 'insideEndBottom', fontSize: 11 },
        lineStyle: { type: 'dotted', width: 1 }
      })
    }
  }

  chartInstance.setOption({
    animation: false,
    title: {
      text: isWind.value ? '风速-功率拟合' : '辐照度-功率拟合',
      textStyle: { fontSize: 13, fontWeight: 'normal', color: '#1D2939' },
      left: 'center',
      top: 5
    },
    tooltip: { trigger: 'axis' },
    legend: {
      top: 5,
      right: 8,
      itemWidth: 14,
      itemHeight: 8,
      textStyle: { fontSize: 12, color: '#1D2939' },
      data: ['实测数据', '拟合曲线']
    },
    grid: {
      left: '3%',
      right: '3%',
      top: 35,
      bottom: '8%',
      containLabel: true
    },
    xAxis: {
      type: 'value',
      name: isWind.value ? '风速 (m/s)' : '辐照度 (W/m²)',
      nameLocation: 'middle',
      nameGap: 30,
      nameTextStyle: { color: '#1D2939', fontSize: 12 },
      scale: true,
      axisLabel: { color: '#1D2939', fontSize: 12 },
      axisLine: { lineStyle: { color: '#C9CDD4' } },
      axisTick: { lineStyle: { color: '#C9CDD4' } },
      splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } }
    },
    yAxis: {
      type: 'value',
      name: '功率 (kW)',
      nameLocation: 'middle',
      nameGap: 48,
      nameTextStyle: { color: '#1D2939', fontSize: 12 },
      scale: true,
      axisLabel: { color: '#1D2939', fontSize: 12 },
      axisLine: { show: true, lineStyle: { color: '#C9CDD4' } },
      axisTick: { show: true, lineStyle: { color: '#C9CDD4' } },
      splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } }
    },
    series: [
      {
        type: 'scatter',
        name: '实测数据',
        data: scatter.map(p => [p.x, p.y]),
        symbolSize: 5,
        itemStyle: { color: '#165DFF', opacity: 0.4 },
        animation: false
      },
      {
        type: 'line',
        name: '拟合曲线',
        data: curve.map(p => [p.x, p.y]),
        showSymbol: false,
        smooth: false,
        lineStyle: { color: '#165DFF', width: 2 },
        itemStyle: { color: '#165DFF' },
        animation: false,
        ...(markLineData.length
          ? {
              markLine: {
                symbol: 'none',
                silent: true,
                lineStyle: { color: '#165DFF', type: 'dashed', width: 1 },
                label: { color: '#1D2939', fontSize: 11 },
                data: markLineData
              }
            }
          : {})
      }
    ]
  }, true)
}

const resizeChart = () => chartInstance?.resize()

onMounted(() => {
  nextTick(() => {
    updateChart()
    window.addEventListener('resize', resizeChart)
  })
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', resizeChart)
  chartInstance?.dispose()
  chartInstance = null
})

watch(() => [props.fitting.scatter, props.fitting.curve, props.fitting.params], () => {
  nextTick(() => updateChart())
})
</script>

<template>
  <div class="flex-1 flex flex-col gap-2 overflow-hidden min-h-0">
    <div class="panel-card px-8 py-4 flex flex-col flex-1 min-h-0 space-y-3 overflow-hidden">
      <!-- 第一行：输入路径 + 列名 + 操作 -->
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-2 flex-[3] min-w-0">
          <label class="w-16 text-sm text-app shrink-0">输入路径</label>
          <PropertyText v-model="form.filePath" placeholder="C:\Users\...\data.csv" />
        </div>
        <div class="flex items-center gap-2 w-72 shrink-0">
          <label class="w-14 text-sm text-app shrink-0">功率列</label>
          <PropertyText v-model="form.powerColumn" placeholder="power" />
        </div>
        <template v-if="isWind">
          <div class="flex items-center gap-2 w-72 shrink-0">
            <label class="w-14 text-sm text-app shrink-0">风速列</label>
            <PropertyText v-model="form.windColumn" placeholder="wind_speed" />
          </div>
        </template>
        <template v-else>
          <div class="flex items-center gap-2 w-72 shrink-0">
            <label class="w-14 text-sm text-app shrink-0">辐照列</label>
            <PropertyText v-model="form.irradianceColumn" placeholder="irradiance" />
          </div>
          <div class="flex items-center gap-2 w-72 shrink-0">
            <label class="w-14 text-sm text-app shrink-0">温度列</label>
            <PropertyText v-model="form.temperatureColumn" placeholder="temperature" />
          </div>
        </template>
        <div class="flex items-center gap-2 shrink-0 ml-auto">
          <AppButton
            label="拟合计算"
            tone="primary"
            :disabled="!canFit"
            @click="runFit"
          />
          <AppButton
            label="提交"
            tone="green"
            @click="submitFitting"
          />
        </div>
      </div>

      <!-- 第二行：关联组件 -->
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-2 flex-1">
          <label class="w-16 text-sm text-app shrink-0">关联组件</label>
          <div class="flex-1 relative">
            <PropertyMultiSelect
              :model-value="form.relatedComponents"
              :options="availableNodes.map(n => ({ label: n.label, value: n.id }))"
              placeholder="请选择组件..."
              @update:model-value="handleRelatedChange"
            />
          </div>
        </div>
      </div>

      <!-- 统计 + 公式（公式区加高，图表相应压矮） -->
      <div v-if="formulaText" class="shrink-0 min-h-[120px]">
        <div class="text-xs text-app mb-1.5">拟合结果：{{ statsLine }}</div>
        <pre class="px-3 py-3 text-sm text-app whitespace-pre-wrap font-mono leading-7 border border-app-border rounded bg-white/40">{{ formulaText }}</pre>
      </div>

      <!-- 图表 -->
      <div class="relative flex-1 min-h-[180px]">
        <div
          v-if="!formulaText"
          class="absolute inset-0 flex flex-col items-center justify-center text-app-muted border border-dashed border-app-border rounded"
        >
          <svg class="w-10 h-10 mb-2" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
            <path d="M3 3v18h18M7 16l4-4 4 4 5-6" stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
          <span class="text-sm">点击「拟合计算」后显示散点与拟合曲线</span>
        </div>
        <div ref="chartRef" class="absolute inset-0" :class="{ invisible: !formulaText }"></div>
      </div>
    </div>
  </div>
</template>
