<script setup lang="ts">
interface PieItem {
  label: string
  value: number
  color: string
}

const props = defineProps<{
  title?: string
  items: PieItem[]
  unit?: string
}>()

const total = computed(() => props.items.reduce((sum, item) => sum + item.value, 0) || 1)
const hoveredItem = ref<PieItem | null>(null)
const tooltipPosition = ref({ left: 0, top: 0 })

const showTooltip = (event: PointerEvent, item: PieItem) => {
  hoveredItem.value = item
  tooltipPosition.value = {
    left: Math.max(8, Math.min(event.clientX + 12, window.innerWidth - 288)),
    top: Math.max(8, Math.min(event.clientY + 12, window.innerHeight - 110))
  }
}

const hideTooltip = () => { hoveredItem.value = null }
const formatValue = (value: number) => value.toLocaleString('zh-CN', { maximumFractionDigits: 2 })
watch(() => props.items, hideTooltip)

const polarToCartesian = (centerX: number, centerY: number, radius: number, angleInDegrees: number) => {
  const angleInRadians = (angleInDegrees - 90) * Math.PI / 180

  return {
    x: centerX + radius * Math.cos(angleInRadians),
    y: centerY + radius * Math.sin(angleInRadians)
  }
}

const describeArc = (startAngle: number, endAngle: number) => {
  const radius = 68
  // 单个项目占满圆时，起终点重合，需要两段圆弧才能绘制完整扇形。
  if (endAngle - startAngle >= 360 - 1e-9) {
    return 'M 90 22 A 68 68 0 1 1 90 158 A 68 68 0 1 1 90 22 Z'
  }
  const start = polarToCartesian(90, 90, radius, endAngle)
  const end = polarToCartesian(90, 90, radius, startAngle)
  const largeArcFlag = endAngle - startAngle <= 180 ? '0' : '1'

  return [`M`, start.x, start.y, `A`, radius, radius, 0, largeArcFlag, 0, end.x, end.y, `L`, 90, 90, `Z`].join(' ')
}

const segments = computed(() => {
  let currentAngle = 0

  return props.items.map(item => {
    const angle = (item.value / total.value) * 360
    const segment = {
      ...item,
      path: describeArc(currentAngle, currentAngle + angle)
    }
    currentAngle += angle
    return segment
  })
})
</script>

<template>
  <div class="bg-white">
    <div v-if="title" class="mb-2">
      <h3 class="bg-gray-100 p-2 text-sm text-app-text">{{ title }}</h3>
    </div>
    <div class="flex items-center gap-4">
      <svg viewBox="0 0 180 180" class="h-44 w-44 shrink-0">
        <path
          v-for="segment in segments"
          :key="segment.label"
          :d="segment.path"
          :fill="segment.color"
          class="pie-segment"
          :class="{ 'pie-segment-active': hoveredItem?.label === segment.label }"
          @pointerenter="showTooltip($event, segment)"
          @pointermove="showTooltip($event, segment)"
          @pointerleave="hideTooltip"
        />
      </svg>

      <div class="space-y-2 text-xs text-app-muted">
        <div
          v-for="item in items"
          :key="item.label"
          class="flex items-center gap-2"
          @pointerenter="showTooltip($event, item)"
          @pointermove="showTooltip($event, item)"
          @pointerleave="hideTooltip"
        >
          <span class="h-2.5 w-2.5 rounded-full" :style="{ backgroundColor: item.color }" />
          <span class="min-w-24">{{ item.label }}</span>
          <span>{{ ((item.value / total) * 100).toFixed(1) }}%</span>
        </div>
      </div>
    </div>
    <Teleport to="body">
      <div
        v-if="hoveredItem"
        role="tooltip"
        class="pointer-events-none fixed z-[1000] w-[280px] max-w-[calc(100vw-16px)] rounded border border-app-border bg-white px-3 py-2 text-xs text-app-text shadow-lg"
        :style="{ left: `${tooltipPosition.left}px`, top: `${tooltipPosition.top}px` }"
      >
        <div class="mb-1 flex items-center gap-2">
          <span class="h-2 w-2 shrink-0 rounded-full" :style="{ backgroundColor: hoveredItem.color }" />
          <span>{{ hoveredItem.label }}</span>
        </div>
        <div>{{ formatValue(hoveredItem.value) }}{{ unit ? ` ${unit}` : '' }}</div>
        <div class="mt-1 text-app-muted">占比：{{ ((hoveredItem.value / total) * 100).toFixed(1) }}%</div>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.pie-segment {
  transform-box: view-box;
  transform-origin: 90px 90px;
  transition: transform 150ms ease-out;
}

.pie-segment-active {
  transform: scale(1.1);
}

@media (prefers-reduced-motion: reduce) {
  .pie-segment {
    transition: none;
  }
}
</style>
