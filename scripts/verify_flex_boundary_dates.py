from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")
ok = True

def check(cond, msg):
    global ok
    print(("OK  " if cond else "FAIL"), msg)
    if not cond:
        ok = False

svc = (root / "backend/services/flexibility_evaluation_service.jl").read_text(encoding="utf-8")
check("target_poi_power_boundary_id" in svc, "config has boundary id fields")
check("function flexibility_boundary_ids" in svc, "flexibility_boundary_ids helper")
check("function _read_flexibility_boundary_value" in svc, "boundary value reader")
check("function _flexibility_requirement_value" in svc, "requirement value resolver")
check('meaning="power"' in svc, "AGC uses meaning=power")
check('meaning="flex_up"' in svc, "up uses flex_up")
check('meaning="flex_down"' in svc, "down uses flex_down")
check("targetPoiPowerBoundaryId" in svc, "normalize accepts boundary id")
# no double end after constructor
check("target_poi_power_boundary_id,\n        upward_requirement_boundary_id,\n        downward_requirement_boundary_id,\n    )\nend\nend" not in svc, "no extra end after constructor")

run = (root / "backend/services/simulation_runner.jl").read_text(encoding="utf-8")
check(run.count("flexibility_boundary_ids(flexibility_config)") >= 2, "seed includes flexibility boundaries")
check(run.count("flexibility_config = flexibility_evaluation_config_from_task(task)") >= 2, "both runners load config")

fe = (root / "app/pages/tasks/index.vue").read_text(encoding="utf-8")
check("targetPoiPowerBoundaryId" in fe, "frontend sends target boundary id")
check("upwardRequirementBoundaryId" in fe, "frontend sends up boundary id")
check("downwardRequirementBoundaryId" in fe, "frontend sends down boundary id")
check("update:boundary-id" in fe, "editor emits boundary id")

ed = (root / "app/components/FlexibilityTimeSeriesEditor.vue").read_text(encoding="utf-8")
check("update:boundaryId" in ed, "editor emits update:boundaryId")
check("props.mode !== 'boundary'" in ed, "skip H:MM check in boundary mode")

api = (root / "types/api.ts").read_text(encoding="utf-8")
check("targetPoiPowerBoundaryId?: string" in api, "api type has boundary ids")

lib = (root / "config/component-library.json").read_text(encoding="utf-8")
check('"buy_price",\n        "sell_price"' in lib or '"buy_price", "sell_price"' in lib.replace("\n", " ").replace("  ", " "), "GRID buy/sell keys")
check(lib.count('"fuel_price"') >= 3, "fuel_price keys on CP/GP/CHP")

b = (root / "types/boundary.ts").read_text(encoding="utf-8")
for k in ("buy_price", "sell_price", "fuel_price", "flex_up", "flex_down"):
    check(f"'{k}'" in b, f"meaning {k}")

print("\nRESULT:", "ALL PASSED" if ok else "HAS FAILURES")
raise SystemExit(0 if ok else 1)
