#!/usr/bin/env python3
"""Compose a labeled GIF from existing real A1/B/A2 capture-test snapshots.

Requires Pillow. Reads evidence only: never captures the screen, launches the
product, downloads media, changes permissions, or edits source screenshots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


RUN_ID = "39415956457"
RUN_URL = f"https://github.com/miha1744/QuietBar/actions/runs/{RUN_ID}"
PHASES = (("A1", "A1", "Normal launch"),
          ("B", "B/capture", "Through QuietBar"),
          ("A2", "A2", "Normal launch restored"))
SECONDS = (8, 16, 24)
DURATIONS = (850, 850, 1900) * 3
SIZE = (1120, 580)
DETAIL_BOX = (704, 0, 1024, 32)
DETAIL_POSITION = (80, 270)
CONTEXT_POSITION = (48, 182)
COLORS = {"bg": "#101321", "panel": "#191D30", "border": "#30364D",
          "text": "#F6F5FF", "muted": "#ABAEC6", "accent": "#AB9AFF",
          "success": "#9AE6C3"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    names = (["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "DejaVuSans-Bold.ttf"]
             if bold else ["/System/Library/Fonts/Supplemental/Arial.ttf", "DejaVuSans.ttf"])
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    raise RuntimeError("Install a readable Arial or DejaVu Sans font; no font is downloaded.")


def text(draw: ImageDraw.ImageDraw, xy: tuple[int, int], value: str,
         size: int, fill: str = "text", bold: bool = False) -> None:
    draw.text(xy, value, font=font(size, bold), fill=COLORS.get(fill, fill), anchor="lt")


def load_samples(repo: Path, raw: Path) -> list[dict]:
    public_path = repo / "docs/evidence/1.3.0/measurements.json"
    public = json.loads(public_path.read_text())
    assert public["runURL"] == RUN_URL
    lane = next(item for item in public["lanes"] if item["label"] == "macos-15")
    assert "15.7.9" in lane["environment"]["os"]
    assert "24G830" in lane["environment"]["os"]
    assert lane["environment"]["architecture"] == "arm64"
    assert lane["environment"]["sip"] == "System Integrity Protection status: disabled."
    fixture = lane["fixtures"]["direct"]
    assert fixture["productProcessLinkAndProtocolVerified"] is True
    assert fixture["observedSharingPillPattern"] == "visible / absent / visible"
    samples = []
    for phase, folder, title in PHASES:
        previous_frames = previous_changes = -1
        for index, second in enumerate(SECONDS):
            image_path = raw / folder / f"sample-{second}s-native-menubar.png"
            metric_path = raw / folder / f"sample-{second}s.json"
            metrics = json.loads(metric_path.read_text())
            sanitized = fixture["phases"][phase]["samples8_16_24seconds"][index]
            for key, value in sanitized.items():
                assert metrics[key] == value, f"Metrics mismatch: {phase}/{second}s/{key}"
            assert metrics["scheduledSecond"] == second
            assert metrics["nativeImageSaved"] is True and metrics["streamError"] is None
            assert metrics["completeFrames"] > previous_frames
            assert metrics["animatedPixelChanges"] > previous_changes
            assert metrics["strictVisibleTargets"] == (0 if phase == "B" else 1)
            assert metrics["regionPurplePixels"] == (0 if phase == "B" else 877)
            # The retained purple pixels outside the pill correspond to the
            # visible native dot. The GIF does not claim every indicator vanishes.
            assert metrics["wholeNativePurplePixels"] == (24 if phase == "B" else 901)
            with Image.open(image_path) as source:
                assert source.format == "PNG" and source.size == (1024, 80)
                assert source.width == metrics["nativeImageWidth"]
                assert source.height == metrics["nativeImageHeight"]
                pixels = source.convert("RGB")
            if second == 24:
                retained = repo / "docs/evidence/1.3.0" / fixture["phases"][phase]["representativeNativeImage"]
                assert sha256(image_path) == sha256(retained) == fixture["phases"][phase]["imageSHA256"]
            samples.append({"phase": phase, "title": title, "second": second,
                "image": pixels, "metrics": metrics,
                "sourcePNG": f"{folder}/{image_path.name}", "sourceJSON": f"{folder}/{metric_path.name}",
                "sourcePNG_SHA256": sha256(image_path), "sourceJSON_SHA256": sha256(metric_path)})
            previous_frames = metrics["completeFrames"]
            previous_changes = metrics["animatedPixelChanges"]
    return samples


def compose(sample: dict) -> Image.Image:
    image = Image.new("RGB", SIZE, COLORS["bg"])
    draw = ImageDraw.Draw(image)
    text(draw, (48, 30), "QuietBar", 27, bold=True)
    draw.rounded_rectangle((930, 28, 1072, 59), radius=15, fill="#28223D")
    text(draw, (947, 36), "EXPERIMENTAL", 13, "accent", True)
    text(draw, (48, 85), sample["title"], 39, bold=True)
    text(draw, (48, 139), "Recorded test snapshots · macOS 15.7.9 · SIP off", 19, "muted")
    # Copy only real source pixels. All annotations remain outside both crops.
    context = sample["image"].crop((0, 0, 1024, 32))
    image.paste(context, CONTEXT_POSITION)
    text(draw, (48, 231), "RIGHT MENU BAR · 3× DETAIL", 13, "muted", True)
    detail = sample["image"].crop(DETAIL_BOX).resize((960, 96), Image.Resampling.NEAREST)
    image.paste(detail, DETAIL_POSITION)
    draw.rounded_rectangle((48, 390, 1072, 480), radius=16,
                           fill=COLORS["panel"], outline=COLORS["border"])
    metrics = sample["metrics"]
    text(draw, (72, 407), f"{metrics['completeFrames']:03d}", 29, "success", True)
    text(draw, (148, 412), "complete capture frames", 17, "muted")
    text(draw, (72, 446), f"{metrics['animatedPixelChanges']} animated-frame changes", 16, "muted")
    label = "Sharing pill absent" if sample["phase"] == "B" else "Sharing pill visible"
    text(draw, (539, 409), label, 21, "accent" if sample["phase"] != "B" else "success", True)
    text(draw, (539, 446), "Small purple dot remains", 16, "muted")
    # The +8/+16/+24 counters are sampled values, never invented interpolation.
    stamp = f"{sample['phase']} · snapshot +{sample['second']:02d} s"
    text(draw, (829, 239), stamp, 14, "accent")
    text(draw, (48, 510), "Own ScreenCaptureKit fixture · Three separate test runs", 17, "muted")
    text(draw, (48, 540), "Snapshot sequence, not a continuous screen recording. Third-party apps / SIP-on unverified.", 16, "muted")
    return image


def write_notes(repo: Path, samples: list[dict], report: dict) -> None:
    rows = []
    for sample in samples:
        metric = sample["metrics"]
        rows.append(f"| {sample['phase']} | {sample['second']} s | {metric['completeFrames']} | "
                    f"{metric['animatedPixelChanges']} | `{sample['sourcePNG_SHA256']}` | `{sample['sourceJSON_SHA256']}` |")
    body = f"""# Animated demonstration: evidence and scope

![Recorded native menu-bar snapshots: normal launch, through QuietBar, normal launch restored](demo.gif)

This **snapshot sequence** uses nine existing native menu-bar images from three separate test runs. It is **not a continuous screencast** and does not depict a user clicking a button. Images are cropped and enlarged with nearest-neighbor scaling; no icon is painted over, erased or recreated. Annotations sit outside the original-pixel regions. GIF palette quantization is the only color encoding conversion.

The visible sequence is ordinary launch **A1** → production QuietBar selected-application launcher **B** → ordinary launch **A2**. Each run contributes its native snapshots at +8, +16 and +24 seconds and the exact corresponding `completeFrames` / `animatedPixelChanges` metrics. The displayed counts reset between runs; no values are interpolated.

**Environment:** macOS 15.7.9 (24G830), arm64 hosted VM, **SIP disabled**, CI-only Screen Recording provisioning. The app is QuietBar's **own direct ScreenCaptureKit fixture**. The large sharing pill is visible / absent / visible. The small purple dot remains, including during B. This does not establish third-party app compatibility, remote input, or ordinary SIP-enabled Mac behavior.

Source: [capture run {RUN_ID}]({RUN_URL}), `macos-15/direct/`. A1 and A2 use their named subdirectories; B uses `B/capture/`. Every image filename is `sample-{{8,16,24}}s-native-menubar.png`, paired with `sample-{{8,16,24}}s.json`. The retained 24-second PNGs match [the public evidence](../evidence/1.3.0/README.md) and [sanitized measurements](../evidence/1.3.0/measurements.json) byte for byte. All nine JSON observations are checked against that public record before rendering.

## Rebuild

Requires Python 3 and Pillow. No downloads or fresh capture occur:

```sh
python3 scripts/make-demo.py --raw-root /path/to/run-{RUN_ID}/macos-15/direct
```

The default raw root is the existing sibling `quietbar-application-ci-results/run-{RUN_ID}/macos-15/direct`. Scratch frames, a contact sheet and the verification manifest go to the sibling `quietbar-demo/`; `--scratch` can override it. Font lookup uses local Arial or DejaVu Sans only. Rebuilding on another Pillow/font version can change layout/encoding bytes.

## Verification

- GIF: **{report['size'][0]} × {report['size'][1]}**, **{report['frames']} frames**, **{report['durationMilliseconds']/1000:.1f} seconds**, continuous loop.
- Encoded size: **{report['bytes']:,} bytes** (under 2 MB).
- GIF SHA-256: `{report['gifSHA256']}`.
- Full native context crop: `(0, 0, 1024, 32)`, shown at native size.
- Enlarged native crop: `{DETAIL_BOX}`, shown at 3× with nearest-neighbor resampling.
- Durations: `{list(DURATIONS)}` milliseconds. The +8/+16/+24 labels refer to source-run sampling times, not GIF playback time.
- Exact decoded context/detail pixel regions are compared with the identically quantized source crops for every frame. Source screenshots and JSON remain unchanged.

| Run | Sample | Complete frames | Animated changes | Native PNG SHA-256 | Paired JSON SHA-256 |
| --- | --- | --- | --- | --- | --- |
{chr(10).join(rows)}
"""
    (repo / "docs/assets/demo.md").write_text(body)


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-root", type=Path, default=repo.parent / f"quietbar-application-ci-results/run-{RUN_ID}/macos-15/direct")
    parser.add_argument("--scratch", type=Path, default=repo.parent / "quietbar-demo")
    args = parser.parse_args()
    samples = load_samples(repo, args.raw_root.resolve())
    args.scratch.mkdir(parents=True, exist_ok=True)
    frames = [compose(sample) for sample in samples]
    # One shared palette keeps native pixel colors stable across frames. No
    # crossfades, invented cursor movement or intermediate screen states.
    atlas = Image.new("RGB", (SIZE[0], SIZE[1] * len(frames)))
    for index, frame in enumerate(frames):
        atlas.paste(frame, (0, index * SIZE[1]))
    palette = atlas.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    quantized = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    output = repo / "docs/assets/demo.gif"
    quantized[0].save(output, save_all=True, append_images=quantized[1:],
                      duration=list(DURATIONS), loop=0, optimize=False, disposal=2)
    duration = 0
    with Image.open(output) as gif:
        assert gif.n_frames == 9 and gif.size == SIZE and gif.info["loop"] == 0
        for index, sample in enumerate(samples):
            gif.seek(index)
            assert gif.info["duration"] == DURATIONS[index]
            duration += gif.info["duration"]
            decoded = gif.convert("RGB")
            native_regions = (
                (*CONTEXT_POSITION, sample["image"].crop((0, 0, 1024, 32))),
                (*DETAIL_POSITION, sample["image"].crop(DETAIL_BOX).resize((960, 96), Image.Resampling.NEAREST)),
            )
            for x, y, native in native_regions:
                width, height = native.size
                box = (x, y, x + width, y + height)
                # Independently reconstruct each expected native crop rather
                # than comparing the encoder with the composed frame itself.
                assert frames[index].crop(box).tobytes() == native.tobytes()
                expected = native.quantize(palette=palette, dither=Image.Dither.NONE).convert("RGB")
                assert decoded.crop(box).tobytes() == expected.tobytes()
            assert sha256(args.raw_root / sample["sourcePNG"]) == sample["sourcePNG_SHA256"]
            assert sha256(args.raw_root / sample["sourceJSON"]) == sample["sourceJSON_SHA256"]
            decoded.save(args.scratch / f"frame-{index:02d}-{sample['phase']}-{sample['second']}s.png")
    assert duration == 10800 and output.stat().st_size <= 2_000_000
    thumb_size = (560, 290)
    contact = Image.new("RGB", (thumb_size[0] * 3, thumb_size[1] * 3), COLORS["bg"])
    for index, frame in enumerate(frames):
        contact.paste(ImageOps.contain(frame, thumb_size), ((index % 3) * thumb_size[0], (index // 3) * thumb_size[1]))
    contact.save(args.scratch / "contact-sheet.png")
    report = {"size": list(SIZE), "frames": len(frames), "durationMilliseconds": duration,
        "durations": list(DURATIONS), "bytes": output.stat().st_size, "gifSHA256": sha256(output),
        "runURL": RUN_URL, "scope": "Own direct fixture; macOS 15.7.9 arm64; SIP off; separate test snapshots",
        "inputs": [{key: value for key, value in sample.items() if key != "image"} for sample in samples]}
    (args.scratch / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    write_notes(repo, samples, report)
    print(json.dumps({key: value for key, value in report.items() if key != "inputs"}, indent=2))


if __name__ == "__main__":
    main()
