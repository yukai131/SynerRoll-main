export const createId = (prefix: string): string => {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
    return `${prefix}-${crypto.randomUUID()}`
  }

  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`
}

/** 边界/拟合模型等业务 ID：b_ + base36 时间戳 + 随机后缀 */
export const createBoundaryId = (): string =>
  `b_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`
