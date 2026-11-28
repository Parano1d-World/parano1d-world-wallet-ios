#!/usr/bin/env python3
"""Static guard for the public edition. Lists every reference to an excluded
screen that is still compiled into PUBLIC_EDITION code paths and fails if one
appears outside the reviewed baseline (definitions of the excluded features
themselves, which are unreachable in the public build)."""
import os,re,sys
root=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','App')
NAMES=["TradeHubView","MarketsView(","OTCOfferView","NFTMarketplaceView","SiteScreen(","ExternalWalletKeyView","GatewaySettingsView","WebsiteSessionsView","AnonymousInvadersView","PrivateOfferSettingsView","NFTPrivateOffer","MarketDetail(","OwnedNFTActionsView","NFTContactOffer","WebsiteTabScreen","VPNSettingsView","NFTCollectionListingsView","TabLayoutSettings","DAppBrowser("]
# file -> symbols allowed there (inside the excluded features' own definitions)
# The excluded features were removed from this tree on 23 Nov 2026; any reference now fails the check.
BASELINE={}
def public_text(src):
    out=[];stack=[]  # each: active?
    for line in src.split('\n'):
        t=line.strip()
        if t.startswith('#if'):
            cond=t[3:].strip()
            if cond=='PUBLIC_EDITION': stack.append(['pub',True])
            elif cond=='!PUBLIC_EDITION': stack.append(['pub',False])
            else: stack.append(['other',True])
            out.append('');continue
        if t.startswith('#else') and stack:
            if stack[-1][0]=='pub': stack[-1][1]=not stack[-1][1]
            out.append('');continue
        if t.startswith('#endif') and stack:
            stack.pop();out.append('');continue
        out.append(line if all(a for _,a in stack) else '')
    return out

failures=[]
for f in sorted(os.listdir(root)):
    if not f.endswith('.swift'): continue
    lines=public_text(open(os.path.join(root,f)).read())
    for i,l in enumerate(lines,1):
        if re.match(r'\s*(struct|///|//)',l): continue
        for n in NAMES:
            if n in l and n not in BASELINE.get(f,set()):
                failures.append(f"{f}:{i}: {n}")
# Nothing in the published tree may name the internal edition's identifiers or a person's home folder.
top=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..')
PRIVATE=[re.compile(p,re.I) for p in (r'com\.'+'grant'+r'jones', 'grant'+r'[ ._-]?jones', r'/Users/[a-z]')]
for folder,dirs,files in os.walk(top):
    dirs[:]=[d for d in dirs if d not in ('.git','target','Vendor','TestResults','__pycache__') and not d.startswith('DerivedData') and not d.endswith('.xcodeproj')]
    for f in files:
        if not f.endswith(('.swift','.yml','.plist','.entitlements','.md','.json','.sh','.py','.rs','.toml','.js','.xcprivacy','.strings')): continue
        path=os.path.join(folder,f)
        try: text=open(path,encoding='utf-8').read()
        except (UnicodeDecodeError,OSError): continue
        for i,l in enumerate(text.split('\n'),1):
            if any(p.search(l) for p in PRIVATE): failures.append(f"{os.path.relpath(path,top)}:{i}: private identifier")
if failures:
    print("Public edition check failed:"); print("\n".join(failures)); sys.exit(1)
print("Public edition compliance check passed: no new references to excluded features.")
