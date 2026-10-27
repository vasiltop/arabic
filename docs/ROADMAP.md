# Feature ideas and improvement priorities

Proposals for future work, based on the current noun bank, forms, quiz, and database code.

Deck creation, activation, noun moves, and portable JSON import/export with merge previews are implemented. See [deck files](DECK-FORMAT.md) for the supported format.

Private profiles, review history, practice levels, XP, streaks, and a 14-day activity chart are implemented. Daily statistics use each learner’s saved timezone.

## New features

| Feature | Learner experience | Fit with the current app |
| --- | --- | --- |
| Sentence gap-fill | See an example with the noun blanked out; recall the correct singular or plural form, then reveal the complete sentence. | Reuses saved examples. Mark the missing phrase explicitly so Arabic vowels, prefixes, and attached articles do not cause incorrect blanks. |
| English → Arabic review | See the English meaning and recall the Arabic singular or plural. Optionally type an answer before revealing the vocalized form. | Adds productive recall alongside recognition, with a separate schedule for each direction. |
| Listening practice | Hear a noun or example, recall its meaning, then reveal the Arabic transcript and English translation. | Adds audio to the existing word bank. Start with attached recordings; choose any speech service separately when designing the feature. |
| Deck study sessions | Start a focused session for one deck, or choose a temporary combination without changing the saved active-deck settings. | Persistent deck activation and one-deck-per-entry membership are already implemented. |
| Reading notebook | Save short Arabic passages, select unfamiliar nouns, and turn them into entries with the source sentence already filled in. | Connects reading to the learner's personal noun bank; the learner still supplies the forms and translations. |
| Spreadsheet import/export | Add CSV interchange for learners editing vocabulary in a spreadsheet. | Versioned JSON deck transfer and merge previews are already implemented. |

Start with **sentence gap-fill** and **English → Arabic review**: both reuse the material learners already enter and add distinct recall exercises. Listening and reading introduce new types of content and need more interface work.

## Improve the existing experience

| Priority | Improvement | Current behavior and intended outcome |
| --- | --- | --- |
| 1 | Retry missed cards during the session | Again currently schedules the card for the next day. Add a short learning/relearning interval so a missed noun can return in the same session. Show each rating's next interval before selection. |
| 2 | Show review progress and due counts | The bank shows a total, while the review empty state gives no return time. Show cards due, remaining in the session, and the next scheduled review. |
| 3 | Search the noun bank | Every noun is loaded into one list. Add search by Arabic form or English meaning, ignore vowel marks when matching Arabic, and paginate larger banks. |
| 4 | Protect work in forms | Noun validation now preserves submitted values. Add field-specific errors and confirm noun deletion before removing its review schedules. Deck deletion already preserves its contents. |
| 5 | Add review shortcuts | Reveal and ratings require clicking. Add Space to reveal and 1–4 to rate, with accessible shortcut hints and protection against duplicate requests. |
| 6 | Explore difficult nouns | Review events now record ratings, practice time, and XP. Add per-noun trends and focused practice for repeatedly missed cards. |

The deck work separates noun CRUD, deck management, review selection, storage helpers, and transfer handling, and releases their database results and rendering buffers. Before increasing usage, measure memory over longer review sessions and add a connection pool for concurrent traffic.
