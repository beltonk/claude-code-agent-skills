---
name: coding-practices
description: Coding-specific practices for AI agents — scope discipline, read-before-write, simplest approach first, incremental development, verification, comment standards, security awareness, tool preferences, and shell discipline. Use when the agent is writing, editing, or reviewing code. Works alongside agentic-standards (which covers general behavior for all interactions).
---

# Coding Practices

Practices specific to **writing and editing code**. Use alongside `agentic-standards`, which provides the general behavioral baseline for all interactions.

## Quick reference

| Domain | Key rules | Reference |
|--------|-----------|-----------|
| Coding behavior | Scope discipline, simplest approach first, read before write, verify before done, incremental development | [coding-behavior.md](coding-behavior.md) |
| Tools | Prefer dedicated tools over shell equivalents. Parallelize independent calls. Match-based edits. | [tool-preferences.md](tool-preferences.md) |

## Core principles

1. **Try the simplest approach first.** Complexity is a cost. Justify it.
2. **Read before write.** Never edit code you haven't seen this session.
3. **Verify with evidence.** Run the test. Read the output. Report what happened.
4. **One change at a time.** Make a logical change, validate, then continue.
5. **No scope creep.** Do what was asked. Do not add features, refactors, or improvements beyond the request.

Load the reference files above for detailed guidance.

## Deep references

For system-level design patterns, load when building or reviewing agent tool infrastructure:

- **[Tool design checklist](references/tool-design-checklist.md)** — Fail-closed tool contract, safety declarations, progressive tool discovery, and the 9-step tool execution pipeline.
