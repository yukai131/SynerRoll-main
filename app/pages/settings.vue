<script setup lang="ts">
import brand from '~~/config/brand.json'
import { useToastCenter } from '~~/state/ui'
import {
  DEVICE_COLOR_BY_TYPE,
  DEVICE_TYPE_COLOR_LABELS,
  ENERGY_FLOW_COLOR_BY_ROLE,
  ENERGY_FLOW_ROLE_LABELS,
} from '~~/config/device-colors'
import {
  applySavedDeviceColorPreferences,
  clearDeviceColorPreferences,
  saveDeviceColorPreferences,
} from '~~/utils/device-color-preferences'
import {
  clearResultDisplayPreferences,
  loadGlobalResultDisplayPreferences,
  resolveResultCatalog,
  saveResultDisplayPreferences,
  type ResultDisplayPreference,
} from '~~/utils/result-display-preferences'
import type { ResultCatalogItem } from '~~/config/result-variables'

const { push } = useToastCenter()
const router = useRouter()
const desktopAvailable = ref(false)
onMounted(() => { desktopAvailable.value = Boolean(window.synerroll?.openLocation) })
async function openDesktopLocation(location: 'data' | 'logs' | 'settings'): Promise<void> {
  try { await window.synerroll?.openLocation(location) }
  catch (error) {
    push({ tone: 'error', title: '打开失败', description: error instanceof Error ? error.message : '请稍后重试。' })
  }
}

// 从哪来回哪去；无历史时退回项目页
function goBack(): void {
  if (import.meta.client && window.history.length > 1) {
    router.back()
    return
  }
  navigateTo('/project')
}

// ─── 结果变量展示偏好（优先级 / 显隐） ───
const catalogRows = ref<ResultCatalogItem[]>(resolveResultCatalog())
const preferenceDirty = ref(false)

function markDirty(): void {
  preferenceDirty.value = true
}

// ─── 拖拽排序 ───
const dragIndex = ref<number | null>(null)
const dragOverIndex = ref<number | null>(null)

function reorderRows(from: number, to: number): void {
  if (from === to || from < 0 || to < 0 || from >= catalogRows.value.length || to >= catalogRows.value.length) {
    return
  }
  const rows = [...catalogRows.value]
  const [item] = rows.splice(from, 1)
  rows.splice(to, 0, item!)
  catalogRows.value = rows.map((row, i) => ({ ...row, order: (i + 1) * 10 }))
  markDirty()
}

function onRowDragStart(event: DragEvent, index: number): void {
  dragIndex.value = index
  dragOverIndex.value = index
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('text/plain', String(index))
  }
}

function onRowDragOver(event: DragEvent, index: number): void {
  if (dragIndex.value === null) return
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  dragOverIndex.value = index
}

function onRowDrop(event: DragEvent, index: number): void {
  event.preventDefault()
  const from = dragIndex.value
    ?? Number(event.dataTransfer?.getData('text/plain') ?? Number.NaN)
  if (Number.isFinite(from)) reorderRows(from, index)
  dragIndex.value = null
  dragOverIndex.value = null
}

function onRowDragEnd(): void {
  dragIndex.value = null
  dragOverIndex.value = null
}

function toggleVisible(row: ResultCatalogItem): void {
  catalogRows.value = catalogRows.value.map(item =>
    item.key === row.key ? { ...item, visible: !item.visible } : item,
  )
  markDirty()
}

function persistPreferences(): void {
  const prefs: Record<string, ResultDisplayPreference> = {}
  for (const row of catalogRows.value) {
    prefs[row.key] = { key: row.key, order: row.order, visible: row.visible }
  }
  saveResultDisplayPreferences(prefs)
  preferenceDirty.value = false
  push({
    tone: 'success',
    title: '结果展示偏好已保存',
    description: '优先级与显隐已写入本地设置，运行总览将按此排序过滤。',
  })
}

function resetPreferences(): void {
  clearResultDisplayPreferences()
  catalogRows.value = resolveResultCatalog(loadGlobalResultDisplayPreferences())
  preferenceDirty.value = false
  push({
    tone: 'info',
    title: '已清除本机覆盖',
    description: '顺序与显隐回到 config/result-display.json 全局配置。',
  })
}

// ─── 设备主色 / 能流方向色 ───
const deviceColorDraft = ref<Record<string, string>>({})
const energyFlowColorDraft = ref<Record<string, string>>({})
const colorDirty = ref(false)

const deviceColorRows = computed(() =>
  Object.keys(DEVICE_COLOR_BY_TYPE).map(key => ({
    key,
    label: DEVICE_TYPE_COLOR_LABELS[key] ?? key,
    defaultValue: DEVICE_COLOR_BY_TYPE[key]!,
    value: deviceColorDraft.value[key] ?? DEVICE_COLOR_BY_TYPE[key]!,
  })),
)

const energyFlowColorRows = computed(() =>
  Object.keys(ENERGY_FLOW_COLOR_BY_ROLE).map(key => ({
    key,
    label: ENERGY_FLOW_ROLE_LABELS[key] ?? key,
    defaultValue: ENERGY_FLOW_COLOR_BY_ROLE[key]!,
    value: energyFlowColorDraft.value[key] ?? ENERGY_FLOW_COLOR_BY_ROLE[key]!,
  })),
)

function loadColorDrafts(): void {
  const saved = applySavedDeviceColorPreferences()
  deviceColorDraft.value = { ...saved.device }
  energyFlowColorDraft.value = { ...saved.energyFlow }
  colorDirty.value = false
}

function onDeviceColorInput(key: string, value: string): void {
  deviceColorDraft.value = { ...deviceColorDraft.value, [key]: value }
  colorDirty.value = true
}

function onEnergyFlowColorInput(key: string, value: string): void {
  energyFlowColorDraft.value = { ...energyFlowColorDraft.value, [key]: value }
  colorDirty.value = true
}

function resetDeviceColor(key: string): void {
  const next = { ...deviceColorDraft.value }
  delete next[key]
  deviceColorDraft.value = next
  colorDirty.value = true
}

function resetEnergyFlowColor(key: string): void {
  const next = { ...energyFlowColorDraft.value }
  delete next[key]
  energyFlowColorDraft.value = next
  colorDirty.value = true
}

function persistColors(): void {
  saveDeviceColorPreferences({
    device: { ...deviceColorDraft.value },
    energyFlow: { ...energyFlowColorDraft.value },
  })
  loadColorDrafts()
  push({
    tone: 'success',
    title: '设备颜色已保存',
    description: '结果分析各图与能流方向色将使用新配色；默认表仍可一键恢复。',
  })
}

function resetColors(): void {
  clearDeviceColorPreferences()
  loadColorDrafts()
  push({
    tone: 'info',
    title: '已恢复默认设备颜色',
    description: '主色与能流方向色已回到系统默认表。',
  })
}

onMounted(() => {
  catalogRows.value = resolveResultCatalog()
  loadColorDrafts()
})
</script>

<template>
  <div class="flex h-screen flex-col bg-app-bg">
    <header class="flex h-14 items-center border-b border-app-border bg-primary px-4 text-white">
      <button
        class="inline-flex h-8 items-center gap-1 rounded px-3 text-sm hover:bg-white/10"
        type="button"
        @click="goBack"
      >
        <svg class="h-4 w-4" viewBox="0 0 16 16" fill="none">
          <path d="M10 12L6 8L10 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        返回
      </button>
      <h1 class="ml-4 text-base font-medium">系统设置</h1>
    </header>

    <div class="flex-1 min-h-0 overflow-y-auto">
      <div class="mx-auto w-full max-w-[1680px] space-y-6 px-6 py-6">
        <PanelSection title="软件信息">
          <div class="flex flex-wrap items-center gap-4">
            <img src="/logo.png" alt="软件图标" class="h-14 w-14 rounded-xl object-contain">
            <div class="min-w-0 flex-1">
              <p class="text-base font-semibold text-primary">{{ brand.displayName }}</p>
              <p class="mt-1 text-sm text-app-muted">{{ brand.publisher }} · {{ brand.publisherEnglish }} · 版本 {{ brand.version }}</p>
            </div>
            <div v-if="desktopAvailable" class="flex flex-wrap gap-2">
              <AppButton label="数据目录" tone="neutral" @click="openDesktopLocation('data')" />
              <AppButton label="日志目录" tone="neutral" @click="openDesktopLocation('logs')" />
              <AppButton label="启动设置" tone="neutral" @click="openDesktopLocation('settings')" />
            </div>
          </div>
        </PanelSection>
        <PanelSection title="运行总览页设备主色">
          <template #extra>
            <div class="flex items-center gap-2">
              <span v-if="colorDirty" class="text-xs text-orange-200">有未保存的修改</span>
              <AppButton label="恢复默认" tone="ghost" size="sm" @click="resetColors" />
              <AppButton label="保存颜色" tone="primary" size="sm" @click="persistColors" />
            </div>
          </template>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-5">
            <div
              v-for="row in deviceColorRows"
              :key="row.key"
              class="flex items-center gap-3 rounded-[12px] border border-app-border bg-white px-3 py-2"
            >
              <input
                type="color"
                class="h-9 w-12 cursor-pointer rounded border border-app-border bg-white p-0.5"
                :value="row.value"
                @input="onDeviceColorInput(row.key, ($event.target as HTMLInputElement).value)"
              >
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium text-app-text">{{ row.label }}
                <span class="ml-2 truncate text-xs text-app-muted">
                  {{ row.key }}
                  <span v-if="row.value !== row.defaultValue" class="ml-1 text-orange-600">已自定义</span>
                </span>
                </div>
              </div>
              <button
                type="button"
                class="h-7 shrink-0 rounded border border-app-border px-2 text-xs text-app-muted hover:bg-app-panel-soft disabled:opacity-30"
                :disabled="row.value === row.defaultValue"
                @click="resetDeviceColor(row.key)"
              >默认</button>
            </div>
          </div>
        </PanelSection>

        <PanelSection title="运行总览页能流方向色">
          <template #extra>
            <div class="flex items-center gap-2">
              <AppButton label="恢复默认" tone="ghost" size="sm" @click="resetColors" />
              <AppButton label="保存颜色" tone="primary" size="sm" @click="persistColors" />
            </div>
          </template>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-5">
            <div
              v-for="row in energyFlowColorRows"
              :key="row.key"
              class="flex items-center gap-3 rounded-[12px] border border-app-border bg-white px-3 py-2"
            >
              <input
                type="color"
                class="h-9 w-12 cursor-pointer rounded border border-app-border bg-white p-0.5"
                :value="row.value"
                @input="onEnergyFlowColorInput(row.key, ($event.target as HTMLInputElement).value)"
              >
              <div class="min-w-0 flex-1">
                <span class="truncate text-sm font-medium text-app-text">{{ row.label }}</span>
                <span class="ml-2 truncate text-xs text-app-muted">
                  {{ row.key }}
                  <span v-if="row.value !== row.defaultValue" class="ml-1 text-orange-600">已自定义</span>
                </span>
              </div>
              <button
                type="button"
                class="h-7 shrink-0 rounded border border-app-border px-2 text-xs text-app-muted hover:bg-app-panel-soft disabled:opacity-30"
                :disabled="row.value === row.defaultValue"
                @click="resetEnergyFlowColor(row.key)"
              >默认</button>
            </div>
          </div>
        </PanelSection>

        <PanelSection title="运行总览页变量优先级与显隐">
          <template #extra>
            <div class="flex items-center gap-2">
              <span v-if="preferenceDirty" class="text-xs text-orange-600">有未保存的修改</span>
              <AppButton label="恢复默认" tone="ghost" size="sm" @click="resetPreferences" />
              <AppButton label="保存偏好" tone="primary" size="sm" @click="persistPreferences" />
            </div>
          </template>

          <div class="grid grid-cols-1 gap-2 lg:grid-cols-2 xl:grid-cols-3">
            <div
              v-for="(row, index) in catalogRows"
              :key="row.key"
              class="flex items-center gap-2 rounded-[12px] border border-app-border bg-white px-2 py-2"
              :class="[
                dragIndex === index ? 'opacity-50 ring-2 ring-primary' : '',
                dragOverIndex === index && dragIndex !== null && dragIndex !== index
                  ? 'border-primary bg-primary-soft/40 ring-1 ring-primary'
                  : '',
              ]"
              draggable="true"
              @dragstart="onRowDragStart($event, index)"
              @dragover="onRowDragOver($event, index)"
              @drop="onRowDrop($event, index)"
              @dragend="onRowDragEnd"
            >
              <span
                class="flex h-8 w-7 shrink-0 cursor-grab items-center justify-center rounded text-app-muted hover:bg-app-panel-soft hover:text-app-text active:cursor-grabbing"
                title="拖拽排序"
              >⠿</span>
              <span class="w-8 shrink-0 text-xs text-app-muted">#{{ index + 1 }}</span>
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium text-app-text">
                  {{ row.name }}
                  <span class="ml-1 text-xs text-app-muted">{{ row.labelName }}</span>
                  <span class="ml-3 truncate text-xs text-app-muted">{{ row.key }}</span>
                </div>
              </div>
              <label class="inline-flex shrink-0 items-center gap-1.5 text-xs text-app-text" @mousedown.stop>
                <input
                  type="checkbox"
                  class="accent-primary"
                  :checked="row.visible"
                  @change="toggleVisible(row)"
                >
                {{ row.visible ? '显示' : '隐藏' }}
              </label>
            </div>
          </div>
        </PanelSection>
      </div>
    </div>
  </div>
</template>
