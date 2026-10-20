# shellcheck shell=bash
# ccswitch: Token test: one real request through `claude -p`

# Send one tiny prompt to Haiku with the account's access token.
# Prints a one-line verdict and returns 1 when the token does not actually work.
test_account_inference() {
    local num="$1" email="$2" active="$3"
    local work_dir output result started elapsed

    load_account_credentials "$num" "$email" "$active"
    if ! token_usable; then
        if [[ "$ACCOUNT_TOKEN_STATE" == "expired-active" ]]; then
            echo "SKIPPED: $(token_state_message "$ACCOUNT_TOKEN_STATE")"
        else
            echo "FAILED: $(token_state_message "$ACCOUNT_TOKEN_STATE")"
        fi
        return 1
    fi

    # An empty directory with no settings, MCP servers, or tools keeps the test to one plain
    # request; the token goes through the environment, never the command line
    work_dir=$(mktemp -d)
    started=$(date +%s)
    output=$(cd "$work_dir" && printf 'Reply with exactly: OK\n' |
        CLAUDE_CODE_OAUTH_TOKEN="$(access_token "$ACCOUNT_CREDENTIALS")" ANTHROPIC_API_KEY="" \
            claude -p --model haiku --output-format json --no-session-persistence \
            --strict-mcp-config --setting-sources "" --tools "" 2>&1) || true
    elapsed=$(($(date +%s) - started))
    rm -rf "$work_dir"

    result=$(jq -c 'if type == "array" then (map(select(.type == "result")) | last) else . end
        | {is_error, result}' 2>/dev/null <<<"$output" || true)
    if [[ -z "$result" || "$result" == "null" ]]; then
        echo "FAILED: claude -p gave no result: $(head -n1 <<<"$output" | cut -c1-120)"
        return 1
    fi
    if [[ "$(jq -r '.is_error' <<<"$result")" != "false" ]]; then
        echo "FAILED: $(jq -r '.result // "unknown error"' <<<"$result" | head -n1 | cut -c1-120)"
        return 1
    fi
    echo "OK: haiku replied in ${elapsed}s"
}

test_account_line() {
    local verdict
    verdict=$(test_account_inference "$2" "$3" "$4") || true
    printf '  %s: %-32s %s\n' "$2" "$3" "$verdict"
}

cmd_test() {
    require_accounts
    require_command claude

    local only="" output
    if [[ $# -gt 0 ]]; then
        resolve_account "$1"
        only="$RESOLVED_ACCOUNT"
    fi

    echo "Testing with claude -p (haiku)..."
    output=$(for_each_account test_account_line "$only")
    echo "$output"
    awk '!/ OK: / { failed = 1 } END { exit failed }' <<<"$output"
}
