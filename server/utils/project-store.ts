import { copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { DatabaseSync } from 'node:sqlite'
import { join } from 'node:path'

import type { Project } from '~~/types/project'
import { createInitialProjects, normalizeProject } from '~~/utils/project-factory'
import { cloneCanvasWithFreshIds } from '~~/utils/canvas'
import { deepClone } from '~~/utils/clone'
import { createBoundaryId, createId } from '~~/utils/id'

const dataDirectory = join(process.cwd(), 'server', 'data')
const dataFile = join(dataDirectory, 'projects.json')

// 项目 boundary 时序数据库目录：backend/data/projects/<project_id>/boundary.db
// 由计算任务方案阶段 0 引入，每个项目独立一份
const projectsBoundaryRoot = join(process.cwd(), '..', 'backend', 'data', 'projects')

// Serialize store access so requests never read a half-written JSON file.
let storeOperationQueue: Promise<void> = Promise.resolve()

const withStoreLock = async <T>(operation: () => Promise<T>): Promise<T> => {
  const nextOperation = storeOperationQueue.then(operation, operation)
  storeOperationQueue = nextOperation.then(() => undefined, () => undefined)
  return nextOperation
}

const buildSeedProjects = (): Project[] =>
  createInitialProjects().map(project => normalizeProject(project))

const writeProjectsUnlocked = async (projects: Project[]): Promise<void> => {
  await mkdir(dataDirectory, { recursive: true })
  const jsonStr = JSON.stringify(projects, null, 2)
  // console.log(`[STORE] writing projects.json: ${(jsonStr.length / 1024).toFixed(1)} KB, projects=${projects.length}`)
  for (const p of projects) {
    const boundaryBytes = JSON.stringify(p.boundaries ?? []).length
    if (boundaryBytes > 10000) {
      // console.log(`[STORE]   project ${p.id} boundaries JSON: ${(boundaryBytes / 1024).toFixed(1)} KB, count=${(p.boundaries ?? []).length}`)
      for (const b of (p.boundaries ?? [])) {
        const bAny = b as any
        const rawLen = bAny.rawData?.values?.length ?? 0
        const transLayers = bAny.transformedData?.layers ?? []
        if (rawLen > 100 || transLayers.length > 0) {
          const transPoints = transLayers.reduce((s: number, l: any) => s + (l.values?.length ?? 0), 0)
          // console.log(`[STORE]     boundary ${b.id} rawData=${rawLen}pts transformedData=${transPoints}pts layers=${transLayers.length}`)
        }
      }
    }
  }
  await writeFile(dataFile, jsonStr, 'utf8')
  // console.log(`[STORE] projects.json written OK`)
}

// 确保某项目的 boundary 时序库文件存在（空文件即可，Julia 后端打开时会自动建表）
const ensureProjectBoundaryDb = async (projectId: string): Promise<void> => {
  const dir = join(projectsBoundaryRoot, projectId)
  await mkdir(dir, { recursive: true })
  const dbPath = join(dir, 'boundary.db')
  // touch 空文件：仅当文件不存在时创建；存在则跳过
  try {
    await readFile(dbPath)
  }
  catch (error) {
    const isMissing = typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT'
    if (!isMissing) throw error
    await writeFile(dbPath, '', 'utf8')
  }
}

// 删除某项目的整个 boundary 目录（含 boundary.db 和未来可能扩展的文件）
const removeProjectBoundaryDb = async (projectId: string): Promise<void> => {
  const dir = join(projectsBoundaryRoot, projectId)
  await rm(dir, { recursive: true, force: true })
}

// 复制源项目的 boundary 时序库到目标项目；源不存在时确保目标空库可用。
// 必须先 wal_checkpoint(TRUNCATE) 再复制主库，否则 WAL 中未合并数据会丢失。
// boundaryIdMap 非空时，复制后同步改写 source_id / boundary_id，保证副本与源项目边界身份隔离。
const copyProjectBoundaryDb = async (
  sourceProjectId: string,
  targetProjectId: string,
  boundaryIdMap?: Map<string, string>
): Promise<void> => {
  const sourceDb = join(projectsBoundaryRoot, sourceProjectId, 'boundary.db')
  const targetDir = join(projectsBoundaryRoot, targetProjectId)
  const targetDb = join(targetDir, 'boundary.db')
  await mkdir(targetDir, { recursive: true })

  let sourceExists = true
  try {
    await readFile(sourceDb)
  }
  catch (error) {
    const isMissing = typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT'
    if (!isMissing) throw error
    sourceExists = false
  }

  if (!sourceExists) {
    await ensureProjectBoundaryDb(targetProjectId)
    return
  }

  // 把 WAL 内容合并进主库，保证 copyFile 拿到完整数据
  const source = new DatabaseSync(sourceDb)
  try {
    source.exec('PRAGMA wal_checkpoint(TRUNCATE)')
  }
  finally {
    source.close()
  }

  await copyFile(sourceDb, targetDb)
  // 清掉目标侧可能残留的 WAL/SHM，避免与刚复制的主库不一致
  await rm(`${targetDb}-wal`, { force: true })
  await rm(`${targetDb}-shm`, { force: true })

  if (boundaryIdMap && boundaryIdMap.size > 0) {
    const target = new DatabaseSync(targetDb)
    try {
      target.exec('BEGIN IMMEDIATE')
      for (const [oldId, newId] of boundaryIdMap) {
        if (oldId === newId) continue
        target.prepare('UPDATE time_series_meta SET source_id = ? WHERE source_id = ?').run(newId, oldId)
        target.prepare('UPDATE boundary_config SET boundary_id = ? WHERE boundary_id = ?').run(newId, oldId)
      }
      target.exec('COMMIT')
    }
    catch (error) {
      try { target.exec('ROLLBACK') } catch { /* ignore */ }
      throw error
    }
    finally {
      target.close()
    }
  }
}

/**
 * 复制项目内部身份：画布/节点/边全部换新 ID，边界 ID 也换新并同步改写引用。
 * 返回 boundaryIdMap（旧→新）供 boundary.db source_id 改写使用。
 */
const cloneProjectIdentity = (source: Project): { project: Project; boundaryIdMap: Map<string, string> } => {
  const cloned = deepClone(source)
  const boundaryIdMap = new Map<string, string>()
  const remapNodeId = new Map<string, string>()

  // 1. 节点/边/画布：整画布换新 ID，同时建立节点映射
  const canvases = (cloned.workspace?.canvases ?? []).map(canvas => {
    const fresh = cloneCanvasWithFreshIds(canvas)
    canvas.nodes.forEach((oldNode, index) => {
      const newNode = fresh.nodes[index]
      if (newNode) remapNodeId.set(oldNode.id, newNode.id)
    })
    return fresh
  })

  // 2. 边界：换新 ID；relatedComponents 用源项目数据 + 节点映射重写
  const sourceBoundaries = source.boundaries ?? []
  const boundaries = sourceBoundaries.map(boundary => {
    const nextId = createBoundaryId()
    boundaryIdMap.set(boundary.id, nextId)
    return {
      ...deepClone(boundary),
      id: nextId,
      relatedComponents: (boundary.relatedComponents ?? [])
        .map(nodeId => remapNodeId.get(nodeId) ?? nodeId)
        .filter((id, index, arr) => arr.indexOf(id) === index)
    }
  })

  // 3. 节点上的 boundaryIds 同步改写
  const nextCanvases = canvases.map(canvas => ({
    ...canvas,
    nodes: canvas.nodes.map(node => {
      const business = node.data?.business
      if (!business?.boundaryIds?.length) return node
      return {
        ...node,
        data: {
          ...node.data!,
          business: {
            ...business,
            boundaryIds: business.boundaryIds
              .map(id => boundaryIdMap.get(id) ?? id)
              .filter((id, index, arr) => arr.indexOf(id) === index)
          }
        }
      }
    })
  }))

  const sourceActiveIndex = (source.workspace?.canvases ?? [])
    .findIndex(c => c.id === source.workspace?.activeCanvasId)

  return {
    project: {
      ...cloned,
      workspace: {
        ...cloned.workspace,
        activeCanvasId: nextCanvases[sourceActiveIndex]?.id ?? nextCanvases[0]?.id ?? '',
        canvases: nextCanvases,
        clipboard: null
      },
      boundaries
    },
    boundaryIdMap
  }
}

const resolveCopyName = (projects: Project[], sourceName: string, preferredName?: string): string => {
  const baseName = preferredName?.trim() || `${sourceName} - 副本`
  const existingNames = new Set(projects.map(project => project.name))

  if (!existingNames.has(baseName)) {
    return baseName
  }

  let suffix = 2
  while (existingNames.has(`${baseName} ${suffix}`)) {
    suffix += 1
  }
  return `${baseName} ${suffix}`
}

const ensureStoreUnlocked = async (): Promise<Project[]> => {
  await mkdir(dataDirectory, { recursive: true })

  let content: string
  try {
    content = await readFile(dataFile, 'utf8')
  }
  catch (error) {
    const isMissingFile = typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT'

    if (isMissingFile) {
      const projects = buildSeedProjects()
      await writeProjectsUnlocked(projects)
      return projects
    }

    throw createError({
      statusCode: 500,
      statusMessage: `Failed to read project store: ${dataFile}`,
      data: {
        cause: error instanceof Error ? error.message : String(error)
      }
    })
  }

  const trimmedContent = content.trim()
  if (!trimmedContent) {
    throw createError({
      statusCode: 500,
      statusMessage: `Project store is empty: ${dataFile}`
    })
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmedContent)
  }
  catch (error) {
    throw createError({
      statusCode: 500,
      statusMessage: `Project store is corrupted. Refusing to overwrite ${dataFile}.`,
      data: {
        cause: error instanceof Error ? error.message : String(error)
      }
    })
  }

  if (!Array.isArray(parsed)) {
    throw createError({
      statusCode: 500,
      statusMessage: `Project store must be an array: ${dataFile}`
    })
  }

  return parsed.map(project => normalizeProject(project as Project))
}

export const readProjects = async (): Promise<Project[]> =>
  withStoreLock(() => ensureStoreUnlocked())

export const writeProjects = async (projects: Project[]): Promise<void> => {
  await withStoreLock(() => writeProjectsUnlocked(projects))
}

export const readProjectById = async (projectId: string): Promise<Project> => {
  const projects = await readProjects()
  const project = projects.find(item => item.id === projectId)

  if (!project) {
    throw createError({ statusCode: 404, statusMessage: `Project ${projectId} not found` })
  }

  return normalizeProject(project)
}

export const updateProject = async (
  projectId: string,
  updater: (project: Project) => Project
): Promise<Project> =>
  withStoreLock(async () => {
    const projects = await ensureStoreUnlocked()
    const projectIndex = projects.findIndex(project => project.id === projectId)

    if (projectIndex === -1) {
      throw createError({ statusCode: 404, statusMessage: `Project ${projectId} not found` })
    }

    const nextProject = updater(normalizeProject(projects[projectIndex]!))
    const persistedProject = {
      ...nextProject,
      updateTime: new Date().toISOString()
    }

    const nextProjects = [...projects]
    nextProjects[projectIndex] = persistedProject

    await writeProjectsUnlocked(nextProjects)

    return normalizeProject(persistedProject)
  })

export const createProjectRecord = async (project: Project): Promise<Project> =>
  withStoreLock(async () => {
    const normalizedProject = normalizeProject(project)
    const projects = await ensureStoreUnlocked()
    const nextProjects = [...projects, normalizedProject]

    await writeProjectsUnlocked(nextProjects)

    // 计算任务方案：项目创建时自动建立 boundary 时序库目录 + 空 DB 文件
    await ensureProjectBoundaryDb(normalizedProject.id)

    return normalizedProject
  })

/**
 * 复制项目：深拷贝全部项目配置（画布/时层/边界元数据/算法/求解器），
 * 重生成项目/画布/节点/边/边界 ID，并同步复制 boundary 时序库。
 */
export const copyProjectRecord = async (projectId: string, preferredName?: string): Promise<Project> =>
  withStoreLock(async () => {
    const projects = await ensureStoreUnlocked()
    const sourceProject = projects.find(project => project.id === projectId)

    if (!sourceProject) {
      throw createError({ statusCode: 404, statusMessage: `Project ${projectId} not found` })
    }

    const normalizedSource = normalizeProject(sourceProject)
    const now = new Date().toISOString()
    const { project: identityProject, boundaryIdMap } = cloneProjectIdentity(normalizedSource)
    const copiedProject = normalizeProject({
      ...identityProject,
      id: createId('project'),
      name: resolveCopyName(projects, normalizedSource.name, preferredName),
      createTime: now,
      updateTime: now
    })

    const nextProjects = [...projects, copiedProject]
    await writeProjectsUnlocked(nextProjects)
    await copyProjectBoundaryDb(projectId, copiedProject.id, boundaryIdMap)

    return copiedProject
  })

export const removeProject = async (projectId: string): Promise<void> =>
  withStoreLock(async () => {
    const projects = await ensureStoreUnlocked()
    const nextProjects = projects.filter(project => project.id !== projectId)

    await writeProjectsUnlocked(nextProjects)

    // 删除项目对应的 boundary 时序库目录
    await removeProjectBoundaryDb(projectId)
  })