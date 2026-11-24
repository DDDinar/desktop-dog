"""Register the original transparent atlases without resampling their pixels."""

import json
from pathlib import Path

from PIL import Image

motion = Path(__file__).resolve().parents[1] / "Assets/Photo/Motion"

# The bed atlas has twelve original exposures. pack_bed.swift adds four more
# at the bottom of the texture in the application bundle.
alpha = Image.open(motion / "Bed.png").getchannel("A")
solid = alpha.point(lambda x: 255 if x > 38 else 0)
frames = []
for index in range(12):
    row, col = divmod(index, 4)
    x, y = col * alpha.width // 4, row * alpha.height // 3
    right, bottom = (col + 1) * alpha.width // 4, (row + 1) * alpha.height // 3
    l, t, r, b = solid.crop((x, y, right, bottom)).getbbox()
    if l < 2 or t < 2 or r > right - x - 2 or b > bottom - y - 2:
        raise ValueError(f"bed frame {index}: transparent gutter is missing")
    frames.append([max(x,x+l-6), max(y,y+t-6), min(right,x+r+6), min(bottom,y+b+6),
                   x+182, y+b-2])
for i in range(4):
    x, y = i*362, 3*362
    frames.append([x,y,x+362,y+330,x+182,y+320])

registered = {"bed": dict(atlas="Bed", scale=0.482, frames=frames)}

# The two actions share the approach. Register the near forepaw at a fixed ground point.
ready = [75, 544, 435, 960, 244, 952]
sheet = Image.open(motion / "Breaks.png").getchannel("A")
for name, cells in [("urinate", [(0, 0, 343), (1, 0, 343), (2, 0, 345)]),
                    ("defecate", [(0, 0, 343), (1, 1, 345), (2, 1, 345)])]:
    frames = [ready, [87, 1099, 424, 1490, 251, 1485],
              [583, 1114, 953, 1490, 786, 1485]]
    for col, row, forepaw in cells:
        x, y = col * 512, row * 512
        alpha = sheet.crop((x, y, x + 512, y + 512))
        l, t, r, b = alpha.point(lambda v: 255 if v > 38 else 0).getbbox()
        frames.append([x+l-4, y+t-4, x+r+4, y+b+4, x+forepaw-26, y+449])
    registered[name] = dict(atlas="Breaks", scale=0.329, frames=frames)

# Nine poses from a single photographic turnaround. The paws are measured at
# their pads in the source cell. Order: right fore, left fore, right hind,
# left hind. Hidden paws share the ground rig but do not warp visible fur.
turn_toes = [
    [(176,386,1),(237,387,1),(149,340,1),(234,334,0)],
    [(183,386,1),(251,380,1),(113,339,1),(161,330,0)],
    [(211,386,1),(267,380,1),(91,340,1),(156,338,1)],
    [(215,384,1),(263,373,1),(74,351,1),(137,340,1)],
    [(247,383,1),(271,366,1),(61,365,1),(99,351,1)],
    [(283,366,1),(243,355,1),(125,384,1),(78,366,1)],
    [(275,385,1),(217,372,1),(171,418,1),(94,402,1)],
    [(266,379,1),(214,362,0),(202,418,1),(122,414,1)],
    [(198,375,1),(219,362,0),(245,419,1),(154,417,1)],
]
# The nose recedes behind the ears on the last three bearings. Its projected
# position still steers the gaze continuously across those photographs.
turn_noses = [(214,118),(266,118),(326,112),(357,113),(387,115),
              (367,111),(327,113),(270,113),(215,110)]
sheet = Image.open(motion / "Pivot.png").getchannel("A")
scale = 0.344
frames, toes = [], []
for i, contacts in enumerate(turn_toes):
    x, y = (i % 3)*426, [0,400,798][i // 3]
    rect = (x,y,x+426,[400,798,1230][i // 3])
    left, top, right, bottom = sheet.crop(rect).point(lambda a: 255 if a>38 else 0).getbbox()
    # The common ground origin is between the four feet. The projection of
    # the support polygon changes with yaw, while its centre stays put.
    cx = round(sum(q[0] for q in contacts) / 4)
    cy = round(sum(q[1] for q in contacts) / 4) + 13
    frames.append([x+left-4,y+top-4,x+right+4,y+bottom+4,x+cx,y+cy])
    toes.append([v for tx,ty,visible in contacts
                 for v in (round((tx-cx)*scale,3),round((ty-cy)*scale,3),visible)])
def registered_landmark(i, point):
    x, y = (i % 3)*426, [0,400,798][i // 3]
    return [round((x+point[0]-frames[i][4])*scale,3),
            round((y+point[1]-frames[i][5])*scale,3)]

noses = [registered_landmark(i, point) for i,point in enumerate(turn_noses)]
tail = registered_landmark(2, (129,87)) + registered_landmark(2, (96,137))
registered["pivot"] = dict(atlas="Pivot", scale=scale, frames=frames, toes=toes,
                           noses=noses, tail=tail)

with (motion / "Atlas.json").open("w", encoding="utf-8") as out:
    json.dump(registered, out, separators=(",", ":"), indent=1)
    out.write("\n")
