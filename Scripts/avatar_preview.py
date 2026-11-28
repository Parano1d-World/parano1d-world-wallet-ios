#!/usr/bin/env python3
# Usage: python3 Scripts/avatar_preview.py <output-dir>   (needs Pillow; writes presets.png and options.png)
# Preview renderer mirroring App/CharacterAvatar.swift (VectorCharacterAvatarArt).
# Same 200x200 coordinates and primitive order, so Swift and preview stay in step.
import math, sys
from PIL import Image, ImageDraw, ImageFont

S = 4  # supersample


def head_outline(left, width, ry, fem):
    rx = width / 2; cx = left + rx; cy = 45 + ry; r = left + width; k = 0.5523; b = 45 + ry * 2
    f = lambda v: "%.2f" % v
    x = lambda dx: f(cx + dx); lx = lambda dx: f(cx - dx)
    if fem:
        right = f"C{x(rx)} {f(cy+ry*0.42)} {x(rx-5.5)} {f(b-13)} {x(12.5)} {f(b-4.2)} C{x(7.5)} {f(b-0.9)} {x(3.5)} {f(b)} {f(cx)} {f(b)}"
        left2 = f"C{lx(3.5)} {f(b)} {lx(7.5)} {f(b-0.9)} {lx(12.5)} {f(b-4.2)} C{lx(rx-5.5)} {f(b-13)} {lx(rx)} {f(cy+ry*0.42)} {f(left)} {f(cy)}"
    else:
        right = f"C{x(rx)} {f(cy+ry*0.36)} {x(rx-3.5)} {f(b-15)} {x(rx-13)} {f(b-6.5)} C{x(rx-18.5)} {f(b-2)} {x(7.5)} {f(b)} {f(cx)} {f(b)}"
        left2 = f"C{lx(7.5)} {f(b)} {lx(rx-18.5)} {f(b-2)} {lx(rx-13)} {f(b-6.5)} C{lx(rx-3.5)} {f(b-15)} {lx(rx)} {f(cy+ry*0.36)} {f(left)} {f(cy)}"
    return f"M{f(left)} {f(cy)} C{f(left)} {f(cy-ry*k)} {f(cx-rx*k)} 45 {f(cx)} 45 C{f(cx+rx*k)} 45 {f(r)} {f(cy-ry*k)} {f(r)} {f(cy)} " + right + " " + left2 + " Z"

def angular_jaw(left, width, fem):
    r = left + width; f = lambda v: "%.2f" % v
    chin = 9 if fem else 13; b = 143 if fem else 142
    return (f"M{f(left)} 77 L{f(r)} 77 L{f(r-1.5)} 111 C{f(r-2.5)} 118 {f(100+chin+6)} 136 {f(100+chin)} {f(b-2)} "
            f"C{f(100+chin-3)} {f(b)} {f(103)} {f(b+0.5)} 100 {f(b+0.5)} C{f(97)} {f(b+0.5)} {f(100-chin+3)} {f(b)} {f(100-chin)} {f(b-2)} "
            f"C{f(100-chin-6)} 136 {f(left+2.5)} 118 {f(left+1.5)} 111 Z")

def hexc(v, a=1.0):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255, int(round(255 * a)))

TINT = {"Cyan": 0x32ADE6, "Purple": 0xAF52DE, "Orange": 0xFF9500, "Pink": 0xFF2D55, "Gold": 0xE4B94C,
        "Red": 0xF06C73, "Blue": 0x76A7F4, "Silver": 0xC7D2DD, "Mint": 0x5CF2C4, "Lime": 0xB6F24A,
        "Magenta": 0xE25CF2}
MINT = 0x30E374
SKIN = {"Porcelain": 0xF3D8C5, "Fair": 0xEBC3A2, "Warm": 0xDCA577, "Tan": 0xB97E54, "Brown": 0x885636, "Deep": 0x503426,
        "Mint": 0x8ED8B9, "Lunar": 0xAFC6C7, "Violet": 0xA98CC6, "Emerald": 0x67BE9C}
HAIRC = {"Black": 0x171922, "Brown": 0x51372D, "Blonde": 0xDAB777, "Auburn": 0x954930, "Silver": 0xCDD6DE, "Pink": 0xE571A1,
         "Blue": 0x4C83CE, "Mint": 0x69E4BA, "Copper": 0xC4642D, "Violet": 0x8E5CD9, "White": 0xEEF1F2, "Neon": 0x3BF07A}
BACKS = {"Paper": 0xDBE5DF, "Plum": 0x30233F, "Ocean": 0x153948, "Grid": 0x102C2A, "Exchange": 0x18232B, "Circuit": 0x102D37,
         "Sunset": 0x674337, "Starlight": 0x253956, "Rose": 0x4D2E4A, "Matrix": 0x04140C, "Vault": 0x1A2026, "Aurora": 0x0D1F2A,
         "Skyline": 0x121A33, "Blockchain": 0x0C1A1F, "Void": 0x030507}

DEFAULT = dict(style="Classic", presentation="Masculine", face="Oval", skin="Warm", hair="Crop", hairColor="Black",
               facialHair="None", eyes="Calm", accessory="None", jewelry=None, clothing="Jacket", accent="Green",
               background="Midnight", branding=True)

PRESETS = {
    "Astronaut": dict(clothing="Spacesuit", accessory="Helmet", background="Ocean", accent="Cyan"),
    "Anonymous": dict(style="Anonymous", clothing="Full Anonymous", accessory="Mask", background="Midnight"),
    "Cowboy": dict(clothing="Duster", accessory="Cowboy Hat", background="Paper", accent="Orange"),
    "Alien": dict(face="Alien", hair="Bald", clothing="Spacesuit", skin="Mint", background="Plum"),
    "Paranoid Cat": dict(face="Cat", hair="Bald", clothing="Jacket", background="Midnight"),
    "Cyber Pilot": dict(style="Cyber", clothing="Armor", accessory="Visor", background="Grid", accent="Cyan"),
    "Space Ranger": dict(clothing="Spacesuit", accessory="Helmet", background="Plum", accent="Purple"),
    "Crypto Trader": dict(style="Cyber", clothing="Suit", accessory="Shades", jewelry="Chain", background="Exchange", accent="Gold"),
    "Cyber Hero": dict(style="Cyber", clothing="Hero Armor", accessory="Visor", background="Circuit", accent="Cyan"),
    # New in build 157
    "Hacker": dict(style="Hooded", clothing="Hoodie", hair="Undercut", eyes="Glow", accessory="Earpiece", background="Matrix", accent="Green"),
    "Node Runner": dict(style="Cyber", clothing="Bomber", hair="Ponytail", hairColor="Neon", accessory="Cyber Eye", background="Blockchain", accent="Mint", presentation="Feminine"),
    "Miner": dict(clothing="Tactical", accessory="Respirator", hair="Buzz", background="Vault", accent="Orange", skin="Tan"),
    "Robot": dict(face="Robot", hair="Bald", clothing="Armor", eyes="Glow", background="Circuit", accent="Cyan"),
    "Ghost": dict(style="Hooded", clothing="Trench", accessory="Bandana", eyes="Sly", hair="Bob", hairColor="White", background="Void", accent="Silver", presentation="Feminine", skin="Porcelain"),
    "Vault Keeper": dict(clothing="Turtleneck", accessory="Monocle", hair="Bun", hairColor="Silver", background="Vault", accent="Gold", presentation="Feminine", skin="Brown"),
    "Neon Ronin": dict(style="Cyber", clothing="Trench", hair="Bun", accessory="Bandana", facialHair="Goatee", background="Skyline", accent="Magenta", skin="Fair"),
    "Whale": dict(clothing="Suit", accessory="Crown", jewelry="Double chain", eyes="Wink", hair="Afro", background="Aurora", accent="Gold", skin="Deep"),
}

def preset(name):
    c = dict(DEFAULT); c.update(PRESETS.get(name, {})); return c


# Hand-drawn hair art shared with the app (Scripts/hair_art/styles.py -> App/HairArt.swift).
import os as _os, re as _re
sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "hair_art"))
from styles import S as HAIR_ART
def svg_subpaths(d):
    toks = _re.findall(r"[MLCQZ]|-?\d*\.?\d+(?:e-?\d+)?", d)
    subs, cur, i, cmd, pos = [], [], 0, "M", (0, 0)
    def num():
        nonlocal i
        i += 1; return float(toks[i - 1])
    while i < len(toks):
        if toks[i] in "MLCQZ":
            cmd = toks[i]; i += 1
            if cmd == "Z":
                if cur: subs.append((cur, True)); cur = []
                continue
        if cmd == "M":
            if cur: subs.append((cur, False))
            pos = (num(), num()); cur = [pos]; cmd = "L"
        elif cmd == "L":
            pos = (num(), num()); cur.append(pos)
        elif cmd == "C":
            a = (num(), num()); b = (num(), num()); e = (num(), num())
            for k in range(1, 17):
                t = k / 16; u = 1 - t
                cur.append((u**3*pos[0]+3*u*u*t*a[0]+3*u*t*t*b[0]+t**3*e[0], u**3*pos[1]+3*u*u*t*a[1]+3*u*t*t*b[1]+t**3*e[1]))
            pos = e
        elif cmd == "Q":
            a = (num(), num()); e = (num(), num())
            for k in range(1, 13):
                t = k / 12; u = 1 - t
                cur.append((u*u*pos[0]+2*u*t*a[0]+t*t*e[0], u*u*pos[1]+2*u*t*a[1]+t*t*e[1]))
            pos = e
        else:
            i += 1
    if cur: subs.append((cur, False))
    return subs

def render(c, size=256):
    W = 200 * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 255))
    def layer():
        return Image.new("RGBA", (W, W), (0, 0, 0, 0))
    def comp(l):
        nonlocal img
        img = Image.alpha_composite(img, l)
    def P(x): return x * S
    def ellipse(x, y, w, h, col):
        l = layer(); ImageDraw.Draw(l).ellipse([P(x), P(y), P(x + w), P(y + h)], fill=col); comp(l)
    def rect(x, y, w, h, col):
        l = layer(); ImageDraw.Draw(l).rectangle([P(x), P(y), P(x + w), P(y + h)], fill=col); comp(l)
    def rrect(x, y, w, h, r, fill=None, stroke=None, width=0):
        l = layer(); ImageDraw.Draw(l).rounded_rectangle([P(x), P(y), P(x + w), P(y + h)], radius=P(r), fill=fill, outline=stroke, width=int(P(width))); comp(l)
    def polygon(pts, col):
        l = layer(); ImageDraw.Draw(l).polygon([(P(x), P(y)) for x, y in pts], fill=col); comp(l)
    def line(pts, col, width=2):
        l = layer(); d = ImageDraw.Draw(l); w = max(1, int(P(width)))
        q = [(P(x), P(y)) for x, y in pts]
        d.line(q, fill=col, width=w, joint="curve")
        for x, y in q: d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=col)
        comp(l)
    def smooth_pts(pts, closed=True):
        # Quadratic curves through edge midpoints (same as the Swift `smooth`).
        n = len(pts); out = []
        mids = [((pts[i][0] + pts[(i + 1) % n][0]) / 2, (pts[i][1] + pts[(i + 1) % n][1]) / 2) for i in range(n)]
        for i in range(n):
            a = mids[i - 1]; ctrl = pts[i]; b = mids[i]
            for k in range(12):
                t = k / 12
                out.append(((1 - t) ** 2 * a[0] + 2 * (1 - t) * t * ctrl[0] + t * t * b[0], (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * ctrl[1] + t * t * b[1]))
        return out
    def smooth_open(pts):
        # Open curve through midpoints, ending at the first and last points.
        out = [pts[0]]
        for i in range(1, len(pts) - 1):
            a = pts[i - 1] if i == 1 else ((pts[i - 1][0] + pts[i][0]) / 2, (pts[i - 1][1] + pts[i][1]) / 2)
            b = pts[i + 1] if i == len(pts) - 2 else ((pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2)
            for k in range(1, 13):
                t = k / 12
                out.append(((1 - t) ** 2 * a[0] + 2 * (1 - t) * t * pts[i][0] + t * t * b[0], (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * pts[i][1] + t * t * b[1]))
        return out
    def smooth(pts, col):
        polygon(smooth_pts(pts), col)
    def ring(x, y, w, h, col, width):
        l = layer(); ImageDraw.Draw(l).ellipse([P(x), P(y), P(x + w), P(y + h)], outline=col, width=int(P(width))); comp(l)
    def radial(cx, cy, r0, r1, inner, outer):
        l = layer(); px = l.load()
        # coarse radial gradient: concentric rings
        steps = 40
        d = ImageDraw.Draw(l)
        for i in range(steps, -1, -1):
            t = i / steps; r = r0 + (r1 - r0) * t
            col = tuple(int(inner[k] + (outer[k] - inner[k]) * t) for k in range(4))
            d.ellipse([P(cx - r), P(cy - r), P(cx + r), P(cy + r)], fill=col)
        comp(l)

    accent_hex = TINT.get(c["accent"], MINT)
    A = lambda a=1.0: hexc(accent_hex, a)
    skin_hex = SKIN.get(c["skin"], 0xDCA577)
    skin = hexc(skin_hex)
    hair = lambda a=1.0: hexc(HAIRC.get(c["hairColor"], 0x171922), a)
    _hh = HAIRC.get(c["hairColor"], 0x171922)
    def hair_shade(amount, alpha=1.0):
        return tuple(int(((_hh >> sh) & 255) + ((((0x18212B >> sh) & 255) - ((_hh >> sh) & 255)) * amount)) for sh in (16, 8, 0)) + (int(255 * alpha),)
    brows = hair_shade(0.5)
    ink = lambda a=1.0: hexc(0x18212B, a)
    white = lambda a=1.0: (255, 255, 255, int(255 * a))
    black = lambda a=1.0: (0, 0, 0, int(255 * a))
    special = c["face"] in ("Alien", "Cat", "Robot")
    face_w = 83 if c["face"] == "Round" else 71 if c["face"] == "Angular" else 75
    # Hair stays under whatever covers the head (same rule as the app).
    _hood = c["style"] in ("Hooded", "Anonymous") or c["clothing"] in ("Hoodie", "Full Anonymous")
    _acc = c["accessory"]
    def hair_clip_mask():
        m = Image.new("L", (200 * S, 200 * S), 0); dm = ImageDraw.Draw(m)
        if c["clothing"] == "Spacesuit": dm.ellipse([45 * S, 32 * S, 155 * S, 152 * S], fill=255)
        elif _hood: dm.ellipse([48 * S, 32 * S, 152 * S, 158 * S], fill=255)
        elif _acc in ("Beanie", "Cap"): dm.rectangle([0, 60 * S, 200 * S, 200 * S], fill=255)
        elif _acc == "Cowboy Hat": dm.rectangle([0, 56 * S, 200 * S, 200 * S], fill=255)
        elif _acc == "Crown": dm.rectangle([0, 44 * S, 200 * S, 200 * S], fill=255)
        elif _acc == "Helmet": dm.rounded_rectangle([54 * S, 47 * S, 146 * S, 138 * S], radius=30 * S, fill=255)
        else: return None
        return m
    def draw_hair_art(layers):
        nonlocal img
        mask = hair_clip_mask()
        before = img.copy() if mask is not None else None
        _draw_hair_art(layers)
        if mask is not None:
            img = Image.composite(img, before, mask)
    def _draw_hair_art(layers):
        sx = face_w / 75; sy = 47 / 51 if c["face"] == "Round" else 1
        fit = lambda q: (100 + (q[0] - 100) * sx, 45 + (q[1] - 45) * sy)
        for d, role in layers:
            for pts, closed in svg_subpaths(d):
                pts = [fit(q) for q in pts]
                if role in ("lightline", "shadeline"):
                    line(pts, white(0.16) if role == "lightline" else black(0.22), 1.6)
                elif closed or len(pts) > 2:
                    polygon(pts, {"hair": hair(), "fill": hair(), "stubble": hair(0.4), "shade": black(0.22), "light": white(0.16)}[role])
                    if role == "hair": line(pts + ([pts[0]] if closed else []), black(0.16), 0.9)

    # Background
    rect(0, 0, 200, 200, hexc(BACKS.get(c["background"], 0x0A151B)))
    bg = c["background"]
    if bg == "Grid":
        for x in range(0, 201, 20): line([(x, 0), (x, 200)], A(0.16), 1)
    if bg == "Exchange":
        for x in range(0, 201, 25): line([(x, 0), (x, 200)], A(0.08), 1)
        line([(0, 125), (35, 108), (70, 117), (104, 75), (143, 88), (200, 42)], A(0.55), 2)
    if bg == "Circuit":
        for y in range(8, 201, 24): line([(0, y), (200, y)], A(0.12), 1)
        for x in range(12, 201, 24): line([(x, 0), (x, 200)], A(0.12), 1)
    if bg == "Starlight":
        for x in range(18, 186, 33): ellipse(x, (x * 31) % 170, 3, 3, white(0.7))
    # --- new backgrounds ---
    if bg == "Matrix":
        for col in range(0, 13):
            x = 6 + col * 16; top = (col * 37) % 60
            for k in range(0, 9):
                y = top + k * 16
                if y < 200: rect(x, y, 3, 8, A(0.10 + 0.05 * ((col + k) % 3)))
    if bg == "Vault":
        ring(10, 10, 180, 180, A(0.22), 3); ring(30, 30, 140, 140, A(0.14), 2)
        for k in range(12):
            a = k * math.pi / 6
            line([(100 + 70 * math.cos(a), 100 + 70 * math.sin(a)), (100 + 90 * math.cos(a), 100 + 90 * math.sin(a))], A(0.20), 3)
    if bg == "Aurora":
        polygon([(0, 70), (40, 40), (90, 62), (140, 30), (200, 52), (200, 88), (140, 66), (90, 96), (40, 76), (0, 104)], A(0.22))
        polygon([(0, 104), (50, 84), (100, 104), (150, 80), (200, 96), (200, 118), (150, 102), (100, 124), (50, 106), (0, 126)], hexc(0x8E5CD9, 0.18))
    if bg == "Skyline":
        for i, (x, h) in enumerate([(0, 70), (22, 105), (44, 80), (70, 120), (98, 90), (124, 130), (150, 85), (174, 110)]):
            rect(x, 200 - h, 24, h, hexc(0x0A1022))
            for wy in range(200 - h + 8, 196, 12):
                rect(x + 6, wy, 3, 4, A(0.35 if (i + wy) % 3 else 0.12)); rect(x + 14, wy, 3, 4, A(0.12 if (i + wy) % 2 else 0.30))
    if bg == "Blockchain":
        for i, (x, y) in enumerate([(14, 22), (60, 12), (112, 26), (158, 14)]):
            rrect(x, y, 30, 22, 4, stroke=A(0.35), width=2)
            if i < 3: line([(x + 30, y + 11), (x + 46, y + 11 + (4 if i % 2 == 0 else -4))], A(0.30), 2)
    if bg == "Void":
        ring(20, 20, 160, 160, A(0.10), 1)
    # Quality: soft halo behind the figure (existing) and edge vignette (new)
    if c["style"] != "Minimal": ellipse(16, 10, 168, 168, A(0.14))
    if c["style"] == "Cyber":
        for x in range(12, 189, 16): line([(x, 0), (x, 200)], A(0.12), 1)
        for y in range(8, 201, 16): line([(0, y), (200, y)], A(0.12), 1)

    if not special:  # hair that falls behind the head and shoulders goes under the body
        draw_hair_art(HAIR_ART.get(c["hair"], {}).get("back", []))
    shoulders = 154 if c["presentation"] == "Masculine" else 130
    cl = c["clothing"]
    outfit_hex = {"Armor": 0x344850, "Hero Armor": 0x344850, "Spacesuit": 0xDCE4E6, "Duster": 0x69452E, "Suit": 0x171E2C,
                  "Trench": 0x3B3428, "Turtleneck": 0x1C1F26, "Bomber": 0x2F3B2A, "Tactical": 0x2C3328, "Lab Coat": 0xE8EEF0}.get(cl, 0x26333F)
    outfit = A(0.8) if cl == "T-shirt" else hexc(outfit_hex)
    ellipse((200 - shoulders) / 2, 141, shoulders, 112, outfit)
    # Quality: shoulder shading
    ellipse((200 - shoulders) / 2 + 8, 176, shoulders - 16, 70, black(0.12))
    hood = c["style"] in ("Hooded", "Anonymous") or cl in ("Hoodie", "Full Anonymous")
    if hood:
        ellipse(39, 22, 122, 148, hexc(0x25323A)); ellipse(48, 32, 104, 126, hexc(0x101A21))
    if cl == "Spacesuit":
        ellipse(31, 18, 138, 151, hexc(0xB9C8CB)); ellipse(37, 24, 126, 137, A(0.5)); ellipse(45, 32, 110, 120, hexc(0x101A21))
    h = c["hair"]
    if not special:
        polygon([(88, 120), (112, 120), (115, 154), (85, 154)], skin)
        smooth([(87, 122), (113, 122), (113, 134), (100, 139), (87, 134)], black(0.16))
    width = 83 if c["face"] == "Round" else 71 if c["face"] == "Angular" else 75
    left = (200 - width) / 2
    right = left + width
    # Skull outline: the top of every human head is this ellipse (Angular
    # has its own rounded crown on a sharp jaw), so hair can hug it.
    sk_cy, sk_ry = (92, 47) if c["face"] == "Round" else (77, 32) if c["face"] == "Angular" else (96, 51)
    sk_rx = width / 2
    def skull_half(y):
        # Half-width of the skull at height y (straight sides below an Angular crown).
        if y >= sk_cy: return sk_rx
        q = (sk_cy - y) / sk_ry
        return sk_rx * math.sqrt(max(0.0, 1 - q * q))
    def arc_pts(temple, pad_x, pad_y, n=24, taper=True):
        # Skull outline from the left temple over the top to the right temple.
        # The padding grows from 0 at the temples to full at the crown, so hair
        # meets the side of the head exactly instead of sticking out as wings.
        s0 = min(1.0, max(0.0, (sk_cy - temple) / sk_ry)); t0 = math.asin(s0)
        pts = []
        for i in range(n + 1):
            t = t0 + (math.pi - 2 * t0) * i / n
            k = 1.0 if not taper else 0.0 if s0 >= 1 else max(0.0, (math.sin(t) - s0) / (1 - s0)) ** 0.5
            pts.append((100 - (sk_rx + pad_x * k) * math.cos(t), sk_cy - (sk_ry + pad_y * k) * math.sin(t)))
        if temple > sk_cy:
            pts = [(100 - sk_rx, temple)] + pts + [(100 + sk_rx, temple)]
        return pts
    def cap_pts(temple, hairline, pad_x=1.5, pad_y=1.5, sweep=0.0):
        # Hair hugging the skull, closed along a natural hairline that starts
        # just inside the head at the temples and flattens across the forehead.
        pts = arc_pts(temple, pad_x, pad_y)
        hw = skull_half(temple - 4) - 1
        for i in range(17):
            u = 1 - 2 * i / 16
            # A soft arch that curves down into the temples (no flat headband
            # edge); sweep drops the left side for a side part.
            pts.append((100 + hw * u, hairline + (temple - 4 - hairline) * u * u + sweep * (1 - u * u) * (1 - u) / 2))
        return pts
    if not special:
        ellipse(left - 7, 84, 16, 25, skin); ellipse(left + width - 9, 84, 16, 25, skin)
    face = c["face"]
    if face == "Cat":
        polygon([(59, 79), (57, 28), (79, 56), (121, 56), (143, 28), (141, 79), (133, 129), (100, 144), (67, 129)], skin)
        polygon([(62, 39), (68, 67), (78, 57)], A(0.7)); polygon([(138, 39), (132, 67), (122, 57)], A(0.7))
    elif face == "Alien":
        polygon([(100, 27), (129, 38), (148, 65), (145, 94), (128, 121), (111, 139), (100, 149), (89, 139), (72, 121), (55, 94), (52, 65), (71, 38)], skin)
        ellipse(61, 46, 78, 50, skin)
    elif face == "Robot":
        metal = hexc(0x9AA8B2)
        rect(90, 128, 20, 26, hexc(0x5E6B74))
        for y in (133, 141, 149): rect(90, y, 20, 2, black(0.25))
        rrect(58, 40, 84, 96, 18, fill=metal)
        rrect(58, 40, 84, 96, 18, stroke=hexc(0x6E7C86), width=3)
        rect(52, 76, 8, 26, hexc(0x6E7C86)); rect(140, 76, 8, 26, hexc(0x6E7C86))
        line([(100, 40), (100, 24)], hexc(0x6E7C86), 3); ellipse(95, 17, 10, 10, A())
        rrect(68, 78, 64, 22, 8, fill=ink())
        rect(80, 116, 40, 8, ink()); [rect(84 + k * 8, 116, 2, 8, metal) for k in range(4)]
        line([(62, 50), (70, 44)], white(0.5), 3)
    elif face == "Angular":
        ellipse(left, 45, width, 64, skin)
        [polygon(pts, skin) for pts, _ in svg_subpaths(angular_jaw(left, width, c["presentation"] == "Feminine"))]
    else:
        [polygon(pts, skin) for pts, _ in svg_subpaths(head_outline(left, width, 47 if face == "Round" else 51, c["presentation"] == "Feminine"))]
    if not special:
        # Quality: soft jaw shading and cheek light
        if c["presentation"] == "Feminine":
            ellipse(left + 7, 98, 15, 9, hexc(0xE0736B, 0.20)); ellipse(left + width - 22, 98, 15, 9, hexc(0xE0736B, 0.20))
    if not special:
        draw_hair_art(HAIR_ART.get(h, {}).get("front", []))
    e = c["eyes"]
    fem = c["presentation"] == "Feminine"
    def fill_d(d, col):
        for pts, closed in svg_subpaths(d): polygon(pts, col)
    def stroke_d(d, col, w):
        for pts, closed in svg_subpaths(d): line(pts + ([pts[0]] if closed else []), col, w)
    def eye(cx, cy, kind, side):
        if kind == "Wink" and side > 0:
            stroke_d(f"M{cx-5.5} {cy} C{cx-2} {cy+3} {cx+2} {cy+3} {cx+5.5} {cy}", ink(0.9), 2); return
        rx = 5.6 if fem else 5.0
        ry = (4.6 if fem else 3.7) if kind == "Wide" else (3.9 if fem else 2.9)
        ir = 3.3 if fem else 2.8
        glow = kind == "Glow"
        if glow: ellipse(cx - 8, cy - 7.5, 16, 15, A(0.35))
        ellipse(cx - rx, cy - ry, rx * 2, ry * 2, hexc(0xF5F0EA))
        ellipse(cx - ir, cy + 0.2 - ir, ir * 2, ir * 2, A() if glow else hexc(0x3A2B22))
        ellipse(cx - ir / 2, cy + 0.2 - ir / 2, ir, ir, A(0.6) if glow else hexc(0x0D1116))
        ellipse(cx + 1.1 - 0.95, cy - 1 - 0.95, 1.9, 1.9, white())
        top = cy - ry; drop = 1.6 if kind == "Focused" else 2.6 if kind == "Sly" else 0
        fill_d(f"M{cx-rx-1.5} {cy-ry-3} L{cx+rx+1.5} {cy-ry-3} L{cx+rx+1.5} {cy-ry+drop+0.3} C{cx+rx*0.5} {top-0.8+drop} {cx-rx*0.5} {top-0.8+drop} {cx-rx-1.5} {cy-ry+drop+0.3} Z", skin)
        if kind == "Friendly":
            fill_d(f"M{cx-rx-1.5} {cy+ry+3} L{cx+rx+1.5} {cy+ry+3} L{cx+rx+1.5} {cy+1.2} C{cx+rx*0.5} {cy-0.6} {cx-rx*0.5} {cy-0.6} {cx-rx-1.5} {cy+1.2} Z", skin)
        arch_l = 1 if fem else 0.2
        stroke_d(f"M{cx-rx-0.6} {cy+0.4+drop*0.4} C{cx-rx*0.6} {top-arch_l+drop} {cx+rx*0.6} {top-arch_l+drop} {cx+rx+0.6} {cy+0.4+drop*0.4}", ink(0.92), 2.4 if fem else 2.0)
        if fem:
            ox = cx + side * (rx + 0.3)
            stroke_d(f"M{ox} {cy-0.8} L{ox+side*3.0} {cy-2.8} M{ox-side*1.8} {cy-2.9} L{ox+side*0.4} {cy-5.2} M{ox-side*4.0} {cy-3.6} L{ox-side*3.2} {cy-6.0}", ink(0.92), 1.4)
        else:
            stroke_d(f"M{cx-rx+0.8} {cy+ry+0.9} C{cx-1.5} {cy+ry+1.9} {cx+1.5} {cy+ry+1.9} {cx+rx-0.8} {cy+ry+0.9}", black(0.12), 1.2)
    if not special:
        for side in (-1, 1):
            cx = 100 + side * 15
            y = (78.6 if fem else 80.6) + (0.6 if e == "Focused" else 0)
            lift = -1.6 if (e == "Sly" and side > 0) else 0; arch = 2.8 if fem else 0.5
            stroke_d(f"M{cx-side*6.8} {y+1.0+lift*0.3} Q{cx+side*2.5} {y-arch+lift-0.8} {cx+side*7.4} {y+(1.8 if fem else 0.6)+lift}", brows, 2.0 if fem else 3.6)
        eye(85, 89, e, -1); eye(115, 89, e, 1)
    if face == "Alien":
        polygon([(63, 82), (82, 75), (93, 88), (83, 108), (69, 102)], ink()); polygon([(137, 82), (118, 75), (107, 88), (117, 108), (131, 102)], ink())
        ellipse(76, 85, 5, 7, A(0.55)); ellipse(119, 85, 5, 7, A(0.55))
    if face == "Robot":
        glow = A() if e == "Glow" or True else A()
        ellipse(76, 83, 14, 12, A(0.95)); ellipse(110, 83, 14, 12, A(0.95))
        ellipse(80, 86, 4, 4, white(0.85)); ellipse(114, 86, 4, 4, white(0.85))
    if face == "Cat":
        ellipse(76, 87, 10, 11, ink()); ellipse(114, 87, 10, 11, ink())
        polygon([(92, 105), (108, 105), (100, 114)], ink()); line([(100, 114), (100, 121)], ink(), 2)
        line([(87, 117), (100, 122), (113, 117)], ink(), 2)
        for y in (106.0, 113.0): line([(62, y), (86, y + 3)], ink(0.6), 1); line([(114, y + 3), (138, y)], ink(0.6), 1)
    elif face == "Alien":
        line([(94, 119), (106, 119)], ink(0.7), 2)
    elif face != "Robot":
        L, R = left, left + width
        stroke_d(f"M{L-4} 92 C{L-4.5} 89 {L-2} 87.5 {L} 89 C{L+1} 93 {L+0.5} 99 {L-1} 103", black(0.14), 1.3)
        stroke_d(f"M{R+4} 92 C{R+4.5} 89 {R+2} 87.5 {R} 89 C{R-1} 93 {R-0.5} 99 {R+1} 103", black(0.14), 1.3)
        stroke_d("M101.5 95 C102.5 99.5 103.5 103 103.8 105.5", black(0.13), 1.3)
        stroke_d("M95.8 106.2 C97 108.4 99 108.8 100 108.2 C101 108.8 103 108.4 104.2 106.2", ink(0.35), 1.5)
        ellipse(96.4, 102.4, 7.2, 4.8, white(0.10))
        # Facial hair sits under the mouth so the expression always reads.
        fh = c["facialHair"]
        jl, jr = left, left + width
        bottom = 151 if face == "Round" else 147 if face == "Angular" else 153
        stache = [(85, 117), (92, 112.5), (100, 114.5), (108, 112.5), (115, 117), (110, 119.5), (100, 117.5), (90, 119.5)]
        if fh in ("Beard", "Stubble"):
            beard = [(jl + 1, 84), (jl + 5, 103), (75, 113), (86, 110), (100, 112), (114, 110), (125, 113), (jr - 5, 103), (jr - 1, 84),
                     (jr + 1, 112), (130, 136), (116, bottom - 4), (100, bottom), (84, bottom - 4), (70, 136), (jl - 1, 112)]
            if fh == "Beard":
                smooth(beard, hair_shade(0.25))
                smooth([(70, 128), (84, 142), (100, bottom - 6), (116, 142), (130, 128), (126, 142), (100, bottom), (74, 142)], black(0.18))
                smooth(stache, hair_shade(0.25))
            else:
                hd = angular_jaw(left, width, fem) if face == "Angular" else head_outline(left, width, 47 if face == "Round" else 51, fem)
                l = layer(); ImageDraw.Draw(l).polygon([(P(x), P(y)) for x, y in smooth_pts(beard)], fill=hair_shade(0.5, 0.17))
                m = Image.new("L", (W, W), 0)
                for pts, _ in svg_subpaths(hd): ImageDraw.Draw(m).polygon([(P(x), P(y)) for x, y in pts], fill=255)
                a = l.getchannel("A"); l.putalpha(Image.composite(a, Image.new("L", (W, W), 0), m)); comp(l)
                smooth(stache, hair_shade(0.5, 0.22))
        elif fh == "Mustache":
            smooth(stache, hair_shade(0.25))
        elif fh == "Goatee":
            smooth(stache, hair_shade(0.25))
            smooth([(90, 127), (100, 126), (110, 127), (109, 136), (104, bottom - 7), (96, bottom - 7), (91, 136)], hair_shade(0.25))
        covered = c["accessory"] in ("Bandana", "Respirator", "Mask")
        mouth = ink(0.85) if fh == "Beard" else ink(0.72)
        if fh == "Beard": fill_d("M90 120.5 C95 119 105 119 110 120.5 C106 125 94 125 90 120.5 Z", hexc(0x8C4F45, 0.9))
        if e == "Friendly":
            fill_d("M90.5 119.5 C94 126.5 106 126.5 109.5 119.5 C103 121 97 121 90.5 119.5 Z", hexc(0x5A2328))
            fill_d("M92.5 120.4 C97 121.6 103 121.6 107.5 120.4 L107 122 C102.5 123 97.5 123 93 122 Z", white(0.92))
        else:
            if fem and fh != "Beard" and not covered:
                fill_d("M91 121 C94 119 97 118.6 100 119.6 C103 118.6 106 119 109 121 C106 125.6 94 125.6 91 121 Z", hexc(0xB4505A, 0.55))
            if e == "Sly": stroke_d("M91 122 C95 123 101 122.6 104 121.4 C106 120.6 108 119.4 109.5 118.2", mouth, 1.9)
            elif fem: stroke_d("M91.5 121 C95.5 123.3 104.5 123.3 108.5 121", mouth, 1.9)
            else: stroke_d("M91.5 121.6 C95.5 122.8 104.5 122.8 108.5 121.6", mouth, 2.1)
        if fh != "Beard": stroke_d("M96.5 126.8 C98.5 127.5 101.5 127.5 103.5 126.8", black(0.07), 1.1)
    acc = c["accessory"]
    if c["style"] == "Anonymous" or acc == "Mask":
        por = hexc(0xE6EBE5)
        polygon([(66, 69), (79, 61), (100, 58), (121, 61), (134, 69), (132, 113), (119, 136), (100, 148), (81, 136), (68, 113)], por)
        line([(73, 85), (89, 82), (94, 87)], ink(), 4); line([(106, 87), (111, 82), (127, 85)], ink(), 4)
        polygon([(75, 91), (88, 89), (93, 94), (85, 98)], ink()); polygon([(107, 94), (112, 89), (125, 91), (115, 98)], ink())
        polygon([(78, 119), (87, 118), (96, 116), (100, 119), (104, 116), (113, 118), (122, 119), (112, 123), (103, 122), (100, 125), (97, 122), (88, 123)], ink())
        polygon([(94, 136), (100, 139), (106, 136), (100, 147)], ink())
    elif acc in ("Glasses", "Shades", "Sunglasses"):
        for x in (68.0, 108.0):
            rrect(x, 83, 26, 20, 6, fill=ink() if acc != "Glasses" else A(0.15), stroke=A(), width=2)
        line([(94, 90), (108, 90)], A())
    elif acc == "Visor":
        rrect(65, 82, 70, 22, 7, fill=A(0.85)); line([(72, 88), (124, 88)], white(0.7), 2)
    elif acc == "Piercing":
        ellipse(57, 105, 6, 9, A())
    elif acc == "Monocle":
        ring(108, 81, 24, 24, hexc(0xE4B94C), 2.5); ellipse(110, 83, 20, 20, white(0.12))
        line([(132, 96), (138, 118), (134, 150)], hexc(0xE4B94C), 1.5)
    elif acc == "Eyepatch":
        line([(60, 74), (140, 98)], ink(), 3); ellipse(108, 80, 26, 22, ink())
    elif acc == "Cyber Eye":
        rrect(106, 80, 28, 22, 6, fill=hexc(0x2A3640), stroke=A(), width=2)
        ellipse(114, 85, 12, 12, A()); ellipse(118, 89, 4, 4, white(0.9))
        line([(134, 91), (146, 91), (150, 104)], A(0.8), 2)
    elif acc == "Bandana":
        polygon([(64, 106), (136, 106), (132, 128), (100, 146), (68, 128)], A(0.9))
        for x in range(74, 128, 10): ellipse(x, 116, 4, 4, white(0.35))
    elif acc == "Respirator":
        rrect(76, 108, 48, 30, 12, fill=hexc(0x2C3338)); ellipse(64, 114, 20, 20, hexc(0x4A555D)); ellipse(116, 114, 20, 20, hexc(0x4A555D))
        ellipse(69, 119, 10, 10, A(0.7)); ellipse(121, 119, 10, 10, A(0.7))
        for y in (116, 122, 128): line([(88, y), (112, y)], black(0.5), 1.5)
    if acc == "Beanie":
        dome = arc_pts(68, 7, 18, taper=False)
        polygon(dome + [(right + 4, 68), (left - 4, 68)], A())
        # Folded cuff across the forehead, with knit ribs.
        smooth([(left - 5, 58), (100, 53), (right + 5, 58), (right + 5, 71), (100, 67), (left - 5, 71)], A())
        smooth([(left - 5, 58), (100, 53), (right + 5, 58), (right + 5, 71), (100, 67), (left - 5, 71)], black(0.14))
        for k in range(1, 12):
            x = left - 3 + (width + 6) * k / 12
            line([(x, 58 - 4 * math.cos((x - 100) / 50)), (x, 68 - 2 * math.cos((x - 100) / 50))], black(0.12), 1)
    elif acc == "Cap":
        crown = arc_pts(66, 6, 20, taper=False)
        polygon(crown + [(right + 4, 66), (left - 4, 66)], A())
        polygon(crown + [(right + 4, 66), (left - 4, 66)], black(0.10))
        line([(100, sk_cy - sk_ry - 20), (100, 64)], black(0.18), 1.2); ellipse(97, sk_cy - sk_ry - 22, 6, 4, A())
        # Brim seen from the front: a curved band across the forehead.
        smooth([(left - 7, 63), (100, 57), (right + 7, 63), (right + 6, 70), (100, 75), (left - 6, 70)], A())
        smooth([(left - 6, 68), (100, 71), (right + 6, 68), (right + 6, 70), (100, 75), (left - 6, 70)], black(0.28))
    if acc == "Cowboy Hat":
        ellipse(40, 40, 120, 24, hexc(0x69452E)); rect(70, 20, 60, 29, hexc(0x69452E)); rect(72, 41, 56, 5, A())
    if acc == "Helmet":
        rrect(50, 43, 100, 99, 34, stroke=hexc(0xDCE4E6), width=9)
        line([(60, 64), (70, 49), (90, 42)], white(0.65), 4)
    if acc == "Headphones":
        ellipse(48, 61, 12, 53, A()); ellipse(140, 61, 12, 53, A())
        line([(54, 68), (60, 38), (100, 28), (140, 38), (146, 68)], A(), 4)
    if acc == "Crown":
        gold = hexc(0xE4B94C)
        polygon([(66, 44), (66, 18), (80, 32), (90, 12), (100, 28), (110, 12), (120, 32), (134, 18), (134, 44)], gold)
        rect(66, 38, 68, 8, hexc(0xC99B2E))
        for x, col in ((78, A()), (97, hexc(0xF06C73)), (116, A())): ellipse(x, 37, 7, 7, col)
    if acc == "Halo":
        ring(64, 8, 72, 20, hexc(0xF4D899), 4); ring(66, 10, 68, 16, white(0.5), 1.5)
    if acc == "Earpiece":
        ellipse(left + width - 6, 92, 10, 12, ink()); ellipse(left + width - 3, 95, 4, 4, A())
        line([(left + width + 2, 104), (left + width - 8, 120), (112, 122)], ink(0.8), 1.5)
    # Necklines and garment details. Everything here belongs to the garment;
    # none of it depends on the NOID badge, so turning branding off leaves a
    # finished outfit, not orphaned lines.
    darker = lambda v, a=0.28: black(a)
    tee = hexc(0x161D24)
    def open_neck(depth):
        # Undershirt opening with the neck continuing into it.
        polygon([(82, 145), (118, 145), (100, 145 + depth)], tee)
        smooth([(86, 143), (114, 143), (100, 145 + depth * 0.55)], skin)
        smooth([(88, 144), (112, 144), (100, 150)], black(0.10))
    if cl == "Jacket":
        open_neck(36)
        polygon([(72, 148), (84, 143), (99, 180), (95, 200), (78, 200), (82, 168)], black(0.20))
        polygon([(128, 148), (116, 143), (101, 180), (105, 200), (122, 200), (118, 168)], black(0.20))
        line([(84, 143), (99, 180)], white(0.14), 1.2); line([(116, 143), (101, 180)], white(0.14), 1.2)
    elif cl == "T-shirt":
        smooth([(81, 144), (119, 144), (116, 153), (100, 158), (84, 153)], black(0.22))
        polygon([(86, 140), (114, 140), (114, 150), (100, 154), (86, 150)], skin)
    elif cl == "Turtleneck":
        # Rolled collar sits under the chin rather than over the jaw.
        smooth([(80, 142), (120, 142), (122, 161), (100, 164), (78, 161)], hexc(0x2A2E38))
        for y in (149, 155): line([(82, y), (118, y)], black(0.28), 1.3)
    elif cl == "Suit":
        polygon([(80, 146), (120, 146), (100, 184)], hexc(0xEFF2F3))
        smooth([(89, 143), (111, 143), (100, 152)], skin)
        polygon([(84, 144), (93, 146), (100, 156), (90, 158)], hexc(0xDCE2E5)); polygon([(116, 144), (107, 146), (100, 156), (110, 158)], hexc(0xDCE2E5))
        smooth([(97, 156), (103, 156), (105, 176), (100, 184), (95, 176)], A())
        polygon([(72, 148), (82, 144), (99, 186), (95, 200), (78, 200), (80, 168)], black(0.30)); polygon([(128, 148), (118, 144), (101, 186), (105, 200), (122, 200), (120, 168)], black(0.30))
    elif cl == "Duster" or cl == "Trench":
        coat = hexc(0x4A4133 if cl == "Trench" else 0x7A5236)
        open_neck(33)
        polygon([(68, 147), (85, 142), (100, 178), (94, 200), (76, 200), (80, 166)], coat)
        polygon([(132, 147), (115, 142), (100, 178), (106, 200), (124, 200), (120, 166)], coat)
        line([(85, 143), (99, 176)], white(0.12), 1.2); line([(115, 143), (101, 176)], white(0.12), 1.2)
    elif cl == "Bomber":
        smooth([(80, 143), (120, 143), (118, 152), (100, 157), (82, 152)], A(0.55))
        for x in range(84, 117, 4): line([(x, 145), (x, 151)], black(0.18), 1)
        line([(100, 156), (100, 200)], hexc(0xC7D2DD, 0.8), 1.6)
    elif cl == "Tactical":
        open_neck(18)
        smooth([(70, 156), (130, 156), (132, 200), (68, 200)], hexc(0x3A4434))
        line([(80, 148), (78, 200)], black(0.35), 4); line([(120, 148), (122, 200)], black(0.35), 4)
        for x in (82.0, 103.0): rrect(x, 168, 15, 13, 3, fill=hexc(0x48543F))
    elif cl == "Lab Coat":
        polygon([(82, 145), (118, 145), (100, 176)], hexc(0x2A3640))
        smooth([(86, 143), (114, 143), (100, 162)], skin)
        polygon([(70, 148), (85, 143), (99, 178), (95, 200), (78, 200), (82, 166)], hexc(0xF4F7F8)); polygon([(130, 148), (115, 143), (101, 178), (105, 200), (122, 200), (118, 166)], hexc(0xF4F7F8))
        line([(85, 143), (99, 178)], black(0.14), 1.2); line([(115, 143), (101, 178)], black(0.14), 1.2)
        rect(72, 170, 2, 10, A(0.9))
    elif cl in ("Armor", "Hero Armor"):
        smooth([(78, 142), (122, 142), (128, 158), (100, 166), (72, 158)], hexc(0x4C6470))
        smooth([(82, 145), (118, 145), (122, 155), (100, 161), (78, 155)], hexc(0x3A505B))
        line([(76, 158), (100, 165), (124, 158)], A(0.55), 1.5)
        if cl == "Hero Armor": smooth([(100, 168), (108, 177), (100, 186), (92, 177)], A(0.85))
    elif cl == "Spacesuit":
        smooth([(78, 140), (122, 140), (126, 152), (100, 158), (74, 152)], hexc(0xB9C8CB))
        line([(80, 148), (100, 153), (120, 148)], black(0.18), 1.5)
    if hood:
        smooth([(80, 150), (120, 150), (123, 160), (100, 166), (77, 160)], hexc(0x1B252C))
        cord = hexc(0xC7D2DD, 0.85)
        line([(92, 160), (89, 176)], cord, 1.6); line([(108, 160), (111, 176)], cord, 1.6)
        rrect(87.5, 175, 3, 6, 1.5, fill=cord); rrect(109.5, 175, 3, 6, 1.5, fill=cord)
    j = c.get("jewelry")
    gold_c = hexc(0xE4B94C)
    if j in ("Chain", "Double chain", "Pendant"): line(smooth_open([(84, 146), (88, 160), (100, 166), (112, 160), (116, 146)]), gold_c, 2.4)
    if j == "Double chain": line(smooth_open([(81, 148), (86, 168), (100, 176), (114, 168), (119, 148)]), hexc(0xF4D899), 2)
    if j == "Pendant": line([(100, 166), (100, 169)], gold_c, 1.5); smooth([(100, 168), (105, 174), (100, 181), (95, 174)], A())
    if False:  # chest badge removed in 1.0.0 (22) / 198
        # A small sewn-on chest badge; removing it leaves nothing behind.
        rrect(118, 173, 28, 12, 3, fill=black(0.38), stroke=A(0.7), width=1)
        l = layer(); d = ImageDraw.Draw(l)
        try: f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", int(7.5 * S))
        except Exception: f = ImageFont.load_default()
        d.text((P(132), P(179.3)), "NOID", font=f, fill=A(), anchor="mm"); comp(l)
    # Quality: edge vignette and rim light
    l = layer(); d = ImageDraw.Draw(l)
    for i in range(24):
        t = i / 23; r = 100 - t * 14
        d.ellipse([P(100 - r), P(100 - r), P(100 + r), P(100 + r)], outline=(0, 0, 0, int(10 * (1 - t) ** 1.2 + 2)), width=int(P(1)))
    comp(l)
    ring(1.5, 1.5, 197, 197, A(0.35), 2)
    # circular clip
    mask = Image.new("L", (W, W), 0); ImageDraw.Draw(mask).ellipse([0, 0, W, W], fill=255)
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0)); out.paste(img, (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)

def sheet(names, path, cols=6, size=200, title=None):
    rows = (len(names) + cols - 1) // cols
    pad = 16; lab = 28
    W = cols * (size + pad) + pad; H = rows * (size + pad + lab) + pad + (40 if title else 0)
    img = Image.new("RGBA", (W, H), (6, 15, 12, 255)); d = ImageDraw.Draw(img)
    f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 15)
    y0 = 0
    if title:
        d.text((pad, 12), title, font=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 20), fill=(238, 246, 239)); y0 = 40
    for i, (name, conf) in enumerate(names):
        r, cidx = divmod(i, cols); x = pad + cidx * (size + pad); y = y0 + pad + r * (size + pad + lab)
        img.alpha_composite(render(conf, size), (x, y))
        d.text((x + size / 2, y + size + 14), name, font=f, fill=(159, 199, 175), anchor="mm")
    img.convert("RGB").save(path)

if __name__ == "__main__":
    out = sys.argv[1]
    names = [(n, preset(n)) for n in PRESETS]
    sheet(names, out + "/presets.png", title="Character looks (9 existing + 8 new)")
    opts = []
    for h in ["Buzz", "Bob", "Ponytail", "Undercut", "Afro", "Bun"]:
        c = dict(DEFAULT); c.update(hair=h, hairColor="Copper" if h in ("Bob", "Ponytail") else "Black", presentation="Feminine" if h in ("Bob", "Ponytail", "Bun") else "Masculine"); opts.append(("Hair: " + h, c))
    for e in ["Wink", "Sly", "Glow"]:
        c = dict(DEFAULT); c.update(eyes=e); opts.append(("Eyes: " + e, c))
    for a in ["Monocle", "Eyepatch", "Crown", "Halo", "Bandana", "Respirator", "Cyber Eye", "Earpiece"]:
        c = dict(DEFAULT); c.update(accessory=a); opts.append((a, c))
    for cl in ["Trench", "Turtleneck", "Bomber", "Tactical", "Lab Coat"]:
        c = dict(DEFAULT); c.update(clothing=cl); opts.append((cl, c))
    for b in ["Matrix", "Vault", "Aurora", "Skyline", "Blockchain", "Void"]:
        c = dict(DEFAULT); c.update(background=b); opts.append(("BG: " + b, c))
    c = dict(DEFAULT); c.update(facialHair="Goatee"); opts.append(("Goatee", c))
    sheet(opts, out + "/options.png", cols=6, size=170, title="New options")

def all_options(out):
    """Every option in the editor, one change at a time from the default look."""
    groups = {
        "hair": ["Crop","Buzz","Undercut","Curls","Afro","Long","Bob","Ponytail","Bun","Braids","Mohawk","Spikes","Bald"],
        "face": ["Oval","Round","Angular","Alien","Cat","Robot"],
        "eyes": ["Calm","Friendly","Focused","Wide","Wink","Sly","Glow"],
        "facialHair": ["None","Stubble","Mustache","Goatee","Beard"],
        "clothing": ["Jacket","Hoodie","T-shirt","Bomber","Turtleneck","Trench","Tactical","Lab Coat","Armor","Hero Armor","Suit","Spacesuit","Full Anonymous","Duster"],
        "accessory": ["Glasses","Sunglasses","Shades","Visor","Cyber Eye","Monocle","Eyepatch","Mask","Bandana","Respirator","Piercing","Earpiece","Beanie","Cap","Headphones","Helmet","Cowboy Hat","Crown","Halo"],
        "jewelry": ["Chain","Double chain","Pendant"],
    }
    for key, values in groups.items():
        items = []
        for v in values:
            for pres in (["Masculine", "Feminine"] if key == "hair" else ["Masculine"]):
                c = dict(DEFAULT); c[key] = v; c["presentation"] = pres
                if key == "hair": c["hairColor"] = "Brown"
                items.append((f"{v}" + (" F" if pres == "Feminine" else ""), c))
        sheet(items, f"{out}/all-{key}.png", cols=6, size=170, title=key)
    for face in ["Round","Angular"]:
        items = []
        for v in groups["hair"]:
            c = dict(DEFAULT); c.update(hair=v, face=face, hairColor="Brown"); items.append((v, c))
        sheet(items, f"{out}/all-hair-{face}.png", cols=7, size=150, title=f"hair on {face}")

if __name__ == "__main__" and len(sys.argv) > 2 and sys.argv[2] == "all":
    all_options(sys.argv[1])
