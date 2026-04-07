# Tool Design Checklist

When designing tools for an agentic system, use this checklist to ensure each tool is safe, well-defined, and robust.

## The tool contract

A tool is not just a function — it's a contract between the agent, the user, and the system. Each tool should declare:

| Property | What it answers | Default (fail-closed) |
|----------|----------------|----------------------|
| **Name** | What is this tool called? | Required |
| **Description** | What does it do? (For the agent) | Required |
| **Search hint** | 3-10 word capability phrase for discovery | — |
| **Input schema** | What does it accept? (Validated at runtime) | Required |
| **Is read-only?** | Does it modify state? | `false` (assumed write) |
| **Is concurrency-safe?** | Can it run alongside other tools? | `false` (serial only) |
| **Is destructive?** | Is the action hard to reverse? | `false` |
| **Max result size** | How large can output be? | 50,000 chars |
| **Interrupt behavior** | Cancel immediately or finish current op? | `cancel` |
| **Permission check** | Who can invoke this? | Require explicit approval |

## Fail-closed defaults

**Every tool starts with the most restrictive assumptions.** A developer must explicitly opt into less restrictive behavior. This means:

- A forgotten `isReadOnly: true` → tool requires write permission (safe)
- A forgotten `isConcurrencySafe: true` → tool runs serially (safe, just slower)
- A forgotten `isDestructive: false` → tool is NOT assumed safe (correct default)

**Principle:** A forgotten annotation should make the tool harder to use, never more dangerous.

## Design checklist

### Before implementation
- [ ] Name is clear, unambiguous, and follows project conventions
- [ ] Description explains what the tool does in terms the agent can use to decide when to invoke it
- [ ] Input schema uses strict validation (reject unknown fields, validate types)
- [ ] Output format is documented and consistent

### Safety declarations
- [ ] `isReadOnly` is explicitly set (not relying on default)
- [ ] `isConcurrencySafe` is set based on actual thread-safety analysis
- [ ] `isDestructive` is set for any action that's hard to reverse
- [ ] Maximum result size is configured (prevents single tool result from consuming context)
- [ ] Timeout is set for operations that could hang

### Permission integration
- [ ] Tool participates in the permission pipeline (deny → ask → allow → default)
- [ ] Read-only tools can bypass permission checks in read-only modes
- [ ] Destructive tools require explicit confirmation regardless of mode
- [ ] Tool can operate in "bubble" mode (escalate to parent when in sub-agent)

### Capability filtering
- [ ] **Composable filter stages**: tool availability passes through orthogonal layers (auth/provider, runtime enablement, deployment context). Each layer checks one concern; adding a new dimension doesn't require rewriting existing filters.
- [ ] Tool is excluded from contexts where it's unsafe (e.g., remote sessions, embedded mode) via declarative metadata, not ad-hoc conditionals.

### Input robustness
- [ ] **Semantic type wrappers** for LLM-facing parameters: accept `"true"`, `"false"`, `1`, `0`, `"yes"`, `"no"` for booleans; accept `"5"` for numbers. LLMs are imprecise about types — coerce rather than reject.
- [ ] **Strict input schemas** reject unknown fields. This catches the model hallucinating extra parameters rather than silently ignoring them.

### Error handling
- [ ] Invalid input returns a clear error message (not a stack trace)
- [ ] Partial failure is handled (e.g., some files edited, others failed)
- [ ] Timeout produces a meaningful error (not silent hang)
- [ ] Tool errors don't crash the agent loop
- [ ] Error stacks are truncated (top 5 frames) before entering conversation to save context tokens

### Result handling
- [ ] Large results are truncated with a retrieval mechanism (save to disk, provide preview)
- [ ] Results are formatted for the agent (structured), not for humans (pretty-printed)
- [ ] Sensitive data is redacted from results before they enter conversation history
- [ ] Tool output is mapped to a format the model API expects (not raw internal types)

### Race condition prevention
- [ ] **File edit mtime check**: if the tool reads a file and later edits it, verify the modification time hasn't changed between read and write. Reject with a clear "file unexpectedly modified" error if it has.
- [ ] **Idempotency**: where possible, make tool operations idempotent. Running the same tool call twice should produce the same result, not duplicate side effects.

## Tool execution pipeline

For reference, a well-designed tool execution pipeline processes each call through these stages:

```
1. Tool lookup (name + alias fallback)
2. Input validation (schema check)
3. Tool-specific validation (business rules)
4. Permission check (deny → ask → allow → mode default)
5. Pre-execution hooks (can block, modify input, auto-approve)
6. Execute tool
7. Post-execution hooks (can modify output)
8. Result size enforcement (truncate if needed)
9. Result formatting for conversation
```

## Progressive tool discovery

Don't front-load all tools into the system prompt. This wastes 15-20K tokens on tools the agent may never use.

- Load ~10 core tools in the base prompt (file read, file edit, search, shell, etc.)
- Make the rest discoverable via a meta-tool that searches by capability description
- Each tool provides a `searchHint` — a brief capability phrase the search tool uses for matching

**Trade-off:** This adds one extra turn when the agent needs a non-core tool, but saves significant tokens on every turn where it doesn't.
