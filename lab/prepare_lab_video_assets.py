"""Prepare stills for lateral/overview lab clips from attached highway refs.

Refs (André feedback):
  fixtures/video/ref-lateral.png  — side highway sedan pass
  fixtures/video/ref-overview.png — high panoramic multi-lane
Falls back to ANPR source photos only if refs are missing.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

W, H = 960, 540


def _fit_cover(src: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(src.convert("RGB"), size, method=Image.Resampling.LANCZOS)


def _lateral_still(ref: Path) -> Image.Image:
    """Side highway still — slight sharpen + gantry-cam HUD-friendly grade."""
    img = _fit_cover(Image.open(ref), (W, H))
    img = ImageEnhance.Contrast(img).enhance(1.06)
    img = ImageEnhance.Color(img).enhance(0.95)
    # Soft vignette so drawtext HUD stays readable
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rectangle([0, 0, W, 78], fill=(8, 14, 12, 110))
    draw.rectangle([0, H - 36, W, H], fill=(8, 14, 12, 90))
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def _overview_still(ref: Path) -> Image.Image:
    """High panoramic multi-lane still."""
    img = _fit_cover(Image.open(ref), (W, H))
    img = ImageEnhance.Contrast(img).enhance(1.08)
    img = ImageEnhance.Color(img).enhance(0.92)
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rectangle([0, 0, W, 78], fill=(8, 14, 12, 120))
    draw.rectangle([0, H - 36, W, H], fill=(8, 14, 12, 90))
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def _motion_plate(still: Image.Image, kind: str) -> tuple[Image.Image, Image.Image]:
    """Build a slightly wider plate so ffmpeg can pan across it for ~10 s motion.

    Returns (bg_plate, dummy_transparent) — car overlay is unused with real refs;
    generate-lab-media.ps1 still expects two inputs, so we ship a 1×1 transparent PNG.
    """
    if kind == "lateral":
        # Extra width for L→R pan (car appears to travel through frame)
        plate_w, plate_h = 1280, H
        plate = ImageOps.fit(still, (plate_w, plate_h), method=Image.Resampling.LANCZOS)
    else:
        # Extra height for slow forward drift / zoom feel
        plate_w, plate_h = W, 680
        plate = ImageOps.fit(still, (plate_w, plate_h), method=Image.Resampling.LANCZOS)
        plate = plate.filter(ImageFilter.GaussianBlur(0.2))
    dummy = Image.new("RGBA", (2, 2), (0, 0, 0, 0))
    return plate, dummy


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--lab",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "ops-ui" / "public" / "lab",
    )
    parser.add_argument(
        "--ref-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "fixtures" / "video",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "fixtures" / "anpr" / "source",
        help="Fallback if ref-lateral/overview missing",
    )
    args = parser.parse_args()
    gen = args.lab / "_gen"
    gen.mkdir(parents=True, exist_ok=True)

    lat_ref = args.ref_dir / "ref-lateral.png"
    ov_ref = args.ref_dir / "ref-overview.png"
    if not lat_ref.is_file():
        lat_ref = args.source_dir / "front.png"
    if not ov_ref.is_file():
        ov_ref = args.source_dir / "rear.png"
    if not lat_ref.is_file() or not ov_ref.is_file():
        raise SystemExit(f"Need lateral/overview refs under {args.ref_dir} (or ANPR sources)")

    lat_still = _lateral_still(lat_ref)
    ov_still = _overview_still(ov_ref)
    lat_plate, lat_dummy = _motion_plate(lat_still, "lateral")
    ov_plate, ov_dummy = _motion_plate(ov_still, "overview")

    lat_plate.save(gen / "lateral-bg.png")
    lat_dummy.save(gen / "lateral-car.png")
    ov_plate.save(gen / "overview-bg.png")
    ov_dummy.save(gen / "overview-car.png")
    # Also keep framed 960×540 stills for smoke / docs
    lat_still.save(gen / "lateral-frame.png")
    ov_still.save(gen / "overview-frame.png")
    print(f"wrote assets under {gen} (refs: {lat_ref.name}, {ov_ref.name})")


if __name__ == "__main__":
    main()
