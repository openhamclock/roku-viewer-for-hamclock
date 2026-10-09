#!/usr/bin/env python3
"""Turn Roku screenshots into exactly 1920x1080 images for the Streaming Store.

    python3 tools/fit_screenshot.py shot1.jpg shot2.jpg ...        # writes shot1_1920x1080.png etc.
    python3 tools/fit_screenshot.py shots/*.jpg --out store/screenshots

- Already 1920x1080: just converted to PNG.
- Smaller 16:9 (for example 1280x720): scaled up with a high-quality filter. It cannot add detail, so it looks
  a little softer than a true 1080p capture. Setting the Roku to a 1080p display type and re-capturing is better.
- Not 16:9: padded with black bars to 1920x1080 (never stretched) and a warning is printed.
Needs Pillow:  pip install pillow
"""
import argparse
import os
import sys

from PIL import Image, ImageFilter

W, H = 1920, 1080


def fit(path, out_dir):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    note = ""
    if (w, h) == (W, H):
        out = im
        note = "already 1920x1080"
    elif abs(w / h - W / H) < 0.01:
        out = im.resize((W, H), Image.LANCZOS)
        if w < W:                                    # a light touch of sharpening after an upscale
            out = out.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))
        note = f"scaled up from {w}x{h}"
    else:
        scale = min(W / w, H / h)
        nw, nh = round(w * scale), round(h * scale)
        out = Image.new("RGB", (W, H), (0, 0, 0))
        out.paste(im.resize((nw, nh), Image.LANCZOS), ((W - nw) // 2, (H - nh) // 2))
        note = f"WARNING: {w}x{h} is not 16:9, padded with black bars"
    base = os.path.splitext(os.path.basename(path))[0]
    dest = os.path.join(out_dir or os.path.dirname(path) or ".", f"{base}_1920x1080.png")
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    out.save(dest)
    print(f"{path} -> {dest}  ({note})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", help="folder for the results (default: next to each input)")
    a = ap.parse_args()
    bad = 0
    for f in a.files:
        try:
            fit(f, a.out)
        except Exception as e:                       # keep going if one file is unreadable
            print(f"{f}: could not process ({e})")
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
