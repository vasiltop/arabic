"""Integration checks using a disposable local PostgreSQL 17 cluster.

Run from the repository root: python3 tests/decks.py
Requires the same Homebrew dependencies as `jacket run`; never uses the normal app database.
"""
import base64
import copy
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
PG = Path(subprocess.check_output(["brew", "--prefix", "postgresql@17"], text=True).strip()) / "bin"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


DATA = dict(gender="masculine", singular="كِتَابٌ", plural="كُتُبٌ", meaning='book "quoted" <script>not code</script>',
            singular_sentence="هَذَا كِتَابٌ جَدِيدٌ.", singular_translation='This is a "new" book.',
            plural_sentence="هَذِهِ كُتُبٌ جَدِيدَةٌ.", plural_translation="These are new books — yes!")


class Client:
    def __init__(self, suite):
        self.suite, self.cookie = suite, None
        self.username = "deckqa_" + secrets.token_hex(5)
        code, _, _ = self.request("/register", {"username": self.username, "password": "DeckCheckPass2026"})
        assert code == 303, code
        self.user_id = int(suite.sql(f"SELECT id FROM users WHERE username={literal(self.username)}"))
        self.default = int(suite.sql(f"SELECT id FROM decks WHERE user_id={self.user_id} AND is_default"))

    def request(self, path, fields=None, raw=None):
        headers, body = {}, raw
        if self.cookie:
            headers["Cookie"] = self.cookie
        if fields is not None:
            body = urllib.parse.urlencode(fields, doseq=True)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif raw is not None:
            body = json.dumps(raw, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        conn = http.client.HTTPConnection("127.0.0.1", self.suite.web_port, timeout=20)
        conn.request("POST" if body is not None else "GET", path, body, headers)
        response = conn.getresponse()
        code, result_headers, text = response.status, dict(response.getheaders()), response.read().decode()
        conn.close()
        if "Set-Cookie" in result_headers:
            self.cookie = result_headers["Set-Cookie"].split(";")[0]
        return code, result_headers, text

    def deck(self, name):
        assert self.request("/decks", {"name": name})[0] == 303
        return int(self.suite.sql(f"SELECT id FROM decks WHERE user_id={self.user_id} AND name={literal(name)}"))

    def noun(self, deck=None, data=None):
        assert self.request("/nouns", {**(data or DATA), "deck_id": deck or self.default})[0] == 303
        return int(self.suite.sql(f"SELECT max(id) FROM entries WHERE user_id={self.user_id}"))

    def export(self, deck):
        code, headers, text = self.request(f"/decks/{deck}/export")
        assert code == 200 and "attachment" in headers["Content-Disposition"]
        return json.loads(text)

    def preview(self, document, expected_error=None):
        text = document if isinstance(document, bytes) else json.dumps(document, ensure_ascii=False).encode()
        code, _, response = self.request("/decks/import/preview", raw={"files": [{"name": "deck.json", "mime": "application/json", "contents": base64.b64encode(text).decode()}]})
        assert code == 200, (code, response[:500])
        if expected_error:
            assert expected_error in response, response[:1000]
            return None
        match = re.search(r'name="token" value="([a-f0-9]{64})"', response)
        assert match, response[:2000]
        return match.group(1), response

    def confirm(self, token, name="Imported", updates=(), moves=()):
        return self.request("/decks/import/confirm", {"token": token, "name": name, "updates": updates, "moves": moves})


class DeckIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="learn-arabic-decks-"))
        cls.pg_port, cls.web_port = free_port(), free_port()
        cls.env = os.environ.copy()
        for key in ("DATABASE_URL", "LIBRARY_PATH", "COOKIE_SECURE"):
            cls.env.pop(key, None)
        cls.env.update(DEV_PGDATA=str(cls.work / "postgres data"), DEV_PGPORT=str(cls.pg_port), LISTEN_ADDRESS=f"127.0.0.1:{cls.web_port}")
        cls.proc, cls.log = None, None
        try:
            subprocess.run(["jacket", "check"], cwd=ROOT, env=cls.env, check=True)
            subprocess.run(["jacket", "build"], cwd=ROOT, env=cls.env, check=True)
            cls.start()
            assert cls.sql("SELECT string_agg(version::text,',' ORDER BY version) FROM schema_migrations") == "1,2,3,5"
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def start(cls):
        cls.log = cls.work / f"app-{time.time_ns()}.log"
        with cls.log.open("w") as output:
            cls.proc = subprocess.Popen([str(ROOT / "build/arabic")], cwd=ROOT, env=cls.env, stdout=output, stderr=subprocess.STDOUT)
        for _ in range(200):
            if cls.proc.poll() is not None:
                raise AssertionError(cls.log.read_text())
            try:
                conn = http.client.HTTPConnection("127.0.0.1", cls.web_port, timeout=.3)
                conn.request("GET", "/")
                response = conn.getresponse()
                response.read()
                conn.close()
                if response.status == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(.1)
        raise AssertionError(cls.log.read_text())

    @classmethod
    def stop(cls):
        if cls.proc and cls.proc.poll() is None:
            cls.proc.send_signal(signal.SIGINT)
            cls.proc.wait(timeout=10)

    @classmethod
    def sql(cls, query, admin=False, database=None):
        args = [str(PG / "psql"), "-h", "/tmp" if admin else "127.0.0.1", "-p", str(cls.pg_port), "-d", database or ("postgres" if admin else "arabic"), "-v", "ON_ERROR_STOP=1", "-Atc", query]
        if not admin:
            args += ["-U", "arabic"]
        result = subprocess.run(args, env={**cls.env, "PGPASSWORD": "arabic"}, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    @classmethod
    def tearDownClass(cls):
        cls.stop()
        data = cls.work / "postgres data"
        if (data / "postmaster.pid").exists():
            subprocess.run([str(PG / "pg_ctl"), "-D", str(data), "-m", "fast", "-w", "stop"], capture_output=True)
        if not (data / "postmaster.pid").exists():
            shutil.rmtree(cls.work)

    def schedules(self, entry_id):
        return self.sql(f"SELECT row_to_json(c)::text FROM review_cards c WHERE entry_id={entry_id} ORDER BY id")

    def test_01_decks_and_ownership(self):
        a, b = Client(self), Client(self)
        food = a.deck("Food")
        entry = a.noun(food)
        saved = self.schedules(entry)
        self.assertIn(f'value="{food}" selected', a.request(f"/nouns/new?deck={food}")[2])
        self.assertEqual(a.request(f"/decks/{food}/edit", {"name": "طعام"})[0], 303)
        self.assertIn("طعام", a.request("/decks")[2])
        self.assertEqual(a.request(f"/nouns/{entry}/edit", {**DATA, "deck_id": a.default})[0], 303)
        self.assertEqual(self.schedules(entry), saved)
        self.assertEqual(a.request(f"/nouns/{entry}/edit", {**DATA, "deck_id": food})[0], 303)
        for path, form in [(f"/decks/{food}/edit", None), (f"/decks/{food}/export", None), (f"/decks/{food}/enabled", {"enabled": 0}), (f"/decks/{food}/delete", {}), (f"/nouns?deck={food}", None), (f"/nouns/{entry}/edit", None)]:
            self.assertEqual(b.request(path, form)[0], 404, path)
        self.assertEqual(b.request("/nouns", {**DATA, "deck_id": food})[0], 404)
        self.assertEqual(a.request(f"/decks/{a.default}/delete", {})[0], 409)
        self.assertEqual(a.request(f"/decks/{food}/delete", {})[0], 303)
        self.assertEqual(int(self.sql(f"SELECT deck_id FROM entries WHERE id={entry}")), a.default)
        self.assertEqual(self.schedules(entry), saved)

    def test_02_activation_and_stale_quiz(self):
        a = Client(self)
        entry = a.noun()
        paused = a.deck("Paused")
        paused_entry = a.noun(paused)
        a.request(f"/decks/{paused}/enabled", {"enabled": 0})
        paused_schedule = self.schedules(paused_entry)
        prompt = a.request("/quiz")[2]
        card = re.search(r"/quiz/reveal/(\d+)", prompt).group(1)
        saved = self.schedules(entry)
        self.assertEqual(a.request(f"/decks/{a.default}/enabled", {"enabled": 0})[0], 303)
        self.assertIn("No active decks", a.request("/quiz")[2])
        self.assertIn("No active decks", a.request(f"/quiz/reveal/{card}")[2])
        self.assertIn("No active decks", a.request(f"/quiz/rate/{card}", raw={"rating": 2})[2])
        self.assertEqual(self.schedules(entry), saved)
        a.request(f"/decks/{a.default}/enabled", {"enabled": 1})
        self.assertIn("/quiz/reveal/", a.request("/quiz")[2])
        for _ in range(2):
            card = re.search(r"/quiz/reveal/(\d+)", a.request("/quiz")[2]).group(1)
            self.assertEqual(a.request(f"/quiz/rate/{card}", raw={"rating": 2})[0], 200)
        self.assertIn("No reviews due", a.request("/quiz")[2])
        a.request(f"/decks/{paused}/enabled", {"enabled": 1})
        self.assertIn("/quiz/reveal/", a.request("/quiz")[2])
        self.assertEqual(self.schedules(paused_entry), paused_schedule)

    def shared_fixture(self):
        a, b = Client(self), Client(self)
        source = a.deck("Shared")
        entry = a.noun(source)
        self.sql(f"UPDATE review_cards SET interval_days=20,repetitions=4,ease_factor=2.1,due_at=now()+interval '20 days' WHERE entry_id={entry}")
        document = a.export(source)
        token, preview = b.preview(document)
        self.assertIn("1 new", preview)
        self.assertNotIn("<script>not code</script>", preview)
        self.assertEqual(b.confirm(token, "Shared")[0], 303)
        target = int(self.sql(f"SELECT id FROM decks WHERE user_id={b.user_id} AND uid={literal(document['deck']['id'])}::uuid"))
        imported = int(self.sql(f"SELECT id FROM entries WHERE user_id={b.user_id} AND uid={literal(document['entries'][0]['id'])}::uuid"))
        return a, b, source, target, imported, document

    def test_03_roundtrip_and_repeat(self):
        a, b, source, target, entry, document = self.shared_fixture()
        self.assertEqual(document["entries"][0]["data"], DATA)
        self.assertEqual(set(document), {"format", "version", "deck", "entries"})
        self.assertEqual(set(document["entries"][0]), {"id", "type", "data"})
        self.assertEqual(self.sql(f"SELECT enabled FROM decks WHERE id={target}"), "f")
        self.assertEqual(self.sql(f"SELECT string_agg(interval_days||':'||repetitions,',' ORDER BY id) FROM review_cards WHERE entry_id={entry}"), "0:0,0:0")
        self.assertIn("No reviews due", b.request("/quiz")[2])
        b.request(f"/decks/{target}/edit", {"name": "My shared deck"})
        b.request(f"/decks/{target}/enabled", {"enabled": 1})
        before = self.schedules(entry)
        token, preview = b.preview(document)
        self.assertIn("1 unchanged", preview)
        self.assertEqual(b.confirm(token)[0], 303)
        self.assertEqual(b.confirm(token)[0], 409)
        self.assertEqual(self.sql(f"SELECT count(*) FROM entries WHERE deck_id={target}"), "1")
        self.assertEqual(self.sql(f"SELECT name||':'||enabled::text FROM decks WHERE id={target}"), "My shared deck:true")
        self.assertEqual(self.schedules(entry), before)
        self.assertEqual(b.export(target)["entries"], document["entries"])
        self.assertEqual(b.request(f"/decks/{source}/export")[0], 404)

    def test_04_merge_move_stale_and_expiry(self):
        _, b, _, target, entry, document = self.shared_fixture()
        self.sql(f"UPDATE review_cards SET interval_days=6,repetitions=2 WHERE entry_id={entry}")
        before = self.schedules(entry)
        changed = copy.deepcopy(document)
        changed["entries"][0]["data"]["meaning"] = "updated meaning"
        changed["entries"].append({"id": str(uuid.uuid4()), "type": "noun", "data": {**DATA, "meaning": "another noun"}})
        token, preview = b.preview(changed)
        self.assertIn("1 changed", preview)
        self.assertNotIn('name="updates" checked', preview)
        self.assertEqual(b.confirm(token)[0], 303)
        self.assertEqual(self.sql(f"SELECT meaning FROM nouns WHERE id={entry}"), DATA["meaning"])
        token, _ = b.preview(changed)
        self.assertEqual(b.confirm(token, updates=[document["entries"][0]["id"]])[0], 303)
        self.assertEqual(self.sql(f"SELECT meaning FROM nouns WHERE id={entry}"), "updated meaning")
        self.assertEqual(self.schedules(entry), before)
        other = b.deck("Elsewhere")
        updated_data = changed["entries"][0]["data"]
        b.request(f"/nouns/{entry}/edit", {**updated_data, "deck_id": other})
        token, preview = b.preview(changed)
        self.assertIn("1 moves", preview)
        self.assertEqual(b.confirm(token)[0], 303)
        self.assertEqual(int(self.sql(f"SELECT deck_id FROM entries WHERE id={entry}")), other)
        token, _ = b.preview(changed)
        self.assertEqual(b.confirm(token, moves=[document["entries"][0]["id"]])[0], 303)
        self.assertEqual(int(self.sql(f"SELECT deck_id FROM entries WHERE id={entry}")), target)
        self.assertEqual(self.schedules(entry), before)
        token, _ = b.preview(changed)
        b.request(f"/nouns/{entry}/edit", {**updated_data, "meaning": "new local edit", "deck_id": target})
        self.assertEqual(b.confirm(token)[0], 409)
        self.assertIn("Refresh preview", b.request(f"/decks/import/{token}")[2])
        self.assertEqual(b.request(f"/decks/import/{token}/refresh", {})[0], 303)
        self.assertEqual(b.confirm(token)[0], 303)
        token, _ = b.preview(changed)
        self.sql(f"UPDATE deck_imports SET expires_at=now()-interval '1 second' WHERE token={literal(token)}")
        self.assertEqual(b.confirm(token)[0], 410)
        self.assertEqual(b.request(f"/decks/import/{token}")[0], 410)
        attacker = Client(self)
        self.assertEqual(attacker.confirm(token)[0], 404)
        self.assertEqual(attacker.request(f"/decks/import/{token}")[0], 404)
        token, _ = b.preview(changed)
        self.assertEqual(b.confirm(token, updates=[str(uuid.uuid4())])[0], 400)

    def test_05_validation_and_name_conflicts(self):
        a = Client(self)
        a.noun()
        document = a.export(a.default)
        b = Client(self)
        # The imported default deck is an ordinary, disabled deck with an editable unique name.
        token, preview = b.preview(document)
        self.assertIn("Default (imported", preview)
        self.assertEqual(b.confirm(token, "Default")[0], 409)
        self.assertEqual(b.confirm(token, "Separate default")[0], 303)
        for change, error in [(lambda d: d.update(version=99), "Unsupported deck format"),
                              (lambda d: d["entries"][0].update(type="verb"), "unsupported type"),
                              (lambda d: d["entries"].append(copy.deepcopy(d["entries"][0])), "duplicate entry IDs"),
                              (lambda d: d["entries"][0]["data"].update(singular=" "), "invalid noun fields"),
                              (lambda d: d["entries"][0].update(id="not-a-uuid"), "UUID")]:
            invalid = copy.deepcopy(document)
            change(invalid)
            b.preview(invalid, error)
        b.preview(b'{invalid', "Invalid deck file")
        b.preview(b'\xff', "valid UTF-8")
        b.preview(b'x' * (5 * 1024 * 1024 + 1), "5 MiB")
        # A declared oversized body is rejected before upload, so do not send 8 MiB after
        # the server has already closed the connection with its 413 response.
        conn = http.client.HTTPConnection("127.0.0.1", self.web_port, timeout=5)
        try:
            conn.putrequest("POST", "/decks/import/preview")
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Content-Length", str(8 * 1024 * 1024 + 1))
            conn.endheaders()
            response = conn.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        finally:
            conn.close()
        self.assertEqual(self.sql(f"SELECT count(*) FROM entries WHERE user_id={b.user_id}"), "1")

    def test_06_atomic_failure(self):
        a = Client(self)
        doc = {"format": "learn-arabic-deck", "version": 1, "deck": {"id": str(uuid.uuid4()), "name": "Rollback"}, "entries": [
            {"id": str(uuid.uuid4()), "type": "noun", "data": DATA},
            {"id": str(uuid.uuid4()), "type": "noun", "data": {**DATA, "singular": "FAIL_IMPORT_TEST"}}]}
        token, _ = a.preview(doc)
        self.sql("CREATE FUNCTION fail_test_import() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.singular='FAIL_IMPORT_TEST' THEN RAISE EXCEPTION 'intentional test failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_test_import BEFORE INSERT ON nouns FOR EACH ROW EXECUTE FUNCTION fail_test_import()")
        try:
            self.assertEqual(a.confirm(token, "Rollback")[0], 500)
            self.assertEqual(self.sql(f"SELECT count(*) FROM entries WHERE user_id={a.user_id}"), "0")
            self.assertEqual(self.sql(f"SELECT count(*) FROM decks WHERE user_id={a.user_id}"), "1")
            self.assertEqual(self.sql(f"SELECT consumed_at IS NULL FROM deck_imports WHERE token={literal(token)}"), "t")
        finally:
            self.sql("DROP TRIGGER fail_test_import ON nouns; DROP FUNCTION fail_test_import()")
        self.assertEqual(a.confirm(token, "Rollback")[0], 303)

    def test_07_explicit_external_migrations(self):
        self.sql("CREATE DATABASE explicit_migration_test OWNER arabic", admin=True)
        env = {**self.env, "DATABASE_URL": f"postgres://arabic:arabic@127.0.0.1:{self.pg_port}/explicit_migration_test"}
        for _ in range(2):
            result = subprocess.run([str(ROOT / "build/arabic"), "--migrate"], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.sql("SELECT count(*) FROM schema_migrations", database="explicit_migration_test"), "4")

    def test_08_gender_examples_and_legacy_transfer(self):
        a = Client(self)
        masculine = a.noun()
        feminine_data = dict(gender="feminine", singular="مَدْرَسَةٌ", plural="مَدَارِسُ", meaning="school",
                             singular_sentence="هَذِهِ مَدْرَسَةٌ كَبِيرَةٌ.", singular_translation="This is a big school.",
                             plural_sentence="هَذِهِ مَدَارِسُ كَبِيرَةٌ.", plural_translation="These are big schools.")
        feminine = a.noun(data=feminine_data)
        bank = a.request("/nouns")[2]
        self.assertEqual(bank.count("<h3>Singular</h3>"), 2)
        self.assertEqual(bank.count("<h3>Plural</h3>"), 2)
        for text in [DATA["singular_sentence"], DATA["plural_sentence"], feminine_data["singular_sentence"], feminine_data["plural_sentence"], feminine_data["plural_translation"]]:
            self.assertIn(text, bank)
        self.assertIn('This is a &quot;new&quot; book.', bank)
        self.assertNotIn("<script>not code</script>", bank)
        self.assertIn(f'/nouns/{feminine}/edit', bank)
        self.assertIn(f'/nouns/{masculine}/delete', bank)
        self.assertIn('name="gender" required', a.request('/nouns/new')[2])
        prompt = a.request('/quiz')[2]
        self.assertNotIn('Feminine', prompt)
        self.assertNotIn('Masculine', prompt)
        cards = self.sql(f"SELECT id FROM review_cards WHERE entry_id={feminine} ORDER BY id").splitlines()
        for card in cards:
            answer = a.request('/quiz/reveal/' + card)[2]
            self.assertIn('class="gender-badge">Feminine', answer)
        before = self.schedules(feminine)
        invalid = a.request(f'/nouns/{feminine}/edit', {**feminine_data, 'gender': '', 'deck_id': a.default})
        self.assertEqual(invalid[0], 400)
        self.assertIn('Choose masculine or feminine.', invalid[2])
        self.assertIn(feminine_data['singular_sentence'], invalid[2])
        self.assertEqual(self.schedules(feminine), before)
        exported = a.export(a.default)
        self.assertEqual(exported['version'], 2)
        self.assertEqual({e['data']['gender'] for e in exported['entries']}, {'masculine', 'feminine'})
        uid = next(e['id'] for e in exported['entries'] if e['data']['gender'] == 'feminine')
        changed = copy.deepcopy(exported)
        next(e for e in changed['entries'] if e['id'] == uid)['data']['gender'] = 'masculine'
        token, preview = a.preview(changed)
        self.assertIn('<th>Gender</th>', preview)
        self.assertEqual(a.confirm(token, updates=[uid])[0], 303)
        self.assertEqual(self.sql(f'SELECT gender FROM nouns WHERE id={feminine}'), 'masculine')
        self.assertEqual(self.schedules(feminine), before)
        legacy = copy.deepcopy(exported)
        legacy['version'] = 1
        for entry in legacy['entries']:
            del entry['data']['gender']
        b = Client(self)
        token, _ = b.preview(legacy)
        self.assertEqual(b.confirm(token, 'Legacy nouns')[0], 303)
        self.assertEqual(self.sql(f"SELECT count(*) FROM nouns n JOIN entries e ON e.id=n.id WHERE e.user_id={b.user_id} AND n.gender='unknown'"), '2')
        self.assertIn('Gender not set', b.request('/nouns')[2])
        # A content update from an older deck must not erase a known gender.
        legacy['entries'][0]['data']['meaning'] = 'legacy content update'
        token, preview = a.preview(legacy)
        self.assertNotIn('<th>Gender</th>', preview)
        self.assertEqual(a.confirm(token, updates=[legacy['entries'][0]['id']])[0], 303)
        self.assertEqual(self.sql(f"SELECT count(*) FROM nouns n JOIN entries e ON e.id=n.id WHERE e.user_id={a.user_id} AND n.gender='masculine'"), '2')
        # New exports of legacy content explicitly retain the unknown state and round-trip it.
        imported_deck = int(self.sql(f"SELECT id FROM decks WHERE user_id={b.user_id} AND NOT is_default"))
        unknown_export = b.export(imported_deck)
        c = Client(self)
        token, _ = c.preview(unknown_export)
        self.assertEqual(c.confirm(token)[0], 303)
        invalid = copy.deepcopy(exported)
        del invalid['entries'][0]['data']['gender']
        b.preview(invalid, 'needs a gender field')
        invalid = copy.deepcopy(exported)
        invalid['entries'][0]['data']['gender'] = 'neuter'
        b.preview(invalid, 'invalid noun fields')

    def test_09_large_deck_learning_limit(self):
        a = Client(self)
        document = {
            "format": "learn-arabic-deck", "version": 2,
            "deck": {"id": str(uuid.uuid4()), "name": "Large deck"},
            "entries": [{"id": str(uuid.uuid4()), "type": "noun", "data": DATA} for _ in range(250)],
        }
        token, _ = a.preview(document)
        self.assertEqual(a.confirm(token, "Large deck")[0], 303)
        deck = int(self.sql(f"SELECT id FROM decks WHERE user_id={a.user_id} AND NOT is_default"))
        cards = list(map(int, self.sql(f"SELECT c.id FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE e.deck_id={deck} ORDER BY c.id").splitlines()))
        self.assertEqual(len(cards), 500)
        self.assertIn("500 cards · 0 due", a.request("/decks")[2])
        self.assertEqual(a.request(f"/decks/{deck}/enabled", {"enabled": 1})[0], 303)
        self.assertIn("500 cards · 5 due", a.request("/decks")[2])
        before = self.sql(f"SELECT row_to_json(c)::text FROM review_cards c WHERE id={cards[5]}")
        for card in (cards[5], cards[-1]):
            self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{card}")[2])
            self.assertEqual(a.request(f"/quiz/rate/{card}", raw={"rating": 3})[0], 200)
        self.assertEqual(self.sql(f"SELECT row_to_json(c)::text FROM review_cards c WHERE id={cards[5]}"), before)
        stranger = Client(self)
        self.assertEqual(stranger.request(f"/quiz/reveal/{cards[0]}")[0], 404)
        self.assertEqual(stranger.request(f"/quiz/rate/{cards[0]}", raw={"rating": 2})[0], 404)

        # Rating each card once must not replace it with another unfamiliar card.
        seen = []
        for _ in range(5):
            prompt = a.request("/quiz")[2]
            card = int(re.search(r"/quiz/reveal/(\d+)", prompt).group(1))
            seen.append(card)
            self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{card}")[2])
            self.assertEqual(a.request(f"/quiz/rate/{card}", raw={"rating": 2})[0], 200)
        self.assertEqual(seen, cards[:5])
        for _ in range(3):
            self.assertIn("No reviews due", a.request("/quiz")[2])
        self.assertIn("500 cards · 0 due", a.request("/decks")[2])
        self.stop()
        self.start()
        self.assertIn("No reviews due", a.request("/quiz")[2])
        self.assertEqual(self.sql(f"SELECT count(*) FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE e.user_id={a.user_id} AND last_reviewed_at IS NOT NULL"), "5")

        # Advancing the scheduled reviews keeps the same five cards in learning.
        learning_ids = ','.join(map(str, cards[:5]))
        self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 second' WHERE id IN ({learning_ids})")
        self.assertIn("500 cards · 5 due", a.request("/decks")[2])
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[5]}")[2])
        card = cards[0]
        self.assertEqual(a.request(f"/quiz/rate/{card}", raw={"rating": 0})[0], 200)
        self.assertEqual(self.sql(f"SELECT repetitions FROM review_cards WHERE id={card}"), "0")
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[5]}")[2])
        self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 second' WHERE id={card}")
        a.request(f"/quiz/rate/{card}", raw={"rating": 2})
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[5]}")[2])
        self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 second' WHERE id={card}")
        a.request(f"/quiz/rate/{card}", raw={"rating": 2})
        self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[5]}")[2])
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[6]}")[2])
        self.assertEqual(self.sql(f"SELECT repetitions||':'||interval_days FROM review_cards WHERE id={card}"), "2:6")

        # Learned cards remain reviewable alongside the five learning slots.
        self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 second' WHERE id={card}")
        self.assertIn("500 cards · 6 due", a.request("/decks")[2])
        self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{card}")[2])
        # A lapse takes priority over an unseen card without resetting schedules.
        a.request(f"/quiz/rate/{card}", raw={"rating": 0})
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{cards[5]}")[2])
        self.assertIn("500 cards · 4 due", a.request("/decks")[2])

    def test_10_learning_limit_across_decks(self):
        a = Client(self)
        older = a.deck("Older")
        for _ in range(3):
            a.noun(older)
        a.request(f"/decks/{older}/enabled", {"enabled": 0})
        for _ in range(3):
            a.noun()
        cards = list(map(int, self.sql(f"SELECT c.id FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE e.user_id={a.user_id} ORDER BY c.id").splitlines()))
        started = cards[6]
        self.assertEqual(a.request(f"/quiz/rate/{started}", raw={"rating": 1})[0], 200)
        a.request(f"/decks/{older}/enabled", {"enabled": 1})
        # The in-progress card retains a slot even with older unseen cards enabled.
        self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 second' WHERE id={started}")
        self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{started}")[2])
        for card in cards[:4]:
            self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{card}")[2])
        for card in (cards[4], cards[7], cards[-1]):
            self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{card}")[2])
        self.assertIn(f"/quiz/reveal/{started}", a.request("/quiz")[2])
        # Disable/re-enable and noun moves preserve progress and recheck eligibility.
        saved = self.schedules(int(self.sql(f"SELECT entry_id FROM review_cards WHERE id={started}")))
        a.request(f"/decks/{a.default}/enabled", {"enabled": 0})
        self.assertNotIn('class="quiz-answer"', a.request(f"/quiz/reveal/{started}")[2])
        a.request(f"/decks/{a.default}/enabled", {"enabled": 1})
        self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{started}")[2])
        entry = int(self.sql(f"SELECT entry_id FROM review_cards WHERE id={started}"))
        self.assertEqual(a.request(f"/nouns/{entry}/edit", {**DATA, "deck_id": older})[0], 303)
        self.assertIn('class="quiz-answer"', a.request(f"/quiz/reveal/{started}")[2])
        self.assertEqual(self.sql(f"SELECT repetitions||':'||interval_days FROM review_cards WHERE id={started}"), "1:1")
        self.assertEqual(self.schedules(entry), saved)

    def extension_fields(self, client):
        page = client.request('/quiz')[2]
        self.assertIn('action="/quiz/extend"', page)
        return {name: re.search(r'name="' + name + r'" value="([^"]+)"', page).group(1)
                for name in ('card_limit', 'study_day')}

    def rate_batch(self, client, count):
        seen = []
        for _ in range(count):
            page = client.request('/quiz')[2]
            match = re.search(r'/quiz/reveal/(\d+)', page)
            self.assertIsNotNone(match, page)
            card = int(match.group(1))
            seen.append(card)
            self.assertEqual(client.request(f'/quiz/rate/{card}', raw={'rating': 2})[0], 200)
        return seen

    def test_11_keep_going_batches_and_expiry(self):
        a, b = Client(self), Client(self)
        entries = [a.noun() for _ in range(6)]
        cards = list(map(int, self.sql(f"SELECT c.id FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE e.user_id={a.user_id} ORDER BY c.id").splitlines()))
        day = self.sql("SELECT (now() AT TIME ZONE 'UTC')::date::text")
        fields = {'card_limit': '5', 'study_day': day}
        self.assertNotIn('Keep going', a.request('/quiz')[2])
        self.assertEqual(a.request('/quiz/extend', fields)[0], 303)
        self.assertEqual(self.sql(f'SELECT count(*) FROM review_extensions WHERE user_id={a.user_id}'), '0')
        self.assertEqual(self.rate_batch(a, 5), cards[:5])
        first = self.extension_fields(a)
        self.assertEqual(first, fields)
        before = [self.schedules(entry) for entry in entries]
        self.assertEqual(b.request('/quiz/extend', first)[0], 303)
        self.assertEqual(self.sql(f'SELECT count(*) FROM review_extensions WHERE user_id={b.user_id}'), '0')
        self.assertEqual(a.request('/quiz/extend', first)[0], 303)
        self.assertEqual([self.schedules(entry) for entry in entries], before)
        self.assertEqual(self.sql(f'SELECT extra_cards FROM review_extensions WHERE user_id={a.user_id}'), '5')
        self.assertIn('12 cards · 5 due', a.request('/decks')[2])
        self.assertNotIn('Keep going', a.request('/quiz')[2])
        self.assertEqual(a.request('/quiz/extend', first)[0], 303)
        self.stop()
        self.start()
        self.assertEqual(self.rate_batch(a, 5), cards[5:10])
        # Retrying the old form after the next batch is done must still be harmless.
        self.assertEqual(a.request('/quiz/extend', first)[0], 303)
        self.assertEqual(self.sql(f'SELECT extra_cards FROM review_extensions WHERE user_id={a.user_id}'), '5')
        second = self.extension_fields(a)
        self.assertEqual(second['card_limit'], '10')
        self.assertEqual(a.request('/quiz/extend', second)[0], 303)
        self.assertIn('12 cards · 2 due', a.request('/decks')[2])
        self.assertEqual(self.rate_batch(a, 2), cards[10:])
        self.assertNotIn('Keep going', a.request('/quiz')[2])
        self.assertEqual(a.request('/quiz/extend', second)[0], 303)
        self.assertEqual(self.sql(f'SELECT extra_cards FROM review_extensions WHERE user_id={a.user_id}'), '10')
        self.sql(f"UPDATE review_extensions SET study_day=study_day-1 WHERE user_id={a.user_id}; UPDATE review_cards SET due_at=now()-interval '1 minute' WHERE id IN ({','.join(map(str,cards[5:]))})")
        self.assertIn('12 cards · 0 due', a.request('/decks')[2])
        expired = self.extension_fields(a)
        self.assertEqual(expired['card_limit'], '5')
        stale_day = {**expired, 'study_day': self.sql("SELECT ((now() AT TIME ZONE 'UTC')::date-1)::text")}
        self.assertEqual(a.request('/quiz/extend', stale_day)[0], 303)
        self.assertIn('12 cards · 0 due', a.request('/decks')[2])
        self.assertEqual(a.request('/quiz/extend', expired)[0], 303)
        self.assertEqual(self.sql(f'SELECT extra_cards FROM review_extensions WHERE user_id={a.user_id}'), '5')
        self.assertIn('12 cards · 5 due', a.request('/decks')[2])
        self.sql(f'DELETE FROM users WHERE id={a.user_id}')
        self.assertEqual(self.sql(f'SELECT count(*) FROM review_extensions WHERE user_id={a.user_id}'), '0')

    def test_12_extension_guards_and_failure(self):
        a = Client(self)
        anonymous = Client(self)
        anonymous.cookie = None
        self.assertEqual(anonymous.request('/quiz/extend', {'card_limit': 5, 'study_day': '2026-01-01'})[0], 302)
        self.assertNotIn('Keep going', a.request('/quiz')[2])
        for _ in range(3):
            a.noun()
        self.rate_batch(a, 5)
        fields = self.extension_fields(a)
        self.assertEqual(a.request('/quiz/extend', {**fields, 'card_limit': 6})[0], 400)
        self.assertEqual(a.request('/quiz/extend', {**fields, 'study_day': "x'; DROP TABLE users;--"})[0], 303)
        a.request(f'/decks/{a.default}/enabled', {'enabled': 0})
        self.assertNotIn('Keep going', a.request('/quiz')[2])
        self.assertEqual(a.request('/quiz/extend', fields)[0], 303)
        self.assertEqual(self.sql(f'SELECT count(*) FROM review_extensions WHERE user_id={a.user_id}'), '0')
        a.request(f'/decks/{a.default}/enabled', {'enabled': 1})
        self.sql("CREATE FUNCTION fail_test_extension() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test extension rollback'; END$$; CREATE TRIGGER fail_test_extension BEFORE INSERT OR UPDATE ON review_extensions FOR EACH ROW EXECUTE FUNCTION fail_test_extension()")
        try:
            self.assertEqual(a.request('/quiz/extend', fields)[0], 500)
            self.assertEqual(self.sql(f'SELECT count(*) FROM review_extensions WHERE user_id={a.user_id}'), '0')
        finally:
            self.sql('DROP TRIGGER fail_test_extension ON review_extensions; DROP FUNCTION fail_test_extension()')
        self.assertEqual(a.request('/quiz/extend', fields)[0], 303)
        self.rate_batch(a, 1)
        self.assertNotIn('Keep going', a.request('/quiz')[2])

    def test_13_extension_profile_timezone_compatibility(self):
        # The profile PR is independent; support both schemas without requiring it to merge first.
        has_timezone = self.sql("SELECT count(*) FROM information_schema.columns WHERE table_name='users' AND column_name='timezone'") == '1'
        if not has_timezone:
            self.sql("ALTER TABLE users ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC'")
        try:
            a = Client(self)
            for _ in range(4):
                a.noun()
            self.sql(f"UPDATE users SET timezone='Pacific/Kiritimati' WHERE id={a.user_id}")
            self.rate_batch(a, 5)
            first = self.extension_fields(a)
            self.assertEqual(first['study_day'], self.sql("SELECT (now() AT TIME ZONE 'Pacific/Kiritimati')::date::text"))
            self.assertEqual(a.request('/quiz/extend', first)[0], 303)
            self.rate_batch(a, 3)
            self.sql(f"UPDATE users SET timezone='Pacific/Honolulu' WHERE id={a.user_id}")
            # Make only the extra cards due, keeping the base five slots reserved.
            self.sql(f"UPDATE review_cards SET due_at=now()-interval '1 minute' WHERE id IN (SELECT c.id FROM review_cards c JOIN entries e ON e.id=c.entry_id WHERE e.user_id={a.user_id} ORDER BY c.id OFFSET 5)")
            second = self.extension_fields(a)
            self.assertNotEqual(second['study_day'], first['study_day'])
            self.assertEqual(second['study_day'], self.sql("SELECT (now() AT TIME ZONE 'Pacific/Honolulu')::date::text"))
            self.assertEqual(second['card_limit'], '5')
            self.assertEqual(a.request('/quiz/extend', first)[0], 303)
            self.assertEqual(self.sql(f"SELECT study_day::text FROM review_extensions WHERE user_id={a.user_id}"), first['study_day'])
            self.assertEqual(a.request('/quiz/extend', second)[0], 303)
            self.assertEqual(self.sql(f"SELECT study_day::text FROM review_extensions WHERE user_id={a.user_id}"), second['study_day'])
        finally:
            if not has_timezone:
                self.sql('ALTER TABLE users DROP COLUMN timezone')

    def test_99_legacy_migration(self):
        self.stop()
        self.sql("ALTER DATABASE arabic RENAME TO feature_test_data", admin=True)
        self.sql("CREATE DATABASE arabic OWNER arabic", admin=True)
        subprocess.run([str(PG / "psql"), "-h", "127.0.0.1", "-p", str(self.pg_port), "-U", "arabic", "-d", "arabic", "-v", "ON_ERROR_STOP=1", "-f", str(ROOT / "migrations/001_initial.sql")], env={**self.env, "PGPASSWORD": "arabic"}, check=True, capture_output=True)
        self.sql("DROP TABLE schema_migrations; INSERT INTO users(id,username,password_hash) VALUES(100,'legacy','fixture'); INSERT INTO nouns(id,user_id,singular,plural,meaning,singular_sentence,singular_translation,plural_sentence,plural_translation) VALUES(200,100,'كِتَابٌ','كُتُبٌ','book','هَذَا كِتَابٌ','This is a book','هَذِهِ كُتُبٌ','These are books'); INSERT INTO review_cards(id,noun_id,form,due_at,interval_days,ease_factor,repetitions,last_reviewed_at) VALUES(300,200,'singular','2026-01-01',15,2.2,3,'2025-12-01'),(301,200,'plural','2026-02-01',20,2.4,4,'2025-12-02')")
        before = self.sql("SELECT id||':'||due_at||':'||interval_days||':'||ease_factor||':'||repetitions||':'||last_reviewed_at FROM review_cards ORDER BY id")
        self.start()
        self.assertEqual(self.sql("SELECT id||':'||due_at||':'||interval_days||':'||ease_factor||':'||repetitions||':'||last_reviewed_at FROM review_cards ORDER BY id"), before)
        self.assertEqual(self.sql("SELECT e.id||':'||e.user_id||':'||e.type||':'||d.enabled::text FROM entries e JOIN decks d ON d.id=e.deck_id"), "200:100:noun:true")
        self.assertEqual(self.sql("SELECT singular FROM nouns WHERE id=200"), "كِتَابٌ")
        self.assertEqual(self.sql("SELECT gender FROM nouns WHERE id=200"), "unknown")
        self.assertEqual(self.sql("SELECT count(*) FROM review_extensions"), "0")
        self.stop()
        self.start()
        self.assertEqual(self.sql("SELECT count(*) FROM schema_migrations"), "4")


if __name__ == "__main__":
    unittest.main(verbosity=2)
