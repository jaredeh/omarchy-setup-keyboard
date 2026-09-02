#!/bin/bash
# install.sh — install the plugin and register its Omarchy menu entry.
#
#   curl -fsSL https://raw.githubusercontent.com/jaredeh/omarchy-keyboard-setup/main/install.sh | bash
#   ./install.sh              install and register
#   ./install.sh --uninstall  remove both
#
# bash, not sh: this uses [[ ]], local, and ${var/#pat/rep}.
#
# Both directions are idempotent. The menu entry is written between markers so
# it can be removed again without disturbing anything else in the file.

set -o pipefail

REPO_URL="https://github.com/jaredeh/omarchy-keyboard-setup"
PLUGIN_ID="jaredeh.keyboard-calibration"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
MENU="${OMARCHY_MENU_FILE:-$HOME/.config/omarchy/extensions/omarchy-menu.jsonc}"
ICON="󰌌"   # nf-md-keyboard

BEGIN="  // >>> $PLUGIN_ID (managed by install.sh)"
END="  // <<< $PLUGIN_ID"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
fail() { printf '\033[31minstall.sh: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- menu entry

menu_has_entry() { [[ -f $MENU ]] && grep -qF -- "$BEGIN" "$MENU"; }

menu_strip_entry() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$MENU"
}

# JSONC minus its comments has to be valid JSON. jq is already a hard
# dependency of omarchy-plugin-add, so leaning on it here costs nothing.
menu_valid() {
  sed 's|//.*||' "$1" | jq empty >/dev/null 2>&1
}

# Emit the file with our entry inserted after the opening brace. Appending
# before the closing brace instead would mean adding a comma to whatever entry
# currently sits last — editing a line we do not own.
menu_compose() {
  awk -v b="$BEGIN" -v e="$END" -v id="$PLUGIN_ID" -v comma="$1" -v icon="$ICON" '
    !done && /^[[:space:]]*\{/ {
      print
      print b
      print "  \"setup.keyboard-repeat\": {"
      print "    \"icon\": \"" icon "\","
      print "    \"label\": \"Keyboard repeat\","
      print "    \"description\": \"Calibrate repeat delay from how you actually type\","
      print "    \"aliases\": [\"repeat-delay\", \"double-typing\", \"key-repeat\"],"
      print "    \"action\": \"omarchy-shell shell summon " id "\""
      print "  }" comma
      print e
      done = 1
      next
    }
    { print }
  ' "$MENU"
}

menu_add_entry() {
  mkdir -p "$(dirname "$MENU")"
  [[ -f $MENU ]] || printf '{\n}\n' > "$MENU"

  grep -q '^[[:space:]]*{' "$MENU" || fail "$MENU does not look like a JSONC object"
  menu_valid "$MENU" || fail "$MENU is not valid JSONC before we touch it — fix it first"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"

  # Our entry needs a trailing comma only when something follows it. Rather
  # than infer that from the text, try it and keep whichever parses.
  local variant
  for variant in "," ""; do
    menu_compose "$variant" > "$tmp" || fail "failed to compose $MENU"
    if menu_valid "$tmp"; then
      cp -f "$tmp" "$MENU" || fail "failed to write $MENU"
      rm -f "$tmp"
      return 0
    fi
  done

  rm -f "$tmp"
  fail "could not produce a valid menu file; $MENU left untouched"
}

# Sourcing with INSTALL_SH_LIB=1 loads the functions above without acting, so
# the menu logic can be exercised against a scratch file.
[[ ${INSTALL_SH_LIB:-} == 1 ]] && return 0

# ----------------------------------------------------------------------- main
#
# Everything that acts lives inside main(), and main runs on the very last
# line. Piped to bash, the script is executed as it arrives, so a download that
# dies halfway would otherwise run whatever it had already read. This way a
# truncated file leaves an incomplete function definition that never runs.

uninstall() {
  bold "Removing $PLUGIN_ID"

  if menu_has_entry; then
    cp -f "$MENU" "$MENU.bak.$(date +%s%N)"
    local tmp
    tmp=$(mktemp) && menu_strip_entry > "$tmp" && cp -f "$tmp" "$MENU" && rm -f "$tmp" \
      || fail "failed to remove the menu entry"
    info "menu entry removed"
  else
    info "no menu entry to remove"
  fi

  if [[ -d $PLUGIN_DIR ]]; then
    omarchy plugin remove "$PLUGIN_ID" --yes || fail "omarchy plugin remove failed"
    info "plugin removed"
  else
    info "plugin not installed"
  fi

  bold "Done."
}

install() {
  bold "Installing $PLUGIN_ID"

  if [[ -d $PLUGIN_DIR ]]; then
    info "plugin already installed at ~/.config/omarchy/plugins/$PLUGIN_ID"
  else
    # --yes matters here: piped to bash, stdin is the script itself, so
    # anything that stopped to ask a question would read garbage or hang.
    omarchy plugin add "$REPO_URL" --enable --yes || fail "omarchy plugin add failed"
    info "plugin installed and enabled"
  fi

  if menu_has_entry; then
    info "menu entry already present"
  else
    [[ -f $MENU ]] && cp -f "$MENU" "$MENU.bak.$(date +%s%N)"
    menu_add_entry
    info "menu entry added to ${MENU/#$HOME/\~}"
  fi

  # The menu file hot-reloads, but a freshly cloned plugin needs the shell to
  # notice it. Best-effort: -q keeps this quiet when the shell is not running.
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1

  echo
  bold "Run it"
  info "SUPER + SPACE  →  Setup  →  Keyboard repeat"
  info "omarchy menu summon setup.keyboard-repeat"
}

main() {
  command -v omarchy >/dev/null \
    || fail "omarchy not found — this installs an Omarchy shell plugin"
  command -v jq >/dev/null \
    || fail "jq not found — needed to edit the menu file safely"

  case "${1:-}" in
    --uninstall) uninstall ;;
    "")          install ;;
    *)           fail "unknown argument: $1 (expected --uninstall or nothing)" ;;
  esac
}

main "$@"
