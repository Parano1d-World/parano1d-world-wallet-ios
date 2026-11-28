# Usage: python3 Scripts/hair_art/one.py <Style> '#hex'   (writes /tmp/one.png at 700 px)
import sys,subprocess; import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from base import face
import importlib, styles; importlib.reload(styles)
from sheet import layers
name, color = sys.argv[1], sys.argv[2]
v=styles.S[name]
open("/tmp/one.svg","w").write(face(layers(v["back"]),layers(v["front"]),hair=color))
subprocess.run(["rsvg-convert","-w","700","-h","700","/tmp/one.svg","-o","/tmp/one.png"],check=True)
