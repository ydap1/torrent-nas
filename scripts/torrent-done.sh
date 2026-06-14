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
    cleaned="${cleaned//./ }"
    cleaned="${cleaned//_/ }"
    cleaned=$(echo "$cleaned" | tr -d '()[]{}')
    cleaned=$(echo "$cleaned" | tr -s ' ')

    year=$(echo "$cleaned" | grep -oE '(19|20)[0-9]{2}' | head -1)

    if [ -n "$year" ]; then
        title=$(echo "$cleaned" | sed -E "s/ $year( .*)?$//")
    else
        title="$cleaned"
    fi

    title=$(echo "$title" | tr '[:upper:]' '[:lower:]')

    for tag in dvdrip bdrip bluray "blu ray" webrip "web dl" web hdtv pdtv \
               cam scr r5 dvdscr hdrip hevc avc xvid divx remux proper repack \
               extended theatrical unrated retail limited ntsc pal multi dubbed \
               subbed by ts; do
        title=$(echo "$title" | sed "s/ $tag / /g; s/ $tag$//; s/^$tag //")
    done

    title=$(echo "$title" | sed -E 's/ [0-9]+(mb|gb)//g')
    title=$(echo "$title" | tr -s ' ' | sed 's/^ //;s/ $//')

    printf '%s|%s\n' "$title" "$year"
}

title_case() {
    echo "$1" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}'
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

    local encoded
    encoded=$(printf '%s' "$title" | jq -Rr @uri)

    local url="https://api.themoviedb.org/3/search/movie?api_key=${TMDB_API_KEY}&query=${encoded}&language=en-US&include_adult=false"
    [ -n "$year" ] && url="${url}&year=${year}"

    log "TMDB: querying '${title}'${year:+ ($year)}"

    local response
    response=$(curl -sf --max-time 10 --retry 2 --retry-delay 3 "$url" 2>/dev/null) || true

    if [ -z "$response" ]; then
        log "TMDB: no response (network error or timeout)."
        return 1
    fi

    if echo "$response" | jq -e '.status_code' &>/dev/null; then
        log "TMDB: API error – $(echo "$response" | jq -r '.status_message // "unknown"')"
        return 1
    fi

    local total
    total=$(echo "$response" | jq -r '.total_results // 0')
    if [ "${total:-0}" -eq 0 ]; then
        log "TMDB: no results found."
        return 1
    fi

    local orig_title eng_title orig_lang release_year chosen_title
    orig_title=$(echo "$response"   | jq -r '.results[0].original_title // ""')
    eng_title=$(echo "$response"    | jq -r '.results[0].title // ""')
    orig_lang=$(echo "$response"    | jq -r '.results[0].original_language // "en"')
    release_year=$(echo "$response" | jq -r '.results[0].release_date // ""' \
                   | grep -oE '[0-9]{4}' | head -1)

    if [ "$orig_lang" != "en" ] && [ -n "$orig_title" ]; then
        chosen_title="$orig_title"
        log "TMDB: non-English ($orig_lang), using original_title: '$chosen_title' ($release_year)"
    else
        chosen_title="$eng_title"
        log "TMDB: using title: '$chosen_title' ($release_year)"
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
