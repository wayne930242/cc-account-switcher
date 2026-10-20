#!/usr/bin/env bash
# Assemble lib/*.sh into the single-file release dist/ccswitch and its SHA256 checksum.
# Usage: scripts/build.sh <version> [output directory]   (for example: scripts/build.sh 1.0.0)

set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Usage: $0 <version> [output directory]   (semantic version without a leading v, e.g. 1.0.0)" >&2
    exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="${2:-$root/dist}"
output="$dist/ccswitch"
mkdir -p "$dist"

{
    cat <<EOF
#!/usr/bin/env bash
# ccswitch $version: Multi-Account Switcher for Claude Code
# https://github.com/wayne930242/cc-account-switcher
# Built from lib/*.sh; edit those modules, not this file.

set -euo pipefail

readonly CCSWITCH_VERSION="$version"
EOF
    for module in "$root"/lib/*.sh; do
        echo ""
        # Module headers only matter to shellcheck when a module is read on its own
        grep -v '^# shellcheck shell=bash$' "$module"
    done
    cat <<'EOF'

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
EOF
} >"$output"

chmod 755 "$output"
bash -n "$output"

(
    cd "$dist"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum ccswitch >ccswitch.sha256
    else
        shasum -a 256 ccswitch >ccswitch.sha256
    fi
)

echo "Built $output ($version)"
