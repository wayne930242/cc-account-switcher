#!/usr/bin/env bash
# Herdr plugin entry: `run.sh open` opens the popup, `run.sh dashboard` runs inside it.
# Herdr starts plugin commands with the PATH of whatever started its server; a Herdr launched from a macOS app
# has only /usr/bin:/bin:/usr/sbin:/sbin, where neither ccswitch nor jq is found, and where `env bash` finds macOS's
# bash 3.2, which ccswitch refuses. The usual install directories go first so a newer bash wins.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH"

# CCSWITCH_BIN first, then PATH, then the usual install locations, then the release bundled with this plugin.
find_ccswitch() {
	local candidate
	if [[ -n "${CCSWITCH_BIN:-}" ]]; then
		echo "$CCSWITCH_BIN"
		return
	fi
	if command -v ccswitch; then
		return
	fi
	for candidate in "$HOME/.local/bin/ccswitch" "$HOME/bin/ccswitch" "$HOME/bin/ccswitch.sh" ../dist/ccswitch; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return
		fi
	done
}

case "${1:-}" in
	open)
		exec "${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "${HERDR_PLUGIN_ID:-wayne930242.ccswitch}" --entrypoint dashboard --focus
		;;
	dashboard)
		ccswitch="$(find_ccswitch)"
		status=0
		if [[ -z "$ccswitch" ]]; then
			echo "ccswitch not found: set CCSWITCH_BIN, put it on PATH, or install it to ~/.local/bin" >&2
			status=127
		else
			"$ccswitch" --dashboard || status=$?
		fi
		# A failure would close the popup before its message could be read.
		if ((status != 0 && status != 130)); then
			echo
			read -rsn1 -p "ccswitch exited with status $status; press any key to close"
		fi
		exit "$status"
		;;
	*)
		echo "Usage: run.sh open|dashboard" >&2
		exit 2
		;;
esac
