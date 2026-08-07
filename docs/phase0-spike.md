# Phase 0 spike results — subscription CLI path

Ran 2026-08-07 on this machine. Claude Code CLI **2.1.223** (`/opt/homebrew/bin/claude`), Xcode 26.6.

## What was tested

Sanitized child environment (`env -i` with only `HOME`/`PATH`/`USER`/`TERM` — the parent session exported `ANTHROPIC_BASE_URL` and `CLAUDE_CODE_*` vars that must not leak into the child). 3-page generated PDF with distinctive per-page facts + an 800×400 crop PNG of page 1.

| Step | Command shape | Result |
|---|---|---|
| Prime (attach) | `claude -p "Read the PDF at <path>. Reply only 'ready'." --output-format json --allowedTools Read --add-dir <dir>` | ✅ 20.7 s, session captured, 17,393 cache-write tokens, modeled cost $0.199 |
| Q1 (fork) | `claude -p "<question>" --resume <sid> --fork-session …` | ✅ 31.8 s, **correct page-2 fact, no PDF re-read** (45 cache-write / 33,360 cache-read tokens), $0.019 — ~10× cheaper than prime |
| Q2 (fork + image) | question referencing `crop.png` path, `--resume <sid> --fork-session` | ✅ 26.2 s, crop content correctly described, and **no knowledge of Q1** ("have I asked earlier questions?" → "No") |

## Findings (feed into §5.3 of PLAN.md)

1. **GO — and better than planned: `--fork-session` exists.** Every question resumes the primed per-document session with `--fork-session`, which branches into a *new* session ID and leaves the primed session untouched. This gives **strictly independent questions + cached PDF read** — the history-accumulation deviation in the original plan is eliminated. No "Reset context" action needed. *Parent immutability verified directly, not just inferred:* after both forked questions ran, the parent's transcript (`~/.claude/projects/<dir>/<sid>.jsonl`, 15 lines) contained only the prime ("ready") and zero occurrences of either question's text, while each fork's transcript contained only its own question.
2. **Subscription auth confirmed.** Child env had no API key; calls succeeded via the stored `claude` login, and the output stream contains a `rate_limit_event` (subscription limit tracking). `total_cost_usd` is the *modeled* API-equivalent cost, useful for the UI's cost indicator even though billing is subscription.
3. **Output shape (CLI 2.1.223):** `--output-format json` emits a **JSON array** of message objects (`system`, `rate_limit_event`, `assistant`, `user`, …) ending with a `type == "result"` object carrying `session_id`, `result`, `total_cost_usd`, `usage`, `modelUsage`. The provider parser must take the trailing `result` element, not assume a bare object. `stream-json` (NDJSON) is the shape to use in-app for live tokens.
4. **Latency is 20–32 s per question** at CLI defaults (Opus 5). Streaming output is mandatory for acceptable UX; expose `--model` and `--effort <level>` in settings as latency levers (both exist in this CLI version).
5. **Images work as file paths** — the crop PNG was read and described accurately via the Read tool. Write crops to a temp dir covered by `--add-dir`.

## Spike artifacts

Scratch-only (generated PDF/PNG and raw JSON transcripts lived in the session scratchpad; regenerate with the commands above if needed).
