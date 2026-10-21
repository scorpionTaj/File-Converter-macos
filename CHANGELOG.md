# Changelog

All notable changes to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-21

### Added
- **Annotate…** for images: pen, arrow, rectangle, ellipse, highlighter, text, pixelate (permanent) and
  crop, with undo/redo and keys 1–8 to switch tools. Saves `name (annotated).ext`.
- **File-promise drags** from Photos, Mail and Safari. The wheel is built from the promised file types;
  results go to Downloads.
- Drop files on the **menu-bar icon**, use Finder ▸ Services ▸ **Open in Kumquat**, or **Open With ▸ Kumquat**.
- Tools: **Trim…** (frame-accurate, audio and video), **Resize…** (`50%`, `1280`, `1280x720`, `x720`),
  **Make GIF** from several images, **Remove Pages…** and **Keep Pages…** (`1, 3-5, 8-`).
- Batch conversions run three files at a time with combined progress.
- Escape closes the click-mode wheel.
- Release pipeline: tagged releases (universal `.dmg`, `.zip`, CLI tarball, SHA-256 checksums) and a
  nightly pre-release from `main`. Test summaries and code coverage on every CI run.

### Fixed
- OGG and WebP conversions failed with "Encoder not found" on Homebrew's FFmpeg, which ships without
  libvorbis and libwebp. Kumquat now detects the encoders your FFmpeg has and falls back: OGG → Opus
  in Ogg, WebP → `cwebp`, AVIF → SVT-AV1 or `avifenc`, H.264 → VideoToolbox, WebM → AV1.
- Holding ⌘ in Finder (which restricts a drag to "move") made drops on the wheel bounce back.
- Extracting an archive that holds a single file named it `report.pdf.pdf`.
- A batch tool that failed on one file lost every other file's result.
- Zipping or tarring files from different folders (Recents, search results) failed.
- A quick notice (e.g. "Path copied") hid a running conversion's progress and result.
- An older job finishing replaced a newer job's progress in the HUD.
- The click-mode wheel didn't highlight segments under the pointer.

## [0.1.0] - 2026-10-21

### Added
- Menu bar app with three radial wheels summoned mid-drag: ⇧ Convert, ⌘ Tools, ⌃ Actions (remappable).
- 646 conversions across images, audio, video, PDF, documents, slides, spreadsheets, subtitles, archives
  and data, routed through a conversion graph with multi-step routes and stream-copy remuxing.
- 36 tools (compress, resize, rotate, remove background, OCR, merge/split/encrypt/redact PDFs, mute,
  normalize…) and 7 actions (AirDrop, Float, Copy, Move to…, Copy to…, Copy Path, Terminal).
- `kumquat-cli`, settings, welcome window, CI on Linux and macOS, `.app`/`.dmg` packaging.

[Unreleased]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/scorpionTaj/File-Converter-macos/releases/tag/v0.1.0
