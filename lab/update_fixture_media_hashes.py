"""Sync evidence_package.json media sha256/size_bytes + OCR plate from ops-ui/public/lab."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "ops-ui" / "public" / "lab"
FIXTURE = ROOT / "freeflow-contracts" / "fixtures" / "v1" / "passages" / "evidence_package.json"
PLATE = "ABC1D23"


def main() -> None:
    wanted = {
        "anpr-front.jpg",
        "anpr-rear.jpg",
        "video-lateral.mp4",
        "video-overview.mp4",
    }
    rows: dict[str, dict[str, int | str]] = {}
    for name in sorted(wanted):
        p = LAB / name
        if not p.is_file():
            raise SystemExit(f"missing lab media: {p}")
        data = p.read_bytes()
        rows[name] = {
            "size_bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        print(f"{name}\t{len(data)}\t{rows[name]['sha256']}")

    pkg = json.loads(FIXTURE.read_text(encoding="utf-8"))
    media = pkg.setdefault("media", {})

    def apply(item: dict, name: str, role: str, media_type: str) -> None:
        meta = rows[name]
        item["uri"] = f"sim://lab/{name}"
        item["media_type"] = media_type
        item["sha256"] = meta["sha256"]
        item["size_bytes"] = meta["size_bytes"]
        item["role"] = role

    anpr = media.setdefault("anpr", [{}, {}])
    while len(anpr) < 2:
        anpr.append({})
    apply(anpr[0], "anpr-front.jpg", "anpr_front", "image/jpeg")
    apply(anpr[1], "anpr-rear.jpg", "anpr_rear", "image/jpeg")
    anpr[0].setdefault("evidence_id", "33333333-3333-4333-8333-333333333333")
    anpr[1].setdefault("evidence_id", "44444444-4444-4444-8444-444444444444")
    # Front→rear Δt = length_m / v = 4.3 m @ 90 km/h → 172 ms (not 20 ms / ~200+ km/h)
    anpr[0]["captured_at"] = "2026-01-01T12:00:00.070Z"
    anpr[1]["captured_at"] = "2026-01-01T12:00:00.242Z"
    anpr[0]["ocr_text"] = PLATE
    anpr[1]["ocr_text"] = PLATE

    lateral = media.setdefault("video_lateral", {})
    overview = media.setdefault("video_overview", {})
    apply(lateral, "video-lateral.mp4", "video_lateral", "video/mp4")
    apply(overview, "video-overview.mp4", "video_overview", "video/mp4")
    lateral.setdefault("evidence_id", "66666666-6666-4666-8666-666666666666")
    overview.setdefault("evidence_id", "77777777-7777-4777-8777-777777777777")
    lateral.setdefault("captured_at", "2026-01-01T12:00:00.000Z")
    overview.setdefault("captured_at", "2026-01-01T12:00:00.000Z")

    for ev in pkg.get("events", []):
        data = ev.get("data")
        if isinstance(data, dict) and "plate" in data:
            data["plate"] = PLATE

    passage = pkg.setdefault("passage", {})
    if isinstance(passage, dict):
        passage["plate"] = PLATE

    stubs = pkg.setdefault("stubs", {})
    stubs["videos_pending"] = False
    stubs["notes"] = (
        f"Lab path: Mercosul ANPR ({PLATE}) + lateral/overview 10s MP4 from highway refs "
        "(ref-lateral/overview) under ops-ui /lab; radar/lidar/WIM events for twin"
    )

    FIXTURE.write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"updated {FIXTURE} plate={PLATE}")


if __name__ == "__main__":
    main()
