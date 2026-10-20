# shellcheck shell=bash
# ccswitch: Version and self-update

cmd_version() {
    echo "ccswitch ${CCSWITCH_VERSION:-dev}"
}

# Absolute path of the running script, following symlinks
script_path() {
    local path="${BASH_SOURCE[-1]}" link
    while [[ -L "$path" ]]; do
        link=$(readlink "$path")
        if [[ "$link" != /* ]]; then
            link="$(dirname "$path")/$link"
        fi
        path="$link"
    done
    echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

# Reinstall this file from a release by running that release's own installer
cmd_self_update() {
    local version="${1:-latest}" target installer url

    if [[ "${CCSWITCH_VERSION:-dev}" == "dev" ]]; then
        echo "Error: This ccswitch runs from a source checkout; update it with git pull"
        exit 1
    fi

    if [[ "$version" == "latest" ]]; then
        url="https://github.com/$CCSWITCH_REPO/releases/latest/download/install.sh"
    else
        [[ "$version" == v* ]] || version="v$version"
        url="https://github.com/$CCSWITCH_REPO/releases/download/$version/install.sh"
    fi

    target=$(script_path)
    installer=$(mktemp)
    if ! curl -fsSL "$url" -o "$installer"; then
        rm -f "$installer"
        echo "Error: Could not download the installer for $version"
        exit 1
    fi
    echo "Current: ccswitch $CCSWITCH_VERSION"
    bash "$installer" --version "$version" --dir "$(dirname "$target")" --name "$(basename "$target")" || {
        rm -f "$installer"
        exit 1
    }
    rm -f "$installer"
}
