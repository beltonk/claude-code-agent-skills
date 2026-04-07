---
name: verifying-implementations
description: Guides adversarial verification of completed code changes. Runs actual commands, requires evidence for every check, and recognizes rationalization patterns like "the code looks correct." Use after finishing any non-trivial implementation (3+ file edits, backend changes, or infrastructure changes) to verify it works before claiming completion.
---

# Verifying Implementations

Your job is to **try to break it**, not confirm it works.

**CRITICAL: Do NOT modify the project.** You are strictly prohibited from creating, modifying, or deleting any project files during verification. Use temporary directories if you need scratch space.

## Workflow

Copy this checklist and track progress:

```
Verification:
- [ ] 1. List all behaviors the implementation should produce
- [ ] 2. List edge cases and failure modes
- [ ] 3. Run commands and record evidence for each check
- [ ] 4. Apply adversarial probes
- [ ] 5. Re-run a sample of checks to confirm consistency
- [ ] 6. Issue verdict
```

### 1. Choose verification strategy by change type

| Change type | Strategy |
|-------------|----------|
| Tests | Run the full suite. Read actual output line by line. |
| Frontend | Start dev server → check console for errors → check network tab → test user flows |
| Backend/API | Start server → send actual HTTP requests → check response codes and bodies |
| CLI/Scripts | Run with representative inputs, edge cases, and malformed input |
| Bug fixes | **First** reproduce the original bug → **then** verify the fix → **then** run regression tests |
| Config changes | Verify the config loads correctly, test with missing/malformed config |

### 2. Record evidence for EVERY check

A check without a command and observed output is **not a check — it's a guess**.

```
### Check: [what you're verifying]
**Command:** [exact command run]
**Output:** [actual terminal/browser output observed]
**Result:** PASS | FAIL
```

### 3. Recognize your own failure patterns

**Verification avoidance** — You read the code, narrate what it does, write "PASS," and move on. Reading is not verification. Run it.

**Seduced by the first 80%** — The UI looks polished, the happy path works, so you conclude it's done. But state persistence is broken, error handling is missing, or edge cases crash. Test beyond the happy path.

Watch for these rationalizations and stop yourself:
- "The code looks correct based on my reading" — **run it.**
- "The implementer's tests already pass" — the implementer is an LLM. **Verify independently.**
- "This is probably fine" — probably is not verified. **Run it.**
- "This would take too long" — not your call. **Verify.**
- "I don't have the right tools" — **check what's actually available before giving up.**

### 4. Adversarial probes

Go beyond happy-path testing:

- **Boundary values**: 0, -1, empty string, very long strings (10K chars), unicode, special characters, MAX_INT
- **Idempotency**: run the same mutating operation twice — does it break or produce duplicates?
- **Missing data**: what happens when expected files, configs, env vars, or DB records don't exist?
- **Concurrency**: parallel requests to create-if-not-exists paths — race conditions? duplicate entries?
- **Malformed input**: invalid JSON, wrong types, extra fields, missing required fields
- **Permissions**: what happens without auth? With expired auth? With wrong role?

### 5. Verdict

End your verification with exactly one of:

- **VERDICT: PASS** — every check has a command, output, and PASS result
- **VERDICT: FAIL** — at least one check failed. List every failure with command and output.
- **VERDICT: PARTIAL** — some checks passed, some could not be verified due to environment limitations (no database access, no browser, etc.). List exactly what could not be verified and why.

Rules:
- Every PASS must have a command and observed output. No exceptions.
- You cannot assign yourself PASS based on code reading alone.
- If you cannot run a check, it is PARTIAL, never PASS.
- After issuing FAIL, list concrete steps to fix each failure.

## Scripts

- **[run-checks.sh](scripts/run-checks.sh)** — Auto-detects test framework, linter, type checker, and build system for the current project. Run it to get a structured PASS/FAIL report in one shot instead of manually discovering and running each tool.
  - `./run-checks.sh` — run all checks
  - `./run-checks.sh --tests-only` — skip lint and type checks
  - `./run-checks.sh --lint-only` — skip tests

## References

For the full report template, adversarial probe library, and per-change-type verification strategies:

- **[Verification report template](references/verification-report-template.md)** — Complete markdown report template with check format, adversarial probe library (input validation, state, error handling, security), and minimum check counts by change type.
