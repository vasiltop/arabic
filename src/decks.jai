Deck :: struct {
    id: s64;
    uid: string;
    name: string;
    enabled: bool;
    is_default: bool;
    cards: s64;
    due: s64;
}

Deck_Name_Form :: struct {
    name: string;
}

Deck_Enabled_Form :: struct {
    enabled: s32;
}

deck_select_sql :: "SELECT d.id,d.uid::text,d.name,d.enabled,d.is_default, count(c.id)::bigint AS cards, count(c.id) FILTER (WHERE c.due_at<=now() AND c.id IN (SELECT id FROM eligible_cards))::bigint AS due FROM decks d LEFT JOIN entries e ON e.deck_id=d.id LEFT JOIN review_cards c ON c.entry_id=e.id";

load_decks :: (user_id: s64) -> [] Deck, bool {
    return Postgres.execute(database_connection, Deck, tprint("% % WHERE d.user_id=$1 GROUP BY d.id ORDER BY d.is_default DESC,lower(d.name),d.id", review_eligibility_sql, deck_select_sql), user_id);
}

load_deck :: (user_id: s64, id: s64) -> Deck, bool {
    rows, success := Postgres.execute(database_connection, Deck, tprint("% % WHERE d.user_id=$1 AND d.id=$2 GROUP BY d.id", review_eligibility_sql, deck_select_sql), user_id, id);
    if !success || rows.count == 0 {
        free_db_rows(*rows);
        return .{}, false;
    }
    result := rows[0];
    free(rows.data);
    return result, true;
}

default_deck_id :: (user_id: s64) -> s64 {
    rows, success := Postgres.execute(database_connection, Id_Row, "SELECT id FROM decks WHERE user_id=$1 AND is_default", user_id);
    defer free_db_rows(*rows);
    if !success || rows.count == 0 return 0;
    return rows[0].id;
}

deck_options :: (user_id: s64, selected: s64, include_all := false) -> string {
    decks, success := load_decks(user_id);
    defer free_db_rows(*decks);
    if !success return "";
    b: String_Builder;
    defer free_buffers(*b);
    if include_all append(*b, "<option value=\"0\">All decks</option>");
    for deck: decks append(*b, tprint("<option value=\"%\"%>%</option>", deck.id,
        ifx deck.id == selected then " selected" else "", html_escape(deck.name)));
    return builder_to_string(*b,, temp);
}

query_deck_id :: (request: *Http.Request) -> s64, bool {
    value, found := Http.query_param(request, "deck");
    if !found || value.count == 0 return 0, true;
    id, valid, tail := to_integer(value);
    return id, valid && tail.count == 0 && id >= 0;
}

decks_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    decks, success := load_decks(user.id);
    defer free_db_rows(*decks);
    if !success return Http.text("Could not load decks.", 500);
    b: String_Builder;
    defer free_buffers(*b);
    append(*b, "<section class=\"topline\"><h1>Decks</h1><a class=\"button secondary\" href=\"/decks/import\">Import</a></section>");
    append(*b, "<p class=\"muted\">Learn up to 5 cards at a time across enabled decks. Due counts include only cards ready to review.</p>");
    append(*b, "<form class=\"actions deck-create\" action=\"/decks\" method=\"post\"><label class=\"sr-only\" for=\"deck-name\">Deck name</label><input id=\"deck-name\" name=\"name\" placeholder=\"Deck name\" maxlength=\"100\" required><button type=\"submit\">Create deck</button></form>");
    for deck: decks {
        append(*b, tprint("<section class=\"panel deck-row\"><div class=\"topline\"><h2><a href=\"/nouns?deck=%\">%</a></h2><form action=\"/decks/%/enabled\" method=\"post\"><input type=\"hidden\" name=\"enabled\" value=\"%\"><button type=\"submit\" class=\"%\" aria-label=\"% %\">%</button></form></div><p class=\"muted\">% cards · % due%</p>",
            deck.id, html_escape(deck.name), deck.id, ifx deck.enabled then 0 else 1,
            ifx deck.enabled then "" else "secondary", ifx deck.enabled then "Disable" else "Enable", html_escape(deck.name),
            ifx deck.enabled then "Enabled" else "Disabled", deck.cards, deck.due, ifx deck.is_default then " · Default" else ""));
        append(*b, tprint("<div class=\"actions\"><a class=\"button secondary\" href=\"/decks/%/edit\">Rename</a><a class=\"button secondary\" href=\"/decks/%/export\">Export</a>", deck.id, deck.id));
        if !deck.is_default append(*b, tprint("<a class=\"button secondary\" href=\"/decks/%/delete\">Delete</a>", deck.id));
        append(*b, "</div></section>");
    }
    return Http.html(layout("Decks", builder_to_string(*b,, temp), user));
}

valid_deck_name :: (name: string) -> bool {
    if String.trim(name).count == 0 || !valid_utf8(name) return false;
    characters := 0;
    for byte: name if (byte & 0xc0) != 0x80 characters += 1;
    return characters <= 100;
}

create_deck :: (form: Http.Form(Deck_Name_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    if !valid_deck_name(form.name) return Http.text("Enter a deck name of 1–100 characters.", 400);
    if !db_exec(sql("INSERT INTO decks (user_id,name) VALUES ($1,$2)"), user.id, String.trim(form.name)) return Http.text("That deck name is already in use.", 409);
    return Http.redirect("/decks", 303);
}

edit_deck_page :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    fields := tprint("<label for=\"name\">Name</label><input id=\"name\" name=\"name\" required maxlength=\"100\" value=\"%\">", html_escape(deck.name));
    return Http.html(form_page("Rename deck", fields, tprint("/decks/%/edit", deck.id), "Save", user));
}

rename_deck :: (id: Http.Path("id", s64), form: Http.Form(Deck_Name_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    if !valid_deck_name(form.name) return Http.text("Enter a deck name of 1–100 characters.", 400);
    if !db_exec(sql("UPDATE decks SET name=$1,updated_at=clock_timestamp() WHERE id=$2 AND user_id=$3"), String.trim(form.name), id.value, user.id) return Http.text("That deck name is already in use.", 409);
    return Http.redirect("/decks", 303);
}

set_deck_enabled :: (id: Http.Path("id", s64), form: Http.Form(Deck_Enabled_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    if form.enabled != 0 && form.enabled != 1 return Http.text("Invalid enabled setting.", 400);
    if !db_exec(sql("UPDATE decks SET enabled=$1,updated_at=clock_timestamp() WHERE id=$2 AND user_id=$3"), form.enabled == 1, id.value, user.id) return Http.text("Could not update deck.", 500);
    return Http.redirect("/decks", 303);
}

delete_deck_page :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    if deck.is_default return Http.text("The default deck cannot be deleted.", 409);
    target, target_found := load_deck(user.id, default_deck_id(user.id));
    defer free_db_rows(*target);
    if !target_found return Http.text("Default deck not found.", 500);
    return Http.html(form_page("Delete deck", tprint("<p>Move this deck's entries to <strong>%</strong> and keep their review progress?</p>", html_escape(target.name)), tprint("/decks/%/delete", deck.id), "Delete deck", user));
}

delete_deck :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, id.value);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    if deck.is_default return Http.text("The default deck cannot be deleted.", 409);
    if !db_begin() return Http.text("Could not delete deck.", 500);
    success := db_exec(sql("UPDATE entries SET deck_id=$1,updated_at=clock_timestamp() WHERE deck_id=$2 AND user_id=$3"), default_deck_id(user.id), deck.id, user.id) &&
               db_exec(sql("DELETE FROM decks WHERE id=$1 AND user_id=$2 AND NOT is_default"), deck.id, user.id);
    if !success || !db_commit() {
        db_rollback();
        return Http.text("Could not delete deck.", 500);
    }
    return Http.redirect("/decks", 303);
}
