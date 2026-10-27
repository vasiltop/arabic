DECK_FILE_LIMIT :: 5 * 1024 * 1024;

Transfer_Deck :: struct {
    id: string;
    name: string;
}

Transfer_Entry :: struct {
    id: string;
    type: string;
    data: Json.Json_Value;
}

Deck_File :: struct {
    format: string;
    version: s32;
    deck: Transfer_Deck;
    entries: [] Transfer_Entry;
}

Upload_File :: struct {
    name: string;
    contents: string;
    mime: string;
}

Upload_Signals :: struct {
    files: [] Upload_File;
}

Import_Confirm :: struct @json(default) {
    token: string;
    name: string;
    updates: [] string;
    moves: [] string;
}

Import_Record :: struct {
    token: string;
    payload: string;
    snapshot: string;
    expired: bool;
    consumed: bool;
}

Existing_Entry :: struct {
    id: s64;
    uid: string;
    type: string;
    deck_id: s64;
    deck_name: string;
    source_index: s64;
    singular: string;
    plural: string;
    meaning: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
}

Entry_Identity :: struct {
    id: s64;
    uid: string;
    type: string;
}


valid_uuid :: (value: string) -> bool {
    if value.count != 36 return false;
    for byte, index: value {
        if index == 8 || index == 13 || index == 18 || index == 23 {
            if byte != #char "-" return false;
        } else if !((byte >= #char "0" && byte <= #char "9") || (byte >= #char "a" && byte <= #char "f")) return false;
    }
    return true;
}

valid_utf8 :: (value: string) -> bool {
    index: s64;
    while index < value.count {
        first := value[index];
        if first < 0x80 {
            index += 1;
            continue;
        }
        size: s64;
        code: u32;
        minimum: u32;
        if first >= 0xc2 && first <= 0xdf {
            size = 2;
            code = first & 0x1f;
            minimum = 0x80;
        } else if first >= 0xe0 && first <= 0xef {
            size = 3;
            code = first & 0x0f;
            minimum = 0x800;
        } else if first >= 0xf0 && first <= 0xf4 {
            size = 4;
            code = first & 0x07;
            minimum = 0x10000;
        } else return false;
        if index + size > value.count return false;
        for offset: 1..size - 1 {
            byte := value[index + offset];
            if byte < 0x80 || byte > 0xbf return false;
            code = (code << 6) | cast(u32) (byte & 0x3f);
        }
        if code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) return false;
        index += size;
    }
    return true;
}


entry_validate_payload :: (kind: string, value: Json.Json_Value) -> bool {
    if kind != "noun" return false;
    data, valid := noun_payload(value);
    defer Json.free_json(*data);
    return valid;
}

noun_equal :: (a: Noun_Data, b: Noun_Data) -> bool {
    return a.singular == b.singular && a.plural == b.plural && a.meaning == b.meaning &&
        a.singular_sentence == b.singular_sentence && a.singular_translation == b.singular_translation &&
        a.plural_sentence == b.plural_sentence && a.plural_translation == b.plural_translation;
}

entry_payload_changed :: (existing: Existing_Entry, incoming: Transfer_Entry) -> bool {
    data, valid := noun_payload(incoming.data);
    defer Json.free_json(*data);
    return !valid || existing.type != incoming.type || !noun_equal(noun_data(existing), data);
}

entry_import_create :: (user_id: s64, deck_id: s64, incoming: Transfer_Entry) -> bool {
    if incoming.type != "noun" return false;
    data, valid := noun_payload(incoming.data);
    defer Json.free_json(*data);
    if !valid return false;
    _, saved := insert_noun_entry(user_id, deck_id, data, incoming.id);
    return saved;
}

entry_import_update :: (user_id: s64, existing: Existing_Entry, incoming: Transfer_Entry) -> bool {
    if incoming.type != "noun" || existing.type != incoming.type return false;
    data, valid := noun_payload(incoming.data);
    defer Json.free_json(*data);
    return valid && save_noun_data(user_id, existing.id, data) && db_exec(sql("UPDATE entries SET updated_at=clock_timestamp() WHERE id=$1 AND user_id=$2"), existing.id, user_id);
}

decode_deck_file :: (text: string) -> Deck_File, string {
    if text.count > DECK_FILE_LIMIT return .{}, "Deck files must be 5 MiB or smaller.";
    if !valid_utf8(text) return .{}, "The deck file must contain valid UTF-8 text.";
    document, error := Json.from_json(Deck_File, text, .{ max_depth = 32, max_size = DECK_FILE_LIMIT });
    defer Json.free_json(*error);
    if error.kind != .NONE return document, tprint("Invalid deck file: %", Json.error_text(error));
    if document.format != "learn-arabic-deck" || document.version != 1 return document, "Unsupported deck format or version.";
    if !valid_uuid(document.deck.id) || !valid_deck_name(document.deck.name) return document, "The deck needs a lowercase UUID and a name of 1–100 characters.";
    if document.entries.count > 10000 return document, "A deck file can contain at most 10,000 entries.";
    for entry, index: document.entries {
        if !valid_uuid(entry.id) return document, tprint("Entry % needs a lowercase UUID.", index + 1);
        if !entry_supported(entry.type) return document, tprint("Entry % has an unsupported type: %.", index + 1, entry.type);
        if !entry_validate_payload(entry.type, entry.data) return document, tprint("Entry % has missing or invalid noun fields.", index + 1);
    }
    duplicates, checked := Postgres.execute(database_connection, Id_Row,
        "SELECT (count(*) - count(DISTINCT item->>'id'))::bigint AS id FROM jsonb_array_elements(($1::jsonb)->'entries') item", text);
    defer free_db_rows(*duplicates);
    if !checked || duplicates.count != 1 return document, "Could not validate this deck file.";
    if duplicates[0].id return document, "The deck file contains duplicate entry IDs.";
    return document, "";
}

load_deck_by_uid :: (user_id: s64, uid: string) -> Deck, bool {
    rows, ok := Postgres.execute(database_connection, Deck, tprint("% WHERE d.user_id=$1 AND d.uid=$2::uuid GROUP BY d.id", deck_select_sql), user_id, uid);
    if !ok || rows.count == 0 {
        free_db_rows(*rows);
        return .{}, false;
    }
    deck := rows[0];
    free(rows.data);
    return deck, true;
}

merge_entries :: (user_id: s64, payload: string) -> [] Existing_Entry, bool {
    return Postgres.execute(database_connection, Existing_Entry,
        "SELECT e.id,e.uid::text,e.type,e.deck_id,d.name AS deck_name,(item.ordinality-1)::bigint AS source_index,n.singular,n.plural,n.meaning,n.singular_sentence,n.singular_translation,n.plural_sentence,n.plural_translation FROM entries e JOIN decks d ON d.id=e.deck_id LEFT JOIN nouns n ON n.id=e.id JOIN jsonb_array_elements(($2::jsonb)->'entries') WITH ORDINALITY item(value,ordinality) ON e.uid=(item.value->>'id')::uuid WHERE e.user_id=$1", user_id, payload);
}

merge_snapshot :: (user_id: s64, payload: string) -> string, bool {
    rows, ok := Postgres.execute(database_connection, Text_Row,
        "SELECT jsonb_build_object('deck',(SELECT jsonb_build_object('id',id,'updated',updated_at,'name',name,'enabled',enabled) FROM decks WHERE user_id=$1 AND uid=(($2::jsonb)->'deck'->>'id')::uuid),'entries',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',e.id,'uid',e.uid,'deck',e.deck_id,'type',e.type,'updated',e.updated_at) ORDER BY e.uid) FROM entries e JOIN jsonb_array_elements(($2::jsonb)->'entries') item ON e.uid=(item->>'id')::uuid WHERE e.user_id=$1),'[]'::jsonb))::text AS value", user_id, payload);
    defer free_db_rows(*rows);
    if !ok || rows.count != 1 return "", false;
    return token_hash(rows[0].value), true;
}

proposed_deck_name :: (user_id: s64, name: string) -> string {
    decks, ok := load_decks(user_id);
    defer free_db_rows(*decks);
    if !ok return name;
    candidate := name;
    suffix := 2;
    while true {
        exists := false;
        for deck: decks if String.equal_nocase(deck.name, candidate) exists = true;
        if !exists return candidate;
        candidate = ifx name.count < 75 then tprint("% (imported %)", name, suffix) else tprint("Imported deck %", suffix);
        suffix += 1;
    }
    return candidate;
}

entry_render_diff :: (existing: Existing_Entry, incoming: Transfer_Entry) -> string {
    // Each content type owns its diff view, just as it owns validation and review rendering.
    if incoming.type != "noun" return "";
    data, valid := noun_payload(incoming.data);
    defer Json.free_json(*data);
    if !valid return "";
    labels: [] string = .["Singular", "Plural", "Meaning", "Singular example", "English translation", "Plural example", "English translation"];
    old: [] string = .[existing.singular, existing.plural, existing.meaning, existing.singular_sentence, existing.singular_translation, existing.plural_sentence, existing.plural_translation];
    incoming_values: [] string = .[data.singular, data.plural, data.meaning, data.singular_sentence, data.singular_translation, data.plural_sentence, data.plural_translation];
    b: String_Builder;
    defer free_buffers(*b);
    append(*b, "<div class=\"diff-scroll\"><table class=\"import-diff\"><thead><tr><th>Field</th><th>Current</th><th>Imported</th></tr></thead><tbody>");
    for value, index: old {
        if value == incoming_values[index] continue;
        append(*b, tprint("<tr><th>%</th><td dir=\"auto\">%</td><td dir=\"auto\">%</td></tr>", labels[index], html_escape(value), html_escape(incoming_values[index])));
    }
    append(*b, "</tbody></table></div>");
    return builder_to_string(*b,, temp);
}

load_import :: (user_id: s64, token: string, lock := false) -> Import_Record, bool {
    if token.count != 64 return .{}, false;
    rows, ok := Postgres.execute(database_connection, Import_Record,
        tprint("SELECT token,payload,snapshot,expires_at<=now() AS expired,consumed_at IS NOT NULL AS consumed FROM deck_imports WHERE user_id=$1 AND token=$2%", ifx lock then " FOR UPDATE" else ""), user_id, token);
    if !ok || rows.count == 0 {
        free_db_rows(*rows);
        return .{}, false;
    }
    record := rows[0];
    free(rows.data);
    return record, true;
}

import_preview_markup :: (user_id: s64, record: Import_Record, message := "") -> string {
    if record.expired return "<section id=\"deck-import\" class=\"panel\"><h1>Preview expired</h1><a href=\"/decks/import\">Import again</a></section>";
    if record.consumed return "<section id=\"deck-import\" class=\"panel\"><h1>Already imported</h1><a href=\"/decks\">Decks</a></section>";
    document, error := decode_deck_file(record.payload);
    defer Json.free_json(*document);
    if error.count return tprint("<section id=\"deck-import\" class=\"panel\">%</section>", panel_error(error));
    target, target_exists := load_deck_by_uid(user_id, document.deck.id);
    defer free_db_rows(*target);
    existing, loaded := merge_entries(user_id, record.payload);
    defer free_db_rows(*existing);
    if !loaded return "<section id=\"deck-import\" class=\"panel\">Could not load preview.</section>";
    lookup := NewArray(document.entries.count, *Existing_Entry,, temp);
    for *entry: existing lookup[entry.source_index] = entry;
    fresh, changed, unchanged, moves: s64;
    for incoming, index: document.entries {
        entry := lookup[index];
        if !entry {
            fresh += 1;
            continue;
        }
        if entry_payload_changed(entry.*, incoming) changed += 1;
        else unchanged += 1;
        if !target_exists || entry.deck_id != target.id moves += 1;
    }
    name := ifx target_exists then target.name else proposed_deck_name(user_id, String.trim(document.deck.name));
    current_snapshot, snapshot_ok := merge_snapshot(user_id, record.payload);
    stale := !snapshot_ok || current_snapshot != record.snapshot;
    b: String_Builder;
    defer free_buffers(*b);
    append(*b, "<section id=\"deck-import\" class=\"panel\"><h1>Import preview</h1>");
    if message.count append(*b, panel_error(message));
    if stale {
        append(*b, tprint("<p role=\"alert\">Content changed since this preview.</p><form action=\"/decks/import/%/refresh\" method=\"post\"><button type=\"submit\">Refresh preview</button></form></section>", record.token));
        return builder_to_string(*b,, temp);
    }
    append(*b, tprint("<p>% new · % changed · % unchanged · % moves</p><form action=\"/decks/import/confirm\" method=\"post\"><input type=\"hidden\" name=\"token\" value=\"%\">", fresh, changed, unchanged, moves, record.token));
    if target_exists append(*b, tprint("<h2>%</h2><p class=\"muted\">Existing deck settings and review progress are kept.</p>", html_escape(name)));
    else append(*b, tprint("<label for=\"import-name\">Deck name</label><input id=\"import-name\" name=\"name\" maxlength=\"100\" required value=\"%\"><p class=\"muted\">New deck starts disabled.</p>", html_escape(name)));
    for incoming, index: document.entries {
        entry := lookup[index];
        data, valid := noun_payload(incoming.data);
        defer Json.free_json(*data);
        if !valid continue;
        append(*b, tprint("<article class=\"import-entry\"><h3 dir=\"auto\">% · %</h3>", html_escape(data.singular), html_escape(data.meaning)));
        if !entry append(*b, "<p class=\"muted\">New</p>");
        else {
            if entry_payload_changed(entry.*, incoming) {
                append(*b, entry_render_diff(entry.*, incoming));
                append(*b, tprint("<label class=\"check-label\"><input type=\"checkbox\" name=\"updates\" value=\"%\">Use imported content</label>", incoming.id));
            } else append(*b, "<p class=\"muted\">Unchanged</p>");
            if !target_exists || entry.deck_id != target.id append(*b, tprint("<label class=\"check-label\"><input type=\"checkbox\" name=\"moves\" value=\"%\">Move from % to this deck</label>", incoming.id, html_escape(entry.deck_name)));
        }
        append(*b, "</article>");
    }
    append(*b, "<div class=\"actions\"><button type=\"submit\">Confirm import</button><a class=\"button secondary\" href=\"/decks\">Cancel</a></div></form></section>");
    return builder_to_string(*b,, temp);
}

import_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    content := "<section id=\"deck-import\" class=\"panel\" data-signals=\"{files: [], busy: false}\"><h1>Import deck</h1><label for=\"deck-file\">JSON file · up to 5 MiB</label><input id=\"deck-file\" type=\"file\" accept=\".json,application/json\" data-bind:files><div class=\"actions\"><button type=\"button\" data-indicator:busy data-attr:disabled=\"$busy || $files.length !== 1\" data-on:click=\"@post('/decks/import/preview', {filterSignals: {include: /^files$/}})\">Preview</button></div></section>";
    return Http.html(layout("Import deck", content, user));
}

import_upload_error :: (message: string) -> Http.Response {
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, tprint("<section id=\"deck-import\" class=\"panel\"><h1>Import deck</h1>%<a href=\"/decks/import\">Choose another file</a></section>", panel_error(message)));
    return Datastar.sse_response(*sse);
}

preview_import :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.text("Sign in to import a deck.", 401);
    signals, error := Datastar.read_signals(request, Upload_Signals);
    defer Json.free_json(*signals);
    if error.kind != .NONE return import_upload_error("Could not read the upload. Choose a JSON deck file.");
    if signals.files.count != 1 return import_upload_error("Choose one JSON deck file.");
    if signals.files[0].contents.count > ((DECK_FILE_LIMIT + 2) / 3) * 4 return import_upload_error("Deck files must be 5 MiB or smaller.");
    text, decoded := Base64.base64_decode(signals.files[0].contents);
    defer free(text);
    if !decoded return import_upload_error("Could not decode the uploaded file.");
    canonical := Base64.base64_encode(text);
    defer free(canonical);
    if canonical != signals.files[0].contents return import_upload_error("Could not decode the uploaded file.");
    document, failure := decode_deck_file(text);
    defer Json.free_json(*document);
    if failure.count return import_upload_error(failure);
    existing, loaded := merge_entries(user.id, text);
    defer free_db_rows(*existing);
    if !loaded return import_upload_error("Could not load existing entries.");
    for entry: existing if entry.type != document.entries[entry.source_index].type return import_upload_error("An entry ID already belongs to a different content type.");
    snapshot, snapshot_ok := merge_snapshot(user.id, text);
    token, token_ok := random_token();
    if !snapshot_ok || !token_ok return import_upload_error("Could not create preview.");
    db_exec(sql("DELETE FROM deck_imports WHERE expires_at < now() - interval '1 day'"));
    if !db_exec(sql("INSERT INTO deck_imports (token,user_id,payload,snapshot) VALUES ($1,$2,$3,$4)"), token, user.id, text, snapshot) return import_upload_error("Could not save preview.");
    record := Import_Record.{ token = token, payload = text, snapshot = snapshot };
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, import_preview_markup(user.id, record));
    return Datastar.sse_response(*sse);
}

import_preview_page :: (token: Http.Path("token", string), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    record, found := load_import(user.id, token.value);
    defer free_db_rows(*record);
    if !found return Http.text("Preview not found.", 404);
    return Http.html(layout("Import preview", import_preview_markup(user.id, record), user), ifx record.expired then 410 else 200);
}

refresh_import :: (token: Http.Path("token", string), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    record, found := load_import(user.id, token.value);
    defer free_db_rows(*record);
    if !found return Http.text("Preview not found.", 404);
    if record.expired || record.consumed return Http.html(layout("Import preview", import_preview_markup(user.id, record), user), 410);
    snapshot, ok := merge_snapshot(user.id, record.payload);
    if !ok || !db_exec(sql("UPDATE deck_imports SET snapshot=$1,expires_at=now()+interval '30 minutes' WHERE token=$2 AND user_id=$3 AND consumed_at IS NULL AND expires_at>now()"), snapshot, record.token, user.id) return Http.text("Could not refresh preview.", 409);
    return Http.redirect(tprint("/decks/import/%", record.token), 303);
}

selected_id :: (ids: [] string, uid: string) -> bool {
    for id: ids if id == uid return true;
    return false;
}

confirm_import :: (form: Http.Form(Import_Confirm), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    if !db_begin() return Http.text("Could not start import.", 500);
    committed := false;
    defer if !committed db_rollback();
    record, found := load_import(user.id, form.token, true);
    defer free_db_rows(*record);
    if !found return Http.text("Preview not found.", 404);
    if record.expired || record.consumed return Http.html(layout("Import preview", import_preview_markup(user.id, record), user), ifx record.expired then 410 else 409);
    snapshot, ok := merge_snapshot(user.id, record.payload);
    if !ok || snapshot != record.snapshot return Http.html(layout("Import preview", import_preview_markup(user.id, record), user), 409);
    document, failure := decode_deck_file(record.payload);
    defer Json.free_json(*document);
    if failure.count return Http.text(failure, 400);
    target, target_exists := load_deck_by_uid(user.id, document.deck.id);
    defer free_db_rows(*target);
    existing, loaded := merge_entries(user.id, record.payload);
    defer free_db_rows(*existing);
    if !loaded return Http.text("Could not load existing entries.", 500);
    lookup := NewArray(document.entries.count, *Existing_Entry,, temp);
    for *entry: existing lookup[entry.source_index] = entry;
    // Only accept choices present in this preview; arbitrary IDs cannot update other entries.
    for uid: form.updates {
        known := false;
        for entry: existing if entry.uid == uid && entry_payload_changed(entry, document.entries[entry.source_index]) known = true;
        if !known return Http.text("Invalid content selection.", 400);
    }
    for uid: form.moves {
        known := false;
        for entry: existing if entry.uid == uid && (!target_exists || entry.deck_id != target.id) known = true;
        if !known return Http.text("Invalid move selection.", 400);
    }
    deck_id := target.id;
    if !target_exists {
        if !valid_deck_name(form.name) return Http.html(layout("Import preview", import_preview_markup(user.id, record, "Enter a deck name of 1–100 characters."), user), 400);
        ids, created := Postgres.execute(database_connection, Id_Row,
            "INSERT INTO decks (user_id,uid,name,enabled) VALUES ($1,$2::uuid,$3,false) ON CONFLICT DO NOTHING RETURNING id", user.id, document.deck.id, String.trim(form.name));
        defer free_db_rows(*ids);
        if !created || ids.count != 1 return Http.html(layout("Import preview", import_preview_markup(user.id, record, "That deck name is already in use. Choose another name."), user), 409);
        deck_id = ids[0].id;
    }
    for incoming, index: document.entries {
        entry := lookup[index];
        if !entry {
            if !entry_import_create(user.id, deck_id, incoming) return Http.text("Import failed. No changes were saved.", 500);
        } else {
            if selected_id(form.updates, incoming.id) && !entry_import_update(user.id, entry.*, incoming) return Http.text("Import failed. No changes were saved.", 500);
            if selected_id(form.moves, incoming.id) && !db_exec(sql("UPDATE entries SET deck_id=$1,updated_at=clock_timestamp() WHERE id=$2 AND user_id=$3"), deck_id, entry.id, user.id) return Http.text("Import failed. No changes were saved.", 500);
        }
    }
    consumed := db_exec(sql("UPDATE deck_imports SET consumed_at=clock_timestamp() WHERE token=$1 AND user_id=$2 AND consumed_at IS NULL"), record.token, user.id);
    if !consumed || !db_commit() return Http.text("Import failed. Refresh the preview and try again.", 409);
    committed = true;
    return Http.redirect(tprint("/nouns?deck=%", deck_id), 303);
}

export_deck :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    identities, loaded := Postgres.execute(database_connection, Entry_Identity,
        "SELECT id,uid::text,type FROM entries WHERE user_id=$1 AND deck_id=$2 ORDER BY id", user.id, deck.id);
    defer free_db_rows(*identities);
    if !loaded return Http.text("Could not export deck.", 500);
    document := Deck_File.{ format = "learn-arabic-deck", version = 1, deck = .{ id = deck.uid, name = deck.name } };
    entries: [..] Transfer_Entry;
    defer {
        for *entry: entries Json.free_json(*entry.data);
        array_free(entries);
    }
    for identity: identities {
        data, encoded := entry_export_payload(user.id, identity.id, identity.type);
        if !encoded {
            Json.free_json(*data);
            return Http.text("This deck contains a type that cannot be exported by this version.", 422);
        }
        array_add(*entries, .{ id = identity.uid, type = identity.type, data = data });
    }
    document.entries = entries;
    response := Http.bytes_response(temp_json(document, true), "application/json; charset=utf-8");
    Http.add_header(*response, "Content-Disposition", tprint("attachment; filename=\"learn-arabic-%.json\"", deck.uid));
    Http.add_header(*response, "Cache-Control", "no-store");
    return response;
}
