#!/usr/bin/python3
"""Generate the OmniAgent ADE macOS DMG installer background.

Re-run from the repo root (needs Pillow, which ships with the system python3
here — `/usr/bin/python3 -c "import PIL"` works with no venv):

    /usr/bin/python3 src-tauri/dmg/make_dmg_background.py

Outputs, all beside this file in `src-tauri/dmg/`:

    dmg-background.png       700x420   <- the one `tauri.conf.json` wires up
    dmg-background@2x.png   1400x840   <- companion; see the retina note below
    dmg-window-preview.png   700x420   <- design check only, not shipped

Retina note (checked, not assumed): Tauri v2's `bundle.macOS.dmg` has exactly
five fields — background / windowPosition / windowSize / appPosition /
applicationFolderPosition (tauri-utils 2.9.3 `config.rs::DmgConfig`, and the
same shape in `@tauri-apps/cli/config.schema.json`). There is no @2x concept,
and the `bundle_dmg.sh` Tauri emits simply copies the single file into the
volume's `.background/` and points Finder at it by name — no `tiffutil`, no
`@2x` lookup. So the background must be exactly `windowSize` pixels or Finder
crops it. The @2x file is kept because it is free (everything is rendered at
4x and downsampled) and because the documented retina upgrade path, if it is
ever wanted, is `tiffutil -cathidpicheck` over the 1x + 2x pair.

If `tauri build` fails at the DMG step
--------------------------------------
The failure seen on this machine is NOT the background, the config, or the
other volumes that happen to be mounted. `bundle_dmg.sh` gets all the way
through — it creates, mounts, and populates the scratch image — and then dies
in the one step that needs a GUI:

    execution error: Finder got an error: AppleEvent timed out. (-1712)
    Failed running AppleScript

create-dmg drives Finder over Apple events to set the window bounds, the
background picture, and the icon positions. From a non-interactive shell with
no Automation (TCC) grant for Finder, that event never resolves. It is
reproducible with no disk image involved at all:

    osascript -e 'tell application "Finder" to get name of startup disk'

If that hangs and then returns -1712, `tauri build --bundles dmg` will fail
the same way; if it answers immediately, the DMG builds. Run the build from a
logged-in Terminal that has been granted Automation -> Finder. The `.app` is
unaffected either way — only the DMG's cosmetics need Finder.

Design notes
------------
Palette and type are lifted from the app itself, not invented: the hexes are
the `:root` tokens in `ui/src/App.css` (--void, --line, --ink*, --signal,
--status-thinking-lo, --panel/--pane-header*, --radius-lg) plus three blues
sampled straight out of `docs/reference/omniagent-logo-1024.png`. Type is the
app's own pairing, JetBrains Mono as the structural face (this is a
terminal-first cockpit, per docs/DESIGN.md) with the logo mark as the only
non-type element in the lockup.

The idea: the two drop zones are drawn as two *panes of the ADE itself*,
pane header and all, and the drag gesture is drawn as an edge in the
knowledge graph running from one to the other — over a very faint field of
the same nodes and edges. The installer looks like the product's workspace,
and the install action is literally "connect this node to that one", which is
the product's whole thesis. Deliberately not the competitor's composition:
no corner registration marks, no dashed circle/rounded-square pair, no
bottom gradient rule, and no orange (Bruno asked for blue / dark / black).
"""

from __future__ import annotations

import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# --------------------------------------------------------------------------
# Canvas. Must stay in lockstep with `bundle.macOS.dmg.windowSize` in
# src-tauri/tauri.conf.json — Finder draws the background unscaled from the
# window's top-left, so any mismatch crops or letterboxes it.
# --------------------------------------------------------------------------
W, H = 700, 400
SS = 4  # supersample factor; everything is drawn at 4x and downsampled

# --------------------------------------------------------------------------
# Palette — every value traced to a source (see module docstring)
# --------------------------------------------------------------------------
VOID_DEEP = (0x09, 0x0A, 0x0E)  # darker sibling of --void, so Finder's icons pop
VOID = (0x16, 0x17, 0x1C)  # --void
PANEL = (0x14, 0x15, 0x1A)  # between --void and --line-soft: the pane body
PANE_HEADER = (0x1A, 0x1B, 0x20)  # --pane-header
PANE_HEADER_FOCUS = (0x3E, 0x40, 0x49)  # --pane-header-focus
LINE = (0x2C, 0x2D, 0x34)  # --line
INK = (0xE8, 0xE9, 0xEC)  # --ink
INK_DIM = (0x8B, 0x8D, 0x97)  # --ink-dim
INK_FAINT = (0x5C, 0x5E, 0x66)  # --ink-faint
SIGNAL = (0x9A, 0xA7, 0xE6)  # --signal
BLUE = (0x4B, 0x86, 0xFF)  # --status-thinking-lo
BRAND_BLUE = (0x30, 0x74, 0xB6)  # sampled: logo mid
BRAND_BLUE_DEEP = (0x24, 0x57, 0x9E)  # sampled: logo bottom
BRAND_BLUE_LIT = (0x3F, 0x91, 0xCE)  # sampled: logo top

RADIUS = 14  # --radius-lg

# --------------------------------------------------------------------------
# Layout (1x points, origin top-left — same space Finder uses for icon
# positions, which is why the numbers below and the JSON agree by hand)
# --------------------------------------------------------------------------
ICON1_X, ICON2_X = 172, 528  # -> appPosition.x / applicationFolderPosition.x
ICON_Y = 205  # -> appPosition.y / applicationFolderPosition.y
ICON_BOX = 128  # bundle_dmg.sh's default ICON_SIZE, which Tauri does not override

# Pane wide enough to clear the 128pt icon by ~36pt each side, and tall enough
# that Finder's icon label (drawn just under the icon box) still lands inside.
PLATE_W = 200
PLATE_TOP, PLATE_BOT = 84, 302
HEADER_H = 26

PLATE1 = (ICON1_X - PLATE_W // 2, PLATE_TOP, ICON1_X + PLATE_W // 2, PLATE_BOT)
PLATE2 = (ICON2_X - PLATE_W // 2, PLATE_TOP, ICON2_X + PLATE_W // 2, PLATE_BOT)

MARK_C = (34, 44)  # logo mark centre in the wordmark lockup
MARK_D = 26
FOOTER_XY = (PLATE1[0], 352)  # aligned to the left pane's edge

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
LOGO = REPO / "docs" / "reference" / "omniagent-logo-1024.png"

FONT_DIRS = [Path("/Library/Fonts"), Path.home() / "Library/Fonts", Path("/System/Library/Fonts")]


def font(name: str, size_pt: float) -> ImageFont.FreeTypeFont:
    """Load a font by filename stem, at a supersampled size."""
    for d in FONT_DIRS:
        p = d / f"{name}.ttf"
        if p.exists():
            return ImageFont.truetype(str(p), max(1, round(size_pt * SS)))
    sys.exit(f"font not found: {name}.ttf (looked in {[str(d) for d in FONT_DIRS]})")


def s(v: float) -> float:
    """points -> supersampled pixels."""
    return v * SS


def rgba(rgb, a: float):
    return rgb + (max(0, min(255, round(a * 255))),)


# --------------------------------------------------------------------------
# Drawing helpers
# --------------------------------------------------------------------------
def bloom(base: Image.Image, cx, cy, rx, ry, rgb, peak: float, power: float = 2.4):
    """Composite a soft elliptical radial glow onto `base` (in 1x coords)."""
    w, h = max(2, round(s(rx) * 2)), max(2, round(s(ry) * 2))
    m = Image.radial_gradient("L").resize((w, h), Image.LANCZOS)
    top = round(peak * 255)
    m = m.point(lambda v: round(top * (1.0 - v / 255.0) ** power))
    alpha = Image.new("L", base.size, 0)
    alpha.paste(m, (round(s(cx) - w / 2), round(s(cy) - h / 2)))
    layer = Image.new("RGBA", base.size, rgb + (0,))
    layer.putalpha(alpha)
    return Image.alpha_composite(base, layer)


def measure(text: str, f: ImageFont.FreeTypeFont, tracking: float) -> float:
    if not text:
        return 0.0
    return sum(f.getlength(c) for c in text) + s(tracking) * (len(text) - 1)


def tracked_text(d: ImageDraw.ImageDraw, xy, text, f, fill, tracking=0.0, align="left"):
    """Draw letter-spaced text. xy is (x, baseline_y) in 1x points."""
    x, y = s(xy[0]), s(xy[1])
    total = measure(text, f, tracking)
    if align == "center":
        x -= total / 2
    elif align == "right":
        x -= total
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill, anchor="ls")
        x += f.getlength(ch) + s(tracking)
    return total


def cbezier(p0, c1, c2, p3, n=160):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u**3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t**3 * p3[1]))
    return out


def lerp_rgb(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ribbon(pts, w_start: float, w_end: float):
    """Outline polygon for a stroke of varying width along `pts` (1x points).

    Drawn as one filled polygon rather than as N separate `line` calls — the
    per-segment approach leaves visible scalloping where consecutive butt caps
    of different widths meet.
    """
    n = len(pts)
    left, right = [], []
    for i, (x, y) in enumerate(pts):
        t = i / (n - 1)
        hw = (w_start + (w_end - w_start) * t) / 2
        if i == 0:
            dx, dy = pts[1][0] - x, pts[1][1] - y
        elif i == n - 1:
            dx, dy = x - pts[-2][0], y - pts[-2][1]
        else:
            dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L
        left.append((s(x + nx * hw), s(y + ny * hw)))
        right.append((s(x - nx * hw), s(y - ny * hw)))
    return left + right[::-1]


def h_gradient(size, x0: float, x1: float, c0, c1) -> Image.Image:
    """Full-canvas RGB image ramping c0 -> c1 horizontally between x0 and x1."""
    row = Image.new("RGB", (size[0], 1))
    px = row.load()
    for x in range(size[0]):
        t = 0.0 if x1 <= x0 else max(0.0, min(1.0, (x / SS - x0) / (x1 - x0)))
        px[x, 0] = lerp_rgb(c0, c1, t)
    return row.resize(size, Image.BILINEAR)


# --------------------------------------------------------------------------
# 1. Field — base tone, blooms, vignette
# --------------------------------------------------------------------------
def draw_field(img: Image.Image) -> Image.Image:
    # a vertical lift so the canvas isn't a flat black slab
    ramp = Image.new("L", (1, 256))
    ramp.putdata([round(70 * (1 - i / 255) ** 1.5) for i in range(256)])
    lift = Image.new("RGBA", img.size, VOID + (0,))
    lift.putalpha(ramp.resize(img.size, Image.BICUBIC))
    img = Image.alpha_composite(img, lift)

    # One broad wash across the whole field, so the canvas reads as lit rather
    # than as black with two spotlights stuck on it.
    img = bloom(img, W * 0.34, H * 0.46, 560, 400, BRAND_BLUE_DEEP, 0.30, 1.9)
    # ambient from the top-left, in the logo's own lit blue
    img = bloom(img, 60, 0, 400, 260, BRAND_BLUE_LIT, 0.16, 2.4)
    # the two drop zones are lit from behind — pane 01 brighter (it is the
    # thing you act on), pane 02 cooler and dimmer (the destination)
    img = bloom(img, ICON1_X, ICON_Y - 4, 250, 215, BRAND_BLUE, 0.42, 2.1)
    img = bloom(img, ICON1_X, ICON_Y - 4, 130, 120, BRAND_BLUE_LIT, 0.16, 2.0)
    img = bloom(img, ICON2_X, ICON_Y - 4, 235, 200, BLUE, 0.20, 2.4)
    # one low, wide bed of light under the whole install row
    img = bloom(img, W // 2, 320, 420, 150, BRAND_BLUE_DEEP, 0.16, 2.0)
    return img


def draw_vignette(img: Image.Image) -> Image.Image:
    m = Image.radial_gradient("L").resize(img.size, Image.LANCZOS)
    m = m.point(lambda v: round(200 * (v / 255.0) ** 2.3))
    layer = Image.new("RGBA", img.size, VOID_DEEP + (0,))
    layer.putalpha(m)
    return Image.alpha_composite(img, layer)


# --------------------------------------------------------------------------
# 2. Graph field — the ambient constellation
# --------------------------------------------------------------------------
def graph_nodes():
    """Deterministic weighted scatter: dense left, thinning right."""
    rnd = random.Random(0x0A6E)
    pts = []
    tries = 0
    while len(pts) < 78 and tries < 20000:
        tries += 1
        x = rnd.uniform(-20, W + 20)
        y = rnd.uniform(-20, H + 20)
        # density falls off to the right and toward the vertical extremes
        px = 1.0 - 0.62 * (x / W)
        py = 1.0 - 0.55 * abs((y - H * 0.46) / (H * 0.6)) ** 2
        if rnd.random() > max(0.06, px * py):
            continue
        if any((x - a) ** 2 + (y - b) ** 2 < 34**2 for a, b in pts):
            continue
        pts.append((x, y))
    return pts


def draw_graph(d: ImageDraw.ImageDraw, pts):
    # each node links to its two nearest neighbours inside a sane radius
    edges = set()
    for i, p in enumerate(pts):
        near = sorted(
            (j for j in range(len(pts)) if j != i),
            key=lambda j: (pts[j][0] - p[0]) ** 2 + (pts[j][1] - p[1]) ** 2,
        )[:2]
        for j in near:
            dist = math.dist(p, pts[j])
            if dist < 125:
                edges.add((min(i, j), max(i, j)))

    # Drawn in SIGNAL, not --line: the field is now lit blue, and --line
    # (#2c2d34) is *darker* than the lit background, so it would read as
    # scratches rather than as a constellation.
    for i, j in edges:
        a, b = pts[i], pts[j]
        # edges fade out toward the right, same as the node density
        t = 1.0 - 0.6 * (((a[0] + b[0]) / 2) / W)
        d.line([(s(a[0]), s(a[1])), (s(b[0]), s(b[1]))],
               fill=rgba(SIGNAL, 0.16 * t), width=max(1, round(s(0.6))))

    for x, y in pts:
        t = 1.0 - 0.55 * (x / W)
        r = s(1.35)
        d.ellipse([s(x) - r, s(y) - r, s(x) + r, s(y) + r], fill=rgba(SIGNAL, 0.62 * t))
        # a handful of nodes get a faint halo ring, like a selected node
        if (round(x) + round(y)) % 7 == 0:
            rr = s(5.5)
            d.ellipse([s(x) - rr, s(y) - rr, s(x) + rr, s(y) + rr],
                      outline=rgba(SIGNAL, 0.20 * t), width=max(1, round(s(0.6))))


# --------------------------------------------------------------------------
# 3. Panes — the two drop zones, drawn as panes of the ADE
# --------------------------------------------------------------------------
def draw_pane(img: Image.Image, box, number: str, title: str, focused: bool) -> Image.Image:
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = s(RADIUS)
    rect = [s(x0), s(y0), s(x1), s(y1)]

    # Body is translucent, not opaque: the blue behind it glows through, so the
    # pane reads as smoked glass over a lit field rather than a hole cut in it.
    d.rounded_rectangle(rect, radius=r, fill=rgba(PANEL, 0.52))
    # header strip — clipped to the pane's top corners by re-rounding and
    # squaring off the bottom with a plain rect
    hdr_bot = s(y0 + HEADER_H)
    d.rounded_rectangle([rect[0], rect[1], rect[2], hdr_bot + r], radius=r,
                        fill=rgba(PANE_HEADER_FOCUS if focused else PANE_HEADER,
                                  0.72 if focused else 0.80))
    d.rectangle([rect[0], hdr_bot, rect[2], hdr_bot + r], fill=rgba(PANEL, 0.52))
    d.line([(rect[0] + s(1), hdr_bot), (rect[2] - s(1), hdr_bot)],
           fill=rgba(LINE, 0.9), width=max(1, round(s(1))))
    # top inside highlight — the one bit of glass rim that makes it read as a
    # surface with an edge rather than a flat swatch
    d.line([(rect[0] + r, rect[1] + s(1)), (rect[2] - r, rect[1] + s(1))],
           fill=rgba(INK, 0.10), width=max(1, round(s(1))))
    d.rounded_rectangle(rect, radius=r,
                        outline=rgba(LINE, 1.0) if not focused else rgba(SIGNAL, 0.42),
                        width=max(1, round(s(1))))

    f_num = font("JetBrainsMono-Bold", 9.5)
    f_ttl = font("JetBrainsMono-Medium", 9.5)
    tx = x0 + 17
    w = tracked_text(d, (tx, y0 + 17.5), number, f_num,
                     rgba(INK, 1.0) if focused else rgba(INK_DIM, 1.0), tracking=0.5)
    tracked_text(d, (tx + w / SS + 8, y0 + 17.5), title, f_ttl,
                 rgba(INK_DIM if focused else INK_FAINT, 1.0), tracking=0.9)
    return Image.alpha_composite(img, layer)


# --------------------------------------------------------------------------
# 4. The signature: the install gesture drawn as a graph edge
# --------------------------------------------------------------------------
def draw_edge(img: Image.Image) -> Image.Image:
    x_start, x_end = PLATE1[2] + 14, PLATE2[0] - 12
    y = ICON_Y
    # Lift-and-land: the tail rises out of the source node, the head flattens
    # so the arrow arrives horizontally and unmistakably points *into* pane 02.
    span = x_end - x_start
    p0 = (x_start, y)
    p3 = (x_end, y - 4)
    c1 = (x_start + span * 0.30, y - 34)
    c2 = (x_end - span * 0.30, y - 4)
    pts = cbezier(p0, c1, c2, p3)
    apex = min(p[1] for p in pts)

    # The edge is a single filled ribbon masked over a signal -> blue ramp, so
    # the taper is smooth and the colour travels along it.
    grad = h_gradient(img.size, x_start, x_end, SIGNAL, BLUE)
    stroke = Image.new("L", img.size, 0)
    # stop the ribbon ~11pt short of the tip so its end cap stays buried inside
    # the arrowhead instead of poking out either side of the taper
    ImageDraw.Draw(stroke).polygon(ribbon(pts[:-16], 2.2, 3.5), fill=255)

    # glow pass — the same silhouette, blurred, composited underneath
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    glow.paste(grad, (0, 0))
    glow.putalpha(stroke.filter(ImageFilter.GaussianBlur(s(5.0))).point(lambda v: round(v * 0.85)))
    img = Image.alpha_composite(img, glow)

    edge = Image.new("RGBA", img.size, (0, 0, 0, 0))
    edge.paste(grad, (0, 0))
    edge.putalpha(stroke.point(lambda v: round(v * 0.95)))
    img = Image.alpha_composite(img, edge)

    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # source node: this end is one of the graph's nodes, lit up
    nr = s(3.8)
    d.ellipse([s(p0[0]) - s(8.5), s(p0[1]) - s(8.5), s(p0[0]) + s(8.5), s(p0[1]) + s(8.5)],
              outline=rgba(SIGNAL, 0.34), width=max(1, round(s(1))))
    d.ellipse([s(p0[0]) - nr, s(p0[1]) - nr, s(p0[0]) + nr, s(p0[1]) + nr], fill=rgba(SIGNAL, 1.0))

    # arrowhead, oriented along the curve's final tangent
    ax, ay = pts[-1]
    bx, by = pts[-6]
    ang = math.atan2(ay - by, ax - bx)
    L, Wd = s(17.0), s(7.6)
    tip = (s(ax) + math.cos(ang) * s(2.0), s(ay) + math.sin(ang) * s(2.0))
    back = (tip[0] - math.cos(ang) * L, tip[1] - math.sin(ang) * L)
    nx, ny = -math.sin(ang), math.cos(ang)
    d.polygon([tip,
               (back[0] + nx * Wd, back[1] + ny * Wd),
               (back[0] + math.cos(ang) * s(4.5), back[1] + math.sin(ang) * s(4.5)),
               (back[0] - nx * Wd, back[1] - ny * Wd)],
              fill=rgba(BLUE, 1.0))

    # instruction, riding above the apex of the curve
    f = font("JetBrainsMono-Bold", 9.0)
    tracked_text(d, ((x_start + x_end) / 2, apex - 11), "DRAG TO INSTALL", f,
                 rgba(INK, 0.95), tracking=1.5, align="center")
    return Image.alpha_composite(img, layer)


# --------------------------------------------------------------------------
# 5. Wordmark + footer
# --------------------------------------------------------------------------
def draw_chrome(img: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    if LOGO.exists():
        px = round(s(MARK_D))
        mark = Image.open(LOGO).convert("RGBA").resize((px, px), Image.LANCZOS)
        halo = Image.new("RGBA", img.size, (0, 0, 0, 0))
        halo.paste(mark, (round(s(MARK_C[0]) - px / 2), round(s(MARK_C[1]) - px / 2)), mark)
        img = Image.alpha_composite(img, halo.filter(ImageFilter.GaussianBlur(s(4))))
        layer.paste(mark, (round(s(MARK_C[0]) - px / 2), round(s(MARK_C[1]) - px / 2)), mark)

    x = MARK_C[0] + MARK_D / 2 + 12
    f_name = font("JetBrainsMono-Bold", 13.5)
    w = tracked_text(d, (x, 49), "OMNIAGENT", f_name, rgba(INK, 1.0), tracking=2.6)
    x += w / SS + 13
    d.line([(s(x), s(37)), (s(x), s(51))], fill=rgba(LINE, 1.0), width=max(1, round(s(1))))
    f_sub = font("JetBrainsMono-Medium", 10.0)
    tracked_text(d, (x + 13, 49), "ADE", f_sub, rgba(SIGNAL, 1.0), tracking=3.0)

    f_foot = font("JetBrainsMono-Medium", 8.5)
    tracked_text(d, FOOTER_XY, "LOCAL-FIRST  ·  YOUR GRAPH NEVER LEAVES THIS MACHINE",
                 f_foot, rgba(INK_DIM, 0.72), tracking=1.1)
    return Image.alpha_composite(img, layer)


# --------------------------------------------------------------------------
# Compose
# --------------------------------------------------------------------------
def render() -> Image.Image:
    img = Image.new("RGBA", (W * SS, H * SS), VOID_DEEP + (255,))
    img = draw_field(img)

    g = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw_graph(ImageDraw.Draw(g), graph_nodes())
    img = Image.alpha_composite(img, g)

    img = draw_vignette(img)
    img = draw_pane(img, PLATE1, "01", "OMNIAGENT.APP", focused=True)
    img = draw_pane(img, PLATE2, "02", "APPLICATIONS", focused=False)
    img = draw_edge(img)
    img = draw_chrome(img)
    return img


# --------------------------------------------------------------------------
# Preview: background + the two icons where tauri.conf.json will put them.
# Purely a design check — proves the artwork and the icon positions agree.
# --------------------------------------------------------------------------
APPLICATIONS_ICNS = (
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
    "ApplicationsFolderIcon.icns"
)


def load_icon(path: Path | str, size: int) -> Image.Image | None:
    try:
        im = Image.open(path)
        if getattr(im, "n_frames", 1) > 1:  # .icns: pick the largest representation
            best, area = None, -1
            for i in range(im.n_frames):
                im.seek(i)
                if im.size[0] * im.size[1] > area:
                    area, best = im.size[0] * im.size[1], im.convert("RGBA")
            im = best
        return im.convert("RGBA").resize((size, size), Image.LANCZOS)
    except Exception:
        return None


def render_preview(bg: Image.Image) -> Image.Image:
    img = bg.copy()
    d = ImageDraw.Draw(img)
    f = font("Inter-Regular", 11.5)

    app_icon = load_icon(REPO / "src-tauri/icons/128x128@2x.png", round(s(ICON_BOX)))
    apps_icon = load_icon(APPLICATIONS_ICNS, round(s(ICON_BOX)))

    for cx, icon, label in ((ICON1_X, app_icon, "OmniAgent"), (ICON2_X, apps_icon, "Applications")):
        box = round(s(ICON_BOX))
        left, top = round(s(cx) - box / 2), round(s(ICON_Y) - box / 2)
        if icon is not None:
            img.paste(icon, (left, top), icon)
        else:  # stand-in, so the preview still shows the footprint
            d.rounded_rectangle([left, top, left + box, top + box], radius=s(20),
                                fill=rgba(BRAND_BLUE, 0.85))
        # Finder's own label placement: centred, just under the icon box
        ty = ICON_Y + ICON_BOX / 2 + 15
        tw = f.getlength(label)
        d.rounded_rectangle([s(cx) - tw / 2 - s(5), s(ty) - s(11.5),
                             s(cx) + tw / 2 + s(5), s(ty) + s(3.5)],
                            radius=s(4), fill=rgba(BLUE, 0.85))
        d.text((s(cx), s(ty)), label, font=f, fill=rgba(INK, 1.0), anchor="ms")

    # the icon footprint Finder reserves, so collisions are obvious
    for cx in (ICON1_X, ICON2_X):
        b = [s(cx - ICON_BOX / 2), s(ICON_Y - ICON_BOX / 2),
             s(cx + ICON_BOX / 2), s(ICON_Y + ICON_BOX / 2)]
        d.rectangle(b, outline=(255, 0, 128, 110), width=max(1, round(s(0.75))))
    return img


def save(img: Image.Image, name: str, size):
    out = img.resize(size, Image.LANCZOS).convert("RGB")
    path = OUT_DIR / name
    out.save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(REPO)}  {out.width}x{out.height}")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"rendering {W}x{H} at {SS}x supersample ...")
    bg = render()
    save(bg, "dmg-background.png", (W, H))
    save(bg, "dmg-background@2x.png", (W * 2, H * 2))
    save(render_preview(bg), "dmg-window-preview.png", (W, H))
    print("done. windowSize must stay "
          f"{{\"width\": {W}, \"height\": {H}}}, appPosition {{\"x\": {ICON1_X}, \"y\": {ICON_Y}}}, "
          f"applicationFolderPosition {{\"x\": {ICON2_X}, \"y\": {ICON_Y}}}")


if __name__ == "__main__":
    main()
