#!/usr/bin/env python3
# Usage: python3 Scripts/avatar_review_sheets.py <output-dir>   (facial hair, necklines with badge on/off, all looks)
import sys
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from avatar_preview import DEFAULT, sheet, preset, PRESETS
out = sys.argv[1]
items = []
for fh in ["None", "Stubble", "Mustache", "Goatee", "Beard"]:
    for skin, hc in (("Warm", "Black"), ("Deep", "Brown"), ("Fair", "Auburn")):
        c = dict(DEFAULT); c.update(facialHair=fh, skin=skin, hairColor=hc, branding=False); items.append((f"{fh} · {skin}", c))
sheet(items, out + "/facial.png", cols=6, size=170, title="Facial hair")
items = []
for cl in ["Jacket", "Hoodie", "T-shirt", "Turtleneck", "Suit", "Duster", "Trench", "Bomber", "Tactical", "Lab Coat", "Armor", "Hero Armor", "Spacesuit", "Full Anonymous"]:
    for b in (True, False):
        c = dict(DEFAULT); c.update(clothing=cl, branding=b)
        if cl == "Full Anonymous": c.update(style="Anonymous", accessory="Mask")
        items.append((f"{cl} · {'badge' if b else 'no badge'}", c))
sheet(items, out + "/outfits.png", cols=7, size=150, title="Necklines, branding on and off")
c = dict(DEFAULT); c.update(jewelry="Chain")
sheet([(n, preset(n)) for n in PRESETS], out + "/presets.png", title="All looks")
