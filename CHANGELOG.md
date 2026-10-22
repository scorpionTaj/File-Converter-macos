# Changelog

All notable changes to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.1] - 2026-10-22

### Added
- The **Release** workflow now has options: version bump (patch / minor / major / custom), pre-release,
  draft, universal or Apple-silicon-only build, and extra release notes.
- `scripts/prepare-release.sh` updates `VERSION` and `CHANGELOG.md` for a release. It moves the
  "Unreleased" notes under the new version, or writes them from commit messages, and fixes the compare links.
- `scripts/release.sh` accepts `patch` / `minor` / `major` and shows the notes before tagging.

### Fixed
- Running the Release workflow with a new version failed with "doesn't match the VERSION file" unless
  `VERSION` and `CHANGELOG.md` were edited first. The workflow now prepares and commits them itself.

### Changed
- Kumquat is now **macOS-only**. Linux build support and the Linux CI job are gone, along with every
  platform `#if`. All tests run on macOS with the real helpers installed.
- SHA-256 uses CryptoKit and streams the file, instead of running `shasum`.
- ZIP extraction always uses `ditto`; the Linux `unzip` fallback is removed.
- CI retries stalled package installs and puts a time limit on every job.

## [0.3.0] - 2026-10-21

### Added
- **Themes**: Kumquat (follows light/dark), Catppuccin Latte, Frappé, Macchiato and Mocha, Dracula,
  Monokai, Nord, Gruvbox, Tokyo Night, One Dark, Rosé Pine, Solarized Light and Dark. They apply to the
  wheels, the progress popup and the annotation editor. Pick one in Settings ▸ Appearance with live previews.
- **Styled installer**: the disk image opens a designed window (background, arrow, big icons) with
  an Applications shortcut, built with dmgbuild.
- **Move to Applications**: when launched from the disk image or Downloads, Kumquat offers to install
  itself, relaunches from Applications and ejects the image.
- **Engines tab**: shows each helper's version and location, has one-click **Install** (Homebrew in
  Terminal, or the App Store for Pages/Keynote/Numbers), a **Choose…** button for custom paths, and
  flags custom paths that don't point at an executable.
- **Cancel** running conversions and tools from the progress popup.
- Recent results persist across launches; **Clear Recent** and **Show Log** in the menu.
- Errors are logged to `~/Library/Logs/Kumquat/Kumquat.log`.

### Fixed
- **Re-check** in Settings ▸ Engines gave no feedback and could keep showing stale results. It now
  re-detects every helper in the background with a spinner and a "Checked at…" time, clears cached FFmpeg
  encoder lists, and runs automatically when Settings opens, when you return to Kumquat, and when a custom
  path changes.
- A mistyped custom path made an installed helper look missing; detection now falls back to auto-search.
- Parallel batch jobs could collide on an output name (`photo.png` + `photo.jpg` → `photo.webp`).
- LibreOffice, Pandoc, iWork automation and Quick Look are stopped after a timeout instead of hanging a job forever.
- Launching a second copy of Kumquat no longer adds a second menu-bar icon.

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

[Unreleased]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/scorpionTaj/File-Converter-macos/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/scorpionTaj/File-Converter-macos/releases/tag/v0.1.0
