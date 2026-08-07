# claude-pdf — Design & Implementation Plan

A minimalist, smooth macOS PDF viewer with an AI side panel: highlight text or screenshot a region of the document and ask questions about it. Supports **Claude via your Pro/Max subscription** (no API key), **Claude via the Anthropic API**, and **DeepSeek via its API**. The PDF is attached once per document and treated like a cached "project"; each question is an independent conversation that reuses that cached document context.

---

## 1. Platform & stack decision

**macOS app, SwiftUI + PDFKit. iOS is deferred.**

This is constraint-driven, not arbitrary: the subscription path works by driving the locally installed Claude Code CLI as a child process, which is only possible on macOS. PDFKit also gives us a production-quality, smooth-scrolling PDF renderer for free — building a custom renderer is explicitly out of scope.

- **Language/UI:** Swift 5.10+, SwiftUI app lifecycle, macOS 14+ target.
- **PDF rendering:** PDFKit (`PDFView` wrapped in `NSViewRepresentable`). No third-party PDF engine.
- **Networking:** `URLSession` directly (there is no official Anthropic Swift SDK; raw HTTPS + SSE is the supported path for Swift). No heavy dependencies — the app should build with zero or near-zero SPM packages.
- **Persistence:** SwiftData (or plain JSON files) for per-document chat history; Keychain for API keys.
- **Distribution:** Developer ID + notarization, **outside the Mac App Store**. This is forced by the headline feature: the subscription provider spawns the user's `claude` CLI and relies on its stored OAuth login, which the App Sandbox (required for MAS) does not permit. A sandboxed build would have to ship with the subscription provider disabled.

---

## 2. Architecture overview

```mermaid
flowchart LR
    subgraph UI
        V[PDFViewerView<br/>PDFKit] --> S[SelectionController<br/>highlight + region crop]
        C[ChatPanel<br/>streaming transcript]
    end
    S -->|Question + selection/crop| CE[ChatEngine]
    C <--> CE
    CE --> P{ChatProvider protocol}
    P --> A[AnthropicAPIProvider<br/>Messages API + Files API]
    P --> D[DeepSeekProvider<br/>OpenAI-compatible API]
    P --> K[ClaudeSubscriptionProvider<br/>Claude Code CLI child process]
    CE --> DOC[DocumentContext<br/>file_id / extracted text / session id]
```

### Module layout

```
ClaudePDF/
  App/                    // app entry, window, settings scene
  Viewer/                 // PDFView wrapper, thumbnails, toolbar
  Selection/              // text selection + rect screenshot overlay
  Chat/                   // chat panel UI, transcript, citation chips
  Engine/                 // ChatEngine, DocumentContext, history store
  Providers/
    ChatProvider.swift    // protocol + capabilities
    AnthropicProvider/    // Messages API, Files API, SSE parsing
    DeepSeekProvider/     // OpenAI-compatible client
    ClaudeCodeProvider/   // CLI process wrapper
  Support/                // Keychain, OCR (later), logging
```

### The provider abstraction

Abstract at the **ask** level, not the HTTP level — the subscription provider isn't HTTP at all, it's a child process.

```swift
struct ProviderCapabilities {
    let supportsVision: Bool        // can accept a cropped screenshot
    let supportsNativePDF: Bool     // can ingest the PDF file itself
    let supportsCitations: Bool     // returns page-anchored citations
}

protocol ChatProvider {
    var capabilities: ProviderCapabilities { get }

    /// Called once per opened document. Uploads / extracts / warms whatever
    /// this provider needs, and returns an opaque handle stored on DocumentContext.
    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment

    /// One independent question. Streams deltas back.
    func ask(_ question: Question, in doc: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
}

struct Question {
    var text: String
    var selectedText: String?       // from text highlight, with page number
    var regionImagePNG: Data?       // from rect screenshot (vision providers)
    var pageHint: Int?              // page the user is looking at
}

enum ChatEvent {
    case textDelta(String)
    case citation(pageNumber: Int, citedText: String)   // 1-indexed
    case usage(inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int)
    case done
}
```

Capability matrix at launch:

| | Vision (crop) | Native PDF | Citations → jump-to-page |
|---|---|---|---|
| Anthropic API | ✅ | ✅ (document block / Files API) | ✅ |
| Claude subscription (CLI) | ✅ (file path to crop PNG) | ✅ (Read tool on the PDF) | ❌ (prompted page numbers only, best-effort) |
| DeepSeek API | ❌ (public API is text-only as of Aug 2026) | ❌ (extracted text) | ❌ (best-effort) |

---

## 3. The viewer (minimalist & smooth)

PDFKit gives "smooth loading/scrolling" essentially for free — the work is restraint, not rendering.

- `PDFView` with `displayMode = .singlePageContinuous`, `autoScales = true`, `displaysPageBreaks = false` for a seamless scroll. PDFKit renders pages lazily and handles zoom/trackpad momentum natively.
- Open via drag-drop, `⌘O`, and Finder "Open With". Restore last scroll position per document.
- Chrome: a single thin toolbar (page indicator, zoom, search, "Ask" toggle) that can auto-hide; optional `PDFThumbnailView` sidebar behind a toggle. Respect system light/dark.
- Chat lives in a **trailing side panel** (`HSplitView` / inspector style), collapsible, so the document stays the hero.
- Search: `PDFDocument.findString` wired to `⌘F` with match highlighting (PDFKit built-in).

Explicit non-goals: annotations/editing, custom page-rendering pipeline, tabs (single window per document via the document architecture is enough).

---

## 4. Selection: highlight and region screenshot

Two input modes, both ending in a `Question`:

**A. Text highlight (default).** Use PDFKit's native text selection. On "Ask about selection" (context menu, `⌘L`, or a floating button near the selection):
- `pdfView.currentSelection` → `selection.string` plus the page number(s) from `selection.pages`.
- Optionally drop a temporary `PDFAnnotation` highlight so the user sees what the question is anchored to.
- The selection text + page number go into `Question.selectedText`.

**B. Region screenshot (for figures, tables, equations).** A crop mode toggled from the toolbar (or `⌘⇧A`):
- A transparent overlay `NSView` on top of the `PDFView` captures a drag rectangle.
- Convert view coords → page coords with `pdfView.convert(rect, to: page)`. *(Known fiddly spot: PDF page space is bottom-left origin and zoom-dependent — isolate all conversion in one tested helper.)*
- Render the crop by drawing the `PDFPage` into a `CGContext` clipped to the rect at **2× scale**, export PNG. Keep crops under ~1600 px on the long edge to control image-token cost.
- PNG goes into `Question.regionImagePNG`. For text-only providers (DeepSeek), also run `page.selection(for: rect)?.string` so there's a text fallback; if the region has no text layer, show "This provider can't see images — switch to Claude for visual questions."

---

## 5. Context model: "PDF cached like a project"

The user-visible model: **attach the document once; every question is a fresh, independent conversation that shares the document as a cached prefix.** No chat history is sent between questions (a later "thread mode" can opt into history).

The implementation per provider differs, but all three follow the same rule that makes caching work: **stable content first (frozen system prompt + document), volatile content last (the question, the crop).** A byte-identical prefix across questions is what turns the document into a "project."

### 5.1 Anthropic API path (the reference implementation)

*Why this provider exists at all (the request named subscription-Claude and API-other-model): it is the only path that returns real page-anchored citations, it is the cleanest expression of the caching model the other two approximate, and for users without a Pro/Max subscription it is the only way to reach Claude. It is also why it is built first — it de-risks the whole context design before the less-documented CLI leg.*

**Attach (once per document):**
1. Upload the PDF via the Files API — `POST /v1/files` with `anthropic-beta: files-api-2025-04-14` → keep `file_id`. (Upload once; never re-send PDF bytes per question.)
2. Optionally pre-warm the cache (see §7).

**Ask (every question, independent):**

```jsonc
POST /v1/messages   // headers: x-api-key, anthropic-version: 2023-06-01,
                    // anthropic-beta: files-api-2025-04-14
{
  "model": "claude-opus-5",            // default; picker also offers claude-sonnet-5 / claude-haiku-4-5
  "max_tokens": 16000,                 // Opus 5 thinks by default and thinking counts against this
  "output_config": { "effort": "medium" },   // latency lever; not part of the cached prefix
  "fallbacks": "default",              // re-serve a refused question instead of an empty bubble
  "stream": true,
  "system": [{ "type": "text", "text": FROZEN_SYSTEM_PROMPT }],   // never interpolate anything dynamic
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "document",
        "source": { "type": "file", "file_id": FILE_ID },
        "title": "<filename>",
        "citations": { "enabled": true },
        "cache_control": { "type": "ephemeral", "ttl": "1h" }     // ← the "project" cache breakpoint
      },
      // everything below the breakpoint varies per question and never invalidates the cache:
      { "type": "text", "text": "The user selected this on page 12: \"…\"" },   // if any
      { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": CROP } },  // if any
      { "type": "text", "text": USER_QUESTION }
    ]
  }]
}
```

Why this shape:
- **Prompt caching is a prefix match.** System prompt + document block are byte-identical on every question, so question 2..N read the document from cache (~0.1× input price) instead of re-processing it. The question/selection/crop sit *after* the `cache_control` breakpoint, so they never invalidate it.
- **First question** pays the cache write (2× at 1-hour TTL); every subsequent question within the TTL pays cache-read prices. Verify in `usage.cache_read_input_tokens` — if it's 0 on question 2, something is mutating the prefix (this is the #1 bug class; keep the system prompt literally a constant).
- **Citations** (`citations: {enabled: true}`) make responses return `page_location` citations (`start_page_number`, 1-indexed) attached to text blocks. Render each as a clickable chip in the chat panel that scrolls the `PDFView` to that page — the single strongest product feature for a PDF reader, nearly free.
- **Streaming:** parse SSE `content_block_delta` events — `text_delta` for text, `citations_delta` for citation attachments. Surface tokens immediately.
- Handle `stop_reason == "refusal"` before reading content (Opus 5 safety classifiers), and surface a readable error rather than an empty bubble. `"fallbacks": "default"` (beta `server-side-fallback-2026-07-01`) additionally lets the API re-serve a refused question on its recommended fallback model; drop the parameter and the beta together to disable.
- **Adaptive thinking is on by default on Opus 5** and its tokens count against `max_tokens`, so the cap is 16000, not 4096. `thinking` is left unset; `display` defaults to `"omitted"`, so the stream carries empty `thinking` blocks — the SSE parser must skip unknown block/delta types (`thinking_delta`, `signature_delta`, `ping`, `fallback`) rather than switch exhaustively.

**Model default:** `claude-opus-5` (current Opus, $5/$25 per MTok). Settings expose `claude-sonnet-5` (cheaper) and `claude-haiku-4-5` (cheapest, 200K context / 100-page doc cap).

### 5.2 DeepSeek API path

OpenAI-compatible endpoint at `https://api.deepseek.com/chat/completions`. Current models: **`deepseek-v4-flash`** (default: $0.14/M input miss, **$0.0028/M cache hit**, $0.28/M output) and `deepseek-v4-pro`. The legacy `deepseek-chat` alias is deprecated (July 2026) — don't ship it.

- **Attach:** extract the full text with PDFKit (`page.string` per page), annotated with page markers: `[Page 12]\n…`. Store as the document prefix. If the PDF has no text layer (scanned), offer OCR via Apple's Vision framework (`VNRecognizeTextRequest`) as a later phase; until then, suggest the Claude provider.
- **Ask:** every question sends `[system prompt][full annotated text]` as the stable prefix and the question last. **DeepSeek's context caching is automatic on repeated prefixes** — no cache parameters at all. The identical-prefix discipline alone gives project-like economics (~50× cheaper input on hits).
- **Region questions:** text-only — send the extracted selection text with its page number. Image crops are unsupported (DeepSeek's public API has no vision as of Aug 2026); the UI degrades as described in §4.
- 1M-token context covers most documents; for very large ones, warn and truncate to a page range around the user's current page (with an explicit indicator), rather than silently clipping.

### 5.3 Claude subscription path (Claude Code CLI)

**Decision: spawn the locally installed Claude Code CLI in headless mode as a child process, using the user's existing `claude` login.** This is the only sanctioned way to drive Claude on subscription auth from a non-SDK language; the app stores no credential. Alternatives considered: an Agent SDK sidecar (a Node/Python process the app would have to bundle and talk to — same auth store, more moving parts) and `CLAUDE_CODE_OAUTH_TOKEN` against the raw Messages API (undocumented and likely against ToS — do not build on it).

**Attach (once per document, at open):** prime a per-document session so the PDF read happens up front — matching the `attach()` contract, the "cached at the start" model, and keeping the slow read off the first question's latency:

```bash
claude -p "Read the PDF at <path>. Reply only 'ready'." \
  --output-format json \
  --allowedTools "Read" \
  --add-dir <folder containing the PDF>
# response JSON carries session_id and cost_usd — persist session_id per document
```

(One upfront read is wasted if the user never asks a question — acceptable default, with a "lazy attach" setting if it bothers anyone.)

**Ask (every question):** *fork* the primed per-document session — the cached PDF read is reused **and** each question is strictly independent (validated in the Phase 0 spike, see [docs/phase0-spike.md](docs/phase0-spike.md)):

```bash
claude -p "<next question>" --resume <primed_session_id> --fork-session \
  --output-format stream-json --allowedTools "Read"
# --fork-session branches into a NEW session id; the primed session is never mutated,
# so every question starts from the same post-attach snapshot. Verified: forked questions
# have no knowledge of each other, answer from cache (~10× cheaper than the prime), and
# do not re-read the PDF.
```

Mechanics that matter:

- **Auth:** after the user runs `claude` login once, headless calls use subscription OAuth automatically. **Sanitize the child environment** — an inherited `ANTHROPIC_API_KEY` silently takes precedence in `-p` mode and would misbill to the API key. **Never pass `--bare`** (it disables OAuth credential reading); Anthropic has signaled bare may become the `-p` default in a future release, so pin/check the CLI version and keep `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` (1-year subscription token, Pro/Max+) as the migration path *within Claude Code* if that lands.
- **Files:** the PDF and any crop PNG are handed over as local paths in the prompt; Claude ingests them via its Read tool (images natively; PDFs whole up to 10 pages, in ≤20-page ranges up to 1000 pages, text-only beyond). Write crops to a temp folder covered by `--add-dir`.
- **Caching / "project" semantics:** Claude Code requests the 1-hour cache TTL on subscription automatically. Prime once per document, then `--resume <primed> --fork-session` per question: follow-ups reuse the cached document read, pay mostly for the new question (spike measured ~10× cheaper than the prime), and stay independent of each other — matching the other providers exactly. After ~1 hour idle, the next fork re-processes the primed history uncached — same economics caveat as §7.
- **Streaming:** parse the newline-delimited `stream-json` output into `ChatEvent`s (assistant text deltas → `textDelta`; final result object → `usage`/`done`). Note the `--output-format json` envelope in CLI 2.1.x is a JSON *array* whose last element is the `type:"result"` object — parse accordingly. Support cancellation by terminating the child process. Per-question latency at CLI defaults is ~20–30 s (spike-measured) — stream tokens immediately and expose `--model`/`--effort` as latency levers in settings.
- **Onboarding/errors:** detect the CLI (`which claude`, version check) and the login state; walk the user through install/login instead of failing opaquely. Surface subscription rate-limit messages verbatim.

**Terms of service posture (as of Aug 2026):** using *your own* subscription via the CLI/Agent SDK in an app you run yourself is within policy. What is **not** allowed without Anthropic approval is offering claude.ai login or subscription rate limits to *your* users — so the app ships as "bring your own Claude Code install," with no "Sign in with Claude" UI. Note the policy is in flux: Anthropic announced a billing restructure for third-party Agent SDK usage in May 2026 and paused it on June 15, 2026, promising notice before changes. Treat this as a monitored risk (§9).

---

## 6. Chat panel UX

- Right-side collapsible panel; input field pinned at bottom; each Q&A rendered as an independent card (matching the independent-context model — no fake "conversation" affordance in v1).
- Every card shows its anchor: the highlighted snippet or crop thumbnail it was asked about, plus provider/model badge.
- Streaming text with Markdown rendering (headings, code, lists — via `AttributedString(markdown:)` or a small renderer).
- Citation chips (Anthropic path): `p. 12` chips that scroll the viewer and flash-highlight the cited region's page.
- Per-document history persisted locally; reopening a document restores its Q&A cards (history is display-only — it is never re-sent to the model).
- A subtle per-answer cost/cache indicator (e.g. "97% cached") built from `usage` — it makes the caching model legible and catches cache-busting regressions.

---

## 7. Limits, economics, and fallbacks (stated up front)

- **Anthropic native PDF caps: 32 MB request size / 600 pages** (100 pages on 200K-context models like Haiku). Over the cap → fall back to extracted-text mode (same as the DeepSeek path but on Claude), or offer a page-range selection.
- **The cache is not permanent.** "Cached like a project" means *cached for the TTL*: 1-hour ephemeral cache, refreshed on each hit. After a long idle, the next question re-pays a cache write (2× input for the doc at 1h TTL). The cost indicator in §6 makes this visible. Optional knob: **pre-warm on open** (a `max_tokens: 0` request that writes the cache before the first question) for users who prioritize first-answer latency over the extra write — *verify this works on `claude-opus-5` (always-on adaptive thinking) before shipping the knob; the documented rejection list doesn't cover it.*
- **Cache-read ≠ free:** a 300-page PDF is ~100K+ tokens; even at 0.1× that's real money per question on Opus. The model picker + DeepSeek option are the cost levers; show estimated per-question cost in settings.
- **Scanned PDFs** (no text layer): fine on Anthropic (vision reads them natively); DeepSeek path requires the OCR phase.
- **Keys & privacy:** API keys live in the Keychain (never UserDefaults, never logged). Subscription path stores nothing. All history stays local. Note in onboarding that documents are sent to the selected provider.

---

## 8. Implementation phases

Ordered by risk: the least-documented leg (subscription/CLI) gets a validation spike **first**, in parallel with the viewer, not last.

**Phase 0 — Subscription-path spike: ✅ DONE (2026-08-07, GO).** Results in [docs/phase0-spike.md](docs/phase0-spike.md). Subscription auth confirmed headless; `--fork-session` exists and works, so the default mode is **prime once + fork per question** (strict independence + cache reuse, no deviation); crop PNGs ingest via file paths; per-question latency ~20–30 s at defaults (streaming mandatory); `--output-format json` emits an array envelope in CLI 2.1.x.

**Phase 1 — Viewer shell: ✅ DONE (2026-08-07).** Document-based app; PDFView with continuous seamless scroll; toolbar with thumbnail-sidebar toggle, zoom in/out/fit (⌘−/⌘0/⌘=), page indicator with type-to-jump, ⌘F search (debounced, highlighted matches, ⌘G/⇧⌘G navigation, Esc clears); per-document scroll restore via UserDefaults. Machine-verified: clean build; 250-page PDF opens and renders (smoke-tested); restore round-trips to the saved page (seeded page 42, confirmed via defaults round-trip and visually — [docs/phase1-viewer.png](docs/phase1-viewer.png)). Pending a 60-second human pass: search interaction (⌘F focus → type → ⌘G/⇧⌘G → Esc), thumbnail toggle, type-to-jump, and the "scrolls at 120 Hz" feel criterion. Search on very large documents is synchronous/debounced — switch to `beginFindString` if typing ever hitches.

**Phase 2 — Selection & crop: ✅ DONE (2026-08-07).** Text-selection ask flow: "Ask About Selection" in the PDF context menu + ⌘L stage the selection as a removable chip in the composer (live selection still auto-attaches at submit). Region crop mode (toolbar toggle / ⇧⌘A, Esc cancels): drag-rect overlay → page-space conversion → 2× PNG capped at 1600 px + region-text fallback → crop chip with thumbnail; crops render in answer cards with their page badge. Machine-verified: clean build; **6/6 unit tests pass** (`Tests/CropTests.swift`: render dimensions at 2×, long-edge cap, degenerate-rect rejection, view↔page round-trip at 0.5×/1×/2× zoom, end-to-end `makeCrop` at two zooms, tiny-rect rejection) — the "correct `Question` from any zoom level" exit criterion. Pending a manual pass: drag feel, context-menu flow, chip UX. Known limitations (documented in code): rotated pages aren't handled by the crop renderer yet, and a drag spanning two pages clamps to the midpoint's page.

**Phase 3 — Anthropic provider + chat panel: ✅ CODE COMPLETE (2026-08-07), live exit criteria unverified.** Files API upload (multipart, `file_id` cached per file in UserDefaults so reopening never re-sends bytes); streaming Messages client over `URLSession.bytes` with a permissive SSE decoder; prompt-cache-correct request builder (frozen system prompt + document block carrying `citations` and `cache_control` 1h, everything volatile after the breakpoint); `citations_delta` → deduped per-page chips that scroll the viewer; attach-in-progress state and a per-answer "% cached" indicator; model picker in Settings (Opus 5 / Sonnet 5 / Haiku 4.5) with the page cap enforced at attach. Machine-verified: clean build; **24/24 unit tests pass** — 8 in `Tests/AnthropicRequestTests.swift` (cached prefix byte-identical across two very different questions, document block first and sole, citations + 1h TTL present, PDF bytes never in the request, volatile content strictly after the breakpoint, frozen system prompt across documents and models) and 10 in `Tests/AnthropicStreamTests.swift` (text/citation deltas, usage totals monotonic, `.usage` + `.done` at `message_stop`, thinking/ping/fallback/unknown events skipped, malformed payload skipped, `error` event throws, refusal category surfaced, multipart body shape). **The two stated exit criteria need a live API key and are NOT yet verified**: question 2 showing non-zero `cache_read_input_tokens` (the UI's "% cached" line reads it), and a citation chip scrolling to the cited page. Known limitations: the provider is chosen at document-open and fixed for the window (changing the model in Settings applies to documents opened afterwards); over-cap documents fail at attach with a readable error rather than falling back to extracted text (that machinery arrives with Phase 4).

**Phase 4 — DeepSeek provider:** page-annotated text extraction, OpenAI-compatible streaming client, capability-based UI degradation for crops. *Exit: repeated questions show DeepSeek cache hits; crop mode cleanly redirects.*

**Phase 5 — Claude subscription provider:** CLI detection/onboarding, process wrapper with streamed JSON parsing, file handoff, cancellation, error surfaces (not installed / not logged in / rate-limited). *Exit: with no API key configured, the full highlight→ask→answer loop works on a subscription account.*

**Phase 6 — Polish:** per-document history store, cost indicators, pre-warm knob, OCR for scanned PDFs, keyboard shortcuts, app icon, notarized build.

---

## 9. Risks & open questions

| Risk | Mitigation |
|---|---|
| Claude Code CLI flags/behavior change between releases — in particular, `--bare` (which disables subscription OAuth) may become the `-p` default | Pin/check a minimum CLI version at launch; never pass `--bare`; keep `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` as the fallback credential path; integration test against the installed CLI |
| Subscription-use ToS is in flux (billing restructure announced May 2026, paused June 15, 2026) | Personal-use, BYO-Claude-Code framing; no "Sign in with Claude" UI; monitor Anthropic announcements before any distribution |
| Cache silently busted by a request-builder change | The `usage`-based cache indicator doubles as a regression alarm; unit-test that request prefixes are byte-identical across questions |
| Coordinate-conversion bugs in crop mode | Single conversion helper + unit tests across zoom/rotation cases |
| Very large PDFs exceed native-PDF caps or make even cached questions expensive | Page-range mode + extracted-text fallback + visible cost estimates |
| DeepSeek ships vision later | Capability flags are data, not code paths — flip `supportsVision` when their API documents image input |
