# System Prompt Architecture

Detailed reference for building and optimizing the system prompt — the single highest-leverage component in an agentic system. Every design choice here affects cost, latency, accuracy, and behavioral consistency.

## Static/Dynamic Split

The system prompt is split into two zones by a cache boundary marker. Everything before the boundary is constant between turns; everything after changes per-turn.

```
┌──────────────────────────────────────┐
│         STATIC PREFIX                │  ← Cached by provider
│                                      │     (KV states reused across turns)
│  1. Identity and role                │
│  2. Behavioral rules                 │
│  3. Security directives              │
│  4. Tool preference hierarchy        │
│  5. Output style and tone            │
│  6. Action risk framework            │
│  7. Code review handling             │
│                                      │
│  ════ CACHE BOUNDARY ════            │
│                                      │
│         DYNAMIC SUFFIX               │  ← Rebuilt per turn
│                                      │     (each token here = cache miss)
│  8. Environment (CWD, OS, git, date) │
│  9. Loaded memories                  │
│ 10. Available tools/skills           │
│ 11. Project instruction overrides    │
│ 12. MCP server descriptions          │
│ 13. Language/locale preferences      │
│ 14. Context window budget            │
└──────────────────────────────────────┘
```

### Why this matters

LLM providers (Anthropic, OpenAI, Google) cache key-value states for prompt prefixes. When consecutive API calls share a byte-identical prefix, the provider skips recomputing those tokens — saving 80-90% of input processing cost and reducing latency significantly.

**Every token in the dynamic section invalidates the cache from that point forward.** Moving a single line from dynamic to static saves one cache miss per turn for the entire session.

### Design rules

1. **Stable content goes above the boundary.** If it doesn't change between turns, it belongs in the static prefix.
2. **Minimize the dynamic section.** Load only what's needed for this turn. Unused memories, inactive tool schemas, and stale environment data should not appear.
3. **Ordering within static matters.** Put the most important behavioral rules early — the model weights earlier tokens more heavily during attention.
4. **The boundary is a constant.** Define it as a named string (e.g., `__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__`) so tooling can reliably locate and split on it.
5. **Test cache hit rates.** Log whether the provider reports a cache hit. If cache misses spike, something is leaking into the static section or the boundary is moving.

## Prompt Layering and Precedence

Multiple instruction sources combine:

```
Priority (highest wins):
  1. Session override       ← Coordinator or task-specific directive
  2. Project instructions   ← AGENTS.md, CLAUDE.md, .cursorrules in project
  3. User preferences       ← User-level config or loaded memories
  4. Global defaults        ← The base system prompt (this document)
```

### Conflict resolution

- Later layers override earlier layers for the same directive.
- If a project instruction says "always use tabs" and the base prompt says "match project convention," the project instruction wins.
- Explicit negations override positives: "do NOT use semicolons" overrides an earlier "follow standard JS style."

### File-based instruction loading

Users place instruction files in their project. Loading rules:

- **Transitive includes**: Support `@include path/to/file.md` with a max depth (e.g., 5) and cycle detection.
- **Size limits**: Cap individual files (e.g., 40KB) to prevent prompt injection via enormous instruction files. HTML comments are stripped.
- **Scope**: Instructions in subdirectories apply only when working in that subtree. Root-level instructions always apply.

## Progressive Tool Loading

Front-loading all tool schemas wastes 15-20K tokens on tools the model may never use in a session.

### Pattern: Core + discoverable

1. Load ~10 core tools in the static prefix (read, write, edit, search, glob, shell, browser, etc.)
2. Provide a meta-tool (`searchTools`) that searches the full tool catalog by capability description
3. Each tool carries a `searchHint` — a 3-10 word capability description used for matching
4. When the model needs a capability not in the loaded set, it calls `searchTools("deploy to staging")` and gets back the relevant tool schema

### Benefits

- Saves 15-20K tokens per turn
- Reduces decision paralysis (40+ tools in a prompt overwhelms the model)
- New tools can be added without bloating the base prompt
- Tools that require specific permissions are only loaded when needed

## Sub-Agent Prompt Optimization

When spawning sub-agents (workers):

### Fork mode (cache-sharing)

If a sub-agent inherits the parent's full conversation context, the API request prefix is byte-identical to the parent's. The provider serves cached KV states for the entire parent context — making sub-agents extremely cheap (only the per-child directive is "new" computation).

### Independent mode

If a sub-agent gets a fresh prompt:
- Reuse the same static prefix as the parent (to share cache)
- Include only the task-specific context in the dynamic section
- Strip conversation history — the worker prompt must be self-contained

### Type-specific prompts

Different agent types get different tool pools and instructions:
- **Research agents**: Read-only tools. "Report findings. Do not implement."
- **Implementation agents**: Full tool access. Specific file paths and scope boundaries.
- **Verification agents**: Read-only tools + test runners. "Try to break it. Do not modify project files."

## Context Window Budget

Track token consumption and set thresholds:

| Metric | Threshold | Action |
|--------|-----------|--------|
| System prompt | < 25% of context | If exceeded, reduce tool schemas or memory |
| Conversation history | 70% of remaining | Trigger compaction |
| Tool results | Budget per result | Truncate large outputs |
| Total utilization | > 85% | Mandatory compaction with structured summary |

### Budget allocation strategy

```
Total context window (e.g., 200K tokens)
├── System prompt:     ~30K  (static ~20K + dynamic ~10K)
├── Conversation:      ~140K (history + tool results)
├── Output reserve:    ~25K  (model's response space)
└── Safety margin:     ~5K   (overhead, formatting)
```

Adjust dynamically: if conversation history is short, allow more tool results. If many tools are loaded, reduce memory content.

## Speculative Execution

Use idle time productively. After the agent completes a turn, predict what the user will likely ask next and pre-execute it.

### Pipeline

```
1. Post-turn: generate next-prompt prediction via lightweight side-query
2. Spawn isolated agent to execute the predicted prompt
3. All file writes go to a copy-on-write overlay — never the real workspace
4. Execution halts at the first operation that requires user permission
5. If the user accepts the prediction → copy overlay files to workspace
6. If the user rejects → discard overlay, no effect
7. While waiting for acceptance → generate next prediction (pipeline)
```

### Safety invariants

- **Copy-on-write isolation is mandatory.** Speculative writes must never touch the real workspace until accepted.
- **Permission boundary halts execution.** If the speculative agent would need user approval for an operation, stop — do not guess.
- **Rejection is free.** Discarding a speculation has no side effects. This makes speculation low-risk.

### When to speculate

- After completing a multi-step task where the next step is predictable
- After answering a question where a follow-up action is likely
- NOT when the user's intent is ambiguous or the next step could go multiple directions

### Cost considerations

Speculative execution trades compute for latency. It's most valuable when:
- The predicted next step is highly likely (> 70% confidence)
- The next step is expensive (file changes, test runs) and benefits from pre-computation
- The user is in an interactive flow with fast back-and-forth

## Anti-Patterns

- **Dumping everything in static**: Tool result schemas, user-specific preferences, and session state in the static section cause cache misses when any of them change.
- **No boundary at all**: Without an explicit boundary, the entire prompt is re-processed on every turn.
- **Unbounded dynamic growth**: Loading all memories, all tool schemas, and full environment state into dynamic makes it grow beyond budget.
- **Ignoring ordering**: Burying critical behavioral rules at the end of a 20K-token prompt weakens their effect.
- **Hardcoded tool lists**: Enumerating all tools in the static prompt prevents adding new tools without cache invalidation.
