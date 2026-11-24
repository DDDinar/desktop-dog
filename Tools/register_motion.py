"""Register the original transparent atlases without resampling their pixels."""

import json
from pathlib import Path

from PIL import Image

motion = Path(__file__).resolve().parents[1] / "Assets/Photo/Motion"

# Each clip keeps one uniform scale. The X coordinate marks the torso (or
# chest, for head-on views); the lowest fully visible paw defines the floor.
# The jump moves right within its atlas, so register its torso in every cell.
clips = {
    "trot": ("Action", 4, 0, 0.578, 166),
    "jump": ("Action", 4, 2, 0.578, (128, 131, 147, 171, 187, 188, 178, 166)),
    "wag": ("Wag", 2, 0, 0.329, 230),
    "bed": ("Bed", 3, 0, 0.482, 182),
}

registered = {}
for name, (atlas, rows, first_row, scale, pivot_x) in clips.items():
    alpha = Image.open(motion / f"{atlas}.png").getchannel("A")
    solid = alpha.point(lambda x: 255 if x > 38 else 0)
    frames = []
    for index in range(12 if name == "bed" else 8):
        row, col = first_row + index // 4, index % 4
        x, y = col * alpha.width // 4, row * alpha.height // rows
        right, bottom = (col + 1) * alpha.width // 4, (row + 1) * alpha.height // rows
        l, t, r, b = solid.crop((x, y, right, bottom)).getbbox()
        if l < 2 or t < 2 or r > right - x - 2 or b > bottom - y - 2:
            raise ValueError(f"{name} frame {index}: transparent gutter is missing")
        # A little space for translucent fur around the opaque silhouette.
        bounds = [max(x, x + l - 6), max(y, y + t - 6),
                  min(right, x + r + 6), min(bottom, y + b + 6)]
        horizontal = pivot_x if isinstance(pivot_x, int) else pivot_x[index]
        frames.append(bounds + [x + horizontal, y + b - 2])
    if name == "bed":
        # pack_bed.swift adds four registered 362px cells under the original sheet.
        for i in range(4):
            x, y = i * 362, 3 * 362
            frames.append([x, y, x + 362, y + 330, x + 182, y + 320])
    registered[name] = dict(atlas=atlas, scale=scale, frames=frames)

# The first pose is an exact copy of wag frame 3. The two actions share
# their standing pose. Register the near forepaw at a fixed ground point.
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
    registered[name] = dict(atlas="Breaks", scale=registered["wag"]["scale"], frames=frames)

# Nine poses from a single photographic turnaround. The paws are measured at
# their pads in the source cell. Order: right fore, left fore, right hind,
# left hind. Hidden paws share the ground rig but do not warp visible fur.
turn_toes = [
    [(215,382,1),(267,374,1),(175,344,1),(243,336,0)],
    [(202,382,1),(251,373,1),(131,343,1),(173,334,0)],
    [(230,382,1),(269,371,1),(103,348,1),(171,335,1)],
    [(246,380,1),(275,366,1),(86,352,1),(149,337,1)],
    [(269,368,1),(281,353,1),(62,359,1),(84,340,1)],
    [(291,352,1),(237,342,1),(130,377,1),(85,357,1)],
    [(281,368,1),(219,362,1),(170,400,1),(105,384,1)],
    [(259,361,1),(179,346,0),(219,401,1),(140,392,1)],
    [(243,358,0),(203,353,1),(241,401,1),(166,397,1)],
]
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
registered["pivot"] = dict(atlas="Pivot", scale=scale, frames=frames, toes=toes)

with (motion / "Atlas.json").open("w", encoding="utf-8") as out:
    json.dump(registered, out, separators=(",", ":"), indent=1)
    out.write("\n")
