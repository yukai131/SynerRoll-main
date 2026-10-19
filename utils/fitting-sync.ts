import type { FittingModel } from '~~/types/fitting'
import type { FlowNode } from '~~/types/canvas'
import type { CanvasWorkspace } from '~~/types/canvas'

const dedupeStrings = (values: string[]): string[] => [...new Set(values.filter(Boolean))]

const getNodeFittingModelId = (node: FlowNode): string =>
  String(node.data?.business?.fittingModelId ?? '')

const setNodeFittingModelId = (node: FlowNode, fittingModelId: string): FlowNode => {
  if (!node.data) return node
  return {
    ...node,
    data: {
      ...node.data,
      business: {
        ...node.data.business,
        fittingModelId
      }
    }
  }
}

/**
 * 取当前画布视角下的关联节点列表（保留其他画布的 nodeId）。
 */
export function getFittingRelatedComponentsForActiveCanvas(
  model: FittingModel,
  workspace: CanvasWorkspace | undefined
): string[] {
  const canvas = workspace?.canvases?.find(c => c.id === workspace.activeCanvasId) ?? workspace?.canvases?.[0]
  const allNodeIds = new Set((canvas?.nodes ?? []).map(n => n.id))
  const current = model.relatedComponents.filter(id => allNodeIds.has(id))
  const preserved = model.relatedComponents.filter(id => !allNodeIds.has(id))
  return dedupeStrings([...current, ...preserved])
}

/**
 * 写入当前画布视角下的关联节点，并把节点侧 fittingModelId 写成该 model.id。
 * 每个节点最多关联一个机型：写入时会从其他机型的 relatedComponents 中移除。
 */
export function setFittingRelatedComponentsForActiveCanvas(
  model: FittingModel,
  workspace: CanvasWorkspace,
  nodeIds: string[]
): string[] {
  const canvas = workspace.canvases?.find(c => c.id === workspace.activeCanvasId) ?? workspace.canvases?.[0]
  const allNodeIds = new Set((canvas?.nodes ?? []).map(n => n.id))
  const next = dedupeStrings(nodeIds)
  const preservedOther = model.relatedComponents.filter(id => !allNodeIds.has(id))
  return dedupeStrings([...next.filter(id => allNodeIds.has(id)), ...preservedOther])
}

/**
 * 从 fittingModels 同步到 workspace：以机型 relatedComponents 为准回写节点.fittingModelId；
 * 不在任何机型中的节点会清除 fittingModelId。
 */
export function syncWorkspaceFromFittingModels(
  workspace: CanvasWorkspace,
  models: FittingModel[]
): CanvasWorkspace {
  const nodeToModel = new Map<string, string>()
  for (const model of models) {
    for (const nodeId of model.relatedComponents) {
      if (!nodeToModel.has(nodeId)) {
        nodeToModel.set(nodeId, model.id)
      }
    }
  }

  return {
    ...workspace,
    canvases: (workspace.canvases ?? []).map(canvas => ({
      ...canvas,
      nodes: (canvas.nodes ?? []).map(node => {
        const nextId = nodeToModel.get(node.id) ?? ''
        const currentId = getNodeFittingModelId(node)
        if (currentId === nextId) return node
        return setNodeFittingModelId(node, nextId)
      })
    }))
  }
}

/**
 * 从 workspace 节点回写机型 relatedComponents（只维护当前画布内节点）。
 */
export function syncFittingModelsFromWorkspace(
  models: FittingModel[],
  workspace: CanvasWorkspace
): FittingModel[] {
  const canvas = workspace.canvases?.find(c => c.id === workspace.activeCanvasId) ?? workspace.canvases?.[0]
  const allNodeIds = new Set((canvas?.nodes ?? []).map(n => n.id))

  const modelNodeIds = new Map<string, string[]>()
  for (const node of canvas?.nodes ?? []) {
    const mid = getNodeFittingModelId(node)
    if (!mid) continue
    const list = modelNodeIds.get(mid) ?? []
    list.push(node.id)
    modelNodeIds.set(mid, list)
  }

  return models.map(model => {
    const nextCurrent = modelNodeIds.get(model.id) ?? []
    const preserved = model.relatedComponents.filter(id => !allNodeIds.has(id))
    const next = dedupeStrings([...nextCurrent, ...preserved])
    if (next.length === model.relatedComponents.length && next.every((v, i) => v === model.relatedComponents[i])) {
      return model
    }
    return { ...model, relatedComponents: next }
  })
}

/**
 * 设为某节点的唯一机型：写入节点.fittingModelId，并维护双向关系。
 */
export function assignFittingModelToNode(
  models: FittingModel[],
  workspace: CanvasWorkspace,
  nodeId: string,
  modelId: string
): { models: FittingModel[]; workspace: CanvasWorkspace } {
  const nextModels = models.map(model => {
    const related = model.relatedComponents.filter(id => id !== nodeId)
    if (model.id === modelId) {
      return { ...model, relatedComponents: dedupeStrings([...related, nodeId]) }
    }
    return { ...model, relatedComponents: related }
  })

  const nextWorkspace = {
    ...workspace,
    canvases: (workspace.canvases ?? []).map(canvas => ({
      ...canvas,
      nodes: (canvas.nodes ?? []).map(node =>
        node.id === nodeId ? setNodeFittingModelId(node, modelId) : node
      )
    }))
  }

  return { models: nextModels, workspace: nextWorkspace }
}

/**
 * 取消节点关联。
 */
export function clearFittingModelFromNode(
  models: FittingModel[],
  workspace: CanvasWorkspace,
  nodeId: string
): { models: FittingModel[]; workspace: CanvasWorkspace } {
  return assignFittingModelToNode(models, workspace, nodeId, '')
}
