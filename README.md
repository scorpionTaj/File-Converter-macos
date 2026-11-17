# 🍊 Kumquat

**Convert, edit and share files mid-drag on macOS. Free and open source.**

Start dragging any file, then tap a key. A wheel opens around the cursor; drop the file on what you want.

| Tap while dragging   | Wheel             | Examples                                                                                                                                     |
| -------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **⇧ Shift**   | **Convert** | HEIC → JPG, MOV → MP4, DOCX → PDF, XLSX → CSV, SRT → VTT, ZIP → TAR.GZ                                                                 |
| **⌘ Command** | **Tools**   | Annotate images & PDFs, compress, resize, upscale, rename, edit metadata, remove background, OCR, searchable PDFs, arrange/merge/split/lock/redact PDFs, trim, GIFs from clips, burn subtitles, split chapters, normalize audio |
| **⌃ Control** | **Actions** | AirDrop, Float on top, Copy, Move to…, Copy to…, Copy Path, open in Terminal                                                               |

The result is saved **next to the original**, which is never modified. Nothing is uploaded: Kumquat uses
macOS frameworks (ImageIO, PDFKit, Vision, the Cocoa text system) and optional local tools such as FFmpeg.

> Kumquat is an independent open-source project inspired by the workflow of
> [Tangerine](https://tangerineformac.com/) (Leap Studio). It isn't affiliated with or endorsed by Leap
> Studio and shares no code or assets with it. If you like the idea and want a polished commercial app,
> support the original.

## Features

- **600+ conversions** across images, audio, video, PDF, documents, slides, spreadsheets, subtitles, archives and data.
  Run `kumquat-cli count` to see the exact number for your setup.
- **51 tools** and **7 actions**, filtered to what makes sense for the dragged files.
- **Annotate images**: pen, arrow, rectangle, ellipse, highlighter, text, pixelate (true redaction) and crop, with undo/redo.
  The edited copy is saved as `photo (annotated).jpg`.
- **PDF power tools**: **Make Searchable** adds a hidden OCR text layer to scans (Vision, on device);
  **Arrange Pages…** shows thumbnails to drag into order, turn or remove; **Annotate…** adds highlights,
  underlines, strike-outs, text, notes, boxes and freehand ink as standard PDF annotations.
- **Image tools**: **Rename…** (`Trip {date} {n}` — numbered copies, or a real rename with "Originals: move
  to Trash"), **Edit Metadata…** (date taken, title, artist, copyright, location; lossless), **Upscale 2×**.
- **Media tools**: **GIF from Clip…** and **Trim…** with QuickTime's trim handles, **Burn Subtitles** (drop a
  video with its .srt/.vtt/.ass, or use a same-named file or the video's own subtitle track), **Split Chapters**.
- **Queue window** (menu bar ▸ Queue…, ⌘J): every file's progress; pause and resume, drag waiting files into
  a new order, cancel, and retry what failed.
- **User recipes**: add your own conversions with a small JSON file (see [User recipes](#user-recipes)).
- **Works with Photos, Mail and Safari**: file-promise drags are received on drop. Results go to Downloads.
- **Themes**: Catppuccin (Latte, Frappé, Macchiato, Mocha), Dracula, Monokai, Nord, Gruvbox, Tokyo Night,
  One Dark, Rosé Pine, Solarized and the adaptive Kumquat default.
- **Helper management**: Settings ▸ Engines shows versions and paths and installs missing helpers in one click.
- **Cancel** any running job from the progress popup, and **Undo** finished ones from the menu bar or the
  "job finished" notification (results go to the Trash, replaced files come back).
- **No drag needed**: select files in Finder and press **⌃⌥K** to open the wheel (Settings ▸ General).
- **Your wheel, your order**: recently used formats come first, right-click pins a slice, and **presets**
  (e.g. “WebP 80%, 2048 px”) become one-tap slices. Hold **⌥** when choosing a format to adjust quality,
  size, bitrate or PDF pages first.
- **Output rules**: save next to the original, to Downloads, a custom folder or **ask each time**; put
  batches in their own folder; send images, videos or PDFs to their own folders.
- **More ways in**: drop files on the menu-bar icon, the floating **drop shelf** or Kumquat's Dock icon (if you
  keep it in the Dock); right-click files in Finder ▸ Quick Actions ▸ **Open in Kumquat**; **Share ▸ Kumquat**;
  Finder ▸ Services ▸ **Open in Kumquat**; or **Open With ▸ Kumquat**. Each opens the wheel for those files.
- **Watch folders**: pick a folder and a preset in Settings ▸ Presets, and every new file dropped into the
  folder is converted with that preset, no wheel needed.
- **Launch at login** from Settings ▸ General.
- **Precise edits**: Trim… audio/video (`0:05-1:30`), Resize… (`50%`, `1280`, `1280x720`), Remove/Keep Pages… (`1, 3-5`),
  Arrange Pages… (`3, 1-2, 4r90`).
- **Multi-file drops**: convert a batch (three files at a time), merge PDFs, combine images into a PDF or an animated GIF, zip a selection, even from different folders.
- **Smart routing**: multi-step conversions (e.g. XLSX → CSV → JSON) are found automatically, and stream copy
  (instant, lossless) is used when a video only needs a new container.
- **No special permissions**: no Accessibility or Input Monitoring prompt.
- **Menu bar app** with a click-driven fallback (**Convert Files…**), recent results, and settings for keys, quality and output folder.
- **`kumquat-cli`**: the same engines from the terminal.

### Supported formats

| Kind         | Read                                                                                           | Write                                                              |
| ------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Images       | JPG PNG HEIC WebP AVIF TIFF GIF BMP ICO ICNS JPEG 2000 PSD SVG RAW (DNG/CR2/CR3/NEF/ARW…) TGA | JPG PNG HEIC WebP AVIF TIFF GIF BMP ICO ICNS JP2 PDF               |
| Audio¹      | MP3 M4A AAC WAV FLAC OGG Opus AIFF WMA CAF                                                     | MP3 M4A AAC WAV FLAC OGG Opus AIFF WMA                             |
| Video¹      | MP4 MOV MKV WebM AVI WMV M4V FLV MPEG 3GP MTS, GIF                                             | MP4 MOV MKV WebM AVI WMV M4V GIF, and any audio format             |
| PDF          | PDF                                                                                            | PNG JPG HEIC TIFF (per page), TXT RTF DOCX ODT HTML Markdown Pages |
| Documents    | DOCX DOC RTF ODT TXT HTML Markdown, Pages², EPUB³                                            | DOCX DOC RTF ODT TXT HTML Markdown PDF, Pages², EPUB³            |
| Slides       | PPTX PPT ODP⁴, Keynote²                                                                      | PDF PPTX ODP⁴, Keynote²                                          |
| Spreadsheets | XLSX XLS ODS⁴, CSV TSV, Numbers²                                                             | XLSX ODS⁴, CSV TSV JSON HTML Markdown PDF, Numbers²              |
| Subtitles    | SRT VTT, ASS/SSA¹                                                                             | SRT VTT TXT                                                        |
| Archives     | ZIP TAR TAR.GZ TAR.BZ2 TAR.XZ GZ 7Z RAR                                                        | ZIP TAR TAR.GZ TAR.BZ2 TAR.XZ                                      |
| Data         | JSON plist CSV                                                                                 | JSON plist CSV                                                     |

¹ FFmpeg · ² Pages/Keynote/Numbers installed · ³ Pandoc · ⁴ LibreOffice. Items that need a missing helper
appear dimmed on the wheel, with the install command.

## Install

1. Download `Kumquat-<version>.dmg` from [Releases](../../releases) (or `Kumquat-nightly.dmg` from the
   `nightly` pre-release).
2. Open it and drag **Kumquat** onto the **Applications** shortcut in the installer window. If you open
   Kumquat straight from the disk image, it offers to move itself to Applications and eject the image.
3. Development builds are ad-hoc signed. On first launch, right-click → **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/Kumquat.app`.
4. Optional helpers for more formats:

```bash
brew install ffmpeg            # audio, video, GIF, WebP/AVIF fallback
brew install --cask libreoffice # best Office ↔ PDF fidelity, slides & sheets
brew install pandoc            # EPUB & high-quality Markdown
brew install pngquant          # PNG compression
brew install ghostscript       # smaller text-heavy PDFs when compressing
```

Requires macOS 13 Ventura or later (Apple silicon or Intel). Background removal requires macOS 14.

## Build from source

```bash
git clone https://github.com/scorpionTaj/Kumquat.git
cd Kumquat
swift test                    # unit + integration tests
scripts/build-app.sh          # → build/Kumquat.app, Kumquat.zip, Kumquat.dmg
open build/Kumquat.app
```

`UNIVERSAL=1` builds arm64 + x86_64. `SIGN_IDENTITY="Developer ID Application: …"` signs with the
hardened runtime, ready for notarization. `FFMPEG_BIN=/path/to/ffmpeg FFPROBE_BIN=/path/to/ffprobe`
bundles FFmpeg inside the app.

You can also open `Package.swift` in Xcode and run the **Kumquat** scheme.

## Releases (CI/CD)

| Channel              | How it's made                                                         | Where                                                                                                |
| -------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **Stable**     | Push a `vX.Y.Z` tag, or run the **Release** workflow manually | [Releases](../../releases): universal `.dmg`, `.zip`, `kumquat-cli` tarball, `SHA256SUMS.txt` |
| **Nightly**    | Every push to `main` that passes all tests                          | The `nightly` pre-release                                                                          |
| **Per commit** | Every push and pull request                                           | The `Kumquat` artifact on each [CI run](../../actions)                                              |

The Release workflow first runs the **full test suite** on macOS as a reusable workflow. It then
checks that the tag matches `VERSION` and that `CHANGELOG.md` has a section for it. Next it builds a
universal (arm64 + x86_64) app and verifies the bundle (version, architectures, code signature, CLI
smoke test). Finally it publishes the assets, with that changelog section as the release notes.

To cut a release, use either:

- **From GitHub:** Actions ▸ **Release** ▸ **Run workflow**. Pick a bump (`patch`, `minor`, `major` or
  `custom`) and optionally tick *pre-release*, *draft* or *universal*, or add extra notes. The workflow
  writes the new `VERSION` and turns the changelog's "Unreleased" notes into the version's section (or
  writes them from commit messages). It commits that to `main`, runs the tests, builds and publishes.
- **From your Mac:** `scripts/release.sh patch` (or `minor`, `major`, `1.2.3`). It does the same file
  updates locally, shows you the notes, then tags and pushes.

You only need to edit `CHANGELOG.md` if you want hand-written notes: put them under `## [Unreleased]`.

Every CI run also publishes a test summary (passed / failed / skipped per platform) and a KumquatCore
code-coverage table on the run page.

## Command line

```bash
kumquat-cli convert IMG_0042.HEIC --to jpg
kumquat-cli convert talk.mov --to mp4 --crf 20
kumquat-cli convert data.xlsx --to json --out ~/Desktop
kumquat-cli convert *.HEIC --to jpg --name "{name}-web" --max-size 2048 --metadata removeLocation
kumquat-cli tool pdfMerge part1.pdf part2.pdf
kumquat-cli tool pdfRedactPersonalInfo contract.pdf
kumquat-cli targets song.flac      # what can this become?
kumquat-cli tools photo.jpg        # which tools apply?
kumquat-cli doctor                 # which helpers are installed?
kumquat-cli tool pdfSearchable scan.pdf
kumquat-cli tool pdfArrange report.pdf --param "3, 1-2, 4r90"
kumquat-cli tool batchRename *.jpg --param "Trip {date} {n}"
kumquat-cli tool imageEditMetadata photo.jpg --param "date=2024-05-01 14:30; title=Beach; location="
kumquat-cli tool videoToGIF talk.mov --param "0:12-0:16"
kumquat-cli tool videoBurnSubtitles movie.mp4 movie.srt
kumquat-cli recipes                # your recipes, and why any were skipped
```

The CLI comes with the app: when Kumquat runs from Applications, it links
`Kumquat.app/Contents/Resources/bin/kumquat-cli` into Homebrew's `bin` folder, so `kumquat-cli` works in
any new Terminal window and stays in step with app updates. Without Homebrew, use
**Settings ▸ Advanced ▸ Command Line ▸ Install…** (asks for your password, links into `/usr/local/bin`),
or link it yourself:

```bash
sudo ln -sf /Applications/Kumquat.app/Contents/Resources/bin/kumquat-cli /usr/local/bin/kumquat-cli
```

`kumquat-cli --version` prints the version.

### Shortcuts and Automator

Kumquat has no Shortcuts actions of its own (see [the roadmap](docs/ROADMAP.md) for
why). Use the CLI from Shortcuts' **Run Shell Script** action (set "Pass input" to **as arguments**) or
Automator's **Run Shell Script**:

```bash
/Applications/Kumquat.app/Contents/Resources/bin/kumquat-cli convert "$@" --to webp --max-size 2048
```

To get the wheel instead, use Shortcuts' **Open File** action with **Kumquat** as the app.

### User recipes

Add a conversion Kumquat doesn't have, or replace one with your own tool, by putting a JSON file in
`~/Library/Application Support/Kumquat/recipes` (**Settings ▸ Engines ▸ Recipes ▸ Open Folder** creates it
with a disabled example):

```json
{
  "name": "Markdown to PDF with my stylesheet",
  "from": ["md"],
  "to": "pdf",
  "command": ["/opt/homebrew/bin/pandoc", "{input}", "-o", "{output}", "--css", "/Users/me/style.css"],
  "timeout": 120
}
```

- `from` (one format or a list) and `to` are format names from `kumquat-cli formats`. The recipe shows on the
  Convert wheel, wins over a built-in conversion for the same formats, and chains with built-in ones
  (e.g. TSV → CSV → your recipe).
- `command` is the program (a full path, or a name found where Kumquat looks for helpers) and its arguments.
  `{input}` and `{output}` are replaced with file paths. It runs directly, **not through a shell**, so file
  names can never become commands. The command must write `{output}`; Kumquat then saves it next to the
  original like any result.
- `timeout` (seconds, default 300, at most 3600): the command is stopped after this.
- Only regular files directly in the folder, owned by you and not writable by other users, are loaded (links
  are refused). Skipped files and failed runs (with the command's error output) are shown in Settings ▸
  Engines and by `kumquat-cli recipes`. Edits are picked up the next time the wheel opens.

Recipes run with your permissions: only add commands you trust.

## How it works

See [docs/PLAN.md](docs/PLAN.md) for the full product and engineering plan, covering interaction design,
architecture, the conversion graph, engines, permissions, and testing, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes before 1.0. In short:

- A global mouse monitor notices file drags (via the drag pasteboard) without any permission prompt. It
  then polls modifier keys while the button is down.
- The wheel is a non-activating panel that registers as a drop target, so the system drag lands on it directly.
- `KumquatCore` models formats as a graph of engine edges and finds the cheapest route for each conversion.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a format is usually one
`add(...)` line in `ConversionGraph.swift` plus a test.

## License

[MIT](LICENSE) © 2026 Tajeddine Bourhim
