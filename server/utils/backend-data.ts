import { existsSync } from 'node:fs'
import { join } from 'node:path'

/**
 * 统一 backend/data 根目录解析（与 Julia BACKEND_DATA_DIR 对齐）。
 * 优先级：SYNERROLL_DATA_DIR → cwd/backend/data → cwd/../backend/data
 * Node 建/拷/删 boundary.db 与 Julia 读写必须指向同一棵树。
 */
export function backendDataDir(): string {
  if (process.env.SYNERROLL_DATA_DIR) return process.env.SYNERROLL_DATA_DIR
  const candidates = [
    process.env.SYNERROLL_DATA_DIR,
    join(process.cwd(), 'backend', 'data'),
    join(process.cwd(), '..', 'backend', 'data')
  ].filter(Boolean) as string[]

  for (const dir of candidates) {
    // 有任一已知库文件或 projects 目录即认定为数据根
    if (existsSync(join(dir, 'tasks.db')) || existsSync(join(dir, 'projects')) || existsSync(join(dir, 'capacity-planning.db'))) {
      return dir
    }
  }
  return join(process.cwd(), 'backend', 'data')
}

export function projectsBoundaryRoot(): string {
  return join(backendDataDir(), 'projects')
}
