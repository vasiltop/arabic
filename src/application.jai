using Basic;

database_connection: *Postgres.PGconn;
datastar_bundle: string;
site_stylesheet: string;

User :: struct {
    id: s64;
    username: string;
}

User_With_Password :: struct {
    id: s64;
    username: string;
    password_hash: string;
}

Noun :: struct {
    id: s64;
    singular: string;
    plural: string;
    meaning: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
}

Card :: struct {
    id: s64;
    form: string;
    singular: string;
    plural: string;
    meaning: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
    interval_days: s32;
    ease_factor: float64;
    repetitions: s32;
}

Id_Row :: struct {
    id: s64;
}

Register_Form :: struct {
    username: string;
    password: string;
}

Login_Form :: struct {
    username: string;
    password: string;
}

Noun_Form :: struct {
    singular: string;
    plural: string;
    meaning: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
}

Rating_Signals :: struct {
    rating: s32;
}

html_escape :: (value: string) -> string {
    output: String_Builder;
    for value {
        if it == #char "&" append(*output, "&amp;");
        else if it == #char "<" append(*output, "&lt;");
        else if it == #char ">" append(*output, "&gt;");
        else if it == #char "\"" append(*output, "&quot;");
        else if it == #char "'" append(*output, "&#39;");
        else append(*output, it);
    }
    return builder_to_string(*output,, temp);
}

layout :: (title: string, content: string, user: User = .{}) -> string {
    output: String_Builder;
    append(*output, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    append(*output, "<title>");
    append(*output, html_escape(title));
    append(*output, " · Learn Arabic</title>");
    append(*output, "<script type=\"module\" src=\"/static/datastar.js\"></script><link rel=\"stylesheet\" href=\"/static/site.css\"></head><body>");
    append(*output, "<header><a href=\"/\"><strong>Learn Arabic</strong></a><nav>");
    if user.id {
        append(*output, "<a href=\"/nouns\">Nouns</a><a href=\"/quiz\">Review</a><span>");
        append(*output, html_escape(user.username));
        append(*output, "</span><form action=\"/logout\" method=\"post\"><button class=\"secondary\" type=\"submit\">Sign out</button></form>");
    } else {
        append(*output, "<a href=\"/login\">Sign in</a><a href=\"/register\">Create account</a>");
    }
    append(*output, "</nav></header><main>");
    append(*output, content);
    append(*output, "</main></body></html>");
    return builder_to_string(*output,, temp);
}

panel_error :: (message: string) -> string {
    return tprint("<p class=\"error\" role=\"alert\">%</p>", html_escape(message));
}

form_page :: (title: string, fields: string, action: string, submit: string, user: User = .{}) -> string {
    content := tprint("<section class=\"panel\"><h1>%</h1><form action=\"%\" method=\"post\">%<div class=\"actions\"><button type=\"submit\">%</button></div></form></section>", html_escape(title), action, fields, html_escape(submit));
    return layout(title, content, user);
}

auth_form :: (is_register: bool, message := "") -> string {
    heading := ifx is_register then "Create account" else "Sign in";
    action := ifx is_register then "/register" else "/login";
    button := ifx is_register then "Create account" else "Sign in";
    fields: String_Builder;
    if message.count append(*fields, panel_error(message));
    append(*fields, "<label for=\"username\">Username</label><input id=\"username\" name=\"username\" autocomplete=\"username\" required minlength=\"3\" maxlength=\"32\">");
    append(*fields, "<label for=\"password\">Password</label><input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"new-password\" required minlength=\"12\">");
    if !is_register append(*fields, "<script>document.getElementById('password').autocomplete='current-password'</script>");
    return form_page(heading, builder_to_string(*fields,, temp), action, button);
}

random_token :: () -> string, bool {
    bytes: [32] u8;
    if RAND_bytes(cast(*u8) *bytes, 32) != 1 return "", false;
    alphabet := "0123456789abcdef";
    token := alloc_string(64,, temp);
    for 0..31 {
        token[it_index * 2] = alphabet[bytes[it_index] >> 4];
        token[it_index * 2 + 1] = alphabet[bytes[it_index] & 0x0f];
    }
    return token, true;
}

token_hash :: (token: string) -> string {
    digest: [32] u8;
    SHA256(token.data, cast(u64) token.count, cast(*u8) *digest);
    alphabet := "0123456789abcdef";
    encoded := alloc_string(64,, temp);
    for 0..31 {
        encoded[it_index * 2] = alphabet[digest[it_index] >> 4];
        encoded[it_index * 2 + 1] = alphabet[digest[it_index] & 0x0f];
    }
    return encoded;
}

hash_password :: (password: string) -> string, bool {
    salt: [16] u8;
    if RAND_bytes(cast(*u8) *salt, 16) != 1 return "", false;
    encoded := alloc_string(256,, temp);
    result := argon2id_hash_encoded(3, 65536, 1, password.data, cast(u64) password.count,
                                    cast(*void) *salt, 16, 32, encoded.data, cast(u64) encoded.count);
    if result != 0 return "", false;
    encoded.count = c_style_strlen(encoded.data);
    return encoded, true;
}

verify_password :: (password: string, encoded_hash: string) -> bool {
    c_hash := to_c_string(encoded_hash);
    defer free(c_hash);
    return argon2id_verify(c_hash, password.data, cast(u64) password.count) == 0;
}

cookie_token :: (request: *Http.Request) -> string {
    cookies, found := Http.header(request, "Cookie");
    if !found return "";
    start := 0;
    while start < cookies.count {
        end := start;
        while end < cookies.count && cookies[end] != #char ";" end += 1;
        part := String.slice(cookies, start, end - start);
        while part.count > 0 && part[0] == #char " " {
            part.data += 1;
            part.count -= 1;
        }
        prefix := "arabic_session=";
        if part.count > prefix.count && String.slice(part, 0, prefix.count) == prefix {
            value := String.slice(part, prefix.count, part.count - prefix.count);
            if value.count == 64 return value;
        }
        start = end + 1;
    }
    return "";
}

current_user :: (request: *Http.Request) -> User, bool {
    token := cookie_token(request);
    if token.count == 0 return .{}, false;
    hash := token_hash(token);
    rows, success := Postgres.execute(database_connection, User,
        "SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = $1 AND s.expires_at > now()",
        hash);
    if !success || rows.count == 0 return .{}, false;
    return rows[0], true;
}

session_cookie_secure :: () -> bool {
    setting := environment_value("COOKIE_SECURE");
    if setting.count return setting != "0";
    return !local_database_mode;
}

new_session :: (user_id: s64) -> Http.Response {
    token, ok := random_token();
    if !ok return Http.text("Could not create a secure login session.", 500);
    hash := token_hash(token);
    session_insert_sql := "INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + interval '30 days')";
    _, inserted := Postgres.execute(database_connection, session_insert_sql, hash, user_id);
    if !inserted return Http.text("Could not create a login session.", 500);
    response := Http.redirect("/nouns", 303);
    secure_flag := ifx session_cookie_secure() then "; Secure" else "";
    Http.add_header(*response, "Set-Cookie", tprint("arabic_session=%; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax%", token, secure_flag));
    return response;
}

clear_session_cookie :: (response: *Http.Response) {
    secure_flag := ifx session_cookie_secure() then "; Secure" else "";
    Http.add_header(response, "Set-Cookie", tprint("arabic_session=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax%", secure_flag));
}

home :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if signed_in return Http.redirect("/nouns");
    content := "<section class=\"panel\"><h1>Learn Arabic</h1><div class=\"actions\"><a class=\"button\" href=\"/register\">Create account</a><a class=\"button secondary\" href=\"/login\">Sign in</a></div></section>";
    return Http.html(layout("Home", content));
}

datastar_asset :: () -> Http.Response {
    return Http.bytes_response(datastar_bundle, "text/javascript; charset=utf-8");
}

css_asset :: () -> Http.Response {
    return Http.bytes_response(site_stylesheet, "text/css; charset=utf-8");
}

register_page :: () -> Http.Response {
    return Http.html(auth_form(true));
}

login_page :: () -> Http.Response {
    return Http.html(auth_form(false));
}

valid_username :: (value: string) -> bool {
    if value.count < 3 || value.count > 32 return false;
    for value {
        valid := (it >= #char "a" && it <= #char "z") || (it >= #char "A" && it <= #char "Z") ||
                 (it >= #char "0" && it <= #char "9") || it == #char "_";
        if !valid return false;
    }
    return true;
}

register_account :: (form: Http.Form(Register_Form), request: *Http.Request) -> Http.Response {
    if !valid_username(form.username) return Http.html(auth_form(true, "Use 3–32 letters, numbers, or underscores for your username."), 400);
    if form.password.count < 12 return Http.html(auth_form(true, "Use a password with at least 12 characters."), 400);
    password_hash, hashed := hash_password(form.password);
    if !hashed return Http.text("Password hashing failed.", 500);
    users, inserted := Postgres.execute(database_connection, Id_Row,
        "INSERT INTO users (username, password_hash) VALUES (lower($1), $2) RETURNING id",
        form.username, password_hash);
    if !inserted || users.count == 0 return Http.html(auth_form(true, "That username is already taken or could not be saved."), 409);
    return new_session(users[0].id);
}

login_account :: (form: Http.Form(Login_Form), request: *Http.Request) -> Http.Response {
    users, success := Postgres.execute(database_connection, User_With_Password,
        "SELECT id, username, password_hash FROM users WHERE username = lower($1)", form.username);
    if !success || users.count == 0 || !verify_password(form.password, users[0].password_hash) {
        return Http.html(auth_form(false, "Username or password was not recognized."), 401);
    }
    return new_session(users[0].id);
}

logout_account :: (request: *Http.Request) -> Http.Response {
    token := cookie_token(request);
    if token.count {
        hash := token_hash(token);
        session_delete_sql := "DELETE FROM sessions WHERE token_hash = $1";
        Postgres.execute(database_connection, session_delete_sql, hash);
    }
    response := Http.redirect("/", 303);
    clear_session_cookie(*response);
    return response;
}

load_nouns :: (user_id: s64) -> [] Noun, bool {
    return Postgres.execute(database_connection, Noun,
        "SELECT id, singular, plural, meaning, singular_sentence, singular_translation, plural_sentence, plural_translation FROM nouns WHERE user_id = $1 ORDER BY lower(singular), id",
        user_id);
}

load_noun :: (user_id: s64, noun_id: s64) -> Noun, bool {
    nouns, success := Postgres.execute(database_connection, Noun,
        "SELECT id, singular, plural, meaning, singular_sentence, singular_translation, plural_sentence, plural_translation FROM nouns WHERE user_id = $1 AND id = $2",
        user_id, noun_id);
    if !success || nouns.count == 0 return .{}, false;
    return nouns[0], true;
}

noun_page :: (title: string, content: string, user: User) -> Http.Response {
    return Http.html(layout(title, content, user));
}

nouns_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    nouns, success := load_nouns(user.id);
    if !success return Http.text("Could not load your noun bank.", 500);

    content: String_Builder;
    append(*content, "<section class=\"topline\"><h1>Nouns</h1><a class=\"button\" href=\"/nouns/new\">Add noun</a></section>");
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

noun_form_markup :: (action: string, noun: Noun = .{}, error_message: string = "") -> string {
    b: String_Builder;
    append(*b, "<section class=\"panel\"><h1>");
    append(*b, ifx action == "/nouns" then "Add noun" else "Edit noun");
    append(*b, "</h1>");
    if error_message.count append(*b, panel_error(error_message));
    append(*b, tprint("<form action=\"%\" method=\"post\"><div class=\"grid\">", action));
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
    return noun_page("Add noun", noun_form_markup("/nouns"), user);
}

valid_noun :: (noun: Noun_Form) -> bool {
    return noun.singular.count > 0 && noun.plural.count > 0 && noun.meaning.count > 0 &&
           noun.singular_sentence.count > 0 && noun.singular_translation.count > 0 &&
           noun.plural_sentence.count > 0 && noun.plural_translation.count > 0;
}

create_noun :: (form: Http.Form(Noun_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    noun := Noun_Form.{ form.singular, form.plural, form.meaning, form.singular_sentence, form.singular_translation, form.plural_sentence, form.plural_translation };
    if !valid_noun(noun) return noun_page("Add noun", noun_form_markup("/nouns", .{}, "Fill in every field."), user);

    Postgres.execute(database_connection, "BEGIN");
    ids, inserted := Postgres.execute(database_connection, Id_Row,
        "INSERT INTO nouns (user_id, singular, plural, meaning, singular_sentence, singular_translation, plural_sentence, plural_translation) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
        user.id, noun.singular, noun.plural, noun.meaning, noun.singular_sentence, noun.singular_translation, noun.plural_sentence, noun.plural_translation);
    if !inserted || ids.count == 0 {
        Postgres.execute(database_connection, "ROLLBACK");
        return noun_page("Add noun", noun_form_markup("/nouns", .{}, "Could not save this noun."), user);
    }
    noun_id := ids[0].id;
    singular_card_sql := "INSERT INTO review_cards (noun_id, form) VALUES ($1, 'singular')";
    plural_card_sql := "INSERT INTO review_cards (noun_id, form) VALUES ($1, 'plural')";
    _, singular_card := Postgres.execute(database_connection, singular_card_sql, noun_id);
    _, plural_card := Postgres.execute(database_connection, plural_card_sql, noun_id);
    if !singular_card || !plural_card {
        Postgres.execute(database_connection, "ROLLBACK");
        return noun_page("Add noun", noun_form_markup("/nouns", .{}, "Could not create review cards for this noun."), user);
    }
    Postgres.execute(database_connection, "COMMIT");
    return Http.redirect("/nouns", 303);
}

edit_noun_page :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    noun, found := load_noun(user.id, id.value);
    if !found return Http.text("Noun not found.", 404);
    action := tprint("/nouns/%/edit", tprint("%", id.value));
    return noun_page("Edit noun", noun_form_markup(action, noun), user);
}

update_noun :: (id: Http.Path("id", s64), form: Http.Form(Noun_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    noun, found := load_noun(user.id, id.value);
    if !found return Http.text("Noun not found.", 404);
    values := Noun_Form.{ form.singular, form.plural, form.meaning, form.singular_sentence, form.singular_translation, form.plural_sentence, form.plural_translation };
    if !valid_noun(values) return noun_page("Edit noun", noun_form_markup(tprint("/nouns/%/edit", tprint("%", id.value)), noun, "Fill in every field."), user);
    update_noun_sql := "UPDATE nouns SET singular=$1, plural=$2, meaning=$3, singular_sentence=$4, singular_translation=$5, plural_sentence=$6, plural_translation=$7, updated_at=now() WHERE id=$8 AND user_id=$9";
    _, updated := Postgres.execute(database_connection, update_noun_sql,
        values.singular, values.plural, values.meaning, values.singular_sentence, values.singular_translation, values.plural_sentence, values.plural_translation, id.value, user.id);
    if !updated return Http.text("Could not update this noun.", 500);
    return Http.redirect("/nouns", 303);
}

delete_noun :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    delete_sql := "DELETE FROM nouns WHERE id=$1 AND user_id=$2";
    _, deleted := Postgres.execute(database_connection, delete_sql, id.value, user.id);
    if !deleted return Http.text("Could not delete this noun.", 500);
    return Http.redirect("/nouns", 303);
}

unvowel :: (value: string) -> string {
    output: String_Builder;
    index := 0;
    while index < value.count {
        if index + 1 < value.count && value[index] == 0xd9 {
            next := value[index + 1];
            if (next >= 0x8b && next <= 0x9f) || next == 0xb0 {
                index += 2;
                continue;
            }
        }
        if index + 1 < value.count && value[index] == 0xdb && value[index + 1] >= 0x96 && value[index + 1] <= 0xad {
            index += 2;
            continue;
        }
        append(*output, value[index]);
        index += 1;
    }
    return builder_to_string(*output,, temp);
}

load_due_card :: (user_id: s64) -> Card, bool {
    cards, success := Postgres.execute(database_connection, Card,
        "SELECT c.id, c.form, n.singular, n.plural, n.meaning, n.singular_sentence, n.singular_translation, n.plural_sentence, n.plural_translation, c.interval_days, c.ease_factor, c.repetitions FROM review_cards c JOIN nouns n ON n.id=c.noun_id WHERE n.user_id=$1 AND c.due_at <= now() ORDER BY c.due_at, random() LIMIT 1",
        user_id);
    if !success || cards.count == 0 return .{}, false;
    return cards[0], true;
}

load_due_card_by_id :: (user_id: s64, card_id: s64) -> Card, bool {
    cards, success := Postgres.execute(database_connection, Card,
        "SELECT c.id, c.form, n.singular, n.plural, n.meaning, n.singular_sentence, n.singular_translation, n.plural_sentence, n.plural_translation, c.interval_days, c.ease_factor, c.repetitions FROM review_cards c JOIN nouns n ON n.id=c.noun_id WHERE n.user_id=$1 AND c.id=$2 AND c.due_at <= now()",
        user_id, card_id);
    if !success || cards.count == 0 return .{}, false;
    return cards[0], true;
}

quiz_card_markup :: (card: Card, found: bool) -> string {
    if !found return "<section class=\"panel\" id=\"quiz-card\"><h1>No reviews due</h1><a class=\"button secondary\" href=\"/nouns\">Nouns</a></section>";
    word := ifx card.form == "plural" then card.plural else card.singular;
    sentence := ifx card.form == "plural" then card.plural_sentence else card.singular_sentence;
    form_label := ifx card.form == "plural" then "Plural" else "Singular";
    return tprint("<section class=\"panel\" id=\"quiz-card\" data-signals:rating=\"0\"><p class=\"muted\">%</p><div class=\"arabic\" lang=\"ar\" dir=\"rtl\">%</div><p class=\"muted\">Translate</p><div class=\"arabic example-prompt\" lang=\"ar\" dir=\"rtl\">%</div><div class=\"actions\" style=\"justify-content:center\"><button type=\"button\" data-on:click=\"@get('/quiz/reveal/%')\">Reveal</button></div><div id=\"quiz-answer\" aria-live=\"polite\"></div></section>", form_label, html_escape(unvowel(word)), html_escape(sentence), tprint("%", card.id));
}

quiz_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    card, found := load_due_card(user.id);
    return noun_page("Review", quiz_card_markup(card, found), user);
}

quiz_answer_markup :: (card: Card) -> string {
    translation := ifx card.form == "plural" then card.plural_translation else card.singular_translation;
    word := ifx card.form == "plural" then card.plural else card.singular;
    card_id := tprint("%", card.id);
    return tprint("<div class=\"quiz-answer\" id=\"quiz-answer\"><div class=\"arabic\" lang=\"ar\" dir=\"rtl\">%</div><h2>%</h2><p>%</p><div class=\"actions ratings\"><button type=\"button\" data-on:click=\"$rating = 0; @post('/quiz/rate/%')\">Again</button><button type=\"button\" data-on:click=\"$rating = 1; @post('/quiz/rate/%')\">Hard</button><button type=\"button\" data-on:click=\"$rating = 2; @post('/quiz/rate/%')\">Good</button><button type=\"button\" data-on:click=\"$rating = 3; @post('/quiz/rate/%')\">Easy</button></div></div>", html_escape(word), html_escape(card.meaning), html_escape(translation), card_id, card_id, card_id, card_id);
}

reveal_card :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    card, found := load_due_card_by_id(user.id, id.value);
    if !found return Http.text("Review card not found.", 404);
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, quiz_answer_markup(card));
    return Datastar.sse_response(*sse);
}

rate_card :: (id: Http.Path("id", s64), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.error_response(request, Http.unauthorized("Sign in to review cards."));
    signals, error := Datastar.read_signals(request, Rating_Signals);
    if error.kind != .NONE return Http.error_response(request, error);
    if signals.rating < 0 || signals.rating > 3 return Http.error_response(request, Http.bad_request("Rating must be from 0 to 3."));
    card, found := load_due_card_by_id(user.id, id.value);
    if !found return Http.error_response(request, Http.not_found("Review card not found."));

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
    update_review_sql := "UPDATE review_cards SET due_at=now() + make_interval(days => $1::integer), interval_days=$1, ease_factor=$2, repetitions=$3, last_reviewed_at=now() WHERE id=$4 AND noun_id IN (SELECT id FROM nouns WHERE user_id=$5)";
    _, updated := Postgres.execute(database_connection, update_review_sql, interval, new_ease, repetitions, id.value, user.id);
    if !updated return Http.text("Could not save this review.", 500);

    next_card, has_next := load_due_card(user.id);
    sse := Datastar.new_sse();
    Datastar.patch_elements(*sse, quiz_card_markup(next_card, has_next));
    return Datastar.sse_response(*sse);
}
