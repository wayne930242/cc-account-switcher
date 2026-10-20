# shellcheck shell=bash
# ccswitch: Environment

is_running_in_container() {
    [[ -f /.dockerenv ]] && return 0
    [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null && return 0
    [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null && return 0
    [[ -n "${CONTAINER:-}" || -n "${container:-}" ]]
}

detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then echo "wsl"; else echo "linux"; fi ;;
        *) echo "unknown" ;;
    esac
}

check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Required command '$1' not found"
        echo "Install with: apt install $1 (Linux) or brew install $1 (macOS)"
        exit 1
    fi
}

now_ms() {
    echo $(($(date +%s) * 1000))
}

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}
