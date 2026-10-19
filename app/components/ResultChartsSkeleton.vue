<script setup lang="ts">
/** 结果页骨架屏：任务刚创建/正在求解、尚无时序数据时占位 */
const props = withDefaults(
  defineProps<{
    status?: string
    cardCount?: number
    errorMessage?: string | null
  }>(),
  {
    status: 'pending',
    cardCount: 6,
    errorMessage: null
  }
)

const statusText = computed(() => {
  switch (props.status) {
    case 'pending':
      return '任务已创建，正在排队…'
    case 'parsing':
      return '正在解析模型…'
    case 'building':
      return '正在构建优化模型…'
    case 'solving':
      return '正在求解，结果即将刷新…'
    case 'failed':
      return '任务失败，暂无数据'
    case 'cancelled':
      return '任务已取消，暂无数据'
    default:
      return '正在准备结果…'
  }
})

const isTerminal = computed(() => props.status === 'failed' || props.status === 'cancelled')
const showErrorMessage = computed(() => props.status === 'failed' && Boolean(props.errorMessage))
</script>

<template>
  <div class="h-full overflow-y-auto">
    <div class="mb-3 flex items-center gap-2 text-sm text-app-muted">
      <span
        class="inline-block h-2 w-2 rounded-full"
        :class="isTerminal ? 'bg-app-danger' : 'animate-pulse bg-primary'"
      />
      <span>{{ statusText }}</span>
    </div>
    <div
      v-if="showErrorMessage"
      class="mb-3 rounded border border-app-danger/30 bg-red-50 px-3 py-2 text-sm text-app-danger"
    >
      <div class="whitespace-pre-wrap break-words">{{ errorMessage }}</div>
    </div>
    <div class="grid grid-cols-2 gap-3">
      <div
        v-for="i in cardCount"
        :key="i"
        class="border border-app-border rounded p-2"
      >
        <div class="mb-2 h-4 w-2/5 animate-pulse rounded bg-app-panel-soft" />
        <div class="h-[180px] animate-pulse rounded bg-app-panel-soft/80" />
      </div>
    </div>
  </div>
</template>
