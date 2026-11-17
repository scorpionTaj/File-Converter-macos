# Changelog

All notable changes to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.8.0] - 2026-11-17

### Added
- **Kumquat speaks French, Spanish, German and Arabic.** Menus, settings, the wheels (tool and action names
  and descriptions), prompts, progress notices, notifications and the editors are translated, and Arabic
  lays out right to left. Kumquat follows your Mac's language, or pick one for Kumquat alone in
  **Settings ▸ General ▸ Language** (applies after Relaunch Now). Error and result messages from the
  conversions are translated too; `kumquat-cli` and result file names stay in English.
- Wheel labels wrap onto two lines when they don't fit their segment, instead of running into the
  neighbouring slices (long translations, and a few English titles such as “Strip Metadata”).
- Translations live in a String Catalog; `scripts/strings.py` keeps it in step with the code, and CI checks
  that every language is complete.

### Fixed
- **Pages, Numbers and Keynote showed as not installed** on Macs where they're called "Pages Creator Studio"
  (and so on), or live outside Applications. Kumquat now finds them by bundle identifier through Launch
  Services, and talks to them by identifier too, so their conversions work again.

## [0.7.1] - 2026-11-17

### Changed
- **Settings redesign**: a sidebar like System Settings replaces the tab bar, whose tabs no longer fit and
  hid behind a » menu. Each page has a header saying what it's for. General was split into **General**,
  **Wheels** and **Notifications**; **Watch Folders** and **Recipes** have their own pages; PDF quality has its
  own section; "files at a time" moved to **Quality ▸ Speed**. The window is larger and resizable.
- **Recipes** page shows the recipe file format and the safety rules.

## [0.7.0] - 2026-11-17

### Added
- **Make Searchable** (PDF): adds an invisible, positioned text layer to scanned pages with on-device OCR, so
  the PDF can be searched, selected and copied. Pages that already have text are kept as they are; sideways
  scans with a rotation come out upright.
- **Arrange Pages…** (PDF): drag page thumbnails into a new order, turn them, remove them, and save a copy.
  The CLI takes the same as text: `--param "3, 1-2, 4r90"`.
- **Annotate…** for PDFs: highlight, underline, strike out, text, notes, boxes and freehand drawing, saved as
  standard annotations (editable in Preview and Acrobat) on a copy.
- **Rename…**: renamed copies from a pattern with `{name}`, `{n}` (drop order) and `{date}` (date taken, or the
  file's date). With "Originals: move to Trash" it renames in place; Undo puts things back.
- **Edit Metadata…** (JPEG, PNG, TIFF, HEIC): set or clear date taken, title, artist, copyright and GPS
  location without re-encoding the image.
- **Upscale 2×**: Lanczos enlargement with light sharpening. It's high-quality resampling, not AI
  super-resolution, which macOS doesn't offer to apps without bundling a model.
- **GIF from Clip…**: an animated GIF of a chosen part of a video.
- **Burn Subtitles**: draws a dropped .srt/.vtt/.ass file, one next to the video with the same name, or the
  video's own text subtitle track into the picture. Works with FFmpeg builds without libass, such as
  Homebrew's.
- **Split Chapters**: one file per chapter marker of a video or audiobook, copied without re-encoding.
- **Queue window** (menu bar ▸ Queue…, ⌘J): each file's progress, pause/resume, drag to reorder waiting
  files, cancel, and retry failed ones.
- **User recipes**: your own conversions as JSON files in `~/Library/Application Support/Kumquat/recipes`,
  run as an argument list (never through a shell) with a timeout. Problems are listed in Settings ▸ Engines
  and by `kumquat-cli recipes`.

### Changed
- **Trim…** on a single clip opens a player with QuickTime's trim handles instead of asking for times
  (several files, or formats AVFoundation can't play, still take a typed range).
- PDF → image conversions now include annotations (highlights, notes, filled-in forms).
- The "files at a time" setting now applies across all running jobs, not per drop.

## [0.6.0] - 2026-11-16

### Added
- **Watch folders**: in Settings ▸ Presets, pick a folder and a preset; every file added to the folder is
  converted with that preset once it has finished copying or downloading. Files already there are left
  alone, files added while Kumquat was closed are converted at the next launch, and results follow your
  Output settings (“Ask each time” saves next to the file). Pause or remove a folder at any time.
- **Finder Quick Action and Share extension**: right-click files ▸ Quick Actions ▸ **Open in Kumquat**, or
  **Share ▸ Kumquat**, opens the wheel for them. If they don't show up, turn them on in System Settings ▸
  General ▸ Login Items & Extensions.
- **Drop shelf**: a small floating window (Settings ▸ General ▸ Show the drop shelf). Drop files on it to
  open the wheel without holding a key, which is easier on a trackpad. Drag it anywhere; right-click to hide.
- Shortcuts and Automator recipes using `kumquat-cli` in the README.

### Changed
- **Launch at login** says when macOS is waiting for your approval (with a button to open Login Items) and
  explains why it couldn't be turned on, e.g. when Kumquat runs from the disk image.

## [0.5.0] - 2026-11-16

### Added
- **Wheel for the Finder selection**: select files in Finder and press ⌃⌥K to open the wheel without
  dragging. Choose another shortcut or turn it off in Settings ▸ General. macOS asks once to let Kumquat
  read Finder's selection.
- **Install and Relaunch** for updates: after downloading, Kumquat checks the new app (bundle, version and
  code signature), quits, replaces itself and opens again. The old version is kept until the new one is in
  place and restored if the swap fails. Updates installed this way don't need right-click ▸ Open. When the
  app's folder isn't writable, the disk image opens for a manual install as before.
- **Undo**: the menu bar's **Undo** (⌘Z while the menu is open) reverses the last conversion or tool run.
  Its results go to the Trash and any file it replaced or moved to the Trash is put back. The last 10 jobs
  can be undone; a file is never overwritten to put something back, and anything that can't be restored
  is listed.
- **Notifications** when a job finishes, with **Show in Finder**, **Open** and **Undo** buttons. Choose
  never, jobs over 10 seconds (default) or always in Settings ▸ General ▸ Notices.
- **Wheel order**: recently used formats and tools come first for each file type, and right-clicking a
  slice (on a wheel opened by click, the Finder shortcut or the menu) pins it to the front. Settings ▸
  General can turn recents off and clear pins.
- **Presets**: save a format plus settings (e.g. “WebP, 80%, 2048 px”) in Settings ▸ Presets; presets
  appear first on the Convert wheel for files that can become their format.
- **Options before converting**: hold ⌥ while choosing a format (or turn it on in Settings ▸ Quality) to
  set quality, size, video quality, bitrate or the PDF pages to export for that conversion. “Remember”
  keeps them for that format.
- **Output rules**: “Ask each time” as a save location, “Put each batch in its own folder”, and folders
  by kind (e.g. images to Pictures) in Settings ▸ Output.
- PDF → image conversions can export a page range.

### Changed
- The updater uses the renamed `scorpionTaj/Kumquat` repository.

### Security
- Downloaded updates are checked against the release's SHA-256 sums; a damaged or altered disk image is
  deleted instead of opened.

## [0.4.2] - 2026-11-16

### Added
- Installing Kumquat installs `kumquat-cli` too: when Kumquat runs from Applications it links its
  bundled CLI into Homebrew's `bin` folder, and repairs the link if the app moves. Settings ▸ Advanced ▸
  Command Line shows where it is and can install it into `/usr/local/bin` with your password on Macs
  without Homebrew. Files named `kumquat-cli` that Kumquat didn't create are never replaced.
- `kumquat-cli --version` (or `kumquat-cli version`) prints the version of the app the CLI belongs to.

## [0.4.1] - 2026-11-16

### Changed
- **Compress** for PDFs now downsamples and re-encodes the images inside the file, so scanned PDFs
  shrink by 70–95% instead of not at all. Text, fonts and vector art are kept. It also works on
  macOS 13.0–13.3 now.
- Choose how hard PDF Compress works in Settings ▸ Quality: **Light** (best quality), **Balanced**
  (default) or **Strong** (smallest file, e.g. a 1.2 MB scan → 46 KB). The CLI takes
  `--pdf-compression light|balanced|strong`.
- Optional **Ghostscript** helper (`brew install ghostscript`, or Settings ▸ Engines ▸ Install): PDF
  Compress then also rewrites fonts and page content, which shrinks PDFs that are mostly text. The
  smallest result still wins, and results missing pages are never used.
- Images → PDF (and Make PDF) embed JPEGs as they are instead of re-encoding them, so the PDF is about
  the size of the photos instead of roughly double. Rotated phone photos stay upright.
- Tools process several files at once, using the "files at a time" setting (the CLI takes `--jobs`).
  Results keep the order the files were dropped in.
- Redact PII is more precise: phone numbers need a country code, a leading 0 or (415) 555-0134 style
  grouping, and card numbers must pass the Luhn check, so invoice, order and reference numbers stay.

### Fixed
- Redact PII and Redact… no longer save a file when a match can't be located on the page (it would
  have stayed visible), and overlapping matches are counted once.
- Two files with the same name from different folders no longer mix their results in Split Pages or
  Extract.
- Compress never saves an image, video or audio copy that is larger than the original.
- Cancelling a job just before its helper process launched no longer lets the helper run to the end.
- A helper's timeout no longer signals its process id after the helper has already exited.
- Split Pages reports a page that couldn't be saved instead of silently skipping it.
- Converting a property list with NaN/infinite numbers (or a non-container root) to JSON fails with a
  message instead of crashing.

## [0.4.0] - 2026-10-22

### Added
- New **Output** settings tab:
  - File name template with `{name}`, `{format}`, `{date}` and `{time}`, plus a live example.
  - When a file with that name exists: keep both, replace (the old file goes to the Trash) or skip.
  - Move originals to the Trash after a successful conversion; tools that combine files never do.
  - Give results the original's creation and modification dates.
  - Photo and media metadata: keep, remove location only, or remove all.
- **Quality** tab:
  - Separate JPEG, HEIC, WebP and AVIF quality, and a maximum image size.
  - Video: encoder (automatic / hardware / software), speed preset, maximum resolution, frame-rate cap
    and remove audio.
  - Audio: sample rate, mono/stereo and loudness normalisation.
- **Advanced** tab: how many files convert at once (1–8), Open Log, Copy Diagnostics, Clear Temporary
  Files and Reset All Settings.
- **General** settings:
  - Open the wheel under the pointer or in the centre of the screen.
  - Notice position (any corner or top centre), how long results stay on screen (or until clicked), and
    whether to show a notice for successful jobs.
  - Choose the success and failure sounds.
  - Menu bar icon style, a progress percentage next to the icon while converting, and how many recent
    results to keep.
- **Custom themes**: duplicate any theme and edit its colours with a live preview, export themes as `.json`
  and import them on another Mac. You can also use different themes for Light and Dark mode.
- **Check for Updates…** (menu bar and Settings ▸ Advanced) compares your version with the GitHub
  releases, shows the release notes and downloads the new disk image. It also checks automatically once
  a day (can be turned off), you can include pre-releases, and you can skip a version.
- **Crash reporting**: if Kumquat quit unexpectedly last time, it offers to open a prefilled GitHub issue
  with diagnostics and the recent log. **Report a Problem…** does the same at any time. Nothing is sent
  until you submit the issue.
- `kumquat-cli` options: `--name`, `--on-conflict`, `--originals`, `--metadata`, `--keep-dates`,
  `--max-size`, `--max-height` and `--encoder`.

### Changed
- Image conversions now keep EXIF, TIFF, IPTC and GPS metadata by default. Before, they dropped it.
  Choose "Remove location only" or "Remove all" in Settings ▸ Output to change this.
- A tool result that can't be saved no longer discards the batch's other results.

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

[Unreleased]: https://github.com/scorpionTaj/Kumquat/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/scorpionTaj/Kumquat/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/scorpionTaj/Kumquat/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/scorpionTaj/Kumquat/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/scorpionTaj/Kumquat/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/scorpionTaj/Kumquat/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/scorpionTaj/Kumquat/releases/tag/v0.1.0
