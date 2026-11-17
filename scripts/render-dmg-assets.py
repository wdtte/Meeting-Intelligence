#!/usr/bin/env python3
"""Optional macOS/Pillow source for the checked-in installer artwork."""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
import math, subprocess, tempfile
R=Path(__file__).resolve().parent.parent/'Resources/Installer'
R.mkdir(parents=True,exist_ok=True)
S=4; W,H=720,272
BG=(247,251,254)
bg=Image.new('RGBA',(W*S,H*S),BG)
d=ImageDraw.Draw(bg)
# Trace the reference's broad smile, with rounded ends and a slim open head.
pts=[]
for i in range(241):
 t=i/240;u=1-t
 pts.append(((u**3*217.5+3*u*u*t*278+3*u*t*t*399+t**3*468.5)*S,(u**3*198+3*u*u*t*264+3*u*t*t*264+t**3*198)*S))
def line(points,width=6):
 d.line(points,fill='#607D91',width=round(width*S),joint='curve')
 r=width*S/2
 for x,y in [points[0],points[-1]]:d.ellipse((x-r,y-r,x+r,y+r),fill='#607D91')
left=[];right=[]
for i,(x,y) in enumerate(pts):
 a=pts[max(0,i-1)];b=pts[min(len(pts)-1,i+1)];dx=b[0]-a[0];dy=b[1]-a[1];n=math.hypot(dx,dy)
 left.append((x-dy/n*3*S,y+dx/n*3*S));right.append((x+dy/n*3*S,y-dx/n*3*S))
d.polygon(left+right[::-1],fill='#607D91')
for x,y in [pts[0],pts[-1]]:d.ellipse((x-3*S,y-3*S,x+3*S,y+3*S),fill='#607D91')
line([(442*S,201.5*S),(468.5*S,198*S),(472.5*S,225*S)])
font=ImageFont.truetype('/System/Library/Fonts/SFNS.ttf',25*S)
font.set_variation_by_axes([100,28,400,500])
mask=Image.new('L',bg.size);md=ImageDraw.Draw(mask)
md.text((350*S,135*S),'drag and drop',font=font,fill=255,anchor='mm',stroke_width=0)
bounds=mask.getbbox();grad=Image.new('RGBA',bg.size)
gd=ImageDraw.Draw(grad)
for x in range(bounds[0],bounds[2]):
 t=(x-bounds[0])/(bounds[2]-bounds[0]-1)
 c=tuple(round(a*(1-t)+b*t) for a,b in zip((49,55,64),(111,139,157)))
 gd.line((x,0,x,H*S),fill=c)
bg.paste(grad,(0,0),mask)
for scale,suffix in [(1,''),(2,'@2x')]:bg.resize((W*scale,H*scale),Image.Resampling.LANCZOS).convert('RGB').save(R/f'background{suffix}.png')
# A quiet silver drive with the application's waveform etched into the top.
I=1024; icon=Image.new('RGBA',(I,I))
def surface(points,top,bottom):
 m=Image.new('L',(I,I));ImageDraw.Draw(m).polygon(points,fill=255)
 g=Image.new('RGBA',(I,I));dd=ImageDraw.Draw(g);y0=math.floor(min(y for x,y in points));y1=math.ceil(max(y for x,y in points))
 for y in range(y0,y1+1):
  t=(y-y0)/(y1-y0);c=tuple(round(a*(1-t)+b*t) for a,b in zip(top,bottom));dd.line((0,y,I,y),fill=c)
 icon.paste(g,(0,0),m)
# Smooth quadratic corners on the slightly tapered drive body.
def path(start,segments):
 out=[start];p=start
 for kind,data in segments:
  if kind=='L':out.append(data);p=data
  else:
   q,end=data
   for j in range(1,31):
    t=j/30;out.append(((1-t)**2*p[0]+2*(1-t)*t*q[0]+t*t*end[0],(1-t)**2*p[1]+2*(1-t)*t*q[1]+t*t*end[1]))
   p=end
 return out
front=path((174,617),[('L',(850,617)),('L',(850,745)),('Q',((850,782),(812,782))),('L',(212,782)),('Q',((174,782),(174,745))),('L',(174,617))])
surface(front,(165,174,184),(208,215,222))
top=path((249,247),[('L',(775,247)),('Q',((809,247),(817,285))),('L',(850,645)),('Q',((854,683),(815,683))),('L',(209,683)),('Q',((170,683),(174,645))),('L',(207,285)),('Q',((215,247),(249,247)))])
surface(top,(248,250,252),(218,225,232))
id=ImageDraw.Draw(icon);id.line(top+[top[0]],fill='#F8FAFC',width=3)
# Six bars follow the brand waveform and remain readable at small sizes.
for x,h in [(377,63),(431,138),(485,202),(539,114),(593,163),(647,82)]:
 y=452-h/2
 id.rounded_rectangle((x-13,y,x+13,y+h),radius=13,fill='#596670')
id.line((237,716,690,716),fill='#A3AFBA',width=3)
id.rounded_rectangle((744,712,778,721),radius=4,fill='#477FA5')
icon.save(R/'volume-icon.png')
with tempfile.TemporaryDirectory(prefix='meeting-volume-icon-') as scratch:
 iconset=Path(scratch)/'Volume.iconset';iconset.mkdir()
 for n in [16,32,128,256,512]:
  for scale in [1,2]:
   icon.resize((n*scale,n*scale),Image.Resampling.LANCZOS).save(iconset/f'icon_{n}x{n}{"@2x" if scale==2 else ""}.png')
 subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(R/'volume-icon.icns')],check=True)
