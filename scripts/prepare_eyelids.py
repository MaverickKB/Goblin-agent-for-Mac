#!/usr/bin/env python3
"""Register shaded eyelid renders onto the unchanged standing figure."""

import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image


def prepare(root, renders):
    catalog = json.loads((root / "Resources/character-rigs.json").read_text())
    destination = root / "Resources/Eyelids"
    destination.mkdir(parents=True, exist_ok=True)
    for name, rig in catalog["avatars"].items():
        original = Image.open(root / "Resources/Standing" / (name + ".png")).convert("RGBA")
        rendered = np.array(Image.open(renders / (name + ".png")).convert("RGBA"))
        chroma = np.minimum(rendered[:, :, 0].astype(int), rendered[:, :, 2].astype(int)) - rendered[:, :, 1].astype(int)
        rendered[chroma > 65, 3] = 0
        keyed = Image.fromarray(rendered)
        bounds = keyed.getbbox()
        target = original.getbbox()
        if bounds is None or target is None:
            raise ValueError("Empty eyelid image: " + name)
        resized = keyed.crop(bounds).resize((target[2] - target[0], target[3] - target[1]), Image.Resampling.LANCZOS)
        aligned = Image.new("RGBA", original.size)
        aligned.alpha_composite(resized, (target[0], target[1]))
        rest = np.array(original)
        closed = np.array(aligned)
        height, width = rest.shape[:2]
        mask = np.zeros((height, width), dtype=np.uint8)
        mask[:int(height * 0.34), :] = 255
        mask[rest[:, :, 3] < 200] = 0
        for x, y, rx, ry in rig["eyes"]:
            cv2.ellipse(mask, (round(x * width), round(y * height)), (round(rx * width * 1.7), round(ry * height * 1.7)), 0, 0, 360, 0, -1)
        template = cv2.cvtColor(rest[:, :, :3], cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
        moving = cv2.cvtColor(closed[:, :, :3], cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
        warp = np.eye(2, 3, dtype=np.float32)
        try:
            score, warp = cv2.findTransformECC(template, moving, warp, cv2.MOTION_AFFINE,
                                              (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 250, 1e-5), mask, 5)
        except cv2.error as error:
            raise ValueError("Eyelid registration failed: " + name) from error
        registered = cv2.warpAffine(closed, warp, (width, height), flags=cv2.INTER_CUBIC | cv2.WARP_INVERSE_MAP)
        # Retain only the socket surfaces. Costumes and the rest of the face
        # always come from the approved standing image.
        socket = np.zeros((height, width), dtype=np.float32)
        for x, y, rx, ry in rig["eyes"]:
            cv2.ellipse(socket, (round(x * width), round(y * height)), (round(rx * width * 1.35), round(ry * height * 1.35)), 0, 0, 360, 1, -1)
        socket = cv2.GaussianBlur(socket, (3, 3), 0.65)
        result = rest.copy()
        blend = socket[:, :, np.newaxis]
        result[:, :, :3] = np.clip(rest[:, :, :3] * (1 - blend) + registered[:, :, :3] * blend, 0, 255).astype(np.uint8)
        Image.fromarray(result).save(destination / (name + ".png"))
        print(name, "registration", round(score, 3), "transform", warp.round(3).tolist())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("renders", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    prepare(arguments.root, arguments.renders)
