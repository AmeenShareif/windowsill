"""Turns the ChatGPT paintings (windowsill-<theme>-<light>.png) into the app's wallpapers.

Usage: python scripts/import-paintings.py <folder with the PNGs>
Writes Resources/Wallpapers/<theme>-<light>.jpg at full size and keeps the PNGs in art-src/.
"""
import shutil
import sys
from pathlib import Path

from PIL import Image

THEMES = ["winter", "rain", "stars", "fireflies", "autumn", "spring"]
LIGHTS = ["day", "evening", "night"]

root = Path(__file__).resolve().parent.parent
src = Path(sys.argv[1])
out = root / "Resources" / "Wallpapers"
keep = root / "art-src"
out.mkdir(parents=True, exist_ok=True)
keep.mkdir(exist_ok=True)

missing = []
for theme in THEMES:
    for light in LIGHTS:
        png = src / f"windowsill-{theme}-{light}.png"
        if not png.exists():
            png = keep / png.name
        if not png.exists():
            missing.append(png.name)
            continue
        img = Image.open(png).convert("RGB")
        assert img.width >= 1500, f"{png.name} is only {img.width} px wide"
        jpg = out / f"{theme}-{light}.jpg"
        img.save(jpg, quality=90, optimize=True, progressive=True)
        if png.parent != keep:
            shutil.move(str(png), keep / png.name)
        print(f"{jpg.name}: {img.width}x{img.height}, {jpg.stat().st_size // 1024} KB")

print(f"missing: {missing}" if missing else "all 18 paintings imported")
sys.exit(1 if missing else 0)
