# Usage: python3 Scripts/hair_art/gen.py   (rewrites the styles table in App/HairArt.swift from styles.py)
import os, sys; here=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,here)
import styles
S=styles.S
role={"hair":".hair","shade":".shade","light":".light","lightline":".lightLine","stubble":".stubble","shadeline":".shadeLine","fill":".fill"}
body=[]
for name,v in S.items():
    def L(ls): return "["+",\n            ".join(f'("{d}",{role[r]})' for d,r in ls)+"]"
    body.append(f'        "{name}": (back: {L(v["back"])},\n          front: {L(v["front"])}),')
p=os.path.join(here,"..","..","App","HairArt.swift"); s=open(p).read()
a=s.index("    static let styles")+len("    static let styles: [String: (back: [Layer], front: [Layer])] = [\n")
b=s.index("    ]\n",a)
s=s[:a]+"\n".join(body)+"\n"+s[b:]
open(p,"w").write(s)
