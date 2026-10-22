# Contributing to Kumquat

## Layout

```
Sources/KumquatCore/        formats, conversion graph, catalog, converter, engines
  Engines/                  one file per engine family
Sources/Kumquat/            the menu bar app (AppKit + SwiftUI settings)
Sources/KumquatCLI/         kumquat-cli
Tests/KumquatCoreTests/     unit + integration tests
scripts/                    build-app.sh, make-icon.swift
docs/PLAN.md                product & engineering plan
```

## Workflow

```bash
swift build
swift test
scripts/build-app.sh && open build/Kumquat.app
```

Kumquat targets macOS only (13 Ventura or later), so use Apple frameworks freely. Keep pure logic
(argument builders, parsers, routing) separate from engine code, so it can be unit-tested without real
files or helpers.

## Adding a conversion

1. If an existing engine can already do it, add an edge in `StandardEdges.make()` (`ConversionGraph.swift`).
   Multi-step routes come for free.
2. If the format is new, declare it in `Format.swift` and add it to the right group and `FormatRegistry.all` ordering.
3. Make sure `TargetPolicy` allows the pair.
4. Add a test (`ConversionGraphTests` for routing, an engine integration test for behaviour).

## Adding a tool

Add a case to `ToolID` (title, detail, symbol, suffix, applicability), implement it in the engine's
`runTool`, and route it in `ToolRunner`.

## Style

Match the surrounding code: small types, doc comments on anything non-obvious, no force-unwraps on user
data, and errors that tell the user what to do next.
