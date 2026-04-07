---
name: managing-memories
description: Covers the full memory lifecycle — when to save, what format to use, how to organize and deduplicate, how to recall relevant memories, and what to never persist. Use at natural breakpoints to capture user preferences, corrections, and project conventions, and at session start to load relevant context.
---

# Managing Memories

Extract persistent memories at natural breakpoints, not mid-chain.

## When to extract

Extract when ALL conditions are met:
- **Volume threshold**: substantial conversation has occurred (roughly 10+ back-and-forth exchanges or significant work completed)
- **Natural pause**: task completed, waiting for user input, or session ending
- **Novelty**: something worth remembering that isn't already captured
- **No pending work**: the last assistant turn has no in-progress tool calls or unfinished chains

Do NOT extract:
- Mid-chain (during active multi-step implementation or debugging)
- After trivial exchanges (quick questions, one-liners, status checks)
- When the information is already in project instruction files or existing memories
- When the conversation is primarily about information retrieval (reading files, answering questions) with no decisions or corrections

## Memory types

Each memory file uses YAML frontmatter + markdown body. The body for corrections and project conventions must include **Why** (context) and **How to apply** (actionable rule).

### User preferences — working style, communication style, role
```yaml
---
name: prefers-minimal-comments
description: User wants no code comments unless explaining non-obvious why
type: user
---
No narrating comments. Only trade-offs, constraints, workarounds.
```

### Corrections — explicit user corrections of agent behavior
```yaml
---
name: use-pnpm-not-npm
description: Project uses pnpm exclusively, user corrected agent when npm was used
type: correction
---
Always use pnpm for package operations.
**Why:** Project has pnpm-lock.yaml. Using npm creates conflicting lock files and breaks CI.
**How to apply:** Replace `npm install` → `pnpm install`, `npm run` → `pnpm run`, `npx` → `pnpm exec`.
```

### Project conventions — architecture decisions, standards, processes
```yaml
---
name: api-error-format-rfc7807
description: All API errors must use RFC 7807 Problem Details format
type: project
---
Error response shape: `{ type, title, status, detail, instance }` per RFC 7807.
**Why:** Frontend error handling depends on this format. Inconsistent errors break the error boundary.
**How to apply:** Use the project's error helper to construct responses. Never return bare `{ message }` objects.
```

### References — pointers to external systems and resources
```yaml
---
name: team-grafana-dashboard
description: Production monitoring dashboard link for the auth service
type: reference
---
Auth service dashboard: https://grafana.internal/d/abc123
On-call runbook: https://wiki.internal/auth-oncall
```

## Session memory (short-term)

Distinct from persistent memories. Session memory captures key facts from the current conversation for use in compaction recovery and context continuity.

**When to capture session memory:**
- After substantial work (roughly 10K tokens of conversation) AND 3+ tool calls
- At natural breakpoints — task completed, waiting for input, not mid-chain
- Not after trivial exchanges or pure information retrieval

**What session memory contains:**
- Active task and current approach
- Key decisions made and why
- Files recently read or modified
- Errors encountered (exact messages)
- User corrections and preferences expressed during the session

**How it differs from persistent memory:**
- Scope: single session, not cross-session
- Lifetime: discarded when session ends (unless worth promoting to persistent memory)
- Purpose: survive compaction without losing operational context
- Storage: in-context or in a temp file, not in the memory directory

**Promote to persistent memory when:** a session-level observation is likely to be useful in future sessions (e.g., user corrected a recurring mistake, a project convention was discovered).

## Memory staleness

Annotate memories with age when loading them into context. Memories older than 1 day should include their age so the agent can weight recent memories more heavily and question stale ones.

Format: append `(last updated: 3 days ago)` or `(last updated: 2025-04-05)` to the manifest entry.

If a memory contradicts current evidence (e.g., a project convention that the codebase no longer follows), flag the contradiction rather than blindly following the memory. Stale memories are worse than no memory.

## Never save
- **Code patterns or architecture** — derive by reading the codebase (it changes; memories go stale)
- **Git history** — use `git log` / `git blame` (authoritative and current)
- **Debugging solutions** — the fix is in the code; the commit message has context
- **Anything already documented** in project instruction files or existing memories
- **Ephemeral task state** — in-progress work, temp context, conversation-specific details

## Updating vs. creating

Before creating a new memory, check if a related memory already exists:
- If an existing memory covers the same topic, **update it** (edit the file) rather than creating a duplicate
- If the new information contradicts an existing memory, **replace** the old one — do not keep both
- If the new information extends an existing memory, **append** to it

## Storage

All memories live in `.agent/memories/` at the project root. If the project already has an agent state directory (`.claude/`, `.cursor/memories/`, etc.), use the existing one.

```
.agent/memories/
├── MEMORY.md                  ← Index (max 200 lines)
├── use-pnpm-not-npm.md
├── prefers-minimal-comments.md
└── api-error-format-rfc7807.md
```

Create `.agent/` on first use. Add it to `.gitignore` unless the team wants shared agent state.

## Organization
- **One concept per file.** Short, specific, searchable.
- **Descriptions must be specific** enough for relevance selection: "User prefers Tailwind over CSS modules for styling" not "UI preference."
- **Keep the index** (`MEMORY.md`) with one-line summaries. Each line: `- [Title](file.md) — one-line description`. Under 200 lines.
- **File names** should be kebab-case and descriptive: `use-pnpm-not-npm.md`, not `correction-1.md`.

## References

For deeper implementation details, load these on demand:

- **[Secret scanner patterns](references/secret-scanner-patterns.md)** — 36 regex patterns for detecting credentials before persisting to shared memory. Scan at the write boundary.
- **[Memory recall prompt](references/memory-recall-prompt.md)** — LLM-based recall prompt template for selecting relevant memories from a store. Includes manifest format and pipeline.

## Scripts

- **[scan-secrets.sh](scripts/scan-secrets.sh)** — Portable bash script implementing the secret scanner. Pipe content or pass files/directories. Exit code 1 = secrets found. Returns rule IDs only, never matched text.
- **[memory-index.sh](scripts/memory-index.sh)** — Manage the MEMORY.md index: initialize, add entries (with duplicate detection), search, list, validate index-to-file consistency.
  - `./memory-index.sh init .agent/memories` — create directory and index
  - `./memory-index.sh add .agent/memories use-pnpm-not-npm "Project uses pnpm" correction` — add entry
  - `./memory-index.sh has .agent/memories use-pnpm-not-npm` — check if exists (exit 0=yes)
  - `./memory-index.sh search .agent/memories "pnpm"` — search index and contents
  - `./memory-index.sh validate .agent/memories` — check for orphans and missing files
