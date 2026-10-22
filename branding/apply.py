#!/usr/bin/env python3
"""Applies FreeChat branding (name, app IDs, icon) to the client forks.

    branding/apply.py                   all clients present under forks/
    branding/apply.py android web       only these
    branding/apply.py --default-icon    redraw branding/icon.png with the built-in design, then apply

Reads branding/branding.conf and branding/icon.png: the symbol, 1024x1024, transparent background,
drawn inside the central two thirds (Android crops icons to circles and other shapes). The background
colour comes from ICON_BACKGROUND. If icon.png is missing, the built-in design is drawn first.

Needs Pillow (python3 -m pip install --user pillow).
"""

import json
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("Pillow is needed: python3 -m pip install --user pillow")

ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "branding"
FORKS = ROOT / "forks"
ICON = BRANDING / "icon.png"


def main() -> None:
    args = sys.argv[1:]
    if "--default-icon" in args or not ICON.exists():
        draw_default_icon().save(ICON)
        print(f"drew the default icon: {ICON.relative_to(ROOT)}")
        args = [a for a in args if a != "--default-icon"]

    conf = read_conf()
    symbol = Image.open(ICON).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    background = conf["ICON_BACKGROUND"]

    appliers = {"android": apply_android, "ios": apply_ios, "web": apply_web}
    targets = args or [name for name, path in FORK_DIRS.items() if (FORKS / path).exists()]
    for target in targets:
        if target not in appliers:
            sys.exit(f"unknown target: {target} (android, ios or web)")
        if not (FORKS / FORK_DIRS[target]).exists():
            sys.exit(f"forks/{FORK_DIRS[target]} is missing")
        appliers[target](conf, symbol, background)
        print(f"{target}: applied {conf['APP_NAME']}")


FORK_DIRS = {"android": "element-x-android", "ios": "element-x-ios", "web": "element-web"}


def read_conf() -> dict:
    conf = {}
    for line in (BRANDING / "branding.conf").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            conf[key.strip()] = value.strip().strip('"')
    for key in ("APP_NAME", "ANDROID_APP_ID", "IOS_BUNDLE_ID", "ICON_BACKGROUND", "THEME_COLOR"):
        if not conf.get(key):
            sys.exit(f"branding.conf is missing {key}")
    if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+", conf["ANDROID_APP_ID"]):
        sys.exit(f"invalid Android application ID: {conf['ANDROID_APP_ID']} (example: chat.freechat.app)")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", conf["IOS_BUNDLE_ID"]):
        sys.exit(f"invalid iOS bundle ID: {conf['IOS_BUNDLE_ID']}")
    for key in ("ICON_BACKGROUND", "THEME_COLOR"):
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", conf[key]):
            sys.exit(f"{key} must be #RRGGBB, not {conf[key]}")
    return conf


# --- Icons ---------------------------------------------------------------------------------------


def draw_default_icon() -> Image.Image:
    """A speech bubble with a padlock, white on transparent, inside the central two thirds."""
    size = 1024
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    white = (255, 255, 255, 255)
    # Bubble with a tail at the bottom left.
    d.rounded_rectangle((232, 262, 792, 682), radius=110, fill=white)
    d.polygon([(318, 640), (300, 790), (450, 672)], fill=white)
    # Padlock, cut out of the bubble so the background shows through.
    clear = (0, 0, 0, 0)
    d.rounded_rectangle((432, 450, 592, 590), radius=22, fill=clear)
    d.arc((452, 360, 572, 480), start=180, end=360, fill=clear, width=26)
    d.rectangle((452, 418, 478, 456), fill=clear)
    d.rectangle((546, 418, 572, 456), fill=clear)
    d.ellipse((498, 492, 526, 520), fill=white)
    d.rectangle((506, 510, 518, 552), fill=white)
    return im


def full_icon(symbol: Image.Image, background: str, size: int, alpha: bool = True) -> Image.Image:
    """The square icon: background colour with the symbol on top."""
    base = Image.new("RGBA", (1024, 1024), background)
    base.alpha_composite(symbol)
    im = base.resize((size, size), Image.LANCZOS)
    return im if alpha else im.convert("RGB")


def adaptive_layer(symbol: Image.Image, size: int) -> Image.Image:
    """Android adaptive icon layer: 108dp canvas, where the symbol's 1024 square maps to the full canvas."""
    return symbol.resize((size, size), Image.LANCZOS)


def monochrome(symbol: Image.Image) -> Image.Image:
    """White symbol keeping only its shape, for Android themed icons."""
    alpha = symbol.getchannel("A")
    out = Image.new("RGBA", symbol.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def circle(im: Image.Image) -> Image.Image:
    # Drawn four times larger and scaled down, so the edge is smooth.
    big = Image.new("L", (im.size[0] * 4, im.size[1] * 4), 0)
    ImageDraw.Draw(big).ellipse((0, 0, big.size[0] - 1, big.size[1] - 1), fill=255)
    mask = big.resize(im.size, Image.LANCZOS)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, mask=mask)
    return out


# --- Android -------------------------------------------------------------------------------------

ANDROID_DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def apply_android(conf: dict, symbol: Image.Image, background: str) -> None:
    fork = FORKS / "element-x-android"
    config = fork / "plugins/src/main/kotlin/config/BuildTimeConfig.kt"
    text = config.read_text(encoding="utf-8")
    text = re.sub(r'(const val APPLICATION_ID = )"[^"]*"', rf'\1"{conf["ANDROID_APP_ID"]}"', text)
    text = re.sub(r'(const val APPLICATION_NAME = )"[^"]*"', rf'\1"{conf["APP_NAME"]}"', text)
    config.write_text(text, encoding="utf-8")

    res = fork / "appicon/element/src/main/res"
    mono = monochrome(symbol)
    for density, scale in ANDROID_DENSITIES.items():
        folder = res / f"mipmap-{density}"
        launcher = round(48 * scale)
        layer = round(108 * scale)
        full_icon(symbol, background, launcher).save(folder / "ic_launcher.webp", lossless=True)
        circle(full_icon(symbol, background, launcher)).save(folder / "ic_launcher_round.webp", lossless=True)
        adaptive_layer(symbol, layer).save(folder / "ic_launcher_foreground.webp", lossless=True)
        adaptive_layer(mono, layer).save(folder / "ic_launcher_monochrome.webp", lossless=True)
    full_icon(symbol, background, 512, alpha=False).save(fork / "appicon/element/src/main/ic_launcher-playstore.png")

    for variant in ("release", "debug", "nightly"):
        drawable = fork / f"appicon/element/src/{variant}/res/drawable/ic_launcher_background.xml"
        if drawable.exists():
            xml = drawable.read_text(encoding="utf-8")
            drawable.write_text(re.sub(r'android:fillColor="#[0-9A-Fa-f]{6,8}"', f'android:fillColor="{background}"', xml, count=1), encoding="utf-8")


# --- iOS -----------------------------------------------------------------------------------------


def apply_ios(conf: dict, symbol: Image.Image, background: str) -> None:
    fork = FORKS / "element-x-ios"
    app = fork / "app.yml"
    text = app.read_text(encoding="utf-8")
    text = re.sub(r"(\n\s*APP_DISPLAY_NAME:).*", rf"\1 {conf['APP_NAME']}", text)
    text = re.sub(r"(\n\s*BASE_BUNDLE_IDENTIFIER:).*", rf"\1 {conf['IOS_BUNDLE_ID']}", text)
    app.write_text(text, encoding="utf-8")
    # The App Store rejects app icons with transparency.
    full_icon(symbol, background, 1024, alpha=False).save(fork / "ElementX/Resources/AppIcon.icon/Assets/AppIcon.png")


# --- Web -----------------------------------------------------------------------------------------

WEB_ICON_SIZES = (24, 120, 144, 152, 180, 512, 1024)


def apply_web(conf: dict, symbol: Image.Image, background: str) -> None:
    web = FORKS / "element-web/apps/web"
    for size in WEB_ICON_SIZES:
        full_icon(symbol, background, size).save(web / f"res/vector-icons/{size}.png")

    manifest_path = web / "res/manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["name"] = manifest["short_name"] = conf["APP_NAME"]
    manifest["theme_color"] = conf["THEME_COLOR"]
    manifest_path.write_text(json.dumps(manifest, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")

    index = web / "src/vector/index.html"
    html = index.read_text(encoding="utf-8")
    index.write_text(re.sub(r"<title>[^<]*</title>", f"<title>{conf['APP_NAME']}</title>", html, count=1), encoding="utf-8")


if __name__ == "__main__":
    main()
