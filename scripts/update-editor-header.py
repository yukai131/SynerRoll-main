# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"C:/Users/Administrator/Desktop/SynerRoll-main/app/components/EditorHeader.vue")
text = p.read_text(encoding="utf-8")

text = text.replace(
    "logoText: '综合能源系统配置策略优化软件',",
    "logoText: '新能源发电灵活性量化评估软件',",
)

old = """        <button type="button" class="flex items-center gap-3 text-left" @click="$emit('navigateHome')">
          <img
            v-if="logoSrc"
            :src="logoSrc"
            alt="SynerRoll Logo"
            class="h-12 w-12 rounded-lg object-cover"
          >
          <span
            v-else
            class="inline-flex h-12 items-center text-xl font-bold tracking-[0.02em] text-white"
          >
            {{ logoText }}
          </span>
        </button>"""

new = """        <button type="button" class="flex min-w-0 items-center gap-2.5 text-left" @click="$emit('navigateHome')">
          <img
            v-if="logoSrc"
            :src="logoSrc"
            alt="软件主标志"
            class="h-9 w-auto max-h-10 shrink-0 object-contain"
          >
          <span class="inline-flex min-w-0 items-center text-base font-semibold tracking-[0.02em] text-white lg:text-lg">
            <span class="truncate">{{ logoText }}</span>
          </span>
        </button>"""

if old not in text:
    raise SystemExit("header logo block not found")

text = text.replace(old, new)
p.write_text(text, encoding="utf-8")
print("EditorHeader updated")
print("title:", "新能源发电灵活性量化评估软件" in text)
print("logo+text:", "软件主标志" in text and "v-else" not in text.split("logoText")[0])
