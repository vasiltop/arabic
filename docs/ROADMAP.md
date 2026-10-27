# Feature ideas and improvement priorities

Proposals for future work, based on the current noun bank, forms, quiz, and database code.

## New features

| Feature | Learner experience | Fit with the current app |
| --- | --- | --- |
| Sentence gap-fill | See an example with the noun blanked out; recall the correct singular or plural form, then reveal the complete sentence. | Reuses saved examples. Mark the missing phrase explicitly so Arabic vowels, prefixes, and attached articles do not cause incorrect blanks. |
| English → Arabic review | See the English meaning and recall the Arabic singular or plural. Optionally type an answer before revealing the vocalized form. | Adds productive recall alongside recognition, with a separate schedule for each direction. |
| Listening practice | Hear a noun or example, recall its meaning, then reveal the Arabic transcript and English translation. | Adds audio to the existing word bank. Start with attached recordings; choose any speech service separately when designing the feature. |
| Themed decks | Organize nouns into topics such as food, travel, or a textbook chapter; review one collection or mix several. | A noun can belong to multiple decks while retaining its review progress. |
| Reading notebook | Save short Arabic passages, select unfamiliar nouns, and turn them into entries with the source sentence already filled in. | Connects reading to the learner's personal noun bank; the learner still supplies the forms and translations. |
| Vocabulary import/export | Import a CSV of nouns and examples with a preview before saving, and export a personal bank for backup or sharing. | Makes larger banks practical. Detect duplicates and preserve per-account privacy during import. |

Start with **sentence gap-fill** and **English → Arabic review**: both reuse the material learners already enter and add distinct recall exercises. Follow with decks and import/export to support growing banks. Listening and reading introduce new types of content and need more interface work.

## Improve the existing experience

| Priority | Improvement | Current behavior and intended outcome |
| --- | --- | --- |
| 1 | Retry missed cards during the session | Again currently schedules the card for the next day. Add a short learning/relearning interval so a missed noun can return in the same session. Show each rating's next interval before selection. |
| 2 | Show review progress and due counts | The bank shows a total, while the review empty state gives no return time. Show cards due, remaining in the session, and the next scheduled review. |
| 3 | Search the noun bank | Every noun is loaded into one list. Add search by Arabic form or English meaning, ignore vowel marks when matching Arabic, and paginate larger banks. |
| 4 | Protect work in forms | Failed creation re-renders empty fields; failed editing re-renders the old saved values. Preserve the submitted values, identify invalid fields, and confirm deletion before removing a noun and its cards. |
| 5 | Add review shortcuts | Reveal and ratings require clicking. Add Space to reveal and 1–4 to rate, with accessible shortcut hints and protection against duplicate requests. |
| 6 | Record review history | Cards store only their latest review timestamp and schedule. Add review events to show difficult nouns and track progress over time. |

Before increasing usage, also address database result ownership: the PostgreSQL client allocates result arrays and copied strings, and most application callers do not release them. Introduce request-scoped ownership or explicit cleanup and verify memory stays stable across repeated reviews. Separate database access, review scheduling, and page rendering as those changes are implemented.
