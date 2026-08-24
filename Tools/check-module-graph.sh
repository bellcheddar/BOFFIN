#!/usr/bin/env bash
#
# check-module-graph.sh
#
# Enforces the module dependency rule from CLAUDE.md:
#
#   BoffinCore      -> nothing
#   BoffinML        -> BoffinCore
#   BoffinData      -> BoffinCore
#   BoffinStructure -> BoffinCore
#   BoffinCharts    -> BoffinCore
#   BoffinUI        -> BoffinCore
#   BoffinViewer    -> BoffinCore, BoffinStructure
#
# If a feature seems to need an upward dependency, the abstraction is in the
# wrong module. This script fails the build rather than letting that happen
# quietly.
#
# Uses find plus a fixed-string grep over an explicit file list, so it does not
# depend on any particular grep implementation's directory-walking or ignore-file
# behaviour (which differs between BSD grep, GNU grep and ugrep).

set -euo pipefail

cd "$(dirname "$0")/.."

MODULES=(BoffinCore BoffinML BoffinData BoffinStructure BoffinViewer BoffinCharts BoffinUI)

allowed_for () {
    case "$1" in
        BoffinCore)      echo "" ;;
        BoffinML)        echo "BoffinCore" ;;
        BoffinData)      echo "BoffinCore" ;;
        BoffinStructure) echo "BoffinCore" ;;
        BoffinCharts)    echo "BoffinCore" ;;
        BoffinUI)        echo "BoffinCore" ;;
        BoffinViewer)    echo "BoffinCore BoffinStructure" ;;
        *)               echo "__UNKNOWN__" ;;
    esac
}

violations=0

for module in "${MODULES[@]}"; do
    src="Packages/$module/Sources"
    [ -d "$src" ] || { echo "missing sources: $src"; exit 1; }

    allowed="$(allowed_for "$module")"

    # Every Boffin* module imported anywhere in this module's sources.
    imported="$(
        find "$src" -name '*.swift' -type f -print0 \
        | xargs -0 grep -h -E '^[[:space:]]*(@[a-zA-Z]+[[:space:]]+)?import[[:space:]]+Boffin[A-Za-z]+' 2>/dev/null \
        | sed -E 's/.*import[[:space:]]+(Boffin[A-Za-z]+).*/\1/' \
        | sort -u || true
    )"

    for dep in $imported; do
        [ "$dep" = "$module" ] && continue
        if ! printf '%s\n' $allowed | grep -qx "$dep"; then
            echo "VIOLATION: $module imports $dep (allowed: ${allowed:-none})"
            find "$src" -name '*.swift' -type f -print0 \
              | xargs -0 grep -n -E "^[[:space:]]*(@[a-zA-Z]+[[:space:]]+)?import[[:space:]]+$dep\$" 2>/dev/null \
              | sed 's/^/    /' || true
            violations=$((violations + 1))
        fi
    done

    echo "ok: $module -> $(echo ${imported:-nothing} | tr '\n' ' ')"
done

# The package manifests must agree with the source imports: a manifest that
# declares a dependency the rule forbids is a violation even if nothing
# imports it yet.
for module in "${MODULES[@]}"; do
    manifest="Packages/$module/Package.swift"
    allowed="$(allowed_for "$module")"
    declared="$(
        grep -o -E '\.package\(path: "\.\./Boffin[A-Za-z]+"\)' "$manifest" 2>/dev/null \
        | sed -E 's/.*\.\.\/(Boffin[A-Za-z]+).*/\1/' | sort -u || true
    )"
    for dep in $declared; do
        if ! printf '%s\n' $allowed | grep -qx "$dep"; then
            echo "VIOLATION: $manifest declares a dependency on $dep (allowed: ${allowed:-none})"
            violations=$((violations + 1))
        fi
    done
done

if [ "$violations" -gt 0 ]; then
    echo
    echo "Module dependency rule violated in $violations place(s). See CLAUDE.md."
    exit 1
fi

echo
echo "Module dependency rule satisfied."
