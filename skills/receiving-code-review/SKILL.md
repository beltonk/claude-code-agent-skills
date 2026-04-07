---
name: receiving-code-review
description: Enforces rigorous handling of code review feedback. Classifies comments by severity, verifies claims independently, prevents blind implementation of incorrect suggestions, and handles contradictory reviews. Use when receiving review comments on a pull request or code change.
---

# Receiving Code Review

Apply technical rigor to review feedback — not performative agreement.

## Step 1: Classify and prioritize each comment

Process comments in priority order — fix critical issues before addressing style.

| Priority | Category | Action |
|----------|----------|--------|
| **P0** | Security issue | Verify and fix immediately. These block merging. |
| **P1** | Correctness bug | Verify independently. If confirmed, fix. If not, explain with evidence. |
| **P2** | Performance concern | Verify with measurement, profiling, or big-O reasoning. Do not optimize without evidence of a real problem. |
| **P3** | API/contract issue | Check if it would break consumers. Fix if yes, discuss trade-offs if debatable. |
| **P4** | Style preference | Implement if it matches project conventions. Skip if purely personal preference with no convention behind it. |
| **P5** | Nit / typo | Fix. These are cheap and reduce review noise. |

## Step 2: Verify before implementing

For each non-trivial suggestion:
1. **Read the code** the reviewer is commenting on — do not rely on memory
2. **Understand their claim** — what specifically do they think is wrong?
3. **Test the claim** — does the edge case they describe actually occur? Run it.
4. **Check for side effects** — will the suggested fix break something else?
5. **Check test coverage** — do existing tests cover this case? If not, should they?

## Step 3: Implement

- **Never implement feedback that introduces bugs.** If a suggestion would break existing tests or behavior, flag the conflict with evidence.
- **Never implement feedback you don't understand.** Ask for clarification with a specific question.
- **Never assume the reviewer is right** — verify independently. Reviewers make mistakes too.
- **Never assume the reviewer is wrong** — they may see something you missed. Approach with genuine curiosity.
- **Batch related changes** into one commit, not one commit per comment.
- **Run the full test suite** after all changes. Do not commit untested changes.

## Step 4: Handle contradictory reviews

When multiple reviewers disagree:
1. Identify the conflict explicitly: "Reviewer A suggests X, Reviewer B suggests Y"
2. Evaluate each suggestion independently against the codebase and tests
3. Pick the approach with stronger evidence. Document the reasoning.
4. If genuinely ambiguous, ask the reviewers to resolve the conflict between themselves
5. Do NOT implement both conflicting suggestions

## Step 5: Respond to each comment

- **Agreed and implemented** → state what changed in 1 line
- **Disagree** → explain why with evidence (test output, spec reference, or logical reasoning). Be respectful but firm.
- **Need clarification** → ask a specific, bounded question. Not "what do you mean?" but "do you mean X or Y?"
- **Won't fix** → explain why (e.g., out of scope, introduces regression). Offer to create a follow-up issue.

## Anti-patterns
- Changing correct code to satisfy a misguided comment
- "Sounds good, fixed!" without actually testing the change
- Ignoring comments because they seem minor (nits accumulate)
- Implementing every suggestion without questioning (rubber-stamping)
- Defensive responses without evidence ("that's fine as-is" with no reasoning)

