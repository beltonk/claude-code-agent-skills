# Claude Code — Master Architecture Dossier

---

## Table of Contents

1. [Orchestration and Control Loops](#1-orchestration-and-control-loops)
2. [Tooling and Integration Layer](#2-tooling-and-integration-layer)
3. [Memory Architecture](#3-memory-architecture)
4. [Reasoning and Self-Correction](#4-reasoning-and-self-correction)
5. [Autonomy and Background Operation](#5-autonomy-and-background-operation)
6. [Configuration and Policy](#6-configuration-and-policy)
7. [Telemetry, Metrics, and Feedback](#7-telemetry-metrics-and-feedback)
8. [Security and Safety Controls](#8-security-and-safety-controls)
9. [Cross-Cutting Observations](#9-cross-cutting-observations)

---

## 1. Orchestration and Control Loops

### 1.1 Entry Points and Bootstrap

Claude Code uses a three-stage entry sequence that prioritizes startup latency by parallelizing expensive I/O with module loading.

| Stage | File | Responsibility |
|-------|------|----------------|
| CLI dispatch | `src/entrypoints/cli.tsx` | Fast-path exit for `--version`, `--dump-prompt`, `--remote-control`, `--daemon`. Avoids loading the full CLI if not needed. |
| Main bootstrap | `src/main.tsx` | Module-level side effects launch MDM read (~135ms) and Keychain prefetch (~65ms) **in parallel** with import resolution. |
| REPL launcher | `src/replLauncher.tsx` | Thin wrapper that lazy-imports the `App` component and REPL module, then calls `renderAndRun()`. |

The fast-path dispatch in `cli.tsx` checks a small set of flags before any heavy import. This avoids paying the full module graph cost for trivial operations like `--version`.

`main.tsx` uses top-level `Promise.all`-style parallelism (MDM read + Keychain prefetch) so that by the time the import graph settles, the slowest I/O is already complete or nearly so.

`replLauncher.tsx` is intentionally thin — it exists solely to defer the `App` and REPL imports behind a dynamic `import()`, keeping the critical path short.

### 1.2 QueryEngine — Turn Lifecycle Manager

**File:** `src/QueryEngine.ts`

The `QueryEngine` class owns the per-session conversation state and acts as the turn-level orchestrator. It is the boundary between the UI layer and the query pipeline.

**Private state:**

| Field | Type | Purpose |
|-------|------|---------|
| `mutableMessages` | `Message[]` | Conversation history, mutated in-place across turns |
| `abortController` | `AbortController` | Per-turn cancellation propagation |
| `permissionDenials` | `PermissionDenial[]` | Accumulated denial records for the session |
| `totalUsage` | Usage accumulator | Token/cost tracking across turns |
| `readFileState` | `FileStateCache` | Deduplication and mtime tracking for file reads |
| `discoveredSkillNames` | `Set<string>` | Skills encountered during current turn (cleared per-turn) |
| `loadedNestedMemoryPaths` | `Set<string>` | Memory files already injected into context |

All of these fields are class-private and mutated across the turn lifecycle.

**Core method — `submitMessage(prompt, options)`:**

Returns an `AsyncGenerator<SDKMessage>`, making it the turn entry point for both the interactive REPL and the SDK.

**Per-turn flow:**

```
1. Clear discoveredSkillNames (reset per turn)
2. fetchSystemPromptParts() — assemble system prompt
3. processUserInput() — preprocess user message
4. Persist transcript snapshot
5. Enter queryLoop() — the core state machine
6. Post-loop: classify result (success/error/abort)
```

The `AsyncGenerator` pattern allows the caller (UI or SDK) to consume model output incrementally as it streams, while the engine retains control of the turn lifecycle.

**Budget enforcement:** After each model response, `QueryEngine` compares `getTotalCost()` against `maxBudgetUsd`. If the budget is exceeded, the turn terminates.

**Structured output retry:** When the model fails to produce valid structured output, the engine retries up to `MAX_STRUCTURED_OUTPUT_RETRIES = 5` times before giving up.

### 1.3 queryLoop — The Core State Machine

**File:** `src/query.ts`

This is the central execution loop of Claude Code. It is a `while(true)` state machine driven by an explicit `State` type with 10 fields:

| State Field | Purpose |
|-------------|---------|
| `messages` | Current message buffer |
| `toolUseContext` | Shared context for tool execution |
| `autoCompactTracking` | Tracks auto-compaction triggers |
| `maxOutputTokensRecoveryCount` | Retry counter for output truncation |
| `hasAttemptedReactiveCompact` | Circuit breaker for reactive compaction |
| `maxOutputTokensOverride` | Current output token limit (escalatable) |
| `pendingToolUseSummary` | Summary of pending tool operations |
| `stopHookActive` | Whether a stop hook is currently blocking |
| `turnCount` | Number of iterations through the loop |
| `transition` | Discriminated union controlling the next iteration |

The explicit `State` type and `transition` field make the state machine self-documenting. Each iteration reads `transition` to determine whether to continue, retry, or terminate.

#### Phase 1: Context Preparation

Before any model call, the loop applies a chain of context-management transforms:

1. **`applyToolResultBudget`** — Truncates oversized tool results to fit within token limits.
2. **`snipCompactIfNeeded`** — Removes stale compact summaries if the context has grown past them.
3. **`microcompact`** — Lightweight in-place compression of redundant message content.
4. **`applyCollapsesIfNeeded`** — Collapses sequences of similar tool results into summaries.
5. **`autocompact`** — Triggers full compaction when context approaches the window limit.

This five-step pipeline runs on every iteration, ensuring the context window is always optimally utilized before paying for a model call.

#### Phase 2: Model Streaming

- **`callModel()`** with a fallback loop handles transient API errors.
- **`StreamingToolExecutor`** (gated behind a Statsig flag) allows tool execution to begin while the model is still streaming. Tools are dispatched as their input JSON is completed, not after the full response.
- **Tombstoning:** When streaming execution falls back to non-streaming, in-progress tool results are "tombstoned" — replaced with failure markers so the model knows to retry.
- **Recoverable error withholding:** Certain errors (e.g., transient rate limits) are withheld from the model to avoid contaminating its reasoning.

The streaming tool execution is a significant latency optimization. By beginning tool execution before the model finishes its response, the system can overlap model compute with tool I/O.

#### Phase 3: Post-Streaming Recovery

Three recovery mechanisms handle edge cases after the model response completes:

1. **Prompt-too-long recovery:** If the context exceeds the model's limit, the loop first attempts collapse-drain (removing collapsible content), then reactive compaction (full summarization).
2. **Max output tokens recovery:** If the model's output was truncated, the system escalates the output limit (64K → multi-turn, up to 3 attempts).
3. **Stop hooks and token budget checks** determine whether the turn should continue or yield.

The escalation from 64K to multi-turn output is a recovery mechanism, not a default — the system only pays the cost when truncation actually occurs.

#### Phase 4: Tool Execution

If streaming tool execution was not used (or for remaining tools), this phase executes tools via one of two paths:

- **`StreamingToolExecutor.getRemainingResults()`** — Collects buffered results from tools that started during streaming.
- **`runTools()`** — Batch execution with concurrency partitioning (see §2).

Results are collected in receipt order from the streaming executor, preserving the model's intended tool execution sequence.

#### Phase 5: Attachment and Queue Processing

Between model turns, the loop handles:

- **Queued commands** — User-submitted commands that arrived during model execution.
- **Attachment messages** — Files or other context attached by the user mid-turn.
- **Memory prefetch** — Preloads relevant memory files for the next turn.
- **Skill discovery** — Identifies and loads skills referenced in tool results.

This phase ensures the next model turn has access to all relevant context, including asynchronously arriving user input.

#### Phase 6: Turn Boundary

Checks the max turns limit and sets the state transition for the next iteration.

#### Transition Taxonomy

**7 continue/retry paths:**

| Transition | Trigger |
|------------|---------|
| `next_turn` | Normal continuation after tool results |
| `collapse_drain_retry` | Context too long; collapsible content removed |
| `reactive_compact_retry` | Context too long; full compaction performed |
| `max_output_tokens_escalate` | Output truncated; limit increased |
| `max_output_tokens_recovery` | Output truncated; multi-turn recovery |
| `stop_hook_blocking` | A stop hook is preventing completion |
| `token_budget_continuation` | Token budget allows continued generation |

**10 termination reasons:**

| Reason | Meaning |
|--------|---------|
| `completed` | Model finished naturally (end_turn stop reason) |
| `blocking_limit` | Too many consecutive permission denials |
| `aborted_streaming` | User cancelled during streaming |
| `model_error` | Unrecoverable API error |
| `prompt_too_long` | Context exceeds limit after all recovery attempts |
| `image_error` | Image processing failure |
| `stop_hook_prevented` | A hook blocked the response |
| `hook_stopped` | A hook terminated the turn |
| `aborted_tools` | User cancelled during tool execution |
| `max_turns` | Turn limit reached |

The explicit enumeration of transitions and termination reasons makes the state machine exhaustively analyzable.

### 1.4 Context Assembly

**File:** `src/context.ts`

Two memoized functions produce the context injected into every model call:

- **`getUserContext()`** → `{claudeMd, currentDate}` — Loads CLAUDE.md files (see §3.4) and the current date.
- **`getSystemContext()`** → `{gitStatus, cacheBreaker?}` — Runs parallel git commands to capture repository state.

Both functions are memoized to avoid redundant I/O across turns within the same session.

### 1.5 Cost Tracking

**File:** `src/cost-tracker.ts`

| Function | Behavior |
|----------|----------|
| `addToTotalSessionCost(cost, usage, model)` | Updates per-model usage counters and OpenTelemetry cost counters |
| `saveCurrentSessionCosts()` | Persists accumulated costs to project config (enables session resume) |
| `restoreCostStateForSession()` | Restores cost state from project config on session restart |

Cost tracking is per-model, allowing the system to report usage breakdowns across different model tiers (e.g., Sonnet vs. Opus).

---

## 2. Tooling and Integration Layer

### 2.1 Core Type System

**File:** `src/Tool.ts`

The `Tool<Input, Output, P>` generic interface defines 35+ methods spanning five categories:

| Category | Key Methods |
|----------|-------------|
| **Identity** | `name`, `displayName`, `description`, `schema` |
| **Schema** | Zod-based input validation, `schema()` returns `z.ZodObject` |
| **Execution** | `call()`, `isLongRunning()`, `timeout()` |
| **Permissions** | `isReadOnly()`, `isDestructive()`, `needsPermission()`, `getPermissionRequest()` |
| **Behavior** | `isConcurrencySafe()`, `shouldDefer()`, `isEnabled()`, `contextModifier()` |
| **UI** | `renderToolUseMessage()`, `renderToolResultMessage()` |

The `buildTool(def)` factory applies fail-closed defaults: `isConcurrencySafe=false`, `isReadOnly=false`, `isDestructive=false`. This means new tools are conservatively treated as serial, write-capable, and non-destructive unless explicitly opted in.

**`ToolResult<T>` shape:**

```typescript
{
  data: T,
  newMessages?: Message[],
  contextModifier?: (ctx: ToolUseContext) => void,
  mcpMeta?: MCPMeta
}
```

The `contextModifier` field allows tools to side-effect the shared context (e.g., updating `readFileState` after a file read) without the execution pipeline needing to know tool-specific details.

**`ToolUseContext` — the execution environment:**

A 59-field structure providing tools with everything they need:

- `tools` — the full tool pool
- `mcpClients` — active MCP server connections
- `abortController` — cancellation propagation
- `readFileState` — file mtime/content cache
- `getAppState/setAppState` — global state access
- `messages` — conversation history
- `toolDecisions` — accumulated permission decisions
- `fileReadingLimits` — per-tool file size limits

The large field count reflects the reality that tools operate in a rich context: they need access to permissions, state, history, and cancellation signals.

### 2.2 Tool Pool Assembly

**File:** `src/tools.ts`

Tool registration follows a three-step pipeline:

1. **`getAllBaseTools()`** — Static registration of all built-in tools with conditional includes via `bun:bundle` feature gates. Tools gated behind disabled features are eliminated at build time.
2. **`getTools(permCtx)`** — Filters the base pool by deny rules, `isEnabled()` checks, and current mode (e.g., plan mode restricts to read-only tools).
3. **`assembleToolPool(permCtx, mcpTools)`** — Merges built-in tools with MCP-provided tools. Built-in tools win on name collisions. The final pool is sorted for prompt cache stability and deduplicated.

The build-time elimination via `bun:bundle` is a key optimization — unreachable tool code is tree-shaken from the production bundle.

Built-in tools taking priority over MCP tools on name collision prevents an MCP server from shadowing core functionality.

### 2.3 Execution Pipeline

**Directory:** `src/services/tools/`

#### Single Tool Execution (`toolExecution.ts`)

`runToolUse()` implements a 7-step pipeline for each individual tool invocation:

```
1. Tool lookup (by name from pool)
2. Zod input parsing (schema validation)
3. Backfill (populate defaults, resolve paths)
4. Speculative classifier (predict permission outcome)
5. Pre-hooks (runPreToolUseHooks — can block, modify, auto-approve)
6. Permission check (rule-based + mode-specific)
7. Tool.call() execution
8. Post-hooks (runPostToolUseHooks — can modify output)
9. Result mapping (ToolResult → SDKMessage)
```

The speculative classifier (step 4) is a latency optimization: it predicts whether permission will be granted before running the full permission pipeline, allowing optimistic execution to begin earlier.

#### Batch Orchestration (`toolOrchestration.ts`)

`runTools()` partitions a batch of tool invocations into two groups:

- **Concurrent-safe tools** (`isConcurrencySafe() === true`): Run in parallel, up to 10 at a time.
- **Serial tools**: Run one at a time, in order.

Context modifiers from all tools are queued and applied in `toolUseId` order, regardless of execution order. This ensures deterministic state updates even with concurrent execution.

The max parallelism of 10 prevents resource exhaustion while still capturing most of the latency benefit from concurrent tool execution.

#### Streaming Tool Execution (`StreamingToolExecutor`)

- **`addTool()`** — Called during model streaming as each tool use block's JSON input is completed.
- Results are buffered in receipt order.
- On error in any tool, sibling tools in the same batch are aborted to prevent wasted work.

The Statsig gate on streaming execution allows gradual rollout and instant rollback of this optimization.

### 2.4 Tool Implementations (41 Tools)

#### BashTool

**Schema:** `{command, timeout?, run_in_background?, dangerouslyDisableSandbox?, description?}`

The most security-sensitive tool, protected by a 3-layer security pipeline:

| Layer | File | Mechanism |
|-------|------|-----------|
| 1 | `bashSecurity.ts` (~2600 lines) | 23 static validators: command substitution, Zsh dangerous commands, IFS injection, brace expansion, control chars, Unicode whitespace, comment/quote desync |
| 2 | `bashPermissions.ts` | Rule matching (exact/prefix/wildcard) + bash classifier (LLM-based, speculative) |
| 3 | `readOnlyValidation.ts` | `COMMAND_ALLOWLIST` with flag-level parsing, `READONLY_COMMAND_REGEXES`, `$`-token rejection |

See §8.3 for full details on the bash security pipeline.

#### FileEditTool

**Schema:** `{file_path, old_string, new_string, replace_all?}`

Uses string find-and-replace, not diff/patch. Includes an mtime check that detects unexpected modifications between the model's file read and its edit attempt.

The mtime check prevents a class of race conditions where external processes modify files between the model reading them and writing edits.

#### AgentTool (exposed as "Task")

**Schema:** `{description, prompt, subagent_type?, model?, run_in_background?, isolation?, cwd?}`

Spawns sub-agents via `runAgent()`. Supports a **fork mode** where the sub-agent inherits the parent's full conversation, enabling prompt cache sharing across the parent-child boundary.

See §5.2 for the full sub-agent architecture.

#### MCPTool

A template tool with `z.object({}).passthrough()` schema. Methods are overridden per MCP server connection, allowing each MCP server to define its own tool semantics.

The passthrough schema means MCP tools accept arbitrary JSON, with validation delegated to the MCP server.

#### GrepTool

Wraps ripgrep with 14 parameters. Marked as `ConcurrencySafe` and `ReadOnly`, enabling parallel execution without permission checks.

The ripgrep backend provides near-instantaneous search even on large codebases.

#### WebSearchTool

Calls `queryModelWithStreaming` with the `web_search_20250305` tool. Hard-limited to 8 searches per invocation.

The search limit prevents runaway web search loops that could consume excessive API credits.

#### SkillTool

Supports two execution modes:
- **Inline:** Skill content is injected into the current conversation context.
- **Forked:** Skill runs in a sub-agent, isolating its context from the parent.

Skills are wrapped as `Commands` for execution.

#### CronCreateTool

**Schema:** `{cron, prompt, recurring, durable}`

Feature-gated behind `AGENT_TRIGGERS`. See §5.1 for the full scheduling architecture.

### 2.5 Hook System (3 Phases)

| Phase | Function | Capabilities |
|-------|----------|-------------|
| **Pre-tool** | `runPreToolUseHooks()` | Block execution, modify input, auto-approve |
| **Permission resolution** | `resolveHookPermissionDecision()` | Merge hook results with rule-based permissions |
| **Post-tool** | `runPostToolUseHooks()` | Modify output |

**Critical invariant:** Hook `allow` decisions do **not** bypass `deny` rules. A hook can approve a tool use, but if a deny rule matches, the denial takes precedence. This prevents hooks from undermining the security model.

---

## 3. Memory Architecture

### 3.1 Short-Term: Session Memory

Session memory captures key context from the current conversation for use in compaction recovery and session continuity.

**Mechanism:**
- Registered as a post-sampling hook via `registerPostSamplingHook(extractSessionMemory)`.
- **Threshold-gated:** Requires 10K tokens to initialize, then 5K tokens + 3 tool calls between updates.
- Runs as `runForkedAgent` restricted to `FileEditTool` operating on exactly one file path.
- **Feature gate:** `tengu_session_memory` AND `isAutoCompactEnabled()`.

The threshold gating prevents excessive memory extraction on short or low-activity sessions, where the overhead would outweigh the benefit.

Restricting the forked agent to a single `FileEditTool` path prevents the memory extraction agent from accidentally modifying workspace files.

### 3.2 Long-Term: Auto Memory (Memdir System)

The memdir system provides persistent, project-scoped memory using a file-based storage model.

**Storage format:** YAML frontmatter + Markdown body in `~/.claude/projects/<slug>/memory/`

**Index file:** `MEMORY.md` — A 200-line / 25KB index that catalogs all individual memory files. Hard-limited to prevent unbounded growth.

**Memory types:**

| Type | Purpose |
|------|---------|
| `user` | User preferences, working style, conventions |
| `feedback` | Corrections and feedback from the user |
| `project` | Project-specific context (architecture, dependencies, patterns) |
| `reference` | Reference material (API docs, library usage) |

**Two write paths:**

1. **Main agent direct writes** — The primary agent creates/updates memory files directly.
2. **Background extraction agent** — A `runForkedAgent` that asynchronously extracts memories from conversation. Gated behind `tengu_passport_quail`, throttled by turns since last extraction, maximum 5 turns between extractions.

The dual write path reflects the tension between immediacy (direct writes for explicit user requests) and comprehensiveness (background extraction for implicit knowledge).

### 3.3 Memory Recall

**Function:** `findRelevantMemories()`

**Pipeline:**
1. `scanMemoryFiles()` — Enumerate all memory files, collecting filenames and descriptions.
2. `selectRelevantMemories()` — Send the manifest to a Sonnet side-query that selects up to 5 relevant files.

Memory recall is **not** embedding-based search. It uses an LLM to select from a manifest of filenames and descriptions. This trades recall precision for simplicity (no embedding index to maintain) and flexibility (the LLM can reason about relevance in context).

**Staleness handling:** `memoryAge.ts` annotates memories older than 1 day with age metadata, allowing the model to weight recent memories more heavily.

### 3.4 CLAUDE.md Files

CLAUDE.md files are the user-facing configuration mechanism for injecting project-specific instructions into the system prompt.

**Loading hierarchy (highest to lowest priority):**

1. **User:** `~/.claude/CLAUDE.md` — Global user preferences
2. **Local:** `CLAUDE.local.md` — Machine-specific overrides (gitignored)
3. **Project:** `CLAUDE.md` — Project root instructions
4. **Managed:** System-managed CLAUDE.md content

The hierarchy is loaded via `getClaudeMds(getMemoryFiles())`, which is cached for the duration of the conversation to avoid redundant file reads.

### 3.5 Team Memory

**Directory:** `<autoMemPath>/team/`

Team memory enables shared knowledge across team members working on the same project.

**Feature gate:** `isAutoMemoryEnabled() && tengu_herring_clock`

**Security measures:**
- Symlink resolution prevents path traversal attacks.
- Null-byte checks prevent string truncation attacks.
- URL-encoding attack prevention for file paths.
- **Secret scanner:** 30+ regex patterns detect potential secrets in memory content. Returns only rule IDs (not matched text) to avoid logging secrets in telemetry.

The secret scanner's decision to return rule IDs rather than matched text is a defense-in-depth measure — even if the scanner's output is logged, no actual secret values are exposed.

### 3.6 Conversation Compaction

**Function:** `compactConversation()`

When the conversation context approaches the model's window limit, compaction summarizes the history to reclaim space.

**Pipeline:**
```
1. PreCompact hooks (allow external observers to prepare)
2. streamCompactSummary() via forked agent
3. PTL (prompt-too-long) retry if summary itself is too large
4. Post-compact restoration of essential context
```

**Summary format (9 sections):**

1. Primary request
2. Key concepts
3. Files and code
4. Errors encountered
5. Problem-solving approaches
6. All user messages (preserved verbatim)
7. Pending tasks
8. Current work
9. Next step

The `NO_TOOLS_PREAMBLE` flag prevents the compaction agent from attempting tool use, keeping it focused on summarization.

**Auto-compact trigger:** Fires when context reaches `effectiveContextWindow - 13,000` tokens. A circuit breaker disables auto-compact after 3 consecutive failures to prevent infinite retry loops.

**Post-compact context re-injection:**
- Top 5 recent files (50K budget, 5K each) — ensures the model retains awareness of recently touched files.
- Plan preservation — any active plan is re-injected.
- Skill preservation (25K budget) — loaded skills are re-injected.
- Deferred tools delta — tool results that arrived during compaction are applied.

The re-injection budget is carefully balanced: enough context to maintain continuity, but not so much that it defeats the purpose of compaction.

---

## 4. Reasoning and Self-Correction

### 4.1 Thinking Configuration

**Type:** `ThinkingConfig = adaptive | enabled(budgetTokens) | disabled`

| Mode | Behavior |
|------|----------|
| `adaptive` | Model decides when to use extended thinking based on query complexity |
| `enabled(budgetTokens)` | Always use extended thinking with the specified token budget |
| `disabled` | No extended thinking |

**Default:** `adaptive` for all supported models.

**Ultrathink mode:** An escalated thinking mode that allocates significantly more thinking tokens.
- **Build-time gate:** `ULTRATHINK` feature flag.
- **Runtime gate:** `tengu_turtle_carbon` Statsig flag.
- **User trigger:** Keyword match `/\bultrathink\b/i` in user input.

The dual gating (build-time + runtime) allows ultrathink to be compiled out entirely in builds where it's not needed, while still supporting runtime activation in builds that include it.

### 4.2 Plan Mode

Plan mode restricts the agent to read-only operations, forcing it to reason about an approach before taking action.

**Permission constraint:** Plan mode sets the tool permission mode to `read-only`, disabling all write tools.

**Entry:** `EnterPlanModeTool` — has `shouldDefer: true`, meaning it is blocked in sub-agent contexts (agents should not unilaterally enter plan mode).

**Exit:** `ExitPlanModeV2Tool` — implements a teammate approval workflow:
1. The plan is persisted to a file.
2. Mode is restored to the previous state.
3. If teammates are configured, the plan is routed for approval.

**Prompt variants:** Two system prompt variants control plan mode behavior:
- **External** (non-Anthropic users): More aggressive about suggesting plan mode for complex tasks.
- **Ant** (Anthropic internal users): More conservative, assuming users are familiar with the system.

The `USER_TYPE` flag (`'ant'` vs `'external'`) determines which variant is used.

### 4.3 System Prompt Assembly

**File:** `src/services/queryContext.ts`

**Function:** `fetchSystemPromptParts()`

Performs 3 parallel fetches:
1. System prompt (static text)
2. User context (`getUserContext()` — CLAUDE.md + date)
3. System context (`getSystemContext()` — git status)

The system prompt is a branded `string[]` with a static/dynamic split at `__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__`:

- **Static prefix:** Stable across turns, enabling prompt caching.
- **Dynamic suffix:** Changes per-turn, containing:
  - Agent tools and skills
  - Memory content
  - Model overrides
  - Environment context
  - Language preferences
  - Output style directives
  - MCP server descriptions
  - Context window parameters

The static/dynamic split is a deliberate prompt cache optimization — the static prefix remains cache-eligible across turns even as the dynamic suffix changes.

### 4.4 Prompt Suggestion and Speculation

A multi-stage pipeline for predictive execution:

**Stage 1: Suggestion generation**
- A post-sampling hook generates next-prompt suggestions via a forked agent.
- The suggestion represents what the user is likely to ask or confirm next.

**Stage 2: Speculative execution**
- A forked agent executes the suggested prompt.
- File writes go to an **overlay directory** (copy-on-write), not the real workspace.
- Execution halts at the first non-read-only operation that would require permission.

**Stage 3: Acceptance**
- If the user accepts the suggestion, overlay files are copied to the main workspace.
- If rejected, the overlay is discarded with no effect on the workspace.

**Stage 4: Pipelining**
- After speculation completes, a new suggestion is generated from the augmented context (including the speculative result).
- This creates a pipeline: while the user is reading the current response, the system is already speculating on the next turn.

The copy-on-write overlay is essential for safety — speculative file writes never touch the real workspace until explicitly accepted.

The pipelining behavior suggests the system optimizes for conversational latency at the cost of potentially wasted compute on rejected speculations.

### 4.5 Verification

**File:** `src/utils/hookHelpers.ts`

- **`createStructuredOutputTool()`** — Creates a verification tool that returns `{ok: boolean, reason?: string}`.
- **`registerStructuredOutputEnforcement`** — A stop hook that re-prompts the model if it skips the verification tool (i.e., tries to end its turn without calling the structured output tool).
- **Verification agent:** Runs in strictly read-only mode with an adversarial posture. Uses change-type-specific strategies (e.g., different verification approaches for code edits vs. file creation vs. configuration changes).

The adversarial posture means the verification agent is prompted to look for problems, not to confirm success. This counteracts the model's tendency toward optimistic self-assessment.

---

## 5. Autonomy and Background Operation

### 5.1 Cron Scheduling

**Tool:** `CronCreateTool` — `{cron (5-field local time), prompt, recurring, durable}`

**Scheduler:** `cronScheduler.ts`
- **Check interval:** 1-second poll loop.
- **Storage:** File-backed tasks (survive restarts) + session-only tasks (in-memory).
- **Ownership:** `tryAcquireSchedulerLock()` prevents double-firing across multiple Claude Code instances.

**Jitter:**
- Recurring tasks: Up to 10% of the period (max 15 minutes).
- One-shot tasks on `:00`/`:30`: Up to 90 seconds.

The jitter prevents thundering-herd effects when multiple cron tasks are scheduled at the same time, and prevents tasks from firing at exactly predictable times.

**Auto-expiry:** Recurring tasks expire after `recurringMaxAgeMs`, preventing indefinite resource consumption.

### 5.2 Sub-Agent Architecture

**Tool:** `AgentTool` spawns sub-agents via `runAgent()`, which returns an `AsyncGenerator`.

**Built-in agent types:**

| Type | Purpose |
|------|---------|
| `Explore` | Code exploration and search |
| `Plan` | Planning and design |
| `verification` | Adversarial verification of changes |
| `claudeCodeGuide` | Help and documentation |
| `generalPurpose` | Catch-all for untyped tasks |
| User-defined | Custom agent types via configuration |

**Fork mode:** A sub-agent can inherit the parent's full conversation context. This enables prompt cache sharing — the forked agent's prompt prefix is identical to the parent's, so the API can serve cached KV states.

**Isolation modes:**

| Mode | Mechanism | Use Case |
|------|-----------|----------|
| `default` | In-process | Low-overhead sub-tasks |
| `worktree` | Git worktree | Isolated file system changes |
| `remote` | CCR (Claude Code Remote) cloud | Heavy compute, CI-like tasks |

The worktree isolation mode leverages git worktrees to give each sub-agent its own working directory, preventing file conflicts between parallel agents.

**Permission bubbling:** When `agentDefinition.permissionMode === 'bubble'`, permission requests from the sub-agent surface to the parent agent (and ultimately to the user).

### 5.3 Coordinator Mode

**File:** `src/coordinator/coordinatorMode.ts`

Activated via `CLAUDE_CODE_COORDINATOR_MODE=1`.

**Available tools in coordinator mode:**

| Tool | Purpose |
|------|---------|
| `Agent` | Spawn sub-agents |
| `SendMessage` | Communicate with running agents |
| `TaskStop` | Terminate agents |

**Structured workflow:**

```
Research → Synthesis → Implementation → Verification
```

Coordinator mode transforms Claude Code from a single-agent system into a multi-agent orchestrator, with the coordinator responsible for task decomposition and result synthesis.

### 5.4 Task System

**7 task types:**

| Type | Description |
|------|-------------|
| `local_bash` | Shell command execution |
| `local_agent` | In-process sub-agent |
| `remote_agent` | Cloud-hosted agent |
| `in_process_teammate` | Teammate agent sharing the process |
| `local_workflow` | Multi-step workflow |
| `monitor_mcp` | MCP server monitoring task |
| `dream` | Background ideation/speculation task |

**Lifecycle:** `pending → running → completed | failed | killed`

**Persistence:** Task output is written to `outputFile` on disk, allowing results to survive process restarts for durable tasks.

---

## 6. Configuration and Policy

### 6.1 Global Config

**File:** `~/.claude.json` (GlobalConfig type, ~200 fields)

**Access pattern:**
- **Fast path:** In-memory cache. All reads after the first are zero-cost.
- **Slow path:** Synchronous I/O at startup, exactly once. This is intentional — the config file is small, and async I/O here would complicate the startup sequence.

**File watcher:** `fs.watchFile` with a 1-second poll interval detects external changes to the config file (e.g., from another Claude Code instance or manual editing).

**Write-through:** `writeThroughGlobalConfigCache()` writes to disk and updates the in-memory cache atomically. Uses mtime overshoot to prevent the file watcher from triggering a redundant reload.

**Lock:** `saveConfigWithLock()` provides advisory locking for concurrent write access. Includes compromised-lock handling (if another process holds the lock for too long, the lock is force-acquired).

**Per-project config:** `GlobalConfig.projects[normalizedPath]` allows project-specific overrides within the global config file.

The sync I/O choice at startup is pragmatic — config loading is on the critical path, and the file is small enough that the sync penalty is negligible compared to the complexity async would add.

### 6.2 Settings System (5 Layers)

Settings are resolved through a 5-layer hierarchy where higher layers override lower ones:

```
policySettings (highest priority)
  └── flagSettings
       └── localSettings
            └── projectSettings
                 └── userSettings (lowest priority)
```

| Layer | Source | Purpose |
|-------|--------|---------|
| `policySettings` | MDM (Mobile Device Management) | Enterprise deployment constraints |
| `flagSettings` | Feature flags (Statsig/GrowthBook) | A/B testing and rollout |
| `localSettings` | Machine-local config | Machine-specific overrides |
| `projectSettings` | Project-scoped config | Project conventions |
| `userSettings` | User preferences | Personal defaults |

The MDM integration for `policySettings` enables enterprise IT departments to enforce constraints (e.g., disabling bypass mode, requiring specific models) via platform-specific managed configuration paths.

The MDM paths are likely platform-specific: macOS uses managed preferences (plist), while Linux may use `/etc/claude/` or similar.

### 6.3 Feature Flags

**Compile-time flags:**
- `bun:bundle`'s `feature()` function returns `true` or `false` literals at build time.
- Dead code elimination removes unreachable branches, reducing bundle size.
- 88+ build-time flags controlling feature inclusion.

**Runtime flags:**
- GrowthBook client with disk-cached features for offline operation.
- 500+ `tengu_*` runtime flags controlling behavior, rollout, and experiments.
- Feature evaluation is synchronous (reads from cache), with background refresh.

**Identity-based gating:**
- `USER_TYPE: 'ant' | 'external'` — Distinguishes Anthropic internal users from external users.
- Certain features, prompt variants, and behaviors differ based on this flag.

The two-tier flag system (compile-time + runtime) provides both performance benefits (dead code elimination) and operational flexibility (instant runtime changes without redeployment).

---

## 7. Telemetry, Metrics, and Feedback

### 7.1 Event Pipeline

**Entry point:** `logEvent()` — Fire-and-forget API. Events are buffered in a `QueuedEvent` array until `attachAnalyticsSink()` is called (typically after authentication completes).

**Metadata safety:** The `Metadata` type prohibits string values, preventing accidental PII inclusion. Fields requiring PII are explicitly tagged with `_PROTO_*` prefixes that trigger server-side handling.

The type-level PII prevention is a compile-time guarantee — a developer cannot accidentally log a raw string as event metadata without using the `_PROTO_*` escape hatch.

**Dual backend:**

| Backend | Protocol | Batching | Limits |
|---------|----------|----------|--------|
| **Datadog** | HTTP POST | 15-second intervals, 100 events/batch | 64 allowlisted event names |
| **1P (First-party)** | OTel `BatchLogRecordProcessor` → POST `/api/event_logging/batch` | OTel defaults | All events |

**1P resilience:**
- Failed events are written to a JSONL file for later retry.
- Retry uses quadratic backoff (not exponential — slower growth, more persistent).
- Auth fallback: if primary auth fails, events are still persisted locally.

The dual-backend approach provides redundancy: if either Datadog or the 1P endpoint is unavailable, the other continues to receive events.

**Event sampling:** GrowthBook configuration controls per-event sampling rates, allowing high-volume events to be sampled down without code changes.

**Privacy safeguards:**
- MCP tool names are sanitized to the literal string `'mcp_tool'` in telemetry, preventing leakage of customer-specific MCP server names.
- File paths are never logged as raw strings.

These safeguards reflect a privacy-by-design approach where the telemetry system is structurally incapable of capturing certain sensitive data.

**3P OTLP (Customer-facing telemetry):**
- Activated when `CLAUDE_CODE_ENABLE_TELEMETRY=1`.
- Exports metrics, logs, and traces via the standard OpenTelemetry Protocol.
- Designed for customers who want to integrate Claude Code telemetry into their own observability stack.

### 7.2 Session Recording

**Function:** `recordTranscript()` — Called at multiple points in the query loop to capture conversation state.

**VCR (Video Cassette Recorder) mode:**
- Records and replays API fixtures for testing.
- Fixtures are keyed by SHA-1 hash of dehydrated input (input with non-deterministic fields removed).
- Enables deterministic replay of API interactions for regression testing.

The dehydration step (removing timestamps, request IDs, etc.) ensures that recordings are stable across test runs.

### 7.3 Debug Logging

**Output:** `~/.claude/debug/{sessionId}.txt`

- Level-filtered (debug, info, warn, error).
- Buffered with 1-second flush interval (reduces I/O overhead).
- In-memory ring buffer of 100 entries for the error log, enabling post-mortem inspection without relying on file output.

The ring buffer ensures that even if the file system is unavailable or full, the most recent 100 error entries are available in memory for crash diagnostics.

---

## 8. Security and Safety Controls

### 8.1 Permission Model

**6 permission modes:**

| Mode | Behavior |
|------|----------|
| `default` | Ask for permission on non-read-only operations |
| `plan` | Read-only; all write operations blocked |
| `acceptEdits` | Auto-approve file edits; ask for other writes |
| `bypassPermissions` | Skip permission checks (killswitchable) |
| `dontAsk` | Auto-approve all operations (no UI prompts) |
| `auto` | YOLO classifier decides (see §8.2) |

**Rule sources (highest to lowest priority):**

```
policy > flag > local > project > user > cliArg > session > command
```

**Decision flow:**

```
1. Check deny rules → if match, DENY (non-overridable)
2. Check ask rules → if match, PROMPT USER
3. Check allow rules → if match, ALLOW
4. Fall through to mode-specific default logic
```

The deny-first evaluation order means that security-critical restrictions cannot be overridden by lower-priority allow rules, regardless of their source.

### 8.2 Auto Mode (YOLO Classifier)

The auto mode ("You Only Live Once") uses an LLM-based classifier to decide whether to auto-approve tool invocations.

**2-stage pipeline:**

| Stage | Mechanism | Purpose |
|-------|-----------|---------|
| **Stage 1** | Fast XML decision | Quick approval/denial based on structured analysis |
| **Stage 2** | Thinking-enabled evaluation | Deep analysis for ambiguous cases (only triggered if Stage 1 blocks) |

**Optimizations:**
- **Safe tool bypass:** Tools marked as read-only and concurrency-safe skip the classifier entirely.
- **Text block exclusion:** Only tool-use blocks are fed to the classifier; text blocks are excluded to reduce noise and cost.

**Safety guardrails:**
- **Denial tracking:** Consecutive denial count is tracked. After reaching a threshold, the system falls back to direct user prompting (exiting auto mode for that tool).
- **On entry:** When auto mode is activated, overly broad allow rules (e.g., `Bash(*)`) are stripped. This prevents users from accidentally creating a configuration that approves all bash commands in auto mode.

The stripping of broad allow rules on auto mode entry is a critical safety measure — it means that auto mode is always at least as restrictive as the classifier's judgment, never less.

### 8.3 Bash Security Pipeline

The most complex security subsystem, reflecting the inherent danger of arbitrary command execution.

#### Layer 1: Static Validators (`bashSecurity.ts`, ~2600 lines)

23 validators check for dangerous patterns before any command reaches the permission system:

| Validator Category | Examples |
|-------------------|----------|
| Command substitution | `$(...)`, backtick expansion |
| Zsh-specific dangers | Glob qualifiers, `=(process)` substitution |
| Injection attacks | IFS manipulation, null bytes, Unicode whitespace |
| Expansion attacks | Brace expansion bombs, parameter expansion |
| Encoding attacks | Control characters, homoglyphs, comment/quote desync |

The validators use Tree-sitter AST analysis where possible, with regex fallback for cases where the AST parser fails or produces ambiguous results.

Validator ordering is misparsing-aware: validators that detect parsing ambiguities run before validators that assume correct parsing, preventing a misparse from causing a dangerous command to pass through a later validator.

#### Layer 2: Rule Matching and Classification (`bashPermissions.ts`)

- **Rule matching:** Exact match, prefix match, and wildcard match against the command string.
- **Sandbox auto-allow:** Commands that run inside the sandbox (see §8.4) may be auto-approved if they fall within the sandbox's capability set.
- **Bash classifier:** An LLM-based classifier that evaluates commands not covered by static rules. The classifier is speculative — its result is computed in parallel with other checks, and used only if the static checks are inconclusive.

The LLM classifier is a last resort, not a first check. This layered approach ensures that clearly dangerous commands are blocked by fast static analysis, while the slower LLM classifier handles novel or ambiguous cases.

#### Layer 3: Read-Only Validation (`readOnlyValidation.ts`)

For read-only mode, an additional layer restricts commands to a known-safe set:

- **`COMMAND_ALLOWLIST`** — Explicitly permitted commands with flag-level parsing (e.g., `ls` is allowed, but `ls --recursive /` may be restricted).
- **`READONLY_COMMAND_REGEXES`** — Regex patterns matching read-only command structures.
- **`$`-token rejection** — Any command containing `$` (variable expansion, command substitution) is rejected in read-only mode, preventing indirect command execution.

The `$`-token rejection is a deliberately conservative measure. It blocks some safe uses (e.g., `echo $HOME`) but eliminates an entire class of injection attacks.

### 8.4 Sandbox

Sandboxing isolates tool execution from the host system.

| Platform | Mechanism |
|----------|-----------|
| **Linux** | bubblewrap (`bwrap`) — namespace-based isolation |
| **macOS** | `sandbox-exec` (Seatbelt) — profile-based restriction |

**Always-denied writes:**

| Target | Rationale |
|--------|-----------|
| Settings files | Prevent self-modification of security configuration |
| `.claude/skills` | Prevent injection of malicious skills |
| Bare git repo files | Prevent exploitation of git hooks |

**Network controls:**
- Allowed/denied domain lists for HTTP(S) traffic.
- Unix socket access control.
- Proxy interception support for enterprise environments.

**Post-execution cleanup:** Bare git repo scrubbing removes any `core.fsmonitor` entries or similar attack vectors that a sandboxed command might have planted for later execution outside the sandbox.

The bare git repo scrubbing is a defense against a specific attack: a malicious command could set `core.fsmonitor` to a command that executes the next time `git status` runs outside the sandbox.

### 8.5 Hook System Security

**20+ event types:** `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, and others.

**Output format:** JSON with `allow`/`deny`/`ask` decisions.

**Critical invariant (repeated for emphasis):** Hook `allow` decisions do **NOT** bypass deny or ask rules. The hook system can add restrictions but cannot remove them.

**Policy controls:**
- `shouldAllowManagedHooksOnly()` — Restricts hooks to those provided by managed configuration (enterprise).
- `shouldDisableAllHooksIncludingManaged()` — Nuclear option: disables all hooks entirely.

The two-level disable provides flexibility: enterprises can restrict hooks to managed ones (preventing user-installed hooks from running), or disable them entirely if the hook system itself is a concern.

### 8.6 Trust Model

The trust model is built on the settings hierarchy (§6.2):

- Settings from higher-priority layers are more trusted.
- The trust dialog gates initial access, ensuring the user has acknowledged the system's capabilities.
- Remote managed settings (MDM) can force-disable `bypassPermissions` mode, preventing users from circumventing the permission system in managed environments.
- The `bypassPermissions` mode is killswitchable via a Statsig gate, allowing Anthropic to remotely disable it if a security issue is discovered.

The killswitch on `bypassPermissions` is a safety net: if the permission bypass is found to be exploitable, it can be disabled globally without requiring a software update.

---

## 9. Cross-Cutting Observations

### 9.1 Architectural Principles

The following principles are evident across multiple subsystems:

**Defense in depth.** Security is never a single check. The bash security pipeline has 3 layers. The permission system has 6+ rule sources. The hook system cannot override deny rules.

**Fail-closed defaults.** New tools default to serial, write-capable, non-destructive. New commands default to requiring permission. The sandbox denies unknown operations.

**Latency-driven parallelism.** Startup parallelizes I/O with imports. The query loop overlaps model streaming with tool execution. Speculation pre-executes predicted next turns. Context assembly runs 3 parallel fetches.

**Graceful degradation.** Offline feature flags use disk cache. Failed telemetry events are persisted for retry. Cost tracking survives session restarts. Compaction has a circuit breaker.

**LLM as runtime.** The system uses LLMs not just for user-facing responses, but as runtime components: the YOLO classifier, memory relevance selection, bash security classification, verification, memory extraction, and prompt suggestion are all LLM-powered subsystems.

### 9.2 Scale Indicators

| Metric | Value |
|--------|-------|
| Source modules | ~1,915 |
| Tool implementations | 41 |
| Build-time feature flags | 88+ |
| Runtime feature flags | 500+ |
| Bash security validators | 23 |
| ToolUseContext fields | 59 |
| GlobalConfig fields | ~200 |
| Query loop state fields | 10 |
| Permission rule sources | 8 |
| Memory types | 4 |
| Task types | 7 |
| Telemetry event allowlist | 64 |

All metrics derived from architecture analysis.

### 9.3 Key Design Tensions

| Tension | Resolution |
|---------|------------|
| Latency vs. safety | Speculative execution with copy-on-write overlay; streaming tool execution with abort-on-error |
| Autonomy vs. control | 6 permission modes on a spectrum from fully interactive to fully autonomous, with classifier fallback |
| Memory comprehensiveness vs. cost | Threshold-gated extraction, LLM-based relevance selection (not embedding search), staleness annotations |
| Context size vs. quality | 5-step context preparation pipeline, auto-compact with re-injection of critical context |
| Offline vs. connected | Disk-cached feature flags, local event persistence, file-based memory storage |
| Enterprise vs. individual | 5-layer settings hierarchy with MDM at the top, killswitchable permissions |

These tensions represent deliberate architectural trade-offs rather than accidental complexity. Each resolution reflects a specific stance on where the system should fall on the trade-off spectrum.

---
