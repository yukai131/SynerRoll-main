from pathlib import Path

fe = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\app\pages\tasks\index.vue").read_text(encoding="utf-8")
idx = 0
while True:
    i = fe.find("if (newTask.requirementSource === 'agc_or_schedule')", idx)
    if i < 0:
        break
    print("==== at", i)
    print(fe[i:i+550])
    print()
    idx = i + 1
