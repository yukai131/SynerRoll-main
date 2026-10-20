import type { Project, ProjectSummary } from '~~/types/project'
import { DEFAULT_LAYER_CONFIG } from '~~/types/simulation'

import { createInitialWorkspace, normalizeCanvasBusNodes } from './canvas'
import { deepClone } from './clone'
import { createId } from './id'

export const createEmptyProject = (name: string, description?: string): Project => {
  const workspace = createInitialWorkspace()

  return {
    id: createId('project'),
    name,
    createTime: new Date().toISOString(),
    updateTime: new Date().toISOString(),
    description,
    owner: 'LYDL',
    favorite: false,
    tags: ['综合能源'],
    status: 'draft',
    workspace,
    layerConfig: deepClone(DEFAULT_LAYER_CONFIG),
    boundaries: [],
    fittingModels: [],
    algorithm: {
      electricityLoadPrediction: 'None',
      windTurbinePrediction: 'None',
      optimizationAlgorithm: 'MILP',
      solver: 'HiGHS',
      slackEnabled: false,
      shortagePenalty: 1000,
      excessPenalty: 50
    },
    solverConfig: {
      tolerance: 0.0001,
      maxIteration: 500,
      threadCount: 8,
      warmStart: true
    }
  }
}

export const normalizeProject = (project: Project): Project => {
  const workspace = project.workspace?.canvases?.length ? project.workspace : createInitialWorkspace()
  const algorithm = project.algorithm ?? {} as Partial<Project['algorithm']>
  const normalizedWorkspace = {
    ...workspace,
    canvases: workspace.canvases.map(canvas => normalizeCanvasBusNodes(canvas))
  }

  return {
    ...project,
    workspace: normalizedWorkspace,
    algorithm: {
      ...algorithm,
      electricityLoadPrediction: algorithm.electricityLoadPrediction ?? 'None',
      windTurbinePrediction: algorithm.windTurbinePrediction ?? 'None',
      optimizationAlgorithm: algorithm.optimizationAlgorithm ?? 'MILP',
      slackEnabled: algorithm.slackEnabled ?? false,
      shortagePenalty: algorithm.shortagePenalty ?? algorithm.slackPenalty ?? 1000,
      excessPenalty: algorithm.excessPenalty ?? algorithm.slackPenalty ?? 50,
      solver: (algorithm.solver === 'HiGHS' || algorithm.solver === 'COPT') ? algorithm.solver : 'HiGHS'
    }
  }
}

export const buildProjectSummary = (project: Project): ProjectSummary => {
  const activeCanvas = project.workspace?.canvases?.find(c => c.id === project.workspace?.activeCanvasId)
    ?? project.workspace?.canvases?.[0]

  return {
    id: project.id,
    name: project.name,
    createTime: project.createTime,
    updateTime: project.updateTime,
    description: project.description,
    favorite: project.favorite,
    tags: project.tags,
    owner: project.owner,
    status: project.status,
    nodeCount: activeCanvas?.nodes.length ?? 0,
    edgeCount: activeCanvas?.edges.length ?? 0
  }
}

export const createInitialProjects = (): Project[] => [createEmptyProject('空白项目模板', '用于快速开始新的方案设计')]
