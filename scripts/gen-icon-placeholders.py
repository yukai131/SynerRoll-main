from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DEVICE_DIR = ROOT / "public" / "icons" / "device"
DEVICE_DIR.mkdir(parents=True, exist_ok=True)

DEVICES = {
    "wind-turbine": ((239, 248, 255), (21, 94, 239), "WT"),
    "solar-panel": ((240, 253, 244), (18, 183, 106), "PV"),
    "hydro": ((239, 246, 255), (37, 99, 235), "HY"),
    "grid": ((245, 243, 255), (124, 58, 237), "GRID"),
    "gas-plant": ((255, 247, 237), (249, 115, 22), "CP"),
    "coal-plant": ((255, 241, 240), (220, 38, 38), "GP"),
    "chp": ((255, 247, 232), (245, 158, 11), "CHP"),
    "battery": ((255, 241, 242), (225, 29, 72), "ES"),
    "fuel-storage": ((243, 240, 255), (139, 92, 246), "FS"),
    "air-storage": ((224, 242, 254), (2, 132, 199), "CS"),
    "water-storage": ((224, 242, 254), (14, 165, 233), "PS"),
    "hydrogen-storage": ((240, 253, 250), (13, 148, 136), "HS"),
    "electrolyzer": ((247, 254, 231), (101, 163, 13), "ET"),
    "load": ((240, 249, 255), (2, 132, 199), "ELOAD"),
    "hydrogen-load": ((240, 253, 250), (15, 118, 110), "HLOAD"),
    "heat-load": ((255, 247, 237), (234, 88, 12), "QLOAD"),
    "bus-electric": ((238, 244, 255), (21, 94, 239), "EBUS"),
    "bus-thermal": ((255, 244, 237), (249, 115, 22), "TBUS"),
    "bus-hydrogen": ((236, 253, 243), (18, 183, 106), "H2BUS"),
}


def load_font(size: int):
    for name in ("arial.ttf", "segoeui.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_placeholder(path: Path, size: int, bg, accent, label: str, title: str) -> None:
    img = Image.new("RGBA", (size, size), bg + (255,))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [8, 8, size - 9, size - 9],
        radius=max(12, size // 12),
        outline=accent + (255,),
        width=max(3, size // 64),
    )
    cx = size // 2
    cy = size // 2 - size // 16
    r = size // 5
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=accent + (255,), width=max(3, size // 48))
    d.rectangle(
        [cx - max(3, size // 20), cy + r + 4, cx + max(3, size // 20), cy + r + size // 10],
        fill=accent + (255,),
    )

    font = load_font(max(14, size // 10))
    font_small = load_font(max(11, size // 14))

    bbox = d.textbbox((0, 0), label, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text(((size - tw) / 2, size - th - size // 8), label, fill=accent + (255,), font=font)

    bbox2 = d.textbbox((0, 0), title, font=font_small)
    tw2 = bbox2[2] - bbox2[0]
    d.text(((size - tw2) / 2, size // 10), title, fill=(102, 112, 133, 255), font=font_small)

    img.save(path, "PNG")
    print(f"wrote {path} {img.size}")


def main() -> None:
    for name, (bg, accent, label) in DEVICES.items():
        make_placeholder(DEVICE_DIR / f"{name}.png", 512, bg, accent, label, name)

    make_placeholder(ROOT / "public" / "logo.png", 512, (21, 94, 239), (255, 255, 255), "SynerRoll", "LOGO")
    make_placeholder(
        ROOT / "packaging" / "resources" / "icon-256.png",
        256,
        (21, 94, 239),
        (255, 255, 255),
        "SR",
        "APP",
    )
    print(f"done: {len(DEVICES)} devices + logo + app icon")


if __name__ == "__main__":
    main()
