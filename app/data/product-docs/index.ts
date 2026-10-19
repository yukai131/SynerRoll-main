import type { DocChapter } from './types'
import { chapter1 } from './ch1'
import { chapter2 } from './ch2'
import { chapter3 } from './ch3'

export type { DocBlock, DocSection, DocChapter } from './types'

export const productDocChapters: DocChapter[] = [chapter1, chapter2, chapter3]
