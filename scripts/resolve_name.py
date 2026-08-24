#!/usr/bin/env python3
"""Resolve a torrent release name to a confident library folder name.

Replaces the shell parser's two weakest behaviours:

  * It subtracted a fixed list of tags with word-boundary matching, so anything
    glued together (`Amadeus.BDRip1080p`), bracketed (`[anti-raws]Mononoke
    Hime`), suffixed after a dash (`...2160p-sofcj`) or abbreviated (`Cc` for
    Criterion, `Kp` for Kinopoisk) survived into the folder name. Twenty-eight
    titles on the NAS still carry that debris. Instead of subtracting known
    tags, this finds where the *title ends* - at the first year or metadata
    token - so unfamiliar tags are dropped too.

  * It accepted `.results[0]` from TMDB unconditionally, with no measure of
    whether the result resembled the query. That is how `Zerkalo.1974` became
    `Кривое зеркало (2018)`. Every candidate here is scored on title similarity
    and year agreement, and a weak best result is rejected rather than used.

Film and television are both searched: a series arrives named the way a film
does, and the film index alone returns nothing for one, which sent it to the
caller's unscored lookup instead.

Prints "<title>\\t<year>" and exits 0 on a confident match; exits 1 otherwise so
the caller can fall back to its own logic. Standard library only: this runs
inside the qBittorrent container, which has no third-party packages.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import sys
import unicodedata
import urllib.parse
import urllib.request

API = "https://api.themoviedb.org/3"
TIMEOUT = 15

# Ordered longest-first so `bdrip` wins over `bd` and leaves nothing behind.
BOUNDARY = r"""(?:
    web-?dl | webrip | webdl | bluray | blu-?ray | bdremux | bdrip | bdmux |
    hddvdrip | hddvd | dvdrip | dvdscr | dvbrip | brrip | hdrip | tvrip |
    satrip | vhsrip | multisubs? | remastered | anniversary | dualaudio |
    criterion | rutracker | torrents | ai_?upscale | upscale | kinozal |
    uindex | itunes | atmos | truehd | complete | internal | repack | proper |
    edition | limited | rerip | amzn | hmax | dsnp | hdtv | pdtv | wiki |
    hevc | xvid | divx | flac | opus | dts(?:-?hd)?(?:-?ma)? | ddp?\d? |
    aac\d? | ac3 | mp3 | hdr10\+? | hdr\d* | sdr | uhd | \d{3,4}p | 2160 |
    1080i? | 720i? | 480i? | x\.?26[45] | h\.?26[45] | vc-?1 | av1 | mpeg\d? |
    dvd\d? | dvb | dvd | avc | nf | ma | kp | cc | bd | br | dv | ts | rip |
    scr | cam | r5 | 4k | multi | dual
)"""

BOUNDARY_RE = re.compile(rf"(?<![a-z0-9]){BOUNDARY}(?![a-z0-9])", re.I | re.X)
GLUED_RE = re.compile(rf"^{BOUNDARY}", re.I | re.X)
YEAR_RE = re.compile(r"(?<!\d)(19\d{2}|20\d{2})(?!\d)")
BRACKETED = re.compile(r"[\[\(\{][^\]\)\}]*[\]\)\}]")
EXTENSION = re.compile(r"(?i)\.(mkv|mp4|avi|m4v|ts|m2ts|mov|wmv|mpg|mpeg|iso)$")
SEASON = re.compile(r"(?i)(?<![a-z0-9])s\d{1,2}(?:e\d{1,3})?(?![a-z0-9])")
# A season written as a bare trailing number, as in `Skam.01`. Only ever cut as
# a last resort: Rocky 2 and Ocean's 11 end the same way and mean it.
TRAILING_NUMBER = re.compile(r"\s+\d{1,2}$")
# A two-digit year written as an apostrophe suffix, e.g. "Подозрительные лица '95".
SHORT_YEAR = re.compile(r"['’](\d{2})\s*$")
ARTICLES = {"the", "a", "an", "of", "and"}

# Below this the best candidate is not trustworthy enough to rename a file by.
MIN_SCORE = 0.62


def is_all_metadata(word: str) -> bool:
    """Whether a word is nothing but metadata tokens run together.

    This is what lets `BDRip1080p` be removed while `Amadeus` survives: the
    former decomposes completely into known tokens, the latter does not. A
    plain substring match would find `ma` inside Amadeus and `cam` in Camera.
    """
    rest = word.strip("-_. ")
    while rest:
        hit = GLUED_RE.match(rest)
        if not hit or not hit.group(0):
            return False
        rest = rest[hit.end():].lstrip("-_. ")
    return True


def parse_release(raw: str) -> tuple[str, int | None]:
    """Best-effort (title, year) from a release name."""
    name = raw.strip().rstrip("/").rsplit("/", 1)[-1]
    name = EXTENSION.sub("", name)

    # Bracketed runs are group tags far more often than title text, but a name
    # that is entirely bracketed is the title itself.
    stripped = BRACKETED.sub(" ", name)
    if stripped.strip(" .-_"):
        name = stripped

    name = re.sub(r"[._]+", " ", name)
    name = re.sub(r"\s+", " ", name).strip()

    short = SHORT_YEAR.search(name)
    if short:
        name = name[: short.start()].strip()

    year_match = YEAR_RE.search(name)
    year = int(year_match.group(1)) if year_match else None
    if year is None and short:
        value = int(short.group(1))
        year = 1900 + value if value > 25 else 2000 + value

    cut = year_match.start() if year_match else len(name)
    boundary = BOUNDARY_RE.search(name)
    if boundary and boundary.start() < cut:
        cut = boundary.start()
        after = YEAR_RE.search(name, cut)
        year = int(after.group(1)) if after else year

    title = name[:cut]
    season = SEASON.search(title)
    if season:
        title = title[: season.start()]

    words = [w for w in re.sub(r"[-_]+", " ", title).split() if w]
    while words and is_all_metadata(words[-1]):
        words.pop()
    while len(words) > 1 and words[-1].lower() in ARTICLES:
        words.pop()
    return " ".join(words).strip(" -_.,"), year


# Cyrillic is romanised before comparison so a Latin release name can be scored
# against a Cyrillic original title. Without this "Brat" scores 0.0 against
# "Брат" - no shared characters - and loses to the unrelated "Brats".
CYRILLIC = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def romanise(text: str) -> str:
    return "".join(CYRILLIC.get(ch, ch) for ch in text)


def normalise(text: str) -> str:
    text = romanise(text.lower())
    text = unicodedata.normalize("NFKD", text)
    return re.sub(r"[^a-z0-9 ]+", " ", text).strip()


def score(query: str, year: int | None, cand_title: str, cand_original: str, cand_year: int | None) -> float:
    """Confidence that a candidate is the film the release name refers to."""
    q = normalise(query)
    best = 0.0
    for name in (cand_title, cand_original):
        if name:
            best = max(best, difflib.SequenceMatcher(None, q, normalise(name)).ratio())
    if year and cand_year:
        # An exact year is strong corroboration; being years apart is decisive
        # evidence against, which is the check the shell version never made.
        if year == cand_year:
            best = min(1.0, best + 0.15)
        elif abs(year - cand_year) > 1:
            best -= 0.35
    return max(0.0, best)


def request(path: str, params: dict[str, str]) -> dict:
    key = os.environ.get("TMDB_API_KEY", "")
    token = os.environ.get("TMDB_READ_TOKEN", "")
    if key:
        params = dict(params, api_key=key)
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token and not key:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
        return json.load(response)


# TMDB keeps films and television in separate endpoints that name the same
# fields differently. Everything below works on one shape so the scoring and
# ranking never have to know which kind it is holding.
FIELDS = {
    "movie": ("title", "original_title", "release_date", "year"),
    "tv": ("name", "original_name", "first_air_date", "first_air_date_year"),
}


def as_candidate(raw: dict, kind: str) -> dict:
    title_key, original_key, date_key, _ = FIELDS[kind]
    return {
        "id": int(raw.get("id")),
        "kind": kind,
        "title": raw.get(title_key) or "",
        "original_title": raw.get(original_key) or "",
        "year": int((raw.get(date_key) or "")[:4] or 0) or None,
        "votes": int(raw.get("vote_count") or 0),
    }


def search(query: str, year: int | None, language: str, kind: str = "movie") -> list[dict]:
    """Candidates of one kind, already in the common shape."""
    params = {"query": query, "language": language, "include_adult": "true"}
    if year:
        params[FIELDS[kind][3]] = str(year)
    try:
        results = request(f"/search/{kind}", params).get("results", []) or []
    except Exception:
        return []
    return [as_candidate(raw, kind) for raw in results]


def collect(scored: dict, query: str, year: int | None, query_year: int | None, language: str) -> None:
    """Score one query against both indexes, keeping each title's best result.

    Television is searched alongside film because a series arrives named exactly
    the way a film does, and the film index alone returns nothing for one.
    """
    for kind in ("movie", "tv"):
        for candidate in search(query, query_year, language, kind):
            value = score(query, year, candidate["title"],
                          candidate["original_title"], candidate["year"])
            key = (candidate["kind"], candidate["id"])
            previous = scored.get(key)
            if previous is None or value > previous[0]:
                scored[key] = (value, candidate["votes"], candidate)


def resolve(raw: str) -> tuple[str, int | None] | None:
    title, year = parse_release(raw)
    if not title:
        return None

    # Try the year both ways: a release name that needed heavy cleaning often
    # has an unreliable year too. Every title is retried in ru-RU, which is what
    # renders a film's Russian title where it can be compared to the query.
    attempts: list[tuple[str, int | None, str]] = [(title, year, "en-US")]
    if year:
        attempts.append((title, None, "en-US"))
    # ru-RU is tried for every title, not only Cyrillic ones: transliterated
    # Russian names like "Zerkalo" are only found by the Russian index, and an
    # English search returns nothing for them.
    attempts.append((title, year, "ru-RU"))
    attempts.append((title, None, "ru-RU"))

    # Keyed by film id, holding that film's *best* score across the attempts.
    # A film seen in one language is still worth scoring in the other: TMDB
    # answers a Cyrillic query from its alternative titles but returns them
    # rendered in the language asked for, so the en-US pass finds Black Swan
    # for "Черный лебедь" and scores it 0.17 against "Black Swan", while the
    # ru-RU pass scores the same film 1.00 against "Чёрный лебедь". Skipping
    # ids already seen kept the first of those and threw away the second,
    # which is how a file named in Russian resolved to nothing at all.
    scored: dict[tuple[str, int], tuple[float, int, dict]] = {}
    for query, query_year, language in attempts:
        collect(scored, query, year, query_year, language)
        # Stop as soon as an attempt yields a solid match. The ru-RU passes come
        # last and exist only to rescue transliterated names like "Zerkalo"
        # that English search cannot find; letting them run anyway lets an
        # unrelated Russian film outrank a good English one, which is how
        # The Conformist became ДАУ. Конформисты.
        if scored and max(s for s, _, _ in scored.values()) >= 0.8:
            break

    # `Skam.01` is a season, and TMDB returns nothing whatsoever for it - not a
    # weak match, nothing - so the caller fell back to its own unscored lookup
    # and filed three seasons of it as A Shame For Sweden 2. Dropping the number
    # is only safe once everything else has failed, since a film that ends in
    # one means it.
    if not scored or max(s for s, _, _ in scored.values()) < MIN_SCORE:
        shorter = TRAILING_NUMBER.sub("", title).strip()
        if shorter and shorter != title:
            for language in ("en-US", "ru-RU"):
                collect(scored, shorter, year, year, language)

    if not scored:
        return None
    # Rank on score, then on how well known the film is. Rounding first means a
    # trivial similarity difference does not outrank a far more likely title,
    # while a genuinely better match still wins outright.
    best_score, _, chosen = max(scored.values(), key=lambda row: (round(row[0], 2), row[1]))
    best = (best_score, chosen)

    if best is None or best[0] < MIN_SCORE:
        return None

    chosen = best[1]
    # A ru-RU search returns the title localised into Russian, so taking it
    # verbatim renamed English films to their Russian titles - Shawshank became
    # Побег из Шоушенка. Re-read the winner in en-US to get the canonical name,
    # then apply the library convention: Russian-language titles keep their
    # Cyrillic original, everything else uses the English one.
    title_key, original_key, date_key, _ = FIELDS[chosen["kind"]]
    try:
        detail = request(f"/{chosen['kind']}/{chosen['id']}", {"language": "en-US"})
    except Exception:
        detail = {}

    released = (detail.get(date_key) or "")[:4]
    final_year = int(released) if released.isdigit() else (chosen["year"] or year)

    if detail.get("original_language") == "ru" and detail.get(original_key):
        return detail[original_key], final_year
    return (detail.get(title_key) or chosen["title"] or title), final_year


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: resolve_name.py <release-name>", file=sys.stderr)
        return 2
    if sys.argv[1] == "--parse-only":
        title, year = parse_release(sys.argv[2])
        print(f"{title}\t{year or ''}")
        return 0

    result = resolve(sys.argv[1])
    if result is None:
        return 1
    title, year = result
    print(f"{title}\t{year or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
