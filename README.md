# claude-pdf

A minimalist macOS PDF viewer with an AI side panel — highlight text or screenshot a region and ask questions about it, via your Claude subscription (Claude Code CLI), the Anthropic API, or DeepSeek.

- **Design & implementation plan:** [PLAN.md](PLAN.md)
- **Phase 0 spike results** (subscription CLI path, validated): [docs/phase0-spike.md](docs/phase0-spike.md)

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -project ClaudePDF.xcodeproj -scheme ClaudePDF build
xcodebuild -project ClaudePDF.xcodeproj -scheme ClaudePDF -destination 'platform=macOS' test
```

Or open `ClaudePDF.xcodeproj` in Xcode after generating. The project file is generated from [project.yml](project.yml) and not checked in. The only SPM dependency is [SwiftMath](https://github.com/mgriebling/SwiftMath), used to typeset LaTeX in chat answers.

## Status

Phases 0–5 are done: the viewer, selection/crop, and all three providers (Anthropic API, Claude subscription via the Claude Code CLI, DeepSeek) are implemented, with 65 unit tests. The subscription path has been verified live; the two API paths are code-complete with their live cache-hit criteria still unverified. Phase 6 (history, OCR, notarized build) is next — see the phase list in [PLAN.md](PLAN.md).

Chat answers render Markdown **and LaTeX** — inline math flows within the sentence, display math gets its own block ([screenshot](docs/latex-rendering.png)). The design notes, including why math must be segmented out before Markdown parsing, are in [PLAN.md §6](PLAN.md).
