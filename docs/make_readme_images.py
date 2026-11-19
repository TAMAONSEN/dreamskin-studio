"""Turn a sample-picture self-test run into the images used by README.md.

    python make_readme_images.py <self-test folder> <docs folder>

The self-test folder comes from
    DreamSkinStudio.exe --self-test <folder> <sample pictures>
and holds the page captures, the tilt frames and report.json, whose
"layout" section says where each control sits so callouts land on it.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = ImageFont.truetype(r"C:\Windows\Fonts\segoeuib.ttf", 19)
BADGE, INK, RADIUS = (255, 197, 61), (20, 21, 26), 15

# page -> (control, x anchor, y anchor, dx, dy); the badge number is the position in the list.
CALLOUTS = {
    "home": [("ChangeMediaButton", 0, 1, -5, 0), ("RevealSlider", 0, 0.5, -12, 0), ("PreviewOriginalButton", 0, 0.5, -15, 0),
             ("SaveThemeButton", 0, 1, -5, 0), ("PauseSkinButton", 0, 1, -5, 0), ("ApplyButton", 0, 0, -5, -5),
             ("ColorsButton", 0, 0.5, -12, 0), ("NavLibrary", 1, 0.5, -22, 0)],
    "library": [("SearchBox", 0, 0, -3, -3), ("ThemeList", 0, 0, -1, 30), ("LibraryStage", 1, 0, -30, 30),
                ("ApplySelectedButton", 0, 0, -5, -5), ("RenameSelectedButton", 0, 0, -5, -5), ("RecycleSelectedButton", 0, 0, -5, -5),
                ("ImportZipButton", 0, 0, -9, -3), ("OpenLibraryButton", 0, 0, -9, -3)],
    "settings": [("SettingsColorsButton", 0, 0, -5, -5), ("AutoStartCheck", 0, 0.5, -16, 0), ("RestoreButton", 0, 0, -5, -5),
                 ("WallpaperLinkHost", 1, 0, -6, 12), ("DiagnoseButton", 0, 0, -5, -5), ("ApplyButton", 0, 0, -5, -5)],
}


def save(image, path):
    image.convert("RGB").save(path, quality=88, optimize=True)
    print(path.name, round(path.stat().st_size / 1024), "KB")


def annotate(image, layout, callouts):
    image = image.convert("RGBA")
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    badges = Image.new("RGBA", image.size, (0, 0, 0, 0))
    under, over = ImageDraw.Draw(shadow), ImageDraw.Draw(badges)
    for number, (name, ax, ay, dx, dy) in enumerate(callouts, 1):
        if name not in layout:
            raise SystemExit("the self-test did not report where %s is" % name)
        x, y, w, h = layout[name]
        cx, cy = x + ax * w + dx, y + ay * h + dy
        under.ellipse((cx - RADIUS - 2, cy - RADIUS + 2, cx + RADIUS + 2, cy + RADIUS + 6), fill=(0, 0, 0, 150))
        over.ellipse((cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS), fill=BADGE + (255,), outline=(255, 255, 255, 255), width=2)
        over.text((cx, cy - 1), str(number), font=FONT, fill=INK + (255,), anchor="mm")
    image = Image.alpha_composite(image, shadow.filter(ImageFilter.GaussianBlur(4)))
    return Image.alpha_composite(image, badges)


def tilt_gif(frames, box, path, width=540):
    pictures = [Image.open(frame).convert("RGB").crop(box) for frame in frames]
    height = round(width * pictures[0].height / pictures[0].width)
    pictures = [picture.resize((width, height), Image.LANCZOS) for picture in pictures]
    # One shared palette, taken from frames spread around the loop, keeps the colours from flickering.
    sheet = Image.new("RGB", (width * 4, height))
    for index in range(4):
        sheet.paste(pictures[index * len(pictures) // 4], (index * width, 0))
    palette = sheet.quantize(colors=200, method=Image.Quantize.MEDIANCUT)
    indexed = [picture.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG) for picture in pictures]
    indexed[0].save(path, save_all=True, append_images=indexed[1:], duration=70, loop=0, optimize=True)
    print(path.name, round(path.stat().st_size / 1024), "KB,", len(indexed), "frames")


def main(run, docs):
    run, docs = Path(run), Path(docs)
    layout = json.loads((run / "report.json").read_text(encoding="utf-8-sig"))["layout"]
    save(Image.open(run / "home.png"), docs / "home.jpg")
    for page in ("home", "library", "settings"):
        save(annotate(Image.open(run / (page + ".png")), layout[page], CALLOUTS[page]), docs / ("steps-" + page + ".jpg"))
    save(Image.open(run / "color-dialog.png"), docs / "colors.jpg")

    # The collection page lit by four different pictures.
    shots = [Image.open(run / name).convert("RGB") for name in ("library.png", "palette-0.png", "palette-1.png", "palette-2.png")]
    gap, w, h = 12, shots[0].width // 2, shots[0].height // 2
    grid = Image.new("RGB", (w * 2 + gap, h * 2 + gap), (14, 15, 20))
    for index, shot in enumerate(shots):
        grid.paste(shot.resize((w, h), Image.LANCZOS), ((index % 2) * (w + gap), (index // 2) * (h + gap)))
    save(grid, docs / "palette.jpg")

    x, y, w, h = layout["home"]["HomeStage"]
    tilt_gif(sorted((run / "tilt").glob("*.png")), (int(x) - 14, int(y) - 14, int(x + w) + 14, int(y + h) + 14), docs / "tilt.gif")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
