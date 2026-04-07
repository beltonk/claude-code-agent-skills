# Designing an Agentic Coding Assistant — Lessons from Claude Code

> A design-oriented companion to the [Implementation Blueprint](./03-implementation-blueprint.md).
> This document is language-agnostic, framework-agnostic, and focused entirely on *practices, design decisions, and architectural philosophy* — the things that matter regardless of your tech stack.
> Based on analysis of Claude Code by Anthropic.

---

## Table of Contents

1. [The Agent Loop — How to Think About Turns](#1-the-agent-loop)
2. [Prompt Engineering — What the Model Sees](#2-prompt-engineering)
3. [Tool Design — Giving the Agent Hands](#3-tool-design)
4. [Memory — What the Agent Remembers](#4-memory)
5. [Context Window Management — Working Inside Limits](#5-context-window-management)
6. [Permission and Safety — Letting the Agent Act Without Breaking Things](#6-permission-and-safety)
7. [Multi-Agent Coordination — Dividing Labor](#7-multi-agent-coordination)
8. [Self-Correction and Verification — Knowing When You're Wrong](#8-self-correction-and-verification)
9. [Autonomous and Background Operation — Agents That Run Without You](#9-autonomous-and-background-operation)
10. [Observability and Feedback — Knowing What Happened](#10-observability-and-feedback)
11. [Configuration and Policy — Adapting to Every Environment](#11-configuration-and-policy)
12. [Key Design Tensions and How Claude Code Resolves Them](#12-design-tensions)

---

## 1. The Agent Loop

The heart of any coding agent is the loop: **ask the model → parse its intent → execute actions → feed results back → repeat**.

### 1.1 Use a Flat State Machine, Not Recursion

Claude Code's main loop is a flat `while(true)` with an explicit state object that gets replaced on each iteration. It does not recurse. This matters because:

- **Sessions can last hundreds of turns.** Recursive calls accumulate stack frames. A flat loop doesn't.
- **State is inspectable.** Every continuation records *why* it continued (tool result, error recovery, budget continuation). Debugging a flat state object is easier than debugging a call stack.
- **Cancellation is cheap.** At every yield point, the loop checks an abort signal. In a recursive design, unwinding nested calls is expensive.

**Design principle:** Represent your agent's lifecycle as a state machine where each transition is explicit and named, not as a nested function call graph.

### 1.2 Define All the Ways the Loop Ends

Claude Code defines exactly 10 termination reasons: natural completion, user abort (during streaming or tools), unrecoverable errors, context overflow after all recovery, permission blocks, hook vetoes, and turn limits. Separately, it defines 7 continuation reasons for when the loop needs to retry or continue.

**Design principle:** Enumerate your loop's exit conditions exhaustively. If you can't name the reason the loop stopped, you have a bug.

### 1.3 Stream Everything

The loop yields events as they happen — partial model tokens, tool progress, error notifications — rather than blocking until a turn is complete. This serves three purposes:

1. **Progressive rendering** — the user sees output immediately.
2. **Backpressure** — the consumer controls the pace.
3. **Mid-turn cancellation** — the user can interrupt at any yield point without losing the partial state.

**Design principle:** Make your agent loop a producer of incremental events, not a function that returns a complete result.

### 1.4 Overlap Execution with Streaming

When the model is still generating text, tool calls that have already been fully specified can begin executing. Claude Code starts executing concurrency-safe tools during streaming, before the model finishes. If a tool errors, sibling tools in the same batch are aborted.

**Design principle:** Don't wait for the complete model response to start acting. Parse tool calls incrementally and execute when their inputs are complete. Always include an abort mechanism for in-flight work.

### 1.5 Rich Completion Signaling

When an action (command, tool, sub-agent) finishes, it shouldn't just return a result — it should signal how the agent loop should proceed. Claude Code's commands can influence the next turn via structured completion metadata:

- **Display mode**: Skip display, inject as system message, or display as user message.
- **Auto-query flag**: Whether the loop should automatically send the next turn to the model without waiting for user input.
- **Meta-messages**: Hidden instructions for the model that the user doesn't see.
- **Pre-filled input**: Suggest the user's next query.

**Design principle:** Let commands and tools choreograph what happens next without coupling them to the loop implementation. A structured completion protocol is cleaner than every action reaching into the loop's internals.

---

## 2. Prompt Engineering

This is where the real craft is. Claude Code's prompt system is extensive, carefully structured, and full of subtle design choices.

### 2.1 Static/Dynamic Split for Cache Efficiency

The system prompt is split into two zones separated by a boundary marker:

- **Static prefix** — identity, behavioral rules, security directives, code style guidelines, tool preference hierarchies, tone instructions. This never changes between turns, so it stays in the LLM provider's prompt cache.
- **Dynamic suffix** — environment details (CWD, OS, git state), model overrides, available tools and skills, loaded memory content, MCP server descriptions, context window parameters, language preferences. This changes per turn.

**Design principle:** Move everything stable into the prompt prefix. Every token in the dynamic section costs a cache miss. The boundary between "what changes" and "what doesn't" is a first-class architectural decision.

### 2.2 Identity and Behavioral Directives

The main system prompt establishes:

- **Identity**: "You are an interactive agent that helps users with software engineering tasks." — Clear, specific, bounded.
- **Conciseness**: "Go straight to the point. Try the simplest approach first. Be extra concise." The prompt actively discourages over-engineering.
- **Scope discipline**: "Don't add features, refactor code, or make 'improvements' beyond what was asked." / "Don't add error handling for scenarios that can't happen." / "Don't create helpers or utilities for one-time operations."
- **Honesty**: "Never claim 'all tests pass' when output shows failures." / "If you notice a misconception, say so." (Internal users get even stricter honesty directives.)
- **Tool preferences**: Explicit hierarchy — use the dedicated Read tool over `cat`, the Edit tool over `sed`, the Grep tool over `grep`. This is not cosmetic; it routes the agent toward tools with proper permission and safety checks.

**Design principle:** Don't leave behavioral expectations implicit. If you want the agent to be concise, say "be concise." If you want honesty, say "never overclaim." Vague prompts produce vague behavior.

### 2.3 Security Directives in the Prompt

The system prompt includes an explicit security policy (owned by a named safety team, requiring their review for changes):

- **Allowed**: Authorized pentesting, CTFs, defensive security, educational contexts.
- **Blocked**: DoS, mass targeting, supply chain compromise, detection evasion for malicious purposes.
- **Dual-use judgment**: Tools like C2 frameworks require clear authorization context before use.

Separately, the prompt instructs the model to flag suspected prompt injection in tool results rather than silently following injected instructions.

**Design principle:** Embed your security policy in the system prompt, not just in code. The model needs to understand *why* certain actions are dangerous so it can generalize to novel situations. Name the owners and review process in comments so the policy doesn't drift.

### 2.4 Reversibility as a Decision Framework

The prompt establishes a reversibility/blast-radius framework for deciding when to act autonomously vs. when to ask:

- **Freely take**: Local, reversible actions (editing files, running read-only commands, creating branches).
- **Ask first**: Hard-to-reverse actions (deleting files, force-pushing, sending external messages, uploading to third-party tools).

**Design principle:** Give the agent a *decision framework*, not a list of allowed/denied actions. The framework lets it reason about novel situations. The list only covers known cases.

### 2.5 Environment as Context, Not Configuration

Every turn, the dynamic section of the prompt includes:

- Current working directory and OS
- Git repository state (branch, recent commits, modified files)
- Available model IDs and the active model
- Knowledge cutoff date
- A scratchpad directory path for temp files
- Whether old tool results have been cleared from context (prompting the model to write down important information before it vanishes)

**Design principle:** Don't make the agent guess its environment. Inject the ground truth on every turn. This is especially important after compaction, when the model's memory of its environment may be stale.

### 2.6 Persona Variants

Claude Code uses two prompt variants based on user type:

- **External users**: More guardrails, more encouragement to use plan mode, more explanation of capabilities.
- **Internal (Anthropic) users**: Stricter length limits (≤25 words between tool calls, ≤100 words in final responses), more trust, less hand-holding.

There's also a "simple mode" (`CLAUDE_CODE_SIMPLE=true`) that strips the entire dynamic prompt down to 4 lines: identity, CWD, date. Used for testing and minimal-overhead scenarios.

**Design principle:** Different users need different prompt postures. Don't force power users through the same guardrails as beginners. Make the prompt layer configurable without touching the core loop.

### 2.7 Compaction Prompt

When conversation history is summarized, the compaction agent receives a specialized prompt:

- A **no-tools preamble**: "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools." — because the compaction agent inherits the parent's tool pool (for cache sharing), but must not use them.
- An **analysis/summary two-phase structure**: The agent drafts in an `<analysis>` block (which is stripped from the final output), then writes the real summary in a `<summary>` block. This scratchpad technique improves summary quality without polluting the conversation.
- **9 required sections**: Primary request, key technical concepts, files and code, errors and fixes, problem solving, all user messages (preserved verbatim), pending tasks, current work, next step.

**Design principle:** When using an LLM for internal bookkeeping (summarization, memory extraction, classification), give it a tightly constrained prompt. Prevent tool use. Require structured output. Strip the scratchpad from the result.

### 2.8 Instruction Files (CLAUDE.md)

Users inject project-specific instructions via markdown files discovered by walking from the current directory to the root:

- **Loading order** (later = higher priority): managed → user → project → local.
- **Conditional injection**: Frontmatter `paths` field enables glob-based conditional loading (instructions only activate when working in matching files).
- **Transitive includes**: `@include` directive with max depth 5 and cycle prevention.
- **Hard limits**: 40,000 chars per file. HTML comments stripped.

The prompt is explicit: "These instructions OVERRIDE any default behavior and you MUST follow them exactly as written."

**Design principle:** Let users extend the system prompt through files in their project. Make the override semantics clear. Limit file size to prevent prompt injection via enormous instruction files.

---

## 3. Tool Design

### 3.1 Fail-Closed Defaults

Every tool starts with the most restrictive assumptions:

- Not safe to run concurrently (serial execution only)
- Not read-only (requires permission)
- Not destructive (but also not assumed safe)

Developers must explicitly opt into safety properties. This means a forgotten annotation results in *more* permission checks, not fewer.

**Design principle:** New tools should be maximally restricted by default. Force explicit safety declarations. A forgotten flag should make the tool harder to use, not more dangerous.

### 3.2 The Tool as a Rich Protocol

A tool is not just a function. In Claude Code, each tool declares:

- **What it does**: Name, description, search hints for discovery.
- **What it accepts**: Input schema with runtime validation.
- **What it costs**: Whether it's read-only, destructive, long-running.
- **How it interacts with concurrency**: Whether it's safe to run alongside other tools.
- **How to display it**: Separate render functions for the tool call (input) and result (output).
- **How to handle interruption**: Cancel (abort immediately) or block (finish current operation).
- **How its result enters conversation**: A mapping function that converts the raw output into the format the model expects.

**Design principle:** Tools are a contract between the agent, the user, and the system. The richer the contract, the smarter the orchestrator can be about execution, display, and safety.

### 3.3 Progressive Tool Discovery

Dumping all tool schemas into the system prompt wastes 15-20K tokens on tools the model may never use. Claude Code loads only ~10 core tools in the base prompt and makes the rest discoverable via a meta-tool that searches by capability description.

Each tool provides a `searchHint` — a 3-10 word capability description — that the search tool uses for matching.

**Design principle:** Don't front-load all capabilities. Give the model a small set of core tools and a way to discover more. This saves tokens and reduces decision paralysis (40+ tools in a prompt is overwhelming for the model).

### 3.4 String Find-Replace for File Edits

Claude Code uses exact string matching (`old_string` → `new_string`), not unified diffs or patch format. This is a deliberate choice:

- LLMs are unreliable at generating correct line numbers in diffs.
- String matching is self-validating: if `old_string` doesn't match, the tool fails with a clear error.
- No silent corruption from off-by-one line numbers.

**Design principle:** Choose tool interfaces that are robust to LLM imprecision. Prefer self-validating operations (exact match, idempotent APIs) over operations that require precise numeric coordinates.

### 3.5 Tool Result Budget

Tool results can be arbitrarily large. Claude Code caps them:

- Each tool has a `maxResultSizeChars` property.
- Large results are stored to disk; the model receives a ~2KB preview.
- The model can request the full result via a file read if it needs more.

Between turns, a budget enforcement pass (`applyToolResultBudget`) truncates or replaces oversized results in the message history.

**Design principle:** Cap tool output. Provide a preview and a way to get more. Never let a single tool result consume the entire context window.

### 3.6 Hook System for Tool Lifecycle

Every tool execution passes through three hook phases:

1. **Pre-execution hooks**: Can block the tool, modify its input, or auto-approve it.
2. **Permission resolution**: Merges hook decisions with the rule-based permission system.
3. **Post-execution hooks**: Can modify the tool's output.

Hooks are user-configurable shell commands that receive JSON payloads and return JSON responses. They support 20+ event types covering the full lifecycle (session start/end, pre/post tool use, compaction, task creation, etc.).

**Critical invariant**: A hook's "allow" decision does NOT override deny rules. Hooks can add restrictions but cannot remove them.

**Design principle:** Provide lifecycle hooks so users and administrators can observe, modify, and gate tool execution without forking the codebase. But ensure hooks cannot bypass your security model.

### 3.7 Composable Capability Filtering

Not every tool or command should be available in every context. Claude Code applies multiple independent filter layers before exposing a capability:

1. **Auth/provider availability**: Does the current API key grant access to this capability?
2. **Runtime enablement**: Is this feature enabled by the user's configuration and feature flags?
3. **Deployment context**: Is this safe for the current environment (remote session, embedded mode, headless mode)?

Each layer is orthogonal — adding a new filter dimension doesn't require modifying existing ones. The layers compose via AND logic: a capability must pass all filters to be exposed.

**Design principle:** Control capability exposure through composable, orthogonal filter stages. Each stage checks one concern. Adding a new deployment context or auth tier shouldn't require rewriting the filter pipeline.

---

## 4. Memory

### 4.1 Multi-Layer Architecture

Claude Code uses four memory layers, each with a different scope and lifetime:

| Layer | Scope | Lifetime | Update Mechanism |
|-------|-------|----------|-----------------|
| **CLAUDE.md** files | Per-project, per-user, per-machine | Permanent (user-managed) | Manual editing |
| **Auto Memory** (MEMORY.md + topic files) | Per-project | Permanent (agent-managed) | Background extraction + direct writes |
| **Session Memory** | Per-conversation | Session duration | Threshold-gated extraction |
| **Team Memory** | Per-project, shared | Permanent (team-managed) | Sync protocol with secret scanning |

**Design principle:** Memory is not one thing. Different kinds of knowledge (user preferences, project conventions, session state, team knowledge) need different scopes, lifetimes, and update policies.

### 4.2 Index-File Architecture

The `MEMORY.md` file is not a monolithic store. It's a 200-line / 25KB **index** linking to individual topic files. This design:

- Keeps the index small enough to include in every system prompt.
- Allows selective loading of topic files based on relevance.
- Prevents unbounded growth of the prompt-injected memory.
- Makes memory human-readable and manually editable.

**Design principle:** Separate the memory index from memory content. The index lives in the prompt; content is loaded on demand.

### 4.3 LLM-Based Recall, Not Embedding Search

Memory recall works by sending a manifest of available memory files (names and descriptions) to a lightweight LLM side-query, which selects up to 5 relevant files. This is explicitly *not* embedding search.

Why:
- **Cross-domain association**: An LLM can reason that "the user prefers TypeScript" is relevant to a question about language choice in a Python project. Embeddings would miss this.
- **No index maintenance**: No embedding database to build, update, or sync.
- **Context-aware**: The LLM sees the current conversation state when selecting memories.

**Design principle:** For small-to-medium memory stores (hundreds of files, not millions), LLM-based relevance selection outperforms embedding similarity. Use embeddings for pre-filtering at scale, then LLM for final ranking.

### 4.4 Threshold-Gated Extraction

Memory extraction doesn't fire after every turn. Claude Code gates it on:

- **Minimum tokens**: 10K to initialize session memory, 5K between updates.
- **Minimum actions**: 3 tool calls completed between updates.
- **Natural breakpoints**: Extraction only fires when the last assistant turn has no pending tool use, preventing mid-chain artifacts.

**Design principle:** Extract memories at meaningful breakpoints, not at arbitrary intervals. Premature extraction captures incomplete work; too-infrequent extraction loses insights.

### 4.5 Memory Types

Four memory types, each with explicit storage criteria:

- **User**: Cross-project identity (working style, preferences). Scope: private.
- **Feedback**: Things to avoid or repeat, with "why" and "how to apply." Scope: private.
- **Project**: Decisions, conventions, architecture choices. Scope: sharable.
- **Reference**: Pointers to external resources (APIs, libraries). Scope: sharable.

Memories explicitly exclude: code patterns (derivable from code), git history (already in git), debug solutions (ephemeral), content already in CLAUDE.md files (redundant).

**Design principle:** Define what memory is *for* and what it's *not for*. Without explicit exclusion rules, the memory fills with noise.

### 4.6 Secret Scanning for Shared Memory

Before any memory content enters the team-shared layer, a client-side scanner with 30+ regex patterns checks for secrets (API keys, credentials, private keys). The scanner returns only rule IDs, not matched text — preventing the scanner itself from becoming an information leak.

**Design principle:** Scan memory at the write boundary, not just at the read boundary. Return metadata about violations, never the violating content itself.

---

## 5. Context Window Management

### 5.1 Five-Stage Preparation Pipeline

Before every model call, the message history passes through five stages:

1. **Tool result budget** — Truncate oversized tool results.
2. **Snip compaction** — Replace old tool outputs with brief summaries.
3. **Micro-compaction** — Deduplicate paths, code snippets, and other redundant content within messages.
4. **Context collapse** — Merge sequences of similar tool results into summaries.
5. **Auto-compaction** — Full LLM-driven summarization of the entire conversation.

Each stage is progressively more expensive. The pipeline always runs stages 1-3 (cheap). Stages 4-5 only fire when context pressure is high.

**Design principle:** Layer your context management from cheap to expensive. Run cheap transformations on every turn. Run expensive ones only when needed. This way, cheap stages often prevent expensive ones from triggering.

### 5.2 Compaction with Capability Preservation

After summarization, the model loses awareness of its capabilities. Claude Code re-injects:

- **Recently accessed files** (top 5, capped at 50K tokens total)
- **Active plan** (if one exists)
- **Loaded skills** (25K token budget)
- **Tool and MCP server descriptions** that changed since the last known state

**Design principle:** Treat post-compaction as a fresh session start. Everything the model needs to function — not just conversation history, but operational context — must survive compaction.

### 5.3 Circuit Breaker on Compaction Failure

If auto-compaction fails 3 times consecutively, it stops trying. This prevents a pathological loop where compaction keeps failing (perhaps because the remaining context is inherently incompressible) and the system wastes budget on doomed summarization attempts.

**Design principle:** Every automated recovery mechanism needs a circuit breaker. Without one, a persistent failure becomes an infinite loop.

### 5.4 Structured Summaries, Not Free-Form

Compaction produces a 9-section summary with explicit sections for user messages (preserved verbatim), pending tasks, current work state, and next steps. This structure ensures the model doesn't lose track of what the user actually asked for.

**Design principle:** Never use free-form summarization for operational context. Structure forces completeness. Free-form allows the model to forget the boring-but-critical details.

---

## 6. Permission and Safety

### 6.1 Progressive Permission Pipeline

Permission evaluation is a layered pipeline, not a single check:

```
deny rules → ask rules → allow rules → mode-specific default
```

Each layer can short-circuit. Deny rules always win — no later stage can override a denial.

The rules come from 8 sources with strict precedence:
```
policy > flag > local > project > user > cliArg > session > command
```

**Design principle:** Design permissions as a pipeline with early exit. Higher-trust sources override lower-trust sources. Denials are irrevocable.

### 6.2 Permission Modes as a Spectrum

Claude Code offers a spectrum from fully interactive to fully autonomous:

| Mode | Behavior | Trust Level |
|------|----------|-------------|
| `plan` | Read-only; all writes blocked | Lowest (agent explores only) |
| `default` | Ask before non-read-only operations | Normal |
| `acceptEdits` | Auto-approve file edits; ask for everything else | Higher (trusts file ops) |
| `auto` | AI classifier decides | High (trusts the classifier) |
| `bypassPermissions` | Skip all checks | Highest (kill-switchable) |

The user chooses their comfort level. The system respects it.

**Design principle:** Don't force a single permission model. Offer a spectrum from restrictive to permissive, and let users choose. But always provide a "read-only" escape hatch at one end and a "kill switch" at the other.

### 6.3 Auto Mode Safety

When the agent enters autonomous mode, Claude Code:

1. **Strips overly broad allow rules** (e.g., `Bash(*)`) so the classifier sees every action.
2. **Uses a 2-stage classifier**: fast XML-based check first, deeper reasoning only if the fast check blocks.
3. **Bypasses the classifier for safe tools**: Read-only, concurrency-safe tools skip classification entirely.
4. **Excludes model text from classifier input**: Only tool-use blocks are classified, preventing prompt injection through model-authored text.
5. **Tracks consecutive denials**: After too many, falls back to user prompting to prevent classifier loops.
6. **Restores original permissions on exit**.

**Design principle:** Autonomous mode is not "trust everything." It's "trust a classifier, with guardrails." The classifier should operate under *constrained* permissions, not inherit the full human-level permission set.

### 6.4 Command Execution Security

Bash command validation uses three layers:

1. **Static analysis** (23 validators): Detects command substitution, shell injection, dangerous Zsh builtins, encoding attacks, brace expansion bombs, etc. Uses AST parsing (tree-sitter) with regex fallback.
2. **Rule matching**: Exact, prefix, and wildcard matching against user-configured allow/deny lists.
3. **Read-only validation**: A command allowlist with per-flag parsing. Any command containing `$` (variable expansion) is rejected in read-only mode — a deliberately conservative measure that blocks some safe uses but eliminates an entire class of injection attacks.

**Design principle:** Use proper parsing for command validation, not regex alone. Order validators so that regex fallbacks are at least as conservative as the AST path. When in doubt, deny.

### 6.5 Sandbox as Defense in Depth

Even with application-layer permission checks, commands execute inside an OS-level sandbox:

- Write access to settings files is always denied (prevents self-modification of security config).
- Known attack vectors (bare git repo hooks) are scrubbed after execution.
- Network access is domain-allowlisted.

**Design principle:** Don't rely on a single layer. Application-level permissions catch *intended* dangerous actions. The sandbox catches *unintended* ones (exploits, side effects, confused deputies).

### 6.6 The Reversibility/Blast-Radius Heuristic

The system prompt teaches the agent a decision framework:

- **Low risk** (local, reversible): Act freely.
- **Medium risk** (recoverable but noisy): Act, but explain.
- **High risk** (hard to reverse, affects shared state, crosses trust boundaries): Ask first.

Examples of high-risk: deleting files, force-pushing, sending emails, uploading to external services.

**Design principle:** Don't give the agent a binary can/can't. Give it a risk framework that generalizes to novel situations.

---

## 7. Multi-Agent Coordination

### 7.1 Sub-Agent Architecture

Claude Code spawns sub-agents via a tool call (`AgentTool`). Each sub-agent:

- Gets its own system prompt (based on agent type)
- Gets a filtered tool pool (research agents get read-only tools; code agents get the full set)
- Can run in-process, in an isolated git worktree, or remotely
- Can "bubble" permission requests up to the parent

**Fork mode**: A sub-agent can inherit the parent's full conversation history. This enables prompt cache sharing — the forked agent's API prefix is byte-identical to the parent's, so the provider can serve cached KV states. This makes sub-agents cheap.

**Design principle:** Sub-agents should be cheap to spawn (cache sharing), isolated by default (own tool pool, own working directory), and able to escalate decisions they can't make (permission bubbling).

### 7.2 Coordinator Mode

In coordinator mode, the system transforms from a single-agent REPL into a multi-agent orchestrator:

- The **coordinator** can only spawn agents, communicate with them, and stop them. It cannot directly execute tools.
- **Workers** execute tools and report back.
- The workflow is structured: Research → Synthesis → Implementation → Verification.
- The coordinator's most important job is **synthesis**: reading worker results, understanding the approach, and writing precise implementation prompts with specific file paths, line numbers, and exact changes.

**Anti-patterns the coordinator prompt explicitly warns against**: "Fix the bug we discussed" (lazy delegation), ambiguous scope, no-context corrections, delegating synthesis.

**Design principle:** The coordinator synthesizes — it doesn't delegate comprehension. If the coordinator doesn't understand the worker's output well enough to write specific instructions, it should ask the worker for more detail, not pass the ambiguity along.

### 7.3 Task Types

Seven task types with different execution models:

| Type | Execution | Isolation |
|------|-----------|-----------|
| Local bash | Shell process | Sandboxed |
| Local agent | In-process | Shared or worktree |
| Remote agent | Cloud | Full isolation |
| In-process teammate | Same process | Shared state |
| Local workflow | Multi-step script | Varies |
| Monitor MCP | Background watcher | None |
| Dream | Background ideation | Full isolation |

**Design principle:** Different work requires different isolation levels. Read-only research can share state; file-modifying implementation needs isolation; speculative work needs full sandboxing.

---

## 8. Self-Correction and Verification

### 8.1 Plan Mode as a Reasoning Gate

Plan mode constrains the agent to read-only operations, forcing it to think before acting. The agent can read files, search code, and reason about approaches, but cannot modify anything until the user approves the plan and exits plan mode.

This is not just a safety feature — it's a **reasoning quality feature**. Forcing the model to articulate a plan before acting improves the quality of the subsequent implementation.

**Design principle:** Give the agent a way to "think without acting." The constraint improves reasoning quality by separating planning from execution.

### 8.2 Extended Thinking

Three thinking modes:

- **Adaptive**: The model decides when to think deeper based on query complexity. This is the default.
- **Enabled with budget**: Always use extended thinking with a specified token allocation.
- **Disabled**: No extended thinking (used for quick utility tasks).

An "ultrathink" mode provides significantly more thinking tokens for especially complex problems, triggered by a keyword in the user's message.

**Design principle:** Make thinking budget controllable. Default to adaptive (let the model decide), but allow users to force deeper reasoning when they know the problem is hard.

### 8.3 Adversarial Verification

The verification agent operates in read-only mode with an explicitly adversarial posture:

- "Your job is not to confirm the implementation works — it's to try to break it."
- Two documented failure patterns the verification agent is warned about: *verification avoidance* (reading code and narrating instead of running tests) and *being seduced by the first 80%* (seeing polished UI but missing broken state persistence).
- Required: actual command output for every check. "A check without a Command run block is not a PASS — it's a skip."
- Three verdicts: PASS, FAIL, PARTIAL (partial only for environmental limitations).

**Design principle:** Verification should be adversarial, evidence-based, and structured. The verifier should be a separate agent with different incentives than the implementer. Require proof (command output), not assertions.

### 8.4 Structured Output Enforcement

A stop hook can force the model to call a verification tool (`{ok: boolean, reason?: string}`) before ending its turn. If the model tries to end without calling the tool, the hook re-prompts it.

**Design principle:** When you need the model to produce structured output, enforce it at the loop level — not just in the prompt. Prompts can be ignored; stop hooks cannot.

### 8.5 Prompt Suggestion and Speculation

After each turn, a lightweight side-query predicts what the user will ask next. Then:

1. A forked agent speculatively executes the predicted prompt.
2. File writes go to a copy-on-write overlay, not the real workspace.
3. Execution stops at the first operation that would require permission.
4. If the user accepts, overlay files are copied to the workspace.
5. While the user reads the current response, the system is already speculating on the *next* turn.

**Design principle:** Use idle time productively. Speculative execution with copy-on-write isolation lets you pre-compute likely next steps without risk.

---

## 9. Autonomous and Background Operation

### 9.1 Scheduled Execution

Agents can be scheduled via cron expressions. The scheduler handles:

- **Lock-based ownership**: Prevents double-firing across multiple agent instances.
- **Jitter**: Recurring tasks get up to 10% period jitter; one-shot tasks on round times get up to 90 seconds. Prevents thundering-herd effects.
- **Missed task surfacing**: One-shot tasks missed during downtime are presented to the user on next startup.
- **Auto-expiry**: Recurring tasks expire after a configurable maximum age.

**Design principle:** Background scheduling needs ownership locks, jitter, expiry, and missed-task handling. Don't just run a cron; build the infrastructure to make it reliable across restarts and concurrent instances.

### 9.2 Proactive Mode

When the terminal is unfocused, the agent leans into autonomous action: make decisions, commit, push. When the terminal is focused, it's more collaborative: surface choices, ask before large changes.

The agent must call a sleep tool when idle. No idle text output. "Bias toward action" when unfocused; "bias toward collaboration" when focused.

**Design principle:** Terminal focus is a proxy for user attention. When the user is away, the agent should be productive. When the user is present, the agent should be collaborative.

### 9.3 Background Memory Extraction

After each conversation, a background agent extracts memories from the conversation into persistent storage. This runs asynchronously, never blocking the user, with mutual exclusion against the main agent's direct memory writes.

**Design principle:** Memory extraction should be a background, non-blocking, non-interfering process. The user should never wait for the agent to finish remembering.

---

## 10. Observability and Feedback

### 10.1 Type-Level PII Prevention

The analytics metadata type structurally excludes strings. Only numbers, booleans, and explicitly tagged fields are allowed. Fields that must contain strings use a branded type with an intentionally long name (`_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS`) that serves as a review prompt.

**Design principle:** Don't rely on code review to catch PII in telemetry. Use your type system to make PII logging a compile error, not a runtime leak.

### 10.2 Queue-Then-Drain Event Pipeline

Events are buffered from process start. When the telemetry backend initializes, the buffer is drained. This ensures startup metrics — often the most diagnostic — are never lost.

**Design principle:** Decouple event generation from event transport. Buffer from the first line of code. Drain when the transport is ready.

### 10.3 Dual-Backend Resilience

Events go to two independent backends (Datadog and a first-party endpoint). Failed events are persisted to disk for retry with quadratic backoff. If one backend is down, the other continues.

**Design principle:** Don't depend on a single telemetry backend. Persist failed events locally and retry. Your observability system should be more reliable than the systems it observes.

### 10.4 Session Recording for Deterministic Replay

A VCR mode records API interactions keyed by content hash (with non-deterministic fields like timestamps stripped). This enables deterministic replay for testing without requiring a live API.

**Design principle:** Record API interactions for replay testing. Hash inputs after stripping non-deterministic fields. This creates regression tests that work without network access.

---

## 11. Configuration and Policy

### 11.1 Layered Settings with Clear Precedence

Five layers, from highest to lowest priority:

1. **Policy** (organization-managed) — Cannot be overridden by anyone downstream.
2. **Feature flags** (remote A/B testing) — Dynamic, no redeployment needed.
3. **Local** (per-machine) — Machine-specific overrides.
4. **Project** (per-repository) — Committed to source control, shared with team.
5. **User** (per-person) — Personal preferences.

**Design principle:** Configuration is not flat. Different sources have different trust levels. Make the precedence explicit and document it.

### 11.2 Compile-Time Feature Elimination

Security-sensitive code uses compile-time flags that resolve to boolean literals, enabling dead code elimination. Internal-only code is physically absent from external builds — not disabled, not obfuscated, *absent*.

**Design principle:** For code that shouldn't exist in a build, don't rely on runtime flags. Use compile-time elimination so the code is never shipped.

### 11.3 Graceful Degradation

- Feature flags use a disk cache for offline operation.
- Policy limits follow a fail-open design (if the policy server is unreachable, the agent continues with defaults, except for privacy-critical policies which fail closed).
- Configuration migrations that fail don't block startup.

**Design principle:** Every remote dependency needs a fallback. The agent should remain functional when disconnected, degraded when dependencies fail, and never blocked on a non-critical service.

### 11.4 Dual-Mode Error Strategy

In production, non-critical errors are caught, logged, and swallowed — the agent stays alive. But in development, those same swallowed errors would hide bugs. Claude Code solves this with a `--hard-fail` flag that converts graceful degradation into crash-on-any-error.

- **Production mode**: Errors are caught at boundaries, logged, and replaced with fallbacks. The agent never crashes on a non-critical failure.
- **Development mode**: Every logged error terminates the process immediately, making silent failures impossible to miss.

**Design principle:** Resilient error handling and strict error visibility are both essential — just in different contexts. Provide a single flag that switches between them. Developers should see what production silently handles.

### 11.5 Resource Cleanup Registration

Long-running agents accumulate resources — open files, network connections, child processes, temporary directories. Claude Code uses a centralized `registerCleanup()` pattern: each resource registers its own async cleanup callback at creation time, and all callbacks run on process exit.

This decouples resource creation from shutdown orchestration. The module that creates a temp directory is also the module that knows how to clean it up — the shutdown sequence doesn't need to know about every resource type.

**Design principle:** Resources should register their own cleanup at creation time. A centralized cleanup registry ensures orderly shutdown without requiring a god function that knows about every subsystem.

---

## 12. Design Tensions

Every major design decision in Claude Code reflects a tension between competing goals. Understanding these tensions is more valuable than memorizing specific implementations.

| Tension | Claude Code's Resolution |
|---------|--------------------------|
| **Latency vs. safety** | Speculative execution with copy-on-write isolation; streaming tool execution with abort-on-error. Fast by default, safe by constraint. |
| **Autonomy vs. control** | A spectrum of 6 permission modes. Users choose their comfort level. Auto mode uses a classifier, not blanket trust. |
| **Memory completeness vs. token cost** | Threshold-gated extraction (not every turn). LLM-based recall (select 5, not load all). Index-file architecture (small index in prompt, large content on demand). |
| **Context size vs. quality** | Five-stage preparation pipeline, cheapest first. Structured 9-section summaries preserve operational context. Post-compaction capability re-injection. |
| **Offline vs. connected** | Disk-cached feature flags. Local event persistence. File-based memory. The agent works offline; it works better online. |
| **Enterprise vs. individual** | 5-layer settings with organization policy at the top. Kill-switchable bypass mode. MDM integration for managed deployment. |
| **Single-agent simplicity vs. multi-agent power** | Same core loop powers both modes. Coordinator mode adds orchestration on top; it doesn't replace the engine. Fork mode makes sub-agents cheap via cache sharing. |
| **Prompt cache efficiency vs. dynamic context** | Static/dynamic split with explicit boundary marker. Static content (identity, rules, security) is cached. Dynamic content (environment, memory, tools) changes per turn. |
| **Security thoroughness vs. user experience** | Progressive permission pipeline with early exit. Speculative classifier runs in parallel with other checks to hide latency. Recoverable errors are withheld during recovery. |
| **Tool richness vs. prompt bloat** | Deferred tool loading via meta-tool search. Only ~10 core tools in base prompt. Others discovered on demand, saving 15-20K tokens. |

**The meta-principle:** Good agent design is not about choosing one side of a tension. It's about finding mechanisms that give you *most* of both sides. Speculation gives you latency *and* safety. Threshold gating gives you memory *and* efficiency. Permission modes give you autonomy *and* control.

---

*This document distills design practices inspired by Claude Code's architecture. It is intentionally language-agnostic and framework-agnostic. The patterns here reflect production-scale practices from a system with 41 tools, 100+ commands, and multi-agent coordination. They are not theoretical — they are derived from a working, shipping product.*
