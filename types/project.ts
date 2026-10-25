import type { LayerConfigSet } from './simulation'
import type { BoundaryItem } from './boundary'
import type { FittingModel } from './fitting'
import type { AlgorithmConfig, SolverConfig } from './simulation'

export type ProjectLifecycle = 'draft' | 'configured' | 'running' | 'completed'

export interface Project {
  id: string
  name: string
  createTime: string
  updateTime: string
  description?: string
  owner: string
  favorite: boolean
  tags: string[]
  status: ProjectLifecycle
  // 画布配置（节点的参数及节点间连接关系）
  workspace: import('./canvas').CanvasWorkspace
  // 时层配置
  layerConfig: LayerConfigSet
  // 边界配置
  boundaries: BoundaryItem[]
  /** 边界配置/时序最近一次变更时间（容量规划过期检测用） */
  boundariesUpdatedAt?: string
  // 设备参数拟合机型（项目级，可被多个组件引用）
  fittingModels?: FittingModel[]
  // 算法配置
  algorithm: AlgorithmConfig
  // 求解器配置
  solverConfig: SolverConfig
}

export interface ProjectSummary {
  id: string
  name: string
  createTime: string
  updateTime: string
  description?: string
  favorite: boolean
  tags: string[]
  owner: string
  status: ProjectLifecycle
  nodeCount: number
  edgeCount: number
}
