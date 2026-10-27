// Runtime-only local development setup. Checking/building never calls these helpers.
Dev_Process :: #import "Process";
Dev_Files :: #import "File_Utilities";
Dev_System :: #import "System";

local_database_mode: bool;

startup_error :: (message: string) {
    print("Startup: %\n", message, to_standard_error = true);
}

dev_command :: (description: string, args: ..string) -> bool {
    result, output, errors, timed_out := Dev_Process.run_command(..args,
        capture_and_return_output = true, timeout_ms = 30000);
    defer free(output);
    defer free(errors);
    if !timed_out && result.type == .EXITED && result.exit_code == 0 return true;
    startup_error(tprint("% failed%.\n%%", description, ifx timed_out then " (timed out)" else "", output, errors));
    return false;
}

dev_brew_prefix :: (formula := "") -> string, bool {
    args: [..] string;
    defer array_free(args);
    array_add(*args, "brew");
    array_add(*args, "--prefix");
    if formula.count array_add(*args, formula);
    result, output, errors, timed_out := Dev_Process.run_command(..args,
        capture_and_return_output = true, timeout_ms = 5000);
    defer free(output);
    defer free(errors);
    if timed_out || result.type != .EXITED || result.exit_code != 0 {
        startup_error("Cannot locate PostgreSQL 17. Run `brew install postgresql@17`, then `jacket run` again. Alternatively set DATABASE_URL to an existing database.");
        return "", false;
    }
    return copy_string(String.trim(output)), true;
}

// Quote libpq connection-string values without going through a shell.
dev_conninfo_value :: (value: string) -> string {
    output: String_Builder;
    defer free_buffers(*output);
    append(*output, "'");
    for value {
        if it == #char "'" || it == #char "\\" append(*output, "\\");
        append(*output, it);
    }
    append(*output, "'");
    return builder_to_string(*output,, temp);
}

dev_connect :: (connection_string: string) -> *Postgres.PGconn, bool {
    connection := Postgres.PQconnectdb(temp_c_string(connection_string));
    connected := connection != null && Postgres.PQstatus(connection) == .CONNECTION_OK;
    return connection, connected;
}

dev_apply_schema :: (connection: *Postgres.PGconn) -> bool {
    schema, read_ok := File.read_entire_file("migrations/001_initial.sql");
    if !read_ok {
        startup_error("Cannot read migrations/001_initial.sql. Run `jacket run` from the project root.");
        return false;
    }
    defer free(schema);
    query := tprint("BEGIN;\nSET LOCAL client_min_messages=warning;\n%\nCOMMIT;", schema);
    result := Postgres.PQexec(connection, temp_c_string(query));
    if result == null {
        startup_error("Could not apply the local database schema.");
        return false;
    }
    defer Postgres.PQclear(result);
    if Postgres.PQresultStatus(result) != .PGRES_COMMAND_OK {
        startup_error(tprint("Could not apply the local database schema: %", to_string(Postgres.PQresultErrorMessage(result))));
        rollback := Postgres.PQexec(connection, "ROLLBACK;");
        if rollback Postgres.PQclear(rollback);
        return false;
    }
    return true;
}

dev_prepare_database :: (port: s32) -> bool {
    username, username_ok := Dev_System.get_username();
    if !username_ok {
        startup_error("Cannot determine the local PostgreSQL administrator. Set DATABASE_URL to an existing database.");
        return false;
    }
    admin_url := tprint("host=/tmp port=% dbname=postgres user=% connect_timeout=3", port, dev_conninfo_value(username));
    admin, connected := dev_connect(admin_url);
    defer Postgres.disconnect(admin);
    if !connected {
        startup_error("PostgreSQL is listening, but the app cannot connect and the local administrator is unavailable. Existing credentials were preserved. Set DATABASE_URL to the correct database connection URL.");
        return false;
    }

    roles, roles_ok := Postgres.execute(admin, Id_Row, "SELECT 1::bigint AS id FROM pg_roles WHERE rolname='arabic'");
    defer free(roles.data);
    if !roles_ok return false;
    if roles.count == 0 {
        created, _ := Postgres.execute(admin, "CREATE ROLE arabic LOGIN PASSWORD 'arabic'");
        if !created return false;
    }
    databases, databases_ok := Postgres.execute(admin, Id_Row, "SELECT 1::bigint AS id FROM pg_database WHERE datname='arabic'");
    defer free(databases.data);
    if !databases_ok return false;
    if databases.count == 0 {
        created, _ := Postgres.execute(admin, "CREATE DATABASE arabic OWNER arabic ENCODING 'UTF8' TEMPLATE template0");
        if !created return false;
    }
    return true;
}

start_local_database :: () -> *Postgres.PGconn, bool {
    #if OS != .MACOS {
        startup_error("Automatic local database setup requires macOS and Homebrew. Set DATABASE_URL to use an existing PostgreSQL database.");
        return null, false;
    }
    port: s32 = 54329;
    port_setting := environment_value("DEV_PGPORT");
    if port_setting.count {
        parsed, valid, tail := to_integer(port_setting);
        if !valid || tail.count || parsed < 1 || parsed > 65535 {
            startup_error("DEV_PGPORT must be a port number from 1 to 65535.");
            return null, false;
        }
        port = cast(s32) parsed;
    }
    connection_string := tprint("postgres://arabic:arabic@127.0.0.1:%/arabic?connect_timeout=3", port);
    database, connected := dev_connect(connection_string);
    if connected {
        if dev_apply_schema(database) {
            print("Local PostgreSQL ready on 127.0.0.1:% (existing data preserved).\n", port);
            return database, true;
        }
        Postgres.disconnect(database);
        return null, false;
    }
    Postgres.disconnect(database);

    prefix, prefix_ok := dev_brew_prefix("postgresql@17");
    if !prefix_ok return null, false;
    defer free(prefix);
    bin := tprint("%/bin", prefix);
    if !Dev_Files.file_exists(tprint("%/pg_ctl", bin)) || !Dev_Files.file_exists(tprint("%/initdb", bin)) {
        startup_error("PostgreSQL 17 tools are missing. Run `brew install postgresql@17`, then `jacket run` again.");
        return null, false;
    }
    // PQping distinguishes an existing PostgreSQL server from an absent listener even if the
    // app role/database is missing. Never replace a running server or reset its credentials.
    ping := Postgres.PQping(temp_c_string(connection_string));
    if ping == .PQPING_NO_RESPONSE {
        data_directory := environment_value("DEV_PGDATA");
        if data_directory.count == 0 {
            brew_root, root_ok := dev_brew_prefix();
            if !root_ok return null, false;
            defer free(brew_root);
            data_directory = tprint("%/var/postgresql@17", brew_root);
        }
        if !Dev_Files.file_exists(tprint("%/PG_VERSION", data_directory)) {
            print("Initializing local PostgreSQL 17 in %...\n", data_directory);
            if !dev_command("PostgreSQL initialization", tprint("%/initdb", bin), "-D", data_directory,
                "--encoding=UTF8", "--locale=C", "--auth-local=trust", "--auth-host=scram-sha-256") return null, false;
        } else {
            version, read_ok := File.read_entire_file(tprint("%/PG_VERSION", data_directory));
            if !read_ok return null, false;
            defer free(version);
            if String.trim(version) != "17" {
                startup_error("The existing PostgreSQL data directory is not version 17. Set DATABASE_URL to that server; its data was left intact.");
                return null, false;
            }
        }
        print("Starting local PostgreSQL on 127.0.0.1:%...\n", port);
        if !dev_command("PostgreSQL startup (check the data directory's server.log for port conflicts)",
            tprint("%/pg_ctl", bin), "-D", data_directory, "-l", tprint("%/server.log", data_directory),
            "-o", tprint("-p % -h 127.0.0.1", port), "-w", "-t", "20", "start") return null, false;
    } else if ping != .PQPING_OK {
        startup_error(tprint("PostgreSQL on port % is not accepting connections. Wait for it to finish starting or set DATABASE_URL; no service was stopped.", port));
        return null, false;
    }

    if !dev_prepare_database(port) {
        startup_error("Could not prepare the local app database. Check the database permissions or set DATABASE_URL; existing data and passwords were preserved.");
        return null, false;
    }
    database, connected = dev_connect(connection_string);
    if !connected {
        startup_error("Cannot sign in to the local arabic database. Existing credentials were preserved. Set DATABASE_URL to the correct connection URL.");
        Postgres.disconnect(database);
        return null, false;
    }
    if !dev_apply_schema(database) {
        Postgres.disconnect(database);
        return null, false;
    }
    print("Local PostgreSQL ready on 127.0.0.1:%. Data persists between runs.\n", port);
    return database, true;
}
