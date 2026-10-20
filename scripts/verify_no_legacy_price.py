from pathlib import Path
import re

root = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main")
ok = True

def check(cond, msg):
    global ok
    print(("OK  " if cond else "FAIL"), msg)
    if not cond:
        ok = False

# meaning type must not contain bare 'price'
b = (root / "types/boundary.ts").read_text(encoding="utf-8")
type_block = b.split("export type BoundaryMeaning")[1].split("export const")[0]
check("'price'" not in type_block, "no bare 'price' in BoundaryMeaning")
check("价格（旧）" not in b, "no legacy label")
for k in ("buy_price", "sell_price", "fuel_price", "flex_up", "flex_down", "power"):
    check(f"'{k}'" in b, f"meaning {k} present")
check("meaning === 'price'" not in b, "resolve no meaning===price")

bs = (root / "backend/services/boundary_service.jl").read_text(encoding="utf-8")
labels = bs.split("BOUNDARY_MEANING_LABELS")[1].split(")")[0]
check('"price"' not in labels, "backend labels no price")

pu = (root / "backend/utils/prediction_utils.jl").read_text(encoding="utf-8")
check("legacy_prices" not in pu, "no legacy_prices")
check('name in ("buy_price", "sell_price", "fuel_price")' in pu, "price meaning set exact")
check('var_name == "price"' not in pu, "no var_name == price")
check('meaning="power"' in (root / "backend/services/flexibility_evaluation_service.jl").read_text(encoding="utf-8"), "AGC still uses power")

lib = (root / "config/component-library.json").read_text(encoding="utf-8")
check(lib.count('"price"') == 0 or all(x in ("buy_price", "sell_price", "fuel_price") for x in re.findall(r'"([a-z_]*price)"', lib)), "library only typed prices")
check('"fuel_price"' in lib and '"buy_price"' in lib and '"sell_price"' in lib, "library typed price keys")

print("\nRESULT:", "ALL PASSED" if ok else "HAS FAILURES")
raise SystemExit(0 if ok else 1)
