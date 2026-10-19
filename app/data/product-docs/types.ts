export type DocBlock =
  | { type: 'p'; text: string }
  | { type: 'h'; level: 2 | 3 | 4; text: string }
  | { type: 'formula'; text: string; caption?: string }
  | { type: 'list'; ordered?: boolean; items: string[] }
  | { type: 'table'; headers: string[]; rows: string[][]; caption?: string }
  | { type: 'callout'; tone: 'info' | 'tip' | 'warning' | 'danger'; title?: string; text: string }
  | { type: 'steps'; items: Array<{ title: string; text: string }> }

export interface DocSection {
  id: string
  title: string
  blocks: DocBlock[]
}

export interface DocChapter {
  id: string
  title: string
  summary: string
  sections: DocSection[]
}
