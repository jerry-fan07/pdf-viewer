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

Phases 0–5 are done: the viewer, selection/crop, and all three providers (Anthropic API, Claude subscription via the Claude Code CLI, DeepSeek) are implemented, with 153 unit tests. The subscription path has been verified live; the two API paths are code-complete with their live cache-hit criteria still unverified. Phase 6 (history, OCR, notarized build) is next — see the phase list in [PLAN.md](PLAN.md).

Chat answers render block-level Markdown **and LaTeX** — headings, nested lists, tables, blockquotes, and syntax-highlighted code fences, with inline math flowing within the sentence and display math on its own block ([screenshot](docs/latex-rendering.png)). The design notes, including why blocks must be cut before math and math before Markdown, are in [PLAN.md §6](PLAN.md).

## Asking about the document

- **Text** — select text in the PDF, then ⌘L (or the toolbar's *Ask about Selection*). The snippet appears above the chat input and is attached to your next question.
- **Region** — ⌘⇧A, then drag a rectangle around a figure, table, or equation. Esc or a click cancels. The crop is exported as a 2× PNG (long edge capped at 1600 px) and any text underneath it is captured too, so text-only providers still get something to read.
