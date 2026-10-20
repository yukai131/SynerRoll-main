import re
from pathlib import Path

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")
pattern = re.compile(
    r"'price'|\"price\"|BOUNDARY_MEANING|flex_up|buy_price|sell_price|fuel_price"
)

for path in root.rglob("*"):
    if path.suffix.lower() not in {".ts", ".vue", ".jl", ".json", ".md"}:
        continue
    if any(part in path.parts for part in ("node_modules", ".nuxt", ".output", "data", "scripts")):
        continue
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        if pattern.search(line):
            hits.append(f"{i}:{line.strip()[:140]}")
    if hits:
        print("==", path.relative_to(root))
        print("\n".join(hits[:20]))
        print()
