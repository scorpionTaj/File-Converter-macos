# Kumquat roadmap to 1.0

Where Kumquat stands (0.3.1): drag-and-tap radial wheels, 646 conversions, 42 tools, 7 actions,
annotation editor, file promises, themes, engine manager, CLI, styled DMG, CI releases.

1.0 means: an app a stranger can download, keep up to date, tune to their taste, and trust with
their files, while staying as small as possible. The milestones below are ordered by what blocks that most.

Ground rules:
- **No paid Apple Developer account.** Releases stay ad-hoc signed; first launch is right-click → Open
  (the DMG and README explain it). Nothing on this list needs Developer ID or notarization.
- **No bundled engines.** FFmpeg, LibreOffice and Pandoc stay optional and are found or installed
  through Settings ▸ Engines, so the app stays a few MB.

## 0.4 — Updates, settings & reliability (built, unreleased)

✅ done · ⏳ left for later

| Item | Status |
|---|---|
| Check for Updates (GitHub releases, notes, skip version, daily check, pre-releases, DMG download) | ✅ Built in, no Sparkle needed for ad-hoc builds |
| Crash reporting: notice after an unexpected quit, "Report a Problem…" with a prefilled GitHub issue | ✅ |
| File name template (`{name}`, `{format}`, `{date}`, `{time}`) with live example | ✅ (`{n}`, `{width}x{height}` ⏳) |
| When the name exists: keep both / replace (to Trash) / skip | ✅ ("ask" ⏳) |
| Originals: keep / move to Trash; keep the original's file dates | ✅ (undo ⏳ in 0.5) |
| Metadata: keep / remove location / remove all (images, audio, video) | ✅ |
| Per-format JPEG/HEIC/WebP/AVIF quality, maximum image size | ✅ (PNG optimisation level ⏳) |
| Video: encoder (auto/hardware/software), speed preset, max resolution, frame-rate cap, remove audio | ✅ |
| Audio: sample rate, mono/stereo, loudness normalisation | ✅ |
| Jobs: 1–8 files at a time | ✅ (battery priority, per-job timeout ⏳) |
| Wheel position (pointer / screen centre) | ✅ (tap window, hover delay, labels, slice limit ⏳) |
| Notices: position, how long they stay, hide successes, success/failure sounds | ✅ |
| Menu bar: icon style, progress percentage, recent results count | ✅ |
| Custom themes: editor, import/export JSON, light/dark pairs | ✅ |
| Advanced: open log, copy diagnostics, clear temporary files, reset all settings | ✅ |
| Sparkle 2 (signed appcast, in-place install) | ⏳ Optional; revisit if in-place install is wanted |

## 0.5 — Everyday workflow

| Item | Why |
|---|---|
| ✅ Global hotkey: open the wheel for the current **Finder selection** (no drag needed) | Fastest path for keyboard users |
| Favourites & ordering on the wheel; pin per source format; "recent targets first" | 646 conversions is a lot to scan |
| Presets: saved conversion + options (e.g. "WebP 80% max 2048px"), shown as wheel slices | Repeated tasks become one tap |
| Options sheet before converting (quality, size, bitrate, page range) with "remember" | Defaults are not always right |
| Finished-job notifications (UserNotifications) with Reveal / Open / Undo | HUD is easy to miss on long jobs |
| Undo last conversion (move outputs to Trash, restore replaced originals) | Safety net for "replace original" |
| Output location rules: add "ask each time", subfolder per batch, and per-category folders (images → Pictures) | Next-to-source / Downloads / custom exist already |

## 0.6 — macOS integration

| Item | Why |
|---|---|
| App Intents / **Shortcuts** actions: Convert, Run Tool, Run Action | Automation without the CLI |
| Finder Quick Actions (Action extension) and Share extension | Right-click convert in Finder and share sheets |
| Watch folders: auto-convert anything dropped into a folder with a preset | Hands-free pipelines |
| Drop zone on the Dock icon and a floating shelf window | Alternatives for trackpad users |
| Launch at login (SMAppService) toggle in Settings | Menu bar apps need it |

## 0.7 — More power

| Item | Why |
|---|---|
| PDF: annotate, reorder/rotate pages with thumbnails, compress with quality levels, OCR to searchable PDF (Vision) | Most requested PDF features |
| Images: batch rename, strip/edit EXIF, background removal (Vision), upscale | Common "tools" category asks |
| Media: extract audio, make GIF from a time range with a preview scrubber, burn subtitles, split by chapters | Builds on existing FFmpeg recipes |
| User recipes: shell-command edges in `~/Library/Application Support/Kumquat/recipes` added to the graph | Extensibility without code changes |
| Conversion queue window: pause/resume, reorder, retry failed, per-file progress | Large batches need visibility |

## 0.9 — Packaging

| Item | Why |
|---|---|
| Homebrew cask in a personal tap (`brew install --cask scorpionTaj/tap/kumquat`), updated by the release workflow; the cask removes the quarantine flag on install | One-line install and `brew upgrade` |
| `kumquat-cli` formula in the same tap | CLI users don't need the app |
| Release workflow polish: delta updates for Sparkle, smaller DMG (strip symbols, compress with lzfse) | Keep downloads tiny |

## 1.0 — Polish & release

| Item | Why |
|---|---|
| Localisation (String Catalogs): English, French, Arabic (RTL check), Spanish, German | Wider audience |
| Accessibility pass: VoiceOver labels on wheel slices, keyboard navigation of the wheel, Reduce Motion, contrast in every theme | Required for a 1.0 |
| Onboarding window on first launch (how the drag-and-tap works, engine setup, permissions) | Core gesture isn't discoverable |
| Settings redesign with search; import/export settings & presets | Settings have grown |
| UI tests (XCUITest via an Xcode project wrapper) for wheel, HUD, settings; snapshot tests for themes | Core UI is untested today |
| Performance budget: wheel opens < 50 ms, idle CPU ~0%, memory < 60 MB; checked in CI | Menu bar apps must be invisible |
| Website / GitHub Pages with docs, format matrix, changelog | Somewhere to send people |

## Housekeeping (any time)

- Keep `CHANGELOG.md` `[Unreleased]` filled as features land; releases use it automatically.
- Raise test coverage on engines that need external tools by running them in CI with Homebrew helpers.
- Consider making the repository public: macOS GitHub Actions minutes are free for public repos, and a public tap is needed for Homebrew.
