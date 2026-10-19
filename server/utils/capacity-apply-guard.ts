import type { CanvasData } from '~~/types/canvas'

const canonicalJson = (value: unknown): string => JSON.stringify(value, (_key, item) =>
  item && typeof item === 'object' && !Array.isArray(item)
    ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]]))
    : item
)

// Some editor writes preserve updatedAt. Compare content as well as the version
// before restoring a snapshot so an undo cannot discard a later edit.
export const canvasMatchesApplySnapshot = (canvas: CanvasData, snapshot: unknown): boolean => {
  if (!snapshot || typeof snapshot !== 'object') return false
  const { updatedAt: _currentVersion, ...current } = canvas
  const { updatedAt: _savedVersion, ...saved } = snapshot as CanvasData
  return canonicalJson(current) === canonicalJson(saved)
}
