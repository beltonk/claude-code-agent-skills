# Verification Report Template

Use this template to produce a structured, evidence-based verification report. Every check must have a command and observed output — no exceptions.

## Report structure

```markdown
# Verification Report

**Target:** [What was implemented — 1 line]
**Date:** [ISO date]
**Scope:** [Files modified — list paths]

---

## Checks

### Check 1: [What you're verifying]
**Strategy:** [Why this check matters]
**Command:**
```bash
[exact command run]
```
**Expected:** [What a passing result looks like]
**Observed:**
```
[actual terminal output — paste, don't paraphrase]
```
**Result:** PASS | FAIL

### Check 2: [Next check]
...

---

## Adversarial Probes

### Probe 1: [Edge case name]
**Scenario:** [What you're testing — boundary value, missing data, concurrent access, etc.]
**Command:**
```bash
[exact command]
```
**Observed:**
```
[actual output]
```
**Result:** PASS | FAIL

---

## Untestable Items

| Item | Reason | Risk |
|------|--------|------|
| [What couldn't be tested] | [Why — no DB, no browser, etc.] | [Low/Medium/High] |

---

## Summary

| Category | Pass | Fail | Untested |
|----------|------|------|----------|
| Functional checks | N | N | N |
| Adversarial probes | N | N | N |
| **Total** | **N** | **N** | **N** |

## VERDICT: PASS | FAIL | PARTIAL

[1-2 sentence justification]

### Failures (if FAIL or PARTIAL)
1. [Failure description] — **Fix:** [What needs to change]
2. ...
```

## Verification strategy by change type

| Change type | Minimum checks | What to verify |
|-------------|----------------|----------------|
| **Unit test changes** | Run full test suite | All tests pass, no regressions, coverage not decreased |
| **Frontend changes** | 3+ checks | Dev server starts, no console errors, user flow works, responsive |
| **API/Backend changes** | 4+ checks | Server starts, endpoints respond correctly, error cases handled, auth works |
| **CLI/Script changes** | 3+ checks | Runs with normal input, handles edge cases, help/usage works |
| **Bug fixes** | 3+ checks | Original bug reproduced first, fix verified, regression tests pass |
| **Config changes** | 2+ checks | Config loads correctly, missing/malformed config handled |
| **Database changes** | 3+ checks | Migration runs, rollback works, data integrity maintained |

## Adversarial probe library

Use these as a starting checklist. Not all apply to every change — pick the relevant ones.

### Input validation
- Empty string where non-empty expected
- Very long string (10K+ chars)
- Unicode characters (emoji, RTL, zero-width)
- Special characters in paths (`../`, null bytes, spaces)
- Numbers at boundaries: 0, -1, MAX_INT, NaN, Infinity

### State
- Operation with missing prerequisite data
- Same operation run twice (idempotency)
- Operation on stale/deleted data
- Concurrent identical operations (race condition)

### Error handling
- Network timeout / connection refused
- Invalid JSON response from dependency
- Disk full / permission denied
- Missing environment variable
- Missing dependency (library not installed)

### Security
- SQL injection in string input
- XSS in rendered output
- Path traversal in file operations
- Command injection in shell operations
- Auth bypass (missing token, expired token, wrong role)
