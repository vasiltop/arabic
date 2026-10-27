load_nouns :: (user_id: s64, deck_id: s64 = 0) -> [] Noun, bool {
    return Postgres.execute(database_connection, Noun,
        "SELECT n.*,e.deck_id,e.uid::text FROM nouns n JOIN entries e ON e.id=n.id WHERE e.user_id=$1 AND ($2::bigint=0 OR e.deck_id=$2) ORDER BY lower(n.singular),n.id", user_id, deck_id);
}

load_noun :: (user_id: s64, noun_id: s64) -> Noun, bool {
    nouns, success := Postgres.execute(database_connection, Noun,
        "SELECT n.*,e.deck_id,e.uid::text FROM nouns n JOIN entries e ON e.id=n.id WHERE e.user_id=$1 AND e.id=$2", user_id, noun_id);
    if !success || nouns.count == 0 {
        free_db_rows(*nouns);
        return .{}, false;
    }
    result := nouns[0];
    free(nouns.data);
    return result, true;
}

noun_form_value :: (data: Noun_Data, deck_id: s64, id: s64 = 0) -> Noun {
    return .{ id = id, deck_id = deck_id, singular = data.singular, plural = data.plural, meaning = data.meaning,
        singular_sentence = data.singular_sentence, singular_translation = data.singular_translation,
        plural_sentence = data.plural_sentence, plural_translation = data.plural_translation };
}

noun_page :: (title: string, content: string, user: User) -> Http.Response {
    return Http.html(layout(title, content, user));
}

nouns_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck_id, valid := query_deck_id(request);
    if !valid return Http.text("Invalid deck.", 400);
    if deck_id {
        deck, found := load_deck(user.id, deck_id);
        free_db_rows(*deck);
        if !found return Http.text("Deck not found.", 404);
    }
    nouns, success := load_nouns(user.id, deck_id);
    defer free_db_rows(*nouns);
    if !success return Http.text("Could not load your noun bank.", 500);

    content: String_Builder;
    defer free_buffers(*content);
    append(*content, tprint("<section class=\"topline\"><h1>Nouns</h1><a class=\"button\" href=\"/nouns/new?deck=%\">Add noun</a></section>", deck_id));
    append(*content, tprint("<form class=\"actions deck-filter\" action=\"/nouns\" method=\"get\"><label for=\"filter-deck\">Deck</label><select id=\"filter-deck\" name=\"deck\">%</select><button class=\"secondary\" type=\"submit\">Filter</button></form>", deck_options(user.id, deck_id, true)));
    append(*content, tprint("<p class=\"muted\">% noun%</p>", nouns.count, ifx nouns.count == 1 then "" else "s"));
    append(*content, "<section class=\"panel\">");
    if nouns.count == 0 {
        append(*content, "<p>No nouns yet.</p>");
    }
    for noun: nouns {
        append(*content, "<div class=\"word-row\"><div><div class=\"arabic\" lang=\"ar\" dir=\"rtl\">");
        append(*content, html_escape(noun.singular));
        append(*content, " · ");
        append(*content, html_escape(noun.plural));
        append(*content, "</div><strong>");
        append(*content, html_escape(noun.meaning));
        append(*content, "</strong><div class=\"muted\" lang=\"ar\" dir=\"rtl\">");
        append(*content, html_escape(noun.singular_sentence));
        append(*content, "</div></div><div class=\"actions\"><a class=\"button secondary\" href=\"/nouns/");
        append(*content, tprint("%", noun.id));
        append(*content, "/edit\">Edit</a><form class=\"inline\" action=\"/nouns/");
        append(*content, tprint("%", noun.id));
        append(*content, "/delete\" method=\"post\"><button class=\"danger\" type=\"submit\">Delete</button></form></div></div>");
    }
    append(*content, "</section>");
    return noun_page("Nouns", builder_to_string(*content,, temp), user);
}

noun_form_markup :: (action: string, user_id: s64, noun: Noun = .{}, error_message: string = "") -> string {
    b: String_Builder;
    defer free_buffers(*b);
    append(*b, "<section class=\"panel\"><h1>");
    append(*b, ifx action == "/nouns" then "Add noun" else "Edit noun");
    append(*b, "</h1>");
    if error_message.count append(*b, panel_error(error_message));
    append(*b, tprint("<form action=\"%\" method=\"post\"><label for=\"deck_id\">Deck</label><select id=\"deck_id\" name=\"deck_id\" required>%</select><div class=\"grid\">", action, deck_options(user_id, noun.deck_id)));
    append(*b, tprint("<div><label for=\"singular\">Singular (with vowels)</label><input id=\"singular\" name=\"singular\" lang=\"ar\" dir=\"rtl\" required value=\"%\"></div>", html_escape(noun.singular)));
    append(*b, tprint("<div><label for=\"plural\">Plural (with vowels)</label><input id=\"plural\" name=\"plural\" lang=\"ar\" dir=\"rtl\" required value=\"%\"></div>", html_escape(noun.plural)));
    append(*b, "</div>");
    append(*b, tprint("<label for=\"meaning\">English meaning</label><input id=\"meaning\" name=\"meaning\" required value=\"%\">", html_escape(noun.meaning)));
    append(*b, tprint("<div class=\"grid\"><div><label for=\"singular_sentence\">Singular example</label><textarea id=\"singular_sentence\" name=\"singular_sentence\" lang=\"ar\" dir=\"rtl\" required>%</textarea><label for=\"singular_translation\">English translation</label><textarea id=\"singular_translation\" name=\"singular_translation\" required>%</textarea></div>", html_escape(noun.singular_sentence), html_escape(noun.singular_translation)));
    append(*b, tprint("<div><label for=\"plural_sentence\">Plural example</label><textarea id=\"plural_sentence\" name=\"plural_sentence\" lang=\"ar\" dir=\"rtl\" required>%</textarea><label for=\"plural_translation\">English translation</label><textarea id=\"plural_translation\" name=\"plural_translation\" required>%</textarea></div></div>", html_escape(noun.plural_sentence), html_escape(noun.plural_translation)));
    append(*b, "<div class=\"actions\"><button type=\"submit\">Save noun</button><a class=\"button secondary\" href=\"/nouns\">Cancel</a></div></form></section>");
    return builder_to_string(*b,, temp);
}

new_noun_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck_id, valid := query_deck_id(request);
    if !valid return Http.text("Invalid deck.", 400);
    if deck_id == 0 deck_id = default_deck_id(user.id);
    deck, found := load_deck(user.id, deck_id);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    return noun_page("Add noun", noun_form_markup("/nouns", user.id, .{ deck_id = deck_id }), user);
}

create_noun :: (form: Http.Form(Noun_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    deck, found := load_deck(user.id, form.deck_id);
    defer free_db_rows(*deck);
    if !found return Http.text("Deck not found.", 404);
    data := noun_data(form);
    if !valid_noun_data(data) return Http.html(layout("Add noun", noun_form_markup("/nouns", user.id, noun_form_value(data, deck.id), "Fill in every field."), user), 400);
    if !db_begin() return Http.text("Could not save noun.", 500);
    _, inserted := insert_noun_entry(user.id, deck.id, data);
    if !inserted || !db_commit() {
        db_rollback();
        return Http.text("Could not save noun.", 500);
    }
    return Http.redirect(tprint("/nouns?deck=%", deck.id), 303);
}

edit_noun_page :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    noun, found := load_noun(user.id, id.value);
    defer free_db_rows(*noun);
    if !found return Http.text("Noun not found.", 404);
    return noun_page("Edit noun", noun_form_markup(tprint("/nouns/%/edit", id.value), user.id, noun), user);
}

update_noun :: (id: Http.Path("id", s64), form: Http.Form(Noun_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    noun, found := load_noun(user.id, id.value);
    defer free_db_rows(*noun);
    if !found return Http.text("Noun not found.", 404);
    deck, deck_found := load_deck(user.id, form.deck_id);
    defer free_db_rows(*deck);
    if !deck_found return Http.text("Deck not found.", 404);
    data := noun_data(form);
    if !valid_noun_data(data) return Http.html(layout("Edit noun", noun_form_markup(tprint("/nouns/%/edit", id.value), user.id, noun_form_value(data, deck.id, id.value), "Fill in every field."), user), 400);
    if !db_begin() return Http.text("Could not save noun.", 500);
    saved := save_noun_data(user.id, id.value, data) && db_exec(sql("UPDATE entries SET deck_id=$1,updated_at=clock_timestamp() WHERE id=$2 AND user_id=$3"), deck.id, id.value, user.id);
    if !saved || !db_commit() {
        db_rollback();
        return Http.text("Could not save noun.", 500);
    }
    return Http.redirect(tprint("/nouns?deck=%", deck.id), 303);
}

delete_noun :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    success, deleted := Postgres.execute(database_connection, sql("DELETE FROM entries WHERE id=$1 AND user_id=$2 AND type='noun'"), id.value, user.id);
    if !success return Http.text("Could not delete noun.", 500);
    if deleted == 0 return Http.text("Noun not found.", 404);
    return Http.redirect("/nouns", 303);
}
