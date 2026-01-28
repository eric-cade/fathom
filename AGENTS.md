# AGENTS.md — Fathom repo rules for Codex/agents

## Safety + workflow
- Do not delete files unless I explicitly ask you to. Prefer deprecating/moving first.
- Make changes in small, reviewable batches. Keep diffs tight.
- When proposing removals, include evidence: where you searched, what references you found, and what could break if wrong.
- Never add or request secrets. No API keys, tokens, passwords, cookies, or real user data in code, docs, examples, or logs.
- If you need configuration, use environment variables and document them in `.env.example`.

## Godot frontend rules (`Fathom_frontend/`)
- Assume scenes/scripts may be referenced indirectly (autoloads, inspector assignments, dynamic loads).
- Do not rename/move `.tscn`, `.tres`, or scripts without updating all references.
- Prefer “deprecate” markers and a `deprecated/` folder over deletion.
- If you suggest reorganizing folders, propose a step-by-step migration plan.

## Backend rules (`Fathom_backend/`)
- Keep server secrets in environment variables only.
- Avoid logging request bodies or anything that could contain PII.

## Output format I prefer
When asked to prune/organize:
1) Architecture map (entry points, autoloads, key scenes)
2) Candidate list (likely unused) with evidence + risk level
3) Proposed plan in phases (deprecate → verify → delete)
4) A checklist of manual smoke tests to confirm safety
