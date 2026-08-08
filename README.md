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

Phases 0–5 are done: the viewer, selection/crop, and all three providers (Anthropic API, Claude subscription via the Claude Code CLI, DeepSeek) are implemented, with 162 unit tests. The subscription path has been verified live; the two API paths are code-complete with their live cache-hit criteria still unverified. Phase 6 (history, OCR, notarized build) is next — see the phase list in [PLAN.md](PLAN.md).

Chat answers render block-level Markdown **and LaTeX** — headings, nested lists, tables, blockquotes, and syntax-highlighted code fences, with inline math flowing within the sentence and display math on its own block ([screenshot](docs/latex-rendering.png)). The design notes, including why blocks must be cut before math and math before Markdown, are in [PLAN.md §6](PLAN.md).

## Asking about the document

- **Text** — select text in the PDF, then ⌘L (or the toolbar's *Ask about Selection*). The snippet appears above the chat input and is attached to your next question.
- **Region** — ⌘⇧A, then drag a rectangle around a figure, table, or equation. Esc or a click cancels. The crop is exported as a 2× PNG (long edge capped at 1600 px) and any text underneath it is captured too, so text-only providers still get something to read.

## Dark mode

The chrome has always followed the system; **the pages do too** ([screenshot](docs/dark-mode.png)). ⇧⌘D toggles it, and *Settings → Appearance* chooses between *Match system*, *Always light*, and *Always dark* — the toolbar toggle picks a side explicitly, so a document you have darkened by hand does not flip back at sunrise. Thumbnails follow the pages.

Pages are inverted with a Core Image filter on the view layer, not by overriding `PDFPage.draw`: `CropRenderer` draws through that same call, so an override would invert every region screenshot on its way to a provider. So a **crop is always sent — and shown in its chat card — as the document authored it**, light background and all, even while you are reading dark. The model gets the original; only the screen changes.

The inversion is deliberately not full-range. Paper lands at **15/255** and ink stops at **200/255** rather than going pure black under pure white, which is a glare source rather than a night mode; the same map tones down saturated figures. Three details the obvious implementation gets wrong, each measured off the running app rather than reasoned about:

- **Do the arithmetic in the right space.** Core Image works in linear light, where `1 − x` leaves a 0.9 grey panel at 145/255 — a glaring mid-grey — instead of 40. The invert sits between an sRGB tone-curve pair so it happens in the space the colours were authored in.
- **Use the real sRGB curve, not a 2.2 power approximation.** The two diverge most near black, which is exactly where the paper level lives: approximating put paper at 4/255 instead of 15.
- **Compensate the endpoints.** Core Image's tone-curve pair is not quite an exact inverse, so the target levels handed in straight render as 18/210. `PDFAppearanceTests` asserts the *rendered* levels, so the tuning is checked against the spec rather than against the constants.

A 180° hue rotation after the invert keeps a blue figure blue rather than turning it orange, and the ⌘F highlight is picked for what it looks like *after* the filter (`systemYellow` would arrive as a muddy 109/98/0 olive).

Photographs come out as negatives — a known limitation of inverting the page wholesale, and the reason the setting has an *Always light* escape hatch.
