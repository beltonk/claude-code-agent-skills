# Claude Code Analysis & Agent Skills

A comprehensive architecture analysis of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — Anthropic's agentic coding tool — plus a reusable **agent skills pack** that brings its design patterns to any AI agent or IDE.

Claude Code is a production agentic system that reads codebases, edits files, runs commands, manages memory, coordinates sub-agents, and operates autonomously. We studied its publicly available architecture and produced:

1. **[Architecture Analysis](#architecture-overview)** — Six documents covering the agent loop, prompt engineering, tool system, memory, permissions, multi-agent coordination, and more.
2. **[Reusable Agent Skills](#the-agent-skills-pack)** — A drop-in `AGENTS.md` system prompt and 9 standalone agent skills, LLM-agnostic and IDE-agnostic.
3. **[From Analysis to Agent Skills](#from-analysis-to-agent-skills)** — What was distilled into skills, what wasn't (and why), and how to implement the rest.

---

## Architecture Overview

> How Claude Code turns an LLM into a terminal-based coding agent — the design patterns, prompt engineering, safety mechanisms, and memory strategies that make it work.

### The Agent Loop

A flat `while(true)` state machine (not recursive): **prepare context → call the model → parse tool calls → execute tools → feed results back**. Each iteration carries an explicit state object with 10 fields. The loop has 10 termination conditions and 7 retry strategies.

Between turns, a five-stage context pipeline manages the window:

1. **Truncate** oversized tool results
2. **Snip** stale historical outputs
3. **Micro-compact** redundant content within messages
4. **Collapse** sequences of similar tool results
5. **Auto-compact** via full LLM-driven summarization (only when needed)

Stages 1–3 are cheap and run every turn. Stages 4–5 are expensive and only fire under context pressure — cheap operations often prevent expensive ones from triggering.

→ *[Design Handbook §1](./analysis/04-design-handbook.md#1-the-agent-loop) · [Architecture Dossier §1](./analysis/01-architecture-dossier.md#1-orchestration-and-control-loops)*

### Prompt Engineering

The system prompt is split into a **static prefix** (identity, behavioral rules, security policy, tool preferences) that stays in the LLM's prompt cache, and a **dynamic suffix** (environment, memory, tools, git state) that changes per turn — a deliberate cache optimization that saves significant cost at scale.

- **Behavioral directives are explicit**: "Be concise." "Don't add features beyond what was asked."
- **Security policy is embedded in the prompt** — the model needs to understand *why* actions are dangerous.
- **A reversibility framework** teaches the agent when to act freely vs. when to ask.
- **Tool preference hierarchies** route the model toward tools with proper safety checks.
- **User-authored instruction files** (CLAUDE.md) extend the system prompt per-project.

→ *[Design Handbook §2](./analysis/04-design-handbook.md#2-prompt-engineering) · [Architecture Dossier §4](./analysis/01-architecture-dossier.md#4-reasoning-and-self-correction)*

### Tool System

41 tools, but only ~10 loaded into the base prompt. The rest are discoverable via a meta-tool — saving 15–20K tokens per prompt.

Every tool is a rich protocol declaring concurrency safety, read-only status, destructiveness, interruption behavior, and result mapping. **Fail-closed defaults** mean a forgotten safety annotation makes the tool *harder* to use, not more dangerous.

Execution pipeline: **schema validation → input validation → speculative classifier → pre-hooks → permission check → execution → post-hooks → result mapping**. File editing uses **string find-replace**, not diff/patch — self-validating and robust to LLM imprecision.

→ *[Design Handbook §3](./analysis/04-design-handbook.md#3-tool-design) · [Patterns Catalog §5–9](./analysis/02-patterns-catalog.md#5-fail-closed-tool-factory)*

### Memory

| Layer | Stores | Lifetime | Updated by |
|-------|--------|----------|------------|
| **CLAUDE.md files** | Project instructions, coding standards | Permanent | User |
| **Auto Memory** | Learned preferences, conventions | Permanent | Background extraction |
| **Session Memory** | Current conversation context | Session | Threshold-gated extraction |
| **Team Memory** | Shared knowledge across collaborators | Permanent | Sync with secret scanning |

`MEMORY.md` is an **index** (~200 lines) linking to topic files — not a monolithic store. Memory recall is **LLM-based** (a side-query selects top-5 relevant files), not embedding-based — better cross-domain association, no index to maintain.

→ *[Design Handbook §4](./analysis/04-design-handbook.md#4-memory) · [Patterns Catalog §10–13](./analysis/02-patterns-catalog.md#10-index-file-memory-architecture)*

### Permission and Safety

A **progressive pipeline**: deny → ask → allow → mode default. Deny rules **always win** — no hook, classifier, or configuration can override a denial.

| Mode | Behavior |
|------|----------|
| **Plan** | Read-only |
| **Default** | Ask before non-read-only operations |
| **Accept Edits** | Auto-approve file edits, ask for the rest |
| **Auto** | AI classifier decides; broad permissions stripped on entry |
| **Bypass** | Skip all checks; kill-switchable remotely |

Shell commands are protected by **AST-based validators** (with regex fallback), **rule matching**, and an **LLM classifier** as last resort, all inside an **OS-level sandbox**.

→ *[Design Handbook §6](./analysis/04-design-handbook.md#6-permission-and-safety) · [Patterns Catalog §14–18](./analysis/02-patterns-catalog.md#14-progressive-permission-pipeline)*

### Multi-Agent Coordination

Sub-agents **fork** the parent's context for prompt cache sharing, making them cheap. They run in-process, in isolated git worktrees, or remotely. **Coordinator mode** creates a multi-agent orchestrator with a structured workflow: Research → Synthesis → Implementation → Verification.

→ *[Design Handbook §7](./analysis/04-design-handbook.md#7-multi-agent-coordination)*

### Self-Correction

- **Plan mode** — read-only constraints improve reasoning quality
- **Extended thinking** — adaptive, budgeted, or disabled
- **Adversarial verification** — a separate agent tries to break the implementation, requires evidence
- **Speculative execution** — predict next request, pre-execute against a copy-on-write overlay

→ *[Design Handbook §8](./analysis/04-design-handbook.md#8-self-correction-and-verification)*

---

## Key Lessons

The most transferable insights for any LLM agent system:

**Prompt Engineering** — Split prompts for cache efficiency. Be explicit about behavior. Embed security policy in the prompt. Give the agent a decision framework (reversibility heuristic), not a decision list.

**Memory** — Use an LLM for recall, not embeddings (at small-to-medium scale). Separate the memory index from content. Gate extraction on meaningful thresholds, not every turn.

**Tools** — Fail-closed defaults. Design interfaces for LLM imprecision (string match over diffs). Cap tool output. Progressive discovery instead of dumping all schemas.

**Safety** — Deny rules are irrevocable. Use AST parsing for command validation, not just regex. Autonomous mode ≠ trust everything. Sandbox is defense in depth.

**Architecture** — Flat state machine, not recursion. Layer context management cheap-to-expensive. Every recovery needs a circuit breaker. Sub-agents should be cheap (cache sharing), isolated, and able to escalate.

**Meta** — Good design resolves tensions, not picks sides. Speculation gives latency *and* safety. Threshold gating gives memory *and* efficiency. Permission modes give autonomy *and* control.

---

## From Analysis to Agent Skills

The analysis covers 12 architectural domains and 22 reusable patterns. The agent skills pack distills a subset of these into *actionable instructions that an LLM can follow directly*. This section maps what was distilled, what was left out, and why — and points you toward implementing the rest.

### What the skills pack covers

The AGENTS.md system prompt and 9 agent skills encode the patterns that govern **how an agent behaves turn-by-turn** — the decisions it makes, the discipline it follows, and the workflows it runs. These are the patterns where natural-language instructions to an LLM are the implementation.

| Analysis Domain | What's Distilled | Where |
|-----------------|-----------------|-------|
| **Prompt engineering** (§2) | Static/dynamic split, cache boundary, assembly order, prompt layering, environment injection | AGENTS.md §System Prompt Architecture |
| **Tool design** (§3) | Tool preference hierarchy, match-based edits, result handling, progressive discovery | AGENTS.md §Using Your Tools |
| **Memory** (§4) | Index-file architecture, threshold-gated extraction, staleness detection, secret scanning, LLM-based recall | managing-memories skill |
| **Context management** (§5) | 9-section structured summaries, two-phase compression, post-compact re-injection | compacting-context skill |
| **Permission & safety** (§6) | Reversibility framework, risk assessment heuristic, security policy, prompt injection defense | AGENTS.md §Executing Actions with Care, agentic-standards skill |
| **Multi-agent coordination** (§7) | Research→Synthesis→Implementation→Verification workflow, self-contained worker prompts, worktree isolation | coordinating-agents skill |
| **Self-correction** (§8) | Adversarial verification, evidence requirements, plan-mode reasoning | verifying-implementations skill |
| **Session continuity** | Structured handoff documents, session memory extraction | handing-off-sessions skill |
| **Code review** | Severity classification, independent verification, conflict resolution | receiving-code-review skill |
| **Project onboarding** | Structured scaffolding, project exploration | scaffolding-projects skill |

### What the skills pack does NOT cover

The remaining patterns are **infrastructure concerns** — they require code running *around* the LLM, not instructions *to* the LLM. You can't tell a model to "implement a streaming parser" or "sandbox yourself" in a system prompt. These patterns must be built into the agent framework, the IDE, or the deployment platform.

| Analysis Domain | Why It's Not a Skill | How to Implement |
|-----------------|---------------------|------------------|
| **Agent loop** (§1) — flat state machine, streaming, overlapped execution, recovery cascade | The loop is the runtime that *hosts* the agent. The LLM runs inside it; it can't implement it. | Build a `while(true)` loop with explicit state objects. Use an AsyncGenerator (JS/TS) or `async for` (Python) to yield events. Define all termination conditions upfront. See [Pattern #1](./analysis/02-patterns-catalog.md#1-asyncgenerator-state-machine) and [Pattern #3](./analysis/02-patterns-catalog.md#3-progressive-recovery-cascade). |
| **Streaming & withholding** (§1.3–1.4) — progressive rendering, error buffering during recovery | These are UI/transport concerns between the agent loop and the display layer. | Buffer errors during active retries; only surface when unrecoverable. Start tool execution before the model finishes generating when tool inputs are complete. See [Pattern #2](./analysis/02-patterns-catalog.md#2-withholding-mechanism) and [Pattern #7](./analysis/02-patterns-catalog.md#7-streaming-tool-execution). |
| **Tool execution pipeline** (§3) — schema validation, pre/post hooks, concurrency partitioning | The pipeline that *wraps* tool calls is framework code, not LLM behavior. | Implement a pipeline: validate schema → run pre-hooks → check permissions → execute → run post-hooks → map results. Declare concurrency safety per tool. See [Pattern #5](./analysis/02-patterns-catalog.md#5-fail-closed-tool-factory) and [Pattern #6](./analysis/02-patterns-catalog.md#6-concurrency-partitioning). |
| **Permission pipeline** (§6) — deny→ask→allow→mode default, AST-based command validation, OS sandbox | Permission enforcement requires intercepting tool calls at runtime. An LLM can follow a *heuristic*, but the actual gate must be code. | Build a progressive pipeline where deny rules are irrevocable. Use AST parsing (not just regex) for shell command validation. Layer an OS sandbox as defense in depth. See [Pattern #14](./analysis/02-patterns-catalog.md#14-progressive-permission-pipeline) and [Pattern #15](./analysis/02-patterns-catalog.md#15-ast-based-security-with-regex-fallback). |
| **Autonomous operation** (§9) — background execution, speculative execution, copy-on-write | Background and speculative modes require process management, filesystem overlays, and scheduling — all outside the LLM. | Run the agent loop headlessly with structured output. For speculation, pre-execute likely next requests against a COW filesystem snapshot; discard on misprediction. See [Design Handbook §9](./analysis/04-design-handbook.md#9-autonomous-and-background-operation). |
| **Observability** (§10) — telemetry, queue-then-drain sinks, no-string metadata types | Telemetry is an infrastructure concern. The LLM doesn't instrument itself. | Buffer events from startup, drain when the sink is ready. Use type systems to prevent PII in telemetry payloads. See [Pattern #21](./analysis/02-patterns-catalog.md#21-no-string-metadata-type) and [Pattern #22](./analysis/02-patterns-catalog.md#22-queue-then-drain-sink). |
| **Configuration & feature gating** (§11) — build-time DCE, three-tier gating, 5-layer settings | Configuration systems are application code, not behavioral rules. | Use three tiers: build-time flags (dead-code elimination), runtime flags, and identity-based gates. Layer settings: defaults → org policy → user prefs → project → session. See [Pattern #19](./analysis/02-patterns-catalog.md#19-compile-time-feature-flag-dce) and [Pattern #20](./analysis/02-patterns-catalog.md#20-three-tier-gating). |
| **Diminishing returns detection** (§1) — stopping after low-output continuations | Requires measuring token output per turn from outside the model. | Track output volume per continuation. After 3+ consecutive low-output turns, stop the loop. See [Pattern #4](./analysis/02-patterns-catalog.md#4-diminishing-returns-detection). |

### Why distill into skills at all?

The analysis documents are written for engineers building agent systems. The skills pack is written for agents *being* agent systems. The distinction matters:

- **Prompt-level patterns work.** An LLM that reads "verify before claiming done" and "re-read files after context compression" actually does those things. Behavioral instructions are the implementation for patterns that govern judgment and discipline.
- **Token efficiency.** AGENTS.md is ~4K tokens — always loaded. Skills load on demand. Reference docs load only when depth is needed. The full analysis is ~80K tokens; you'd never load it all into context. The skills pack is a lossy compression optimized for the LLM as the reader.
- **Portable.** The skills are LLM-agnostic and IDE-agnostic. They work in Cursor, Claude Code, OpenCode, or any agent framework that can load instruction files. No code dependency, no runtime dependency.
- **Composable.** Each skill is standalone. Use one, use all, or mix with your own. The AGENTS.md is optional — skills work without it.
- **Grounded.** Every pattern in the skills pack traces back to a production system (Claude Code). They're not theoretical best practices — they're distilled from observed architecture.

### The gap in between

Between "patterns the LLM can follow" (skills) and "patterns that require framework code" (infrastructure) sits a middle ground: patterns where **the framework provides the mechanism** and **the skill teaches the agent when and how to use it**.

Examples already in the pack:
- **Memory**: the framework provides a filesystem; the skill teaches the agent *what* to remember, *when* to extract, and *how* to organize it.
- **Multi-agent coordination**: the framework provides sub-agent spawning; the skill teaches the agent *when* to parallelize, *how* to write worker prompts, and *how* to synthesize results.
- **Context management**: the framework triggers compaction; the skill teaches the agent *how* to summarize without losing critical information.

If you're building an agent framework, the analysis documents tell you what mechanisms to provide. The skills tell you what the agent should do with them.

---

## Design Tensions

| Tension | Resolution |
|---------|------------|
| **Latency vs. safety** | Speculative execution with copy-on-write. Streaming tools with abort-on-error. |
| **Autonomy vs. control** | 6 permission modes. Auto mode uses a classifier under constrained permissions. |
| **Memory vs. token cost** | Threshold-gated extraction. LLM recall (select 5, not load all). Index-file architecture. |
| **Context size vs. quality** | Five-stage pipeline, cheapest first. 9-section structured summaries. |
| **Offline vs. connected** | Disk-cached flags. Local event persistence. File-based memory. |
| **Enterprise vs. individual** | 5-layer settings. Organization policy at the top. Kill-switchable bypass. |
| **Single vs. multi-agent** | Same core loop. Coordinator on top. Fork mode for cheap sub-agents. |
| **Cache efficiency vs. dynamic context** | Static/dynamic prompt split. |
| **Security vs. UX** | Progressive pipeline with early exit. Speculative classifier hides latency. |
| **Tool richness vs. prompt bloat** | Meta-tool search. ~10 core + 30 discoverable. |

---

## 22 Reusable Patterns

| # | Pattern | Domain | Key Insight |
|---|---------|--------|-------------|
| 1 | AsyncGenerator State Machine | Orchestration | Flat loop + explicit state + yield |
| 2 | Withholding Mechanism | Streaming | Buffer errors during recovery |
| 3 | Progressive Recovery Cascade | Resilience | 7 strategies, cheapest first |
| 4 | Diminishing Returns Detection | Cost Control | Stop after 3+ low-output continuations |
| 5 | Fail-Closed Tool Factory | Security | Restrictive defaults, explicit opt-in |
| 6 | Concurrency Partitioning | Performance | Tools self-declare safety |
| 7 | Streaming Tool Execution | Latency | Start before model finishes |
| 8 | Deferred Tool Loading | Tokens | Meta-tool discovers non-core tools |
| 9 | Tool Result Budget | Context | Preview in context, full on disk |
| 10 | Index-File Memory | Memory | Small index in prompt, content on demand |
| 11 | LLM-Based Semantic Recall | Retrieval | Side-query from manifest |
| 12 | Threshold-Gated Extraction | Memory | Extract at breakpoints only |
| 13 | Post-Compact Re-injection | Context | Re-inject capabilities after summarization |
| 14 | Progressive Permission Pipeline | Security | Deny → ask → allow → default |
| 15 | AST + Regex Fallback | Validation | Parse first, regex fallback |
| 16 | Post-Sandbox Scrubbing | Security | Clean attack vectors after execution |
| 17 | Deny-Rules-Always-Win | Policy | Irrevocable denials |
| 18 | Permission Stripping on Autonomy | Safety | Strip broad rules on auto-mode entry |
| 19 | Compile-Time Feature DCE | Build | Absent from external builds, not just disabled |
| 20 | Three-Tier Feature Gating | Config | Build-time + runtime + identity-based |
| 21 | No-String Metadata Type | Privacy | Type system prevents PII in telemetry |
| 22 | Queue-Then-Drain Sink | Observability | Buffer from startup, drain when ready |

→ *Full catalog: [Patterns Catalog](./analysis/02-patterns-catalog.md)*

---

## The Agent Skills Pack

Drop `skills/` into any project to equip your AI agent with Claude Code–inspired behavioral patterns.

| Layer | What | Token cost |
|-------|------|------------|
| `AGENTS.md` | System prompt — behavioral rules, safety, memory, context management, prompt architecture | Always loaded (~4K tokens) |
| 9 agent skills | Verification, context compaction, multi-agent coordination, memory management, session handoff, scaffolding, code review, coding standards, general standards | On trigger |
| 9 reference docs | Tool design checklist, permission pipeline, system prompt architecture, agent types, templates | On demand |
| 9 bash scripts | Project detection, test runners, token estimation, worktree management, secret scanning, memory indexing | Called by skills |

**Works with:** Cursor, OpenCode, Antigravity, Claude Code, or any AI IDE supporting `AGENTS.md` or agent skills.

→ *Full guide: [skills/README.md](./skills/README.md)*

---

## Analysis Documents

| Document | Focus | Depth |
|----------|-------|-------|
| [Design Handbook](./analysis/04-design-handbook.md) | Practices, patterns, philosophy — language-agnostic | Design |
| [Patterns Catalog](./analysis/02-patterns-catalog.md) | 22 patterns + 7 anti-patterns with guidance | Pattern |
| [Architecture Dossier](./analysis/01-architecture-dossier.md) | Architecture across 8 domains | Architecture |
| [Implementation Blueprint](./analysis/03-implementation-blueprint.md) | Data types, control flow, module maps | Implementation |
| [Third-Party Comparison](./analysis/05-third-party-comparison.md) | Cross-checking 6 independent analyses | Comparison |
| [Reusable Assets](./analysis/06-reusable-assets.md) | Prompts, schemas, pipelines, templates | Asset |

**Reading paths:**

- **Build something similar** → This README → [Design Handbook](./analysis/04-design-handbook.md) → [Patterns Catalog](./analysis/02-patterns-catalog.md) → [Blueprint](./analysis/03-implementation-blueprint.md)
- **Understand the architecture** → This README → [Architecture Dossier](./analysis/01-architecture-dossier.md) → [Design Handbook](./analysis/04-design-handbook.md)
- **Extract reusable patterns** → [Design Handbook §12](./analysis/04-design-handbook.md#12-design-tensions) → [Patterns Catalog](./analysis/02-patterns-catalog.md)
- **Copy specific assets** → [Reusable Assets](./analysis/06-reusable-assets.md)
- **Equip your AI agent** → [From Analysis to Agent Skills](#from-analysis-to-agent-skills) → [skills/README.md](./skills/README.md)
- **Build the framework, equip the agent** → [From Analysis to Agent Skills](#from-analysis-to-agent-skills) (what to build vs. what to prompt)

---

## Inspiration

This project was inspired by the architecture of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by [Anthropic](https://www.anthropic.com/). The analysis and skills are original works that capture design patterns and architectural ideas in a technology-agnostic form. No source code is included or redistributed.

## Disclaimer

This project is **not** affiliated with, endorsed by, or supported by Anthropic. All content is original work provided for **educational and reference purposes**.
