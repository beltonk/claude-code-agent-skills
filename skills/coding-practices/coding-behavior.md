# Coding Behavior

## Scope discipline
- Do exactly what was asked. Do not add features, refactors, or improvements beyond the request.
- Do not create files unless absolutely necessary. Prefer editing existing files.
- Do not add error handling for scenarios that cannot happen in the current context.
- Do not create helpers or utility functions for one-time operations.
- Avoid time estimates or predictions about outcomes.

## Read before write
- Read a file before editing it. Never edit code you haven't seen.
- Base changes on actual file contents, not assumptions about what a file might contain.
- For large files, search for the specific section to modify rather than reading the entire file.
- After compaction or context compression, re-read critical files — your memory of them may be stale.

## Try the simplest approach first
- Start with the most straightforward solution. Do not over-engineer.
- Avoid premature abstraction — write the concrete case first, generalize only when needed.
- One function, one responsibility. If a function does two things, question whether that's needed.

## Verify before claiming done
- Run the test, execute the script, check the output before reporting success.
- Never claim "all tests pass" without seeing actual test output showing them pass.
- Report failures faithfully. If something broke, say so — do not rationalize.
- If an approach fails, diagnose **why** before switching tactics. Blind retries waste turns.

## Comments
- Do not add comments that narrate what the code does (e.g., "increment counter", "return result").
- Only comment the *why* when it is non-obvious — trade-offs, constraints, workarounds, API quirks.
- Do not remove existing comments unless removing the code they describe.
- Never use code comments as a scratchpad for your own reasoning.

## Error handling
- **Never crash on non-critical failures.** Catch at boundaries, log, provide fallbacks. The application must remain responsive even when individual operations fail.
- **Return validation results, not exceptions.** Functions that check validity should return `{ok: false, message}`, not throw. Exceptions are for unexpected failures, not expected invalid states.
- **Catch per-promise in parallel operations.** When running `Promise.all` or equivalent, each branch should catch independently so one failure doesn't cancel all parallel work.
- **Shorten error context for LLM consumption.** When feeding error information back to the model, truncate stack traces (top 5 frames is usually enough). Full traces waste context tokens without adding diagnostic value.
- **Queue events before infrastructure is ready.** If the error/event sink isn't initialized yet, buffer events and drain when it attaches — never drop startup errors.
- **Dual-mode error strategy.** Use a flag (e.g., `--hard-fail`) to switch between resilient production behavior (catch + log + continue) and strict development behavior (crash on any error). Developers should see what production silently handles.

## Guard clauses and control flow
- Prefer early return over deep nesting. Check failure conditions first, handle them, and return. The "happy path" should be the least-indented code.
- Use defensive defaults with nullish coalescing (`??`). Supply sensible fallback values rather than crashing on missing data.

## Security awareness
- Do not introduce vulnerabilities: command injection, XSS, SQL injection, path traversal, prototype pollution.
- Validate and sanitize inputs at trust boundaries (user input, API responses, file contents).
- Handle edge cases where failure is likely. Do not silently swallow errors — log or propagate.
- Avoid leaking sensitive data in error messages, logs, or responses.

## Incremental development
- Make one logical change at a time. Validate after each change.
- Do not accumulate hundreds of lines of untested code. Write, test, iterate.
- If you create a dependency file (package.json, requirements.txt, go.mod), use actual version numbers, not "latest."

## Testing discipline
- **Reset state between tests.** Every stateful module should provide a way to reset to initial state. Clear caches, singletons, and global state in `beforeEach`/`afterEach`.
- **Deterministic output.** Sort by name (not time) in tests. Use fixed timestamps and seeded randomness. Tests that depend on execution order or timing are fragile.
- **Mock at boundaries, not functions.** Mock the filesystem, network, and external services — not internal function calls. Internal mocking couples tests to implementation details.
