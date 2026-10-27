Profile_Stats :: struct {
    timezone: string;
    total_reviews: s64;
    today_reviews: s64;
    successful_reviews: s64;
    xp: s64;
    current_streak: s64;
    best_streak: s64;
}

Activity_Day :: struct {
    day: string;
    label: string;
    reviews: s64;
}

Timezone_Form :: struct {
    timezone: string;
}

XP_Row :: struct {
    xp: s64;
}

// Sum of the first L-1 level costs: 100, 150, 200, ... .
level_threshold :: (level: s64) -> s64 {
    return 25 * (level - 1) * (level + 2);
}

practice_level :: (xp: s64) -> s64 {
    level: s64 = 1;
    while xp >= level_threshold(level + 1) level += 1;
    return level;
}

streak_label :: (days: s64) -> string {
    return tprint("% %", days, ifx days == 1 then "day" else "days");
}

profile_stats_sql :: #string SQL
WITH learner AS (
    SELECT timezone, (now() AT TIME ZONE timezone)::date AS today FROM users WHERE id=$1
), events AS (
    SELECT r.*, (r.reviewed_at AT TIME ZONE l.timezone)::date AS day
    FROM review_events r CROSS JOIN learner l WHERE r.user_id=$1
), days AS (
    SELECT DISTINCT day FROM events, learner WHERE day<=today
), islands AS (
    SELECT day, day - (row_number() OVER (ORDER BY day))::integer AS island FROM days
), streaks AS (
    SELECT count(*)::bigint AS length, max(day) AS last_day FROM islands GROUP BY island
)
SELECT l.timezone,
    (SELECT count(*) FROM events)::bigint AS total_reviews,
    (SELECT count(*) FROM events WHERE day=l.today)::bigint AS today_reviews,
    (SELECT count(*) FROM events WHERE rating>0)::bigint AS successful_reviews,
    COALESCE((SELECT sum(xp) FROM events),0)::bigint AS xp,
    COALESCE((SELECT max(length) FROM streaks WHERE last_day>=l.today-1),0)::bigint AS current_streak,
    COALESCE((SELECT max(length) FROM streaks),0)::bigint AS best_streak
FROM learner l
SQL

activity_sql :: #string SQL
WITH learner AS (
    SELECT timezone, (now() AT TIME ZONE timezone)::date AS today FROM users WHERE id=$1
), days AS (
    SELECT l.timezone, l.today-offset_day AS day FROM learner l CROSS JOIN generate_series(0,13) offset_day
)
SELECT d.day::text AS day, to_char(d.day,'Mon DD') AS label, count(r.id)::bigint AS reviews
FROM days d LEFT JOIN review_events r ON r.user_id=$1
    AND r.reviewed_at >= (d.day::timestamp AT TIME ZONE d.timezone)
    AND r.reviewed_at < ((d.day+1)::timestamp AT TIME ZONE d.timezone)
GROUP BY d.day ORDER BY d.day
SQL

review_progress_markup :: (user_id: s64, awarded := false) -> string {
    rows, ok := Postgres.execute(database_connection, XP_Row, sql("SELECT COALESCE(sum(xp),0)::bigint AS xp FROM review_events WHERE user_id=$1"), user_id);
    defer free_db_rows(*rows);
    if !ok || rows.count != 1 return "<p id=\"review-progress\" role=\"status\">Review progress is temporarily unavailable.</p>";
    xp := rows[0].xp;
    level := practice_level(xp);
    leveled_up := awarded && practice_level(max(cast(s64) 0, xp - 10)) < level;
    return tprint("<p id=\"review-progress\" role=\"status\" aria-live=\"polite\">%Level % · % XP · % XP to next level% · <a href=\"/profile\">Profile</a></p>",
        ifx awarded then "+10 XP · " else "", level, xp, level_threshold(level + 1) - xp, ifx leveled_up then " · Level up!" else "");
}

profile_page :: (request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    stats, ok := Postgres.execute(database_connection, Profile_Stats, profile_stats_sql, user.id);
    defer free_db_rows(*stats);
    activity, activity_ok := Postgres.execute(database_connection, Activity_Day, activity_sql, user.id);
    defer free_db_rows(*activity);
    zones, zones_ok := Postgres.execute(database_connection, Text_Row, "SELECT name AS value FROM pg_timezone_names ORDER BY name");
    defer free_db_rows(*zones);
    if !ok || stats.count != 1 || !activity_ok || !zones_ok return Http.text("Could not load your profile. Try again.", 500);
    stat := stats[0];
    level := practice_level(stat.xp);
    earned := stat.xp - level_threshold(level);
    cost := level_threshold(level + 1) - level_threshold(level);
    recall := ifx stat.total_reviews then tprint("%%", (100 * stat.successful_reviews + stat.total_reviews / 2) / stat.total_reviews, "%") else "—";
    b: String_Builder;
    defer free_buffers(*b);
    append(*b, tprint("<section class=\"topline\"><div><h1>Profile</h1><p class=\"muted\">%</p></div><a class=\"button\" href=\"/quiz\">Review</a></section>", html_escape(user.username)));
    append(*b, tprint("<section class=\"panel level-panel\"><h2 id=\"practice-level\">Level %</h2><p><strong id=\"total-xp\">% XP</strong></p><label for=\"level-progress\">% / % XP toward level %</label><progress id=\"level-progress\" value=\"%\" max=\"%\">% / % XP</progress></section>", level, stat.xp, earned, cost, level+1, earned, cost, earned, cost));
    append(*b, tprint("<section class=\"profile-stats\" aria-label=\"Practice statistics\"><div class=\"panel\"><h2>Total reviews</h2><p id=\"total-reviews\">%</p></div><div class=\"panel\"><h2>Today’s reviews</h2><p id=\"today-reviews\">%</p></div><div class=\"panel\"><h2>Recall (self-rated)</h2><p id=\"recall-rate\">%</p></div><div class=\"panel\"><h2>Current streak</h2><p id=\"current-streak\">%</p></div><div class=\"panel\"><h2>Best streak</h2><p id=\"best-streak\">%</p></div></section>", stat.total_reviews, stat.today_reviews, recall, streak_label(stat.current_streak), streak_label(stat.best_streak)));
    append(*b, tprint("<section class=\"panel\"><h2>Last 14 days</h2><p class=\"muted\"><span id=\"statistics-timezone\">%</span></p><ol class=\"activity-chart\" aria-label=\"Daily review activity\">", html_escape(stat.timezone)));
    peak: s64 = 1;
    for activity peak = max(peak, it.reviews);
    for activity {
        height := 100 * it.reviews / peak;
        append(*b, tprint("<li data-day=\"%\" data-reviews=\"%\"><span class=\"activity-count\">%</span><div class=\"activity-track\" aria-hidden=\"true\"><span style=\"height:%%\"></span></div><time datetime=\"%\">%</time></li>", it.day, it.reviews, it.reviews, height, "%", it.day, html_escape(it.label)));
    }
    append(*b, "</ol></section>");
    append(*b, "<section class=\"panel\"><h2>Timezone</h2><form action=\"/profile/timezone\" method=\"post\"><label class=\"sr-only\" for=\"timezone\">Timezone</label><select id=\"timezone\" name=\"timezone\">");
    for zones append(*b, tprint("<option value=\"%\"%>%</option>", html_escape(it.value), ifx it.value == stat.timezone then " selected" else "", html_escape(it.value)));
    append(*b, "</select><div class=\"actions\"><button type=\"button\" class=\"secondary\" data-on:click=\"document.getElementById('timezone').value = Intl.DateTimeFormat().resolvedOptions().timeZone\">Use browser timezone</button><button type=\"submit\">Save timezone</button></div></form></section>");
    return Http.html(layout("Profile", builder_to_string(*b,, temp), user));
}

save_profile_timezone :: (form: Http.Form(Timezone_Form), request: *Http.Request) -> Http.Response {
    user, signed_in := current_user(request);
    if !signed_in return Http.redirect("/login");
    zones, ok := Postgres.execute(database_connection, Text_Row, sql("SELECT name AS value FROM pg_timezone_names WHERE name=$1"), form.timezone);
    defer free_db_rows(*zones);
    if !ok return Http.text("Could not validate timezone. Try again.", 500);
    if zones.count != 1 return Http.text("Choose a supported timezone.", 400);
    if !db_exec(sql("UPDATE users SET timezone=$1 WHERE id=$2"), form.timezone, user.id) return Http.text("Could not save timezone. Try again.", 500);
    return Http.redirect("/profile", 303);
}
