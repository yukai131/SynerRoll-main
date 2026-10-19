import { juliaUrl } from '#server/utils/julia'
import type {
  ApplyCapacityPlanningRequest,
  ApplyCapacityPlanningResult,
  CapacityApplyRecord,
  CapacityApplyVariableChange,
  CapacityPlanningResult,
  CapacityPlanningTask
} from '~~/types/capacity-planning'
import type { CanvasData } from '~~/types/canvas'

import { apiSuccess } from '#server/utils/response'
import { insertApply, updateApply } from '#server/utils/apply-store'
import { updateProject } from '#server/utils/project-store'
import { resolveCapacityHistoryWindow } from '#server/utils/capacity-history-window'

const JULIA_CAPACITY_URL = juliaUrl('/api/capacity-planning')
const JULIA_TASK_URL = juliaUrl('/api/task/create')

// C-406 安全应用：应用前快照与变更校验全部在单个 updateProject 事务内完成，
// 任何一步失败都不会留下部分修改；写库成功后再落应用记录（含撤销所需快照）。
export default defineEventHandler(async (event) => {
  const planningId = getRouterParam(event, 'id') ?? ''
  const body = await readBody<ApplyCapacityPlanningRequest>(event)
  if (!body.expectedProjectUpdatedAt) {
    throw createError({ statusCode: 400, message: '缺少 expectedProjectUpdatedAt' })
  }
  const target = body.target === 'new-canvas' ? 'new-canvas' as const : 'current-canvas' as const

  const [taskResponse, resultResponse] = await Promise.all([
    $fetch<{ success: boolean; data?: CapacityPlanningTask; message?: string }>(
      `${JULIA_CAPACITY_URL}/${encodeURIComponent(planningId)}`
    ),
    $fetch<{ success: boolean; data?: CapacityPlanningResult; message?: string }>(
      `${JULIA_CAPACITY_URL}/${encodeURIComponent(planningId)}/result`
    )
  ])
  if (!taskResponse.success || !taskResponse.data || taskResponse.data.status !== 'completed') {
    throw createError({ statusCode: 400, message: taskResponse.message || '容量规划任务尚未完成' })
  }
  if (!resultResponse.success || !resultResponse.data) {
    throw createError({ statusCode: 400, message: resultResponse.message || '容量规划结果不存在' })
  }

  const planningTask = taskResponse.data
  const planningResult = resultResponse.data
  // C-406：来源溯源——最优候选的评价 id（Julia 任务记录 bestEvaluationId）
  const candidateId = typeof planningTask.bestEvaluationId === 'number' ? planningTask.bestEvaluationId : null
  // datasetId is historical provenance; current main reads the canvas boundary DB.
  const datasetId = planningTask.config.clustering.datasetId ?? null
  let historyWindow: ReturnType<typeof resolveCapacityHistoryWindow> | undefined

  const changes: CapacityApplyVariableChange[] = []
  let canvasSnapshotBefore: CanvasData | null = null
  let canvasSnapshotAfter: CanvasData | null = null
  let targetCanvasId = ''

  const updatedProject = await updateProject(planningTask.projectId, (current) => {
    if (current.updateTime !== body.expectedProjectUpdatedAt) {
      throw createError({
        statusCode: 409,
        message: `项目已在规划后更新（当前 ${current.updateTime}），请重新规划或确认新版本`
      })
    }

    const next = structuredClone(current)
    const sourceCanvas = next.workspace.canvases.find(item => item.id === planningTask.canvasId)
    if (!sourceCanvas) {
      throw createError({ statusCode: 409, message: '规划画布已不存在，不能应用结果' })
    }
    historyWindow = resolveCapacityHistoryWindow(current, planningTask.canvasId)

    // C-406：目标画布——更新当前画布，或复制出新画布后在新画布上应用
    let targetCanvas: CanvasData
    if (target === 'new-canvas') {
      const clone = structuredClone(sourceCanvas)
      clone.id = crypto.randomUUID()
      clone.name = (body.newCanvasName ?? '').trim() || `${sourceCanvas.name}-容量方案`
      clone.updatedAt = new Date().toISOString()
      next.workspace.canvases.push(clone)
      targetCanvas = clone
    }
    else {
      targetCanvas = sourceCanvas
    }
    targetCanvasId = targetCanvas.id
    canvasSnapshotBefore = structuredClone(targetCanvas)

    for (const variable of planningResult.variables) {
      const node = targetCanvas.nodes.find(item => item.id === variable.componentId)
      if (!node?.data) {
        throw createError({ statusCode: 409, message: `设备 ${variable.componentName} 已不存在` })
      }
      const business = node.data.business
      if (business.componentKey !== variable.componentKey) {
        throw createError({ statusCode: 409, message: `设备 ${variable.componentName} 的类型已改变` })
      }
      if (typeof business.commonTechParams.capacity !== 'number') {
        throw createError({ statusCode: 409, message: `设备 ${variable.componentName} 的 capacity 已不是数值` })
      }
      changes.push({
        componentId: variable.componentId,
        componentName: variable.componentName,
        unit: variable.unit,
        previousValue: business.commonTechParams.capacity,
        appliedValue: variable.optimalValue
      })
      business.commonTechParams.capacity = variable.optimalValue
    }
    targetCanvas.updatedAt = new Date().toISOString()
    canvasSnapshotAfter = structuredClone(targetCanvas)
    return next
  })
  if (!historyWindow) throw createError({ statusCode: 500, message: '未生成全历史仿真的日期窗口' })
  const { simStartTime, simEndTime, simStartDate, simEndDate } = historyWindow

  // C-406：应用记录（含撤销/恢复快照与来源）。记录落库失败不阻断应用结果，但提示撤销不可用。
  const applyId = crypto.randomUUID()
  let recordWarning = ''
  try {
    const record: CapacityApplyRecord = {
      applyId,
      planningId: planningTask.id,
      planningTaskId: planningTask.id,
      candidateId,
      projectId: planningTask.projectId,
      sourceCanvasId: planningTask.canvasId,
      targetCanvasId,
      target,
      newCanvasName: target === 'new-canvas' ? (body.newCanvasName ?? '').trim() || undefined : undefined,
      changes,
      status: 'applied',
      projectUpdatedAtBefore: body.expectedProjectUpdatedAt,
      projectUpdatedAtApplied: updatedProject.updateTime,
      projectUpdatedAtUndone: null,
      canvasUpdatedAtApplied: canvasSnapshotAfter!.updatedAt,
      canvasUpdatedAtUndone: null,
      canvasSnapshotBefore,
      canvasSnapshotAfter,
      taskId: null,
      datasetId,
      simStartTime,
      simEndTime,
      simStartDate,
      simEndDate,
      createdAt: new Date().toISOString(),
      undoneAt: null
    }
    await insertApply(record)
  }
  catch (error) {
    recordWarning = `应用记录保存失败，撤销不可用：${error instanceof Error ? error.message : String(error)}`
  }

  const baseResult = {
    projectApplied: true,
    projectUpdatedAt: updatedProject.updateTime,
    applyId,
    targetCanvasId,
    target,
    sourceCandidateId: candidateId,
    boundarySource: 'full-history' as const,
    datasetId,
    simStartTime,
    simEndTime,
    simStartDate,
    simEndDate,
    boundaryTailPolicy: 'cycle-window-lookahead' as const
  }
  try {
    const computeResponse = await $fetch<{
      success: boolean
      data?: Record<string, unknown>
      message?: string
    }>(JULIA_TASK_URL, {
      method: 'POST',
      body: {
        projectId: updatedProject.id,
        // C-406：新画布模式把容量变更与验证仿真都指向新画布
        canvasId: targetCanvasId,
        layerId: planningTask.config.planningLayerId,
        mode: body.mode || 'offline',
        simStartTime,
        simEndTime,
        simStartDate,
        simEndDate,
        name: body.name || '容量规划最优解全历史仿真',
        boundarySource: 'full-history',
        datasetId,
        boundaryTailPolicy: 'cycle-window-lookahead',
        projectJson: {
          ...updatedProject,
          workspace: { ...updatedProject.workspace, activeCanvasId: targetCanvasId }
        }
      }
    })
    const taskCreated = Boolean(computeResponse.success && computeResponse.data)
    const taskId = taskCreated && typeof computeResponse.data?.id === 'string' ? computeResponse.data.id : null
    if (taskId) {
      // 记录回填验证任务 id（失败仅记警告，不影响响应）
      updateApply(applyId, record => ({ ...record, taskId })).catch(() => undefined)
    }
    return apiSuccess<ApplyCapacityPlanningResult>({
      ...baseResult,
      taskCreated,
      taskId,
      message: recordWarning || (!taskCreated ? (computeResponse.message || '容量已应用，但创建仿真任务失败') : undefined)
    })
  }
  catch (error) {
    return apiSuccess<ApplyCapacityPlanningResult>({
      ...baseResult,
      taskCreated: false,
      taskId: null,
      message: recordWarning || `容量已应用，但创建仿真任务失败：${error instanceof Error ? error.message : String(error)}`
    })
  }
})
