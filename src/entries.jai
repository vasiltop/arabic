// Decks and scheduling work with entries. Only this type's handlers know noun fields.
Noun_Data :: struct {
    singular: string;
    plural: string;
    meaning: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
}

noun_data :: (noun: $T) -> Noun_Data {
    return .{ noun.singular, noun.plural, noun.meaning, noun.singular_sentence,
              noun.singular_translation, noun.plural_sentence, noun.plural_translation };
}

valid_noun_data :: (noun: Noun_Data) -> bool {
    return String.trim(noun.singular).count > 0 && String.trim(noun.plural).count > 0 &&
           String.trim(noun.meaning).count > 0 && String.trim(noun.singular_sentence).count > 0 &&
           String.trim(noun.singular_translation).count > 0 && String.trim(noun.plural_sentence).count > 0 &&
           String.trim(noun.plural_translation).count > 0;
}

entry_supported :: (kind: string) -> bool {
    return kind == "noun";
}

entry_variants :: (kind: string) -> [] string {
    if kind == "noun" return .["singular", "plural"];
    return .[];
}

entry_create_cards :: (entry_id: s64, kind: string) -> bool {
    if !entry_supported(kind) return false;
    for variant: entry_variants(kind) {
        if !db_exec(sql("INSERT INTO review_cards (entry_id, variant) VALUES ($1,$2)"), entry_id, variant) return false;
    }
    return true;
}

insert_noun_entry :: (user_id: s64, deck_id: s64, data: Noun_Data, uid := "") -> s64, bool {
    ids, success := Postgres.execute(database_connection, Id_Row,
        "INSERT INTO entries (user_id,deck_id,uid,type) VALUES ($1,$2,COALESCE(NULLIF($3,'')::uuid,gen_random_uuid()),'noun') RETURNING id",
        user_id, deck_id, uid);
    defer free_db_rows(*ids);
    if !success || ids.count != 1 return 0, false;
    id := ids[0].id;
    saved := db_exec(sql("INSERT INTO nouns (id,singular,plural,meaning,singular_sentence,singular_translation,plural_sentence,plural_translation) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)"),
        id, data.singular, data.plural, data.meaning, data.singular_sentence, data.singular_translation, data.plural_sentence, data.plural_translation);
    if !saved || !entry_create_cards(id, "noun") return 0, false;
    return id, true;
}

save_noun_data :: (user_id: s64, entry_id: s64, data: Noun_Data) -> bool {
    return db_exec(sql("UPDATE nouns SET singular=$1,plural=$2,meaning=$3,singular_sentence=$4,singular_translation=$5,plural_sentence=$6,plural_translation=$7 WHERE id=$8 AND id IN (SELECT id FROM entries WHERE user_id=$9 AND type='noun')"),
        data.singular, data.plural, data.meaning, data.singular_sentence, data.singular_translation, data.plural_sentence, data.plural_translation, entry_id, user_id);
}

entry_render_prompt :: (card: Card) -> string {
    if card.type == "noun" return noun_card_markup(card);
    return "<section id=\"quiz-card\" class=\"panel\"><h1>Unsupported card type</h1></section>";
}

entry_render_answer :: (card: Card) -> string {
    if card.type == "noun" return noun_answer_markup(card);
    return "<div id=\"quiz-answer\">Unsupported card type.</div>";
}

entry_load_card_data :: (user_id: s64, card: *Card) -> bool {
    payload, found := entry_export_payload(user_id, card.entry_id, card.type);
    card.data = payload;
    return found;
}

entry_export_payload :: (user_id: s64, entry_id: s64, kind: string) -> Json.Json_Value, bool {
    if kind != "noun" return .{}, false;
    noun, found := load_noun(user_id, entry_id);
    defer free_db_rows(*noun);
    if !found return .{}, false;
    data, error := Json.from_json(Json.Json_Value, temp_json(noun_data(noun)));
    defer Json.free_json(*error);
    return data, error.kind == .NONE;
}


noun_payload :: (value: Json.Json_Value) -> Noun_Data, bool {
    text := temp_json(value);
    data, error := Json.from_json(Noun_Data, text);
    good := error.kind == .NONE && valid_noun_data(data);
    Json.free_json(*error);
    return data, good;
}
