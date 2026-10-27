# Local patches

The vendored upstream revision is listed in `UPSTREAM-COMMIT.txt`.

- `module.jai`: `connect` uses libpq's synchronous `PQconnectdb`. Upstream used `PQconnectStart` and repeatedly polled `PQconnectPoll` without waiting for socket readiness, which could spin indefinitely. The synchronous choice matches this library's synchronous query API.
