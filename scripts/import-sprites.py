"""Cuts the ChatGPT sprite sheets (windowsill-sprites-<sheet>.png, transparent) into the app's sprites.

Usage: python scripts/import-sprites.py <folder with the sheets>
Each sheet's objects are found as separate blobs of opaque pixels, ordered row by row, left to right,
trimmed, and written to Resources/Sprites/<name>.png. The sheets are kept in art-src/.
"""
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageFilter

# sheet -> (objects per row, names in reading order, longest side of its largest piece in px, mirror?,
#           may an opaque copy be keyed out? -- only where no object has white at its rim)
SHEETS = {
    "decor": ([4, 4, 4, 4], ["snowman", "snowball", "star", "cane",
                             "bauble-0", "bauble-1", "bauble-2", "bauble-3",
                             "bauble-4", "bauble-5", "present-0", "present-1",
                             "present-2", "present-3", "present-4", "present-5"], 256, False, False),
    "santa": ([3], ["sleigh", "deer-0", "deer-1"], 384, False, False),
    "yeti": ([2, 2], ["yeti-0", "yeti-1", "yeti-carry-0", "yeti-carry-1"], 320, False, False),
    "train": ([4], ["locomotive", "wagon", "wheel", "elf"], 384, False, False),
    "nature": ([4, 2], ["leaf-0", "leaf-1", "leaf-2", "leaf-3", "petal-0", "petal-1"], 128, False, True),
    "tree": ([1], ["tree"], 640, False, False),
}
CELL = 8          # blob search runs on an 8x smaller mask
SOLID = 40        # alpha above this counts as part of an object


def blobs(alpha: Image.Image) -> list[tuple[int, int, int, int]]:
    """Bounding boxes (full-size pixels) of the separate objects, nearby specks merged in."""
    w, h = alpha.size
    small = alpha.point(lambda a: 255 if a > SOLID else 0).reduce(CELL)   # any solid pixel marks the cell
    sw, sh = small.size
    on = [[small.getpixel((x, y)) > 0 for x in range(sw)] for y in range(sh)]
    seen = [[False] * sw for _ in range(sh)]
    out = []
    for y0 in range(sh):
        for x0 in range(sw):
            if not on[y0][x0] or seen[y0][x0]:
                continue
            stack, box = [(x0, y0)], [x0, y0, x0, y0]
            seen[y0][x0] = True
            while stack:
                x, y = stack.pop()
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                for dx in (-2, -1, 0, 1, 2):          # reach two cells: twigs and sparkles join their object
                    for dy in (-2, -1, 0, 1, 2):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < sw and 0 <= ny < sh and on[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True
                            stack.append((nx, ny))
            out.append((box[0] * CELL, box[1] * CELL, min(w, (box[2] + 1) * CELL), min(h, (box[3] + 1) * CELL)))
    return [b for b in out if (b[2] - b[0]) * (b[3] - b[1]) > 900]          # drop stray dust


def key_out(sheet: Image.Image) -> Image.Image:
    """For a sheet that came back opaque (a checkerboard painted in instead of alpha): clear the light,
    colourless background reachable from the edges. Only safe for art with no white parts at its rim."""
    rgb = sheet.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    alpha = Image.new("L", (w, h), 255)
    a = alpha.load()
    stack = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
    while stack:
        x, y = stack.pop()
        if a[x, y] == 0:
            continue
        r, g, b = px[x, y]
        if min(r, g, b) < 228 or max(r, g, b) - min(r, g, b) > 8:
            continue
        a[x, y] = 0
        stack += [(nx, ny) for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)) if 0 <= nx < w and 0 <= ny < h]
    alpha = alpha.filter(ImageFilter.MinFilter(3))       # trim the pale fringe left from the checkerboard
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def reading_order(boxes, rows):
    boxes = sorted(boxes, key=lambda b: (b[1] + b[3]) / 2)
    ordered, i = [], 0
    for n in rows:
        ordered += sorted(boxes[i:i + n], key=lambda b: b[0])
        i += n
    return ordered


def cut(sheet: Image.Image, box, mirror: bool) -> Image.Image:
    piece = sheet.crop(box)
    r, g, b, a = piece.split()
    a = a.point(lambda v: 0 if v < 16 else (255 if v >= 240 else v))   # the generator leaves 250-254 inside
    piece = Image.merge("RGBA", (r, g, b, a))
    piece = piece.crop(piece.getbbox())
    return piece.transpose(Image.FLIP_LEFT_RIGHT) if mirror else piece


def shrink(piece: Image.Image, scale: float) -> Image.Image:
    if scale >= 1:
        return piece
    return piece.resize((max(1, round(piece.width * scale)), max(1, round(piece.height * scale))), Image.LANCZOS)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    src, keep, out = Path(sys.argv[1]), root / "art-src", root / "Resources" / "Sprites"
    keep.mkdir(exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    problems = []
    for sheet_name, (rows, names, longest, mirror, keyable) in SHEETS.items():
        path = src / f"windowsill-sprites-{sheet_name}.png"
        if not path.exists():
            path = keep / path.name
        if not path.exists():
            problems.append(f"{path.name} missing")
            continue
        sheet = Image.open(path)
        if sheet.mode != "RGBA":
            if not keyable:
                problems.append(f"{path.name} has no transparency; ask for it again")
                continue
            print(f"{path.name}: no alpha, keying out the background")
            sheet = key_out(sheet)
        found = blobs(sheet.getchannel("A"))
        if len(found) != len(names):
            problems.append(f"{path.name}: found {len(found)} objects, expected {len(names)}")
            continue
        pieces = [cut(sheet, box, mirror) for box in reading_order(found, rows)]
        # One scale per sheet, so animation frames and parts of one character keep their relative size.
        scale = longest / max(max(p.size) for p in pieces)
        for name, piece in zip(names, pieces):
            piece = shrink(piece, scale)
            piece.save(out / f"{name}.png", optimize=True)
            print(f"{name}.png {piece.width}x{piece.height}")
        if path.parent != keep:
            shutil.move(str(path), keep / path.name)
    for p in problems:
        print("PROBLEM", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
