#!/usr/bin/env python3
"""Extract the reviewed sprite atlas into transparent full-body avatars."""

import argparse
import json
from pathlib import Path

from PIL import Image


AVATARS = [
    ("rookie", "Rookie"),
    ("guard", "Guard"),
    ("lookout", "Lookout"),
    ("nerd", "Nerd"),
    ("scout", "Scout"),
    ("scribe", "Scribe"),
    ("tinkerer", "Tinkerer"),
    ("veteran", "Veteran"),
]


def prepare(source, root):
    atlas = Image.open(source).convert("RGBA")
    columns = 4
    rows = 2
    output = root / "Resources" / "Standing"
    output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for index, (identifier, name) in enumerate(AVATARS):
        column = index % columns
        row = index // columns
        left = round(column * atlas.width / columns)
        top = round(row * atlas.height / rows)
        right = round((column + 1) * atlas.width / columns)
        bottom = round((row + 1) * atlas.height / rows)
        sprite = atlas.crop((left, top, right, bottom))
        pixels = sprite.load()
        for y in range(sprite.height):
            for x in range(sprite.width):
                red, green, blue, alpha = pixels[x, y]
                magenta = min(red, blue) - green
                if magenta > 65:
                    pixels[x, y] = (0, 0, 0, 0)
        bounds = sprite.getbbox()
        if bounds is None:
            raise ValueError("The avatar cell is empty: " + identifier)
        sprite = sprite.crop(bounds)
        padded = Image.new("RGBA", (sprite.width + 16, sprite.height + 16))
        padded.alpha_composite(sprite, (8, 8))
        target = output / (identifier + ".png")
        padded.save(target)
        manifest.append({
            "id": identifier,
            "name": name,
            "file": "Avatars/" + identifier + ".png",
            "standing_file": "Standing/" + identifier + ".png",
        })
        print(identifier, padded.size, "transparent full-body PNG")
    target = root / "Resources" / "avatars.json"
    target.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Prepared", len(manifest), "selectable avatars")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("atlas", type=Path)
    arguments = parser.parse_args()
    prepare(arguments.atlas, Path(__file__).resolve().parents[1])
