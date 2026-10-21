# Kumquat — Product & Engineering Plan

Kumquat is a free, open-source (MIT) macOS utility that converts, edits and shares files **in the
middle of a drag**. It is a clean-room re-implementation of the *idea* behind
[Tangerine](https://tangerineformac.com/) by Leap Studio, built from its public feature description. It
shares no code, assets or branding with it.

---

## 1. What we are cloning (reference behaviour)

From Tangerine's public website, App Store listing and press kit:

| Tangerine | Notes |
|---|---|
| Drag a file, tap **⇧ Shift** → wheel of output formats | Radial menu appears around the dragged file; drop on a format |
| Tap **⌘ Command** → file-specific editing tools | 26 tools: compress, resize, metadata removal, redaction, photo annotation… |
| Tap **⌃ Control** → actions | AirDrop, Float, Copy, Move, Copy Path, Terminal (6 actions) |
| 275 conversion options | Images, audio, video, PDF, documents, slides, spreadsheets, subtitles, archives |
| Result saved **next to the original** | Original never modified |
| 100 % offline | No uploads |
| macOS 13+, Apple silicon, $29.99 | Kumquat: macOS 13+, Apple silicon **and** Intel, free |

## 2. Product goals

1. **Zero-click feel**: no window to open. The wheel appears only when needed and disappears after the drop.
2. **Parity or better** with every Tangerine feature above (see §8 for the checklist).
3. **Private by construction**: all processing uses on-device frameworks or local CLI tools.
4. **Graceful degradation**: everything that macOS can do natively works out of the box. Formats that need
   a helper (FFmpeg, LibreOffice, Pandoc, iWork) still appear on the wheel, dimmed, with the exact install
   command.
5. **Hackable**: adding a format is usually one line in the conversion graph.

Non-goals (v1): cloud services, Windows/Linux GUI, App Store sandboxing.

## 3. Interaction design

### 3.1 Summoning a wheel
1. User starts dragging one or more files (Finder, Desktop, any app that drags file URLs).
2. While the mouse button is down, the user **taps** a modifier:
   - ⇧ → **Convert** wheel, ⌘ → **Tools** wheel, ⌃ → **Actions** wheel (all remappable, incl. ⌥).
   - Keys already held when the drag began don't count (so ⌘-drag-to-move in Finder still works).
   - Tapping the same key again closes the wheel; tapping another key swaps wheels.
3. The wheel appears centred on the cursor (clamped to the screen).
4. User drags over a segment (it highlights orange; the hub shows the full name or why it's unavailable)
   and releases. Dropping on the hub or outside cancels; Finder's drag snaps back.

### 3.2 Wheel layout
- Up to 10 items: one ring. 11+: inner ring (≤ 8) + outer ring.
- Items are ordered by popularity (JPG, PNG, HEIC, WebP… first).
- Unavailable items are dimmed and refuse the drop (no-entry cursor).
- Hub: wheel name + file name/count, or the hovered item's description.

### 3.3 Feedback
- HUD toast (top-right): title, progress bar (FFmpeg progress is real, parsed from `-progress`),
  then ✓ "Saved photo.jpg" (click to reveal) or ✕ with the error.
- Optional sound, optional auto-reveal in Finder.
- Menu-bar item: enable/disable, **Convert Files…** (opens the same wheel in click mode, with the hub
  cycling through Convert → Tools → Actions), Recent results, How to Use, Settings, Quit.

### 3.4 Onboarding
First launch shows a Welcome window: the three keys, what each wheel does, and which optional helpers are
installed (with copy-able `brew install` commands).

## 4. Architecture

```
┌─────────────────────────── Kumquat.app (AppKit, LSUIElement) ───────────────────────────┐
│ DragMonitor ──► AppDelegate ──► RadialMenuController/View ──► AppDelegate.perform        │
│ (global mouse    (wheel items    (NSPanel, draws rings,        ├─ FileActions (AirDrop…)  │
│  monitor + 60Hz   from Catalog)   NSDraggingDestination)       └─ Converter (async)       │
│  modifier poll)                                                     │                    │
│ HUDController · StatusBarController · SettingsStore · SwiftUI Settings/Welcome           │
└──────────────────────────────────────────────────────────────────────┼──────────────────┘
                                                                       ▼
┌──────────────────────────────── KumquatCore (library) ───────────────────────────────────┐
│ Format/FormatRegistry  ConversionGraph (edges + cheapest-route search)  Catalog/ToolID   │
│ Converter (route → engines → work dir → unique destination)   ToolRunner                 │
│ Engines: Image(ImageIO/CoreImage/Vision) PDF(PDFKit) Document(Cocoa text + print)        │
│          Media(FFmpeg) Archive(tar/ditto/zip) Data(CSV/JSON/plist) Subtitle(SRT/VTT)      │
│          Office(LibreOffice) Pandoc  iWork(AppleScript)                                  │
│ Pure helpers: FFmpegRecipes, MarkdownRenderer, Table (CSV), Subtitles, IWorkScripts       │
└──────────────────────────────────────────────────────────────────────────────────────────┘
          ▲
   kumquat-cli (same engines from the terminal; bundled in Kumquat.app/Contents/Resources/bin)
```

### 4.1 Detecting drags without permissions
- `NSEvent.addGlobalMonitorForEvents(.leftMouseDragged)` needs **no** Accessibility/Input Monitoring
  permission (only key events do).
- On each drag event we compare `NSPasteboard(name: .drag).changeCount`; a change means a new drag
  session. We read its file URLs.
- During the session a 60 Hz timer reads `NSEvent.modifierFlags` and `NSEvent.pressedMouseButtons`
  (class properties, no permission) to detect taps and the mouse-up.
- The wheel is a borderless, non-activating `NSPanel` at `.popUpMenu` level registered for
  `.fileURL` drags, so the system drag session drops straight onto it. The source app (Finder) sees a
  normal `.copy` drop and leaves the original untouched.

### 4.2 Conversion graph
- Each engine declares **direct edges** (`from → to`, engine, optional dependency, cost).
- `ConversionGraph.route` finds the cheapest path (≤ 3 hops). Example: `XLSX → CSV (LibreOffice) → JSON (Swift)`.
- `bestRoute` prefers paths whose dependencies are installed (e.g. DOCX → PDF uses LibreOffice when
  present, otherwise the Cocoa print system), and otherwise returns a path so the UI can say what to install.
- `TargetPolicy` keeps multi-hop search sensible (no JPG → PDF → TXT).
- The wheel's targets = policy-allowed formats with any route; for multi-file drops, the intersection.

### 4.3 Engines

| Engine | Technology | Formats |
|---|---|---|
| Image | ImageIO, Core Graphics, Core Image, Vision, Quick Look (SVG) | JPG PNG HEIC WebP AVIF TIFF GIF BMP ICO ICNS JP2 ← also PSD SVG RAW TGA; → PDF |
| PDF | PDFKit | PDF → PNG/JPG/HEIC/TIFF (one per page), TXT, RTF (→ DOCX/ODT/HTML/MD/Pages via graph) |
| Document | `NSAttributedString` importers/exporters, NSPrintOperation, MarkdownRenderer | DOCX DOC RTF ODT TXT HTML MD ↔ each other, → PDF |
| Media | FFmpeg/ffprobe (stream copy when possible) | MP3 M4A AAC WAV FLAC OGG Opus AIFF WMA CAF; MP4 MOV MKV WebM AVI WMV M4V FLV MPEG 3GP MTS; GIF; ASS→SRT/VTT |
| Archive | `tar` (libarchive), `ditto`, `zip`, `gzip` | ZIP TAR TAR.GZ TAR.BZ2 TAR.XZ ← also GZ 7Z RAR |
| Data | Foundation | CSV TSV JSON plist, CSV → HTML/Markdown tables |
| Subtitle | Swift | SRT ↔ VTT, → TXT transcript |
| Office | LibreOffice headless (`soffice --convert-to`, private profile per job) | DOCX/DOC/ODT/RTF → PDF, PPTX/PPT/ODP, XLSX/XLS/ODS/CSV |
| Pandoc | pandoc | → EPUB, EPUB →, high-quality → Markdown |
| iWork | AppleScript via `osascript` | Pages, Keynote, Numbers import/export |

### 4.4 Tools (Tools wheel, 36)
Images: Compress, Resize 50 %, Fit 1920 px, Rotate L/R, Flip, Grayscale, Remove Background (Vision,
macOS 14), Copy Text (OCR), Make PDF (multi). PDF: Compress, Merge (multi), Split Pages, Rotate, Extract
Text, OCR Text, Add Password, Unlock, Redact PII (emails, phones, card numbers, SSN, IBAN), Redact
custom text. Video: Compress, 720p, Mute, Get Audio, Rotate, Speed 2×, Poster Frame. Audio:
Normalize (EBU R128), Compress, Mono, Trim Silence. Shared: Strip Metadata (images lossless, PDF,
audio/video stream copy), Extract archive, Zip, SHA-256, Word Count.

Redaction flattens matched pages to images with the matches painted black, so the hidden text is
removed from the file, not just covered.

### 4.5 Actions (Actions wheel, 7)
AirDrop (`NSSharingService`), Float (always-on-top Quick Look panel), Copy (file to clipboard), Move to…,
Copy to…, Copy Path, Terminal (Terminal/iTerm2/Warp/Ghostty at the file's folder).

### 4.6 Output rules
- Saved next to the original (or Downloads/custom folder). Read-only folder → Downloads.
- Never overwrite: `photo.jpg`, `photo 2.jpg`, …; tools add a suffix: `photo (compressed).jpg`.
- Every job runs in its own temp work directory; only the final result is moved into place, so a
  failure never leaves partial files next to the original.
- Multi-page results (PDF → PNG, Split Pages) become a folder.

## 5. Dependencies strategy

| Helper | Needed for | Detection |
|---|---|---|
| FFmpeg | audio/video/GIF, WebP/AVIF fallback, ASS subtitles | `/opt/homebrew/bin`, `/usr/local/bin`, MacPorts, `PATH`, app bundle `Resources/bin`, Settings override |
| LibreOffice | best-fidelity Office ↔ PDF, slides, sheets | `/Applications/LibreOffice.app` |
| Pandoc | EPUB, high-quality Markdown | same as FFmpeg |
| Pages/Keynote/Numbers | iWork formats | `/Applications/*.app` |
| pngquant | PNG compression | same as FFmpeg |

The release build can bundle static `ffmpeg`/`ffprobe` (set `FFMPEG_BIN`/`FFPROBE_BIN` when running
`scripts/build-app.sh`); mind FFmpeg's LGPL/GPL terms when distributing.

## 6. Permissions & distribution
- No Accessibility, Input Monitoring, Full Disk Access or network permission.
- Automation (Apple Events) only when converting iWork files (`NSAppleEventsUsageDescription`).
- Not sandboxed (needs to write next to arbitrary files and run helpers), so it ships outside the App Store:
  ad-hoc signed by default; set `SIGN_IDENTITY` for Developer ID + hardened runtime, then notarize with
  `xcrun notarytool submit build/Kumquat.zip --wait` and `xcrun stapler staple build/Kumquat.app`.
- `LSUIElement` (menu bar only), Launch at Login via `SMAppService`.

## 7. Quality & testing
- **Unit tests (Linux + macOS)**: format detection, graph routing & policy, catalog decisions, naming,
  SRT/VTT, CSV/JSON/Markdown tables, Markdown renderer, every FFmpeg recipe, AppleScript generation.
- **Integration tests**: real FFmpeg conversions/tools (Linux CI installs FFmpeg), archives, data,
  subtitles, checksums; on macOS: ImageIO conversions & tools, PDF render/merge/split/encrypt/redact,
  document round trips.
- **CI**: GitHub Actions — Linux (Swift 6 container + FFmpeg) and macOS 15 (tests, `.app`, `.dmg`,
  CLI smoke test, artifact upload). Tag `v*` → universal release with zip + dmg.
- **Manual QA checklist** (each release): drag from Finder/Desktop/Mail attachment; each modifier; swap
  wheels mid-drag; cancel on hub; multi-file drop; Spaces/full-screen; dark/light; external display;
  missing helper messaging; read-only source folder.

## 8. Feature parity checklist

- [x] Shift/Command/Control wheels during drag (remappable, plus Option)
- [x] Only relevant formats/tools for the dragged file type
- [x] Save beside original, never overwrite, offline
- [x] Images: JPG PNG HEIC WebP AVIF TIFF BMP GIF + PDF export + SVG input (+ ICO ICNS JP2 PSD RAW TGA)
- [x] Audio: MP3 M4A WAV FLAC OGG Opus AIFF WMA (+ AAC CAF)
- [x] Video: MP4 MOV MKV WebM AVI WMV GIF (+ M4V FLV MPEG 3GP MTS)
- [x] PDF & documents: DOCX Pages PPTX XLSX EPUB TXT Markdown (+ RTF ODT HTML DOC Keynote Numbers ODS ODP)
- [x] Subtitles: SRT VTT (+ ASS input, TXT transcript)
- [x] Archives: ZIP TAR GZIP (+ BZ2 XZ, 7z/RAR extraction)
- [x] Compress, remove metadata, redact documents
- [x] AirDrop, Float, Copy, Move, Copy Path, Terminal
- [x] ≥ 275 conversions (`kumquat-cli count`)
- [ ] Photo annotation (planned: lightweight markup window, v0.3)
- [ ] File-promise drags (Photos, Mail) — planned v0.2 via `NSFilePromiseReceiver`

## 9. Roadmap

| Version | Scope |
|---|---|
| **0.1** (this repo) | Everything in §8 that is checked; CLI; CI; signed/zipped/dmg builds |
| 0.2 | File-promise drags (Photos/Mail/Safari images), drop onto the menu-bar icon, Finder Quick Actions/Services, per-format favourites & ordering, batch progress per file |
| 0.3 | Annotate (arrows, text, highlight, blur) for images & PDFs; video trim; image crop; PDF page reorder |
| 0.4 | Bundled FFmpeg build, Sparkle auto-updates, notarized releases, localisation |
| 0.5 | Plugin edges (user-defined shell recipes in `~/Library/Application Support/Kumquat/recipes`) |

## 10. Risks

| Risk | Mitigation |
|---|---|
| Apps that drag without the drag pasteboard (rare) | Fallback menu-bar "Convert Files…" click mode |
| Modifier conflicts (Finder ⌘ = move) | Count only *taps* after the drag started; keys remappable |
| HEIC/AVIF encoder availability varies by macOS/hardware | Runtime check of ImageIO writable types; FFmpeg fallback |
| LibreOffice profile locks | Private `-env:UserInstallation` per job |
| iWork automation prompts | Clear usage string; error message pointing to Privacy & Security |
| Large videos | Stream copy whenever codecs allow; real progress; cancellable `Process` |
