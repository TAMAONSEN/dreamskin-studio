"""Render the DreamSkin Studio 'Lumen' icon: squircle + screen frame + aurora ribbon + sparkle."""
import math
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024  # master canvas


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def gradient(size, stops, angle_deg):
    """Linear multi-stop gradient across the canvas at the given angle."""
    w, h = size
    ang = math.radians(angle_deg)
    dx, dy = math.cos(ang), math.sin(ang)
    proj = [x * dx + y * dy for x, y in ((0, 0), (w, 0), (0, h), (w, h))]
    lo, hi = min(proj), max(proj)
    small = 256
    img = Image.new("RGBA", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            p = ((x / small * w) * dx + (y / small * h) * dy - lo) / (hi - lo)
            for i in range(len(stops) - 1):
                t0, c0 = stops[i]
                t1, c1 = stops[i + 1]
                if p <= t1 or i == len(stops) - 2:
                    t = 0 if t1 == t0 else max(0.0, min(1.0, (p - t0) / (t1 - t0)))
                    px[x, y] = lerp(c0, c1, t)
                    break
    return img.resize(size, Image.BICUBIC)


def squircle_mask(size, inset, n=5.0):
    w = size
    mask = Image.new("L", (w, w), 0)
    d = ImageDraw.Draw(mask)
    r = (w - 2 * inset) / 2
    c = w / 2
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        ct, st = math.cos(t), math.sin(t)
        x = c + r * math.copysign(abs(ct) ** (2 / n), ct)
        y = c + r * math.copysign(abs(st) ** (2 / n), st)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return mask


def ribbon_mask(size, top_fn, thickness_fn, x0, x1):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    upper, lower = [], []
    steps = 200
    for i in range(steps + 1):
        x = x0 + (x1 - x0) * i / steps
        y = top_fn(x)
        t = thickness_fn(x)
        upper.append((x, y))
        lower.append((x, y + t))
    d.polygon(upper + lower[::-1], fill=255)
    return mask


def sparkle(draw, cx, cy, r, fill):
    k = 0.22
    pts = []
    for i in range(8):
        ang = math.pi / 2 * (i // 2) + (math.pi / 4 if i % 2 else 0) - math.pi / 2
        rad = r if i % 2 == 0 else r * k
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    draw.polygon(pts, fill=fill)


def render():
    inset = 40
    base = gradient((S, S), [(0.0, (24, 20, 58, 255)), (0.55, (58, 42, 140, 255)), (1.0, (122, 92, 246, 255))], 60)

    # Soft inner glow at the top-right, like light leaking from the scene.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((520, 60, 1080, 560), fill=(176, 150, 255, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    base = Image.alpha_composite(base, glow)

    # Screen frame.
    fx0, fy0, fx1, fy1 = 214, 262, 810, 700
    frame_r = 70
    stroke = 46
    window_fill = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    wd = ImageDraw.Draw(window_fill)
    wd.rounded_rectangle((fx0, fy0, fx1, fy1), radius=frame_r, fill=(12, 10, 34, 150))
    base = Image.alpha_composite(base, window_fill)

    # Aurora ribbon clipped to the screen interior.
    inner = Image.new("L", (S, S), 0)
    ImageDraw.Draw(inner).rounded_rectangle((fx0 + stroke / 2, fy0 + stroke / 2, fx1 - stroke / 2, fy1 - stroke / 2), radius=frame_r - stroke / 2, fill=255)

    def top_a(x):
        return 560 - 120 * math.sin((x - 180) / 640 * math.pi * 1.15)

    def thick_a(x):
        return 70 + 40 * math.sin((x - 180) / 640 * math.pi)

    def top_b(x):
        return 610 - 70 * math.sin((x - 140) / 700 * math.pi * 1.3 + 0.6)

    rib_a = ribbon_mask(S, top_a, thick_a, 150, 880)
    rib_b = ribbon_mask(S, top_b, lambda x: 46, 150, 880)
    col_a = gradient((S, S), [(0.0, (94, 234, 212, 255)), (0.5, (125, 211, 252, 255)), (1.0, (240, 171, 252, 255))], 0)
    col_b = gradient((S, S), [(0.0, (167, 139, 250, 255)), (1.0, (244, 114, 182, 255))], 0)

    glow_a = rib_a.filter(ImageFilter.GaussianBlur(28))
    for mask, col, alpha in ((glow_a, col_a, 0.55), (rib_b, col_b, 0.75), (rib_a, col_a, 1.0)):
        m = ImageChops.multiply(mask, inner)
        m = m.point(lambda v: int(v * alpha))
        layer = col.copy()
        layer.putalpha(m)
        base = Image.alpha_composite(base, layer)

    # Frame stroke on top.
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((fx0, fy0, fx1, fy1), radius=frame_r, outline=(244, 242, 255, 245), width=stroke)
    base = Image.alpha_composite(base, frame)

    # Sparkle above the frame's top-right corner.
    sp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sp)
    sparkle(sd, 770, 236, 112, (255, 255, 255, 255))
    halo = sp.filter(ImageFilter.GaussianBlur(26))
    base = Image.alpha_composite(base, halo)
    base = Image.alpha_composite(base, sp)

    # Subtle top highlight for depth.
    sheen = gradient((S, S), [(0.0, (255, 255, 255, 46)), (0.45, (255, 255, 255, 0)), (1.0, (255, 255, 255, 0))], 90)
    base = Image.alpha_composite(base, sheen)

    mask = squircle_mask(S, inset)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out


def main(png_path, ico_path, preview_path):
    img = render()
    img.resize((256, 256), Image.LANCZOS).save(png_path)
    sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    frames = [img.resize((s, s), Image.LANCZOS) for s in sizes]
    frames[-1].save(ico_path, format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])
    # Contact sheet: large + small sizes on dark and light backgrounds.
    sheet = Image.new("RGBA", (760, 300), (0, 0, 0, 0))
    for i, bg in enumerate(((32, 32, 36, 255), (240, 240, 244, 255))):
        sheet.paste(Image.new("RGBA", (760, 150), bg), (0, i * 150))
        sheet.alpha_composite(img.resize((128, 128), Image.LANCZOS), (16, i * 150 + 11))
        x = 170
        for s in (64, 48, 32, 24, 16):
            sheet.alpha_composite(img.resize((s, s), Image.LANCZOS), (x, i * 150 + 75 - s // 2))
            x += s + 30
    sheet.save(preview_path)


if __name__ == "__main__":
    main(*sys.argv[1:4])
