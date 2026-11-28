# Hand-drawn hair art (SVG path data in the avatar's 200x200 space, Oval face).
# The same strings ship in the app; this file renders review sheets.
import subprocess, sys
SKIN="#DCA577"; HAIR="#171922"; INK="#18212B"
def face(back="", front="", hair=HAIR, label=""):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="400" height="400">
<defs><clipPath id="c"><circle cx="100" cy="100" r="100"/></clipPath></defs>
<g clip-path="url(#c)">
<rect width="200" height="200" fill="#0A151B"/><circle cx="100" cy="100" r="86" fill="#0E2F28"/>
<g fill="{hair}">{back}</g>
<ellipse cx="100" cy="197" rx="77" ry="56" fill="#26333F"/>
<path d="M88 120 L112 120 L115 154 L85 154 Z" fill="{SKIN}"/>
<ellipse cx="63.5" cy="96.5" rx="8" ry="12.5" fill="{SKIN}"/><ellipse cx="136.5" cy="96.5" rx="8" ry="12.5" fill="{SKIN}"/>
<ellipse cx="100" cy="96" rx="37.5" ry="51" fill="{SKIN}"/>
<g fill="{hair}">{front}</g>
<path d="M77 79 L92 77.5" stroke="{INK}" stroke-width="3" stroke-linecap="round"/><path d="M108 77.5 L123 79" stroke="{INK}" stroke-width="3" stroke-linecap="round"/>
<circle cx="85" cy="88" r="3.6" fill="{INK}"/><circle cx="115" cy="88" r="3.6" fill="{INK}"/>
<path d="M100 94 L96 108 L102 109" stroke="{INK}" stroke-opacity=".35" stroke-width="2" fill="none"/>
<path d="M88 121 L100 123 L112 121" stroke="{INK}" stroke-opacity=".7" stroke-width="2" fill="none"/>
</g><circle cx="100" cy="100" r="99" fill="none" stroke="#2C8A5E" stroke-opacity=".4" stroke-width="2"/></svg>'''
def render(styles, out, cols=4):
    import os
    files=[]
    for i,(name,svg) in enumerate(styles):
        p=f"/tmp/hd_{i}.svg"; open(p,"w").write(svg); png=p.replace(".svg",".png")
        subprocess.run(["rsvg-convert","-w","300","-h","300",p,"-o",png],check=True); files.append((name,png))
    args=["montage"]+[f for _,f in files]+["-tile",f"{cols}x","-geometry","+8+8","-background","#06100D",out]
    lab=[]
    for name,f in files: lab+=["-label",name,f]
    subprocess.run(["montage","-font","DejaVu-Sans","-pointsize","18","-fill","#9FC7AF"]+lab+["-tile",f"{cols}x","-geometry","+8+8","-background","#06100D",out],check=True)
