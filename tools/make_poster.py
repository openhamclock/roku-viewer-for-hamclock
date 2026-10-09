#!/usr/bin/env python3
"""Generate the Roku Channel Store poster (540x405) into store/poster_540x405.png.

    python3 tools/make_poster.py                       # uses the default name below
    python3 tools/make_poster.py "My Channel Name"     # if you rename the channel

Original artwork only (a globe, radio-wave arcs, a screen outline) - it does not copy HamClock's own
screen or logo. Needs Pillow.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

NAME = sys.argv[1] if len(sys.argv) > 1 else "HamClock"
TAGLINE = "Your ham radio dashboard on the big screen"
W, H = 540, 405
S = 3                                   # draw at 3x and downsample for smooth edges

FONT_BOLD = "/usr/share/fonts/opentype/inter/Inter-Bold.otf"
FONT_REG = "/usr/share/fonts/opentype/inter/Inter-Regular.otf"


def font(path, size):
    try:
        return ImageFont.truetype(path, size * S)
    except OSError:
        return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


img = Image.new("RGB", (W * S, H * S))
px = ImageDraw.Draw(img)

# background: deep navy -> teal, left to right (broadcast-safe, no pure black/white)
top_left, bottom_right = (16, 28, 52), (22, 82, 98)
for y in range(H * S):
    for x in range(0, W * S, 6):
        t = (x / (W * S)) * 0.7 + (y / (H * S)) * 0.3
        px.rectangle([x, y, x + 5, y], fill=lerp(top_left, bottom_right, t))

d = ImageDraw.Draw(img, "RGBA")

# globe on the right
cx, cy, r = 424 * S, 210 * S, 96 * S
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(30, 72, 110, 255), outline=(150, 205, 215, 255), width=2 * S)
for k in (-2, -1, 0, 1, 2):                                   # latitude lines
    yy = cy + k * r * 0.36
    half = math.sqrt(max(r * r - (yy - cy) ** 2, 0))
    d.line([cx - half, yy, cx + half, yy], fill=(150, 205, 215, 110), width=S)
for k in (-2, -1, 0, 1, 2):                                   # meridians
    w = abs(k) * r * 0.30 + (0 if k else 1)
    if k == 0:
        d.line([cx, cy - r, cx, cy + r], fill=(150, 205, 215, 110), width=S)
    else:
        d.ellipse([cx - w, cy - r, cx + w, cy + r], outline=(150, 205, 215, 110), width=S)

# night side shading (right half dimmed)
shade = Image.new("RGBA", img.size, (0, 0, 0, 0))
sd = ImageDraw.Draw(shade)
sd.pieslice([cx - r, cy - r, cx + r, cy + r], -90, 90, fill=(8, 16, 34, 110))
img.paste(shade, (0, 0), shade)
d = ImageDraw.Draw(img, "RGBA")

# radio-wave arcs radiating from a point on the globe's upper left
ox, oy = cx - 52 * S, cy - 50 * S
d.ellipse([ox - 5 * S, oy - 5 * S, ox + 5 * S, oy + 5 * S], fill=(238, 190, 80, 255))
for i, rad in enumerate((22, 40, 58)):
    a = 255 - i * 60
    d.arc([ox - rad * S, oy - rad * S, ox + rad * S, oy + rad * S], 200, 290, fill=(238, 190, 80, a), width=3 * S)

# title + tagline, left aligned
tf, sf = font(FONT_BOLD, 46 if len(NAME) <= 10 else 36), font(FONT_REG, 19)
d.text((34 * S, 132 * S), NAME, font=tf, fill=(236, 242, 246, 255))
d.rectangle([36 * S, 206 * S, 96 * S, 210 * S], fill=(238, 190, 80, 255))
words, line, y = TAGLINE.split(), "", 226 * S
for wd in words:
    test = (line + " " + wd).strip()
    if d.textlength(test, font=sf) > 230 * S:
        d.text((36 * S, y), line, font=sf, fill=(190, 214, 224, 255))
        y += 27 * S
        line = wd
    else:
        line = test
d.text((36 * S, y), line, font=sf, fill=(190, 214, 224, 255))

out = img.resize((W, H), Image.LANCZOS)
os.makedirs("store", exist_ok=True)
out.save("store/poster_540x405.png")
print("wrote store/poster_540x405.png", out.size)
