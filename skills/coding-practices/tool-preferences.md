# Tool Preferences

## Dedicated tools over shell
When a specialized tool exists, use it instead of shell commands. Dedicated tools have proper permission checks, better error handling, and richer output:

- **Read files** → use the read/view tool, not `cat`, `head`, `tail`
- **Edit files** → use the edit tool, not `sed`, `awk`, or echo redirection
- **Create files** → use the write tool, not `cat` with heredoc
- **Search file contents** → use the search/grep tool, not `grep` or `rg`
- **Find files by name** → use the glob/find tool, not `find` or `ls`

Reserve shell exclusively for operations that genuinely require it: system commands, package managers, build tools, git operations, running tests, starting servers.

## Parallelism
- When calling multiple tools with no dependencies between them, make all independent calls in the same turn.
- Do not serialize independent reads. Read 5 files in one turn, not 5 sequential turns.

## File editing
- Use match-based edits (old string → new string) over line-number patching. String matching is self-validating — if the old string doesn't match, the operation fails clearly rather than corrupting the file.
- For large files, read targeted sections or search for specific content rather than reading the entire file.
- After editing, check for lint errors in the modified file.

## Tool result budgets
- Tool outputs can be very large. If a tool returns a massive result, extract the relevant portion rather than processing everything.
- When search returns many results, refine the query rather than reading all matches.
- For commands that produce unbounded output, pipe through `head` or limit flags.

## Progressive tool discovery
- Start with the tools you know. If you need a capability that doesn't match any available tool, check if the environment provides a search or discovery mechanism for additional tools.
- Prefer a tool designed for the task over a general-purpose tool that can approximate it.

## Shell discipline
- Quote file paths containing spaces.
- Prefer short, focused commands over long pipelines.
- Avoid interactive commands — use flags that produce non-interactive output.
- For destructive shell commands, use `--dry-run` or equivalent when available to preview the effect first.

## Lazy loading and efficiency
- Defer expensive operations until they're actually needed. Don't read all files, load all modules, or compute all results up front.
- When checking file state before editing (e.g., "does file X exist?"), use the lightest operation possible (stat, not read).
- If a tool returns structured data, extract only the fields you need rather than processing the entire response.
