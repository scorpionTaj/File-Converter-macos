# 🍊 Kumquat

**Convert, edit and share files mid-drag on macOS. Free and open source.**

Start dragging any file, then tap a key. A wheel opens around the cursor; drop the file on what you want.

| Tap while dragging | Wheel | Examples |
|---|---|---|
| **⇧ Shift** | **Convert** | HEIC → JPG, MOV → MP4, DOCX → PDF, XLSX → CSV, SRT → VTT, ZIP → TAR.GZ |
| **⌘ Command** | **Tools** | Annotate, compress, resize, rotate, remove background, OCR, make GIFs, merge/split/trim/lock/redact PDFs, trim & mute video, normalize audio |
| **⌃ Control** | **Actions** | AirDrop, Float on top, Copy, Move to…, Copy to…, Copy Path, open in Terminal |

The result is saved **next to the original**, which is never modified. Nothing is uploaded: Kumquat uses
macOS frameworks (ImageIO, PDFKit, Vision, the Cocoa text system) and optional local tools such as FFmpeg.

> Kumquat is an independent open-source project inspired by the workflow of
> [Tangerine](https://tangerineformac.com/) (Leap Studio). It isn't affiliated with or endorsed by Leap
> Studio and shares no code or assets with it. If you like the idea and want a polished commercial app,
> support the original.

## Features

- **600+ conversions** across images, audio, video, PDF, documents, slides, spreadsheets, subtitles, archives and data.
  Run `kumquat-cli count` to see the exact number for your setup.
- **43 tools** and **7 actions**, filtered to what makes sense for the dragged files.
- **Annotate images**: pen, arrow, rectangle, ellipse, highlighter, text, pixelate (true redaction) and crop, with undo/redo.
  The edited copy is saved as `photo (annotated).jpg`.
- **Works with Photos, Mail and Safari**: file-promise drags are received on drop. Results go to Downloads.
- **More ways in**: drop files on the menu-bar icon, use Finder ▸ Services ▸ **Open in Kumquat**, or **Open With ▸ Kumquat**.
- **Precise edits**: Trim… audio/video (`0:05-1:30`), Resize… (`50%`, `1280`, `1280x720`), Remove/Keep Pages… (`1, 3-5`).
- **Multi-file drops**: convert a batch (three files at a time), merge PDFs, combine images into a PDF or an animated GIF, zip a selection, even from different folders.
- **Smart routing**: multi-step conversions (e.g. XLSX → CSV → JSON) are found automatically, and stream copy
  (instant, lossless) is used when a video only needs a new container.
- **No special permissions**: no Accessibility or Input Monitoring prompt.
- **Menu bar app** with a click-driven fallback (**Convert Files…**), recent results, and settings for keys, quality and output folder.
- **`kumquat-cli`**: the same engines from the terminal.

### Supported formats

| Kind | Read | Write |
|---|---|---|
| Images | JPG PNG HEIC WebP AVIF TIFF GIF BMP ICO ICNS JPEG 2000 PSD SVG RAW (DNG/CR2/CR3/NEF/ARW…) TGA | JPG PNG HEIC WebP AVIF TIFF GIF BMP ICO ICNS JP2 PDF |
| Audio¹ | MP3 M4A AAC WAV FLAC OGG Opus AIFF WMA CAF | MP3 M4A AAC WAV FLAC OGG Opus AIFF WMA |
| Video¹ | MP4 MOV MKV WebM AVI WMV M4V FLV MPEG 3GP MTS, GIF | MP4 MOV MKV WebM AVI WMV M4V GIF, and any audio format |
| PDF | PDF | PNG JPG HEIC TIFF (per page), TXT RTF DOCX ODT HTML Markdown Pages |
| Documents | DOCX DOC RTF ODT TXT HTML Markdown, Pages², EPUB³ | DOCX DOC RTF ODT TXT HTML Markdown PDF, Pages², EPUB³ |
| Slides | PPTX PPT ODP⁴, Keynote² | PDF PPTX ODP⁴, Keynote² |
| Spreadsheets | XLSX XLS ODS⁴, CSV TSV, Numbers² | XLSX ODS⁴, CSV TSV JSON HTML Markdown PDF, Numbers² |
| Subtitles | SRT VTT, ASS/SSA¹ | SRT VTT TXT |
| Archives | ZIP TAR TAR.GZ TAR.BZ2 TAR.XZ GZ 7Z RAR | ZIP TAR TAR.GZ TAR.BZ2 TAR.XZ |
| Data | JSON plist CSV | JSON plist CSV |

¹ FFmpeg · ² Pages/Keynote/Numbers installed · ³ Pandoc · ⁴ LibreOffice. Items that need a missing helper
appear dimmed on the wheel, with the install command.

## Install

1. Download `Kumquat.dmg` from [Releases](../../releases), or the `Kumquat` artifact of the latest
   [CI run](../../actions).
2. Drag **Kumquat.app** to Applications.
3. Development builds are ad-hoc signed. On first launch, right-click → **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/Kumquat.app`.
4. Optional helpers for more formats:

```bash
brew install ffmpeg            # audio, video, GIF, WebP/AVIF fallback
brew install --cask libreoffice # best Office ↔ PDF fidelity, slides & sheets
brew install pandoc            # EPUB & high-quality Markdown
brew install pngquant          # PNG compression
```

Requires macOS 13 Ventura or later (Apple silicon or Intel). Background removal requires macOS 14.

## Build from source

```bash
git clone https://github.com/scorpionTaj/File-Converter-macos.git
cd File-Converter-macos
swift test                    # unit + integration tests
scripts/build-app.sh          # → build/Kumquat.app, Kumquat.zip, Kumquat.dmg
open build/Kumquat.app
```

`UNIVERSAL=1` builds arm64 + x86_64. `SIGN_IDENTITY="Developer ID Application: …"` signs with the
hardened runtime, ready for notarization. `FFMPEG_BIN=/path/to/ffmpeg FFPROBE_BIN=/path/to/ffprobe`
bundles FFmpeg inside the app.

You can also open `Package.swift` in Xcode and run the **Kumquat** scheme.

## Command line

```bash
kumquat-cli convert IMG_0042.HEIC --to jpg
kumquat-cli convert talk.mov --to mp4 --crf 20
kumquat-cli convert data.xlsx --to json --out ~/Desktop
kumquat-cli tool pdfMerge part1.pdf part2.pdf
kumquat-cli tool pdfRedactPersonalInfo contract.pdf
kumquat-cli targets song.flac      # what can this become?
kumquat-cli tools photo.jpg        # which tools apply?
kumquat-cli doctor                 # which helpers are installed?
```

The app bundle includes the CLI at `Kumquat.app/Contents/Resources/bin/kumquat-cli`.

## How it works

See [docs/PLAN.md](docs/PLAN.md) for the full product and engineering plan, covering interaction design,
architecture, the conversion graph, engines, permissions, testing and the roadmap. In short:

- A global mouse monitor notices file drags (via the drag pasteboard) without any permission prompt. It
  then polls modifier keys while the button is down.
- The wheel is a non-activating panel that registers as a drop target, so the system drag lands on it directly.
- `KumquatCore` models formats as a graph of engine edges and finds the cheapest route for each conversion.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a format is usually one
`add(...)` line in `ConversionGraph.swift` plus a test.

## License

[MIT](LICENSE) © 2026 Tajeddine Bourhim
