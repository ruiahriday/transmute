# Usage: python3 make_windows_icon.py <out dir> [<installer dir>]
# Windows tile for Spinform: same gradient rounded square as the Mac icon, but filling the
# canvas edge to edge with a smaller corner radius and no drop shadow under the tile.
import math, sys, io, cairosvg
from PIL import Image
C = 512
def swoosh(a0, sweep, r, wmax, steps=60):
    outer = []; inner = []
    for i in range(steps + 1):
        t = i / steps
        a = math.radians(a0 + sweep * t)
        w = wmax * (0.015 + 0.985 * math.sin(t * math.pi / 2) ** 1.4)
        ro = r + w / 2; ri = r - w / 2
        outer.append((C + ro * math.cos(a), C + ro * math.sin(a)))
        inner.append((C + ri * math.cos(a), C + ri * math.sin(a)))
    d = "M %.1f %.1f " % outer[0] + " ".join("L %.1f %.1f" % p for p in outer[1:])
    d += " A %.1f %.1f 0 0 1 %.1f %.1f " % (wmax / 2, wmax / 2, *inner[-1])
    d += " ".join("L %.1f %.1f" % p for p in reversed(inner)) + " Z"
    return d

def svg(scale, rx, shadow=True):
    blades = "".join('<path d="%s" fill="url(#blade)"/>' % swoosh(-90 + k * 120 + 8, 104, 205, 92) for k in range(3))
    soft = ' filter="url(#soft)"' if shadow else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4338CA"/><stop offset="0.5" stop-color="#8B5CF6"/><stop offset="1" stop-color="#F472B6"/></linearGradient>
<radialGradient id="glow" cx="0.28" cy="0.18" r="0.85"><stop offset="0" stop-color="#fff" stop-opacity="0.30"/><stop offset="0.65" stop-color="#fff" stop-opacity="0"/></radialGradient>
<linearGradient id="blade" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#FDE7F3"/></linearGradient>
<radialGradient id="core" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="#FDBA74"/><stop offset="1" stop-color="#F43F5E"/></radialGradient>
<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#2e1065" flood-opacity="0.35"/></filter>
</defs>
<rect x="0" y="0" width="1024" height="1024" rx="{rx}" fill="url(#bg)"/><rect x="0" y="0" width="1024" height="1024" rx="{rx}" fill="url(#glow)"/>
<g transform="translate(512 512) scale({scale}) translate(-512 -512)"><g{soft}>{blades}<circle cx="512" cy="512" r="78" fill="url(#core)"/><circle cx="512" cy="512" r="78" fill="none" stroke="#fff" stroke-width="14"/></g></g>
</svg>'''

def svg_symbol_only():
    # The white blades and coral core alone, on transparent.
    full = svg(1.0, 0)
    return full.replace('<rect x="0" y="0" width="1024" height="1024" rx="0" fill="url(#bg)"/><rect x="0" y="0" width="1024" height="1024" rx="0" fill="url(#glow)"/>', "")

def render_size(s, w, h):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=s.encode(), output_width=w, output_height=h))).convert("RGBA")

def render(s, px):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=s.encode(), output_width=px, output_height=px))).convert("RGBA")

out = sys.argv[1]
big = svg(1.32, 150)           # 1024 / 824 keeps the Mac proportions; a little larger reads better small
small = svg(1.42, 170, shadow=False)  # 16-32 px: bolder symbol, no inner shadow to blur it
open(f"{out}/icon-windows.svg", "w").write(big)
master = render(big, 1024); master.save(f"{out}/icon-windows.png")
master.resize((256, 256), Image.LANCZOS).save(f"{out}/icon256-windows.png")
frames = []
for px in (16, 24, 32, 48, 64, 256):
    src = render(small if px <= 32 else big, 1024)
    frames.append(src.resize((px, px), Image.LANCZOS))
frames[-1].save(f"{out}/app-windows.ico", format="ICO", sizes=[(f.width, f.height) for f in frames], append_images=frames[:-1])

# Installer pictures (Inno Setup): the tile on white for the small header picture, and a brand
# gradient panel with the mark for the finished page. BMP so every Inno Setup 6 version reads them.
inst = sys.argv[2] if len(sys.argv) > 2 else None
if inst:
    for px in (55, 83, 110):
        bg = Image.new("RGB", (px, px), "white")
        tile = master.resize((px - 6, px - 6), Image.LANCZOS)
        bg.paste(tile, (3, 3), tile)
        bg.save(f"{inst}/wizard-small-{px}.bmp")
    for w, h in ((164, 314), (328, 628)):
        panel = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 164 314">
<defs><linearGradient id="bg" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#4338CA"/><stop offset="0.55" stop-color="#8B5CF6"/><stop offset="1" stop-color="#EC4899"/></linearGradient>
<radialGradient id="glow" cx="0.3" cy="0.2" r="0.8"><stop offset="0" stop-color="#fff" stop-opacity="0.25"/><stop offset="0.7" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>
<rect width="164" height="314" fill="url(#bg)"/><rect width="164" height="314" fill="url(#glow)"/></svg>'''
        img = render_size(panel, w, h)
        # the mark in white blades with its coral core, cut from the Windows tile's symbol
        sym = render(svg_symbol_only(), 1024)
        size = int(w * 0.95)
        sym = sym.resize((size, size), Image.LANCZOS)
        img.paste(sym, ((w - size) // 2, int(h * 0.22)), sym)
        img.convert("RGB").save(f"{inst}/wizard-{w}.bmp")
