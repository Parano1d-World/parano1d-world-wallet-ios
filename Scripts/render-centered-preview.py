from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
R=Path(__file__).resolve().parents[2]
W,H=1530,940
im=Image.new('RGB',(W,H),'#081610'); d=ImageDraw.Draw(im)
serif='/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf'; sans='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
logo=Image.open(R/'Paranoid-iOS/App/Assets.xcassets/Brand.imageset/Brand.png').convert('RGBA')
BG='#020706'; PANEL='#0b1716'; TEXT='#f4f7f5'; SUB='#a1b6ac'; GREEN='#30e374'; LINE='#234336'
def font(s,ser=False):return ImageFont.truetype(serif if ser else sans,s)
def t(x,y,v,s=14,c=TEXT,ser=False):d.text((x,y),v,font=font(s,ser),fill=c)
def c(x,w,y,v,s=14,col=TEXT,ser=False):
 bb=d.textbbox((0,0),v,font=font(s,ser)); t(x+(w-bb[2])/2,y,v,s,col,ser)
def r(x,y,w,h,fill=PANEL,outline=LINE,rad=17):d.rounded_rectangle((x,y,x+w,y+h),rad,fill=fill,outline=outline,width=1)
def mark(x,y,z):
 a=logo.resize((z,z),Image.Resampling.LANCZOS);im.paste(a,(int(x),int(y)),a)
def button(x,y,w,label):r(x,y,w,46,GREEN,GREEN,23);c(x,w,y+13,label,13,'#03100a')
xs=[35,410,785,1160]; pw=335; top=90; ph=813
for i,x in enumerate(xs):
 r(x,top,pw,ph,BG,'#718075',45);r(x+7,top+7,pw-14,ph-14,BG,'#1e382b',38)
 r(x+115,top+15,105,25,'#000000','#000000',15)
 t(x+25,top+20,'9:41',12);t(x+269,top+20,'••• ▰',10)
 mark(x+24,top+67,27);t(x+60,top+67,'Parano1d',18,TEXT,True);t(x+61,top+91,'W A L L E T',7,SUB)
 if i:
  d.line((x+20,top+745,x+315,top+745),fill=LINE)
  for j,(sym,lab) in enumerate([('⌂','Home'),('⇄','Trade'),('▱','Collect'),('▢','Chat')]):
   xx=x+23+j*76; color=GREEN if j==i else SUB
   c(xx,61,top+752,sym,19,color);c(xx,61,top+781,lab,10,color)
# Welcome
x=xs[0];r(x+82,top+168,171,171,'#0b2418','#18512e',85);r(x+108,top+194,119,119,'#102e1e','#1d6839',60);mark(x+137,top+220,61)
c(x,pw,top+380,'Your world.',35,TEXT,True);c(x,pw,top+426,'Your wallet.',35,TEXT,True)
for yy,s in [(493,'Create your Parano1d wallet or'),(516,'bring back an existing one.'),(539,'Your recovery secret stays on this device.')]:c(x+23,pw-46,top+yy,s,12,SUB)
button(x+27,top+622,pw-54,'Create a new wallet');r(x+27,top+681,pw-54,46,PANEL,LINE,23);c(x+27,pw-54,top+695,'Import an existing wallet',13)
c(x,pw,top+743,'Watch an address',12,SUB);c(x,pw,top+777,'Never share your master key.',10,SUB)
# Trade
x=xs[1];t(x+23,top+139,'Trade',35,TEXT,True);r(x+22,top+201,pw-44,43);r(x+26,top+205,138,35,'#234336','#234336',9);c(x+26,138,top+215,'Native markets',10);c(x+164,141,top+215,'Launchpad',10,SUB)
t(x+27,top+260,'●  Connect live data   ›',10,SUB)
r(x+22,top+298,pw-44,278);r(x+139,top+320,58,58,'#10281c',LINE,29);c(x+139,58,top+330,'⇄',26,GREEN)
c(x+22,pw-44,top+406,'Find your next trade',23,TEXT,True)
c(x+22,pw-44,top+449,'Connect your data gateway to see',11,SUB);c(x+22,pw-44,top+467,'current markets and prices.',11,SUB)
button(x+43,top+515,pw-86,'Connect live data')
t(x+23,top+606,'Explore markets',21,TEXT,True);r(x+22,top+643,pw-44,88);t(x+39,top+658,'Noidium',23,TEXT,True);t(x+283,top+660,'↗',19);t(x+39,top+700,'Open the ecosystem trading terminal',10,SUB)
# Collect
x=xs[2];t(x+23,top+139,'Collect',35,TEXT,True);r(x+22,top+201,pw-44,43);r(x+26,top+205,138,35,'#234336','#234336',9);c(x+26,138,top+215,'My collection',10);c(x+164,141,top+215,'Marketplace',10,SUB)
r(x+22,top+257,pw-44,40);t(x+40,top+270,'All collections',11);t(x+286,top+270,'⌄',12)
t(x+27,top+313,'●  Connect live data   ›',10,SUB);t(x+245,top+313,'Artwork off',9,SUB)
r(x+22,top+345,pw-44,40);t(x+39,top+358,'⌕  Collection ID or serial',11,SUB)
r(x+139,top+428,58,58,'#10281c',LINE,29);c(x+139,58,top+439,'▱',26,GREEN)
c(x+22,pw-44,top+522,'A home for your collection',19,TEXT,True)
c(x+22,pw-44,top+564,'Connect live data to browse authentic',11,SUB);c(x+22,pw-44,top+582,'ecosystem collections.',11,SUB)
button(x+43,top+631,pw-86,'Connect live data')
r(x+22,top+679,pw-44,52);t(x+39,top+692,'Explore Octonoid',18,TEXT,True);t(x+284,top+692,'↗',18)
# Chat
x=xs[3];t(x+23,top+139,'Chat',35,TEXT,True);t(x+23,top+193,'Encrypted conversations with contacts',12,SUB);t(x+23,top+212,'you verify.',12,SUB)
r(x+22,top+262,pw-44,348);c(x+22,pw-44,top+286,'▢',27,GREEN)
c(x+22,pw-44,top+348,'Your people,',24,TEXT,True);c(x+22,pw-44,top+379,'your keys.',24,TEXT,True)
for yy,s in [(436,'Connect a contact to exchange'),(457,'encrypted messages and payment'),(478,'packets. Check their full identity'),(499,'together before sharing anything'),(520,'sensitive.')]:c(x+22,pw-44,top+yy,s,11,SUB)
button(x+44,top+550,pw-88,'Open messages   ↗')
r(x+22,top+626,pw-44,62);t(x+42,top+646,'♧   Connected contacts',12);t(x+286,top+646,'›',14,SUB)
for yy,s in [(695,'Encrypted packet exchange is experimental.'),(711,'Bluetooth delivery and later blockchain'),(727,'settlement need physical-phone verification.')]:t(x+23,top+yy,s,9,SUB)
t(37,23,'Parano1d Wallet',25,TEXT,True);t(307,top-63,'CURRENT SOURCE · BUILD 25',10,SUB)
for x,lab in zip(xs,['FIRST LAUNCH','TRADE','COLLECT','CHAT']):c(x,pw,top+824,lab,10,SUB)
c(0,W,H-18,'Code-based layout preview · Centered focal elements · Live data and physical iPhone rendering remain unverified',10,SUB)
im.save(R/'Parano1d-centered-preview.png',optimize=True)
