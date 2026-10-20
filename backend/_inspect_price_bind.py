import json
from pathlib import Path

base = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\backend\data\capacity-planning\cp-1f5594fd-4c88-4931-ba59-883ff6fe6b6b")
snap = json.loads((base / "project_snapshot.json").read_text(encoding="utf-8"))
ws = snap.get("workspace") or {}
for c in ws.get("canvases") or []:
    if c.get("id") != ws.get("activeCanvasId"):
        continue
    for n in c.get("nodes") or []:
        data = n.get("data") or {}
        biz = data.get("business") or {}
        key = biz.get("componentKey")
        bids = biz.get("boundaryIds") or []
        print(f"{data.get('label')} ({key}) boundaryIds={bids}")
        eco = biz.get("commonEconomicParams") or {}
        if key in ("GRID", "WT", "PV", "CP"):
            print(f"  scalar eco buy={eco.get('buy_price')} sell={eco.get('sell_price')} "
                  f"fuel={eco.get('fuel_price')} cut={eco.get('cut_cost')} om={eco.get('om_cost')}")

print("=" * 60, "boundary meaning labels from scenarios.json")
sc = json.loads((base / "scenarios.json").read_text(encoding="utf-8"))
# followIds and allBoundaryIds
cfg = sc.get("config") or {}
print("followIds", cfg.get("followIds"))
print("allBoundaryIds", cfg.get("allBoundaryIds"))
print("featureIds", cfg.get("featureIds"))

# scenario series meanings
import sqlite3
con = sqlite3.connect(str(base / "scenarios.db"))
cur = con.cursor()
print("scenario_series boundaries:")
for row in cur.execute("SELECT DISTINCT boundary_id FROM scenario_series ORDER BY boundary_id"):
    print(" ", row[0])
con.close()

# timeseries planned labels for prices
db = base / "work" / "7dd3ecba9ddd7867" / "scenarios" / "scenario-1" / "timeseries.db"
con = sqlite3.connect(str(db))
cur = con.cursor()
print("price-like series in scenario timeseries:")
for row in cur.execute("SELECT source_id, var_name, remark FROM time_series_meta WHERE var_name LIKE '%price%' OR var_name LIKE '%fuel%' ORDER BY source_id"):
    print(" ", row)
    sid = cur.execute("SELECT id FROM time_series_meta WHERE source_id=? AND var_name=? AND remark=?",
                      row).fetchone()
    if sid:
        vals = [v[0] for v in cur.execute(
            "SELECT value FROM time_series_data WHERE series_id=? AND ts_min>=0 AND ts_min<1440 ORDER BY ts_min",
            (sid[0],)).fetchall()]
        print(f"    n={len(vals)} first5={vals[:5]} sum={sum(vals):.3f}")
con.close()

print("=" * 60, "model.jl GRID price lines")
mj = (base / "work" / "7dd3ecba9ddd7867" / "scenarios" / "scenario-1" / "model.jl").read_text(encoding="utf-8")
for i, line in enumerate(mj.splitlines(), 1):
    if "C_grid" in line or "buy" in line.lower() or "sell" in line.lower() or "C_cp_fuel" in line:
        print(f"{i}: {line[:220]}")
