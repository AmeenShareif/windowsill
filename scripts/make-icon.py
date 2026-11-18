"""Composes the app icon, Resources/AppIcon.png (1024x1024 RGBA), from the bundled paintings.

Usage: python scripts/make-icon.py [--previews DIR]
A winter painting seen through a window, a snow-covered sill across the bottom and a painted character
standing in the drift, on the macOS icon grid: an 824 px rounded square centred on the 1024 canvas, a
soft drop shadow, transparent outside. --previews also writes 128, 32 and 16 px downscales (and 8x
nearest-neighbour blow-ups of the small ones) so the silhouette can be checked at Finder sizes.
build-app.sh turns the PNG into AppIcon.icns with sips and iconutil on the Mac.
"""
import argparse
import math
import random
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "AppIcon.png"

CANVAS = 1024
BODY = 824                      # the rounded square, per Apple's macOS icon grid
ORIGIN = (CANVAS - BODY) // 2
CORNER = 185
SS = 4                          # supersampling for anti-aliased shape edges
SHADOW_DY, SHADOW_BLUR, SHADOW_ALPHA = 14, 18, 0.38

PAINTING = "winter-night.jpg"
CROP = (560, 0, 1460, 900)      # source box: the moon, the peaks and the lantern
VIEW_BLUR = 2.5                 # the view through the glass is a touch out of focus
CHARACTER = "snowman.png"
CHARACTER_H = 560               # height on the 824 body
CHARACTER_CX = 412
SINK = 46                       # how far the character's base sits below the drift's crest

FRAME = 34                      # window frame on the top and sides
SILL_BACK, SILL_FRONT = 640, 676   # the sill's top face, from the glass to its front edge
DRIFT_H = 34                    # drift height at the sides; it piles up round the character
LIP = 24                        # how far the drift's overhang hangs down the sill's front face

WOOD = (128, 80, 46)
FRAME_WOOD = (96, 60, 40)
SNOW_LIT, SNOW_SHADE = (248, 248, 255), (150, 160, 214)
SHADOW_BLUE = (22, 20, 64)


def solid(size, rgb, alpha=255):
    return Image.new("RGBA", size, rgb + (alpha,))


def tinted(mask, rgb, alpha):
    """A layer of one colour whose opacity follows mask, at most alpha."""
    layer = solid(mask.size, rgb)
    layer.putalpha(mask.point(lambda v: v * alpha // 255))
    return layer


def shape(draw_fn, size=(BODY, BODY)):
    """Anti-aliased L mask: draw_fn(draw, s) paints in coordinates scaled by s."""
    big = Image.new("L", (size[0] * SS, size[1] * SS), 0)
    draw_fn(ImageDraw.Draw(big), SS)
    return big.resize(size, Image.LANCZOS)


def grain(size, rgb, seed, spread=0.22):
    """Painted wood: long horizontal streaks of lighter and darker brown."""
    rnd = random.Random(seed)
    layers = []
    for cols, rows in ((3, 9), (10, 40), (28, 120)):
        noise = Image.new("L", (cols, rows))
        noise.putdata([rnd.randint(0, 255) for _ in range(cols * rows)])
        layers.append(noise.resize(size, Image.BICUBIC))
    mask = Image.blend(Image.blend(layers[0], layers[1], 0.45), layers[2], 0.3)
    dark = tuple(int(c * (1 - spread)) for c in rgb)
    light = tuple(min(255, int(c * (1 + spread))) for c in rgb)
    return Image.composite(solid(size, light), solid(size, dark), mask)


def view():
    """The painting through the glass: soft focus, darker towards the edges, a faint reflection."""
    src = Image.open(ROOT / "Resources" / "Wallpapers" / PAINTING).convert("RGB")
    img = src.crop(CROP).resize((BODY, BODY), Image.LANCZOS).filter(ImageFilter.GaussianBlur(VIEW_BLUR))
    img = ImageEnhance.Brightness(img).enhance(0.9).convert("RGBA")
    glow = shape(lambda d, s: d.ellipse((-200 * s, -160 * s, (BODY + 200) * s, (BODY + 240) * s), fill=255))
    img.alpha_composite(tinted(ImageChops.invert(glow.filter(ImageFilter.GaussianBlur(90))), SHADOW_BLUE, 150))
    sheen = shape(lambda d, s: d.polygon([(150 * s, 0), (330 * s, 0), (0, 330 * s), (0, 150 * s)], fill=255))
    img.alpha_composite(tinted(sheen.filter(ImageFilter.GaussianBlur(30)), (255, 255, 255), 22))
    return img


def frame(body):
    """Wooden frame on the top and sides, concentric with the icon's corners, shading the glass."""
    glass = (FRAME, FRAME, BODY - FRAME, SILL_BACK + CORNER)
    hole = shape(lambda d, s: d.rounded_rectangle([v * s for v in glass], radius=(CORNER - FRAME) * s, fill=255))
    wood = ImageChops.invert(hole)
    body.alpha_composite(tinted(ImageChops.offset(wood, 0, 10).filter(ImageFilter.GaussianBlur(12)), SHADOW_BLUE, 190))
    body.paste(grain(body.size, FRAME_WOOD, seed=7, spread=0.16), (0, 0), wood)
    rim = ImageChops.subtract(hole, ImageChops.offset(hole, 0, 3))
    body.alpha_composite(tinted(rim, (255, 220, 170), 70))


def crest(x):
    """y of the drift's top edge: a low ridge that piles up round the character, with a few ripples."""
    t = x / BODY
    pile = 38 * math.exp(-(((x - CHARACTER_CX) / 190) ** 2))
    ripple = 7 * math.sin(t * 2 * math.pi * 2.3 + 0.7) + 4 * math.sin(t * 2 * math.pi * 5.1 + 2.0)
    return SILL_BACK - DRIFT_H - pile - ripple


def overhang(x):
    """y of the overhang's lower edge on the sill's front face, with two short drips."""
    t = x / BODY
    hang = LIP + 6 * math.sin(t * 2 * math.pi * 2.0 + 1.3)
    for centre, width, depth in ((0.24, 0.022, 26), (0.78, 0.018, 18)):
        hang += depth * math.exp(-(((t - centre) / width) ** 2))
    return SILL_FRONT + hang


def snow_fill():
    """Lit on top, falling into lavender shade down the overhang's face, with soft uneven patches."""
    ramp = Image.new("L", (1, BODY))
    lit_until, shade_at = SILL_FRONT - 18, SILL_FRONT + LIP + 10
    ramp.putdata([int(255 * min(1.0, max(0.0, (y - lit_until) / (shade_at - lit_until)))) for y in range(BODY)])
    rnd = random.Random(11)
    patches = Image.new("L", (7, 70))          # wide, shallow: wind-smoothed snow, not blotches
    patches.putdata([rnd.randint(0, 48) for _ in range(7 * 70)])
    ramp = ImageChops.add(ramp.resize((BODY, BODY)), patches.resize((BODY, BODY), Image.BICUBIC).filter(ImageFilter.GaussianBlur(4)))
    return Image.composite(solid((BODY, BODY), SNOW_SHADE), solid((BODY, BODY), SNOW_LIT), ramp)


def sill(body):
    """The ledge's wood: a lit top face and a front face darkening downwards."""
    top = grain((BODY, SILL_FRONT - SILL_BACK), tuple(c + 26 for c in WOOD), seed=3)
    front = grain((BODY, BODY - SILL_FRONT), WOOD, seed=5)
    shade = Image.linear_gradient("L").resize(front.size).point(lambda v: v * 150 // 255)
    front.alpha_composite(tinted(shade, (34, 18, 12), 255))
    body.paste(top, (0, SILL_BACK))
    body.paste(front, (0, SILL_FRONT))


def drift(body, foot_w):
    """The snow along the sill, overhanging its front edge, casting a soft shadow down the wood;
    the character's base sits in a shallow lavender hollow so it is planted, not pasted on."""
    xs = range(0, BODY + 1, 4)
    outline = [(x, crest(x)) for x in xs] + [(x, overhang(x)) for x in reversed(xs)]
    mask = shape(lambda d, s: d.polygon([(x * s, y * s) for x, y in outline], fill=255))
    body.alpha_composite(tinted(ImageChops.offset(mask, 0, 12).filter(ImageFilter.GaussianBlur(9)), (24, 12, 20), 170))
    body.paste(snow_fill(), (0, 0), mask)
    top, half = crest(CHARACTER_CX), 0.36 * foot_w
    hollow = shape(lambda d, s: d.ellipse(((CHARACTER_CX - half) * s, (top - 10) * s,
                                           (CHARACTER_CX + half) * s, (top + 34) * s), fill=255))
    hollow = ImageChops.multiply(hollow.filter(ImageFilter.GaussianBlur(12)), mask)
    body.alpha_composite(tinted(hollow, (112, 118, 186), 130))
    edge = ImageChops.subtract(mask, ImageChops.offset(mask, 0, 5)).filter(ImageFilter.GaussianBlur(1.5))
    body.alpha_composite(tinted(edge, (255, 255, 255), 200))


def character(body):
    """The painted character, its base sunk into the drift (which is drawn over it afterwards), with a
    dark halo that keeps its silhouette apart from the painting at 16 px. Returns its width."""
    sprite = Image.open(ROOT / "Resources" / "Sprites" / CHARACTER).convert("RGBA")
    upscaled = CHARACTER_H > sprite.height
    w = round(sprite.width * CHARACTER_H / sprite.height)
    sprite = sprite.resize((w, CHARACTER_H), Image.LANCZOS)
    if upscaled:
        sprite = sprite.filter(ImageFilter.UnsharpMask(radius=2, percent=70, threshold=2))
    at = (CHARACTER_CX - w // 2, round(crest(CHARACTER_CX)) + SINK - CHARACTER_H)
    halo = Image.new("L", body.size, 0)
    halo.paste(sprite.getchannel("A"), at)
    body.alpha_composite(tinted(halo.filter(ImageFilter.GaussianBlur(16)), SHADOW_BLUE, 120))
    body.alpha_composite(sprite, at)
    return w


def body_image():
    body = view()
    frame(body)
    sill(body)
    drift(body, foot_w=character(body))
    mask = shape(lambda d, s: d.rounded_rectangle((0, 0, BODY * s - 1, BODY * s - 1), radius=CORNER * s, fill=255))
    body.putalpha(ImageChops.multiply(body.getchannel("A"), mask))
    return body


def icon():
    body = body_image()
    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    shadow.paste(body.getchannel("A"), (ORIGIN, ORIGIN + SHADOW_DY))
    canvas = tinted(shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)), (0, 0, 0), round(255 * SHADOW_ALPHA))
    canvas.alpha_composite(body, (ORIGIN, ORIGIN))
    return canvas


def previews(img, folder):
    folder.mkdir(parents=True, exist_ok=True)
    for px in (128, 32, 16):
        small = img.resize((px, px), Image.LANCZOS)
        small.save(folder / f"AppIcon-{px}.png")
        if px <= 32:
            small.resize((px * 8, px * 8), Image.NEAREST).save(folder / f"AppIcon-{px}-x8.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--previews", type=Path, help="also write 128/32/16 px downscales here")
    args = parser.parse_args()
    img = icon()
    corner_px, centre_px = img.getpixel((4, 4)), img.getpixel((CANVAS // 2, CANVAS // 2))
    assert img.size == (CANVAS, CANVAS) and img.mode == "RGBA", (img.size, img.mode)
    assert corner_px[3] == 0 and centre_px[3] == 255, "transparent outside, opaque body"
    img.save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)} {img.size[0]}x{img.size[1]} {img.mode}")
    if args.previews:
        previews(img, args.previews)
        print(f"previews in {args.previews}")


if __name__ == "__main__":
    main()
