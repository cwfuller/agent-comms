# Advisory carry-over

Un-actioned advisory findings from APPROVE-terminated review loops, so they survive
the loop's end (protocol v2 convention — see read-from-codex APPROVE branch).

## 2026-06-04 — thread `protocol-v2-9331` (PR 3, auto-implement, approved r3)

- **Manual-pickup state-key mismatch outside cmux** (v2.1 hardening candidate): without
  cmux, `send` keys thread state on the fallback (branch) workspace, which can diverge
  from a cmux-scoped message's filename prefix. Normal cmux-scoped sends key correctly,
  and message/archive paths stay correct either way — the gap is only that state lookups
  may miss. Proper fix: carry one workspace identity in state/frontmatter from loop start.
