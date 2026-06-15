#!/bin/bash

TORRENT_NAME="$1"
SRC="/downloads/$TORRENT_NAME"
LOG="/config/torrent-transfer.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "----------------------------------------"
log "Triggered for: $TORRENT_NAME"

# ── Preflight checks ──────────────────────────────────────────────────────────

if ! mountpoint -q /mnt/nas; then
    log "ERROR: NAS not mounted, aborting."
    exit 1
fi

if [ ! -e "$SRC" ]; then
    log "ERROR: Source not found: $SRC"
    exit 1
fi

# ── Ensure jq is available ────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    log "jq not found, attempting install..."
    if command -v apk &>/dev/null; then
        apk add --quiet --no-cache jq 2>>"$LOG" || log "WARNING: apk install of jq failed."
    elif command -v apt-get &>/dev/null; then
        apt-get install -y -qq jq 2>>"$LOG" || log "WARNING: apt-get install of jq failed."
    else
        log "WARNING: No known package manager, cannot install jq."
    fi
fi

# ── Parse raw torrent name → title + year ─────────────────────────────────────

parse_name() {
    local raw="$1"
    local cleaned title year

    cleaned="${raw%.*}"
    # Replace [Group] tags with a space so adjacent words don't merge
    cleaned=$(echo "$cleaned" | sed 's/\[[^]]*\]/ /g')
    # Pad (YYYY) with spaces before stripping parens so year stays separable
    cleaned=$(echo "$cleaned" | sed -E 's/\(((19|20)[0-9]{2})\)/ \1 /g')
    cleaned="${cleaned//./ }"
    cleaned="${cleaned//_/ }"
    cleaned=$(echo "$cleaned" | tr -d '()[]{}')
    cleaned=$(echo "$cleaned" | tr -s ' ' | sed 's/^ //;s/ $//')

    year=$(echo "$cleaned" | grep -oE '(19|20)[0-9]{2}' | head -1)

    if [ -n "$year" ]; then
        title=$(echo "$cleaned" | sed -E "s/ $year( .*)?$//")
    else
        title="$cleaned"
    fi

    title=$(echo "$title" | tr '[:upper:]' '[:lower:]')

    for tag in dvdrip bdrip bluray "blu ray" webrip "web dl" web hdtv pdtv \
               dvb dvbrip cam scr r5 dvdscr hdrip hevc avc xvid divx remux \
               proper repack extended theatrical unrated retail limited ntsc \
               pal multi dubbed subbed by ts mm; do
        title=$(echo "$title" | sed "s/ $tag / /g; s/ $tag$//; s/^$tag //")
    done

    title=$(echo "$title" | sed -E 's/ [0-9]+(mb|gb)//g')
    title=$(echo "$title" | tr -s ' ' | sed 's/^ //;s/ $//')

    printf '%s|%s\n' "$title" "$year"
}

title_case() {
    echo "$1" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}'
}

# Reverse transliteration: Latin → Cyrillic (Russian torrent scene conventions).
# Multi-char sequences are processed first (longest match wins), then single chars.
# 'y' after a vowel → й (e.g. -oy, -ay); 'y' elsewhere → ы.
transliterate_ru() {
    echo "$1" | sed \
        -e 's/shch/щ/g' \
        -e 's/sch/щ/g'  \
        -e 's/zh/ж/g'   \
        -e 's/kh/х/g'   \
        -e 's/ts/ц/g'   \
        -e 's/ch/ч/g'   \
        -e 's/sh/ш/g'   \
        -e 's/ya/я/g' -e 's/ja/я/g' \
        -e 's/yu/ю/g' -e 's/ju/ю/g' \
        -e 's/yo/ё/g' -e 's/jo/ё/g' \
        -e 's/ye/е/g'   \
        -e 's/\([aeiouаеиоуёяюэ]\)y/\1й/g' \
        -e 's/y/ы/g'    \
        -e 's/a/а/g' -e 's/b/б/g' -e 's/v/в/g' \
        -e 's/g/г/g' -e 's/d/д/g' -e 's/e/е/g' \
        -e 's/z/з/g' -e 's/i/и/g' -e 's/k/к/g' \
        -e 's/l/л/g' -e 's/m/м/g' -e 's/n/н/g' \
        -e 's/o/о/g' -e 's/p/п/g' -e 's/r/р/g' \
        -e 's/s/с/g' -e 's/t/т/g' -e 's/u/у/g' \
        -e 's/f/ф/g' -e 's/x/х/g'
}

# ── TMDB API lookup ───────────────────────────────────────────────────────────

tmdb_lookup() {
    local title="$1"
    local year="$2"

    if [ -z "${TMDB_API_KEY:-}" ]; then
        log "TMDB: TMDB_API_KEY not set, skipping lookup."
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        log "TMDB: jq unavailable, skipping lookup."
        return 1
    fi

    local encoded base_url response total
    encoded=$(printf '%s' "$title" | jq -Rr @uri)
    base_url="https://api.themoviedb.org/3/search/movie?api_key=${TMDB_API_KEY}&language=en-US&include_adult=false"

    # Attempt 1: title + year
    local url="${base_url}&query=${encoded}"
    [ -n "$year" ] && url="${url}&year=${year}"
    log "TMDB: querying '${title}'${year:+ ($year)}"
    response=$(curl -sf --max-time 10 --retry 2 --retry-delay 3 "$url" 2>/dev/null) || true

    if [ -z "$response" ]; then
        log "TMDB: no response (network error or timeout)."
        return 1
    fi
    if echo "$response" | jq -e '.status_code' &>/dev/null; then
        log "TMDB: API error – $(echo "$response" | jq -r '.status_message // "unknown"')"
        return 1
    fi
    total=$(echo "$response" | jq -r '.total_results // 0')

    # Attempt 2: title without year
    if [ "${total:-0}" -eq 0 ] && [ -n "$year" ]; then
        log "TMDB: no results with year, retrying without..."
        response=$(curl -sf --max-time 10 "${base_url}&query=${encoded}" 2>/dev/null) || true
        total=$(echo "$response" | jq -r '.total_results // 0')
    fi

    # Attempts 3+4: reverse transliteration (only for all-Latin titles)
    if [ "${total:-0}" -eq 0 ] && echo "$title" | grep -qE '^[a-z ]+$'; then
        local cyrillic_title cyrillic_encoded
        cyrillic_title=$(transliterate_ru "$title")
        cyrillic_encoded=$(printf '%s' "$cyrillic_title" | jq -Rr @uri)
        log "TMDB: trying transliteration: '$cyrillic_title'"

        # Attempt 3: cyrillic + year
        local url_cyr="${base_url}&query=${cyrillic_encoded}"
        [ -n "$year" ] && url_cyr="${url_cyr}&year=${year}"
        response=$(curl -sf --max-time 10 "$url_cyr" 2>/dev/null) || true
        total=$(echo "$response" | jq -r '.total_results // 0')

        # Attempt 4: cyrillic without year
        if [ "${total:-0}" -eq 0 ] && [ -n "$year" ]; then
            log "TMDB: transliteration without year..."
            response=$(curl -sf --max-time 10 "${base_url}&query=${cyrillic_encoded}" 2>/dev/null) || true
            total=$(echo "$response" | jq -r '.total_results // 0')
        fi
    fi

    if [ "${total:-0}" -eq 0 ]; then
        log "TMDB: no results found."
        return 1
    fi

    local movie_id orig_title eng_title orig_lang release_year chosen_title
    movie_id=$(echo "$response"     | jq -r '.results[0].id // ""')
    orig_title=$(echo "$response"   | jq -r '.results[0].original_title // ""')
    eng_title=$(echo "$response"    | jq -r '.results[0].title // ""')
    orig_lang=$(echo "$response"    | jq -r '.results[0].original_language // "en"')
    release_year=$(echo "$response" | jq -r '.results[0].release_date // ""' \
                   | grep -oE '[0-9]{4}' | head -1)

    # Fetch Russian translation from the translations endpoint
    local ru_title=""
    if [ -n "$movie_id" ]; then
        local trans
        trans=$(curl -sf --max-time 10 \
            "https://api.themoviedb.org/3/movie/${movie_id}/translations?api_key=${TMDB_API_KEY}" \
            2>/dev/null) || true
        ru_title=$(echo "$trans" | jq -r \
            '[.translations[] | select(.iso_639_1 == "ru") | .data.title] | map(select(. != "")) | first // ""' \
            2>/dev/null)
    fi

    # Priority: Russian translation > original title (non-English) > English title
    if [ -n "$ru_title" ]; then
        chosen_title="$ru_title"
        log "TMDB: using Russian translation: '$chosen_title' ($release_year)"
    elif [ "$orig_lang" != "en" ] && [ -n "$orig_title" ]; then
        chosen_title="$orig_title"
        log "TMDB: non-English ($orig_lang), using original_title: '$chosen_title' ($release_year)"
    else
        chosen_title="$eng_title"
        log "TMDB: using English title: '$chosen_title' ($release_year)"
    fi

    printf '%s|%s\n' "$chosen_title" "$release_year"
    return 0
}

# ── Sanitize name for filesystem / SMB ───────────────────────────────────────

sanitize_name() {
    echo "$1" | sed 's/[:/\*?"<>|]//g' | tr -s ' ' | sed 's/^ //;s/ $//'
}

# ── Build destination folder name ─────────────────────────────────────────────

IFS='|' read -r parsed_title parsed_year <<< "$(parse_name "$TORRENT_NAME")"
log "Parsed: title='$parsed_title' year='${parsed_year:-none}'"

folder_name=""
if tmdb_result=$(tmdb_lookup "$parsed_title" "$parsed_year"); then
    IFS='|' read -r tmdb_title tmdb_year <<< "$tmdb_result"
    if [ -n "$tmdb_title" ]; then
        folder_name="${tmdb_title}${tmdb_year:+ ($tmdb_year)}"
    fi
fi

if [ -z "$folder_name" ]; then
    log "Using parsed fallback name."
    folder_name="$(title_case "$parsed_title")${parsed_year:+ ($parsed_year)}"
fi

folder_name=$(sanitize_name "$folder_name")
log "Destination folder: '$folder_name'"

DEST="/mnt/nas/torrents/${folder_name}/"

# ── Transfer ──────────────────────────────────────────────────────────────────

log "Starting transfer to $DEST"
mkdir -p "$DEST"

if [ -d "$SRC" ]; then
    rsync -av --progress --stats --human-readable --remove-source-files "$SRC/" "$DEST" 2>&1 | tee -a "$LOG"
else
    # Single file: rename to match folder name, preserving extension
    ext="${TORRENT_NAME##*.}"
    dest_file="${DEST}${folder_name}.${ext}"
    log "Renaming file to: '${folder_name}.${ext}'"
    rsync -av --progress --stats --human-readable --remove-source-files "$SRC" "$dest_file" 2>&1 | tee -a "$LOG"
fi
EXIT_CODE=${PIPESTATUS[0]}

if [ "$EXIT_CODE" -eq 0 ]; then
    log "SUCCESS: '$TORRENT_NAME' transferred to '$folder_name'."
    if [ -d "$SRC" ]; then
        find "$SRC" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        rmdir "$SRC" 2>/dev/null || true
    fi
    exit 0
else
    log "FAILED: rsync exited with code $EXIT_CODE"
    exit "$EXIT_CODE"
fi
