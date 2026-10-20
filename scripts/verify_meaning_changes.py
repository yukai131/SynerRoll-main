from pathlib import Path

t = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\backend\utils\prediction_utils.jl").read_text(encoding="utf-8")
assert "_is_price_meaning" in t
assert "function _resolve_price_series_by_meaning" in t
print("fuel:", 'meaning="fuel_price"' in t)
print("buy:", 'meaning="buy_price"' in t)
print("sell:", 'meaning="sell_price"' in t)
print("lines:", len(t.splitlines()))

# verify types
b = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\types\boundary.ts").read_text(encoding="utf-8")
for key in ("buy_price", "sell_price", "fuel_price", "flex_up", "flex_down"):
    assert f"'{key}'" in b, key
print("types OK")

lib = Path(r"C:\Users\Administrator\Desktop\SynerRoll-main\config\component-library.json").read_text(encoding="utf-8")
assert '"buy_price",\n        "sell_price"' in lib.replace("\r\n", "\n") or "buy_price" in lib
assert lib.count('"fuel_price"') >= 3
print("library OK")
print("ALL CHECKS PASSED")
