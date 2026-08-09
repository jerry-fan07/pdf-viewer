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

All seven phases are done: the viewer, selection/crop, all three providers (Anthropic API, Claude subscription via the Claude Code CLI, DeepSeek), the polish pass — per-document history, per-answer cost, OCR for scanned pages, and an app icon — and live provider switching, with **278 unit tests**. The subscription path has been verified live; the two API paths are code-complete with their live cache-hit criteria still unverified (both need an API key).

Two things are deliberately not finished, both blocked on credentials rather than code: **notarization** (the Developer ID build is signed, hardened and verified — `Scripts/release.sh --notarize` submits and staples once `xcrun notarytool store-credentials` has run) and the **cache pre-warm knob**, which PLAN §7 asks to be verified against `claude-opus-5` before shipping. See the phase list in [PLAN.md](PLAN.md).

Chat answers render block-level Markdown **and LaTeX** — headings, nested lists, tables, blockquotes, and syntax-highlighted code fences, with inline math flowing within the sentence and display math on its own block ([screenshot](docs/latex-rendering.png)). The design notes, including why blocks must be cut before math and math before Markdown, are in [PLAN.md §6](PLAN.md).

## Asking about the document

- **Text** — select text in the PDF, then ⌘L (or the toolbar's *Ask about Selection*). The snippet appears above the chat input and is attached to your next question.
- **Region** — ⌘⇧A, then drag a rectangle around a figure, table, or equation. Esc or a click cancels. The crop is exported as a 2× PNG (long edge capped at 1600 px) and any text underneath it is captured too, so text-only providers still get something to read; when there is no text layer under the region, it is recognised with OCR rather than refused.

Each answer carries the provider and model that produced it, how much of its input was read from the cached document, and what it cost. Questions and answers are saved per document and restored when you reopen it — history is display-only and is never sent back to the model. The trash button in the panel header clears it.

**Switching provider** — the provider capsule at the top of the chat panel is a menu: pick another one and the open document re-prepares itself for it, no reopening. The transcript stays, and each card goes on naming whoever answered it, so a switch reads as a change of voice rather than a reset. Switching costs one fresh cache write on the next question; switching *back* to a provider this document is already prepared for is free. A change in Settings applies to open windows too — except to a window you have switched by hand, which keeps what you gave it. A region crop staged for Claude is re-read as text (or recognised with OCR) if you switch to a text-only provider. Preparing a large scanned document can be cancelled from the status line, and retried.

**Shortcuts:** ⌘F find (⌘G / ⇧⌘G next and previous, Esc clears) · ⌘L ask about the selection · ⇧⌘A region crop · ⇧⌘D dark mode · ⌥⌘I chat panel · ⌃⌘S thumbnails · ⌘− / ⌘0 / ⌘= zoom.

## Dark mode

**One switch moves a whole window** — toolbar, thumbnails, chat panel and the pages themselves ([screenshot](docs/dark-mode.png)). ⇧⌘D toggles it (a crescent moon in the toolbar, lit when it is on), and *Settings → Appearance* chooses what windows open as: *Match system*, *Always light*, or *Always dark*.

The toggle is **scoped to the window it is pressed in** — the same rule the provider picker follows. Darkening the paper you are reading at night does not reach across to the document on the other display, and Settings is the default a window starts from rather than a remote control for windows you have already steered. It also picks a side explicitly rather than returning to *Match system*, so a window you darkened by hand does not flip back at sunrise. That is also why the window override is applied with `preferredColorScheme` rather than `NSApp.appearance`: the latter is app-wide by construction.

*Match system* is the one mode that forces nothing, and it has to be — the window's colour scheme is where the page filter reads the system's answer from, so forcing it would make the answer its own input and a window dark once would never come back.

Chrome and pages were separate settings before, on the theory that a dark toolbar around white paper is the normal night-reading case. It isn't — it is a half-dark window. The cost of collapsing them is that *Always light* is now light everywhere, including at night: dark chrome around a light page is no longer reachable.

**The switch crosses rather than snaps.** A full page of paper going near-black in one frame is a flashbulb in reverse, so ⇧⌘D sweeps over 0.35s on a smoothstep curve — the pages and the thumbnail strip together ([the frames, at even progress](docs/dark-mode-sweep.png)). The filter chain takes a `progress` and scales towards the identity at 0, and a timer steps it per frame: the matrix rides in `CIVector`s, which Core Animation will not interpolate, so a `CABasicAnimation` on the filter's key paths would animate the hue angle alone and swing the colours around an un-inverted page. Only a switch made while the window is on screen sweeps — a window *opening* dark shows a dark page rather than fading one down from white. The toolbar and panels still change in one step, because `preferredColorScheme` is not an animatable property; the pages are what the eye was objecting to.

**A sunset takes longer than a keypress** — 0.6s against 0.35s. A pressed key wants its result promptly, since you asked and a slow answer reads as lag; a window going dark under a reader who didn't ask is the opposite case, and the eye is on the page rather than the toolbar while it happens. The two are told apart by whether the window was on *Match system* both before and after the change: that is the only way the pages can move without anybody touching the app. Both halves of that test matter — ⇧⌘D fails it because the toggle picks a side rather than following, and choosing *Match system* in Settings from *Always light* at night fails it because it is a decision just made, not a sunset.

Pages are inverted with a Core Image filter on the view layer, not by overriding `PDFPage.draw`: `CropRenderer` draws through that same call, so an override would invert every region screenshot on its way to a provider. So a **crop is always sent — and shown in its chat card — as the document authored it**, light background and all, even while you are reading dark. The model gets the original; only the screen changes.

The inversion is deliberately not full-range. Paper lands at **15/255** and ink stops at **200/255** rather than going pure black under pure white, which is a glare source rather than a night mode; the same map tones down saturated figures. Three details the obvious implementation gets wrong, each measured off the running app rather than reasoned about:

- **Do the arithmetic in the right space.** Core Image works in linear light, where `1 − x` leaves a 0.9 grey panel at 145/255 — a glaring mid-grey — instead of 40. The invert sits between an sRGB tone-curve pair so it happens in the space the colours were authored in.
- **Use the real sRGB curve, not a 2.2 power approximation.** The two diverge most near black, which is exactly where the paper level lives: approximating put paper at 4/255 instead of 15.
- **Compensate the endpoints.** Core Image's tone-curve pair is not quite an exact inverse, so the target levels handed in straight render as 18/210. `PDFAppearanceTests` asserts the *rendered* levels, so the tuning is checked against the spec rather than against the constants.

A 180° hue rotation after the invert keeps a blue figure blue rather than turning it orange, and the ⌘F highlight is picked for what it looks like *after* the filter (`systemYellow` would arrive as a muddy 109/98/0 olive).

Photographs come out as negatives — a known limitation of inverting the page wholesale, and the reason the setting has an *Always light* escape hatch. The answer-to-source flash keeps the system accent colour, which survives the filter as a blue wash rather than needing its own compensation.

## Releasing

`Scripts/release.sh` builds a Release configuration signed with a Developer ID certificate and the hardened runtime, then verifies the signature. `Scripts/release.sh --notarize` additionally submits the app to Apple and staples the ticket — that step needs App Store Connect credentials stored once with `xcrun notarytool store-credentials`. Distribution is outside the Mac App Store by necessity: the subscription provider spawns the user's `claude` CLI, which the App Sandbox does not permit.

The app icon is generated rather than checked in as opaque artwork — `swift Scripts/make-app-icon.swift ClaudePDF/Assets.xcassets/AppIcon.appiconset` redraws every size.
