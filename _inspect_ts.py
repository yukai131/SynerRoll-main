import sqlite3
import json
from pathlib import Path

base = Path(r"backend\data\tasks")
for task_dir in sorted(base.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
    if not task_dir.is_dir():
        continue
    db = task_dir / "timeseries.db"
    if not db.exists():
        continue
    print("=" * 80)
    print("TASK", task_dir.name, "mtime", task_dir.stat().st_mtime)
    conn = sqlite3.connect(str(db))
    cur = conn.cursor()
    try:
        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [r[0] for r in cur.fetchall()]
        print("tables:", tables)
        if "time_series_meta" in tables:
            cur.execute(
                "SELECT id, source_id, var_name, remark, layer_id FROM time_series_meta ORDER BY var_name"
            )
            rows = cur.fetchall()
            print("meta count", len(rows))
            for r in rows:
                print(" ", r)
        # also dump mapping + connection briefly
        for name in ("mapping.json", "connection.json"):
            p = task_dir / name
            if p.exists():
                data = json.loads(p.read_text(encoding="utf-8"))
                if name == "connection.json":
                    print("connection buses:")
                    for b in data:
                        print(
                            " ",
                            b.get("busLabel"),
                            b.get("busCode"),
                            "vars:",
                            b.get("variables"),
                        )
                else:
                    print("mapping:")
                    for m in data:
                        print(" ", m.get("componentName"), m.get("code"), m.get("componentKey"))
    except Exception as e:
        print("ERR", e)
    finally:
        conn.close()
