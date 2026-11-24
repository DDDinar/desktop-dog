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
TROT_STRIDE = 68.0
TROT_SUPPORT = 0.54
TROT_BANDS = [(0.60, 20), (1.0, 36)]
DEPTH = 0.52
RISE = math.sqrt(1 - DEPTH**2)
# Partial loads need fewer samples. Full stride has one exposure per point travelled.
BANDS = [(0.32, 12), (0.65, 24), (1.0, 48)]
# Half-resolution coordinates in each photographic exposure. Curves follow the
# belly and the actual edges of each visible limb, from its root to its toes.
# Order within a view is right fore, left fore, right hind, left hind. Where a
# paw is occluded its counterpart provides the overlapping patch of coat.
RIGS = [
    ([(66,119),(78,137),(90,142),(101,136),(110,137),(119,144),(130,132),(137,117)],
     [(73,103,111),(75,101,139),(78,100,162),(78,99,177),(77,100,188),(83,97,193)],
     [(103,132,112),(102,130,137),(104,128,162),(105,128,177),(105,130,189),(111,125,194)],
     [(70,90,108),(72,87,133),(71,82,152),(68,81,166),(72,80,171)], None),
    ([(48,108),(59,118),(69,113),(78,118),(86,132),(102,141),(117,140),(131,133),(141,117)],
     [(74,105,104),(77,102,133),(79,101,155),(80,101,176),(79,105,189),(85,100,194)],
     [(105,140,110),(107,136,136),(109,131,156),(109,131,173),(112,136,186),(117,132,191)],
     [(50,72,93),(50,69,119),(50,66,145),(50,65,159),(47,66,167),(52,64,170)],None),
    ([(36,105),(49,115),(61,112),(70,120),(82,119),(95,132),(110,139),(123,137),(140,126),(150,117)],
     [(89,117,98),(90,116,127),(91,114,151),(92,114,173),(93,118,189),(98,114,194)],
     [(117,150,102),(117,145,127),(117,140,149),(119,138,169),(120,144,185),(126,140,191)],
     [(39,65,92),(39,62,117),(38,56,140),(35,51,158),(34,54,167),(39,51,171)],
     [(62,88,99),(65,87,119),(65,82,140),(65,80,155),(67,88,166),(73,86,170)]),
    ([(26,106),(41,117),(53,114),(62,117),(73,120),(83,124),(96,130),(113,136),(131,134),(144,123),(151,116)],
     [(87,120,99),(90,116,125),(92,114,148),(93,113,170),(94,119,186),(98,119,192)],
     [(114,147,103),(113,141,129),(115,137,152),(116,134,168),(118,141,181),(124,138,187)],
     [(29,60,95),(29,54,117),(28,46,141),(26,42,157),(25,46,171),(31,44,176)],
     [(55,83,95),(55,80,121),(54,74,141),(54,70,156),(57,79,168),(64,77,171)]),
    ([(18,106),(35,120),(52,112),(64,115),(76,116),(92,124),(103,129),(118,133),(133,131),(150,112)],
     [(97,141,95),(100,136,124),(104,133,146),(106,131,166),(108,135,185),(115,134,192)],
     None,  # The near wrist covers the distant foreleg in profile.
     [(22,57,94),(21,51,117),(18,43,141),(14,34,159),(16,36,170),(17,43,178),(18,42,182),(23,40,184)],
     [(39,69,96),(41,65,119),(38,59,143),(35,52,158),(38,57,170),(44,55,177)]),
    ([(31,110),(43,122),(57,131),(70,129),(84,119),(96,119),(108,125),(122,131),(141,126),(151,115)],
     [(120,157,100),(123,153,124),(127,147,146),(129,145,163),(129,154,178),(136,150,184)],
     [(98,129,101),(103,129,127),(107,128,147),(106,126,161),(107,131,174),(114,128,178)],
     [(48,87,96),(49,80,125),(47,71,147),(47,65,165),(49,75,184),(55,75,193)],
     [(33,58,95),(33,56,124),(28,49,146),(26,44,166),(27,48,179),(33,47,184)]),
    ([(34,123),(52,132),(67,139),(82,144),(97,137),(111,132),(127,134),(141,126),(154,112)],
     [(124,155,105),(123,152,133),(124,147,155),(124,144,173),(126,151,187),(132,148,192)],
     [(97,126,108),(98,124,135),(99,117,157),(98,115,172),(99,119,183),(104,116,187)],
     [(64,104,108),(67,100,138),(66,91,162),(64,87,179),(68,88,197),(73,99,204),(78,96,210)],
     [(41,69,108),(40,67,138),(34,58,161),(33,52,180),(35,56,196),(41,55,202)]),
    ([(46,125),(59,139),(73,138),(86,142),(101,147),(115,138),(129,131),(142,117)],
     [(118,149,105),(119,147,132),(118,142,153),(119,139,170),(119,143,183),(126,140,190)],None,
     [(83,123,108),(86,120,136),(87,116,158),(86,110,180),(88,110,199),(91,115,206),(97,111,210)],
     [(53,84,110),(53,82,138),(50,75,159),(50,69,181),(50,69,199),(52,73,205),(58,70,207)]),
    ([(66,125),(78,137),(89,144),(102,148),(116,146),(128,140),(134,125)],
     [(94,114,107),(94,113,136),(94,110,157),(92,108,175),(90,106,184),(95,103,188)], None,
     [(105,135,107),(108,135,137),(109,130,159),(109,130,180),(110,131,199),(110,135,206),(117,130,210)],
     [(66,97,107),(67,96,136),(70,94,158),(71,90,180),(70,89,199),(67,90,206),(73,86,209)]),
]

# Tail tip / cheek centre followed by the base of the tail / neck.
UPPER_BODY = [
    (None,                (105,59,106,100)),
    ((75,43,62,63),      (128,59,117,97)),
    ((65,44,48,67),      (151,59,123,96)),
    ((54,45,34,76),      (152,59,127,94)),
    ((49,44,23,78),      (162,61,132,94)),
    ((44,44,35,81),      (156,58,136,94)),
    ((56,57,45,92),      (143,59,126,99)),
    ((72,57,61,99),      None),
    ((95,65,95,104),     None),
]


def interp(shape, x):
    return np.interp(x, *np.array(shape).T)


def smooth(x):
    t = np.clip(x, 0, 1)
    return t*t*(3-2*t)


def articulation(phase, strength, hind, height, trot=False):
    # Positive F points to the muzzle; positive H points up.
    support = TROT_SUPPORT if trot else SUPPORT
    stride = TROT_STRIDE if trot else STRIDE
    if phase < support:
        advance = stride * (support/2 - phase)
        swing = 0
    else:
        t = (phase-support)/(1-support)
        advance = stride * (support/2-phase + t**3*(10-15*t+6*t*t))
        swing = math.sin(math.pi*t)**2
    lift = (13.5 if hind else 10.8) if trot else (8.8 if hind else 6.7)
    toe_motion = np.array([advance, lift*swing])*strength
    rest = np.array([(0,55),(14,31),(-8,13),(-3,0)] if hind else
                    [(0,55),(-11,31),(0,10),(3,0)], dtype=float) * height/55
    toe = rest[3] + toe_motion
    lower = rest[2]-rest[3]
    tilt = strength*(0.08*advance/(stride/2) + (0.36 if hind else 0.49)*swing)
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
        belly,*limbs=RIGS[i]
        envelope=interp(belly,X)
        # Keep small tufts along the newly revealed underside.
        grain=np.sin(X*1.7+0.9*np.sin(X*2.4))*0.8 + np.sin(X*.35)*1.4
        self.body=self.texture*smooth((envelope+grain-Y+4)/6)[:,:,None]
        f=clip["frames"][i]
        self.pivot=np.array(f[4:6])-self.cell
        self.feet=np.array(clip["toes"][i],dtype=float).reshape(4,3)
        self.legs=[]
        for leg, data in enumerate(limbs):
            if data is None:
                self.legs.append(self.legs[leg-1])
                continue
            lo,hi,heights=np.array(data).T
            left=np.interp(Y,heights,lo);right=np.interp(Y,heights,hi)
            mask=smooth((X-left+2.1)/2.3)*smooth((right-X+2.1)/2.3)
            mask*=smooth((Y-heights[0]+3)/17)*smooth((heights[-1]+1.7-Y)/2.0)
            skin=self.texture*mask[:,:,None]
            # Use this particular limb’s own fur and measured ground point.
            ys=np.array([heights[0]+1,heights[0]+(heights[-1]-heights[0])*.43,
                         heights[-1]-(heights[-1]-heights[0])*.22,heights[-1]-3])
            xs=np.interp(ys,heights,(lo+hi)/2)
            toes=np.stack([xs,ys],axis=1)
            source = toes*2
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

    def render(self, phase, strength, trot=False, jump_motion=None):
        angle=self.angle; project=np.array([[math.cos(angle),0],[-DEPTH*math.sin(angle),-RISE]])
        bob=(1.6 if trot else 0.7)*math.cos(4*math.pi*(phase-.04))*strength
        sway=0.7*math.sin(2*math.pi*phase)*strength
        shift=np.array([sway*math.sin(angle),bob+sway*math.cos(angle)*DEPTH])/self.zoom
        pose=[None]*4
        # Fore and hind legs on a side touch down a quarter-cycle apart.
        offsets=(0,.5,.5,0) if trot else (.25,.75,0,.5)
        for leg,offset in enumerate(offsets):
            hind=leg>=2; far=leg%2==1
            texture,src=self.legs[leg]
            toe=self.pivot+self.feet[leg,:2]/self.zoom
            borrowed = far and self.legs[leg] is self.legs[leg-1]
            depth=.88 if borrowed else 1.
            # Keep the soles on their measured ground plane.
            base=toe+(src-src[3])*depth
            if borrowed:
                # Both shoulder blades and hips remain inside the trunk, even
                # where the distant toe is laterally offset in a frontal view.
                base[0,0] = .65*src[0,0] + .35*base[0,0]
                base[1,0] = .22*src[1,0] + .78*base[1,0]
            height=max(30,(src[3,1]-src[0,1])*depth*self.zoom/RISE)
            delta=(jump_motion(leg,height) if jump_motion is not None else
                   articulation((phase-offset)%1, strength, hind, height,trot))
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
            if leg%2==1 and self.legs[leg] is self.legs[leg-1]:painted[:,:,:3]*=.92
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
        walk_count = len(poses)
        poses.extend(v.render(k/n, strength, trot=True)
                     for strength,n in TROT_BANDS for k in range(n))
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
        manifest["walk"+str(i)]=dict(atlas=name,scale=v.pixel_scale,
                                     frames=frames[:walk_count],toes=toes[:walk_count])
        manifest["run"+str(i)]=dict(atlas=name,scale=v.pixel_scale,
                                    frames=frames[walk_count:],toes=toes[walk_count:])
        print(name,atlas.size,flush=True)
    (dest/"Walk.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")

if __name__=="__main__":bake()
