# Learn Arabic

A server-rendered Modern Standard Arabic vocabulary app built with Jai, Jacket, Datastar, and PostgreSQL. Learners can create a private noun bank and review singular and plural forms as separate active-recall cards.

## Run locally

On macOS, install Jacket 0.25.0 and the native dependencies once using Homebrew:

```sh
brew install libpq argon2 openssl postgresql@17
```

Then, from the project root:

```sh
jacket run
```

Open <http://127.0.0.1:8080>. No linker-path exports, shell scripts, Docker, or npm packages are needed for this workflow.

`build.jai` discovers the Homebrew library directories at compile time. When the app runs, it connects to the existing local database or starts the Homebrew PostgreSQL 17 cluster on `127.0.0.1:54329`. It initializes a missing cluster, creates a missing `arabic` role/database, and applies pending migrations in order. Existing accounts, nouns, review schedules, and database passwords are preserved. Ctrl+C stops the web server; PostgreSQL stays running and its data persists between runs.

Register a username and a password of at least 12 characters, add nouns with their masculine/feminine gender, then start a review. The Nouns page pairs each form with its Arabic example and English translation. Each quiz prompt shows an unvowelled noun and its Arabic example sentence. Recall the meaning and translate the sentence, then reveal the vocalized word, gender, and saved English answers. Rate recall with Again, Hard, Good, or Easy. Older nouns without gender display “Gender not set” until edited.

Use **Decks** to organize nouns and choose which decks enter the review queue. Each account has a permanent Default deck. Both noun forms stay together when moving between decks, and disabling a deck preserves its schedules. Deleting a deck moves its entries to Default. Export and import content through versioned JSON files; imported decks start disabled. See the [deck file format and merge rules](docs/DECK-FORMAT.md).

Review starts with **five learning cards across enabled decks**, including cards waiting for their next review. Singular and plural forms count separately. A card leaves the learning set after two consecutive successful ratings (Hard, Good, or Easy), making room for one new card. Again resets its progress and keeps it in learning. Previously reviewed learning cards take priority over unseen cards, and learned cards still return on their normal schedule. Refreshing or reopening Review does not unlock more cards. Deck due counts show only eligible cards. Once the queue is finished, **Keep going** unlocks five more learning slots for today when more cards are available. You can repeat this after finishing each batch. Extensions survive refreshes and restarts, reset the next day, and never bring scheduled reviews forward. The study day uses your saved profile timezone.

Checking and building configure linking but never start or initialize a database:

```sh
jacket check
jacket build
```

The executable is written to `build/arabic`.

## Profile and progress

Open **Profile** to see your private practice level, XP, total and today's reviews, self-rated successful recall, current and best streaks, and a 14-day activity chart. Every accepted review earns **10 XP**, including Again. Revealing an answer or repeating an already-saved submission earns no XP. Successful recall means a rating of Hard, Good, or Easy; it does not affect XP.

Start at level 1. Level 2 costs 100 XP, then each following level costs 50 XP more: 150, 200, 250, and so on. The review page shows earned XP and level-ups. History and XP begin with the profile update; earlier review totals cannot be reconstructed. Deleting vocabulary preserves earned XP and review history.

Daily statistics and streaks use the timezone saved on your profile, initially UTC. **Use browser timezone** suggests your device's timezone; select **Save timezone** to apply it. Changing the timezone recalculates historical study days. Any completed review counts toward a streak, and yesterday's streak stays current until the end of today.

## Development workflow

Start each new change task in a fresh worktree from committed `main` with a new `codex/` branch. Leave unrelated edits in their original checkout. Use Conventional Commits, run the relevant verification commands, then push and open a pull request targeting `main` before handoff. Leave merging to the user. See [repository guidance](AGENTS.md) for future-session instructions.

## Configuration

| Variable | Default and behavior |
| --- | --- |
| `DATABASE_URL` | Unset enables automatic local database setup using `postgres://arabic:arabic@127.0.0.1:54329/arabic`. Setting it connects directly and skips database management and migrations, unless `--migrate` is explicitly requested. |
| `LISTEN_ADDRESS` | `127.0.0.1:8080`. Use `127.0.0.1:8081` if another app occupies port 8080. |
| `COOKIE_SECURE` | Disabled in automatic local development mode so login works over HTTP. Enabled by default with an explicit `DATABASE_URL`. Set `0` for local HTTP or `1` for HTTPS. |
| `DEV_PGDATA` | Homebrew's `var/postgresql@17` directory. Override to use an isolated development cluster. |
| `DEV_PGPORT` | `54329`. Override for an isolated cluster or a port conflict. Only used when `DATABASE_URL` is unset. |

If a running database has different credentials or uses a different port, set `DATABASE_URL` to its connection URL. Startup reports errors without resetting credentials or stopping other services. A running compatible database is reused before the helper considers starting a cluster.

For a custom database or an existing Compose volume, explicitly apply pending migrations before starting the updated app:

```sh
jacket run -- --migrate
jacket run
```

## Optional Docker database

With Docker and the Compose plugin installed, you can use the provided PostgreSQL container instead:

```sh
docker compose up -d
DATABASE_URL=postgres://arabic:arabic@127.0.0.1:54329/arabic COOKIE_SECURE=0 jacket run
```

Compose applies the SQL migrations when its database volume is first created. For an existing volume, run `DATABASE_URL=postgres://arabic:arabic@127.0.0.1:54329/arabic jacket run -- --migrate` before starting the app with that URL. The container and native workflow both use port 54329, so only one database should listen there at a time.

## Data and development notes

- `migrations/` contains ordered, recorded SQL migrations. Each migration runs in a transaction and is applied once. The deck migration preserves existing content and schedules in an enabled Default deck.
- Passwords use Argon2id. Session cookies are HTTP-only and SameSite=Lax. Keep `COOKIE_SECURE=1` behind HTTPS.
- `src/modules/Datastar` contains the Datastar SSE helpers; `src/modules/Postgres` is the pinned Jai client. `src/application.jai` contains the server-rendered pages and request handlers.
- `jai-postgres` is pinned to the upstream commit recorded in `src/modules/Postgres/UPSTREAM-COMMIT.txt`; a local connection initialization fix is documented in `src/modules/Postgres/LOCAL-PATCHES.md`. Jacket's `Extensions/Http` is Jacket-specific and may change between releases.
- Datastar 1.0.4 is vendored at `static/datastar.js`; the browser needs no CDN access at runtime.
- The selected Postgres client is synchronous, and this starter uses one HTTP worker and one connection. It is suitable for local development, not concurrent production traffic.
- Git tracks source, migrations, configuration, and vendored dependencies with their licenses. Build output, `.env` files, local database directories, logs, and editor files are ignored. `.env` files are not loaded automatically; pass overrides through your shell environment.

Use Conventional Commits for new commits; see [repository guidance](AGENTS.md). Proposed features and follow-up improvements are in the [roadmap](docs/ROADMAP.md).

## Verification

```sh
jacket check
jacket build
python3 tests/decks.py
```

The integration suite creates and removes its own temporary PostgreSQL cluster. It checks migration of populated databases, deck ownership, activation, noun moves, import/export round trips, stale previews, validation, rollback, grammatical gender, both example displays, profile privacy, atomic review history and XP, level thresholds, timezone boundaries, streaks, extra review batches, daily resets, and repeat-submission protection. It does not use the normal app database.
