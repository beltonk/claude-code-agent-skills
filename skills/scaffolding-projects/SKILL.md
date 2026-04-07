---
name: scaffolding-projects
description: Provides a structured approach to starting new features or projects. Guides the agent through understanding requirements, exploring existing code, planning, incremental implementation, and verification. Use when asked to build something new — a feature, module, service, or project — to avoid jumping into code without context.
---

# Scaffolding Projects

Follow this sequence when starting something new. Do not write code until you understand what exists and what's needed.

**Scale the process to the task.** For a one-function change, skim phases 1-3 in seconds. For a new service, spend real time on each.

## Workflow

```
Progress:
- [ ] Phase 1: Understand requirements
- [ ] Phase 2: Explore existing code
- [ ] Phase 3: Plan approach
- [ ] Phase 4: Implement incrementally
- [ ] Phase 5: Verify each step
```

### Phase 1: Understand requirements
- Clarify what the user wants. Ask **focused** questions if the request is ambiguous — but do not over-interrogate obvious requests.
- Identify success criteria: what does "done" look like? What should the user be able to do?
- Identify constraints: performance requirements, browser/platform compatibility, dependency restrictions.
- If the user has strong opinions on approach, respect them. Don't argue for a "better" way unless there's a concrete problem.

### Phase 2: Explore existing code
Before writing anything:
- **Search for related functionality** — does something similar already exist? Could you extend it instead of building new?
- **Read the files you'll modify** — understand their current structure, imports, and conventions
- **Understand project patterns**: how are similar features structured? What naming conventions are used? Where do tests live?
- **Check dependencies**: are the libraries you'd need already installed? Don't add duplicates.

### Phase 3: Plan approach
State your plan before implementing. Keep it brief — a bulleted list the user can approve or redirect in seconds:
- Which files will be created or modified?
- What's the dependency order? (types → core logic → integration → tests)
- Any risks, trade-offs, or open questions to flag?

**Try the simplest approach first.** Do not over-engineer. If a simple solution works, ship it. You can iterate later.

### Phase 4: Implement incrementally
- Start with the **smallest working version**, not the complete feature
- Follow existing project structure and conventions exactly
- Create dependency management files (package.json, requirements.txt, go.mod) with **actual versions**, not `"latest"`
- Add tests **alongside** implementation, not as a separate phase
- Run tests after each meaningful change — do not accumulate hundreds of lines without validating

### Phase 5: Verify each step
- Run tests after each meaningful change
- Check for type errors and lint violations
- Verify the feature works **end-to-end** before reporting completion
- If the project has CI checks, run them locally (or tell the user which to check)

## When the plan fails

If your initial approach hits a wall:
1. **Diagnose why** — don't just switch to a different approach blindly
2. **Document what failed** and why (so you don't retry it)
3. **Re-assess from Phase 3** with the new information
4. Tell the user what happened and your revised plan

## Anti-patterns
- Writing hundreds of lines before running anything
- Creating files in locations that don't match project conventions
- Installing dependencies without checking if equivalents already exist
- Building features the user didn't ask for ("while I'm here, I also added...")
- Proposing a plan and then not following it
- Over-planning simple tasks — a one-line fix doesn't need a 10-step plan
- Switching approaches without diagnosing why the first one failed

## Scripts

- **[explore-project.sh](scripts/explore-project.sh)** — Auto-detects project type, framework, package manager, test setup, linters, CI/CD, directory structure, entry points, and naming conventions. Run this at the start of Phase 2 to get a complete project profile in one shot instead of 5-10 separate tool calls.
  - `./explore-project.sh` — explore current directory
  - `./explore-project.sh /path/to/project` — explore specified directory
