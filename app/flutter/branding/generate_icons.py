#!/usr/bin/env python3
"""Render all Yarnia app/web/favicon icons from the brand source SVGs.

Run from anywhere: `python3 app/flutter/branding/generate_icons.py`.
Requires: cairosvg, pillow (pip install cairosvg pillow).

Sources (this dir):
  icon-square.svg        full-bleed square mark  -> iOS, Android legacy, web standard, favicon
  icon-maskable.svg      mark inside safe zone   -> web maskable icons
  adaptive-background.svg night sky only          -> Android adaptive background
  adaptive-foreground.svg mark in safe zone       -> Android adaptive foreground
"""
import io
import os

import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FLUTTER = os.path.dirname(HERE)            # app/flutter
APP = os.path.dirname(FLUTTER)             # app
REPO = os.path.dirname(APP)                # repo root

SKY_RGB = (12, 13, 31)  # #0c0d1f -> background for flattened (no-alpha) icons


def render(svg_name, size):
    """Render an SVG source to an RGBA PIL image of size x size."""
    path = os.path.join(HERE, svg_name)
    png = cairosvg.svg2png(url=path, output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def save(img, dest, flatten=False):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if flatten:
        bg = Image.new("RGB", img.size, SKY_RGB)
        bg.paste(img, mask=img.split()[3])
        bg.save(dest, "PNG")
    else:
        img.save(dest, "PNG")
    print("wrote", os.path.relpath(dest, REPO), f"({img.size[0]}px)")


def p(*parts):
    return os.path.join(REPO, *parts)


def main():
    # ---- iOS (must be opaque, no alpha) ----
    ios = "app/flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, sz in ios_sizes.items():
        save(render("icon-square.svg", sz), p(ios, name), flatten=True)

    # ---- Android legacy launcher icons ----
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for dpi, sz in legacy.items():
        save(render("icon-square.svg", sz),
             p("app/flutter/android/app/src/main/res", f"mipmap-{dpi}", "ic_launcher.png"))

    # ---- Android adaptive icons (108dp foreground + background) ----
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for dpi, sz in adaptive.items():
        base = p("app/flutter/android/app/src/main/res", f"mipmap-{dpi}")
        save(render("adaptive-background.svg", sz), os.path.join(base, "ic_launcher_background.png"))
        save(render("adaptive-foreground.svg", sz), os.path.join(base, "ic_launcher_foreground.png"))

    # ---- Flutter web ----
    web = "app/flutter/web"
    save(render("icon-square.svg", 192), p(web, "icons/Icon-192.png"), flatten=True)
    save(render("icon-square.svg", 512), p(web, "icons/Icon-512.png"), flatten=True)
    save(render("icon-maskable.svg", 192), p(web, "icons/Icon-maskable-192.png"))
    save(render("icon-maskable.svg", 512), p(web, "icons/Icon-maskable-512.png"))
    save(render("icon-square.svg", 32), p(web, "favicon.png"))
    save(render("icon-square.svg", 180), p(web, "icons/apple-touch-icon.png"), flatten=True)

    # ---- Marketing apple-touch icon (home-screen add) ----
    save(render("icon-square.svg", 180), p("marketing/public/apple-touch-icon.png"), flatten=True)


if __name__ == "__main__":
    main()
