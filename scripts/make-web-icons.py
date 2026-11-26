#!/usr/bin/env python3
"""The Runlight logo for the web, drawn from the Mac app icon's geometry (scripts/make-icon.swift).

Run: python3 scripts/make-web-icons.py <out-folder>

Writes the vector marks and the PNG and ICO files a site needs. PNGs are rendered by headless
Chrome, so it needs Google Chrome in /Applications and ImageMagick (`magick`) for the ICO.

- mark(prefix): the full logo as inline SVG, a 1024 canvas with the tile inset like an app icon.
  Each copy on a page needs its own prefix, since its gradients and filters have ids.
- favicon.svg: the flat logo, which stays crisp at 16 to 32 pixels.
- favicon.ico (16, 32, and 48), apple-touch-icon.png (180, square: iOS rounds it), icon-192.png and
  icon-512.png (square, safe to mask), and logo-256.png (the rounded tile, for listings).
"""

import os
import subprocess
import sys
import tempfile

LETTER = "M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11M17 17.6l5 5.4"
# The 32 unit mark in the 1024 canvas, as the app icon places it.
PLACE = "translate(96 104) scale(26)"
LAMP = 'cx="23.6" cy="8.4"'


def full(prefix="rl", view="0 0 1024 1024", square=False, attrs=""):
    """The app icon's look: a gradient tile, the R lit from above, and a glowing lamp."""
    p = prefix
    # Square, the tile runs past the edges, so the border pixels are as solid as the rest.
    body = '<rect x="0" y="0" width="1024" height="1024"/>' if square else '<rect x="100" y="100" width="824" height="824" rx="185"/>'
    fill = 'x="0" y="0" width="1024" height="1024"' if square else 'x="100" y="100" width="824" height="824"'
    rim = "" if square else f'<rect x="101.5" y="101.5" width="821" height="821" rx="184" fill="none" stroke="url(#{p}-rim)" stroke-width="3"/>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}"{attrs}><defs>'
        f'<clipPath id="{p}-b">{body}</clipPath>'
        f'<linearGradient id="{p}-t" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#2e2e33"/><stop offset="1" stop-color="#111113"/></linearGradient>'
        f'<radialGradient id="{p}-s" cx="709.6" cy="322.4" r="439.4" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#22c55e" stop-opacity=".38"/><stop offset="1" stop-color="#22c55e" stop-opacity="0"/></radialGradient>'
        f'<linearGradient id="{p}-rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".28"/><stop offset=".5" stop-color="#fff" stop-opacity=".02"/></linearGradient>'
        f'<linearGradient id="{p}-r" x1="0" y1="5.6" x2="0" y2="26" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d4d4d8"/></linearGradient>'
        f'<radialGradient id="{p}-l" {LAMP} r="2.6" fx="22.69" fy="7.36" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#86efac"/><stop offset=".55" stop-color="#22c55e"/><stop offset="1" stop-color="#16a34a"/></radialGradient>'
        f'<filter id="{p}-d" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy=".23" stdDeviation=".27" flood-color="#000" flood-opacity=".45"/></filter>'
        f'<filter id="{p}-g" x="-200%" y="-200%" width="500%" height="500%"><feGaussianBlur stdDeviation="1.15"/></filter>'
        f'<mask id="{p}-n" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/><circle {LAMP} r="3.432" fill="#000" transform="{PLACE}"/></mask>'
        f'</defs>'
        f'<g clip-path="url(#{p}-b)"><rect {fill} fill="url(#{p}-t)"/><rect {fill} fill="url(#{p}-s)"/>{rim}</g>'
        f'<g mask="url(#{p}-n)"><g transform="{PLACE}" filter="url(#{p}-d)"><path d="{LETTER}" fill="none" stroke="url(#{p}-r)" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></g></g>'
        f'<g transform="{PLACE}"><circle {LAMP} r="2.6" fill="#4ade80" fill-opacity=".9" filter="url(#{p}-g)"/><circle {LAMP} r="2.6" fill="url(#{p}-l)"/></g>'
        f'</svg>'
    )


def flat(prefix="rlf", view="100 100 824 824", attrs=""):
    """The same tile, R, and lamp without the glow, for sizes where a glow would blur."""
    p = prefix
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}"{attrs}><defs>'
        f'<mask id="{p}-n" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/><circle {LAMP} r="3.5" fill="#000" transform="{PLACE}"/></mask>'
        f'</defs>'
        f'<rect x="100" y="100" width="824" height="824" rx="185" fill="#1c1c1f"/>'
        f'<g mask="url(#{p}-n)"><path d="{LETTER}" transform="{PLACE}" fill="none" stroke="#fafafa" stroke-width="3.1" stroke-linecap="round" stroke-linejoin="round"/></g>'
        f'<circle {LAMP} r="2.75" fill="#22c55e" transform="{PLACE}"/>'
        f'</svg>'
    )


CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def render(svg, pixels, out, work):
    """A PNG of `svg` at `pixels` square, with a transparent background."""
    page = os.path.join(work, f"render-{pixels}.html")
    with open(page, "w") as f:
        f.write(f'<!doctype html><style>html,body{{margin:0;background:transparent}} svg{{display:block;width:{pixels}px;height:{pixels}px}}</style>{svg}')
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
         "--default-background-color=00000000", f"--window-size={pixels},{pixels}", f"--screenshot={out}", f"file://{page}"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "build/web-icons"
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "mark.svg"), "w") as f:
        f.write(full() + "\n")
    with open(os.path.join(out, "favicon.svg"), "w") as f:
        f.write(flat() + "\n")
    with tempfile.TemporaryDirectory() as work:
        # Tight on the tile for icons; square to the edges where the platform rounds or masks them.
        tile = full(view="100 100 824 824")
        square = full(view="100 100 824 824", square=True)
        render(square, 180, os.path.join(out, "apple-touch-icon.png"), work)
        render(square, 192, os.path.join(out, "icon-192.png"), work)
        render(square, 512, os.path.join(out, "icon-512.png"), work)
        render(tile, 256, os.path.join(out, "logo-256.png"), work)
        render(tile, 128, os.path.join(out, "logo-128.png"), work)
        parts = []
        for pixels, svg in ((16, flat()), (32, flat()), (48, tile)):
            part = os.path.join(work, f"ico-{pixels}.png")
            render(svg, pixels, part, work)
            parts.append(part)
        subprocess.run(["magick", *parts, os.path.join(out, "favicon.ico")], check=True)
    print(f"Wrote the web icons to {out}")


if __name__ == "__main__":
    main()
