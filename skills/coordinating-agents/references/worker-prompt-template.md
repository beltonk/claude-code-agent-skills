# Worker Prompt Template

Use this template to write self-contained prompts for sub-agents. Workers cannot see the coordinator's conversation — every prompt must be complete.

## Template

```
## Task
[1-2 sentence description of what to do]

## Context
[Why this task exists. What problem it solves. How it fits into the larger goal.]

## Specific Instructions

### Files to modify
- `path/to/file.ext` — [what to change and why]
- `path/to/other.ext` — [what to change and why]

### Files to read (for context)
- `path/to/context.ext` — [what information to extract]

### Expected approach
[Step-by-step description of the implementation approach]

### Do NOT
- [Explicit scope boundary — what not to touch]
- [Known pitfall to avoid]

## Verification
[How to test the change. Include exact commands and expected output.]
- Run: `[test command]` — expect: [expected output]
- Check: `[validation command]` — expect: [expected state]

## Output
[What to report back. Be specific about what the coordinator needs.]
- Files modified and what changed
- Test results (command + output)
- Any issues encountered
```

## Checklist

Before sending a worker prompt, verify:

- [ ] **File paths are absolute or repo-relative** — not "the auth file" or "the test"
- [ ] **Problem is described, not assumed** — worker doesn't know "the bug we discussed"
- [ ] **Approach is specified** — worker knows HOW to fix, not just WHAT is broken
- [ ] **Scope boundaries are explicit** — worker knows what NOT to touch
- [ ] **Test commands are included** — worker can verify their own work
- [ ] **Expected output is described** — worker knows what success looks like

## Anti-patterns in prompts

| Bad | Why | Good |
|-----|-----|------|
| "Fix the auth bug" | No specifics | "In `src/auth/session.ts`, `createSession()` at line 45 calls `db.insert()` without checking for existing sessions. Add a SELECT FOR UPDATE before insert." |
| "Make the tests pass" | No context | "Run `npm test -- --filter session`. Test `should prevent duplicate sessions` is failing because of the race condition described above." |
| "Update the docs" | No scope | "Add a section to `docs/api.md` documenting the new `/sessions` endpoint. Include request/response schema and error codes." |
| "Refactor the module" | Too broad | "Extract the validation logic from `processOrder()` (lines 45-80) into a `validateOrder()` function in the same file. No other changes." |
| "Fix it like we discussed" | Worker has no context | [Include the full discussion outcome in the prompt] |

## Prompt sizing guidance

- **Research prompts**: Short (3-5 lines). "Find all usages of X in Y directory. Report file paths and line numbers."
- **Implementation prompts**: Medium (10-20 lines). Full template above.
- **Verification prompts**: Medium (10-15 lines). What to test, how to test, what success looks like.
- **If your prompt exceeds 30 lines**, the task may be too broad. Consider splitting into multiple workers.
