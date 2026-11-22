Noun_Key_Form :: struct {
    csrf: string;
}

noun_key_csrf :: (request: *Http.Request) -> string {
    return token_hash(tprint("noun-write-key:%", cookie_token(request)));
}

noun_key_settings :: (form: Http.Form(Noun_Key_Form), request: *Http.Request, rotate: bool) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    if form.csrf != noun_key_csrf(request) return Http.text("Invalid security token.", 403);
    if !rotate {
        if !db_exec(sql("DELETE FROM noun_write_keys WHERE user_id=$1"), user.id)
            return Http.text("Could not revoke the key.", 500);
        return Http.redirect("/profile", 303);
    }
    token, ok := random_token();
    if !ok || !db_exec(sql("INSERT INTO noun_write_keys (user_id,token_hash) VALUES ($1,$2) ON CONFLICT (user_id) DO UPDATE SET token_hash=EXCLUDED.token_hash"), user.id, token_hash(token))
        return Http.text("Could not create the key.", 500);
    content := tprint("<section class=\"panel\"><h1>Noun API key</h1><p>Copy this key now. Creating another key revokes this one.</p><label for=\"noun-api-key\">Key</label><input id=\"noun-api-key\" type=\"text\" autocomplete=\"off\" readonly value=\"%\"><div class=\"actions\"><a href=\"/profile\">Back to profile</a></div></section>", token);
    response := Http.html(layout("Noun API key", content, user));
    Http.add_header(*response, "Cache-Control", "no-store");
    return response;
}

rotate_noun_key :: (form: Http.Form(Noun_Key_Form), request: *Http.Request) -> Http.Response {
    return noun_key_settings(form, request, true);
}

revoke_noun_key :: (form: Http.Form(Noun_Key_Form), request: *Http.Request) -> Http.Response {
    return noun_key_settings(form, request, false);
}

noun_api_reply :: (id: s64, status: s32) -> Http.Response {
    return Http.bytes_response(tprint("{\"id\":%}", id), "application/json", status);
}

api_create_noun :: (request: *Http.Request) -> Http.Response {
    authorization, _ := Http.header(request, "Authorization");
    prefix := "Bearer ";
    if authorization.count != prefix.count + 64 || String.slice(authorization, 0, prefix.count) != prefix
        return Http.text("A noun API key is required.", 401);
    token := String.slice(authorization, prefix.count, 64);
    users, ok := Postgres.execute(database_connection, Id_Row,
        "SELECT user_id AS id FROM noun_write_keys WHERE token_hash=$1", token_hash(token));
    defer free_db_rows(*users);
    if !ok return Http.text("Could not check the key.", 500);
    if users.count != 1 return Http.text("Invalid noun API key.", 401);
    user_id := users[0].id;

    uid, _ := Http.header(request, "Idempotency-Key");
    if !valid_uuid(uid) return Http.text("Idempotency-Key must be a lowercase UUID.", 400);
    if request.body.count > 16384 return Http.text("Noun data exceeds 16 KiB.", 413);
    data, error := Json.from_json(Noun_Data, cast(string) request.body);
    defer Json.free_json(*error);
    if error.kind != .NONE || !valid_noun_data(data) || !known_noun_gender(data.gender)
        return Http.text("Provide all eight noun fields and a valid gender.", 400);

    if !db_begin() return Http.text("Could not save noun.", 500);
    committed := false;
    defer if !committed db_rollback();
    existing, read_ok := Postgres.execute(database_connection, Id_Row,
        "SELECT id FROM entries WHERE user_id=$1 AND uid=$2::uuid", user_id, uid);
    defer free_db_rows(*existing);
    if !read_ok return Http.text("Could not save noun.", 500);
    if existing.count == 1 {
        committed = db_commit();
        if !committed return Http.text("Could not save noun.", 500);
        return noun_api_reply(existing[0].id, 200);
    }
    deck_id := default_deck_id(user_id);
    if deck_id == 0 return Http.text("Could not load the Default deck.", 500);
    id, inserted := insert_noun_entry(user_id, deck_id, data, uid);
    committed = inserted && db_commit();
    if !committed return Http.text("Could not save noun. Retry with the same Idempotency-Key.", 503);
    return noun_api_reply(id, 201);
}
