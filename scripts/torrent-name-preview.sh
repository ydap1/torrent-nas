#!/bin/bash
# Usage: torrent-name-preview.sh "Torrent.Name.2026.720p.WEB-DL.mkv"
# Prints the folder and file name that torrent-done.sh would create.

if [ -z "$1" ]; then
    echo "Usage: $0 \"Torrent.Name.2026.720p.WEB-DL.mkv\"" >&2
    exit 1
fi

TORRENT_NAME="$1"

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

tmdb_lookup() {
    local title="$1" year="$2"

    if [ -z "${TMDB_API_KEY:-}" ]; then
        echo "[tmdb] TMDB_API_KEY not set, skipping." >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "[tmdb] jq not available, skipping." >&2
        return 1
    fi

    local encoded
    encoded=$(printf '%s' "$title" | jq -Rr @uri)
    local url="https://api.themoviedb.org/3/search/movie?api_key=${TMDB_API_KEY}&query=${encoded}&language=en-US&include_adult=false"
    [ -n "$year" ] && url="${url}&year=${year}"

    echo "[tmdb] querying '${title}'${year:+ ($year)}" >&2

    local response
    response=$(curl -sf --max-time 10 --retry 2 --retry-delay 3 "$url" 2>/dev/null) || true

    if [ -z "$response" ]; then
        echo "[tmdb] no response." >&2; return 1
    fi
    if echo "$response" | jq -e '.status_code' &>/dev/null; then
        echo "[tmdb] API error: $(echo "$response" | jq -r '.status_message')" >&2; return 1
    fi

    local total
    total=$(echo "$response" | jq -r '.total_results // 0')
    if [ "${total:-0}" -eq 0 ]; then
        echo "[tmdb] no results." >&2; return 1
    fi

    local orig_title eng_title orig_lang release_year chosen_title
    orig_title=$(echo "$response"   | jq -r '.results[0].original_title // ""')
    eng_title=$(echo "$response"    | jq -r '.results[0].title // ""')
    orig_lang=$(echo "$response"    | jq -r '.results[0].original_language // "en"')
    release_year=$(echo "$response" | jq -r '.results[0].release_date // ""' \
                   | grep -oE '[0-9]{4}' | head -1)

    if [ "$orig_lang" != "en" ] && [ -n "$orig_title" ]; then
        chosen_title="$orig_title"
        echo "[tmdb] non-English ($orig_lang), using original_title: '$chosen_title'" >&2
    else
        chosen_title="$eng_title"
        echo "[tmdb] matched: '$chosen_title'" >&2
    fi

    printf '%s|%s\n' "$chosen_title" "$release_year"
}

sanitize_name() {
    echo "$1" | sed 's/[:/\*?"<>|]//g' | tr -s ' ' | sed 's/^ //;s/ $//'
}

IFS='|' read -r parsed_title parsed_year <<< "$(parse_name "$TORRENT_NAME")"
echo "[parse] title='$parsed_title' year='${parsed_year:-none}'" >&2

folder_name=""
if tmdb_result=$(tmdb_lookup "$parsed_title" "$parsed_year"); then
    IFS='|' read -r tmdb_title tmdb_year <<< "$tmdb_result"
    [ -n "$tmdb_title" ] && folder_name="${tmdb_title}${tmdb_year:+ ($tmdb_year)}"
fi

if [ -z "$folder_name" ]; then
    echo "[fallback] using parsed name" >&2
    folder_name="$(title_case "$parsed_title")${parsed_year:+ ($parsed_year)}"
fi

folder_name=$(sanitize_name "$folder_name")

ext="${TORRENT_NAME##*.}"
is_dir=false
[ "${ext}" = "${TORRENT_NAME}" ] && is_dir=true  # no extension = likely a directory

echo "Folder : $folder_name"
if [ "$is_dir" = false ]; then
    echo "File   : ${folder_name}.${ext}"
fi
