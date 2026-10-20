#!/usr/bin/env bash
# Bootstrap installer for ccswitch: downloads a release, verifies its SHA256, and installs it.
#
#   curl -fsSL https://github.com/wayne930242/cc-account-switcher/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version v1.0.0 --dir ~/bin
#
# Options (or environment variables):
#   --version <vX.Y.Z|latest>   CCSWITCH_INSTALL_VERSION   default: latest
#   --dir <directory>           CCSWITCH_INSTALL_DIR       default: ~/.local/bin
#   --name <file name>          CCSWITCH_INSTALL_NAME      default: ccswitch

set -euo pipefail

readonly REPO="wayne930242/cc-account-switcher"

version="${CCSWITCH_INSTALL_VERSION:-latest}"
dir="${CCSWITCH_INSTALL_DIR:-$HOME/.local/bin}"
name="${CCSWITCH_INSTALL_NAME:-ccswitch}"

usage() {
    cat <<'USAGE'
Install ccswitch from a GitHub release, verifying its SHA256 checksum.

Options (or environment variables):
  --version <vX.Y.Z|latest>   CCSWITCH_INSTALL_VERSION   default: latest
  --dir <directory>           CCSWITCH_INSTALL_DIR       default: ~/.local/bin
  --name <file name>          CCSWITCH_INSTALL_NAME      default: ccswitch
USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
        --name) name="${2:?--name needs a value}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

if [[ "$version" == "latest" ]]; then
    base="https://github.com/$REPO/releases/latest/download"
else
    [[ "$version" == v* ]] || version="v$version"
    base="https://github.com/$REPO/releases/download/$version"
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    die "sha256sum or shasum is required to verify the download"
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

echo "Downloading ccswitch ($version)..."
curl -fsSL "$base/ccswitch" -o "$work_dir/ccswitch" || die "Could not download ccswitch $version from $base"
curl -fsSL "$base/ccswitch.sha256" -o "$work_dir/ccswitch.sha256" || die "Could not download the checksum for $version"

expected=$(awk '{print $1}' "$work_dir/ccswitch.sha256")
actual=$(sha256 "$work_dir/ccswitch")
[[ -n "$expected" && "$expected" == "$actual" ]] || die "Checksum mismatch for ccswitch $version; nothing was installed"

mkdir -p "$dir"
# Copy next to the target first so the final rename is atomic
cp "$work_dir/ccswitch" "$dir/.$name.installing"
chmod 755 "$dir/.$name.installing"
mv -f "$dir/.$name.installing" "$dir/$name"

echo "Installed $("$dir/$name" --version) to $dir/$name"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "Note: $dir is not on your PATH; add it, or run $dir/$name directly" ;;
esac
