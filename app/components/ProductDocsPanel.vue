<script setup lang="ts">
import type { DocChapter, DocSection } from '~/data/product-docs/types'
import { productDocChapters } from '~/data/product-docs'

const emit = defineEmits<{
  close: []
}>()

const chapters = productDocChapters

const activeChapterId = ref(chapters[0]?.id ?? 'ch1')
const activeSectionId = ref(chapters[0]?.sections[0]?.id ?? '')

const activeChapter = computed<DocChapter | undefined>(() =>
  chapters.find(ch => ch.id === activeChapterId.value)
)

const activeSection = computed<DocSection | undefined>(() =>
  activeChapter.value?.sections.find(s => s.id === activeSectionId.value)
)

const contentEl = ref<HTMLElement | null>(null)

const flatSections = computed(() =>
  chapters.flatMap(ch => ch.sections.map(s => ({ ...s, chapterId: ch.id })))
)

const activeFlatIndex = computed(() =>
  flatSections.value.findIndex(s => s.id === activeSectionId.value)
)

const prevSection = computed(() => {
  const i = activeFlatIndex.value
  return i > 0 ? flatSections.value[i - 1] : undefined
})

const nextSection = computed(() => {
  const i = activeFlatIndex.value
  return i >= 0 && i < flatSections.value.length - 1 ? flatSections.value[i + 1] : undefined
})

const selectChapter = (chapterId: string) => {
  activeChapterId.value = chapterId
  const chapter = chapters.find(ch => ch.id === chapterId)
  activeSectionId.value = chapter?.sections[0]?.id ?? ''
  scrollToTop()
}

const selectSection = (sectionId: string) => {
  const found = flatSections.value.find(s => s.id === sectionId)
  if (found) {
    activeChapterId.value = found.chapterId
  }
  activeSectionId.value = sectionId
  scrollToTop()
}

const scrollToTop = () => {
  nextTick(() => {
    if (contentEl.value) {
      contentEl.value.scrollTop = 0
    }
  })
}

const handleEscape = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    emit('close')
  }
}

onMounted(() => {
  document.addEventListener('keydown', handleEscape)
})

onBeforeUnmount(() => {
  document.removeEventListener('keydown', handleEscape)
})

const toneClass = (tone: string) => {
  switch (tone) {
    case 'tip':
      return 'border-l-[3px] border-[#00B42A] bg-[#E8FFEA] text-app-text'
    case 'warning':
      return 'border-l-[3px] border-[#FF7D00] bg-[#FFF7E8] text-app-text'
    case 'danger':
      return 'border-l-[3px] border-[#F53F3F] bg-[#FFECE8] text-app-text'
    default:
      return 'border-l-[3px] border-primary bg-[#E8F3FF] text-app-text'
  }
}
</script>

<template>
  <Teleport to="body">
    <div class="fixed inset-0 z-[60] flex flex-col bg-app-surface">
      <!-- 顶栏 -->
      <header class="flex h-12 shrink-0 items-center justify-between border-b border-app-border bg-primary px-4 text-white">
        <div class="flex min-w-0 items-center gap-3">
          <button
            type="button"
            class="inline-flex h-9 items-center gap-1.5 rounded-[9px] px-2 text-sm transition hover:bg-white/12"
            @click="emit('close')"
          >
            <span class="text-lg leading-none" aria-hidden="true">←</span>
            <span>返回</span>
          </button>
          <span class="h-5 w-px bg-white/30" aria-hidden="true" />
          <span class="truncate text-base font-medium">产品文档</span>
          <span class="hidden text-sm text-white/70 sm:inline">综合能源系统配置策略优化软件</span>
        </div>
        <button
          type="button"
          class="inline-flex h-9 w-9 items-center justify-center rounded-[10px] transition hover:bg-white/12"
          title="关闭"
          @click="emit('close')"
        >
          <svg class="h-4 w-4" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 4L4 12M4 4L12 12" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </button>
      </header>

      <div class="flex min-h-0 flex-1">
        <!-- 左侧：章节结构 -->
        <aside class="flex w-[280px] shrink-0 flex-col border-r border-app-border bg-white">
          <div class="border-b border-app-border px-4 py-3">
            <p class="text-xs font-medium text-app-muted">章节导航</p>
          </div>

          <!-- 章标签 -->
          <div class="flex shrink-0 gap-1 border-b border-app-border px-2 py-2">
            <button
              v-for="chapter in chapters"
              :key="chapter.id"
              type="button"
              class="flex-1 rounded-[8px] px-2 py-2 text-left text-xs leading-5 transition"
              :class="
                activeChapterId === chapter.id
                  ? 'bg-primary text-white'
                  : 'text-app-text hover:bg-app-panel-soft'
              "
              @click="selectChapter(chapter.id)"
            >
              <span class="block font-medium">{{ chapter.title.split('·')[0]?.trim() }}</span>
              <span
                class="block truncate opacity-80"
                :class="activeChapterId === chapter.id ? 'text-white/85' : 'text-app-muted'"
              >
                {{ chapter.title.split('·')[1]?.trim() || chapter.title }}
              </span>
            </button>
          </div>

          <!-- 节列表 -->
          <nav class="min-h-0 flex-1 overflow-y-auto px-2 py-2">
            <p class="px-2 pb-2 text-xs font-semibold text-app-muted">
              {{ activeChapter?.title ?? '' }}
            </p>
            <ul class="space-y-0.5">
              <li v-for="section in activeChapter?.sections ?? []" :key="section.id">
                <button
                  type="button"
                  class="w-full rounded-[8px] px-3 py-2 text-left text-sm leading-5 transition"
                  :class="
                    activeSectionId === section.id
                      ? 'bg-[#E8F3FF] font-medium text-primary'
                      : 'text-app-text hover:bg-app-panel-soft'
                  "
                  @click="selectSection(section.id)"
                >
                  {{ section.title }}
                </button>
              </li>
            </ul>
          </nav>
        </aside>

        <!-- 右侧：正文 -->
        <main
          ref="contentEl"
          class="min-h-0 flex-1 overflow-y-auto"
        >
          <div class="mx-auto max-w-[860px] px-8 py-8">
            <!-- 章摘要 -->
            <div class="mb-8 rounded-[12px] border border-app-border bg-white p-5">
              <h1 class="text-xl font-semibold text-app-text">{{ activeChapter?.title }}</h1>
              <p class="mt-2 text-sm leading-6 text-app-muted">{{ activeChapter?.summary }}</p>
            </div>

            <article v-if="activeSection" class="space-y-5">
              <h2 class="text-lg font-semibold text-app-text">{{ activeSection.title }}</h2>

              <template v-for="(block, index) in activeSection.blocks" :key="index">
                <!-- 段落 -->
                <p
                  v-if="block.type === 'p'"
                  class="text-[15px] leading-7 text-app-text"
                >
                  {{ block.text }}
                </p>

                <!-- 标题 -->
                <h3
                  v-else-if="block.type === 'h' && block.level === 3"
                  class="pt-2 text-base font-semibold text-app-text"
                >
                  {{ block.text }}
                </h3>
                <h4
                  v-else-if="block.type === 'h' && block.level === 4"
                  class="pt-1 text-[15px] font-semibold text-app-text"
                >
                  {{ block.text }}
                </h4>

                <!-- 公式 -->
                <figure
                  v-else-if="block.type === 'formula'"
                  class="overflow-hidden rounded-[10px] border border-app-border bg-[#F7F8FA]"
                >
                  <pre
                    class="overflow-x-auto px-4 py-4 font-mono text-[13px] leading-6 text-app-text"
                  >{{ block.text }}</pre>
                  <figcaption
                    v-if="block.caption"
                    class="border-t border-app-border px-4 py-2 text-xs leading-5 text-app-muted"
                  >
                    {{ block.caption }}
                  </figcaption>
                </figure>

                <!-- 列表 -->
                <ul
                  v-else-if="block.type === 'list' && !block.ordered"
                  class="list-disc space-y-2 pl-6 text-[15px] leading-7 text-app-text marker:text-primary"
                >
                  <li v-for="(item, i) in block.items" :key="i">{{ item }}</li>
                </ul>
                <ol
                  v-else-if="block.type === 'list' && block.ordered"
                  class="list-decimal space-y-2 pl-6 text-[15px] leading-7 text-app-text marker:text-primary"
                >
                  <li v-for="(item, i) in block.items" :key="i">{{ item }}</li>
                </ol>

                <!-- 表格 -->
                <div
                  v-else-if="block.type === 'table'"
                  class="overflow-hidden rounded-[10px] border border-app-border bg-white"
                >
                  <div class="overflow-x-auto">
                    <table class="w-full min-w-[520px] border-collapse text-sm">
                      <thead>
                        <tr class="bg-app-panel-soft">
                          <th
                            v-for="(header, hi) in block.headers"
                            :key="hi"
                            class="border-b border-app-border px-3 py-2.5 text-left font-medium text-app-muted"
                          >
                            {{ header }}
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          v-for="(row, ri) in block.rows"
                          :key="ri"
                          class="border-b border-app-border last:border-b-0"
                        >
                          <td
                            v-for="(cell, ci) in row"
                            :key="ci"
                            class="px-3 py-2.5 align-top leading-6 text-app-text"
                            :class="ci === 0 ? 'font-medium whitespace-nowrap' : ''"
                          >
                            {{ cell }}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                  <p
                    v-if="block.caption"
                    class="border-t border-app-border px-3 py-2 text-xs leading-5 text-app-muted"
                  >
                    {{ block.caption }}
                  </p>
                </div>

                <!-- 提示 -->
                <div
                  v-else-if="block.type === 'callout'"
                  class="rounded-[10px] px-4 py-3.5"
                  :class="toneClass(block.tone)"
                >
                  <p v-if="block.title" class="text-sm font-semibold">{{ block.title }}</p>
                  <p class="mt-1 text-sm leading-6">{{ block.text }}</p>
                </div>

                <!-- 步骤 -->
                <div
                  v-else-if="block.type === 'steps'"
                  class="space-y-3"
                >
                  <div
                    v-for="(step, si) in block.items"
                    :key="si"
                    class="rounded-[10px] border border-app-border bg-white p-4"
                  >
                    <p class="text-sm font-semibold text-primary">{{ step.title }}</p>
                    <p class="mt-1.5 text-sm leading-6 text-app-text">{{ step.text }}</p>
                  </div>
                </div>
              </template>
            </article>

            <!-- 底部：上一节 / 下一节 -->
            <div
              v-if="activeChapter"
              class="mt-10 flex items-center justify-between gap-4 border-t border-app-border pt-6"
            >
              <button
                v-if="prevSection"
                type="button"
                class="max-w-[45%] rounded-[10px] border border-app-border bg-white px-4 py-3 text-left transition hover:border-primary"
                @click="selectSection(prevSection.id)"
              >
                <p class="text-xs text-app-muted">上一节</p>
                <p class="mt-0.5 truncate text-sm font-medium text-app-text">{{ prevSection.title }}</p>
              </button>
              <span v-else />
              <button
                v-if="nextSection"
                type="button"
                class="max-w-[45%] rounded-[10px] border border-app-border bg-white px-4 py-3 text-right transition hover:border-primary"
                @click="selectSection(nextSection.id)"
              >
                <p class="text-xs text-app-muted">下一节</p>
                <p class="mt-0.5 truncate text-sm font-medium text-app-text">{{ nextSection.title }}</p>
              </button>
              <span v-else />
            </div>
          </div>
        </main>
      </div>
    </div>
  </Teleport>
</template>
