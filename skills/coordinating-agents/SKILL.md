---
name: coordinating-agents
description: Provides a coordinator workflow for orchestrating multiple sub-agents on complex tasks. Covers the research-synthesis-implementation-verification phases, self-contained worker prompt rules, error handling, and anti-patterns. Use when a task has independent sub-problems that benefit from parallel work or when the scope exceeds what a single agent pass can handle reliably.
---

# Coordinating Agents

When a task benefits from parallel work, use this four-phase workflow. The coordinator synthesizes and directs — workers execute.

**When NOT to coordinate**: If the task touches fewer than 3 files or has no independent sub-problems, do it directly. Coordination overhead is only worth it for tasks with genuine parallelism.

## Phases

```
Coordination Progress:
- [ ] Phase 1: Research (workers, parallel)
- [ ] Phase 2: Synthesis (coordinator — YOU)
- [ ] Phase 3: Implementation (workers, parallel where independent)
- [ ] Phase 4: Verification (separate worker, adversarial)
```

### Phase 1: Research
Spawn workers to investigate different codebase areas simultaneously.
- Each worker explores **one area** and reports findings
- Workers report facts — they do NOT make implementation decisions
- Research prompts should specify what to look for and where to look

### Phase 2: Synthesis (your most important job)
Read all research results. Synthesize into a clear implementation plan.
- **Never delegate understanding.** You must comprehend the findings.
- Resolve conflicts between worker reports. Make architectural decisions.
- Write **detailed, self-contained implementation specs** for each worker.
- Each spec should include: exact files to modify, what to change, why, and how to test.

### Phase 3: Implementation
Assign each worker a specific, bounded task from your synthesis.
- Workers should not need to coordinate with each other.
- Each worker's scope should touch ≤5 files. If more, split into multiple workers.
- Workers commit their changes and report what they did.

### Phase 4: Verification
Spawn a **separate** verification worker to test the combined changes.
- The verifier tries to break the implementation, not confirm it.
- The verifier must NOT modify project files.
- Require actual command evidence for every check (PASS/FAIL with output).

## Worker prompt rules

**Workers cannot see your conversation.** Every prompt must be completely self-contained.

### Good prompt
> Fix the race condition in the session creation endpoint.
>
> **File**: `src/auth/session.ts`, function `createSession()` around line 45.
> **Problem**: `db.insert()` is called without checking if a session already exists for the user. When two requests arrive simultaneously, duplicate sessions are created.
> **Fix**: Add a `SELECT ... FOR UPDATE` before the insert, wrapped in a transaction.
> **Test**: Run `npm test -- --filter session` — expect 0 failures.
> **Do NOT modify** any files outside `src/auth/`.

### Bad prompt
> Fix that race condition we discussed in auth.

### Prompt checklist
Every worker prompt must include:
- [ ] Specific file paths and function names
- [ ] Clear description of the problem
- [ ] Specific expected fix or approach
- [ ] How to test / verify the change
- [ ] Scope boundaries (what NOT to touch)

## Error handling

- **Worker returns wrong result**: Re-read their output carefully. Diagnose whether the prompt was unclear or the worker misunderstood. Fix the prompt and re-spawn — do not re-send the same prompt.
- **Workers return conflicting results**: This means research was insufficient or the problem has multiple valid approaches. Choose one approach based on evidence, document the trade-off, and proceed.
- **Worker fails or times out**: Check if the task was too broad. Split it and retry with narrower scope.
- **Verification fails**: Return to Phase 3 with specific fix instructions. Do not re-verify until the fix is confirmed implemented.

## Anti-patterns
- **Lazy delegation**: "Fix the issues we found" — no specifics, no file paths, no test criteria
- **Delegating synthesis**: Asking a worker to "figure out the best approach" — that is your job
- **No-context corrections**: "That's wrong, fix it" — provide the specific problem and expected fix
- **Scope creep**: Worker adds "improvements" beyond the spec — constrain scope explicitly
- **Skipping verification**: Never skip Phase 4. The implementer is an LLM — independent verification is required.

## Scripts

- **[setup-worktree.sh](scripts/setup-worktree.sh)** — Create and teardown isolated git worktrees so parallel workers don't conflict on file changes.
  - `./setup-worktree.sh create worker-auth` — create isolated worktree
  - `./setup-worktree.sh create worker-api main` — create from specific ref
  - `./setup-worktree.sh list` — list active worktrees
  - `./setup-worktree.sh teardown worker-auth` — remove worktree and branch
  - `./setup-worktree.sh teardown-all` — remove all worker-* worktrees

## References

For deeper guidance, load these on demand:

- **[Agent types and isolation](references/agent-types.md)** — Agent type definitions (Explorer, Planner, Verifier, Fork, etc.), tool filtering rules, isolation modes (in-process, worktree, remote), and permission escalation.
- **[Worker prompt template](references/worker-prompt-template.md)** — Copy-ready template for writing self-contained worker prompts, with checklist, anti-pattern table, and sizing guidance.
