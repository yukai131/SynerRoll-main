import { onBeforeUnmount, onMounted, ref, type Ref } from 'vue'
import type { ECharts } from 'echarts'

/** 屏幕外只标脏；多次更新合并到一帧。finished 记录实际绘制完成，而非仅 setOption 返回。 */
export function useVisibleChart(
  element: Ref<HTMLElement | null>, render: () => void,
  getChart: () => ECharts | null, label: () => string, version: () => number = () => 0,
  channel: 'series' | 'flexibility' = 'series',
) {
  const visible = ref(false)
  let dirty = true
  let frame = 0
  let observer: IntersectionObserver | null = null
  let observedChart: ECharts | null = null
  let started = 0
  let prepareMs = 0
  let renderedVersion = 0
  let awaitingFinish = false
  let preparing = false
  const finished = () => {
    if (!awaitingFinish) return
    // 关闭动画时 finished 可能在 setOption 内同步触发，等本次准备耗时记录后再发布。
    if (preparing) { queueMicrotask(finished); return }
    awaitingFinish = false
    window.dispatchEvent(new CustomEvent('synerroll:chart-render', { detail: {
      label: label(), version: renderedVersion, channel, prepareMs,
      paintMs: performance.now() - started, finishedAt: Date.now(),
    } }))
  }
  const bindChart = () => {
    const chart = getChart()
    if (chart === observedChart) return
    observedChart?.off('finished', finished)
    observedChart = chart
    chart?.on('finished', finished)
  }
  const schedule = () => {
    dirty = true
    if (!visible.value || frame) return
    frame = requestAnimationFrame(() => {
      frame = 0
      if (!visible.value || !dirty) return
      dirty = false
      started = performance.now()
      renderedVersion = version()
      awaitingFinish = true
      bindChart()
      preparing = true
      try {
        render()
      } finally {
        prepareMs = performance.now() - started
        preparing = false
        // 首次 render 可能创建 ECharts 实例，后续更新须在 setOption 前绑定。
        bindChart()
      }
    })
  }
  onMounted(() => {
    if (!element.value) return
    if (typeof IntersectionObserver === 'undefined') { visible.value = true; schedule(); return }
    observer = new IntersectionObserver(entries => {
      visible.value = entries.some(entry => entry.isIntersecting)
      if (visible.value && dirty) schedule()
    }, { rootMargin: '150px' })
    observer.observe(element.value)
  })
  onBeforeUnmount(() => {
    observer?.disconnect()
    if (frame) cancelAnimationFrame(frame)
    observedChart?.off('finished', finished)
  })
  return { visible, schedule }
}
