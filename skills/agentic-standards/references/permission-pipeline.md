# Permission Pipeline

Reference for implementing a layered permission system that balances safety with autonomy.

## Pipeline stages

Permissions are evaluated as a pipeline with early exit. Each stage can short-circuit.

```
1. Check DENY rules    → if match, DENY (irrevocable, nothing downstream can override)
2. Check ASK rules     → if match, PROMPT USER for approval
3. Check ALLOW rules   → if match, ALLOW
4. Tool-specific check → tool's own permission logic
5. Mode default        → fall through to the current permission mode's default behavior
```

**Invariant:** Deny always wins. No hook, classifier, configuration, or user action can override a denial rule.

## Permission modes (spectrum)

Offer a spectrum from fully interactive to fully autonomous:

| Mode | Behavior | Trust Level | Use Case |
|------|----------|-------------|----------|
| **Plan / Read-only** | All write operations blocked | Lowest | Agent explores, user decides |
| **Default** | Ask before non-read-only operations | Normal | Standard interactive use |
| **Accept edits** | Auto-approve file edits; ask for everything else | Higher | Trusts file operations |
| **Auto** | AI classifier decides per-operation | High | Semi-autonomous operation |
| **Bypass** | Skip all checks (kill-switchable) | Highest | Full trust, emergency override |
| **Bubble** | Surface permission requests to parent | Sub-agent | Permission delegation |

**Principle:** Don't force a single permission model. Let users choose their comfort level. Always provide read-only at one end and a kill switch at the other.

## Rule sources (8 layers, highest priority first)

```
1. Policy settings     — Organization-managed, cannot be overridden downstream
2. Flag settings       — Feature flags / A/B testing
3. Local settings      — Per-machine overrides
4. Project settings    — Per-repository, committed to source control
5. User settings       — Personal preferences
6. CLI arguments       — Per-session overrides
7. Session rules       — Accumulated during the session
8. Command rules       — Per-command defaults
```

Higher-numbered sources are overridden by lower-numbered sources. Policy always wins.

## Auto-mode safety

When entering autonomous mode with an AI classifier:

1. **Strip overly broad allow rules** — rules like "allow all bash commands" are too dangerous for autonomous operation. Remove them so the classifier sees every action.
2. **Use a 2-stage classifier**:
   - **Stage 1 (fast):** Quick check — if clearly safe, allow. If clearly dangerous, block. If ambiguous, proceed to Stage 2.
   - **Stage 2 (deep):** Deliberate reasoning with structured thinking before deciding.
3. **Bypass classifier for safe tools** — read-only, concurrency-safe tools skip classification entirely (no risk).
4. **Exclude agent text from classifier input** — only tool-use blocks are classified. This prevents the agent from crafting text that influences the classifier.
5. **Track consecutive denials** — after too many, fall back to user prompting. Prevents classifier loops.
6. **Restore original permissions on exit** — auto-mode is a temporary elevation, not a permanent change.

## Classifier output format

For the 2-stage classifier, use structured output:

```xml
<!-- Stage 1: Fast path -->
<block>yes</block><reason>deletes production database</reason>
<!-- or -->
<block>no</block>

<!-- Stage 2: Deep analysis -->
<thinking>The command runs git push --force to a feature branch. 
This is destructive but scoped to a non-shared branch...</thinking>
<block>no</block>
```

Stage 1 suffix: "Err on the side of blocking."
Stage 2 suffix: "Review carefully. Explicit user confirmation is required to override blocks."

## Hook integration

Tools can have lifecycle hooks — user-configurable actions that run before/after execution:

- **Pre-execution hooks**: Can block the tool, modify its input, or auto-approve it
- **Post-execution hooks**: Can modify the tool's output

**Critical invariant:** A hook's "allow" decision does NOT override deny rules. Hooks can add restrictions but CANNOT remove them. This prevents hooks from being used to bypass the security model.

```
Hook says ALLOW + Deny rule matches  → DENY (deny wins)
Hook says ALLOW + No deny rule       → ALLOW (hook respected)
Hook says DENY  + Allow rule matches  → DENY (hook adds restriction)
```

## Command execution security

For shell/bash commands, apply additional validation layers:

1. **Static analysis**: Parse the command (AST if possible, regex fallback) and check for dangerous patterns: command substitution, shell injection, encoding attacks, brace expansion.
2. **Rule matching**: Check against allow/deny lists with exact, prefix, and wildcard matching.
3. **Read-only validation**: In read-only mode, reject any command containing variable expansion (`$`). This is conservative but eliminates an entire class of injection attacks.

**Principle:** Use proper parsing for validation, not regex alone. When AST parsing fails, fall back to regex that is at least as conservative as the AST path.
