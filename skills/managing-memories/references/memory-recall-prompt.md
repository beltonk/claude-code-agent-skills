# Memory Recall Prompt

Use this prompt to select relevant memories from a memory store before starting work. This implements LLM-based recall — using a lightweight model query to select memories by semantic relevance rather than keyword or embedding search.

## Why LLM recall over embedding search

- **Cross-domain association**: An LLM can reason that "user prefers TypeScript" is relevant to a question about language choice in a Python project. Embeddings miss this.
- **No index maintenance**: No embedding database to build, update, or sync.
- **Context-aware**: The LLM sees the current query when selecting, not just static similarity.
- **Small-scale optimized**: For stores under ~200 files, LLM selection is fast and accurate.

## Recall prompt template

```
You are selecting memories that will be useful to the coding agent as it
processes the following query. You will be given a manifest of available memory
files with their descriptions.

Rules:
- Return a JSON object: { "selected_memories": ["filename1.md", "filename2.md"] }
- Select at most 5 files.
- Only include memories you are CERTAIN will be helpful for the current query.
- If unsure whether a memory is relevant, do NOT include it.
- If the query mentions tools or libraries already in active use, do NOT select
  basic usage docs for those (they're already loaded). DO still select warnings,
  gotchas, or known issues.
- Prefer memories that contain corrections, constraints, or non-obvious context
  over memories that contain easily re-derivable information.

Query:
${CURRENT_USER_QUERY}

Available memories:
${MEMORY_MANIFEST}
```

## Memory manifest format

Build the manifest from memory file frontmatter:

```
- [user] prefers-minimal-comments (2025-03-15): User wants no code comments unless explaining non-obvious why
- [correction] use-pnpm-not-npm (2025-03-20): Project uses pnpm exclusively, agent corrected
- [project] api-error-format-rfc7807 (2025-04-01): All API errors must use RFC 7807 Problem Details
- [reference] team-grafana-dashboard (2025-04-05): Production monitoring dashboard for auth service
```

Format: `- [type] filename (date): description`

## Pipeline

```
1. Scan memory directory → read YAML frontmatter from each file (max 200 files)
2. Build manifest string from frontmatter (type, filename, date, description)
3. Send recall prompt + manifest to a lightweight/fast model
4. Parse JSON response → list of filenames
5. Load selected files into agent context
```

## Fallback

If the recall query fails (model error, timeout), fall back to loading the memory index file (MEMORY.md) only. Do not load all memories — that defeats the purpose of selective recall.
