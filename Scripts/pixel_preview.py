#!/usr/bin/env python3
# Usage: python3 Scripts/pixel_preview.py <output.png>   (needs Pillow)
# Mirror of App/PixelCharacterAvatar.swift (48x48 grid) for design review.
import sys
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from avatar_preview import TINT, MINT, SKIN, HAIRC, DEFAULT, PRESETS, preset, hexc

BACKS = {"Paper": 0xD6E5DC, "Ocean": 0x16394B, "Plum": 0x30213F, "Grid": 0x102C2A, "Exchange": 0x18232B, "Circuit": 0x102D37,
         "Sunset": 0x674337, "Starlight": 0x253956, "Rose": 0x4D2E4A, "Matrix": 0x04140C, "Vault": 0x1A2026, "Aurora": 0x0D1F2A,
         "Skyline": 0x121A33, "Blockchain": 0x0C1A1F, "Void": 0x030507}
OUT = {"Spacesuit": 0xDCE4E6, "Duster": 0x69452E, "Trench": 0x3B3428, "Turtleneck": 0x1C1F26, "Bomber": 0x2F3B2A,
       "Tactical": 0x2C3328, "Lab Coat": 0xE8EEF0}

def render(c, size=192):
    img = Image.new("RGBA", (48, 48), (0, 0, 0, 255))
    def box(x, y, w, h, col):
        l = Image.new("RGBA", (48, 48), (0, 0, 0, 0)); ImageDraw.Draw(l).rectangle([x, y, x + w - 1, y + h - 1], fill=col)
        nonlocal img; img = Image.alpha_composite(img, l)
    A = lambda a=1.0: hexc(TINT.get(c["accent"], MINT), a)
    pal = c.get("pixelTheme") or "Neon"
    skin = hexc(SKIN.get(c["skin"], 0xDCA577)); hair = lambda a=1.0: hexc(HAIRC.get(c["hairColor"], 0x171922), a)
    _hh = HAIRC.get(c["hairColor"], 0x171922)
    brows = tuple(int(((_hh >> sh) & 255) + ((((0x18212B >> sh) & 255) - ((_hh >> sh) & 255)) * 0.5)) for sh in (16, 8, 0)) + (255,)
    ink = lambda a=1.0: hexc(0x111A22, a); W = lambda a=1.0: (255, 255, 255, int(255 * a)); B = lambda a=1.0: (0, 0, 0, int(255 * a))
    back = hexc(BACKS.get(c["background"], 0x09141D)); bg = c["background"]
    special = c["face"] in ("Alien", "Cat", "Robot")
    box(0, 0, 48, 48, back)
    if pal != "Shadow":
        for y in range(4, 48, 8): box(0, y, 48, 1, A(0.14))
    if pal == "Circuit" or bg == "Grid":
        for x in range(4, 48, 8): box(x, 0, 1, 48, A(0.12))
    if pal == "Arcade":
        for x in range(2, 48, 8): box(x, 5, 3, 2, A(0.24)); box(x + 3, 42, 2, 2, A(0.24))
    if pal == "Shadow": box(0, 0, 5, 48, ink(0.35)); box(43, 0, 5, 48, ink(0.35))
    if bg == "Exchange":
        for x in range(2, 48, 7): box(x, 36 - x // 3, 5, 1, A(0.35))
    if bg == "Starlight":
        for x in range(3, 48, 9): box(x, (x * 17) % 34, 1, 1, W(0.8))
    if bg == "Matrix":
        for x in range(2, 48, 5):
            for k in range(0, 4): box(x, (x * 7 + k * 12) % 44, 1, 3, A(0.25))
    if bg == "Vault":
        for x, y in ((4, 4), (40, 4), (4, 40), (40, 40)): box(x, y, 4, 4, A(0.22))
        box(2, 22, 3, 4, A(0.22)); box(43, 22, 3, 4, A(0.22))
    if bg == "Aurora":
        for x in range(0, 48, 2): box(x, 8 + (x % 8) // 2, 2, 3, A(0.22)); box(x, 14 + ((x + 4) % 8) // 2, 2, 2, hexc(0x8E5CD9, 0.25))
    if bg == "Skyline":
        for x, h in ((0, 14), (6, 20), (40, 18), (44, 12)):
            box(x, 48 - h, 5, h, hexc(0x0A1022)); box(x + 2, 48 - h + 3, 1, 1, A(0.5))
    if bg == "Blockchain":
        for x in (2, 14, 28, 40): box(x, 3, 6, 4, A(0.30)); box(x + 1, 4, 4, 2, back)
        for x in (8, 20, 34): box(x, 5, 6, 1, A(0.25))
    box(8, 8, 32, 29, A(0.10)); box(5, 13, 3, 19, A(0.07)); box(40, 13, 3, 19, A(0.07))
    sh = 7 if c["presentation"] == "Masculine" else 11
    cl = c["clothing"]
    box(sh, 38, 48 - sh * 2, 10, ink()); box(sh + 3, 35, 42 - sh * 2, 13, hexc(OUT.get(cl, 0x253744)))
    if cl == "Spacesuit": box(9, 9, 30, 27, A()); box(11, 10, 26, 25, hexc(0xB9C8CB)); box(13, 12, 22, 22, ink())
    if not special: box(21, 31, 7, 8, skin); box(21, 32, 7, 3, B(0.15))
    if cl in ("Hoodie", "Full Anonymous") or c["style"] in ("Anonymous", "Hooded"):
        box(11, 9, 26, 27, ink()); box(13, 7, 22, 30, hexc(0x253744)); box(15, 10, 18, 24, ink())
    h = c["hair"]
    if not special:
        if h in ("Long", "Braids"): box(13, 12, 22, 25, hair())
        if h == "Bob": box(13, 11, 22, 19, hair())
        if h == "Afro": box(15, 3, 18, 2, hair()); box(12, 5, 24, 2, hair()); box(11, 7, 26, 12, hair()); box(12, 19, 24, 2, hair())
        if h == "Ponytail": box(33, 12, 4, 6, hair()); box(35, 17, 3, 12, hair())
    left = 14 if c["face"] == "Round" else 15; width = 48 - left * 2
    face = c["face"]
    if face == "Alien":
        box(12, 12, 24, 14, skin); box(14, 9, 20, 4, skin); box(17, 7, 14, 3, skin)
        box(15, 26, 18, 4, skin); box(18, 30, 12, 3, skin); box(22, 33, 4, 2, skin)
    elif face == "Cat":
        box(13, 16, 22, 15, skin); box(16, 30, 16, 4, skin)
        box(13, 8, 6, 10, skin); box(29, 8, 6, 10, skin); box(15, 11, 2, 5, A()); box(31, 11, 2, 5, A())
    elif face == "Robot":
        metal = hexc(0x9AA8B2); seam = hexc(0x6E7C86)
        box(21, 31, 7, 7, hexc(0x5E6B74)); box(21, 33, 7, 1, B(0.25)); box(21, 35, 7, 1, B(0.25))
        box(14, 10, 20, 22, metal); box(14, 10, 20, 1, seam); box(14, 31, 20, 1, seam); box(14, 10, 1, 22, seam); box(33, 10, 1, 22, seam)
        box(12, 18, 2, 7, seam); box(34, 18, 2, 7, seam); box(24, 6, 1, 4, seam); box(23, 4, 3, 2, A())
        box(16, 18, 16, 6, ink()); box(18, 27, 12, 2, ink()); box(20, 27, 1, 2, metal); box(23, 27, 1, 2, metal); box(26, 27, 1, 2, metal)
        box(16, 12, 3, 1, W(0.5))
    else:
        box(left, 14, width, 15, skin); box(left + 2, 29, width - 4, 4, skin); box(left + 4, 33, width - 8, 1, skin)
        box(left - 2, 20, 2, 6, skin); box(48 - left, 20, 2, 6, skin)
        box(left, 16, 2, 12, W(0.12)); box(46 - left, 17, 2, 12, B(0.14))
    if face == "Angular": box(left, 28, 2, 3, ink()); box(46 - left, 28, 2, 3, ink())
    if h != "Bald" and not special:
        if h == "Buzz":
            box(15, 11, 18, 4, hair(0.9)); box(16, 10, 16, 1, hair(0.9))
        elif h == "Undercut":
            box(15, 12, 18, 3, hair(0.45)); box(17, 8, 14, 5, hair()); box(26, 7, 7, 3, hair()); box(29, 12, 4, 4, hair())
        elif h == "Afro":
            box(13, 9, 22, 6, hair())
        elif h == "Mohawk":
            box(15, 13, 18, 2, hair(0.35)); box(14, 14, 2, 4, hair(0.35)); box(32, 14, 2, 4, hair(0.35))
        else:
            box(14, 10, 20, 5, hair()); box(16, 8, 16, 3, hair()); box(14, 14, 4, 4, hair()); box(30, 13, 4, 5, hair())
        if h == "Crop": box(18, 14, 9, 2, hair()); box(18, 10, 10, 1, W(0.15))
        if h == "Curls":
            for x in range(12, 35, 4): box(x, 9 + (x % 3), 4, 5, hair()); box(x, 9 + (x % 3), 2, 1, W(0.12))
        if h == "Mohawk": box(21, 5, 7, 10, hair()); box(22, 3, 5, 2, hair()); box(22, 5, 2, 3, W(0.15))
        if h == "Spikes":
            for x in range(12, 37, 5): box(x, 7 - (x % 3), 3, 7, hair())
        if h == "Braids":
            for y in range(15, 36, 4): box(12, y, 3, 3, hair()); box(33, y, 3, 3, hair())
        if h == "Long": box(13, 14, 3, 21, hair()); box(32, 14, 3, 21, hair())
        if h == "Bob": box(13, 14, 3, 15, hair()); box(32, 14, 3, 15, hair())
        if h == "Bun": box(21, 4, 7, 5, hair()); box(22, 5, 2, 1, W(0.15))
    e = c["eyes"]
    if face == "Cat":
        box(18, 21, 4, 3, ink()); box(27, 21, 4, 3, ink()); box(23, 27, 3, 2, ink())
        box(17, 28, 6, 1, ink(0.6)); box(26, 28, 6, 1, ink(0.6)); box(12, 26, 6, 1, ink(0.4)); box(30, 26, 6, 1, ink(0.4))
    elif face == "Alien":
        box(14, 19, 9, 4, ink()); box(16, 23, 5, 2, ink()); box(25, 19, 9, 4, ink()); box(27, 23, 5, 2, ink()); box(22, 30, 4, 1, ink(0.7))
    elif face == "Robot":
        box(18, 19, 4, 4, A()); box(26, 19, 4, 4, A()); box(18, 19, 1, 1, W(0.85)); box(26, 19, 1, 1, W(0.85))
    else:
        box(17, 19, 5, 1, brows); box(27, 19, 5, 1, brows)
        if e == "Glow":
            box(17, 20, 5, 4, A(0.35)); box(27, 20, 5, 4, A(0.35)); box(18, 21, 3, 2, A()); box(28, 21, 3, 2, A())
        elif e == "Sly":
            box(18, 22, 3, 1, ink()); box(28, 22, 3, 1, ink())
        elif e == "Wink":
            box(18, 21, 3, 2, ink()); box(18, 21, 1, 1, W()); box(28, 22, 3, 1, ink())
        else:
            box(18, 21, 3, 2, ink()); box(28, 21, 3, 2, ink()); box(18, 21, 1, 1, W()); box(28, 21, 1, 1, W())
        if e == "Wide": box(18, 20, 3, 1, ink()); box(28, 20, 3, 1, ink())
        if e == "Focused": box(20, 20, 2, 1, hair()); box(26, 20, 2, 1, hair())
        if c["presentation"] == "Feminine": box(17, 20, 1, 1, ink()); box(31, 20, 1, 1, ink())
        box(24, 23, 1, 4, B(0.18)); box(23, 26, 3, 1, B(0.22))
        fh = c["facialHair"]
        if fh == "Beard":
            box(left, 23, 2, 7, hair()); box(46 - left, 23, 2, 7, hair())
            box(left + 1, 28, width - 2, 4, hair()); box(left + 2, 32, width - 4, 1, hair()); box(left + 4, 33, width - 8, 2, hair())
            box(left + 2, 33, width - 4, 1, B(0.18)); box(20, 27, 9, 1, hair())
        if fh == "Stubble":
            for y in range(27, 34):
                for x in range(left + 1 + (y % 2), 47 - left, 2): box(x, y, 1, 1, hair(0.2))
        if fh in ("Mustache", "Goatee"): box(20, 27, 9, 1, hair()); box(21, 26, 7, 1, hair(0.6))
        if fh == "Goatee": box(22, 31, 5, 2, hair()); box(23, 33, 3, 1, hair())
        if fh == "Beard": box(21, 29, 7, 1, hexc(0x8C4F45))
        box(21, 29, 7, 1, ink(0.7) if fh != "Beard" else ink(0.55))
        if e in ("Friendly", "Wink"): box(22, 30, 5, 1, ink(0.7))
    acc = c["accessory"]
    if c["style"] == "Anonymous" or acc == "Mask":
        box(15, 17, 19, 14, hexc(0xE7EBE5)); box(17, 31, 15, 3, hexc(0xC4D1CA)); box(19, 34, 11, 2, hexc(0xDCE5DE)); box(22, 36, 5, 1, hexc(0xDCE5DE))
        box(17, 20, 6, 1, ink()); box(26, 20, 6, 1, ink()); box(18, 22, 5, 2, ink()); box(26, 22, 5, 2, ink())
        box(23, 24, 3, 4, hexc(0xA9B9B4)); box(17, 27, 3, 1, hexc(0xB97982)); box(29, 27, 3, 1, hexc(0xB97982))
        box(20, 29, 9, 1, ink()); box(18, 28, 2, 1, ink()); box(29, 28, 2, 1, ink()); box(22, 32, 5, 1, ink()); box(23, 34, 3, 2, ink()); box(24, 36, 1, 2, ink())
    if acc in ("Glasses", "Shades", "Sunglasses", "Visor"):
        box(15, 20, 19, 1, A()); box(16, 21, 7, 4, ink()); box(26, 21, 7, 4, ink()); box(23, 22, 3, 1, A())
        if acc == "Glasses": box(17, 21, 5, 3, skin[:3] + (166,)); box(27, 21, 5, 3, skin[:3] + (166,))
        if acc == "Visor": box(16, 20, 17, 5, A()); box(17, 21, 13, 1, W(0.7))
    gold = hexc(0xE4B94C)
    if acc == "Monocle": box(26, 19, 6, 1, gold); box(26, 24, 6, 1, gold); box(26, 19, 1, 6, gold); box(31, 19, 1, 6, gold); box(31, 25, 1, 8, gold)
    if acc == "Eyepatch": box(15, 16, 18, 1, ink()); box(26, 19, 6, 5, ink())
    if acc == "Cyber Eye": box(25, 19, 8, 6, hexc(0x2A3640)); box(27, 20, 4, 4, A()); box(29, 21, 1, 1, W(0.9)); box(33, 22, 3, 1, A(0.8))
    if acc == "Bandana": box(15, 26, 19, 6, A(0.9)); box(17, 32, 15, 2, A(0.9)); box(19, 28, 1, 1, W(0.4)); box(24, 29, 1, 1, W(0.4)); box(29, 28, 1, 1, W(0.4))
    if acc == "Respirator": box(18, 27, 13, 7, hexc(0x2C3338)); box(15, 28, 4, 4, hexc(0x4A555D)); box(30, 28, 4, 4, hexc(0x4A555D)); box(16, 29, 2, 2, A(0.7)); box(31, 29, 2, 2, A(0.7))
    if acc == "Earpiece": box(34, 22, 2, 3, ink()); box(34, 23, 1, 1, A())
    if acc == "Beanie": box(14, 9, 20, 7, A()); box(16, 7, 16, 3, A()); box(14, 15, 20, 2, ink())
    if acc == "Cap": box(14, 10, 20, 6, ink()); box(16, 8, 16, 3, ink()); box(13, 15, 25, 2, A())
    if acc == "Cowboy Hat": box(15, 7, 18, 8, hexc(0x69452E)); box(9, 15, 30, 3, hexc(0x69452E)); box(15, 13, 18, 2, A())
    if acc == "Helmet": box(9, 10, 4, 24, W()); box(35, 10, 4, 24, W()); box(13, 7, 22, 4, W()); box(13, 34, 22, 3, W()); box(14, 11, 4, 2, A(0.7))
    if acc == "Piercing": box(34, 24, 1, 3, A())
    if acc == "Headphones": box(10, 19, 4, 11, A()); box(34, 19, 4, 11, A()); box(13, 12, 3, 3, A()); box(32, 12, 3, 3, A()); box(16, 10, 16, 2, A())
    if acc == "Crown":
        box(16, 5, 16, 4, gold); box(16, 2, 2, 3, gold); box(23, 1, 2, 4, gold); box(30, 2, 2, 3, gold); box(19, 6, 2, 2, A()); box(27, 6, 2, 2, A()); box(23, 6, 2, 2, hexc(0xF06C73))
    if acc == "Halo": box(17, 2, 14, 1, hexc(0xF4D899)); box(16, 3, 1, 1, hexc(0xF4D899)); box(31, 3, 1, 1, hexc(0xF4D899)); box(17, 4, 14, 1, hexc(0xF4D899))
    if cl in ("Armor", "Hero Armor"): box(8, 38, 32, 4, A(0.55)); box(14, 42, 20, 2, A())
    if cl == "Hero Armor": box(21, 39, 6, 5, A()); box(23, 40, 2, 3, ink())
    if cl == "Suit": box(12, 38, 24, 10, hexc(0x171E2C)); box(19, 38, 10, 8, W()); box(23, 40, 2, 7, A())
    if cl == "Trench": box(sh + 3, 37, 6, 11, hexc(0x4A4133)); box(39 - sh, 37, 6, 11, hexc(0x4A4133)); box(sh + 3, 44, 42 - sh * 2, 1, hexc(0x2A251C))
    if cl == "Turtleneck": box(20, 33, 9, 5, hexc(0x2A2E38)); box(20, 35, 9, 1, B(0.35))
    if cl == "Bomber": box(18, 36, 13, 2, A(0.8)); box(24, 38, 1, 10, hexc(0xC7D2DD)); box(sh + 5, 41, 3, 2, A(0.6))
    if cl == "Tactical": box(15, 38, 19, 10, hexc(0x3A4434)); box(16, 41, 4, 3, hexc(0x48543F)); box(22, 41, 4, 3, hexc(0x48543F)); box(28, 41, 4, 3, hexc(0x48543F)); box(15, 38, 19, 1, A(0.8))
    if cl == "Lab Coat": box(19, 37, 11, 11, hexc(0x2A3640)); box(19, 37, 1, 11, hexc(0xB8C4C8)); box(29, 37, 1, 11, hexc(0xB8C4C8)); box(31, 41, 3, 1, A())
    if cl == "T-shirt": box(sh + 3, 39, 42 - sh * 2, 9, A(0.75))
    elif cl in ("Jacket", "Duster", "Hoodie", "Full Anonymous"):
        tee = hexc(0x161D24)
        box(21, 37, 7, 2, tee); box(22, 39, 5, 2, tee); box(23, 41, 3, 2, tee)
        box(22, 37, 5, 1, skin); box(23, 38, 3, 1, skin)
        if cl in ("Hoodie", "Full Anonymous"):
            box(21, 39, 1, 5, hexc(0xC7D2DD, 0.85)); box(27, 39, 1, 5, hexc(0xC7D2DD, 0.85))
        else:
            box(18, 37, 3, 9, B(0.22)); box(28, 37, 3, 9, B(0.22))
        box(sh + 4, 43, 5, 1, W(0.12))
    j = c.get("jewelry")
    if j in ("Chain", "Double chain", "Pendant"):
        for x, y in ((17, 37), (20, 38), (23, 39), (26, 38), (29, 37)): box(x, y, 3, 1, gold)
    if j == "Double chain": box(20, 40, 9, 1, hexc(0xF4D899))
    if j == "Pendant": box(23, 40, 3, 3, A())
    if False:  # chest badge removed in 1.0.0 (22) / 198 box(32, 41, 4, 5, A()); box(33, 42, 1, 3, ink()); box(32, 43, 1, 1, ink())
    return img.resize((size, size), Image.NEAREST)

if __name__ == "__main__":
    names = list(PRESETS)
    cols = 9; size = 120; pad = 12; lab = 22
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * (size + pad) + pad, rows * (size + pad + lab) + pad + 36), (6, 15, 12, 255))
    d = ImageDraw.Draw(sheet); f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
    d.text((pad, 10), "Pixel rendering of every look", font=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 18), fill=(238, 246, 239))
    for i, n in enumerate(names):
        r, k = divmod(i, cols); x = pad + k * (size + pad); y = 36 + pad + r * (size + pad + lab)
        c = preset(n); c["pixelTheme"] = "Neon"
        sheet.alpha_composite(render(c, size), (x, y)); d.text((x + size / 2, y + size + 10), n, font=f, fill=(159, 199, 175), anchor="mm")
    sheet.convert("RGB").save(sys.argv[1])
