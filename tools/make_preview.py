"""Generates the Workshop preview image for Custom DFHack Menu.

Drawn at 256x256 "pixel art" size using DF's curses font, then scaled 4x
with nearest-neighbour so it stays crisp.

    python3 tools/make_preview.py "<Dwarf Fortress>/data/art/curses_800x600.png" preview.png
"""
import random
import sys
from PIL import Image, ImageDraw

FONT, OUT = sys.argv[1], sys.argv[2]
W = H = 256
GW, GH = 10, 12

BG = (22, 19, 15)
STONE = [(26, 22, 18), (30, 26, 21), (24, 21, 17), (33, 28, 22)]
GOLD = (232, 176, 52)
GOLD_DARK = (138, 100, 24)
GOLD_LIGHT = (255, 214, 110)
SHADOW = (10, 8, 5)
PANEL = (30, 28, 26)
WHITE = (226, 226, 220)
GREY = (140, 136, 128)
GREEN = (98, 214, 92)
CYAN = (96, 210, 220)
YELLOW = (255, 224, 70)
SEL_BG = (96, 210, 220)

sheet = Image.open(FONT).convert('RGB')
masks = {}


def glyph(code):
    if code not in masks:
        x, y = (code % 16) * GW, (code // 16) * GH
        # background is magenta (green = 0); glyph pixels are white/grey
        masks[code] = sheet.crop((x, y, x + GW, y + GH)).getchannel('G').point(lambda v: 255 if v > 100 else 0)
    return masks[code]


def text(img, s, x, y, color, scale=1, shadow=None, spacing=0, gw=GW):
    for i, ch in enumerate(s):
        code = ch if isinstance(ch, int) else ord(ch)
        m = glyph(code)
        if scale != 1:
            m = m.resize((GW * scale, GH * scale), Image.NEAREST)
        px = x + i * (gw * scale + spacing)
        if shadow:
            img.paste(shadow, (px + scale, y + scale), m)
        img.paste(color, (px, y), m)


def width(s, scale=1, spacing=0, gw=GW):
    return len(s) * (gw * scale + spacing) - spacing


def centered(img, s, y, color, scale=1, shadow=None, spacing=0):
    text(img, s, (W - width(s, scale, spacing)) // 2, y, color, scale, shadow, spacing)


img = Image.new('RGB', (W, H), BG)
d = ImageDraw.Draw(img)
rnd = random.Random(11)
for ty in range(0, H, 8):
    for tx in range(0, W, 8):
        d.rectangle([tx, ty, tx + 7, ty + 7], fill=rnd.choice(STONE))

# DF-style double gold frame
d.rectangle([3, 3, W - 4, H - 4], outline=GOLD_DARK)
d.rectangle([4, 4, W - 5, H - 5], outline=GOLD, width=2)
d.rectangle([9, 9, W - 10, H - 10], outline=GOLD_DARK)

# title
centered(img, 'CUSTOM', 16, GOLD_LIGHT, scale=2, shadow=SHADOW, spacing=1)
centered(img, 'DFHACK MENU', 42, GOLD, scale=2, shadow=SHADOW, spacing=-3)

# mock of the top-left of the fort screen: DFHack logo, toggle button, top bar,
# and the toolbar hanging under the top bar
BAR = (40, 36, 32)
STEEL = (120, 120, 120)
# DFHack logo box
d.rectangle([16, 66, 38, 92], fill=(236, 236, 230), outline=(90, 90, 90))
text(img, 'DF', 19, 73, (20, 20, 20), gw=8)
# toggle box with a centred green down arrow
d.rectangle([42, 66, 64, 92], fill=PANEL, outline=GOLD)
d.rectangle([43, 67, 63, 91], outline=GOLD_DARK)
for i, w in enumerate([10, 8, 6, 4, 2]):
    y = 76 + i
    d.line([53 - w // 2, y, 53 + w // 2 - 1, y], fill=GREEN)
# top bar
d.rectangle([68, 66, 240, 86], fill=BAR, outline=STEEL)
text(img, 'Pop 15', 74, 70, WHITE, gw=8)
text(img, 'Food ~100', 140, 70, (255, 224, 70), gw=8)
# toolbar under it
tb = ['Quantum', 'Fast Dwarfs']
d.rectangle([68, 89, 240, 105], fill=PANEL, outline=GOLD)
x = 74
for i, name in enumerate(tb):
    if i:
        text(img, [179], x, 92, GREY, gw=8); x += 12
    text(img, name, x, 92, GREEN if name == 'Fast Dwarfs' else WHITE, gw=8)
    x += width(name, gw=8) + 4

# menu panel
px0, py0, px1, py1 = 30, 112, 226, 206
d.rectangle([px0, py0, px1, py1], fill=PANEL, outline=GOLD)
rows = [
    ('launcher', 'Ctrl-D', None),
    ('Quantum', 'Alt-Q', 'sel'),
    ('-- Fort tools --', None, 'head'),
    ('quickfort', 'Ctrl-Q', None),
    ('Fast Dwarfs', 'Alt-F', 'on'),
]
for i, (name, key, kind) in enumerate(rows):
    y = py0 + 7 + i * 17
    if kind == 'sel':
        d.rectangle([px0 + 16, y - 1, px0 + 18 + width(name, gw=8), y + 11], fill=SEL_BG)
    if kind == 'head':
        text(img, name, px0 + 18, y, YELLOW, gw=8)
        continue
    text(img, [26], px0 + 6, y, CYAN, gw=8)  # arrow
    color = (0, 0, 0) if kind == 'sel' else (GREEN if kind == 'on' else CYAN)
    text(img, name, px0 + 18, y, color, gw=8)
    if key:
        text(img, key, px1 - 6 - width(key, gw=8), y, GREEN, gw=8)

# tagline
centered(img, 'your commands, your way', 214, CYAN)
centered(img, 'requires DFHack', 230, GREY)

img.resize((W * 4, H * 4), Image.NEAREST).save(OUT, optimize=True)
print('saved', OUT)
