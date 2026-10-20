from pathlib import Path

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")
fe = (root / "app/pages/tasks/index.vue").read_text(encoding="utf-8")
svc = (root / "backend/services/flexibility_evaluation_service.jl").read_text(encoding="utf-8")

assert "newTask.requirementSource !== 'agc_or_schedule'" in fe
assert "targetPoiPowerBoundaryId = newTask.targetBoundaryId" in fe
assert "请选择目标并网功率边界曲线" in fe

# buildFlexibilityTaskConfig AGC branch
i = fe.find("const buildFlexibilityTaskConfig")
assert i > 0
agc_block = fe[i:].split("if (newTask.requirementSource === 'agc_or_schedule')")[1].split("else if")[0]
assert "targetPoiPowerKw" not in agc_block
assert "targetPoiPowerBoundaryId" in agc_block

# UI: constant/file radios hidden for AGC
assert "newTask.requirementSource !== 'agc_or_schedule'" in fe
assert 'mode="boundary"' in fe  # AGC editor forced boundary

assert "targetPoiPowerBoundaryId is required for agc_or_schedule" in svc
agc_norm = svc.split("if requirement_source == FLEXIBILITY_REQUIREMENT_AGC_SCHEDULE")[1].split("elseif")[0]
assert "targetPoiPowerKw" not in agc_norm
assert 'row["targetPoiPowerBoundaryId"]' in svc

print("AGC boundary-only: ALL PASSED")
