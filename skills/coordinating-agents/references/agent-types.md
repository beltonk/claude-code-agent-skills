# Agent Types and Isolation Modes

Reference for configuring sub-agents with appropriate capabilities and isolation levels.

## Agent Types

| Type | Purpose | Tool Access | Typical Use |
|------|---------|-------------|-------------|
| **General-purpose** | Catch-all worker | All tools | Implementation tasks, mixed work |
| **Explorer** | Code investigation | Read-only tools only | Codebase exploration, finding patterns |
| **Planner** | Design and planning | Read-only tools only | Architecture decisions, approach design |
| **Verifier** | Adversarial testing | Read-only project tools + temp directory writes | Post-implementation verification |
| **Guide** | Help and documentation | Read-only tools | Answering questions, explaining code |
| **Fork** | Branch from parent context | Inherits parent's tool set | Speculative execution, parallel attempts |

### Tool filtering by type

- **Read-only agents** (Explorer, Planner, Guide, Verifier): Strip all write tools except temp/scratch directory writes for Verifier.
- **General-purpose agents**: Full tool set with standard permission checks.
- **Forked agents**: Inherit parent's exact tool pool — this enables prompt cache sharing (the forked API prefix is byte-identical to the parent's).

### When to use each type

- Use **Explorer** for "find all usages of X" or "how does module Y work?" — prevents accidental writes during investigation.
- Use **Planner** when you want the sub-agent to reason about an approach without acting on it.
- Use **Verifier** after implementation — always a separate agent, never the implementer verifying their own work.
- Use **Fork** when you want to try an approach speculatively — the agent can be discarded if the approach fails.

## Isolation Modes

| Mode | Mechanism | File System | Performance | When to Use |
|------|-----------|-------------|-------------|-------------|
| **Default** (in-process) | Same process, isolated state | Shared workspace | Lowest overhead | Sub-tasks that read or make small, coordinated changes |
| **Worktree** | Git worktree | Isolated copy | Medium overhead | Implementation that modifies files — prevents conflicts between parallel workers |
| **Remote** | Separate environment | Fully isolated | Highest overhead | Heavy compute, CI-like validation, untrusted operations |

### Choosing isolation

```
Is the task read-only?
  → Yes: Default (in-process), no isolation needed
  → No: Does it modify files?
    → Yes: Will multiple workers modify files in parallel?
      → Yes: Worktree (prevents merge conflicts)
      → No: Default is fine for a single writer
    → Is it compute-heavy or untrusted?
      → Yes: Remote
      → No: Default or Worktree
```

### Worktree lifecycle

1. Create worktree from current branch: `git worktree add ../worker-<id> HEAD`
2. Worker operates in isolated directory
3. On completion: merge changes back (fast-forward if possible, otherwise manual merge)
4. Cleanup: `git worktree remove ../worker-<id>`

### Permission escalation

Sub-agents cannot make permission decisions above their trust level. When a sub-agent encounters an operation that requires user confirmation:
- The request **bubbles up** to the parent agent (or directly to the user)
- The sub-agent blocks until the permission decision is returned
- The parent can approve, deny, or ask the user

## Agent Loop Design Patterns

These patterns apply to the core execution loop of both parent and sub-agents.

### Flat state machine

Represent the agent loop as a flat `while(true)` state machine with an explicit state object — not recursive calls.
- **Long sessions** can run hundreds of turns. Recursion accumulates stack frames; a flat loop doesn't.
- **State is inspectable.** Each iteration records *why* it continued (tool result, error recovery, budget continuation).
- **Cancellation is cheap.** At every yield point, check an abort signal. Unwinding nested calls is expensive.
- Every transition and termination reason should be explicitly named and enumerable.

### Streaming + overlapped execution

Don't wait for the complete model response before acting:
- Parse tool calls incrementally as their JSON inputs complete during streaming.
- Begin executing concurrency-safe tools while the model is still generating.
- If any streaming tool errors, abort sibling tools in the same batch to prevent wasted work.
- On fallback from streaming to batch execution, "tombstone" in-progress results (mark as failed so the model knows to retry).

### Recovery mechanisms

Build explicit recovery paths for predictable failures:

| Failure | Recovery |
|---------|----------|
| Context too long | First try collapse-drain (remove collapsible content), then reactive compaction (full summarization) |
| Output truncated | Escalate output token limit (e.g., 64K → multi-turn), up to 3 attempts |
| Compaction fails 3x | Circuit breaker — stop retrying, report to user |
| Transient API error | Retry with backoff; withhold recoverable errors from the model to avoid contaminating reasoning |
| Permission denied repeatedly | After N consecutive denials, fall back to user prompting |
