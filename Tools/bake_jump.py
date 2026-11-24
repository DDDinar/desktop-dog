"""Bake the jump from the same photographic limb masks as the walk and trot."""
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image

from bake_walk import MOTION, View

SAMPLES = 17
# Absolute rotations from the photographed resting pose (degrees), in the
# sagittal plane. The hind feet push last and fold later than the forefeet.
TIMES = np.array([0.0, 0.18, 0.39, 0.57, 0.75, 0.89, 1.0])
FORE = np.array([[0, 0, 0], [12, -10, -34], [20, -26, -66],
                 [19, -17, -43], [16, 10, -5], [10, 13, 4], [0, 0, 0]])
HIND = np.array([[0, 0, 0], [-21, 14, -18], [6, -8, 1],
                 [30, -19, 23], [25, -15, 15], [-8, 2, -8], [0, 0, 0]])


def folded_leg(progress, leg, height):
    hind = leg >= 2
    keys = HIND if hind else FORE
    # The opposite leg trails by a little in flight, joining at the endpoints.
    t = progress - (0.033 if leg % 2 else 0) * np.sin(np.pi * progress)**2
    angles = np.deg2rad([np.interp(t, TIMES, column) for column in keys.T])
    rest = np.array([(0, 55), (14, 31), (-8, 13), (-3, 0)] if hind else
                    [(0, 55), (-11, 31), (0, 10), (3, 0)]) * height / 55
    segments = np.diff(rest, axis=0)
    c, s = np.cos(angles), np.sin(angles)
    rotated = np.column_stack((segments[:, 0]*c - segments[:, 1]*s,
                               segments[:, 0]*s + segments[:, 1]*c))
    # Rotate whole bones to preserve length through take-off and landing.
    delta = np.vstack((np.zeros(2), np.cumsum(rotated - segments, axis=0)))
    if not hind:
        delta[:, 0] += 0.09 * delta[-1, 0]
    return delta


def pitch(image, feet, view, progress):
    # Rotate about the chest in the image plane. Pitch is fully visible in
    # profile and disappears head-on. Keep the ground origin for registration.
    angle = np.interp(progress, TIMES, [0, 5, 6, 0, -6, -3, 0]) * np.cos(view.angle)
    pivot = (view.pivot - view.box[:2]) * view.zoom / view.pixel_scale
    if abs(angle) < 0.001:
        return image, feet, pivot
    pad = int(np.ceil(max(image.size) * 0.12))
    canvas = Image.new("RGBA", (image.width + 2*pad, image.height + 2*pad))
    canvas.paste(image, (pad, pad))
    pivot = pivot + pad
    center = np.array([0, -48])
    # PIL's native premultiplied resampler keeps translucent fur edges clean.
    canvas = canvas.rotate(angle, resample=Image.Resampling.BICUBIC,
                           center=tuple(pivot + center / view.pixel_scale))
    a = np.deg2rad(angle)
    matrix = np.array([[np.cos(a), np.sin(a)], [-np.sin(a), np.cos(a)]])
    feet = (np.array(feet) - center) @ matrix.T + center
    return canvas, feet, pivot


def bake(destination):
    pivot = json.loads((MOTION / "Atlas.json").read_text())["pivot"]
    photo = Image.open(MOTION / "Pivot.png").convert("RGBA")
    rows, manifest = [], {}
    y = 0
    for i in range(9):
        view = View(i, photo, pivot)
        frames, toes, images = [], [], []
        x, row_height = 0, 0
        for k in range(SAMPLES):
            progress = k / (SAMPLES - 1)
            image, feet = view.render(phase=0, strength=0,
                jump_motion=lambda leg, height: folded_leg(progress, leg, height))
            image, feet, pivot_pixel = pitch(image, feet, view, progress)
            box = image.getchannel("A").getbbox()
            sprite = image.crop(box)
            left, top = x + 2, y + 2
            origin = np.round(pivot_pixel + [left - box[0], top - box[1]], 3)
            frames.append([left, top, left + sprite.width, top + sprite.height, *origin.tolist()])
            toes.append(np.round(feet, 3).flatten().tolist())
            images.append((left, sprite))
            x += sprite.width + 4
            row_height = max(row_height, sprite.height + 4)
        rows.append((x, y + 2, images))
        y += row_height
        manifest[f"leap{i}"] = dict(atlas="Leap", scale=view.pixel_scale, frames=frames, toes=toes)
    atlas = Image.new("RGBA", (max(width for width, _, _ in rows), y))
    for _, top, row in rows:
        for left, image in row:
            atlas.paste(image, (left, top))
    atlas.save(destination / "Leap.png", compress_level=7)
    (destination / "Leap.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    bake(Path(sys.argv[1]) if len(sys.argv) > 1 else MOTION)
