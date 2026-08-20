#!/usr/bin/env bash
# Show what resolve_name.py would call each release, without transferring.
#
#   ./name-preview.sh "Some.Release.2010.1080p.BluRay.x264.mkv"
#   ./name-preview.sh --stdin < list-of-release-names.txt
set -uo pipefail

RESOLVER="$(dirname "$0")/resolve_name.py"

preview() {
    local raw="$1" parsed resolved title year
    parsed=$(python3 "$RESOLVER" --parse-only "$raw" | cut -f1)
    if resolved=$(python3 "$RESOLVER" "$raw" 2>/dev/null); then
        title=$(printf '%s' "$resolved" | cut -f1)
        year=$(printf '%s' "$resolved" | cut -f2)
        printf '%-52s | parsed: %-28s | -> %s%s\n' "${raw:0:52}" "${parsed:0:28}" \
               "$title" "${year:+ ($year)}"
    else
        printf '%-52s | parsed: %-28s | -> (no confident match, keeps legacy name)\n' \
               "${raw:0:52}" "${parsed:0:28}"
    fi
}

if [ "${1:-}" = "--stdin" ]; then
    while IFS= read -r line; do [ -n "$line" ] && preview "$line"; done
else
    [ $# -eq 0 ] && { echo "usage: $0 <release-name> | --stdin" >&2; exit 2; }
    for arg in "$@"; do preview "$arg"; done
fi
