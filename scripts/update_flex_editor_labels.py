from pathlib import Path

p = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\app\components\FlexibilityTimeSeriesEditor.vue")
text = p.read_text(encoding="utf-8")
text = text.replace("请选择计划/AGC曲线", "请选择边界曲线")
text = text.replace("当前时层没有可用功率曲线", "当前时层没有可用边界曲线")
p.write_text(text, encoding="utf-8")
print("FlexibilityTimeSeriesEditor labels updated")
