# RenderFilm Batch

[繁體中文](README.md) | **English**

A macOS app that exports a whole folder of photos with one set of color settings. Drop in RAW files, apply a film look, even out exposure, and export the batch.

> **Disclaimer**: RenderFilm Batch is an unofficial personal project. It is not affiliated with or endorsed by Kodak, Fujifilm, or any camera or film manufacturer. Film styles are approximate interpretations made for learning and reference; brand names are trademarks of their respective owners.

## Highlights

- **Set once, apply to all**: one set of settings covers the whole folder, including mixed RAW, JPEG, and HEIC.
- **Consistent brightness across a set**: per-photo auto EV with separate metering for faces, subject, and sky. Pick one photo as the brightness reference and match the rest to it.
- **Film look**: Natural, Chrome, and Negative color bases, plus 6 film styles and grain.
- **Fully on-device**: rendered on the GPU with Metal; photos are never uploaded.
- **Full-quality output**: HEIC, JPEG, PNG, TIFF, optional HDR (Rec.2020 PQ/HLG), and 2× Real-ESRGAN upscaling.

## Features

### Color
- Color bases: Natural, Chrome, Negative.
- Film styles: MonoS, MonoH, Cinema, Classic Cinema, Mainichi, Gold.
- Grain with adjustable strength.
- White balance: Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom.
- RGB curves with separate R/G/B channels; per-photo curves are saved next to the original as `<photo>.rfcurve.xml`.

### Exposure
- Per-photo auto EV and scene-aware metering (faces, subject, and sky measured separately).
- Unify EV for Similar Photos.
- **Set as Brightness Reference**, then **Match Selected** or **Match All** to even out similar photos; the last match can be undone.
- Per-photo exposure compensation of ±3 EV.

### Portrait and corrections
- Skin tone adjustment and skin smoothing, each with levels.
- Automatic horizon straightening.
- RAW noise reduction.

### Export
- Formats: HEIC, JPEG, PNG, TIFF, with adjustable quality.
- HDR output: Rec.2020 PQ or HLG.
- Size: original, long edge in pixels, or percentage; long edge up to 32768 px.
- ML super resolution (Real-ESRGAN 2×, not available for HDR).
- Set how many photos process at once, skip existing outputs, and cancel at any time.

### Workflow
- Switch previews from the filmstrip; ⌘-click to add, ⇧-click to select a range.
- Interface in Traditional Chinese and English.

## Download

Download `RenderFilmBatch-<version>.zip` from [Releases](../../releases), unzip, move it to Applications, and double-click to open.

Requires macOS 14 or later on Apple Silicon.

## How to use

1. Choose a folder under **Input Photos**.
2. Choose where to save under **Output Folder**.
3. Adjust the color base, film style, grain, white balance, curves, and exposure on the right.
4. Check each preview from the filmstrip.
5. Click **Start Batch**.

## Build from source

Requires Xcode with the Metal Toolchain. If shader compilation fails, run `xcodebuild -downloadComponent MetalToolchain` first.

```bash
./Scripts/make-batch-app.sh      # builds build/RenderFilmBatch.app
open build/RenderFilmBatch.app
```

## License

Code is MIT ([`LICENSE`](LICENSE)). The bundled Lensfun data (CC BY-SA 3.0) and ML models keep their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
