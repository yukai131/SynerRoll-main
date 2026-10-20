<script setup lang="ts">
import PropertySwitch from './PropertySwitch.vue'
import PropertyNumber from './PropertyNumber.vue'
import PropertySelect from './PropertySelect.vue'

import type { AlgorithmConfig } from '~~/types/simulation'
import { SOLVER_OPTIONS } from '~~/config/solver'

interface Props {
  open: boolean
  algorithm: AlgorithmConfig
}

const props = defineProps<Props>()

const emit = defineEmits<{
  close: []
  confirm: [config: AlgorithmConfig]
}>()

const localConfig = ref<AlgorithmConfig>({
  electricityLoadPrediction: 'None',
  windTurbinePrediction: 'None',
  optimizationAlgorithm: 'MILP',
  solver: 'HiGHS',
  slackEnabled: false,
  shortagePenalty: 1000,
  excessPenalty: 50
})

watch(() => props.open, (isOpen) => {
  if (isOpen) {
    const src = props.algorithm
    const legacy = src.slackPenalty
    localConfig.value = {
      ...src,
      solver: (src.solver === 'HiGHS' || src.solver === 'COPT') ? src.solver : 'HiGHS',
      shortagePenalty: src.shortagePenalty ?? legacy ?? 1000,
      excessPenalty: src.excessPenalty ?? legacy ?? 50
    }
  }
})

const handleConfirm = () => {
  emit('confirm', { ...localConfig.value })
  emit('close')
}

const handleCancel = () => {
  emit('close')
}
</script>

<template>
  <AppModal
    :open="open"
    title="算法配置"
    size="sm"
    @close="handleCancel"
  >
    <div class="space-y-4 px-4 py-3">
      <!-- 求解器 -->
      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0">
          <div class="text-sm font-medium text-app-text">求解器</div>
        </div>
        <div class="w-52 shrink-0">
          <PropertySelect
            v-model="localConfig.solver"
            :options="SOLVER_OPTIONS"
          />
        </div>
      </div>

      <!-- 松弛变量开关 -->
      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0">
          <div class="text-sm font-medium text-app-text">启用松弛变量</div>
          <div class="mt-0.5 text-xs text-app-muted">能量平衡约束加入松弛项，保证模型始终有解</div>
        </div>
        <PropertySwitch v-model="localConfig.slackEnabled" />
      </div>

      <!-- 缺供 / 过剩惩罚系数 -->
      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0">
          <div class="text-sm font-medium text-app-text">缺供惩罚</div>
          <div class="mt-0.5 text-xs text-app-muted">SHORTAGE 系数（元/kWh），默认 1000</div>
        </div>
        <div class="w-52 shrink-0">
          <PropertyNumber
            v-model="localConfig.shortagePenalty"
            :step="100"
            :min="0"
            unit=""
          />
        </div>
      </div>

      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0">
          <div class="text-sm font-medium text-app-text">过剩惩罚</div>
          <div class="mt-0.5 text-xs text-app-muted">EXCESS 系数（元/kWh），默认 50</div>
        </div>
        <div class="w-52 shrink-0">
          <PropertyNumber
            v-model="localConfig.excessPenalty"
            :step="10"
            :min="0"
            unit=""
          />
        </div>
      </div>
    </div>

    <template #footer>
      <AppButton label="取消" tone="neutral" @click="handleCancel" />
      <AppButton label="确定" tone="primary" @click="handleConfirm" />
    </template>
  </AppModal>
</template>
