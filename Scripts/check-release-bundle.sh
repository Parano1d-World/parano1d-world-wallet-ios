#!/bin/bash
# Release check: nothing internal ships inside the app.
# Usage: Scripts/check-release-bundle.sh <path to .xcarchive or .app> [--report]
# Fails (exit 1) if the bundle contains notes, docs, source files or internal wording.
# Swift comments are never compiled in, so this scans bundled files and the strings in every binary.
set -uo pipefail
target="${1:?Give the .xcarchive or .app to check}"; mode="${2:-}"
[[ -d "$target/Products" ]] && target="$(find "$target/Products" -maxdepth 3 -name '*.app' -type d | head -1)"
[[ -d "$target" ]] || { echo "No app bundle found at $1" >&2; exit 2; }
problems=0
note() { echo "RELEASE CHECK: $*"; problems=$((problems+1)); }

# 1. Files that must never be bundled. Licence texts the licences require are allowed.
while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  case "$name" in
    *LICENSE*|*LICENCE*|*OFL*|*NOTICE*|*.ttf|*.otf) continue ;;
  esac
  note "bundled file not allowed: ${file#"$target"/}"
done < <(find "$target" -type f \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.txt' -o -iname '*.rs' -o -iname '*.swift' \
  -o -iname '*.py' -o -iname '*.sh' -o -iname '*.command' -o -iname '*.map' -o -iname '*.zip' -o -iname '*.log' \
  -o -iname '*HANDOFF*' -o -iname '*READ-FIRST*' -o -iname '*.xcconfig' \) -print0)

# 2. Internal wording inside binaries, resources and string tables.
banned="${PARANO1D_BANNED_WORDS:-HANDOFF|READ-FIRST|TODO:|FIXME|/Users/[A-Za-z]}"
while IFS= read -r -d '' file; do
  hits="$(LC_ALL=C strings -n 6 "$file" 2>/dev/null | grep -E -o "$banned" | sort | uniq -c | head -5)"
  [[ -n "$hits" ]] && note "internal wording in ${file#"$target"/}: $(echo "$hits" | tr '\n' ' ')"
done < <(find "$target" -type f \( -perm -u+x -o -name '*.strings' -o -name '*.json' -o -name '*.plist' -o -name '*.html' -o -name '*.js' \) -print0)

if (( problems > 0 )); then
  echo "RELEASE CHECK FAILED: $problems problem(s) in $(basename "$target")."
  [[ "$mode" == "--report" ]] && exit 0 || exit 1
fi
echo "RELEASE CHECK PASSED: $(basename "$target") contains no notes, docs or internal wording."
