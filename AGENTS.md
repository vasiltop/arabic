# Repository guidance

- For each new change task, create a fresh Git worktree from committed `main` and a new `codex/` branch before editing. Leave unrelated and uncommitted work in its original checkout. Use Conventional Commits, run the relevant checks below, then push and open a pull request targeting `main` before handoff. Attach the PR to the chat when supported. Leave merging to the user; report any authentication or publishing blocker.

- Use Conventional Commits for every new commit: `type(scope): description`. The scope is optional. Use `feat`, `fix`, `refactor`, `docs`, `style`, `test`, `build`, or `chore` as appropriate, with a short imperative description. Mark breaking changes with `!` and explain them in the commit body. Do not rewrite existing commits unless requested.
- The product name is **Learn Arabic**. Keep interface copy short and useful; retain clear field labels, actions, validation errors, and exercise cues. Avoid explanatory helper paragraphs and repeated descriptions.
- Keep the Jai backend and Datastar server-rendered architecture. Build configuration belongs in `build.jai`; local database setup runs when the app starts.
- Run `jacket check` and `jacket build` for Jai changes. Check affected user flows when behavior changes. Do not require shell exports or add wrapper scripts for normal local startup.
- Run `python3 tests/decks.py` when changing decks, imports, review eligibility, or migrations. It creates a disposable PostgreSQL cluster and must not use the normal app database.
