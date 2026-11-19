"""Generate abstract sample wallpapers for the README screenshots.

    python make_sample_art.py <output folder>

The self-test shows these instead of the wallpapers in the local library
(see README), so documentation never contains anyone's own pictures.
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H = 1600, 900

# (file stem, base, three colours)
SCENES = [
    ("01-aurora", (8, 14, 30), [(34, 211, 196), (232, 76, 201), (88, 120, 255)]),
    ("02-dusk", (30, 12, 40), [(255, 140, 72), (240, 80, 130), (120, 70, 200)]),
    ("03-deep-sea", (4, 16, 36), [(40, 130, 255), (40, 220, 230), (20, 60, 160)]),
    ("04-mint", (8, 28, 26), [(90, 230, 170), (210, 240, 120), (40, 170, 160)]),
    ("05-ember", (32, 8, 8), [(255, 90, 50), (255, 190, 70), (190, 40, 80)]),
    ("06-nebula", (14, 8, 34), [(150, 90, 255), (70, 200, 255), (240, 100, 220)]),
    ("07-morning", (40, 44, 70), [(255, 180, 200), (150, 200, 255), (255, 225, 170)]),
    ("08-neon", (6, 6, 16), [(255, 60, 190), (60, 230, 255), (140, 80, 255)]),
    ("09-amber", (30, 18, 6), [(255, 176, 40), (255, 110, 60), (250, 230, 150)]),
    ("10-highland", (10, 24, 34), [(80, 200, 190), (130, 170, 255), (190, 240, 220)]),
    ("11-sakura", (40, 16, 30), [(255, 150, 190), (255, 200, 220), (200, 120, 230)]),
    ("12-night-flight", (6, 10, 26), [(70, 110, 255), (255, 200, 110), (40, 190, 230)]),
    ("13-tundra", (16, 26, 18), [(150, 210, 110), (90, 170, 140), (230, 220, 150)]),
]


def glow(base, colours, rng):
    """Soft colour fields: big discs, heavily blurred."""
    image = Image.new("RGB", (W, H), base)
    draw = ImageDraw.Draw(image)
    for index in range(7):
        colour = colours[index % 3]
        x, y, r = rng.uniform(0, W), rng.uniform(0, H), rng.uniform(260, 520)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=colour)
    image = image.filter(ImageFilter.GaussianBlur(170))
    # Keep the picture moody: blend back towards the dark base.
    return Image.blend(Image.new("RGB", (W, H), base), image, 0.78)


def ribbons(image, colours, rng):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for index in range(4):
        colour = colours[index % 3]
        middle, height, thick = rng.uniform(0.35, 0.75) * H, rng.uniform(60, 150), rng.uniform(26, 90)
        phase, period = rng.uniform(0, 6.28), rng.uniform(0.9, 1.7)
        top = [(x, middle + height * math.sin(x / W * 6.28 * period + phase)) for x in range(-20, W + 40, 20)]
        low = [(x, y + thick * (0.6 + 0.4 * math.sin(x / 240 + phase))) for x, y in top]
        draw.polygon(top + low[::-1], fill=colour + (150,))
    return Image.alpha_composite(image.convert("RGBA"), layer.filter(ImageFilter.GaussianBlur(7))).convert("RGB")


def hills(image, colours, base, rng):
    draw = ImageDraw.Draw(image)
    sun = colours[rng.randrange(3)]
    draw.ellipse((W * 0.62, H * 0.2, W * 0.62 + 230, H * 0.2 + 230), fill=tuple(min(255, c + 40) for c in sun))
    for layer in range(4):
        level = H * (0.5 + layer * 0.12)
        shade = tuple(int(base[i] + (colours[layer % 3][i] - base[i]) * (0.42 - layer * 0.09)) for i in range(3))
        phase = rng.uniform(0, 6.28)
        ridge = [(x, level + 60 * math.sin(x / 210 + phase) + 28 * math.sin(x / 67 + phase * 2)) for x in range(-20, W + 40, 20)]
        draw.polygon(ridge + [(W + 40, H), (-20, H)], fill=shade)
    return image


def rings(image, colours, rng):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = rng.uniform(0.3, 0.7) * W, rng.uniform(0.35, 0.65) * H
    for index in range(9):
        r = 90 + index * 95
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=colours[index % 3] + (170,), width=10 + index)
    return Image.alpha_composite(image.convert("RGBA"), layer.filter(ImageFilter.GaussianBlur(2))).convert("RGB")


def grid(image, colours, rng):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    horizon = H * 0.58
    draw.ellipse((W / 2 - 210, horizon - 330, W / 2 + 210, horizon + 90), fill=colours[0] + (235,))
    draw.rectangle((0, horizon, W, H), fill=(6, 6, 16, 255))
    for index in range(-14, 15):
        draw.line((W / 2 + index * 46, horizon, W / 2 + index * 330, H), fill=colours[1] + (200,), width=3)
    for index in range(1, 11):
        y = horizon + (H - horizon) * (index / 10) ** 2
        draw.line((0, y, W, y), fill=colours[1] + (200,), width=3)
    return Image.alpha_composite(image.convert("RGBA"), layer).convert("RGB")


def stars(image, colours, rng):
    draw = ImageDraw.Draw(image)
    for _ in range(420):
        x, y, r = rng.uniform(0, W), rng.uniform(0, H), rng.choice((1, 1, 1, 2, 2, 3))
        tone = rng.choice(colours + [(255, 255, 255)] * 3)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=tuple(min(255, c + 70) for c in tone))
    return image


def main(folder):
    target = Path(folder)
    target.mkdir(parents=True, exist_ok=True)
    styles = (ribbons, "hills", stars, rings, "grid")
    for index, (stem, base, colours) in enumerate(SCENES):
        rng = random.Random(index * 97 + 5)
        image = glow(base, colours, rng)
        style = styles[index % len(styles)]
        if style == "hills":
            image = hills(image, colours, base, rng)
        elif style == "grid":
            image = grid(image, colours, rng)
        else:
            image = style(image, colours, rng)
        image.save(target / (stem + ".jpg"), quality=92)
    print(len(SCENES), "sample wallpapers written to", target)


if __name__ == "__main__":
    main(sys.argv[1])
