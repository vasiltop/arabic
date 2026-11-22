Basic :: #import "Basic";

Http :: #import "Extensions/Http";
Postgres :: #import "Postgres";
Datastar :: #import "Datastar";
File :: #import "File";
String :: #import "String";
Json :: #import "Extensions/Json";
Base64 :: #import "Base64";

libc :: #system_library "libc";
libargon2 :: #system_library "argon2";
libcrypto :: #system_library "crypto";
c_getenv :: (name: *u8) -> *u8 #foreign libc "getenv";

argon2id_hash_encoded :: (time_cost: u32, memory_cost: u32, parallelism: u32,
                          password: *void, password_length: u64, salt: *void,
                          salt_length: u64, hash_length: u64,
                          encoded: *u8, encoded_length: u64) -> s32 #foreign libargon2;

argon2id_verify :: (encoded: *u8, password: *void, password_length: u64) -> s32 #foreign libargon2;
RAND_bytes :: (buffer: *u8, length: s32) -> s32 #foreign libcrypto;
SHA256 :: (data: *u8, length: u64, digest: *u8) -> *u8 #foreign libcrypto;

#load "application.jai";
#load "storage.jai";
#load "entries.jai";
#load "decks.jai";
#load "nouns.jai";
#load "noun_api.jai";
#load "reviews.jai";
#load "profile.jai";
#load "transfers.jai";
#load "development.jai";

environment_value :: (name: string) -> string {
    c_name := to_c_string(name);
    defer free(c_name);
    value := c_getenv(c_name);
    return ifx value then to_string(value) else "";
}

main :: () {
    migrate_only := false;
    for argument: get_command_line_arguments() if argument == "--migrate" migrate_only = true;
    connection_string := environment_value("DATABASE_URL");
    local_database_mode = connection_string.count == 0;
    database: *Postgres.PGconn;
    connected: bool;
    if local_database_mode {
        database, connected = start_local_database();
    } else {
        database, connected = Postgres.connect(connection_string);
    }
    if !connected {
        startup_error("Could not connect to PostgreSQL. For an existing database, check DATABASE_URL and that its server is running.");
        Postgres.disconnect(database);
        exit(1);
        return;
    }
    defer Postgres.disconnect(database);
    database_connection = database;

    if migrate_only {
        if !local_database_mode && !apply_migrations(database) {
            exit(1);
            return;
        }
        print("Database migrations are up to date.\n");
        return;
    }

    bundle, read_ok := File.read_entire_file("static/datastar.js");
    if !read_ok {
        print("Could not read static/datastar.js. Run the server from the project root.\n", to_standard_error = true);
        exit(1);
        return;
    }
    datastar_bundle = bundle;
    defer free(datastar_bundle.data);

    css, css_ok := File.read_entire_file("static/site.css");
    if !css_ok {
        print("Could not read static/site.css. Run the server from the project root.\n", to_standard_error = true);
        exit(1);
        return;
    }
    site_stylesheet = css;
    defer free(site_stylesheet.data);

    app: Http.App;
    // jai-postgres is synchronous and a PGconn must not be used concurrently. Use one request
    // worker for this local starter until the database layer grows a connection pool.
    app.config.address = environment_value("LISTEN_ADDRESS");
    if app.config.address.count == 0 app.config.address = "127.0.0.1:8080";
    app.config.threads = 1;
    app.config.log_requests = true;
    app.config.max_body_size = 8 * 1024 * 1024;

    Http.get(*app, "/", home);
    Http.get(*app, "/static/datastar.js", datastar_asset);
    Http.get(*app, "/static/site.css", css_asset);
    Http.get(*app, "/register", register_page);
    Http.post(*app, "/register", register_account);
    Http.get(*app, "/login", login_page);
    Http.post(*app, "/login", login_account);
    Http.post(*app, "/logout", logout_account);
    Http.get(*app, "/profile", profile_page);
    Http.post(*app, "/profile/timezone", save_profile_timezone);
    Http.post(*app, "/profile/noun-key/rotate", rotate_noun_key);
    Http.post(*app, "/profile/noun-key/revoke", revoke_noun_key);
    Http.post(*app, "/api/v1/nouns", api_create_noun);
    Http.get(*app, "/decks", decks_page);
    Http.get(*app, "/decks/import", import_page);
    Http.post(*app, "/decks/import/preview", preview_import);
    Http.post(*app, "/decks/import/confirm", confirm_import);
    Http.get(*app, "/decks/import/{token}", import_preview_page);
    Http.post(*app, "/decks/import/{token}/refresh", refresh_import);
    Http.get(*app, "/decks/{id}/export", export_deck);
    Http.post(*app, "/decks", create_deck);
    Http.get(*app, "/decks/{id}/edit", edit_deck_page);
    Http.post(*app, "/decks/{id}/edit", rename_deck);
    Http.post(*app, "/decks/{id}/enabled", set_deck_enabled);
    Http.get(*app, "/decks/{id}/delete", delete_deck_page);
    Http.post(*app, "/decks/{id}/delete", delete_deck);
    Http.get(*app, "/nouns", nouns_page);
    Http.get(*app, "/nouns/new", new_noun_page);
    Http.post(*app, "/nouns", create_noun);
    Http.get(*app, "/nouns/{id}/edit", edit_noun_page);
    Http.post(*app, "/nouns/{id}/edit", update_noun);
    Http.post(*app, "/nouns/{id}/delete", delete_noun);
    Http.get(*app, "/quiz", quiz_page);
    Http.post(*app, "/quiz/extend", extend_review);
    Http.get(*app, "/quiz/reveal/{id}", reveal_card);
    Http.post(*app, "/quiz/rate/{id}", rate_card);

    defer Http.free_app(*app);
    if !Http.serve(*app) {
        startup_error("The web server could not start. If port 8080 is occupied, stop the other app or set LISTEN_ADDRESS=127.0.0.1:8081.");
        exit(1);
    }
}
