"""清库脚本：只保留设备/连线拓扑，清空边界、任务、容量规划，并重发内部 ID。

执行后：
- projects.json：保留项目元信息 + 画布拓扑；boundaries=[]；节点 boundaryIds=[]；
  canvas/node/edge ID 全部重生成（消除跨项目/跨画布冲突）
- backend/data/projects/*/boundary.db：重置为空库（只建表）
- backend/data/tasks/*、tasks.db：清空
- backend/data/capacity-planning/*、capacity-planning.db：清空
- server/data/capacity-applies.json：[]
"""
from __future__ import annotations

import json
import shutil
import sqlite3
import uuid
from pathlib import Path

ROOT = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")
PROJECTS_JSON = ROOT / "server" / "data" / "projects.json"
APPLIES_JSON = ROOT / "server" / "data" / "capacity-applies.json"
BACKEND_DATA = ROOT / "backend" / "data"


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4()}"


def new_boundary_id() -> str:
    import random
    import time

    return "b_" + format(int(time.time() * 1000), "x") + "".join(
        random.choices("abcdefghijklmnopqrstuvwxyz0123456789", k=6)
    )


def clean_workspace(workspace: dict) -> dict:
    canvases = workspace.get("canvases") or []
    cleaned_canvases = []
    node_id_map: dict[str, str] = {}

    for canvas in canvases:
        nodes = canvas.get("nodes") or []
        edges = canvas.get("edges") or []
        new_canvas_id = new_id("canvas")

        new_nodes = []
        for node in nodes:
            old_node_id = node.get("id")
            new_node_id = new_id("node")
            if old_node_id:
                node_id_map[old_node_id] = new_node_id

            data = dict(node.get("data") or {})
            business = dict(data.get("business") or {})
            business["boundaryIds"] = []
            # 拟合模型 ID 属于项目级配置，本次只清边界绑定；保留 fittingModelId
            data["business"] = business
            new_node = {**node, "id": new_node_id, "data": data}
            new_nodes.append(new_node)

        new_edges = []
        for edge in edges:
            new_edges.append(
                {
                    **edge,
                    "id": new_id("edge"),
                    "source": node_id_map.get(edge.get("source"), edge.get("source")),
                    "target": node_id_map.get(edge.get("target"), edge.get("target")),
                }
            )

        cleaned_canvases.append(
            {
                **canvas,
                "id": new_canvas_id,
                "nodes": new_nodes,
                "edges": new_edges,
            }
        )

    # activeCanvasId：按原顺序对齐
    old_canvases = canvases
    active_old = workspace.get("activeCanvasId")
    active_new = cleaned_canvases[0]["id"] if cleaned_canvases else ""
    if active_old:
        for idx, c in enumerate(old_canvases):
            if c.get("id") == active_old and idx < len(cleaned_canvases):
                active_new = cleaned_canvases[idx]["id"]
                break

    return {
        **workspace,
        "activeCanvasId": active_new,
        "canvases": cleaned_canvases,
        "clipboard": None,
    }


def reset_boundary_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    # 优先整文件重置；若被服务占用则退化为 SQL 清空
    can_unlink = True
    for suffix in ("", "-wal", "-shm"):
        p = Path(str(db_path) + suffix) if suffix else db_path
        if p.exists():
            try:
                p.unlink()
            except PermissionError:
                can_unlink = False
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        if not can_unlink:
            for table in ("time_series_data", "time_series_meta", "boundary_config", "solve_trace_data", "solve_trace_meta"):
                try:
                    conn.execute(f"DELETE FROM {table}")
                except sqlite3.Error:
                    pass
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS time_series_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id TEXT NOT NULL,
                var_name TEXT NOT NULL,
                remark TEXT NOT NULL DEFAULT 'planned',
                layer_id TEXT NOT NULL,
                created_at TEXT DEFAULT (datetime('now')),
                updated_at TEXT DEFAULT (datetime('now')),
                UNIQUE(source_id, var_name, remark, layer_id)
            );
            CREATE TABLE IF NOT EXISTS time_series_data (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                series_id INTEGER NOT NULL,
                ts INTEGER NOT NULL,
                value REAL,
                FOREIGN KEY(series_id) REFERENCES time_series_meta(id)
            );
            CREATE TABLE IF NOT EXISTS boundary_config (
                boundary_id TEXT PRIMARY KEY,
                boundary_length TEXT,
                boundary_step TEXT,
                day_count INTEGER,
                point_count INTEGER,
                time_mode TEXT NOT NULL DEFAULT 'calendar',
                calendar_start_date TEXT,
                calendar_end_date TEXT,
                created_at TEXT DEFAULT (datetime('now')),
                updated_at TEXT DEFAULT (datetime('now'))
            );
            """
        )
        if not can_unlink:
            try:
                conn.execute("VACUUM")
            except sqlite3.Error:
                pass
        conn.commit()
    finally:
        conn.close()
    print(f"    boundary.db reset ({'unlink' if can_unlink else 'sql-delete'})")


def wipe_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def main() -> None:
    projects = json.loads(PROJECTS_JSON.read_text(encoding="utf-8"))
    print(f"projects: {len(projects)}")

    cleaned = []
    for project in projects:
        pid = project.get("id")
        name = project.get("name")
        workspace = clean_workspace(project.get("workspace") or {})
        node_count = sum(len(c.get("nodes") or []) for c in workspace.get("canvases") or [])
        edge_count = sum(len(c.get("edges") or []) for c in workspace.get("canvases") or [])
        canvas_count = len(workspace.get("canvases") or [])

        next_project = {
            **project,
            "workspace": workspace,
            "boundaries": [],
        }
        # fittingModels 可保留（参数拟合配置，不涉及时序）；relatedComponents 清空避免指向旧节点
        if "fittingModels" in next_project and isinstance(next_project["fittingModels"], list):
            next_project["fittingModels"] = [
                {**m, "relatedComponents": []} if isinstance(m, dict) else m
                for m in next_project["fittingModels"]
            ]
        cleaned.append(next_project)

        db_path = BACKEND_DATA / "projects" / pid / "boundary.db"
        reset_boundary_db(db_path)
        print(
            f"  [topology] {name} ({pid}) canvases={canvas_count} nodes={node_count} edges={edge_count}; boundary.db reset"
        )

    PROJECTS_JSON.write_text(
        json.dumps(cleaned, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"projects.json rewritten: {PROJECTS_JSON}")

    # 任务库
    tasks_db = BACKEND_DATA / "tasks.db"
    if tasks_db.exists():
        conn = sqlite3.connect(tasks_db)
        try:
            conn.execute("DELETE FROM tasks")
            conn.commit()
        finally:
            conn.close()
    wipe_dir(BACKEND_DATA / "tasks")
    print("tasks.db cleared; backend/data/tasks wiped")

    # 容量规划库
    cp_db = BACKEND_DATA / "capacity-planning.db"
    if cp_db.exists():
        conn = sqlite3.connect(cp_db)
        try:
            for table in (
                "planning_results",
                "planning_evaluations",
                "planning_scenarios",
                "planning_tasks",
            ):
                try:
                    conn.execute(f"DELETE FROM {table}")
                except sqlite3.Error:
                    pass
            conn.commit()
        finally:
            conn.close()
    wipe_dir(BACKEND_DATA / "capacity-planning")
    print("capacity-planning.db cleared; backend/data/capacity-planning wiped")

    # 应用记录
    APPLIES_JSON.write_text("[]", encoding="utf-8")
    print("capacity-applies.json reset to []")

    # 二次校验
    projects2 = json.loads(PROJECTS_JSON.read_text(encoding="utf-8"))
    canvas_ids = []
    node_ids = []
    edge_ids = []
    boundary_count = 0
    bound_nodes = 0
    for p in projects2:
        boundary_count += len(p.get("boundaries") or [])
        for c in p.get("workspace", {}).get("canvases") or []:
            canvas_ids.append(c["id"])
            for n in c.get("nodes") or []:
                node_ids.append(n["id"])
                if n.get("data", {}).get("business", {}).get("boundaryIds"):
                    bound_nodes += 1
            for e in c.get("edges") or []:
                edge_ids.append(e["id"])
    print("\n=== verify ===")
    print(f"projects={len(projects2)} boundaries={boundary_count} bound_nodes={bound_nodes}")
    print(f"canvas_ids unique: {len(canvas_ids) == len(set(canvas_ids))} ({len(canvas_ids)})")
    print(f"node_ids unique: {len(node_ids) == len(set(node_ids))} ({len(node_ids)})")
    print(f"edge_ids unique: {len(edge_ids) == len(set(edge_ids))} ({len(edge_ids)})")


if __name__ == "__main__":
    main()
