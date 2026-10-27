// Query results from jai-postgres own their arrays and copied strings. This helper is only
// for database rows composed of scalar fields, strings, and arrays allocated by that client.
free_db_rows :: (rows: *$T) {
    Json.free_json(rows);
}

// Mark parameterized SQL as data rather than a printf-style variadic format. This also avoids
// Jacket 0.25's format-string warning at literal SQL call sites containing $1, $2, ... .
sql :: inline (text: string) -> string {
    return text;
}

temp_json :: (value: $T, pretty := false) -> string {
    b: String_Builder;
    defer free_buffers(*b);
    Json.write_json(*b, value, pretty);
    return builder_to_string(*b,, temp);
}

sql_command :: (connection: *Postgres.PGconn, query: string) -> bool {
    result := Postgres.PQexec(connection, temp_c_string(query));
    if !result return false;
    defer Postgres.PQclear(result);
    status := Postgres.PQresultStatus(result);
    if status == .PGRES_COMMAND_OK || status == .PGRES_TUPLES_OK return true;
    print("Database: %\n", to_string(Postgres.PQresultErrorMessage(result)), to_standard_error = true);
    return false;
}

db_exec :: (query: string, args: ..Any) -> bool {
    success, _ := Postgres.execute(database_connection, query, ..args);
    return success;
}

db_begin :: () -> bool {
    return db_exec(sql("BEGIN ISOLATION LEVEL SERIALIZABLE"));
}

db_commit :: () -> bool {
    return db_exec(sql("COMMIT"));
}

db_rollback :: () {
    db_exec(sql("ROLLBACK"));
}

Text_Row :: struct {
    value: string;
}

apply_migrations :: (connection: *Postgres.PGconn) -> bool {
    // Serialize application startup migrations, including legacy databases without a ledger.
    if !sql_command(connection, "SELECT pg_advisory_lock(762184392)") return false;
    defer sql_command(connection, "SELECT pg_advisory_unlock(762184392)");
    if !sql_command(connection, "SET client_min_messages=warning; CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())") return false;
    files: [] string = .["migrations/001_initial.sql", "migrations/002_decks.sql", "migrations/003_noun_gender.sql", "migrations/004_profiles.sql", "migrations/005_review_extensions.sql"];
    for filename, index: files {
        rows, read_ok := Postgres.execute(connection, Id_Row, "SELECT version::bigint AS id FROM schema_migrations WHERE version=$1", cast(s32) (index + 1));
        defer free_db_rows(*rows);
        if !read_ok return false;
        if rows.count continue;
        source, found := File.read_entire_file(filename);
        if !found {
            startup_error(tprint("Cannot read %. Run from the project root.", filename));
            return false;
        }
        defer free(source);
        print("Applying %...\n", filename);
        if !sql_command(connection, source) {
            sql_command(connection, "ROLLBACK");
            return false;
        }
    }
    return true;
}
