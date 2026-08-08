# claude-pdf

A minimalist macOS PDF viewer with an AI side panel — highlight text or screenshot a region and ask questions about it, via your Claude subscription (Claude Code CLI), the Anthropic API, or DeepSeek.

- **Design & implementation plan:** [PLAN.md](PLAN.md)
- **Phase 0 spike results** (subscription CLI path, validated): [docs/phase0-spike.md](docs/phase0-spike.md)
- **Measured PDFKit coordinate behavior** (why crop conversion looks the way it does): [docs/phase2-geometry.md](docs/phase2-geometry.md)

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -project ClaudePDF.xcodeproj -scheme ClaudePDF build
xcodebuild -project ClaudePDF.xcodeproj -scheme ClaudePDF -destination 'platform=macOS' test
```

Or open `ClaudePDF.xcodeproj` in Xcode after generating. The project file is generated from [project.yml](project.yml) and not checked in. The only SPM dependency is [SwiftMath](https://github.com/mgriebling/SwiftMath), used to typeset LaTeX in chat answers.

Tests live in `Tests` and run against the app as their test host — no GUI automation, but the host means `MathRenderer` is exercised with the same font bundle the shipped app loads.

## Status

All seven phases are done: the viewer, selection/crop, all three providers (Anthropic API, Claude subscription via the Claude Code CLI, DeepSeek), the polish pass — per-document history, per-answer cost, OCR for scanned pages, and an app icon — and live provider switching, with **207 unit tests**. The subscription path has been verified live; the two API paths are code-complete with their live cache-hit criteria still unverified (both need an API key).

Two things are deliberately not finished, both blocked on credentials rather than code: **notarization** (the Developer ID build is signed, hardened and verified — `Scripts/release.sh --notarize` submits and staples once `xcrun notarytool store-credentials` has run) and the **cache pre-warm knob**, which PLAN §7 asks to be verified against `claude-opus-5` before shipping. See the phase list in [PLAN.md](PLAN.md).

Chat answers render block-level Markdown **and LaTeX** — headings, nested lists, tables, blockquotes, and syntax-highlighted code fences, with inline math flowing within the sentence and display math on its own block ([screenshot](docs/latex-rendering.png)). The design notes, including why blocks must be cut before math and math before Markdown, are in [PLAN.md §6](PLAN.md).

## Asking about the document

- **Text** — select text in the PDF, then ⌘L (or the toolbar's *Ask about Selection*). The snippet appears above the chat input and is attached to your next question.
- **Region** — ⌘⇧A, then drag a rectangle around a figure, table, or equation. Esc or a click cancels. The crop is exported as a 2× PNG (long edge capped at 1600 px) and any text underneath it is captured too, so text-only providers still get something to read; when there is no text layer under the region, it is recognised with OCR rather than refused.

Each answer carries the provider and model that produced it, how much of its input was read from the cached document, and what it cost. Questions and answers are saved per document and restored when you reopen it — history is display-only and is never sent back to the model. The trash button in the panel header clears it.

**Switching provider** — the provider capsule at the top of the chat panel is a menu: pick another one and the open document re-prepares itself for it, no reopening. The transcript stays, and each card goes on naming whoever answered it, so a switch reads as a change of voice rather than a reset. Switching costs one fresh cache write on the next question; switching *back* to a provider this document is already prepared for is free. A change in Settings applies to open windows too — except to a window you have switched by hand, which keeps what you gave it. A region crop staged for Claude is re-read as text (or recognised with OCR) if you switch to a text-only provider. Preparing a large scanned document can be cancelled from the status line, and retried.

**Shortcuts:** ⌘F find (⌘G / ⇧⌘G next and previous, Esc clears) · ⌘L ask about the selection · ⇧⌘A region crop · ⌥⌘I chat panel · ⌃⌘S thumbnails · ⌘− / ⌘0 / ⌘= zoom.

## Releasing

`Scripts/release.sh` builds a Release configuration signed with a Developer ID certificate and the hardened runtime, then verifies the signature. `Scripts/release.sh --notarize` additionally submits the app to Apple and staples the ticket — that step needs App Store Connect credentials stored once with `xcrun notarytool store-credentials`. Distribution is outside the Mac App Store by necessity: the subscription provider spawns the user's `claude` CLI, which the App Sandbox does not permit.

The app icon is generated rather than checked in as opaque artwork — `swift Scripts/make-app-icon.swift ClaudePDF/Assets.xcassets/AppIcon.appiconset` redraws every size.
