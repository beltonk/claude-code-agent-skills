# Reusable Patterns & Anti-Patterns Catalog

> Technology-agnostic guidance for engineers building LLM agent systems, inspired by Claude Code's architecture.

---

## How to Use This Catalog

Each pattern follows a consistent structure:

1. **Problem** — What architectural challenge the pattern addresses.
2. **How Claude Code Implements It** — Source-level details.
3. **Technology-Agnostic Guidance** — How to apply the pattern in any LLM agent stack.
4. **Copy / Avoid / Adapt** — Concrete dos, don'ts, and adaptation notes.

Patterns are grouped by architectural domain. Anti-patterns are collected at the end with pointers to the patterns that replace them.

---

## Orchestration Patterns

### 1. AsyncGenerator State Machine

**Category:** Control Flow / Main Loop

**Problem:** Agent loops that use recursion risk stack overflow on long sessions. Event-driven loops couple control flow to the event system, making cancellation and backpressure difficult. The main loop needs to support progressive rendering, mid-turn cancellation, and explicit state transitions without accumulating stack frames.

**How Claude Code Implements It**

`queryLoop()` in `src/query.ts` is a `while(true)` loop that yields control via an AsyncGenerator. Each iteration creates a new immutable `State` object (10 fields including transition reason). The loop does not recurse—it branches on state transitions (`next_turn`, `collapse_drain_retry`, `reactive_compact_retry`, `max_output_tokens_escalate`, `max_output_tokens_recovery`, `stop_hook_blocking`, `token_budget_continuation`) and continues. `submitMessage()` in `src/QueryEngine.ts` is an AsyncGenerator yielding `SDKMessage` events to consumers.

**Technology-Agnostic Guidance**

Implement your agent's main loop as a generator (or coroutine) that yields events to the caller. Represent loop state as an explicit, immutable data structure—not as local variables scattered across stack frames. Each continuation creates a fresh state object; the loop reads the state and branches.

**Copy:** Explicit immutable state objects per iteration. Generator-based main loop with yield points for cancellation and rendering. Flat branching on transition type rather than nested conditionals.

**Avoid:** Recursive agent calls (stack overflow risk on long sessions). Event-emitter-driven loops where backpressure is hard to implement. Mutable shared state that multiple continuations can race on.

**Adapt:** In Python, use `async for` over an `AsyncGenerator`. In Go, use a channel-based loop with a state struct. The key invariant is: one loop, explicit state, no recursion.

---

### 2. Withholding Mechanism

**Category:** Error UX / Streaming

**Problem:** In streaming UIs, transient errors (API timeouts, rate limits, retryable failures) flash momentarily before recovery succeeds, creating a jarring user experience. Users see errors that never actually mattered.

**How Claude Code Implements It**

Recoverable errors in the query loop are withheld from the UI during recovery attempts. They are buffered internally and only released to the rendering layer if all recovery paths fail. This prevents error flash in the streaming terminal UI while retries are in progress.

**Technology-Agnostic Guidance**

Buffer errors that have remaining recovery paths. Only surface an error to the user when it is definitively unrecoverable. Maintain an error buffer alongside the retry state machine so the UI layer never sees intermediate failures.

**Copy:** Error buffering during active recovery. Clear separation between "error detected" and "error displayed."

**Avoid:** Showing every transient error to users. Suppressing errors entirely (users need to know when recovery truly fails).

**Adapt:** In web UIs, use a pending-error state in your store that only promotes to visible-error after retry exhaustion. In CLI tools, hold back stderr output during retry windows.

---

### 3. Progressive Recovery Cascade

**Category:** Resilience / Error Recovery

**Problem:** LLM API calls fail in diverse ways—context too long, output truncated, streaming interrupted, rate limited. A single retry strategy cannot address all failure modes. Giving up after one failure wastes the work already done in a turn.

**How Claude Code Implements It**

The query loop in `src/query.ts` has 7 distinct continuation/retry paths, ordered by increasing cost:

1. **Streaming fallback** — Retry on stream interruption.
2. **Collapse drain** (`collapse_drain_retry`) — Drain partial output, collapse context, retry.
3. **Reactive compact** (`reactive_compact_retry`) — Run compaction to shrink context, retry.
4. **Max output escalation** (`max_output_tokens_escalate`) — Increase the output token budget.
5. **Multi-turn recovery** (`max_output_tokens_recovery`) — Allow the model to continue in a new turn.
6. **Stop hook blocking** (`stop_hook_blocking`) — Hook prevented stop; force continuation.
7. **Token budget continuation** (`token_budget_continuation`) — Budget allows another turn; continue.

Each path is a branch in the flat `while(true)` loop, not a nested escalation ladder.

**Technology-Agnostic Guidance**

Define an ordered sequence of recovery strategies from cheapest to most expensive. Implement them as branches in your main loop, not as nested try/catch blocks. Track which recovery has been attempted in your state object to avoid repeating strategies.

**Copy:** Ordered recovery with increasing cost. Track recovery attempts in loop state. Cheapest recovery first (retry → compact → escalate → multi-turn).

**Avoid:** Single-shot error handling (one retry then give up). Nested try/catch recovery (hard to reason about, hard to extend). Retrying the same strategy indefinitely.

**Adapt:** Your recovery strategies will differ by LLM provider. The pattern is provider-agnostic: define a sequence, try cheapest first, escalate on failure, give up only when all strategies are exhausted.

---

### 4. Diminishing Returns Detection

**Category:** Cost Control / Loop Termination

**Problem:** An agent can get stuck in an unproductive loop—each continuation produces a tiny amount of output without making real progress. Without detection, this wastes tokens and user time indefinitely.

**How Claude Code Implements It**

After 3+ consecutive continuations where each produces fewer than ~500 tokens of output, the system stops further continuations. This heuristic prevents the agent from burning budget on unproductive cycles where the model is repeating itself or producing minimal incremental value.

**Technology-Agnostic Guidance**

Track the output volume per continuation. Define a threshold (e.g., 3 consecutive turns below a minimum token count). When hit, terminate the loop and return what you have rather than continuing indefinitely.

**Copy:** Per-continuation output tracking. Threshold-based termination after sustained low output. Returning partial results rather than wasting budget.

**Avoid:** Unbounded retry loops with no output-based termination. Fixed retry counts that don't account for whether retries are productive. Ignoring the cost of unproductive continuations.

**Adapt:** Tune the threshold to your model and use case. Code generation may need a lower threshold (models can stall on complex problems) while summarization may tolerate more continuations.

---

## Tool Patterns

### 5. Fail-Closed Tool Factory

**Category:** Security / Tool Definition

**Problem:** When defining tools for an LLM agent, developers may forget to mark dangerous tools as non-concurrent or non-read-only. If the default is permissive (concurrent, read-only), a missing annotation silently creates a security hole.

**How Claude Code Implements It**

`buildTool()` in `src/Tool.ts` provides a factory with fail-closed defaults. Tools that do not explicitly declare `isConcurrencySafe()` default to `false` (serial execution only). Tools that do not declare `isReadOnly()` default to `false` (treated as write operations requiring permission). Developers must explicitly opt in to `true` for either property.

**Technology-Agnostic Guidance**

Design your tool registration API so that the most restrictive behavior is the default. Tools should be serial-only and write-capable by default. Each tool must explicitly declare safety properties to unlock less restrictive execution.

**Copy:** Deny-by-default for concurrency and read-only status. Factory pattern that provides safe defaults for all optional fields. Explicit opt-in for any relaxation of restrictions.

**Avoid:** Trusting tool authors to correctly set security properties. Permissive defaults that silently grant capabilities. Allowing tools to be registered without declaring their safety characteristics.

**Adapt:** The specific properties will vary (your system may have `requiresNetwork`, `modifiesFilesystem`, etc.), but the principle is universal: the default should be the most restrictive option.

---

### 6. Concurrency Partitioning

**Category:** Performance / Tool Execution

**Problem:** Running all tools serially wastes time when many are safe to parallelize. Running all tools in parallel risks race conditions when some modify shared state. The orchestrator needs a principled way to decide.

**How Claude Code Implements It**

Each tool self-declares its concurrency safety via `isConcurrencySafe()`. The orchestrator reads these declarations and partitions tool executions: safe tools run in parallel (up to 10 concurrent), unsafe tools run serially. Context-modifying tools (those that change the conversation state or filesystem in ways other tools depend on) are queued and applied in order.

**Technology-Agnostic Guidance**

Let each tool declare whether it is safe to run concurrently. Your orchestrator partitions the pending tool calls into safe and unsafe groups. Safe tools execute in parallel with a concurrency cap; unsafe tools execute serially. If a tool modifies shared state that other tools read, treat it as unsafe regardless of its self-declaration.

**Copy:** Tool-level concurrency safety declarations. Orchestrator-managed partitioning. Concurrency cap to prevent resource exhaustion.

**Avoid:** All-serial execution (wastes latency on safe read operations). All-parallel execution (risks corruption from concurrent writes). Orchestrator guessing concurrency safety without tool input.

**Adapt:** Your concurrency cap depends on your runtime and resource constraints. The declaration mechanism can be a flag, decorator, or interface method—the pattern is the same.

---

### 7. Streaming Tool Execution

**Category:** Performance / Latency

**Problem:** Waiting for the model to finish generating its entire response before starting tool execution wastes time. Many tool calls can be identified and started while the model is still streaming.

**How Claude Code Implements It**

`StreamingToolExecutor` begins tool execution during model streaming, before the full response is received. When the model's streamed output contains enough of a tool call to begin execution (input parameters are complete), the tool starts immediately. If a sibling tool call errors, in-flight tools are aborted.

**Technology-Agnostic Guidance**

Parse tool calls incrementally from the model's streaming output. When a tool call's input is complete (even if the model is still generating other tool calls or text), start that tool immediately. Maintain an abort mechanism so that if one tool fails, sibling in-flight tools can be cancelled.

**Copy:** Overlap tool execution with model streaming. Incremental tool call parsing. Sibling abort on error.

**Avoid:** Executing destructive (write) tools before the model has finished generating and the user has confirmed. Starting all tools simultaneously without abort capability.

**Adapt:** This pattern benefits read-heavy workloads most (file reads, searches). For write operations, you may want to wait for full response + user confirmation before execution.

---

### 8. Deferred Tool Loading

**Category:** Prompt Efficiency / Token Management

**Problem:** Dumping all tool schemas into the system prompt wastes 15–20K tokens on tools the model may never use. This reduces the context available for actual conversation and increases cost.

**How Claude Code Implements It**

Only ~10 core tools are included in the initial system prompt. Additional tools are discoverable via `ToolSearchTool`, which lets the model search for tools by capability description. The `searchHint` field on each tool provides a 3–10 word capability phrase for the search index.

**Technology-Agnostic Guidance**

Include only essential tools in the base prompt. Provide a meta-tool that lets the model discover additional tools by searching capability descriptions. Each tool should have a short searchable description separate from its full schema.

**Copy:** Progressive tool discovery via a search meta-tool. Short capability hints for search indexing. Core tools only in the base prompt.

**Avoid:** Dumping all tool schemas into every prompt. Requiring the model to know all tools upfront. Making tool discovery depend on exact name matching (use semantic descriptions).

**Adapt:** The threshold for "core" vs. "discoverable" depends on your tool count and prompt budget. With fewer than 10 tools, this pattern may not be necessary.

---

### 9. Tool Result Budget Management

**Category:** Context Management / Token Efficiency

**Problem:** Tool results can be arbitrarily large (a `grep` over a large codebase, a full file read). Injecting unbounded results into context pollutes the conversation window and can cause context overflow.

**How Claude Code Implements It**

Tools have a `maxResultSizeChars` property that caps output size. Large results are written to disk, and only a ~2KB preview is injected into the conversation context. The model can request the full result via file read if needed.

**Technology-Agnostic Guidance**

Cap the size of every tool result before it enters the conversation context. For results that exceed the cap, store the full result in an accessible location (disk, object store, or a retrievable reference) and inject a truncated preview into context.

**Copy:** Per-tool output size caps. Disk-backed full results with context-friendly previews. Letting the model request full results explicitly when needed.

**Avoid:** Unlimited tool results flooding context. Silent truncation without telling the model (it won't know data is missing). Storing large results only in context (wastes tokens on every subsequent turn).

**Adapt:** The specific cap depends on your context window size and tool types. The pattern applies to any system where tool output can vary in size.

---

## Memory Patterns

### 10. Index-File Memory Architecture

**Category:** Persistent Memory / Organization

**Problem:** Storing all agent memory in a single file creates scaling problems: the file grows unbounded, every memory load requires reading everything, and concurrent writes risk corruption. Stuffing a monolithic memory file into the system prompt wastes tokens on irrelevant memories.

**How Claude Code Implements It**

`MEMORY.md` is a ~200-line / ~25KB index file that links to individual memory `.md` files by topic. It is not a monolithic store—it serves as a table of contents. The memory system also includes multiple layers: CLAUDE.md files (user/local/project/managed), auto-generated memory, session memory, and team memory.

**Technology-Agnostic Guidance**

Separate the memory index from memory content. The index is a lightweight manifest that fits within prompt budgets; individual memory files are loaded on demand. Organize memory into layers with different scopes (user-global, project-specific, session-specific).

**Copy:** Index file separate from content files. Multiple memory layers with different scopes. Size-bounded index that fits in a prompt.

**Avoid:** Monolithic memory files in the system prompt. Unbounded memory growth without eviction or archival. Single-layer memory that mixes user preferences with project facts.

**Adapt:** The specific layers depend on your product (per-workspace, per-user, per-team, etc.). The invariant is: index is small and loaded always; content is large and loaded selectively.

---

### 11. LLM-Based Semantic Recall

**Category:** Memory Retrieval / Relevance

**Problem:** Embedding-based similarity search is fast but struggles with cross-domain associations and context-dependent relevance. When the memory corpus is small enough, using the LLM itself for relevance selection produces better results.

**How Claude Code Implements It**

Memory recall uses a Sonnet side-query that receives the memory manifest (file list with short descriptions) and selects up to 5 relevant files to inject into context. This is explicitly *not* embedding search—it is LLM-based relevance selection.

**Technology-Agnostic Guidance**

When your memory corpus is manageable (hundreds of files, not millions), use an LLM side-query to select relevant memories rather than relying on embedding similarity. Provide the LLM with a manifest of available memories and let it select based on the current conversation context.

**Copy:** LLM-based relevance selection from a manifest. Side-query that runs cheaply (small model, small input). Bounded selection count (e.g., top 5).

**Avoid:** Blind embedding similarity for small corpora (misses cross-domain associations). Loading all memories into context (token waste). No memory recall at all (agent forgets everything between sessions).

**Adapt:** At scale (millions of documents), embedding pre-filtering followed by LLM re-ranking combines the strengths of both approaches. For small memory stores, LLM-only is simpler and more effective.

---

### 12. Threshold-Gated Memory Extraction

**Category:** Memory / Session Management

**Problem:** Extracting memories after every tool call or turn creates noisy, redundant memory entries. Extracting during the middle of a multi-tool chain captures partial work that may be revised. Memory extraction needs to happen at meaningful breakpoints.

**How Claude Code Implements It**

Session memory extraction fires only at natural breakpoints: after 10K tokens of initial conversation, with at least 5K tokens between extractions, and a minimum of 3 tool calls completed. This prevents mid-chain extraction artifacts.

**Technology-Agnostic Guidance**

Gate memory extraction on meaningful thresholds: minimum conversation length, minimum interval between extractions, and minimum completed actions. The goal is to extract memories at points where the conversation has reached a natural resting state.

**Copy:** Multi-threshold gating (token count + action count + interval). Extraction at natural breakpoints. Preventing duplicate or partial extractions.

**Avoid:** Extracting after every turn (noisy memories). Extracting during multi-step tool chains (captures incomplete work). Never extracting (agent loses learned context).

**Adapt:** Tune thresholds to your conversation patterns. Shorter sessions need lower thresholds; longer sessions with many tool calls need higher minimums to avoid extraction spam.

---

### 13. Post-Compact Capability Re-injection

**Category:** Context Management / Compaction

**Problem:** When conversation history is compacted (summarized to save tokens), the model loses awareness of its capabilities—available tools, open files, active plans, loaded skills. The next turn after compaction may fail because the model doesn't know what tools it has.

**How Claude Code Implements It**

After compaction, the system re-injects declarations of available tools, open files, active plans, and loaded skills. The compaction service produces a 9-section summary, and capability context is appended to restore the model's working inventory.

**Technology-Agnostic Guidance**

After any context compaction or summarization, re-inject a capability inventory: what tools are available, what files are open, what the current plan is, and what skills are loaded. Treat compaction as creating a new "session start" that needs the same bootstrapping as the original session.

**Copy:** Capability re-injection after every compaction. Treating post-compaction as a fresh context that needs bootstrapping. Structured summary format (not free-form).

**Avoid:** Losing tool/file/plan awareness after compaction. Assuming the model remembers capabilities from pre-compaction context. Free-form summaries that omit operational context.

**Adapt:** The specific sections in your summary depend on what your agent tracks. The invariant is: anything the model needs to know to function must survive compaction.

---

## Security Patterns

### 14. Progressive Permission Pipeline

**Category:** Security / Authorization

**Problem:** A single permission check is brittle—it must handle all cases in one pass. Different permission sources (hooks, rules, classifiers, user prompts) have different trust levels and should be evaluated in order with early exit.

**How Claude Code Implements It**

Permission evaluation follows a layered pipeline: hook evaluation → deny rule check → classifier evaluation → tool-specific permission check → user prompt. Each layer can short-circuit: a deny rule immediately blocks regardless of what hooks or classifiers said. The permission system resolves across 8 sources by strict precedence: policy > flag > local > project > user > cliArg > session > command.

**Technology-Agnostic Guidance**

Design permission evaluation as a pipeline where each stage can either approve, deny, or pass to the next stage. Deny decisions should be irrevocable (see Pattern 17). Order stages from most authoritative to least. Allow early exit at any stage to avoid unnecessary evaluation.

**Copy:** Layered pipeline with early exit. Priority-ordered source resolution. Deny rules that cannot be overridden by later stages.

**Avoid:** Single permission check that handles all cases. Permission "racing" where multiple sources evaluate simultaneously without priority. Allowing less-trusted sources to override more-trusted ones.

**Adapt:** Your layers will differ (you may not have hooks, or you may have RBAC instead of classifiers), but the pipeline structure with early-exit and irrevocable denials is universal.

---

### 15. AST-Based Security with Regex Fallback

**Category:** Security / Input Validation

**Problem:** Validating shell commands with regex alone is unreliable—shell syntax is complex enough that regex patterns miss edge cases (quoting, escaping, subshells, heredocs). But AST parsing may not always be available or may fail on malformed input.

**How Claude Code Implements It**

BashTool uses tree-sitter WASM for AST-based bash command analysis with 23 security check IDs. When tree-sitter is unavailable or fails to parse, regex-based validators provide a fallback. The validator ordering is misparsing-aware—it accounts for cases where the AST parser may misinterpret the command.

**Technology-Agnostic Guidance**

Use proper parsing (AST) for command validation as the primary path. Implement regex-based validation as a fallback for when the parser is unavailable or fails. Order validators so that regex fallbacks are at least as conservative as the AST path—when in doubt, deny.

**Copy:** AST-based primary validation. Regex fallback that errs on the side of denial. Multiple security check IDs for auditability.

**Avoid:** Regex-only command validation (too many edge cases). Trusting that the AST parser always succeeds. Fallback validators that are more permissive than the primary path.

**Adapt:** The specific parser (tree-sitter, ShellCheck, ANTLR, etc.) depends on your target language. The pattern applies to any agent that executes commands: parse first, regex fallback, deny when uncertain.

---

### 16. Bare Git Repo Scrubbing

**Category:** Security / Sandbox Hygiene

**Problem:** Sandboxed execution can leave behind artifacts that, if not cleaned up, create attack vectors. Git repositories in particular can contain hooks (`core.fsmonitor`, `post-checkout`) that execute arbitrary code when the repository is accessed.

**How Claude Code Implements It**

After sandbox execution, the system scrubs files that could trigger `core.fsmonitor` RCE (Remote Code Execution) in bare git repositories. The sandbox implementation uses bubblewrap (Linux) and sandbox-exec (macOS), but even with sandboxing, output cleanup is necessary.

**Technology-Agnostic Guidance**

After any sandboxed or untrusted execution, scrub the output for known attack vectors before allowing it to interact with the host system. Do not trust that the sandbox prevented all dangerous outputs—defense in depth means validating outputs even from sandboxed processes.

**Copy:** Post-execution output scrubbing. Known attack vector enumeration (maintain a list). Defense in depth beyond sandbox boundaries.

**Avoid:** Trusting sandbox output blindly. Assuming sandboxes prevent all malicious artifacts. Skipping cleanup because "the sandbox handles it."

**Adapt:** Your attack vector list will differ by platform and execution environment. The pattern is: enumerate known vectors, scrub after execution, update the list as new vectors are discovered.

---

### 17. Deny-Rules-Always-Win Invariant

**Category:** Security / Policy Enforcement

**Problem:** When multiple authorization sources exist (hooks, classifiers, user rules), a permissive source might override a restrictive one. If a hook says "allow" and a deny rule says "deny," which wins? Getting this wrong creates security holes.

**How Claude Code Implements It**

In Claude Code's permission system, a hook `allow` decision does NOT bypass deny rules. Deny rules are inviolable—they always win regardless of what hooks, classifiers, or other sources decide. This is an architectural invariant, not a configurable behavior.

**Technology-Agnostic Guidance**

Make deny rules inviolable in your permission system. No other authorization source—hooks, classifiers, user overrides, admin settings—should be able to override a deny rule. This should be enforced at the architectural level (code structure), not at the policy level (configuration).

**Copy:** Architectural invariant: deny always wins. Deny check runs early in the pipeline and short-circuits. No configuration flag that disables deny rules.

**Avoid:** Allowing hooks to override security policy. Making deny-rule enforcement configurable. Relying on policy ordering alone (enforce in code).

**Adapt:** This applies to any system with multiple authorization sources. The invariant is simple but critical: denials are monotonic—once denied, no later stage can reverse it.

---

### 18. Dangerous Permission Stripping

**Category:** Security / Autonomy Safety

**Problem:** When an agent operates autonomously (auto mode), it inherits the permission rules the user configured. But some rules are overly broad (e.g., `Bash(*)` allows all shell commands). Letting an AI classifier inherit human-level permissions is dangerous.

**How Claude Code Implements It**

On entering auto mode, the system strips overly broad allow rules like `Bash(*)`. The YOLO classifier—a 2-stage classifier where safe-allowlisted tools bypass classification and text blocks are excluded from classifier input—operates under these constrained permissions. Original permissions are restored when auto mode exits.

**Technology-Agnostic Guidance**

When your agent enters an autonomous execution mode, audit and strip overly broad permission grants. The principle: AI classifiers should never inherit the full permission set of a human operator. Restore original permissions when autonomy ends.

**Copy:** Permission stripping on autonomy entry. Restoration on autonomy exit. Explicit enumeration of "too broad" patterns.

**Avoid:** Letting AI classifiers inherit human-level permissions. Forgetting to restore permissions after autonomy ends. Trusting that the classifier will self-limit.

**Adapt:** Define "too broad" for your system. In Claude Code it's `Bash(*)`; in your system it might be `*` on any destructive API, or admin-level database access.

---

## Configuration Patterns

### 19. Compile-Time Feature Flag DCE

**Category:** Security / Build System

**Problem:** Runtime-only feature flags leave the gated code in the binary. If the code is sensitive (internal-only features, experimental capabilities), it can be discovered or accidentally activated. For security-sensitive features, the code should be physically absent from public builds.

**How Claude Code Implements It**

The `bun:bundle` system resolves `feature('FLAG')` to `true` or `false` literals at build time. The bundler's dead code elimination (DCE) then removes unreachable branches entirely. Internal-only code paths (e.g., `feature('PROACTIVE')`) are physically absent from external builds—not just disabled, but not shipped.

**Technology-Agnostic Guidance**

For security-sensitive features, use compile-time flags that resolve to literals, enabling dead code elimination. The gated code should be physically absent from builds where the flag is false—not present-but-disabled.

**Copy:** Compile-time flag resolution to boolean literals. Dead code elimination by the bundler/compiler. Physical absence of sensitive code from public builds.

**Avoid:** Runtime-only feature flags for security-sensitive code (code is still in the binary). String-based flag checks that the bundler can't eliminate. Relying on obfuscation instead of DCE.

**Adapt:** In Rust, use `cfg` attributes. In Go, use build tags. In Java, use ProGuard with compile-time constants. The mechanism differs but the goal is the same: code that shouldn't ship doesn't ship.

---

### 20. Three-Tier Gating

**Category:** Configuration / Feature Management

**Problem:** A single feature flag system cannot address all gating needs. Build-time flags can't change without redeployment. Runtime flags can't remove code. Identity-based flags can't work without user context. Real systems need all three.

**How Claude Code Implements It**

Claude Code uses three tiers of feature gating:

1. **Build-time** — `bun:bundle` feature flags → DCE (code physically absent/present).
2. **Runtime A/B** — GrowthBook feature flags → dynamic activation without deployment.
3. **Identity-based** — `process.env.USER_TYPE === 'ant'` → internal vs. external user capabilities.

Configuration itself uses 5-layer precedence: policy > flag > local > project > user.

**Technology-Agnostic Guidance**

Layer your gating mechanisms: compile-time for code-level inclusion, runtime for dynamic activation, identity-based for per-user/per-tenant capabilities. Each tier addresses a different deployment and security concern.

**Copy:** Compile-time gating for security-sensitive features. Runtime gating for gradual rollout and experimentation. Identity-based gating for user-tier differentiation. Clear precedence ordering when tiers conflict.

**Avoid:** Single-tier feature flags for all purposes. Runtime flags for code that should be physically absent. Build-time flags for features that need instant toggling.

**Adapt:** Your specific tiers depend on your deployment model. The pattern is: multiple tiers with different latencies and security properties, clear precedence when they overlap.

---

## Telemetry Patterns

### 21. No-String Metadata Type

**Category:** Privacy / Telemetry Safety

**Problem:** Developers accidentally log PII (file paths, user content, error messages containing code) in analytics metadata. Review-based prevention doesn't scale—one missed string field can leak sensitive data.

**How Claude Code Implements It**

The analytics metadata type structurally excludes `string` at the type level. Only numbers, booleans, and specially tagged fields are allowed. PII-containing fields must use a `_PROTO_*` prefix that explicitly tags them, forcing developers to verify the data is safe for logging. The long class name `TelemetrySafeError_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS` serves the same purpose for error telemetry—the name itself is a verification prompt.

**Technology-Agnostic Guidance**

Use your type system to prevent PII in telemetry. Design analytics event types that structurally exclude free-text strings. When a string must be included, require an explicit marker (prefix, wrapper type, review annotation) that forces the developer to consciously verify the data is safe.

**Copy:** Type-level PII prevention (no untagged strings in analytics types). Explicit markers for intentional string inclusion. Awkwardly-named types/functions as verification prompts.

**Avoid:** Trusting developers to not log PII. Runtime scanning for PII (too late, too unreliable). Allowing arbitrary strings in analytics metadata.

**Adapt:** In statically typed languages, use branded types or newtype wrappers. In dynamically typed languages, use schema validation at the telemetry boundary. The key insight is structural prevention, not policy prevention.

---

### 22. Queue-Then-Drain Sink

**Category:** Observability / Initialization

**Problem:** Events that occur during application startup—before the telemetry infrastructure is initialized—are lost. These early events often include the most important diagnostics (initialization time, configuration errors, first-interaction latency).

**How Claude Code Implements It**

Events are buffered in an in-memory queue from the moment the process starts. When the telemetry sink attaches (after initialization), the queue is drained—all buffered events are forwarded to the sink. The sink attachment is idempotent (calling it twice is a no-op). The same pattern is used for error logging via `attachErrorLogSink()`.

**Technology-Agnostic Guidance**

Decouple event generation from event transport. Start buffering events from process start. When the transport layer initializes, drain the buffer. Make sink attachment idempotent to handle race conditions during initialization.

**Copy:** In-memory event buffer from process start. Drain-on-attach pattern. Idempotent sink attachment. Type-discriminated events in the queue.

**Avoid:** Losing early-lifecycle events. Requiring the transport layer to be initialized before events can be generated. Non-idempotent sink attachment (double-drain risk).

**Adapt:** The buffer can be a simple array (small event volume) or a ring buffer (high volume with eviction). The drain-on-attach pattern works regardless of buffer implementation.

---

## Anti-Patterns to Avoid

These are common mistakes in LLM agent architectures. Each anti-pattern is paired with the pattern that replaces it.

### 23. All-History Context Dumping

**Problem:** Stuffing the entire conversation history into every API call wastes tokens, increases latency, and eventually hits context limits.

**Instead:** Use structured compaction with multi-section summaries and selective re-injection (Pattern 13). Compact at meaningful thresholds (e.g., `effectiveContextWindow - 13,000 tokens`), preserve capability awareness, and circuit-break after repeated compaction failures (3 failures max).

---

### 24. Single Permission Check

**Problem:** A single pass/fail permission check cannot express layered trust, priority-based overrides, or early-exit optimizations. It becomes a monolithic function that grows with every new permission source.

**Instead:** Use a progressive permission pipeline (Pattern 14) where each layer can short-circuit. Combine with irrevocable deny rules (Pattern 17) and permission stripping for autonomy (Pattern 18).

---

### 25. Regex-Only Command Validation

**Problem:** Regular expressions cannot reliably parse shell syntax. Quoting, escaping, subshells, process substitution, and heredocs create edge cases that regex patterns miss, leading to security bypasses.

**Instead:** Use AST-based parsing as the primary validation path with regex as a conservative fallback (Pattern 15). When the AST parser fails, the regex fallback should deny uncertain inputs rather than allow them.

---

### 26. Unbounded Tool Results

**Problem:** A tool that returns 100KB of grep results or a full file read floods the conversation context, pushing out useful history and hitting context limits in fewer turns.

**Instead:** Cap tool output with per-tool size limits and disk-backed full results (Pattern 9). Provide the model with a preview and let it request more if needed.

---

### 27. Monolithic Memory File

**Problem:** A single memory file grows without bound, contains irrelevant entries, and wastes tokens when loaded into the system prompt. It cannot be selectively queried or scoped.

**Instead:** Use an index-file architecture (Pattern 10) with separate content files. Use LLM-based recall (Pattern 11) to select relevant memories. Gate extraction on meaningful thresholds (Pattern 12).

---

### 28. Runtime-Only Feature Gating

**Problem:** Runtime feature flags leave the gated code in the binary. For security-sensitive features, this means internal-only code ships to external users—disabled but extractable and potentially activatable.

**Instead:** Use compile-time DCE (Pattern 19) so sensitive code is physically absent from builds where it shouldn't exist. Layer with runtime flags (Pattern 20) for features that need dynamic toggling.

---

### 29. Trusting Hook Allow Decisions

**Problem:** If hooks (user-provided scripts that run during permission evaluation) can override deny rules, a malicious or misconfigured hook can bypass security policy. The hook becomes a privilege escalation vector.

**Instead:** Enforce the deny-rules-always-win invariant (Pattern 17). Hook allow decisions are advisory—they can grant permissions that aren't otherwise denied, but they cannot override explicit denials. Strip overly broad hook grants on autonomy entry (Pattern 18).

---

## Pattern Selection Guide

| You need to... | Start with |
|---|---|
| Build the main agent loop | Pattern 1 (AsyncGenerator State Machine) |
| Handle streaming errors gracefully | Pattern 2 (Withholding) + Pattern 3 (Progressive Recovery) |
| Prevent runaway agent loops | Pattern 4 (Diminishing Returns Detection) |
| Register tools safely | Pattern 5 (Fail-Closed Factory) + Pattern 6 (Concurrency Partitioning) |
| Optimize tool execution latency | Pattern 7 (Streaming Execution) + Pattern 8 (Deferred Loading) |
| Manage tool output size | Pattern 9 (Result Budget Management) |
| Implement persistent memory | Pattern 10 (Index-File) + Pattern 11 (LLM Recall) + Pattern 12 (Threshold Gating) |
| Survive context compaction | Pattern 13 (Post-Compact Re-injection) |
| Build a permission system | Pattern 14 (Progressive Pipeline) + Pattern 17 (Deny-Always-Wins) |
| Validate shell commands | Pattern 15 (AST + Regex Fallback) |
| Sandbox untrusted execution | Pattern 16 (Bare Git Repo Scrubbing) |
| Gate features across environments | Pattern 19 (Compile-Time DCE) + Pattern 20 (Three-Tier Gating) |
| Build safe telemetry | Pattern 21 (No-String Metadata) + Pattern 22 (Queue-Then-Drain) |
| Enable autonomous operation | Pattern 18 (Permission Stripping) + Pattern 4 (Diminishing Returns) |

