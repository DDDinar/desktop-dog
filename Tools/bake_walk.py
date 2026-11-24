"""Bake the four-beat walk from the same registered photographs as the turn.

The chest, hips and head keep one exposure per view. Each leg has a shoulder
or hip, elbow or stifle, carpus or hock, and a paw. Work in sagittal coordinates
and project into the camera only after solving the joints.
"""
from pathlib import Path
import json
import math
import sys

import numpy as np
from PIL import Image

MOTION = Path(__file__).resolve().parents[1] / "Assets/Photo/Motion"
STRIDE = 48.0
SUPPORT = 0.64
DEPTH = 0.52
RISE = math.sqrt(1 - DEPTH**2)
# Partial loads need fewer samples. Full stride has one exposure per point travelled.
BANDS = [(0.32, 12), (0.65, 24), (1.0, 48)]
# Measured in half-resolution coordinates within each source cell. The first curve
# follows the underside of the chest and hips. For the two closest visible limbs,
# cross-sections give the left and right edges from root to sole. Overlapped far
# limbs are reconstructed with the same coat, at their own registered ground point.
RIGS = [
    ([(68,124),(85,128),(105,140),(124,143),(144,139),(160,129)],
     [(93,123,108),(91,122,137),(92,119,163),(94,122,181),(96,123,187),(101,120,191)],
     [(78,105,105),(79,101,129),(82,96,151),(81,95,166),(82,95,170),(85,92,172)]),
    ([(48,115),(62,117),(77,119),(96,141),(123,137),(142,124),(155,119)],
     [(76,113,106),(80,111,138),(83,109,159),(87,113,179),(89,119,187),(97,112,191)],
     [(54,83,95),(54,80,119),(54,77,142),(54,77,160),(53,78,169),(59,73,172)]),
    ([(34,108),(51,111),(72,116),(84,128),(104,133),(126,137),(151,122),(170,116)],
     [(86,132,99),(94,126,134),(97,124,153),(99,124,173),(101,131,186),(108,127,191)],
     [(40,76,93),(43,70,118),(40,64,144),(40,62,162),(38,66,169),(45,62,174)]),
    ([(20,106),(42,111),(62,117),(74,113),(88,121),(106,130),(133,133),(149,119),(164,114)],
     [(85,131,95),(91,126,126),(96,125,147),(102,126,166),(105,134,181),(112,138,187),(117,133,190)],
     [(30,70,86),(31,62,111),(31,55,137),(29,52,158),(29,56,171),(34,54,176)]),
    ([(8,110),(28,111),(44,119),(63,113),(76,119),(99,125),(119,130),(142,128),(163,111)],
     [(100,148,89),(103,141,116),(110,137,138),(113,138,157),(118,145,173),(124,152,180),(131,146,184)],
     [(15,63,87),(18,54,112),(16,49,135),(13,40,155),(15,40,170),(19,45,177),(26,42,181)]),
    ([(24,115),(40,122),(58,130),(76,121),(88,117),(105,124),(126,127),(150,113),(172,108)],
     [(125,163,92),(126,156,120),(129,152,143),(129,151,159),(132,160,169),(136,161,173),(141,157,176)],
     [(49,91,91),(53,86,118),(49,80,143),(46,74,164),(47,79,179),(52,83,185),(60,75,189)]),
    ([(32,123),(50,132),(78,141),(98,138),(116,128),(136,128),(158,113),(177,106)],
     [(124,160,100),(123,157,126),(125,151,149),(124,149,168),(126,155,178),(132,154,182),(137,147,185)],
     [(70,114,102),(70,106,132),(68,99,155),(67,96,174),(69,100,190),(72,102,196),(80,97,200)]),
    ([(48,125),(63,137),(84,143),(105,147),(125,136),(143,124),(154,116)],
     [(117,152,98),(121,146,123),(124,141,143),(123,139,161),(123,142,174),(128,140,179),(131,137,181)],
     [(85,130,104),(88,125,133),(89,121,153),(92,123,175),(94,125,189),(96,126,195),(103,121,200)]),
    ([(54,124),(74,141),(98,146),(116,146),(135,142),(149,122)],
     [(85,122,102),(86,117,129),(88,113,150),(92,111,168),(96,110,175),(100,108,177)],
     [(102,144,102),(105,140,131),(105,138,155),(107,136,176),(106,137,190),(108,137,197),(116,130,201)]),
]


# Tail plume and cheek centres, followed by the base of the tail and neck.
# The coordinates use the same half-resolution photograph as the limb guides.
UPPER_BODY = [
    (None,                  (119,58,115,98)),
    ((79,31,79,66),         (126,59,119,96)),
    ((65,32,65,66),         (141,59,123,98)),
    ((55,34,50,65),         (148,58,130,96)),
    ((44,34,40,66),         (165,55,141,91)),
    ((56,39,53,72),         (157,53,134,89)),
    ((65,54,61,88),         (139,48,123,91)),
    ((88,59,81,93),         None),
    ((102,64,100,97),       None),
]


def interp(shape, x):
    return np.interp(x, *np.array(shape).T)


def smooth(x):
    t = np.clip(x, 0, 1)
    return t*t*(3-2*t)


def articulation(phase, strength, hind, height):
    # Positive F points to the muzzle; positive H points up.
    if phase < SUPPORT:
        advance = STRIDE * (SUPPORT/2 - phase)
        swing = 0
    else:
        t = (phase-SUPPORT)/(1-SUPPORT)
        advance = STRIDE * (SUPPORT/2-phase + t**3*(10-15*t+6*t*t))
        swing = math.sin(math.pi*t)**2
    toe_motion = np.array([advance, (8.8 if hind else 6.7)*swing])*strength
    rest = np.array([(0,55),(14,31),(-8,13),(-3,0)] if hind else
                    [(0,55),(-11,31),(0,10),(3,0)], dtype=float) * height/55
    toe = rest[3] + toe_motion
    lower = rest[2]-rest[3]
    tilt = strength*(0.08*advance/(STRIDE/2) + (0.36 if hind else 0.49)*swing)
    rot = np.array([[math.cos(tilt),-math.sin(tilt)],[math.sin(tilt),math.cos(tilt)]])
    hock = toe + rot@lower
    root = rest[0].copy()
    # The scapula glides a little with the foreleg's reach.
    root[0] += (0.05 if hind else 0.16)*advance*strength
    line = hock-root
    a,b = np.linalg.norm(rest[1]-rest[0]),np.linalg.norm(rest[2]-rest[1])
    distance = np.linalg.norm(line)
    axis = line/distance
    along = min(a,(a*a-b*b+distance*distance)/(2*distance))
    perp = np.array([-axis[1],axis[0]])*(1 if hind else -1)
    middle = root+axis*along+perp*math.sqrt(max(0,a*a-along*along))
    return np.stack((root,middle,hock,toe))-rest


def sample(image, x, y):
    # Coordinates are pixel-centred and the image is premultiplied.
    h,w = image.shape[:2]
    x=np.clip(x,0,w-1.001);y=np.clip(y,0,h-1.001)
    i=x.astype(int); j=y.astype(int)
    fx=(x-i)[...,None];fy=(y-j)[...,None]
    return (image[j,i]*(1-fx)+image[j,i+1]*fx)*(1-fy)+(image[j+1,i]*(1-fx)+image[j+1,i+1]*fx)*fy


def warp_limb(texture, source, target, X, Y):
    # Blend inverse rigid bone transforms chiefly at the joint, not across
    # the entire limb. A terminal horizontal segment preserves the paw pad.
    sx=0.;sy=0.;ws=0.
    for a,b,A,B in zip(source,source[1:],target,target[1:]):
        v=B-A; old=b-a; length=np.dot(v,v)
        dx=X-A[0];dy=Y-A[1]
        t=(dx*v[0]+dy*v[1])/length
        across=(-dx*v[1]+dy*v[0])/math.sqrt(length)
        closest=np.clip(t,0,1)
        dist=(dx-closest*v[0])**2+(dy-closest*v[1])**2
        w=1/(10+dist)**2.5
        n=old/np.linalg.norm(old)
        sx+=w*(a[0]+t*old[0]-across*n[1])
        sy+=w*(a[1]+t*old[1]+across*n[0]);ws+=w
    return sample(texture,sx/ws,sy/ws)


def over(bg, fg):
    return fg+bg*(1-fg[:,:,3:4]/255)


def unpremultiply(image):
    out=image.copy()
    out[:,:,:3]*=255/np.maximum(out[:,:,3:4],0.01)
    rgba = np.uint8(np.clip(out+0.5,0,255))
    # Match the upload cutoff in PhotoTexture and omit hidden RGB in transparent gutters.
    rgba[rgba[:, :, 3] <= 8] = 0
    return Image.fromarray(rgba)


class View:
    def __init__(self, i, sheet, clip):
        col,row=i%3,i//3
        rows=[0,400,798,1230]
        self.cell=(col*426,rows[row])
        self.unit=2*clip["scale"]
        self.angle=(i-4)*math.pi/8
        self.texture=np.array(sheet.crop((col*426,rows[row],(col+1)*426,rows[row+1])),dtype=np.float32)
        self.texture[:,:,:3]*=self.texture[:,:,3:4]/255
        h,w=self.texture.shape[:2]
        Y,X=np.mgrid[:h,:w].astype(float)/2
        belly,fore,hind=RIGS[i]
        envelope=interp(belly,X)
        # Keep small tufts along the newly revealed underside.
        grain=np.sin(X*1.7+0.9*np.sin(X*2.4))*0.8 + np.sin(X*.35)*1.4
        self.body=self.texture*smooth((envelope+grain-Y+4)/6)[:,:,None]
        f=clip["frames"][i]
        self.pivot=np.array(f[4:6])-self.cell
        self.feet=np.array(clip["toes"][i],dtype=float).reshape(4,3)
        self.legs=[]
        for data in (fore,hind):
            lo,hi,heights=np.array(data).T
            left=np.interp(Y,heights,lo);right=np.interp(Y,heights,hi)
            mask=smooth((X-left+0.65)/1.2)*smooth((right-X+0.65)/1.2)
            mask*=smooth((Y-heights[0]+3)/17)*smooth((heights[-1]+0.7-Y)/1.2)
            skin=self.texture*mask[:,:,None]
            # A cropped near-side leg supplies its obscured counterpart too.
            # Ground points and lengths differ; only fur comes from the same exposure.
            ys=np.array([heights[0]+1,heights[0]+(heights[-1]-heights[0])*.43,
                         heights[-1]-(heights[-1]-heights[0])*.22,heights[-1]-3])
            xs=np.interp(ys,heights,(lo+hi)/2)
            toes=np.stack([xs,ys],axis=1)
            source = toes*2
            leg = 0 if len(self.legs)==0 else 2
            source[-1] = self.pivot+self.feet[leg,:2]/clip['scale']
            self.legs.append((skin,np.vstack([source,source[-1]+[13,0]])))
        self.nominal=np.array(f[:4])-np.tile(self.cell,2)
        # Preserve a constant floor origin for the entire atlas. Reserve space for toe-off.
        box=self.nominal + [-62,-10,62,30]
        self.box=box
        self.pixel_scale=.54
        self.size=np.ceil((box[2:]-box[:2])*clip['scale']/self.pixel_scale).astype(int)
        y,x=np.mgrid[:self.size[1],:self.size[0]]
        self.X=(x+.5)*self.pixel_scale/clip['scale']+box[0]-.5
        self.Y=(y+.5)*self.pixel_scale/clip['scale']+box[1]-.5
        self.upperMask=smooth((self.Y/2-interp(belly,self.X/2)+17)/14)
        self.zoom=clip['scale']

        # All curls in a patch follow the same small rotation. Fade it out at
        # the attachment; a hidden tail or face doesn't deform the covering fur.
        self.upper_body = []
        for guide, radii in zip(UPPER_BODY[i], [(36,41), (54,52)]):
            if guide is None:
                self.upper_body.append(None)
                continue
            cx,cy,bx,by = guide
            distance = ((self.X/2-cx)/radii[0])**2 + ((self.Y/2-cy)/radii[1])**2
            weight = 1-smooth((distance-0.52)/0.63)
            self.upper_body.append((2*bx,2*by,weight))

    def coat(self, phase, strength, shift):
        x,y = self.X-shift[0], self.Y-shift[1]
        stride = 2*math.pi*phase
        # The plume follows the weight transfer with a lag. The head makes a
        # smaller counter-movement on each beat to steady the dog's gaze.
        tail = (0.049+0.064*abs(math.sin(self.angle)))*math.sin(stride-0.55)
        nod = 0.022*math.cos(self.angle)*math.cos(2*stride-0.8)
        sx,sy = x,y
        for region, rotation in zip(self.upper_body, (tail,nod)):
            if region is None:
                continue
            bx,by,weight = region
            angle = rotation*strength
            c,s = math.cos(angle)-1, math.sin(angle)
            sx = sx + weight*(c*(x-bx)+s*(y-by))
            sy = sy + weight*(c*(y-by)-s*(x-bx))
        head = self.upper_body[1]
        if head is not None:
            sy = sy + head[2]*0.55*shift[1]
        return sample(self.body,sx,sy)

    def render(self, phase, strength):
        angle=self.angle; project=np.array([[math.cos(angle),0],[-DEPTH*math.sin(angle),-RISE]])
        bob=0.7*math.cos(4*math.pi*(phase-.04))*strength
        sway=0.7*math.sin(2*math.pi*phase)*strength
        shift=np.array([sway*math.sin(angle),bob+sway*math.cos(angle)*DEPTH])/self.zoom
        pose=[None]*4
        # Fore and hind legs on a side touch down a quarter-cycle apart.
        offsets=(.25,.75,0,.5)
        for leg,offset in enumerate(offsets):
            hind=leg>=2; far=leg%2==1
            texture,src=self.legs[int(hind)]
            toe=self.pivot+self.feet[leg,:2]/self.zoom
            depth=.90 if far else 1.
            # Keep the soles on their measured ground plane.
            base=toe+(src-src[3])*depth
            if far:
                # Both shoulder blades and hips remain inside the trunk, even
                # where the distant toe is laterally offset in a frontal view.
                base[0,0] = .65*src[0,0] + .35*base[0,0]
                base[1,0] = .22*src[1,0] + .78*base[1,0]
            height=max(30,(src[3,1]-src[0,1])*depth*self.zoom/RISE)
            delta=articulation((phase-offset)%1, strength, hind, height)
            motion=delta@project.T/self.zoom
            target=base.copy();target[:4]+=motion;target[4]+=motion[3]
            target[0]+=shift; target[1]+=0.42*shift
            pose[leg]=(texture,src,target)
        pix=np.zeros((*self.X.shape,4),dtype=np.float32)
        # Sort by distance to the viewer (forepaws nearest in the frontal views).
        order=np.argsort(-self.feet[:,1])
        for leg in reversed(order):
            texture,src,target=pose[leg]
            # Sample only the tight moving limb rectangle.
            lo=target.min(axis=0)-50;hi=target.max(axis=0)+50
            xx=np.where((self.X[0]>=lo[0]) & (self.X[0]<=hi[0]))[0]
            yy=np.where((self.Y[:,0]>=lo[1]) & (self.Y[:,0]<=hi[1]))[0]
            if len(xx)==0 or len(yy)==0:continue
            q=np.s_[yy[0]:yy[-1]+1,xx[0]:xx[-1]+1]
            painted=warp_limb(texture,src,target,self.X[q],self.Y[q])
            if leg%2==1:painted[:,:,:3]*=.94
            pix[q]=over(pix[q],painted)
        chest=self.coat(phase,strength,shift)
        pix*=np.minimum(1,self.upperMask+chest[:,:,3]/255)[:,:,None]
        pix=over(pix,chest)
        toes=[(d[2][3]-self.pivot)*self.zoom for d in pose]
        return unpremultiply(pix),toes


def bake():
    clip=json.loads((MOTION/"Atlas.json").read_text())["pivot"]
    sheet=Image.open(MOTION/"Pivot.png").convert("RGBA")
    dest=Path(sys.argv[1]) if len(sys.argv)>1 else MOTION
    indices=list(map(int,sys.argv[2:])) if len(sys.argv)>2 else list(range(9))
    manifest={}
    for i in indices:
        v=View(i,sheet,clip)
        poses = [v.render(k/n, strength) for strength, n in BANDS for k in range(n)]
        # A fixed cropped cell preserves registration and keeps unused transparent
        # texels out of the GPU's working set. Two gutter texels isolate neighbours.
        limits = np.array([image.getchannel("A").getbbox() for image,_ in poses])
        box = (*limits[:, :2].min(axis=0), *limits[:, 2:].max(axis=0))
        w, h = box[2] - box[0] + 4, box[3] - box[1] + 4
        cols = 8
        atlas = Image.new("RGBA", (w*cols, h*math.ceil(len(poses)/cols)))
        frames, toes = [], []
        for ix,(image,feet) in enumerate(poses):
            x, y = (ix % cols)*w+2, (ix // cols)*h+2
            atlas.paste(image.crop(box), (x,y))
            pivot = (v.pivot-v.box[:2])*v.zoom/v.pixel_scale+[x-box[0],y-box[1]]
            frames.append([int(x), int(y), int(x+w-4), int(y+h-4), *np.round(pivot,3).tolist()])
            toes.append(np.round(feet,3).flatten().tolist())
        name="Walk"+str(i)
        atlas.save(dest/(name+".png"),compress_level=7)
        manifest["walk"+str(i)]=dict(atlas=name,scale=v.pixel_scale,frames=frames,toes=toes)
        print(name,atlas.size,flush=True)
    (dest/"Walk.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")

if __name__=="__main__":bake()
