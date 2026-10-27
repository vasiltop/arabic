// Reserve learning slots even when those cards are not due. Applying LIMIT after
// due_at would introduce five more new cards every time the learner returned.
// Reviewed/lapsed cards take slots before unseen cards; IDs keep the set stable.
review_eligibility_sql :: #string SQL
WITH active_cards AS (
    SELECT c.*,e.type FROM review_cards c
    JOIN entries e ON e.id=c.entry_id JOIN decks d ON d.id=e.deck_id
    WHERE e.user_id=$1 AND d.enabled
), learning_cards AS (
    SELECT id FROM active_cards WHERE repetitions<2
    ORDER BY (last_reviewed_at IS NULL),id LIMIT 5
), eligible_cards AS (
    SELECT * FROM active_cards
    WHERE repetitions>=2 OR id IN (SELECT id FROM learning_cards)
)
SQL

load_due_card :: (user_id: s64) -> Card, bool {
    ids, success := Postgres.execute(database_connection, Id_Row,
        tprint("% SELECT id FROM eligible_cards WHERE due_at<=now() ORDER BY (last_reviewed_at IS NULL),due_at,id LIMIT 1", review_eligibility_sql), user_id);
    defer free_db_rows(*ids);
    if !success || ids.count == 0 return .{}, false;
    return load_due_card_by_id(user_id, ids[0].id);
}

load_due_card_by_id :: (user_id: s64, card_id: s64) -> Card, bool {
    rows, success := Postgres.execute(database_connection, Card,
        tprint("% SELECT id,entry_id,variant AS form,type,interval_days,ease_factor,repetitions FROM eligible_cards WHERE id=$2 AND due_at<=now()", review_eligibility_sql), user_id, card_id);
    if !success || rows.count == 0 {
        free_db_rows(*rows);
        return .{}, false;
    }
    result := rows[0];
    free(rows.data);
    if !entry_load_card_data(user_id, *result) {
        free_db_rows(*result);
        return .{}, false;
    }
    return result, true;
}

quiz_card_markup :: (card: Card, found: bool, user_id: s64) -> string {
    if found return entry_render_prompt(card);
    decks, loaded := load_decks(user_id);
    defer free_db_rows(*decks);
    active := false;
    if loaded for decks if it.enabled active = true;
    return tprint("<section class=\"panel\" id=\"quiz-card\"><h1>%</h1><a class=\"button secondary\" href=\"/decks\">Decks</a></section>", ifx active then "No reviews due" else "No active decks");
}

refresh_quiz :: (user_id: s64) -> Http.Response {
    card, found := load_due_card(user_id);
    defer free_db_rows(*card);
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, quiz_card_markup(card, found, user_id));
    return Datastar.sse_response(*sse);
}

stale_review_response :: (user_id: s64, card_id: s64) -> Http.Response {
    ids, ok := Postgres.execute(database_connection, Id_Row, "SELECT c.id FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE c.id=$1 AND e.user_id=$2", card_id, user_id);
    defer free_db_rows(*ids);
    if !ok || ids.count == 0 return Http.text("Review card not found.", 404);
    return refresh_quiz(user_id);
}

noun_card_markup :: (card: Card) -> string {
    data, valid := noun_payload(card.data);
    defer Json.free_json(*data);
    if !valid return "<section id=\"quiz-card\">Could not load card.</section>";
    word := ifx card.form == "plural" then data.plural else data.singular;
    sentence := ifx card.form == "plural" then data.plural_sentence else data.singular_sentence;
    form_label := ifx card.form == "plural" then "Plural" else "Singular";
    return tprint("<section class=\"panel\" id=\"quiz-card\" data-signals:rating=\"0\"><p class=\"muted\">%</p><div class=\"arabic\" lang=\"ar\" dir=\"rtl\">%</div><p class=\"muted\">Translate</p><div class=\"arabic example-prompt\" lang=\"ar\" dir=\"rtl\">%</div><div class=\"actions\" style=\"justify-content:center\"><button type=\"button\" data-on:click=\"@get('/quiz/reveal/%')\">Reveal</button></div><div id=\"quiz-answer\" aria-live=\"polite\"></div></section>", form_label, html_escape(unvowel(word)), html_escape(sentence), tprint("%", card.id));
}

quiz_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    card, found := load_due_card(user.id);
    defer free_db_rows(*card);
    return noun_page("Review", tprint("%%", review_progress_markup(user.id), quiz_card_markup(card, found, user.id)), user);
}

noun_answer_markup :: (card: Card) -> string {
    data, valid := noun_payload(card.data);
    defer Json.free_json(*data);
    if !valid return "<div id=\"quiz-answer\">Could not load answer.</div>";
    translation := ifx card.form == "plural" then data.plural_translation else data.singular_translation;
    word := ifx card.form == "plural" then data.plural else data.singular;
    card_id := tprint("%", card.id);
    return tprint("<div class=\"quiz-answer\" id=\"quiz-answer\"><div class=\"arabic\" lang=\"ar\" dir=\"rtl\">%</div><h2>%</h2><p class=\"gender-badge\">%</p><p>%</p><div class=\"actions ratings\"><button type=\"button\" data-on:click=\"$rating = 0; @post('/quiz/rate/%')\">Again</button><button type=\"button\" data-on:click=\"$rating = 1; @post('/quiz/rate/%')\">Hard</button><button type=\"button\" data-on:click=\"$rating = 2; @post('/quiz/rate/%')\">Good</button><button type=\"button\" data-on:click=\"$rating = 3; @post('/quiz/rate/%')\">Easy</button></div></div>", html_escape(word), html_escape(data.meaning), noun_gender_label(data.gender), html_escape(translation), card_id, card_id, card_id, card_id);
}

reveal_card :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    card, found := load_due_card_by_id(user.id, id.value);
    defer free_db_rows(*card);
    if !found return stale_review_response(user.id, id.value);
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, entry_render_answer(card));
    return Datastar.sse_response(*sse);
}

rate_card :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.error_response(request, Http.unauthorized("Sign in to review cards."));
    signals, error := Datastar.read_signals(request, Rating_Signals);
    if error.kind != .NONE return Http.error_response(request, error);
    if signals.rating < 0 || signals.rating > 3 return Http.error_response(request, Http.bad_request("Rating must be from 0 to 3."));
    card, found := load_due_card_by_id(user.id, id.value);
    defer free_db_rows(*card);
    if !found return stale_review_response(user.id, id.value);

    quality := ifx signals.rating == 0 then 0 else ifx signals.rating == 1 then 3 else ifx signals.rating == 2 then 4 else 5;
    new_ease := card.ease_factor + (0.1 - cast(float64) (5 - quality) * (0.08 + cast(float64) (5 - quality) * 0.02));
    if new_ease < 1.3 new_ease = 1.3;
    interval: s32 = 1;
    repetitions := card.repetitions + 1;
    if quality < 3 {
        repetitions = 0;
    } else if card.repetitions == 0 {
        interval = 1;
    } else if card.repetitions == 1 {
        interval = 6;
    } else {
        interval = max(cast(s32) 1, cast(s32) (cast(float64) card.interval_days * card.ease_factor + 0.5));
    }
    // One statement commits both the schedule and XP, or neither. A stale request inserts no event.
    update_review_sql := tprint("%, updated AS (UPDATE review_cards SET due_at=now() + make_interval(days => $3::integer), interval_days=$3, ease_factor=$4, repetitions=$5, last_reviewed_at=now() WHERE id=$2 AND due_at<=now() AND id IN (SELECT id FROM eligible_cards) RETURNING id,variant) INSERT INTO review_events (user_id,card_id,form,rating,xp) SELECT $1,id,variant,$6,10 FROM updated", review_eligibility_sql);
    success, updated := Postgres.execute(database_connection, update_review_sql, user.id, id.value, interval, new_ease, repetitions, signals.rating);
    if !success return Http.text("Could not save this review.", 500);
    if updated == 0 return refresh_quiz(user.id);

    next_card, has_next := load_due_card(user.id);
    defer free_db_rows(*next_card);
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, quiz_card_markup(next_card, has_next, user.id));
    Datastar.patch_elements(*sse, review_progress_markup(user.id, true));
    return Datastar.sse_response(*sse);
}
