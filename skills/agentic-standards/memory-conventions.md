# Memory Conventions

## What to remember
- **User preferences**: working style, communication preferences, role context, formatting choices
- **Corrections**: when the user corrects your approach — include what was wrong, why, and how to do it right
- **Project conventions**: naming patterns, architecture decisions, deployment processes, coding standards
- **External references**: links to docs, dashboards, issue trackers, API endpoints

## What NOT to remember
- Code patterns, architecture, or file paths — derive by reading the codebase (it changes)
- Git history — use `git log` / `git blame` (it's authoritative)
- Debugging solutions — the fix is in the code; the commit message has context
- Anything already in project instruction files — don't duplicate
- Ephemeral state: in-progress work, current conversation details, temp context

## When to extract memories
- At natural breakpoints: task completed, waiting for input, session ending
- After the user explicitly corrects you
- When a convention or preference emerges that will apply to future work
- NOT mid-chain, not after trivial exchanges, not when information is already persisted

## Memory file format
```yaml
---
name: descriptive-kebab-case-name
description: Specific one-line summary for relevance selection
type: user | correction | project | reference
---
Content with actionable details.
**Why:** Context for when and why this applies.
**How to apply:** Specific instructions for acting on this memory.
```

## Organization
- One concept per file. Short, specific, searchable.
- Descriptions must be specific enough for relevance selection: "User prefers Tailwind over CSS modules for styling" not "style preference."
- Keep an index file with one-line summaries linking to each memory file.
- Before creating, check if a related memory already exists — update rather than duplicate.
- If new information contradicts an existing memory, replace the old one.

## Session notes
When a session involves significant work, capture structured context:
- Current state and pending tasks
- Important files and their roles
- Errors encountered and resolutions
- Workflow commands and expected outputs
- Learnings: what worked, what didn't, what to avoid
