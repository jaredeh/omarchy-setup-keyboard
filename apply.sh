#!/bin/bash
# apply.sh — write the calibrated repeat_delay into ~/.config/hypr/input.lua.
#
# Called by Calibrate.qml with the value the user confirmed. Kept in bash
# because it is file manipulation that must survive the overlay closing.
#
#   apply.sh 430        write the managed block and reload
#   apply.sh --reset    remove the managed block, fall back to the default
#   apply.sh --show     print the current managed value, if any

set -o pipefail

INPUT_LUA="${HOME}/.config/hypr/input.lua"
BEGIN="-- >>> omarchy:keyboard-repeat (managed — edits here are overwritten)"
END="-- <<< omarchy:keyboard-repeat"

fail() { echo "apply.sh: $*" >&2; exit 1; }

[[ -f $INPUT_LUA ]] || fail "not found: $INPUT_LUA"

# Strip any existing managed block to a temp file. Doing this unconditionally
# is what makes re-running idempotent: a second calibration replaces the block
# rather than stacking another hl.config() that silently shadows the first.
strip_block() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$INPUT_LUA"
}

case "${1:-}" in
  --show)
    # Note the `--` on every grep: the block markers begin with "--", which
    # grep would otherwise parse as options.
    if grep -qF -- "$BEGIN" "$INPUT_LUA"; then
      awk -v b="$BEGIN" -v e="$END" '
        $0 == b { inblock = 1; next }
        $0 == e { inblock = 0 }
        inblock && match($0, /repeat_delay = [0-9]+/) {
          s = substr($0, RSTART, RLENGTH); sub(/[^0-9]+/, "", s); print s
        }
      ' "$INPUT_LUA"
    else
      echo "none"
    fi
    exit 0
    ;;
  --reset)
    tmp=$(mktemp) || fail "mktemp failed"
    strip_block > "$tmp" || fail "failed to rewrite config"
    # Trim trailing blank lines left behind by the removal.
    printf '%s\n' "$(< "$tmp")" > "$tmp.2" && mv "$tmp.2" "$tmp"
    cp -f "$tmp" "$INPUT_LUA" || fail "failed to write $INPUT_LUA"
    rm -f "$tmp"
    hyprctl reload >/dev/null
    echo "removed managed block; reverted to the Omarchy default"
    exit 0
    ;;
esac

value="${1:-}"
[[ $value =~ ^[0-9]+$ ]] || fail "expected a millisecond value, got '${value:-<none>}'"
(( value >= 100 && value <= 2000 )) || fail "value out of range (100-2000): $value"

backup="${INPUT_LUA}.bak.$(date +%s%N)"
cp -f "$INPUT_LUA" "$backup" || fail "could not back up $INPUT_LUA"

tmp=$(mktemp) || fail "mktemp failed"
{
  strip_block
  printf '\n%s\n' "$BEGIN"
  printf 'hl.config({ input = { repeat_delay = %s } })\n' "$value"
  printf '%s\n' "$END"
} > "$tmp" || fail "failed to compose new config"

cp -f "$tmp" "$INPUT_LUA" || fail "failed to write $INPUT_LUA"
rm -f "$tmp"

hyprctl reload >/dev/null

# hyprctl reload exits 0 even when the config it read is broken, so confirm the
# value actually took rather than trusting the status.
live=$(hyprctl getoption input:repeat_delay -j 2>/dev/null | grep -oE '"int": *[0-9]+' | grep -oE '[0-9]+')
if [[ $live != "$value" ]]; then
  cp -f "$backup" "$INPUT_LUA"
  hyprctl reload >/dev/null
  fail "value did not take (live=${live:-unknown}); restored from $backup"
fi

echo "repeat_delay = ${value}ms   backup: ${backup/#$HOME/\~}"
