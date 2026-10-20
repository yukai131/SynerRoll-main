from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")

p = root / "app" / "pages" / "tasks" / "index.vue"
text = p.read_text(encoding="utf-8")
text2 = text.replace(
    "return !boundary || boundary.meaning === want || boundary.meaning === 'price'",
    "return !boundary || boundary.meaning === want",
)
assert text2 != text, "optionsFor still has price"
p.write_text(text2, encoding="utf-8")
print("optionsFor cleaned")

lib = (root / "config" / "component-library.json").read_text(encoding="utf-8")
for key in ("fuel_price", "buy_price", "sell_price", '"price"'):
    print(key, lib.count('"%s"' % key.strip('"')) if key != '"price"' else lib.count('"price"'))
for m in re.finditer(r'"boundaryKey": \[[^\]]+\]', lib):
    print(re.sub(r"\s+", " ", m.group(0)))
