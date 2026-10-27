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
    deck_id: s64;
    uid: string;
    singular: string;
    plural: string;
    meaning: string;
    gender: string;
    singular_sentence: string;
    singular_translation: string;
    plural_sentence: string;
    plural_translation: string;
}

Card :: struct {
    id: s64;
    entry_id: s64;
    type: string;
    form: string;
    data: Json.Json_Value;
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
    deck_id: s64;
    singular: string;
    plural: string;
    meaning: string;
    gender: string;
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
    defer free_buffers(*output);
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
    defer free_buffers(*output);
    append(*output, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    append(*output, "<title>");
    append(*output, html_escape(title));
    append(*output, " · Learn Arabic</title>");
    append(*output, "<script type=\"module\" src=\"/static/datastar.js\"></script><link rel=\"stylesheet\" href=\"/static/site.css\"></head><body>");
    append(*output, "<header><a href=\"/\"><strong>Learn Arabic</strong></a><nav>");
    if user.id {
        append(*output, "<a href=\"/decks\">Decks</a><a href=\"/nouns\">Nouns</a><a href=\"/quiz\">Review</a><span>");
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
    defer free_buffers(*fields);
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
    defer free_db_rows(*rows);
    if !success || rows.count == 0 return .{}, false;
    return .{ id = rows[0].id, username = copy_temporary_string(rows[0].username) }, true;
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
    if !db_begin() return Http.text("Could not create account.", 500);
    users, inserted := Postgres.execute(database_connection, Id_Row,
        "INSERT INTO users (username, password_hash) VALUES (lower($1), $2) RETURNING id",
        form.username, password_hash);
    defer free_db_rows(*users);
    if !inserted || users.count == 0 {
        db_rollback();
        return Http.html(auth_form(true, "That username is already taken or could not be saved."), 409);
    }
    if !db_exec(sql("INSERT INTO decks (user_id,name,is_default) VALUES ($1,'Default',true)"), users[0].id) || !db_commit() {
        db_rollback();
        return Http.text("Could not create account.", 500);
    }
    return new_session(users[0].id);
}

login_account :: (form: Http.Form(Login_Form), request: *Http.Request) -> Http.Response {
    users, success := Postgres.execute(database_connection, User_With_Password,
        "SELECT id, username, password_hash FROM users WHERE username = lower($1)", form.username);
    defer free_db_rows(*users);
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

unvowel :: (value: string) -> string {
    output: String_Builder;
    defer free_buffers(*output);
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
