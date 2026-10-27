#scope_module

Basic :: #import "Basic";
Http :: #import "Extensions/Http";
Json :: #import "Extensions/Json";
String :: #import "String";

using Basic;

write_event_start :: (builder: *String_Builder, event_name: string) {
    append(builder, "event: ");
    append(builder, event_name);
    append(builder, "\n");
}

write_data_lines :: (builder: *String_Builder, field: string, value: string) {
    start := 0;

    while start <= value.count {
        remaining := String.slice(value, start, value.count - start);
        newline := String.find_index_from_left(remaining, #char "\n");
        line_count := ifx newline < 0 then remaining.count else newline;
        line := String.slice(remaining, 0, line_count);

        if line.count > 0 && line[line.count - 1] == #char "\r" line.count -= 1;

        append(builder, "data: ");
        append(builder, field);
        append(builder, " ");
        append(builder, line);
        append(builder, "\n");

        if newline < 0 break;
        start += newline + 1;
    }
}

write_signal_options :: (builder: *String_Builder, only_if_missing: bool) {
    if only_if_missing append(builder, "data: onlyIfMissing true\n");
}

#scope_export

// Builds a buffered Datastar SSE response. Jacket's current Http.Response API writes a
// completed response body; it does not flush events incrementally while the handler is running.
SSE_Builder :: struct {
    body: String_Builder;
    event_count: int;
}

new_sse :: () -> SSE_Builder {
    return .{};
}

// Adds an element patch. Newlines in the markup are encoded as repeated `data: elements` lines.
patch_elements :: (sse: *SSE_Builder, html: string) {
    write_event_start(*sse.body, "datastar-patch-elements");
    write_data_lines(*sse.body, "elements", html);
    append(*sse.body, "\n");
    sse.event_count += 1;
}

// Adds a signal patch from a Datastar-compatible object expression, such as `{count: 2}`.
patch_signals :: (sse: *SSE_Builder, signals_expression: string, only_if_missing := false) {
    write_event_start(*sse.body, "datastar-patch-signals");
    write_signal_options(*sse.body, only_if_missing);
    write_data_lines(*sse.body, "signals", signals_expression);
    append(*sse.body, "\n");
    sse.event_count += 1;
}

// Adds a signal patch from a Jai value, serialized as compact JSON.
patch_signals_value :: (sse: *SSE_Builder, signals: $T, only_if_missing := false) {
    write_event_start(*sse.body, "datastar-patch-signals");
    write_signal_options(*sse.body, only_if_missing);
    append(*sse.body, "data: signals ");
    Json.write_json(*sse.body, signals);
    append(*sse.body, "\n\n");
    sse.event_count += 1;
}

// Converts all added events into one text/event-stream response.
sse_response :: (sse: *SSE_Builder) -> Http.Response {
    body := builder_to_string(*sse.body,, temp);
    response := Http.bytes_response(body, "text/event-stream; charset=utf-8");
    Http.add_header(*response, "Cache-Control", "no-cache");
    Http.add_header(*response, "X-Accel-Buffering", "no");

    return response;
}

// Reads and decodes signals sent by a Datastar backend request. GET uses the `datastar` query
// parameter; other methods use the request body. Free decoded values with Json.free_json when
// they contain allocated strings, arrays, pointers or nested values.
read_signals :: (request: *Http.Request, $T: Type) -> T, Http.Http_Error {
    input: string;

    if request.method == .GET {
        query_signals, found := Http.query_param(request, "datastar");
        if !found return .{}, Http.bad_request("Datastar GET request is missing the `datastar` query parameter");
        input = query_signals;
    } else {
        input = Http.body_text(request);
    }

    value, parse_error := Json.from_json(T, input, request.app.json_options);
    if parse_error.kind != .NONE {
        detail := Json.error_text(parse_error);
        http_error := Http.bad_request("Invalid Datastar signals: %", detail);
        Json.free_json(*parse_error);

        return .{}, http_error;
    }

    Json.free_json(*parse_error);

    return value, .{};
}
