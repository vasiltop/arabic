# Learn Arabic deck files

Export a deck from **Decks → Export**. Import it through **Decks → Import**, review the preview, then confirm. Files contain UTF-8 JSON, with a maximum decoded size of 5 MiB and 10,000 entries. The encoded upload request is limited to 8 MiB.

```json
{
  "format": "learn-arabic-deck",
  "version": 2,
  "deck": {
    "id": "9bec14fc-29c7-4130-a391-616e58cf837d",
    "name": "Everyday nouns"
  },
  "entries": [
    {
      "id": "805120f7-8c9c-465c-9ae3-4ed9a275155a",
      "type": "noun",
      "data": {
        "singular": "كِتَابٌ",
        "plural": "كُتُبٌ",
        "meaning": "book",
        "gender": "masculine",
        "singular_sentence": "هَذَا كِتَابٌ جَدِيدٌ.",
        "singular_translation": "This is a new book.",
        "plural_sentence": "هَذِهِ كُتُبٌ جَدِيدَةٌ.",
        "plural_translation": "These are new books."
      }
    }
  ]
}
```

The deck and entry IDs are stable, lowercase UUIDs. Keep them when editing an exported deck so repeated imports can recognize the same content. Names and Arabic text are not identities: equal text with different IDs creates separate entries. Entry IDs must be unique within a file.

Version 2 supports `noun` entries only. Each entry requires the seven nonempty vocabulary/example strings above and a `gender` field with `masculine`, `feminine`, or `unknown`. Gender describes the noun's lexical gender and is shared by its singular and plural cards. The add/edit form requires masculine or feminine; `unknown` preserves older content whose gender has not been supplied.

Version 1 files remain importable. If an older entry omits gender, a new entry receives `unknown`; merging into an existing entry preserves its recorded gender. Current exports use version 2, including an explicit `unknown` value when necessary. Gender changes appear in merge previews and require the same explicit acceptance as other content updates.

Importing creates singular and plural review cards; they are not serialized in the file. A future content type can define a different `data` structure and its own review variants. Unsupported formats, versions, types, invalid UTF-8, and malformed entries are rejected before a preview is saved.

## Merge behavior

- A previously unknown deck starts disabled. Its suggested name can be edited if another deck already has that name. An existing deck is matched by UUID within the signed-in account and keeps its current name and enabled state.
- New entries are added with fresh review schedules. Unchanged entries are skipped. Select **Use imported content** on a changed entry to accept its incoming fields; otherwise its current content is kept. Existing schedules are preserved either way.
- Entries belong to one deck. If an imported entry already exists in another deck, select its move separately. Accepting a content update does not automatically move it.
- Preview choices never affect another account. Account identifiers, activation settings, default-deck status, and review progress are not exported.
- A preview lasts 30 minutes. Changes to the relevant entries or target deck require refreshing it before confirmation. Confirmation is transactional and cannot apply the same preview twice.

## Internal extension points

`entries` stores ownership, deck membership, stable identity, and type. `nouns` contains noun-specific fields; `review_cards` stores an entry ID, variant, and schedule. A content type supplies payload validation/import/export, review variants, detail loading, and prompt/answer rendering. Deck management and import identities operate independently of those fields.

Ordered SQL migrations record their versions in `schema_migrations`. Local startup applies pending migrations under an advisory lock. Existing noun and review IDs, dates, intervals, ease factors, and repetition counts survive the deck migration.
