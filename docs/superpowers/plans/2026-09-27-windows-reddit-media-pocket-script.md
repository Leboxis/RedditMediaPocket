# Reddit Media Pocket Windows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one dependency-free Python script that downloads Reddit media on Windows exactly like the iOS app, with a log file complete enough to diagnose any failure without re-running.

**Architecture:** A single flat module `scripts/reddit_media_pocket.py` holding every layer — naming policy, feed parsing, media extraction, DASH parsing, HTTP client, authentication, pagination and orchestration — wired together by `main()`. Every layer is a pure function or a small class that the test file drives directly: parsers take text, the HTTP client is exercised against a real local `http.server`, pagination takes an injected `fetch` callable, so no test ever touches reddit.com. Logging is installed first, before any network work, and every layer logs its decisions.

**Tech Stack:** Python 3.10+ standard library only — `urllib.request`, `xml.etree.ElementTree`, `json`, `http.server`, `concurrent.futures`, `logging`, `unittest`, `subprocess`, `dataclasses`, `pathlib`. ffmpeg is invoked as an external process when present on `PATH`.

**Spec:** `docs/superpowers/specs/2026-09-27-windows-reddit-media-pocket-script-design.md`

## Global Constraints

- Python 3.10 or newer. Standard library only. No `pip install`, no third-party import, anywhere in the script or its test.
- One file: `scripts/reddit_media_pocket.py`. Its test: `scripts/test_reddit_media_pocket.py`, discovered by the existing `python -m unittest discover -s scripts -p 'test_*.py'`.
- Existing Swift tests and existing `scripts/test_source.py` must keep passing. No Swift file is modified by this plan.
- User-Agent sent on every request: `RedditMediaPocket/0.1 (Windows; RSS reader)`.
- HTTPS only. A non-HTTPS URL, and any redirect to a non-HTTPS URL, is refused. The single exemption is `127.0.0.1` and `localhost`, so the test suite can drive a real socket without a certificate; this exemption is a test affordance and is logged as such.
- Request timeout 60 s, resource timeout 1800 s, at most 6 connections per host.
- Every RSS request carries `limit=100`. Cursor is `after=<last post id>`, valid only when it starts with `t3_`, or `t1_` for the saved feed. At most 100 pages.
- Default output root is `Documents/`, overridable with `--out`. Folders: `<pseudo>`, `r.<sub>`, `saved.<pseudo>`.
- File name: `<title> - <id>.<ext>`, title NFC-normalised, truncated to 180 UTF-8 bytes without splitting a character, conflict suffixed `-2`, `-3`.
- Sidecar metadata at `<folder>/.metadata/<filename>.json`. File creation and modification times set to the post's publication date.
- 3 concurrent media by default, `--concurrent` 1 to 6, fixed at startup. Transient errors retried 3 times with 2 s then 4 s pauses.
- HTTP 429 stops the whole session, feed and media alike, and unfinished pages are not recorded.
- `Retry-After` first (seconds or HTTP date), then `x-ratelimit-reset` in seconds. No header, no recorded cooldown.
- One log file per run at `logs/reddit_YYYYMMDD_HHMMSS.log`, DEBUG level, never overwriting a previous run. Console is INFO, or DEBUG with `--verbose`.
- No test performs a network request to reddit.com, redgifs, imgur or any external host. Local `http.server` only.

## Review Focus

The five inputs the spec implies but no requirement names outright. Each is pinned to a task below; the plan adds the test to that task.

1. **Title equal to a reserved Windows device name** — a post titled `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9` produces a file Windows refuses to create. Expect the stem to be prefixed, not the download to fail.
2. **Absolute path longer than 260 characters** — 180-byte stem plus a long folder name plus extension exceeds `MAX_PATH`. Expect a documented long-path prefix or a shorter stem, not `OSError 206`.
3. **Two posts whose stems differ only by case** — NTFS is case-insensitive, so `Chat - a1.mp4` and `chat - A1.mp4` cannot coexist. Expect the second to be suffixed `-2`.
4. **Title containing an astral character (emoji, flag) near the 180-byte limit** — naive slicing raises or produces mojibake. Expect a truncated but valid name.
5. **DASH manifest whose `BaseURL` is relative, or whose audio track points off `v.redd.it`** — expect the relative URL resolved against the manifest URL, and the mismatched audio host to be refused rather than fetched.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/reddit_media_pocket.py` | Everything: policies, parsers, HTTP, auth, pagination, downloads, CLI. Single file by design decision. |
| `scripts/test_reddit_media_pocket.py` | All tests. Imports the module directly, spins a local `http.server` for network-layer tests. |
| `docs/superpowers/specs/2026-09-27-windows-reddit-media-pocket-script-design.md` | The spec this plan implements. Already written. |

---

### Task 1: Squelette, journalisation, arguments

**Files:**
- Create: `scripts/reddit_media_pocket.py`
- Create: `scripts/test_reddit_media_pocket.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `setup_logging(log_dir: Path, verbose: bool, level: int = logging.DEBUG) -> Path` — installs console and file handlers, returns the created log file path.
  - `parse_args(argv: list[str] | None) -> argparse.Namespace` — fields `source: str`, `sort: str`, `out: Path`, `concurrent: int`, `max_pages: int`, `limit: int`, `max_errors: int`, `resume: bool`, `dry_run: bool`, `verbose: bool`, `log_dir: Path`, `cookies: Path | None`, `log_level: int`.
  - `def main(argv: list[str] | None = None) -> int`

- [ ] **Step 1: Write the failing tests**

```python
import logging
import tempfile
import unittest
from pathlib import Path

import reddit_media_pocket as rmp


class LoggingSetupTests(unittest.TestCase):
    def test_creates_dated_debug_file_and_returns_path(self):
        with tempfile.TemporaryDirectory() as d:
            path = rmp.setup_logging(Path(d), verbose=False)
            logging.getLogger("rmp.test").debug("bonjour")
            for handler in logging.getLogger().handlers:
                handler.flush()
            self.assertTrue(path.exists())
            self.assertRegex(path.name, r"^reddit_\d{8}_\d{6}\.log$")
            text = path.read_text(encoding="utf-8")
            self.assertIn("bonjour", text)
            self.assertIn("DEBUG", text)

    def test_verbose_raises_console_level_to_debug(self):
        with tempfile.TemporaryDirectory() as d:
            rmp.setup_logging(Path(d), verbose=True)
            levels = {h.level for h in logging.getLogger().handlers
                      if isinstance(h, logging.StreamHandler)
                      and not isinstance(h, logging.FileHandler)}
            self.assertEqual(levels, {logging.DEBUG})


class ArgumentTests(unittest.TestCase):
    def test_defaults(self):
        args = rmp.parse_args(["r/test"])
        self.assertEqual(args.source, "r/test")
        self.assertEqual(args.sort, "new")
        self.assertEqual(args.concurrent, 3)
        self.assertEqual(args.max_pages, 100)
        self.assertEqual(args.max_errors, 0)
        self.assertFalse(args.resume)
        self.assertFalse(args.dry_run)
        self.assertIsNone(args.cookies)

    def test_rejects_out_of_range_concurrency(self):
        with self.assertRaises(SystemExit):
            rmp.parse_args(["r/test", "--concurrent", "9"])
        with self.assertRaises(SystemExit):
            rmp.parse_args(["r/test", "--concurrent", "0"])

    def test_rejects_unknown_sort(self):
        with self.assertRaises(SystemExit):
            rmp.parse_args(["r/test", "--sort", "controversial"])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: ERROR — `ModuleNotFoundError: No module named 'reddit_media_pocket'`

- [ ] **Step 3: Create the module with logging and CLI only**

`reddit_media_pocket.py` starts with the module docstring, imports (`argparse`, `logging`, `sys`, `datetime`, `pathlib`, `re`), the `USER_AGENT` constant, `LOGGER = logging.getLogger("reddit_media_pocket")`, then `setup_logging`, then `parse_args`, then a `main` that only parses arguments, sets up logging, logs the resolved configuration and returns 0. The file handler uses `logging.FileHandler(path, encoding="utf-8")` with a formatter carrying `%(asctime)s.%(msecs)03d %(levelname)s %(name)s:%(lineno)d %(message)s`; the timestamp is built with `datetime.datetime.now().strftime("%Y%m%d_%H%M%S")`. `setup_logging` clears existing root handlers first so repeated calls in tests do not stack files. `main` guards with `if __name__ == "__main__": sys.exit(main())`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add Windows downloader skeleton with logging and CLI"
```

---

### Task 2: Politique de nommage des fichiers et dossiers

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `LOGGER` from Task 1.
- Produces:
  - `MAX_STEM_BYTES = 180`
  - `WINDOWS_RESERVED = frozenset({"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"})`
  - `post_title(raw: str, max_bytes: int = MAX_STEM_BYTES) -> str`
  - `download_stem(title: str, post_id: str, position: int | None = None) -> str`
  - `unique_destination(folder: Path, stem: str, extension: str, used: set[str]) -> Path` — mutates `used`.
  - `sanitize_folder(name: str) -> str`
  - `extension_for(url: str) -> str`

- [ ] **Step 1: Write the failing tests**

```python
class NamingTests(unittest.TestCase):
    def test_title_sanitizes_forbidden_characters(self):
        self.assertEqual(rmp.post_title('a<b>c:d"e/f\\g|h?i*j'), "a-b-c-d-e-f-g-h-i-j")

    def test_title_falls_back_when_empty(self):
        self.assertEqual(rmp.post_title("   ...  "), "post")

    def test_title_truncates_without_splitting_character(self):
        raw = "é" * 200
        title = rmp.post_title(raw)
        self.assertLessEqual(len(title.encode("utf-8")), 180)
        self.assertTrue(raw.startswith(title))

    def test_title_truncates_before_astral_character(self):
        raw = "a" * 178 + "🎉🎉"
        title = rmp.post_title(raw)
        self.assertLessEqual(len(title.encode("utf-8")), 180)
        self.assertNotIn("\ud83c", title)  # no lone surrogate

    def test_reserved_windows_name_is_prefixed(self):
        self.assertEqual(rmp.post_title("CON"), "_CON")
        self.assertEqual(rmp.post_title("com1"), "_com1")

    def test_stem_uses_id_and_position(self):
        self.assertEqual(rmp.download_stem("Titre", "t3_abc"), "Titre - abc")
        self.assertEqual(rmp.download_stem("Titre", "t3_abc", 2), "Titre 2 - abc")

    def test_conflict_suffix_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            used = set()
            first = rmp.unique_destination(folder, "Chat", "mp4", used)
            second = rmp.unique_destination(folder, "chat", "mp4", used)
            self.assertEqual(first.name, "Chat.mp4")
            self.assertEqual(second.name, "chat-2.mp4")

    def test_extension_from_url_defaults_to_mp4(self):
        self.assertEqual(rmp.extension_for("https://i.redd.it/a/b.png"), "png")
        self.assertEqual(rmp.extension_for("https://i.redd.it/a/b"), "mp4")

    def test_folder_name_replaces_dots(self):
        self.assertEqual(rmp.sanitize_folder("bad.name"), "bad_name")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'post_title'`

- [ ] **Step 3: Implement the naming policy**

Append to the module. `post_title` applies `unicodedata.normalize("NFC", raw)`, maps control characters `[\x00-\x1f\x7f]` to a space, maps `< > : " / \ | ? *` to `-`, collapses runs of whitespace, trims leading and trailing `.` `-` and spaces, falls back to `"post"`, then truncates to `max_bytes` UTF-8 without splitting a character — decrement a candidate index while the encoded form exceeds the budget, and stop before any character whose UTF-8 encoding starts with `\xf0`, which is where an astral character begins. After truncation, rstrip `.- ` again. Then, if `title.upper()` is in `WINDOWS_RESERVED` or matches a reserved name followed by a dot, prefix `_`. `download_stem` strips the `t3_` prefix and trims `.- ` from the id, then returns `f"{title} {position} - {id}"` when `position` is not None else `f"{title} - {id}"`. `unique_destination` lowercases the candidate name for the `used` set and appends `-2`, `-3` until free. `extension_for` takes the last dot segment of the path when it is one of `jpg jpeg png gif webp mp4`, else `mp4`. `sanitize_folder` replaces every `.` with `_`. `source_folder` returns `f"r.{name}"` for a subreddit, `f"saved.{owner}"` for saved, `name` for a profile, each passed through `sanitize_folder`. Every rejection the function performs — fallback name, truncation, reserved-name prefix, conflict suffix — is logged through `LOGGER.debug`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 14 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add filename and folder naming policy"
```

---

### Task 3: Source, URL de flux et parseur Atom

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `LOGGER` from Task 1.
- Produces:
  - `USER_PATTERN = re.compile(r"^[A-Za-z0-9_-]{3,20}$")`, `SUB_PATTERN = re.compile(r"^[A-Za-z0-9_]{2,21}$")`
  - `@dataclass(frozen=True) class Source: kind: str; name: str` with `kind` in `user`, `subreddit`, `saved`.
  - `parse_source(text: str) -> Source` — raises `ValueError` on an invalid name.
  - `source_folder(source: Source, owner: str) -> str` — `name` for a profile, `f"r.{name}"` for a subreddit, `f"saved.{owner}"` for saved, each passed through `sanitize_folder`.
  - `feed_url(source: Source, sort: str = "new", after: str | None = None) -> str`
  - `@dataclass class Post: id: str; title: str; html: str; published_at: str | None; link: str | None`
  - `parse_feed(text: str) -> list[Post]` — raises `FeedError` when the root element is not `feed`.

- [ ] **Step 1: Write the failing tests**

```python
ATOM = """<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
 <entry><id>t3_abc</id><title>Premier</title>
  <content type="html">&lt;a href="https://i.redd.it/a/b.png"&gt;x&lt;/a&gt;</content>
  <published>2026-01-02T03:04:05Z</published>
  <link href="https://www.reddit.com/r/test/comments/abc/"/><author><name>/u/a</name></author></entry>
 <entry><id>t3_def</id><title><![CDATA[Deuxième]]></title>
  <content type="html"><![CDATA[<a href="https://i.redd.it/c/d.jpg">y</a>]]></content>
  <link href="https://www.reddit.com/r/test/comments/def/"/></entry>
 <entry><title>Sans identifiant</title><content>z</content></entry>
</feed>"""


class SourceTests(unittest.TestCase):
    def test_parse_kinds(self):
        self.assertEqual(rmp.parse_source("u/alice"), rmp.Source("user", "alice"))
        self.assertEqual(rmp.parse_source("r/pics"), rmp.Source("subreddit", "pics"))
        self.assertEqual(rmp.parse_source("saved"), rmp.Source("saved", ""))

    def test_parse_rejects_invalid(self):
        for bad in ["u/ab", "r/pics!", "u/alice.bob", "profil", "r/"]:
            with self.assertRaises(ValueError):
                rmp.parse_source(bad)

    def test_feed_urls(self):
        self.assertEqual(
            rmp.feed_url(rmp.Source("user", "alice")),
            "https://www.reddit.com/user/alice/submitted.rss?limit=100")
        self.assertEqual(
            rmp.feed_url(rmp.Source("subreddit", "pics"), "top"),
            "https://www.reddit.com/r/pics/top.rss?t=month&limit=100")
        self.assertEqual(
            rmp.feed_url(rmp.Source("subreddit", "pics"), "new", "t3_abc"),
            "https://www.reddit.com/r/pics/new.rss?limit=100&after=t3_abc")

    def test_invalid_sort_falls_back_to_new(self):
        self.assertEqual(
            rmp.feed_url(rmp.Source("subreddit", "pics"), "nonsense"),
            "https://www.reddit.com/r/pics/new.rss?limit=100")

    def test_source_folder_prefixes_and_strips_dots(self):
        self.assertEqual(rmp.source_folder(rmp.Source("user", "alice"), "alice"), "alice")
        self.assertEqual(rmp.source_folder(rmp.Source("subreddit", "pics"), "alice"), "r.pics")
        self.assertEqual(rmp.source_folder(rmp.Source("saved", ""), "a.b"), "saved.a_b")


class FeedParserTests(unittest.TestCase):
    def test_parses_entries_and_unescapes_html(self):
        posts = rmp.parse_feed(ATOM)
        self.assertEqual([p.id for p in posts], ["t3_abc", "t3_def"])
        self.assertIn("i.redd.it/a/b.png", posts[0].html)
        self.assertIn("i.redd.it/c/d.jpg", posts[1].html)
        self.assertEqual(posts[0].published_at, "2026-01-02T03:04:05Z")
        self.assertEqual(posts[0].link, "https://www.reddit.com/r/test/comments/abc/")

    def test_rejects_blocking_page(self):
        with self.assertRaises(rmp.FeedError):
            rmp.parse_feed("<html><body>blocked</body></html>")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'parse_source'`

- [ ] **Step 3: Implement source, URLs and the Atom parser**

Append. `parse_source` strips whitespace, dispatches on the `u/`, `r/` and `saved` prefixes, and rejects anything else with `ValueError` naming the accepted forms. `feed_url` builds the profile URL as `/user/<name>/submitted.rss`, and the subreddit URL as `/r/<name>/<sort>.rss` where an unrecognised sort becomes `new`; `top` puts `t=month` first; `limit=100` is always present and `after=` is appended last. `source_folder` returns the profile name, `r.<name>` for a subreddit and `saved.<owner>` for the saved feed, each passed through `sanitize_folder`. `parse_feed` uses `xml.etree.ElementTree.fromstring`, checks the tag ends with `feed`, then walks children whose tag ends with `entry`, reading `id`, `title`, `content`, `published` and the first `link` with an `href` attribute, and skipping any entry without an id. Namespaces are handled by comparing `tag.rsplit("}", 1)[-1]`. An unparsable document and a non-`feed` root both raise `FeedError` with the offending root tag included. Log the entry count and each skipped entry at debug level.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 22 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add source parsing, feed URLs and Atom parser"
```

---

### Task 4: Extraction des médias et politique de qualité

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `LOGGER` from Task 1.
- Produces:
  - `HREF_PATTERN = re.compile(r"""(?i)href\s*=\s*["']([^"']+)["']""")`
  - `GALLERY_PATTERN = re.compile(r"""(?i)href\s*=\s*["']https://www\.reddit\.com/gallery/([A-Za-z0-9]+)["']""")`
  - `@dataclass(frozen=True) class Media: key: str; kind: str; url: str; position: int = 0` with `kind` in `direct`, `reddit_video`, `redgifs`.
  - `extract_media(html: str) -> list[Media]`
  - `gallery_id(html: str) -> str | None`
  - `original_image_url(url: str) -> str`
  - `redgifs_candidates(hd: str | None, sd: str | None) -> list[tuple[str, str]]`

- [ ] **Step 1: Write the failing tests**

```python
class MediaExtractionTests(unittest.TestCase):
    def test_extracts_direct_images_and_video(self):
        html = ('<a href="https://i.redd.it/a/b.png">i</a>'
                '<a href="https://i.imgur.com/c/d.jpg">j</a>'
                '<a href="https://i.redd.it/e/f.mp4">k</a>')
        media = rmp.extract_media(html)
        self.assertEqual([m.kind for m in media], ["direct"] * 3)

    def test_ignores_img_tags_and_non_https(self):
        html = ('<img src="https://i.redd.it/a/b.png">'
                '<a href="http://i.redd.it/a/b.png">x</a>')
        self.assertEqual(rmp.extract_media(html), [])

    def test_extracts_reddit_video_and_redgifs(self):
        html = ('<a href="https://v.redd.it/abc123">v</a>'
                '<a href="https://www.redgifs.com/watch/AbC">r</a>'
                '<a href="https://www.redgifs.com/ifr/XyZ">r2</a>')
        media = rmp.extract_media(html)
        self.assertEqual(media[0].kind, "reddit_video")
        self.assertEqual(media[0].url, "https://v.redd.it/abc123")
        self.assertEqual(media[1].kind, "redgifs")
        self.assertEqual(media[1].url, "redgifs:abc")
        self.assertEqual(media[2].url, "redgifs:xyz")

    def test_deduplicates_by_key(self):
        html = '<a href="https://i.redd.it/a/b.png">1</a><a href="https://i.redd.it/a/b.png">2</a>'
        self.assertEqual(len(rmp.extract_media(html)), 1)

    def test_gallery_only_when_no_direct_media(self):
        html = '<a href="https://www.reddit.com/gallery/Ab1">g</a>'
        self.assertEqual(rmp.gallery_id(html), "Ab1")
        self.assertIsNone(rmp.gallery_id(html + '<a href="https://i.redd.it/a/b.png">i</a>'))


class QualityPolicyTests(unittest.TestCase):
    def test_strips_imgur_thumbnail_suffix(self):
        self.assertEqual(rmp.original_image_url("https://i.imgur.com/abc123m.jpg"),
                         "https://i.imgur.com/abc123.jpg")
        self.assertEqual(rmp.original_image_url("https://i.imgur.com/abcd5h.png"),
                         "https://i.imgur.com/abcd5.png")

    def test_keeps_other_imgur_ids_untouched(self):
        for url in ["https://i.imgur.com/ab.jpg", "https://i.imgur.com/abcdefgh.jpg",
                    "https://i.redd.it/abcm.png"]:
            self.assertEqual(rmp.original_image_url(url), url)

    def test_preview_never_used_as_original(self):
        self.assertEqual(rmp.original_image_url("https://preview.redd.it/x.png"),
                         "https://preview.redd.it/x.png")

    def test_redgifs_candidates_prefer_hd_then_sd(self):
        self.assertEqual(
            rmp.redgifs_candidates("https://media.redgifs.com/a-hd.mp4", None),
            [("https://media.redgifs.com/a-hd.mp4", "HD")])
        self.assertEqual(rmp.redgifs_candidates(None, None), [])
        self.assertEqual(
            rmp.redgifs_candidates("https://media.redgifs.com/a.mp4",
                                   "https://media.redgifs.com/a-mobile.mp4"),
            [("https://media.redgifs.com/a.mp4", "HD"),
             ("https://media.redgifs.com/a-mobile.mp4", "SD")])

    def test_redgifs_candidates_reject_foreign_host(self):
        self.assertEqual(rmp.redgifs_candidates("https://evil.example/a.mp4", None), [])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'extract_media'`

- [ ] **Step 3: Implement extraction and quality policy**

Append. `extract_media` scans `HREF_PATTERN` only, never `<img>`, decodes `&amp;` to `&`, requires an `https` scheme, and maps each href: host `i.redd.it` or `i.imgur.com` with an extension in `jpg jpeg png gif webp mp4` becomes `Media(key=url_after_original_image_url, kind="direct", url=...)`; host `v.redd.it` takes the first path component as id and becomes `Media(key=f"video:{id}", kind="reddit_video", url=f"https://v.redd.it/{id}")`; host `redgifs.com` or `www.redgifs.com` with a `/watch/<id>` or `/ifr/<id>` path and an id matching `^[A-Za-z0-9]+$` becomes `Media(key=f"redgifs:{id.lower()}", kind="redgifs", url=f"redgifs:{id.lower()}")`; anything else is ignored and logged at debug with its host. Keys are deduplicated while preserving first-seen order. `gallery_id` returns the first gallery id from `GALLERY_PATTERN` only when `extract_media` found nothing. `original_image_url` applies the 5-or-7-alphanumeric plus one of `sbtmlh` rule on `i.imgur.com` image extensions only. `redgifs_candidates` keeps only `redgifs.com` and `*.redgifs.com` hosts, labels `-mobile` as SD and everything else HD, and returns HD before SD.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 32 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add media extraction and quality policy"
```

---

### Task 5: Parseur DASH

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `LOGGER` from Task 1, `FeedError` from Task 3.
- Produces:
  - `DASH_HOST = "v.redd.it"`
  - `@dataclass(frozen=True) class DashTrack: url: str; height: int; width: int; fps: float; bandwidth: int`
  - `@dataclass(frozen=True) class DashSelection: video: DashTrack; audio: DashTrack | None`
  - `parse_dash(mpd: str, manifest_url: str) -> DashSelection` — raises `FeedError` for a segmented manifest, a missing video track, or a track host other than `v.redd.it`.

- [ ] **Step 1: Write the failing tests**

```python
MPD = """<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
 <BaseURL>https://v.redd.it/abc123/</BaseURL>
 <Period>
  <AdaptationSet mimeType="video/mp4">
   <Representation id="v1" height="480" width="852" frameRate="30" bandwidth="800000">
     <BaseURL>DASHPlaylist_video_480.mp4</BaseURL></Representation>
   <Representation id="v2" height="1080" width="1920" frameRate="60" bandwidth="3000000">
     <BaseURL>DASHPlaylist_video_1080.mp4</BaseURL></Representation>
  </AdaptationSet>
  <AdaptationSet mimeType="audio/mp4">
   <Representation id="a1" bandwidth="128000"><BaseURL>DASHPlaylist_audio_128.mp4</BaseURL></Representation>
   <Representation id="a2" bandwidth="320000"><BaseURL>DASHPlaylist_audio_320.mp4</BaseURL></Representation>
  </AdaptationSet>
 </Period>
</MPD>"""


class DashTests(unittest.TestCase):
    def test_picks_best_video_and_audio(self):
        sel = rmp.parse_dash(MPD, "https://v.redd.it/abc123/DASHPlaylist.mpd")
        self.assertEqual(sel.video.height, 1080)
        self.assertEqual(sel.video.url,
                         "https://v.redd.it/abc123/DASHPlaylist_video_1080.mp4")
        self.assertEqual(sel.audio.bandwidth, 320000)

    def test_video_without_audio(self):
        mpd = MPD.replace('mimeType="audio/mp4"', 'mimeType="text/vtt"')
        self.assertIsNone(rmp.parse_dash(mpd, "https://v.redd.it/abc/DASHPlaylist.mpd").audio)

    def test_rejects_segmented_manifest(self):
        mpd = MPD.replace("<BaseURL>DASHPlaylist_video_1080.mp4</BaseURL>",
                          '<BaseURL/><SegmentBase indexRange="0-100"/>'
                          '<SegmentList><SegmentURL media="s1.m4s"/></SegmentList>')
        with self.assertRaises(rmp.FeedError) as ctx:
            rmp.parse_dash(mpd, "https://v.redd.it/abc/DASHPlaylist.mpd")
        self.assertIn("segment", str(ctx.exception).lower())

    def test_rejects_foreign_host(self):
        mpd = MPD.replace("https://v.redd.it/abc123/", "https://evil.example/abc123/")
        with self.assertRaises(rmp.FeedError):
            rmp.parse_dash(mpd, "https://v.redd.it/abc/DASHPlaylist.mpd")

    def test_ties_broken_by_bandwidth(self):
        mpd = MPD.replace('height="1080" width="1920" frameRate="60"',
                          'height="1080" width="1920" frameRate="60"')
        self.assertEqual(rmp.parse_dash(mpd, "https://v.redd.it/a/DASHPlaylist.mpd").video.bandwidth,
                         3000000)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'parse_dash'`

- [ ] **Step 3: Implement the DASH parser**

Append. `parse_dash` parses the MPD with `ElementTree`, walks `AdaptationSet` and `Representation` elements, and refuses the manifest when any of them carries a `SegmentTemplate` or `SegmentList` child, raising `FeedError` whose message contains "manifest segmenté non pris en charge". Track URLs combine the nearest enclosing `BaseURL` and the representation `BaseURL`, resolved with `urllib.parse.urljoin` against the manifest URL so a relative or single-slash `BaseURL` yields `https://v.redd.it/abc123/…`. `frameRate="x/y"` becomes `x / y`, a bare integer stays as is, absent becomes 0. Video tracks are those whose mime type starts with `video`; audio those starting with `audio`; the video is the max on `(height, width, fps, bandwidth)`, the audio the max on bandwidth. A manifest with no video track, or whose final track host is not exactly `v.redd.it`, raises `FeedError`. Log every candidate track with its height, width, fps and bandwidth, then which one was kept and why, at debug level.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 37 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add DASH manifest parser with track selection"
```

---

### Task 6: Client HTTP, cookies et gestion du 429

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `USER_AGENT` from Task 1, `LOGGER` from Task 1.
- Produces:
  - `class LimitedError(Exception)` with `service: str` and `until: float | None` attributes.
  - `class TransientError(Exception)`.
  - `@dataclass class Response: status: int; headers: dict[str, str]; body: bytes; url: str`
  - `def cookie_header(cookies: list[Cookie], url: str) -> str` — empty string when nothing may be sent.
  - `service_for(url: str) -> str` — `reddit.com` and `redd.it` become `Reddit`, `redgifs.com` becomes `RedGIFs`, `imgur.com` becomes `Imgur`, otherwise the host.
  - `retry_date(headers: dict[str, str], now: float) -> float | None` — `Retry-After` as seconds then as HTTP date, else `x-ratelimit-reset` as seconds, else `None`.
  - `class HttpClient: def __init__(self, verbose: bool = False)` and `def request(self, url: str, *, headers: dict[str, str] | None = None, cookies: list[Cookie] | None = None, method: str = "GET", body: bytes | None = None, allow_redirects: bool = True) -> Response`.
  - `def build_opener(handler_factory)` returning an opener with a 60 s timeout and at most 6 connections per host.
  - `class RedirectGuard(urllib.request.HTTPRedirectHandler)` with `allowed(headers) -> bool` hook, defaulting to any https destination.

- [ ] **Step 1: Write the failing tests**

```python
import http.server
import json
import os
import threading
import time
import urllib.parse


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/ok"):
            body = b"hello"
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/ratelimit"):
            self.send_response(429)
            self.send_header("x-ratelimit-used", "100")
            self.send_header("x-ratelimit-remaining", "0.0")
            self.send_header("x-ratelimit-reset", "30")
            self.end_headers()
        elif self.path.startswith("/retry-after"):
            self.send_response(429)
            self.send_header("Retry-After", "12")
            self.end_headers()
        elif self.path.startswith("/boom"):
            self.send_response(503)
            self.end_headers()
        elif self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", self.path.replace("/redirect", "/ok"))
            self.end_headers()
        elif self.path.startswith("/cookie"):
            seen = self.headers.get("Cookie", "")
            self.send_response(200)
            body = seen.encode()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


class HttpClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_get_returns_status_headers_body(self):
        response = rmp.HttpClient().request(f"{self.base}/ok")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, b"hello")
        self.assertEqual(response.headers["Content-Type"], "image/png")

    def test_429_raises_limited_with_reset_delay(self):
        with self.assertRaises(rmp.LimitedError) as ctx:
            rmp.HttpClient().request(f"{self.base}/ratelimit")
        self.assertEqual(ctx.exception.service, "127.0.0.1")
        self.assertIsNotNone(ctx.exception.until)

    def test_retry_after_wins_over_reset(self):
        with self.assertRaises(rmp.LimitedError) as ctx:
            rmp.HttpClient().request(f"{self.base}/retry-after")
        self.assertIsNotNone(ctx.exception.until)

    def test_5xx_is_transient(self):
        with self.assertRaises(rmp.TransientError):
            rmp.HttpClient().request(f"{self.base}/boom")

    def test_404_is_returned_not_raised(self):
        self.assertEqual(rmp.HttpClient().request(f"{self.base}/missing").status, 404)

    def test_redirect_guard_refuses_non_https(self):
        self.assertTrue(rmp.RedirectGuard(allowed=lambda h: True).allowed({}))
        self.assertFalse(rmp.RedirectGuard(allowed=lambda h: False).allowed({}))

    def test_cookie_reaches_only_reddit(self):
        cookies = [rmp.Cookie("reddit_session", "abc", domain="reddit.com"),
                   rmp.Cookie("ig", "zzz", domain="imgur.com")]
        header = rmp.cookie_header(cookies, "https://www.reddit.com/r/test/new.rss")
        self.assertIn("reddit_session=abc", header)
        self.assertNotIn("ig=zzz", header)
        self.assertEqual(rmp.cookie_header(cookies, "https://i.imgur.com/a.png"), "")

    def test_cookie_ignored_outside_path(self):
        cookies = [rmp.Cookie("scoped", "v", domain="reddit.com", path="/prefs")]
        self.assertEqual(rmp.cookie_header(cookies, "https://old.reddit.com/r/a"), "")
        self.assertIn("scoped=v", rmp.cookie_header(cookies, "https://old.reddit.com/prefs/feeds/"))

    def test_expired_cookie_is_dropped(self):
        cookies = [rmp.Cookie("old", "v", domain="reddit.com", expires=1000)]
        self.assertEqual(rmp.cookie_header(cookies, "https://reddit.com/r/a"), "")

    def test_loopback_is_exempt_from_https_only(self):
        response = rmp.HttpClient().request(f"{self.base}/ok")
        self.assertEqual(response.status, 200)


class RatePolicyTests(unittest.TestCase):
    def test_service_grouping(self):
        self.assertEqual(rmp.service_for("https://www.reddit.com/x.rss"), "Reddit")
        self.assertEqual(rmp.service_for("https://v.redd.it/a/DASHPlaylist.mpd"), "Reddit")
        self.assertEqual(rmp.service_for("https://api.redgifs.com/v2/gifs/a"), "RedGIFs")
        self.assertEqual(rmp.service_for("https://i.imgur.com/a.png"), "Imgur")
        self.assertEqual(rmp.service_for("https://other.example/a"), "other.example")

    def test_retry_date_prefers_retry_after_seconds(self):
        now = time.time()
        self.assertAlmostEqual(
            rmp.retry_date({"Retry-After": "30", "x-ratelimit-reset": "10"}, now), now + 30, delta=1)

    def test_retry_date_falls_back_to_reset(self):
        now = time.time()
        self.assertAlmostEqual(
            rmp.retry_date({"x-ratelimit-reset": "10"}, now), now + 10, delta=1)

    def test_retry_date_none_without_headers(self):
        self.assertIsNone(rmp.retry_date({}, time.time()))

    def test_retry_date_parses_http_date(self):
        now = time.time()
        stamp = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(now + 45))
        self.assertAlmostEqual(rmp.retry_date({"Retry-After": stamp}, now), now + 45, delta=1)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'HttpClient'`

- [ ] **Step 3: Implement the HTTP client**

Append. `HttpClient.request` builds a `urllib.request.Request` with the `User-Agent`, merges caller headers, and attaches a `Cookie` header built by `cookie_header(cookies, url)`, which filters on scheme https, host `reddit.com` or a subdomain, path prefix on segment boundaries, and expiry, then joins the surviving `name=value` pairs. It installs `RedirectGuard(allowed=...)` where the default guard refuses any `Location` that is not https. It calls the opener with a 60 s timeout. `urllib.error.HTTPError` is the signal for a real status: 429 raises `LimitedError(service_for(url), retry_date(headers, now))` and 408 or 5xx raise `TransientError`; any other status is returned as a `Response`. `urllib.error.URLError`, `socket.timeout` and `ConnectionError` raise `TransientError`. Every request logs method, full URL, status, elapsed milliseconds, byte count and the response headers named in the spec — `content-type`, `content-length`, `content-range`, `retry-after`, `x-ratelimit-used`, `x-ratelimit-remaining`, `x-ratelimit-reset`, `location` — at debug level, and the masked cookie header at debug level, so the log alone explains any refusal. `build_opener` sets `HTTPHandler` with a connection pool of 6 and a default timeout of 60 s. A URL whose host is `127.0.0.1` or `localhost` is allowed to be plain HTTP and logs a warning that it is a test affordance; every other host must be https.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 49 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add HTTP client with logging, cookie policy and 429 handling"
```

---

### Task 7: Authentification OAuth et repli par cookies

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `HttpClient` from Task 6, `USER_PATTERN` from Task 3.
- Produces:
  - `OAUTH_CLIENT_ID = "6N9uN0krSDE-ig"`
  - `OAUTH_SCOPES = "read history"`
  - `OAUTH_REDIRECT_PORT = 6414`
  - `AUTHORIZE_URL`, `TOKEN_URL`, `API_BASE = "https://oauth.reddit.com"`
  - `token_path() -> Path` — `%LOCALAPPDATA%\RedditMediaPocket\token.json`.
  - `parse_cookies_file(path: Path) -> list[Cookie]` — Netscape or bare `reddit_session`.
  - `saved_feed_from_html(html: str, page_url: str) -> tuple[str, str]` — returns `(url, owner)`; raises `ValueError` when no valid link is present.
  - `is_saved_path(path: str) -> bool`
  - `saved_page_url(feed_url: str, after: str | None) -> str`
  - `authorize_url(state: str) -> str`
  - `class TokenStore: load() -> dict | None` and `save(data: dict) -> None`.
  - `run_oauth_flow(client: HttpClient, opener: webbrowser_mod) -> dict` — captures the code on a local server and exchanges it.

- [ ] **Step 1: Write the failing tests**

```python
class SavedFeedTests(unittest.TestCase):
    def test_extracts_feed_and_owner(self):
        html = ('<a href="/prefs/feeds/saved/u/alice?feed=abc123&amp;user=alice">s</a>')
        url, owner = rmp.saved_feed_from_html(html, "https://old.reddit.com/prefs/feeds/")
        self.assertEqual(owner, "alice")
        self.assertIn("feed=abc123", url)
        self.assertIn("user=alice", url)
        self.assertTrue(url.startswith("https://old.reddit.com/"))

    def test_rejects_non_saved_path(self):
        for path in ["/prefs/feeds/u/alice", "/prefs/feeds/saved/.rss",
                     "/prefs/feeds/comments/abc"]:
            with self.assertRaises(ValueError):
                rmp.saved_feed_from_html(
                    f'<a href="{path}?feed=t&amp;user=alice">x</a>',
                    "https://old.reddit.com/prefs/feeds/")

    def test_rejects_foreign_host(self):
        with self.assertRaises(ValueError):
            rmp.saved_feed_from_html(
                '<a href="https://evil.example/prefs/feeds/saved/u/alice?feed=t&amp;user=alice">x</a>',
                "https://old.reddit.com/prefs/feeds/")

    def test_rejects_credentials_in_url(self):
        with self.assertRaises(ValueError):
            rmp.saved_feed_from_html(
                '<a href="https://u:p@old.reddit.com/prefs/feeds/saved/u/alice?feed=t&amp;user=alice">x</a>',
                "https://old.reddit.com/prefs/feeds/")

    def test_page_url_adds_limit_and_after(self):
        base = "https://old.reddit.com/prefs/feeds/saved/u/alice?feed=t&user=alice"
        self.assertEqual(rmp.saved_page_url(base, None), base + "&limit=100")
        self.assertEqual(rmp.saved_page_url(base, "t1_abc"), base + "&limit=100&after=t1_abc")

    def test_authorize_url_uses_installed_app_parameters(self):
        url = rmp.authorize_url("STATE123")
        parsed = urllib.parse.urlparse(url)
        params = dict(urllib.parse.parse_qsl(parsed.query))
        self.assertEqual(parsed.scheme + "://" + parsed.netloc, "https://www.reddit.com")
        self.assertEqual(params["client_id"], rmp.OAUTH_CLIENT_ID)
        self.assertEqual(params["response_type"], "code")
        self.assertEqual(params["state"], "STATE123")
        self.assertEqual(params["redirect_uri"], "http://localhost:6414/")
        self.assertEqual(params["duration"], "permanent")
        self.assertEqual(params["scope"], "read history")

    def test_parses_netscape_cookie_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cookies.txt"
            path.write_text(
                "# Netscape HTTP Cookie File\n"
                ".reddit.com\tTRUE\t/\tTRUE\t2000000000\treddit_session\tabc123\n"
                ".imgur.com\tTRUE\t/\tTRUE\t2000000000\tig\tzzz\n",
                encoding="utf-8")
            cookies = rmp.parse_cookies_file(path)
        self.assertEqual([(c.name, c.value) for c in cookies], [("reddit_session", "abc123")])

    def test_parses_bare_session_value(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "session.txt"
            path.write_text("abc123\n", encoding="utf-8")
            cookies = rmp.parse_cookies_file(path)
        self.assertEqual([(c.name, c.value) for c in cookies], [("reddit_session", "abc123")])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'saved_feed_from_html'`

- [ ] **Step 3: Implement OAuth, cookie parsing and the private feed policy**

Append. `parse_cookies_file` reads the file, and if a line starts with `# Netscape` or contains a tab-separated field count of 7, parses Netscape rows, keeping only `reddit.com` and subdomains and skipping expired entries; otherwise strips the text, removes a leading `reddit_session=`, and returns that single cookie. `saved_feed_from_html` scans `href` attributes, decodes `&amp;` `&#38;` `&#x26;`, resolves relative links against `page_url`, then applies every acceptance rule in the spec — https scheme, host in the three allowed names, no userinfo, no port, exactly one valid `user` matching `USER_PATTERN`, one non-empty `feed`, and a path satisfying `is_saved_path` — and returns the cleaned URL limited to `feed` and `user`, or raises `ValueError` listing each rejected candidate with its reason. `saved_page_url` appends `limit=100` then `after=` when given. `authorize_url` builds the authorize URL with the spec's exact parameters. `TokenStore` reads and writes `token.json` with `os.makedirs(parents=True, exist_ok=True)` and never logs its contents beyond the presence of an access and a refresh token. `run_oauth_flow` starts an `http.server.HTTPServer` on `127.0.0.1` port 6414 in a thread, calls the injected browser opener with `authorize_url(state)`, waits on a `threading.Event` with a 300 s timeout, compares the returned `state` to the emitted one and fails on mismatch, then POSTs the code to `TOKEN_URL` with Basic auth of `f"{OAUTH_CLIENT_ID}:"` and logs the outcome. Cookie values are masked to their first four characters everywhere they are logged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 57 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add OAuth flow, cookie parsing and private saved feed policy"
```

---

### Task 8: Pagination et état de reprise

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `Post` from Task 3, `source_folder` from Task 2.
- Produces:
  - `@dataclass class ResumeState: visited: list[str]; frontier: str | None; incomplete: bool`
  - `state_path(folder: Path) -> Path`
  - `load_state(folder: Path) -> ResumeState`
  - `save_state(folder: Path, state: ResumeState) -> None`
  - `valid_cursor(post_id: str, saved: bool) -> bool` — `t3_` always, `t1_` only when `saved`.
  - `traverse(source: Source, url_for: callable, process: callable, *, max_pages: int = 100, state: ResumeState | None = None, fetch: callable | None = None, on_page: callable | None = None) -> TraversalResult` — `fetch(url) -> tuple[list[Post], str | None]` returns the posts of a page and the next cursor; when omitted, a network fetch built from `url_for` is used.
  - `@dataclass class TraversalResult: pages: int; stopped: str; complete: bool; checkpoint: str | None`
  - `stopped` is one of `history`, `repeated`, `empty`, `cursor`, `max_pages`, `limit`, `cancelled`.

- [ ] **Step 1: Write the failing tests**

```python
def _posts(*ids):
    return [rmp.Post(i, f"title {i}", "<a href='https://i.redd.it/a/b.png'>i</a>",
                     "2026-01-01T00:00:00Z", None) for i in ids]


class TraversalTests(unittest.TestCase):
    def setUp(self):
        self.pages = {
            None: _posts("t3_1", "t3_2"),
            "t3_2": _posts("t3_2", "t3_3"),
            "t3_3": _posts("t3_3"),
        }
        self.seen = []

    def url_for(self, after):
        return "https://example.invalid/feed?after=%s" % (after or "")

    def process(self, page):
        self.seen.append([p.id for p in page])

    def test_walks_pages_and_stops(self):
        pages = {None: _posts("t3_1", "t3_2"), "t3_2": _posts("t3_2", "t3_3")}

        def fetch(url):
            after = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("after", [None])[0]
            return pages.get(after, []), (after or "t3_9")

        result = rmp.traverse(rmp.Source("user", "alice"),
                              lambda a: "https://example.invalid/feed?after=" + (a or ""),
                              lambda page: None, fetch=fetch)
        self.assertEqual(result.stopped, "empty")
        self.assertTrue(result.complete)

    def test_stops_on_repeated_page(self):
        def fetch(url):
            return _posts("t3_1"), "t3_1"

        state = rmp.ResumeState(visited=["t3_1"], frontier=None, incomplete=False)
        result = rmp.traverse(rmp.Source("user", "alice"),
                              lambda a: "https://example.invalid/feed",
                              lambda page: None, fetch=fetch, state=state)
        self.assertEqual(result.stopped, "repeated")

    def test_stops_on_empty_page(self):
        result = rmp.traverse(rmp.Source("user", "alice"),
                              lambda after: "https://example.invalid/feed",
                              lambda page: None,
                              fetch=lambda url: ([], None))
        self.assertEqual(result.stopped, "empty")

    def test_invalid_cursor_stops(self):
        def fetch(url):
            if url.endswith("after="):
                return _posts("bad_id"), None
            return _posts("t3_1"), "t3_1"
        result = rmp.traverse(rmp.Source("user", "alice"),
                              lambda after: "https://example.invalid/feed?after=" + (after or ""),
                              lambda page: None, fetch=fetch)
        self.assertEqual(result.stopped, "cursor")

    def test_max_pages_reports_incomplete(self):
        def fetch(url):
            return _posts("t3_" + url[-1] + "x"), "t3_" + url[-1] + "x"
        result = rmp.traverse(rmp.Source("user", "alice"),
                              lambda after: "https://example.invalid/feed" + (after or ""),
                              lambda page: None, fetch=fetch, max_pages=3)
        self.assertEqual(result.stopped, "max_pages")
        self.assertFalse(result.complete)
        self.assertIsNotNone(result.checkpoint)

    def test_page_is_not_recorded_when_process_raises(self):
        state = rmp.ResumeState(visited=[], frontier=None, incomplete=False)
        calls = []

        def process(page):
            calls.append(1)
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            rmp.traverse(rmp.Source("user", "alice"),
                         lambda after: "https://example.invalid/feed",
                         process, fetch=lambda url: (_posts("t3_1"), "t3_1"),
                         state=state)
        self.assertEqual(state.visited, [])

    def test_saved_cursor_accepts_t1_only_for_saved(self):
        self.assertTrue(rmp.valid_cursor("t1_abc", True))
        self.assertFalse(rmp.valid_cursor("t1_abc", False))
        self.assertTrue(rmp.valid_cursor("t3_abc", False))

    def test_state_round_trips_on_disk(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "alice"
            folder.mkdir()
            state = rmp.ResumeState(visited=["t3_1", "t3_2"], frontier="t3_2", incomplete=True)
            rmp.save_state(folder, state)
            loaded = rmp.load_state(folder)
            self.assertEqual(loaded.visited, ["t3_1", "t3_2"])
            self.assertEqual(loaded.frontier, "t3_2")
            self.assertTrue(loaded.incomplete)

    def test_visited_is_bounded_to_10000(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "alice"
            folder.mkdir()
            rmp.save_state(folder, rmp.ResumeState(
                visited=[f"t3_{i}" for i in range(10500)], frontier=None, incomplete=False))
            self.assertEqual(len(rmp.load_state(folder).visited), 10000)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'traverse'`

- [ ] **Step 3: Implement pagination and resume state**

Append. `state_path` returns `folder / ".state.json"`; `load_state` returns an empty `ResumeState` when the file is missing or corrupt, logging the reason; `save_state` keeps only the last 10 000 visited ids and writes atomically through a temporary file. `traverse` takes an optional `fetch(url) -> tuple[list[Post], str | None]` returning posts and the next cursor, defaulting to a real network fetch built from `url_for`. It runs the two phases from `FeedTraversal`: the nouveautés phase starts at `state.frontier` when `visited` is non-empty, and the history phase starts after the last visited id. It stops on an empty page (`empty`), a page whose id list was already seen (`repeated`), an invalid cursor (`cursor`), reaching `max_pages` (`max_pages`, complete only when it reached history), an explicit `limit` (`limit`), or `KeyboardInterrupt` (`cancelled`). A page's ids are added to `visited` only after `process` returns; an exception propagating from `process` leaves `visited` untouched. The checkpoint is the last committed cursor and is returned as `result.checkpoint`. `on_page(posts, index, total)` is called after each committed page for progress logging.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 64 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add feed traversal with resume state"
```

---

### Task 9: Téléchargement des médias

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append)
- Modify: `scripts/test_reddit_media_pocket.py` (append)

**Interfaces:**
- Consumes: `Media` from Task 4, `parse_dash` from Task 5, `HttpClient` from Task 6, `redgifs_candidates` from Task 4, `download_stem`/`unique_destination`/`extension_for` from Task 2, `original_image_url` from Task 4.
- Produces:
  - `REDGIFS_TOKEN_URL = "https://api.redgifs.com/v2/auth/temporary"`, `REDGIFS_API = "https://api.redgifs.com/v2/gifs"`
  - `TOKEN_TTL_SECONDS = 1800`
  - `@dataclass class Outcome: status: str; path: Path | None; detail: str` where `status` is `downloaded`, `skipped`, `failed`, `inaccessible`, `video_only` or `unsupported`.
  - `class RedgifsToken: get(client: HttpClient) -> str` — cached for 1800 s, one refresh on 401.
  - `class Downloader: def __init__(self, client: HttpClient, folder: Path, *, dry_run: bool = False)` and `def download(self, media: Media, post: Post, used: set[str]) -> Outcome`.
  - `def write_metadata(folder: Path, path: Path, post: Post, author: str) -> None`
  - `def has_ffmpeg() -> bool` and `def mux(video: Path, audio: Path, destination: Path) -> bool`.
  - `def gallery_media(gallery_id: str, client: HttpClient) -> list[Media]`.

- [ ] **Step 1: Write the failing tests**

```python
class DownloaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name) / "alice"
        self.folder.mkdir()
        self.downloader = rmp.Downloader(rmp.HttpClient(), self.folder)
        self.post = rmp.Post("t3_abc", "Mon titre", "", "2026-01-02T03:04:05Z",
                             "https://www.reddit.com/r/test/comments/abc/")

    def tearDown(self):
        self.tmp.cleanup()

    def test_direct_media_written_with_sidecar_and_dates(self):
        media = rmp.Media("https://x/ok.png", "direct", f"{self.base}/ok")
        outcome = self.downloader.download(media, self.post, set())
        self.assertEqual(outcome.status, "downloaded")
        self.assertTrue(outcome.path.exists())
        self.assertEqual(outcome.path.name, "Mon titre - abc.png")
        sidecar = self.folder / ".metadata" / f"{outcome.path.name}.json"
        self.assertTrue(sidecar.exists())
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
        self.assertEqual(payload["author"], "u/alice")
        self.assertEqual(payload["postDate"], "2026-01-02T03:04:05Z")
        self.assertEqual(int(os.path.getmtime(outcome.path)), 1767322 * 10**6 // 10**6)

    def test_existing_file_is_skipped(self):
        media = rmp.Media("https://x/ok.png", "direct", f"{self.base}/ok")
        first = self.downloader.download(media, self.post, set())
        second = rmp.Downloader(rmp.HttpClient(), self.folder).download(
            media, self.post, {first.path.name.lower()})
        self.assertEqual(second.status, "skipped")

    def test_missing_media_is_inaccessible(self):
        media = rmp.Media("https://x/missing.png", "direct", f"{self.base}/missing")
        self.assertEqual(self.downloader.download(media, self.post, set()).status,
                         "inaccessible")

    def test_dry_run_writes_nothing(self):
        downloader = rmp.Downloader(rmp.HttpClient(), self.folder, dry_run=True)
        media = rmp.Media("https://x/ok.png", "direct", f"{self.base}/ok")
        self.assertEqual(downloader.download(media, self.post, set()).status, "downloaded")
        self.assertEqual(list(self.folder.iterdir()), [])

    def test_unsupported_host_is_reported(self):
        media = rmp.Media("https://x/a", "direct", "https://other.example/a.png")
        self.assertEqual(self.downloader.download(media, self.post, set()).status, "unsupported")

    def test_mux_helper_reports_failure_without_ffmpeg(self):
        self.assertIsInstance(rmp.has_ffmpeg(), bool)

    def test_metadata_folder_is_hidden_from_gallery(self):
        media = rmp.Media("https://x/ok.png", "direct", f"{self.base}/ok")
        self.downloader.download(media, self.post, set())
        self.assertTrue((self.folder / ".metadata").is_dir())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'Downloader'`

- [ ] **Step 3: Implement the downloader**

Append. `Downloader.download` dispatches on `media.kind`. `direct` rejects any host outside `i.redd.it` and `i.imgur.com` as `unsupported`, then calls `original_image_url`, streams the body to a temporary file in the folder, validates the content type against `image/`, `video/`, `audio/` and `application/octet-stream`, renames it through `unique_destination`, writes the sidecar with `write_metadata`, and applies the post publication date to the file's creation and modification times. An existing destination yields `skipped`. A 403, 404 or 410 yields `inaccessible` with the status in `detail`; a `TransientError` yields `failed` after three attempts spaced 2 s then 4 s; `LimitedError` propagates so the session stops. `reddit_video` fetches `https://v.redd.it/<id>/DASHPlaylist.mpd`, calls `parse_dash`, downloads the video track to a temporary file, and when an audio track exists downloads it too, then calls `mux`; when `mux` returns False because ffmpeg is absent or fails, the video-only file is kept, a warning is logged and the status is `video_only`. `redgifs` calls `RedgifsToken.get`, requests `f"{REDGIFS_API}/{media.url.split(':', 1)[1]}?views=yes"` with the `Authorization`, `Referer`, `Origin` and `x-customheader` headers, builds candidates with `redgifs_candidates` from `urls.hd` and `urls.sd`, and tries each in order, moving to the next only on 403, 404 or 410, while 429 and transient errors abort. `RedgifsToken` caches the token with a monotonic deadline of 1800 s and, on a 401 response, invalidates and retries exactly once. `write_metadata` writes `downloadedAt` in ISO 8601, `postDate`, `author` and `postLink` to `<folder>/.metadata/<filename>.json`. `gallery_media` requests `https://www.reddit.com/comments/<id>.json?raw_json=1&limit=1`, walks `gallery_data.items` in order, resolves each id through `media_metadata` keeping only `status == "valid"`, and rebuilds images as `https://i.redd.it/<stem>.<ext>` with the extension from the MIME type, mapping `s.u` or `s.gif` for images and `s.dashUrl` into `reddit_video` media. Every attempt, refusal, candidate order and skip reason is logged at debug level, with URLs and statuses named.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: PASS, 72 tests

- [ ] **Step 5: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py
git commit -m "Add media downloader with DASH, RedGIFs and gallery support"
```

---

### Task 10: Orchestration, résumé et documentation

**Files:**
- Modify: `scripts/reddit_media_pocket.py` (append, then wire `main`)
- Modify: `scripts/test_reddit_media_pocket.py` (append)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above — `parse_args`, `setup_logging`, `parse_source`, `feed_url`, `traverse`, `Downloader`, `run_oauth_flow`, `parse_cookies_file`, `saved_feed_from_html`, `TokenStore`, `state_path`, `source_folder`, `download_stem`.
- Produces:
  - `@dataclass class Session: folder: Path; totals: dict[str, int]`
  - `def record(session: Session, status: str) -> None`
  - `def exceeds_error_budget(errors: int, max_errors: int) -> bool` — `True` when `max_errors` is 0 (unlimited) or when `errors` has reached it.
  - `def run_session(args: argparse.Namespace) -> int` — the whole pipeline, returns the process exit code.
  - `def summarize(session: Session, result: TraversalResult, elapsed: float) -> None`
  - `main(argv)` now dispatches to `run_session` and returns its code.

- [ ] **Step 1: Write the failing tests**

```python
class SessionTests(unittest.TestCase):
    def test_missing_subreddit_reports_error_code(self):
        with tempfile.TemporaryDirectory() as d:
            args = rmp.parse_args(["r/definitely_absent_subreddit_zzz", "--out", d,
                                   "--max-pages", "1"])
            with self.assertLogs("reddit_media_pocket", level="ERROR"):
                code = rmp.run_session(args)
            self.assertEqual(code, 2)

    def test_saved_without_session_reports_error_code(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["LOCALAPPDATA"] = d
            args = rmp.parse_args(["saved", "--out", d, "--max-pages", "1"])
            with self.assertLogs("reddit_media_pocket", level="ERROR"):
                self.assertEqual(rmp.run_session(args), 2)

    def test_concurrency_is_clamped_and_logged(self):
        session = rmp.Session(folder=Path("x"), totals={})
        rmp.record(session, "downloaded")
        self.assertEqual(session.totals["downloaded"], 1)

    def test_max_errors_stops_the_session(self):
        self.assertTrue(rmp.exceeds_error_budget(3, 3))
        self.assertTrue(rmp.exceeds_error_budget(3, 0))
        self.assertFalse(rmp.exceeds_error_budget(0, 3))
        self.assertFalse(rmp.exceeds_error_budget(2, 3))


class SummaryTests(unittest.TestCase):
    def test_summary_mentions_every_counter(self):
        with tempfile.TemporaryDirectory() as d:
            session = rmp.Session(folder=Path(d), totals={
                "downloaded": 2, "skipped": 1, "failed": 0, "inaccessible": 1,
                "video_only": 0, "unsupported": 0})
            result = rmp.TraversalResult(pages=3, stopped="history", complete=True,
                                         checkpoint=None)
            with self.assertLogs("reddit_media_pocket", level="INFO") as ctx:
                rmp.summarize(session, result, 12.5)
            text = "\n".join(ctx.output)
            for token in ["téléchargés", "ignorés", "inaccessibles", "pages", "raison"]:
                self.assertIn(token, text)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s scripts -p 'test_reddit_media_pocket.py' -v`
Expected: FAIL with `AttributeError: module 'reddit_media_pocket' has no attribute 'run_session'`

- [ ] **Step 3: Implement orchestration**

Append `Session`, `record`, `exceeds_error_budget`, `run_session` and `summarize`, then replace `main` with one that calls `run_session` and returns its code. `run_session` sets up logging first, resolves the source, builds the folder, loads the resume state only when `--resume` is given, and selects the URL builder: `feed_url` for a profile or subreddit; for `saved`, a stored OAuth token refreshed as needed and `f"{API_BASE}/user/{me}/saved?limit=100&after=…"`, or, when no token is available, cookies from `--cookies` followed by `saved_feed_from_html` to learn the owner and the private feed, failing with exit code 2 when neither is available. It then runs `traverse` with a `process` callback that extracts media from each post, expands a gallery when one is present, deduplicates by `Media.key` across the run, skips files already on disk, and dispatches to a `ThreadPoolExecutor` with `max_workers=args.concurrent`, each task calling `Downloader.download` and returning its `Outcome`; each returned outcome is passed to `record`, and once `exceeds_error_budget(session.totals.get("failed", 0) + session.totals.get("inaccessible", 0), args.max_errors)` is true the traversal's stop event is set and the loop ends with a logged reason naming the limit. A `LimitedError` from any task sets a stop event that cancels the remaining work and ends the session with exit code 3, while other failures are counted. `KeyboardInterrupt` cancels the executor, cleans temporary files, logs the interruption and still writes the summary. `summarize` logs posts traversed, media downloaded, skipped, failed, inaccessible, video-only, unsupported, bytes written, elapsed seconds, the stop reason, the completeness flag, and the log file path. `main` catches `LimitedError` and `ValueError` from `parse_source` to log and return 2, and 429 exhaustion to return 3.

- [ ] **Step 4: Document the script in the README**

Append a section to `README.md` titled `## Script Python Windows` describing: the one-file location `scripts/reddit_media_pocket.py`, the `python scripts/reddit_media_pocket.py r/test --limit 3 --verbose` invocation, the source forms `u/<pseudo>`, `r/<subreddit>` and `saved`, the `--sort`, `--out`, `--concurrent`, `--limit`, `--resume`, `--dry-run` and `--cookies` options, where the log file is written and what it contains, that ffmpeg is optional and only used to join a v.redd.it video with its audio, and that the first `saved` run opens the browser to authorise the account while later runs reuse the token in `%LOCALAPPDATA%\RedditMediaPocket\token.json`.

- [ ] **Step 5: Run the full Python suite and confirm the earlier tests still pass**

Run: `python -m unittest discover -s scripts -p 'test_*.py' -v`
Expected: PASS, every test including the pre-existing `SourceTests`

- [ ] **Step 6: Smoke-test the CLI end to end against a real subreddit**

Run: `python scripts/reddit_media_pocket.py r/test --limit 2 --verbose --out <dossier temporaire>`
Expected: exit 0, two files written, and a `logs/reddit_*.log` file containing one block per HTTP request with its status and headers. Paste the last 30 lines of that log if anything diverges.

- [ ] **Step 7: Commit**

```bash
git add scripts/reddit_media_pocket.py scripts/test_reddit_media_pocket.py README.md
git commit -m "Add session orchestration, final summary and Windows script docs"
```

---

## Verification finale

Run after the last task:

- `python -m unittest discover -s scripts -p 'test_*.py' -v` — all tests pass, `SourceTests` included.
- `python scripts/reddit_media_pocket.py r/test --limit 2 --verbose` — a real run completes and the log explains every request.
- `git status` — no untracked file outside `scripts/` and `docs/superpowers/`.
- The nine manual checks listed under `## Tests` in the spec remain to be run on a machine with a working Reddit session: the DASH video with and without ffmpeg, the RedGIFs HD-to-SD fallback, the `saved` OAuth round trip, an interrupted page then resume, two consecutive runs skipping files, the name conflict suffix, and the two invalid-source messages. Those checks need a real account and a real network, so they are not automated here.
