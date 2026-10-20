# Animated demonstration: evidence and scope

![Recorded native menu-bar snapshots: normal launch, through QuietBar, normal launch restored](demo.gif)

This **snapshot sequence** uses nine existing native menu-bar images from three separate test runs. It is **not a continuous screencast** and does not depict a user clicking a button. Images are cropped and enlarged with nearest-neighbor scaling; no icon is painted over, erased or recreated. Annotations sit outside the original-pixel regions. GIF palette quantization is the only color encoding conversion.

The visible sequence is ordinary launch **A1** → production QuietBar selected-application launcher **B** → ordinary launch **A2**. Each run contributes its native snapshots at +8, +16 and +24 seconds and the exact corresponding `completeFrames` / `animatedPixelChanges` metrics. The displayed counts reset between runs; no values are interpolated.

**Environment:** macOS 15.7.9 (24G830), arm64 hosted VM, **SIP disabled**, CI-only Screen Recording provisioning. The app is QuietBar's **own direct ScreenCaptureKit fixture**. The large sharing pill is visible / absent / visible. The small purple dot remains, including during B. This does not establish third-party app compatibility, remote input, or ordinary SIP-enabled Mac behavior.

Source: [capture run 39415956457](https://github.com/miha1744/QuietBar/actions/runs/39415956457), `macos-15/direct/`. A1 and A2 use their named subdirectories; B uses `B/capture/`. Every image filename is `sample-{8,16,24}s-native-menubar.png`, paired with `sample-{8,16,24}s.json`. The retained 24-second PNGs match [the public evidence](../evidence/1.3.0/README.md) and [sanitized measurements](../evidence/1.3.0/measurements.json) byte for byte. All nine JSON observations are checked against that public record before rendering.

## Rebuild

Requires Python 3 and Pillow. No downloads or fresh capture occur:

```sh
python3 scripts/make-demo.py --raw-root /path/to/run-39415956457/macos-15/direct
```

The default raw root is the existing sibling `quietbar-application-ci-results/run-39415956457/macos-15/direct`. Scratch frames, a contact sheet and the verification manifest go to the sibling `quietbar-demo/`; `--scratch` can override it. Font lookup uses local Arial or DejaVu Sans only. Rebuilding on another Pillow/font version can change layout/encoding bytes.

## Verification

- GIF: **1120 × 580**, **9 frames**, **10.8 seconds**, continuous loop.
- Encoded size: **290,328 bytes** (under 2 MB).
- GIF SHA-256: `d2b15ab765b1b8897be32e5f6e93d7f82e38148d35f2b972f13d1ef27de9c9ac`.
- Full native context crop: `(0, 0, 1024, 32)`, shown at native size.
- Enlarged native crop: `(704, 0, 1024, 32)`, shown at 3× with nearest-neighbor resampling.
- Durations: `[850, 850, 1900, 850, 850, 1900, 850, 850, 1900]` milliseconds. The +8/+16/+24 labels refer to source-run sampling times, not GIF playback time.
- Exact decoded context/detail pixel regions are compared with the identically quantized source crops for every frame. Source screenshots and JSON remain unchanged.

| Run | Sample | Complete frames | Animated changes | Native PNG SHA-256 | Paired JSON SHA-256 |
| --- | --- | --- | --- | --- | --- |
| A1 | 8 s | 54 | 44 | `6bf2def4e42fb297ef8616d63789d6a02ee66ad2ae7bed5aaed5cc93f1e95452` | `4e1458cebf31ddaaedb45e279f6cbfc35a81094442a39eb673fafb58e1b36c81` |
| A1 | 16 s | 91 | 80 | `6bf2def4e42fb297ef8616d63789d6a02ee66ad2ae7bed5aaed5cc93f1e95452` | `4bb7944665d40ab6e5ee3458ec9f0524a9212fe05f2aed51958d4d3b42b29321` |
| A1 | 24 s | 131 | 120 | `6bf2def4e42fb297ef8616d63789d6a02ee66ad2ae7bed5aaed5cc93f1e95452` | `3e5a645b8ea3cb3118150c65671b619f416a2264f6fdbe0077ea5b312d8a7bec` |
| B | 8 s | 44 | 42 | `ad0d0a435c4b09245407dda7470f5fbdac23788d9b77a1f7f75eaf38aad02f61` | `9afc524707944c037686d45082cadda31c70e64b3a6901b9f12763a09653d560` |
| B | 16 s | 84 | 82 | `ad0d0a435c4b09245407dda7470f5fbdac23788d9b77a1f7f75eaf38aad02f61` | `06fd31c492204f1aae4062ee1ad62b381699254948e154d8297a6cb0ddaf4254` |
| B | 24 s | 124 | 122 | `ad0d0a435c4b09245407dda7470f5fbdac23788d9b77a1f7f75eaf38aad02f61` | `6d20d64ee3317bd2245f33c11508fb9d55b078dfd2e6b04526e84e09d371b3fa` |
| A2 | 8 s | 45 | 42 | `12dcecad23012f59820286bf991c56ba8ebd5471939765281d0a4f93c4a60ac6` | `48f729e7aa5087e7e6c2a7df672e9a487568239b5a60d8908cbac87869640e1a` |
| A2 | 16 s | 85 | 82 | `12dcecad23012f59820286bf991c56ba8ebd5471939765281d0a4f93c4a60ac6` | `78f136aa350f0bb2fc113f1f3488374eeabeca9cb9ae38a0561761d8a6eb16de` |
| A2 | 24 s | 125 | 122 | `12dcecad23012f59820286bf991c56ba8ebd5471939765281d0a4f93c4a60ac6` | `b9a76dfab2a2bff3c7e1297042d7a413968dfaf4ebc4a91a2831a511c5767ea0` |
