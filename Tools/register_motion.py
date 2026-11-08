"""Register the original transparent atlases without resampling their pixels."""

import json
from pathlib import Path

from PIL import Image

motion = Path(__file__).resolve().parents[1] / "Assets/Photo/Motion"

# Each clip keeps one uniform scale. The X coordinate marks the torso (or
# chest, for head-on views); the lowest fully visible paw defines the floor.
# The jump moves right within its atlas, so register its torso in every cell.
clips = {
    "side": ("Side", 2, 0, 0.401, 231),
    "near": ("Near", 2, 0, 0.397, 240),
    "far": ("Far", 2, 0, 0.380, 229),
    "front": ("Axial", 4, 0, 0.416, 169),
    "back": ("Axial", 4, 2, 0.409, 171),
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
    registered[name] = dict(atlas=atlas, scale=scale, frames=frames)

with (motion / "Atlas.json").open("w", encoding="utf-8") as out:
    json.dump(registered, out, separators=(",", ":"), indent=1)
    out.write("\n")
