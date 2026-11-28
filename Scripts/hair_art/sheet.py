# Usage: python3 Scripts/hair_art/sheet.py '#171922' [Style ...]   (needs rsvg-convert and ImageMagick montage; writes /tmp/hd_sheet.png)
import os, sys; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from base import face, render
from styles import S
def layers(ls):
    out=""
    for d,role in ls:
        if role in ("hair","fill"): out+=f'<path d="{d}"/>'
        elif role=="shade": out+=f'<path d="{d}" fill="#000" fill-opacity=".22"/>'
        elif role=="stubble": out+=f'<path d="{d}" fill-opacity=".4"/>'
        elif role=="shadeline": out+=f'<path d="{d}" fill="none" stroke="#000" stroke-opacity=".22" stroke-width="1.6" stroke-linecap="round"/>'
        elif role=="light": out+=f'<path d="{d}" fill="#fff" fill-opacity=".16"/>'
        elif role=="lightline": out+=f'<path d="{d}" fill="none" stroke="#fff" stroke-opacity=".16" stroke-width="1.6" stroke-linecap="round"/>'
    return out
if __name__=="__main__":
  names=sys.argv[2:] or list(S)
  color=sys.argv[1]
  render([(n,face(layers(S[n]["back"]),layers(S[n]["front"]),hair=color)) for n in names],"/tmp/hd_sheet.png",cols=4)
