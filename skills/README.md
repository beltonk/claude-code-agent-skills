# Agentic Patterns

A complete, reusable asset pack for AI agents — system prompt templates ([`../templates/AGENTS-coding.md`](../templates/AGENTS-coding.md), [`../templates/AGENTS-generic.md`](../templates/AGENTS-generic.md)) plus standalone agent skills with reference docs and scripts.

Drop this folder into any project to give your AI agent (Cursor, OpenCode, Antigravity, or any IDE with agent/skill support) battle-tested behavioral rules and workflow patterns. Pick **coding** or **coding + general** template and copy it to your **project root** as `AGENTS.md` so your IDE loads it automatically.

## Overlap with [Superpowers](https://github.com/obra/superpowers)

If you already use Jesse Vincent’s [Superpowers](https://github.com/obra/superpowers) plugin (Cursor marketplace: `/add-plugin superpowers`), prefer its actively maintained skills for **code review reception**, **multi-agent / worktree workflows**, and **verification discipline** — for example [`receiving-code-review`](https://github.com/obra/superpowers/tree/main/skills/receiving-code-review), [`dispatching-parallel-agents`](https://github.com/obra/superpowers/tree/main/skills/dispatching-parallel-agents), [`subagent-driven-development`](https://github.com/obra/superpowers/tree/main/skills/subagent-driven-development), [`using-git-worktrees`](https://github.com/obra/superpowers/tree/main/skills/using-git-worktrees), and [`verification-before-completion`](https://github.com/obra/superpowers/tree/main/skills/verification-before-completion). This pack keeps **Claude Code–oriented** standards, memory/context/handoff/scaffolding skills, plus **`run-checks.sh`** under `coding-practices/scripts/` so you still have one-shot test/lint/type/build detection without duplicating Superpowers’ skill text.

**`scaffolding-projects`** still fits here: it is a single skill with `explore-project.sh`. Superpowers splits similar ground across [`brainstorming`](https://github.com/obra/superpowers/tree/main/skills/brainstorming), [`writing-plans`](https://github.com/obra/superpowers/tree/main/skills/writing-plans), and [`executing-plans`](https://github.com/obra/superpowers/tree/main/skills/executing-plans). Use whichever packaging you prefer, or both if you want the exploration script alongside Superpowers’ plan-driven flow.

## What's inside

Repository layout (template + skills):

```
templates/
├── AGENTS-coding.md                   ← Code-focused system prompt — copy to project root as AGENTS.md
└── AGENTS-generic.md                  ← Coding + general Q&A — copy to project root as AGENTS.md

skills/
├── README.md                          ← You are here
│
├── agentic-standards/                 ← General agent behavior (any interaction)
│   ├── SKILL.md
│   ├── safety-and-reversibility.md
│   ├── output-quality.md
│   ├── memory-conventions.md
│   ├── prompt-defense.md
│   └── references/
│       ├── system-prompt-architecture.md
│       └── permission-pipeline.md
│
├── coding-practices/                  ← Coding-specific practices (use with agentic-standards)
│   ├── SKILL.md
│   ├── coding-behavior.md
│   ├── tool-preferences.md
│   ├── scripts/
│   │   └── run-checks.sh              ← Auto test/lint/type/build report
│   └── references/
│       ├── tool-design-checklist.md
│       └── verification-report-template.md
│
├── compacting-context/                ← Structured summarization
│   ├── SKILL.md
│   ├── references/
│   │   └── context-pipeline.md
│   └── scripts/
│       └── estimate-tokens.sh
│
├── handing-off-sessions/              ← Session state capture
│   ├── SKILL.md
│   └── scripts/
│       └── gather-session-context.sh
│
├── managing-memories/                 ← Memory lifecycle (save, recall, organize)
│   ├── SKILL.md
│   ├── references/
│   │   ├── secret-scanner-patterns.md
│   │   └── memory-recall-prompt.md
│   └── scripts/
│       ├── scan-secrets.sh
│       └── memory-index.sh
│
└── scaffolding-projects/              ← New feature/project workflow
    ├── SKILL.md
    └── scripts/
        └── explore-project.sh
```

## How the pieces fit together

### AGENTS.md — the always-on layer

Canonical templates: [`../templates/AGENTS-coding.md`](../templates/AGENTS-coding.md) (software-engineering emphasis) and [`../templates/AGENTS-generic.md`](../templates/AGENTS-generic.md) (coding plus research, writing, and general queries). Copy **one** to your **project root** as `AGENTS.md`. That file is the system prompt: behavioral DNA for every turn — plan-before-act discipline, reversibility framework, error recovery and resilience, tool preferences, output quality, security policy, memory conventions (including session memory and staleness), context management, multi-agent coordination, session handoff, review/feedback handling, system prompt architecture (with environment context injection), and project instruction file conventions.

It is designed to be loaded automatically by any AI IDE that supports `AGENTS.md` or equivalent project-level instruction files. It does **not** name or reference any skills — it establishes the behavioral rules and workflow patterns that skills implement in depth.

### Skills — the on-demand layer

Skills are split into **general** (any agent interaction) and **coding-specific** (only when writing code):

#### General skills (any interaction)

| Situation | What kicks in |
|-----------|--------------|
| Any interaction | Foundational standards (safety, output quality, memory, prompt defense) |
| Context window filling up | Structured 9-section summarization |
| Session ending or switching agents | Structured handoff document |
| Natural breakpoint after significant work | Memory save/recall with secret scanning |

#### Coding-specific skills

| Situation | What kicks in |
|-----------|--------------|
| Agent starts writing code | Coding standards (scope, read-before-write, verify, tools); optional `run-checks.sh` for bundled checks |
| New feature or project starting | Structured scaffolding workflow |

### Scripts — reusable operational tools

Scripts exist where they genuinely save the agent work — replacing multi-tool-call sequences, eliminating on-the-fly code generation, or automating data-heavy tasks the agent would otherwise reinvent each time.

Each skill that includes scripts has them fully self-contained — detection and utility logic is inlined, so every skill is portable on its own.

| Script | Skill | What it automates |
|--------|-------|-------------------|
| `run-checks.sh` | coding-practices | Runs test suite + linter + type checker + builder → structured PASS/FAIL report |
| `estimate-tokens.sh` | compacting-context | Estimates token count for files/dirs/stdin; warns at 85% context pressure |
| `gather-session-context.sh` | handing-off-sessions | Collects CWD, OS, git state, project type, recent files, directory structure |
| `explore-project.sh` | scaffolding-projects | Full project profile: type, framework, tests, CI, structure, entry points |
| `scan-secrets.sh` | managing-memories | 36 credential patterns — exit 1 if secrets found, returns rule IDs only |
| `memory-index.sh` | managing-memories | Manages MEMORY.md index: add, deduplicate, search, validate consistency |

Only `agentic-standards` has no scripts (it relies on reference markdown). Scripts are only added where they provide a clear efficiency gain.

All scripts are bash 3.2+ compatible (macOS default), produce structured markdown output, and exit with meaningful codes (0 = pass, 1 = fail, 2 = partial).

### References — the deep knowledge layer

Reference files inside skills provide operational depth loaded only when needed:
- System prompt architecture (static/dynamic split, speculative execution, prompt layering)
- Permission pipelines and tool design patterns
- Agent loop design patterns (flat state machine, streaming + overlapped execution, recovery mechanisms)
- Report templates for structured verification output
- Prompt templates for memory recall
- Pipeline specs for context management (5-stage pipeline, circuit breakers)
- Pattern libraries for adversarial probes and secret scanning

## Agent state directory

Skills that produce persistent output (memories, handoffs) write to a standard location:

```
<project-root>/
└── .agent/
    ├── memories/       ← Preferences, corrections, conventions (one .md per concept)
    │   └── MEMORY.md   ← Index file (max 200 lines)
    └── handoffs/       ← Session handoff documents (timestamped .md files)
```

- Created on first use. Add `.agent/` to `.gitignore` unless the team wants shared state.
- If the project already has an agent state directory (`.claude/`, `.cursor/memories/`), the agent uses the existing one instead.

## Quick start

### Any AI IDE with AGENTS.md support
Copy this `skills/` folder into your project. Copy [`../templates/AGENTS-coding.md`](../templates/AGENTS-coding.md) or [`../templates/AGENTS-generic.md`](../templates/AGENTS-generic.md) to your **project root** as `AGENTS.md`. The IDE loads it automatically.

### Cursor
Copy this `skills/` folder into your project and add `AGENTS.md` at the project root (from the template above). Cursor loads `AGENTS.md` from the project root. Skills in subdirectories are available if your setup supports skill loading.

### OpenCode / Antigravity / other agents
Point your agent at this folder. Load [`../templates/AGENTS-coding.md`](../templates/AGENTS-coding.md) or [`../templates/AGENTS-generic.md`](../templates/AGENTS-generic.md) as the system prompt (or copy to project root as `AGENTS.md`). Configure skill directories for on-demand loading.

### Standalone skill use
Each skill works independently. Point your agent at any `SKILL.md` to load just that workflow.

## Design Principles

- **LLM-agnostic**: No dependency on any specific model, provider, or IDE
- **General + coding split**: General agent skills work for any interaction; coding skills activate only when writing code
- **Token-efficient**: AGENTS.md is the only always-loaded file. Everything else loads on demand.
- **Three-layer architecture**: AGENTS.md (always) → SKILL.md (on trigger) → references/ + scripts/ (on need)
- **Standalone**: No skill depends on another skill, on AGENTS.md, or on external code
- **Scripts only where justified**: Automate multi-step detection, data-heavy scanning, or structured output — not simple tool wrappers
- **Self-contained scripts**: Detection logic is inlined into each skill's scripts — no cross-skill dependencies
- **Adversarial by design**: Includes anti-patterns, failure modes, and self-check mechanisms
- **Claude Code–aligned**: Every pattern is grounded in Claude Code's production architecture — plan-before-act, session memory, memory staleness, focus-aware behavior, persona calibration, speculative execution, streaming overlapped execution, and structured recovery mechanisms
