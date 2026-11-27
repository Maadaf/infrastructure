"""Build lab ANPR crops from real Mercosul front/rear photos (+ HUD / OCR)."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PLATE = "ABC1D23"
W, H = 960, 540
SOURCE_DIR = Path(__file__).resolve().parent / "fixtures" / "anpr" / "source"


def _font(size: int) -> ImageFont.ImageFont:
    for name in (
        r"C:\Windows\Fonts\consola.ttf",
        r"C:\Windows\Fonts\courbd.ttf",
        r"C:\Windows\Fonts\arialbd.ttf",
        r"C:\Windows\Fonts\arial.ttf",
    ):
        if Path(name).exists():
            return ImageFont.truetype(name, size)
    return ImageFont.load_default()


def _fit_cover(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    tw, th = size
    scale = max(tw / img.width, th / img.height)
    nw, nh = max(1, int(img.width * scale)), max(1, int(img.height * scale))
    resized = img.resize((nw, nh), Image.Resampling.LANCZOS)
    left = (nw - tw) // 2
    top = (nh - th) // 2
    return resized.crop((left, top, left + tw, top + th))


def _hud(base: Image.Image, kind: str) -> Image.Image:
    img = base.convert("RGB")
    draw = ImageDraw.Draw(img)
    if kind == "front":
        cam_label = "CAM-F · ANPR FRENTE"
        role_tag = "FRONT CROP"
        # Front plate @ 90 km/h; rear = front + length_m/v (4.3 m → Δt 172 ms)
        stamp = "2026-01-01 12:00:00.070Z  ·  A1-KM10-N / L1"
    else:
        cam_label = "CAM-R · ANPR TRÁS"
        role_tag = "REAR CROP"
        stamp = "2026-01-01 12:00:00.242Z  ·  A1-KM10-N / L1"

    # Top HUD only — keep plate characters unobstructed (OCR chip lives in UI below).
    draw.rectangle([0, 0, img.width, 58], fill=(8, 16, 12))
    draw.text((12, 8), cam_label, fill=(160, 220, 170), font=_font(22))
    draw.text((12, 34), stamp, fill=(150, 200, 170), font=_font(16))
    conf_lbl = f"{role_tag} · conf 0.98"
    conf_font = _font(14)
    conf_bbox = draw.textbbox((0, 0), conf_lbl, font=conf_font)
    conf_w = conf_bbox[2] - conf_bbox[0]
    draw.text(
        (img.width - 12 - conf_w, 18),
        conf_lbl,
        fill=(130, 180, 150),
        font=conf_font,
    )
    # Small corner ticks around plate ROI (do not cover glyphs)
    cx = img.width // 2
    cy = int(img.height * (0.86 if kind == "front" else 0.80))
    half_w, half_h = (112, 28) if kind == "front" else (104, 30)
    tick = 5
    corners = [
        (cx - half_w, cy - half_h),
        (cx + half_w, cy - half_h),
        (cx - half_w, cy + half_h),
        (cx + half_w, cy + half_h),
    ]
    for x, y in corners:
        sx = 1 if x < cx else -1
        sy = 1 if y < cy else -1
        draw.line([(x, y), (x + sx * tick, y)], fill=(90, 200, 120), width=1)
        draw.line([(x, y), (x, y + sy * tick)], fill=(90, 200, 120), width=1)
    return img


def make_anpr(kind: str, path: Path, source: Path) -> None:
    raw = Image.open(source).convert("RGB")
    framed = _fit_cover(raw, (W, H))
    out = _hud(framed, kind)
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, "JPEG", quality=90, optimize=True)
    data = path.read_bytes()
    print(f"{path.name}: {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()} ← {source.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "ops-ui" / "public" / "lab",
    )
    parser.add_argument("--source-dir", type=Path, default=SOURCE_DIR)
    args = parser.parse_args()

    front_src = args.source_dir / "front.png"
    rear_src = args.source_dir / "rear.png"
    if not front_src.is_file() or not rear_src.is_file():
        raise SystemExit(
            f"Missing real ANPR sources under {args.source_dir} "
            "(need front.png + rear.png with Mercosul plate)."
        )

    make_anpr("front", args.out / "anpr-front.jpg", front_src)
    make_anpr("rear", args.out / "anpr-rear.jpg", rear_src)


if __name__ == "__main__":
    main()
