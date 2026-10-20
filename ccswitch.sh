#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Manage, monitor, and switch between multiple Claude Code accounts

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Claude Code OAuth endpoints
readonly OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
readonly OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
readonly OAUTH_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
readonly OAUTH_BETA_HEADER="oauth-2025-04-20"
readonly HTTP_USER_AGENT="ccswitch/1.0"

# An inactive token this close to expiry is renewed before use
readonly RENEW_MARGIN_SECONDS=300
# A switch target this close to expiry is renewed first; one with more time left is kept,
# because renewing rotates the refresh token and breaks running sessions that hold the old one
readonly SWITCH_RENEW_MARGIN_SECONDS=3600
readonly DASHBOARD_REFRESH_SECONDS=300

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Storage: Claude Code config, credential slots, and backups
# ---------------------------------------------------------------------------

# Claude Code config path, preferring ~/.claude/.claude.json when it holds an oauthAccount
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    if [[ -f "$primary_config" ]] && jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
        echo "$primary_config"
    else
        echo "$HOME/.claude.json"
    fi
}

# Email of the account Claude Code is logged in as, or "none"
get_current_account() {
    local config email
    config=$(get_claude_config_path)
    if [[ ! -f "$config" ]] || ! jq -e . "$config" >/dev/null 2>&1; then
        echo "none"
        return
    fi
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$config" 2>/dev/null)
    echo "${email:-none}"
}

# Write JSON atomically after validating it
write_json() {
    local file="$1" content="$2" temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    echo "$content" >"$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR" "$BACKUP_DIR"/{configs,credentials}
}

# Credentials live in slots: "live" is what Claude Code uses, "<num>-<email>" is an account backup.
# macOS keeps them in the Keychain, Linux and WSL in files with 600 permissions.
secret_file() {
    if [[ "$1" == "live" ]]; then
        echo "$HOME/.claude/.credentials.json"
    else
        echo "$BACKUP_DIR/credentials/.claude-credentials-$1.json"
    fi
}

keychain_service() {
    if [[ "$1" == "live" ]]; then
        echo "Claude Code-credentials"
    else
        echo "Claude Code-Account-$1"
    fi
}

read_secret() {
    local slot="$1" file
    case "$(detect_platform)" in
        macos)
            security find-generic-password -s "$(keychain_service "$slot")" -w 2>/dev/null || echo ""
            ;;
        linux | wsl)
            file=$(secret_file "$slot")
            if [[ -f "$file" ]]; then cat "$file"; else echo ""; fi
            ;;
    esac
}

write_secret() {
    local slot="$1" credentials="$2" file
    case "$(detect_platform)" in
        macos)
            security add-generic-password -U -s "$(keychain_service "$slot")" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux | wsl)
            file=$(secret_file "$slot")
            mkdir -p "$(dirname "$file")"
            printf '%s' "$credentials" >"$file"
            chmod 600 "$file"
            ;;
    esac
}

delete_secret() {
    local slot="$1"
    case "$(detect_platform)" in
        macos) security delete-generic-password -s "$(keychain_service "$slot")" >/dev/null 2>&1 || true ;;
        linux | wsl) rm -f "$(secret_file "$slot")" ;;
    esac
}

account_config_file() {
    echo "$BACKUP_DIR/configs/.claude-config-$1-$2.json"
}

read_account_config() {
    local file
    file=$(account_config_file "$1" "$2")
    if [[ -f "$file" ]]; then cat "$file"; else echo ""; fi
}

write_account_config() {
    local file
    file=$(account_config_file "$1" "$2")
    echo "$3" >"$file"
    chmod 600 "$file"
}

# ---------------------------------------------------------------------------
# Account registry (sequence.json)
# ---------------------------------------------------------------------------

require_accounts() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
}

init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        write_json "$SEQUENCE_FILE" "$(jq -n --arg now "$(timestamp)" \
            '{activeAccountNumber: null, lastUpdated: $now, sequence: [], accounts: {}}')"
    fi
}

# Print "<num>\t<email>" for every account in sequence order
list_accounts() {
    jq -r '.sequence[] as $n | "\($n)\t\(.accounts["\($n)"].email)"' "$SEQUENCE_FILE"
}

account_email() {
    jq -r --arg num "$1" '.accounts[$num].email // empty' "$SEQUENCE_FILE"
}

account_number_for_email() {
    jq -r --arg email "$1" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null
}

account_exists() {
    [[ -f "$SEQUENCE_FILE" ]] && [[ -n "$(account_number_for_email "$1")" ]]
}

# Resolve an account number or email into RESOLVED_ACCOUNT, or exit with an error
resolve_account() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        RESOLVED_ACCOUNT="$identifier"
    elif [[ ! "$identifier" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid email format: $identifier"
        exit 1
    else
        RESOLVED_ACCOUNT=$(account_number_for_email "$identifier")
        if [[ -z "$RESOLVED_ACCOUNT" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    if [[ -z "$(account_email "$RESOLVED_ACCOUNT")" ]]; then
        echo "Error: Account-$RESOLVED_ACCOUNT does not exist"
        exit 1
    fi
}

# Run "<function> <index> <num> <email> <active>" for each account (or only account <num>) in
# parallel, then print the outputs in sequence order
for_each_account() {
    local function_name="$1" only="${2:-}"
    local work_dir current_email index=0 num email active i
    work_dir=$(mktemp -d)
    current_email=$(get_current_account)
    while IFS=$'\t' read -r num email; do
        if [[ -z "$only" || "$num" == "$only" ]]; then
            active=false
            if [[ "$email" == "$current_email" ]]; then
                active=true
            fi
            "$function_name" "$index" "$num" "$email" "$active" >"$work_dir/$index" &
        fi
        index=$((index + 1))
    done < <(list_accounts)
    wait
    for ((i = 0; i < index; i++)); do
        if [[ -f "$work_dir/$i" ]]; then
            cat "$work_dir/$i"
        fi
    done
    rm -rf "$work_dir"
}

# ---------------------------------------------------------------------------
# OAuth tokens and usage
# ---------------------------------------------------------------------------

# Succeed when the credentials' access token expires within <seconds>
token_expires_within() {
    local credentials="$1" seconds="$2"
    jq -e --argjson limit "$(($(now_ms) + seconds * 1000))" \
        '(.claudeAiOauth.expiresAt // 0) <= $limit' >/dev/null 2>&1 <<<"$credentials"
}

access_token() {
    jq -r '.claudeAiOauth.accessToken' <<<"$1"
}

# Run curl and split its output into HTTP_STATUS and HTTP_BODY; fails on network errors.
# Callers pass secrets through stdin or process substitution, never as arguments.
http_request() {
    local response
    response=$(curl -sS --max-time 15 -w '\n%{http_code}' -A "$HTTP_USER_AGENT" "$@" 2>/dev/null) || return 1
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}

# Exchange the refresh token in ACCOUNT_CREDENTIALS for a new access token, save the result to
# <slot>, and set ACCOUNT_TOKEN_STATE to refreshed, relogin, refresh-rate-limited,
# refresh-failed, or save-failed
renew_credentials() {
    local slot="$1" body renewed

    body=$(jq -c --arg client_id "$OAUTH_CLIENT_ID" \
        '{grant_type: "refresh_token", refresh_token: .claudeAiOauth.refreshToken, client_id: $client_id}' \
        <<<"$ACCOUNT_CREDENTIALS")
    if ! http_request -H 'Content-Type: application/json' --data-binary @- "$OAUTH_TOKEN_URL" <<<"$body"; then
        ACCOUNT_TOKEN_STATE="refresh-failed"
        return 0
    fi

    case "$HTTP_STATUS" in
        200) ;;
        400 | 401)
            if grep -q 'invalid_grant' <<<"$HTTP_BODY"; then ACCOUNT_TOKEN_STATE="relogin"; else ACCOUNT_TOKEN_STATE="refresh-failed"; fi
            return 0
            ;;
        429) ACCOUNT_TOKEN_STATE="refresh-rate-limited"; return 0 ;;
        *) ACCOUNT_TOKEN_STATE="refresh-failed"; return 0 ;;
    esac

    # Credentials and response travel on stdin so no token shows up in the process list
    if ! renewed=$(printf '%s\n%s\n' "$ACCOUNT_CREDENTIALS" "$HTTP_BODY" | jq -ce -s --argjson now "$(now_ms)" '
        .[0] as $creds | .[1] as $r |
        if ($r.access_token | type) != "string" then error("no access token in response") else
            $creds | .claudeAiOauth |= (
                .accessToken = $r.access_token
                | .expiresAt = ($now + $r.expires_in * 1000)
                | if $r.refresh_token then .refreshToken = $r.refresh_token else . end
                | if $r.refresh_token_expires_in then .refreshTokenExpiresAt = ($now + $r.refresh_token_expires_in * 1000) else . end
                | if $r.scope then .scopes = ($r.scope | split(" ")) else . end
            )
        end' 2>/dev/null); then
        ACCOUNT_TOKEN_STATE="refresh-failed"
        return 0
    fi

    if write_secret "$slot" "$renewed"; then
        ACCOUNT_CREDENTIALS="$renewed"
        ACCOUNT_TOKEN_STATE="refreshed"
    else
        ACCOUNT_TOKEN_STATE="save-failed"
    fi
}

# Load an account's credentials into ACCOUNT_CREDENTIALS and its state into ACCOUNT_TOKEN_STATE
# (valid, refreshed, expired-active, missing, or a renew_credentials failure). The active account
# uses the live credentials, which Claude Code owns, so they are never renewed here; an inactive
# account's expiring access token is renewed and saved back to its backup.
load_account_credentials() {
    local num="$1" email="$2" active="$3"

    ACCOUNT_TOKEN_STATE="valid"
    if [[ "$active" == "true" ]]; then
        ACCOUNT_CREDENTIALS=$(read_secret live)
    else
        ACCOUNT_CREDENTIALS=$(read_secret "$num-$email")
    fi

    if [[ -z "$ACCOUNT_CREDENTIALS" ]] || ! jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1 <<<"$ACCOUNT_CREDENTIALS"; then
        ACCOUNT_TOKEN_STATE="missing"
    elif token_expires_within "$ACCOUNT_CREDENTIALS" "$RENEW_MARGIN_SECONDS"; then
        if [[ "$active" == "true" ]]; then
            ACCOUNT_TOKEN_STATE="expired-active"
        else
            renew_credentials "$num-$email"
        fi
    fi
}

token_usable() {
    [[ "$ACCOUNT_TOKEN_STATE" == "valid" || "$ACCOUNT_TOKEN_STATE" == "refreshed" ]]
}

# Explain why a token state is not usable
token_state_message() {
    case "$1" in
        expired-active) echo "token expired, Claude Code renews it on use" ;;
        relogin) echo "login expired or revoked: log in again, then --add-account" ;;
        refresh-rate-limited) echo "token renewal rate limited, try again later" ;;
        refresh-failed) echo "token renewal failed (network or server error)" ;;
        save-failed) echo "renewed token could not be saved: log in again, then --add-account" ;;
        missing) echo "no stored credentials" ;;
        *) echo "$1" ;;
    esac
}

# Print the 5-hour and 7-day usage JSON for an access token, or a short error and return 1
fetch_usage() {
    if ! http_request -H @<(printf 'Authorization: Bearer %s\n' "$1") \
        -H "anthropic-beta: $OAUTH_BETA_HEADER" "$OAUTH_USAGE_URL"; then
        echo "usage request failed (network)"
        return 1
    fi
    case "$HTTP_STATUS" in
        200) jq -ce . <<<"$HTTP_BODY" 2>/dev/null || { echo "usage response is not JSON"; return 1; } ;;
        401 | 403) echo "usage request unauthorized (HTTP $HTTP_STATUS)"; return 1 ;;
        429) echo "usage API rate limited, try again later"; return 1 ;;
        *) echo "usage request failed (HTTP $HTTP_STATUS)"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Commands: add, remove, list, switch
# ---------------------------------------------------------------------------

cmd_add_account() {
    setup_directories
    init_sequence_file

    local current_email account_num current_creds config
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi
    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi

    current_creds=$(read_secret live)
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    account_num=$(jq -r '(.accounts | keys | map(tonumber) | max // 0) + 1' "$SEQUENCE_FILE")
    config=$(get_claude_config_path)
    write_secret "$account_num-$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$(cat "$config")"

    write_json "$SEQUENCE_FILE" "$(jq --arg num "$account_num" --arg email "$current_email" \
        --arg uuid "$(jq -r '.oauthAccount.accountUuid' "$config")" --arg now "$(timestamp)" '
        .accounts[$num] = {email: $email, uuid: $uuid, added: $now}
        | .sequence += [$num | tonumber]
        | .activeAccountNumber = ($num | tonumber)
        | .lastUpdated = $now
    ' "$SEQUENCE_FILE")"

    echo "Added Account $account_num: $current_email"
}

cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi
    require_accounts
    resolve_account "$1"

    local account_num="$RESOLVED_ACCOUNT" email confirm
    email=$(account_email "$account_num")
    if [[ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    delete_secret "$account_num-$email"
    rm -f "$(account_config_file "$account_num" "$email")"
    write_json "$SEQUENCE_FILE" "$(jq --arg num "$account_num" --arg now "$(timestamp)" '
        del(.accounts[$num])
        | .sequence = (.sequence | map(select(. != ($num | tonumber))))
        | .lastUpdated = $now
    ' "$SEQUENCE_FILE")"

    echo "Account-$account_num ($email) has been removed"
}

first_run_setup() {
    local current_email response
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi

    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    cmd_add_account
}

cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    local current_email num email
    current_email=$(get_current_account)
    echo "Accounts:"
    while IFS=$'\t' read -r num email; do
        if [[ "$email" == "$current_email" ]]; then
            echo "  $num: $email (active)"
        else
            echo "  $num: $email"
        fi
    done < <(list_accounts)
}

# Rotate to the next account in sequence
cmd_switch() {
    require_accounts

    local current_email active_account sequence next_index=0 i
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        echo "It has been automatically added as Account-$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")."
        echo "Please run '$0 --switch' again to switch to the next account."
        exit 0
    fi

    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    mapfile -t sequence < <(jq -r '.sequence[]' "$SEQUENCE_FILE")
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            next_index=$(((i + 1) % ${#sequence[@]}))
            break
        fi
    done

    perform_switch "${sequence[next_index]}"
}

cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi
    require_accounts
    resolve_account "$1"
    perform_switch "$RESOLVED_ACCOUNT"
}

perform_switch() {
    local target_account="$1"
    local current_account target_email current_email target_config oauth_section config merged_config

    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(account_email "$target_account")
    current_email=$(get_current_account)

    # The live credentials already belong to the target; renewing its stale backup would
    # rotate the refresh token that the running Claude Code still holds
    if [[ "$target_email" == "$current_email" ]]; then
        echo "Account-$target_account ($target_email) is already active"
        return 0
    fi

    # Step 1: Load and check the target account before changing anything
    ACCOUNT_CREDENTIALS=$(read_secret "$target_account-$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    if [[ -z "$ACCOUNT_CREDENTIALS" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi
    oauth_section=$(jq '.oauthAccount' <<<"$target_config" 2>/dev/null || true)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi

    # Step 2: Renew an expiring target login, so a dead login never replaces a working one
    if token_expires_within "$ACCOUNT_CREDENTIALS" "$SWITCH_RENEW_MARGIN_SECONDS"; then
        echo "Renewing Account-$target_account login..."
        renew_credentials "$target_account-$target_email"
        if [[ "$ACCOUNT_TOKEN_STATE" != "refreshed" ]]; then
            echo "Error: Account-$target_account ($target_email): $(token_state_message "$ACCOUNT_TOKEN_STATE")."
            echo "Nothing was switched."
            exit 1
        fi
    fi

    # Step 3: Back up the current account
    config=$(get_claude_config_path)
    write_secret "$current_account-$current_email" "$(read_secret live)"
    write_account_config "$current_account" "$current_email" "$(cat "$config")"

    # Step 4: Activate the target account, keeping every other Claude Code setting
    write_secret live "$ACCOUNT_CREDENTIALS"
    if ! merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$config" 2>/dev/null); then
        echo "Error: Failed to merge config"
        exit 1
    fi
    write_json "$config" "$merged_config"

    # Step 5: Update state
    write_json "$SEQUENCE_FILE" "$(jq --arg num "$target_account" --arg now "$(timestamp)" \
        '.activeAccountNumber = ($num | tonumber) | .lastUpdated = $now' "$SEQUENCE_FILE")"

    echo "Switched to Account-$target_account ($target_email)"
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
}

# ---------------------------------------------------------------------------
# Token test: one real request through `claude -p`
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

# Print one account's token and usage state as a JSON object
dashboard_account_json() {
    local index="$1" num="$2" email="$3" active="$4"
    local usage="null" error="" meta="null" output

    if load_account_credentials "$num" "$email" "$active"; then
        if token_usable; then
            if output=$(fetch_usage "$(access_token "$ACCOUNT_CREDENTIALS")"); then
                usage="$output"
            else
                error="$output"
            fi
        fi
        if [[ "$ACCOUNT_TOKEN_STATE" != "missing" ]]; then
            meta=$(jq -c '.claudeAiOauth | {plan: .subscriptionType, tier: .rateLimitTier, expiresAt, refreshTokenExpiresAt}' \
                <<<"$ACCOUNT_CREDENTIALS")
        fi
    else
        ACCOUNT_TOKEN_STATE="unknown"
        error="could not read this account"
    fi

    jq -cn --argjson index "$index" --arg num "$num" --arg email "$email" --argjson active "$active" \
        --arg token_state "$ACCOUNT_TOKEN_STATE" --arg token_message "$(token_state_message "$ACCOUNT_TOKEN_STATE")" \
        --arg error "$error" --argjson meta "$meta" --argjson usage "$usage" \
        '{index: $index, num: $num, email: $email, active: $active, token_state: $token_state,
          token_message: $token_message, error: (if $error == "" then null else $error end), meta: $meta, usage: $usage}'
}

dashboard_collect() {
    for_each_account dashboard_account_json | jq -cs '.'
}

# Render the dashboard frame from a snapshot array
dashboard_render() {
    local snapshot="$1" selected="$2" color="$3" status="$4" interactive="$5"
    local columns bar_width

    # Usage lines are 54 columns plus the bar; the bar takes what the terminal has left
    columns=$(tput cols 2>/dev/null || echo 80)
    bar_width=$((columns - 54))
    ((bar_width < 8)) && bar_width=8
    ((bar_width > 30)) && bar_width=30

    jq -r --argjson selected "$selected" --argjson color "$color" --arg status "$status" \
        --argjson bar_width "$bar_width" --argjson interactive "$interactive" \
        --arg updated "$(date +%H:%M:%S)" --argjson now "$(date +%s)" '
        def c($code): if $color then "\u001b[\($code)m\(.)\u001b[0m" else . end;
        def rep($s; $n): [range(0; $n) | $s] | join("");
        def pad($n): . + rep(" "; $n - length);
        def lpad($n): rep(" "; $n - length) + .;
        def dur:
            floor as $s
            | if $s <= 0 then "now"
              elif $s < 3600 then "\($s / 60 | floor)m"
              elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
              else "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h" end;
        def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
        def level($p): if $p >= 80 then "31" elif $p >= 50 then "33" else "32" end;
        def bar($p): ($bar_width * $p / 100 | round) as $n | rep("█"; $n) + rep("░"; $bar_width - $n);
        def window($label; $pct; $resets):
            ($pct // 0 | round) as $p
            | "     " + ($label | pad(12)) + (bar($p) | c(level($p)))
              + " " + ("\($p)%" | lpad(4)) + " used " + ("\(100 - $p)%" | lpad(4)) + " left"
              + (if $resets then "  resets " + ($resets | epoch - $now | dur) else "" end);
        def plan:
            if .meta == null then ""
            elif (.meta.tier // "" | test("max_[0-9]+x")) then "Max " + (.meta.tier | capture("max_(?<x>[0-9]+x)").x)
            elif .meta.plan then .meta.plan | ascii_upcase[0:1] + .[1:]
            else "" end;
        def login:
            if .meta.refreshTokenExpiresAt == null then "login expiry unknown" | c("2")
            else (.meta.refreshTokenExpiresAt / 1000 - $now) as $left
                | if $left <= 0 then "login expired" | c("31")
                  else "login expires in " + ($left | dur)
                      | c(if $left < 3 * 86400 then "31" elif $left < 7 * 86400 then "33" else "2" end)
                  end
            end;
        def token:
            if .token_state == "valid" then "token valid " + ((.meta.expiresAt / 1000 - $now) | dur) | c("2")
            elif .token_state == "refreshed" then "token refreshed" | c("32")
            elif (.token_state | IN("expired-active", "refresh-failed", "refresh-rate-limited")) then .token_message | c("33")
            else .token_message | c("31") end;
        def account_lines:
            (.index == $selected and $interactive) as $sel
            | ((if $sel then "›" else " " end) + (.num | lpad(2)) + "  " + (.email | pad(30))
                + (if .active then "● active" | c("32;1") else "        " end) + "  " + plan) as $head
            | (if $sel then $head | c("1;7") else $head end),
              ("     " + login + " · " + token),
              (if .usage then
                  window("5-hour"; .usage.five_hour.utilization; .usage.five_hour.resets_at),
                  window("7-day"; .usage.seven_day.utilization; .usage.seven_day.resets_at),
                  (.usage.limits // [] | .[] | select(.kind == "weekly_scoped" and .scope.model.display_name != null)
                      | window("7-day " + .scope.model.display_name; .percent; .resets_at))
               elif .error then "     " + (.error | c("31"))
               else empty end),
              "";
        ("Claude Code accounts" | c("1")) + "   " + ("updated " + $updated | c("2")),
        "",
        (if length == 0 then "  No managed accounts. Run --add-account first.", "" else .[] | account_lines end),
        (if $interactive then
            ("↑/↓ select  enter switch  1-9 switch to #  t test  r refresh  q quit" | c("2")),
            (if $status != "" then $status else empty end)
         else empty end)
    ' <<<"$snapshot"
}

# The helpers below share cmd_dashboard's locals: snapshot, count, selected, status, color

dashboard_reload() {
    printf '\033[H\033[2J%s\n' "Loading accounts and usage..."
    snapshot=$(dashboard_collect)
    count=$(jq 'length' <<<"$snapshot")
}

dashboard_draw() {
    local frame
    frame=$(dashboard_render "$snapshot" "$selected" "$color" "$status" true)
    printf '\033[H\033[2J%s\n' "$frame"
}

# Print "<num>\t<email>\t<active>" for the selected account
dashboard_selected_account() {
    jq -r --argjson i "$selected" '.[$i] | [.num, .email, .active] | @tsv' <<<"$snapshot"
}

# Ask for confirmation, then switch to the selected account
dashboard_switch_selected() {
    local num email active answer output rc

    IFS=$'\t' read -r num email active < <(dashboard_selected_account)
    if [[ "$active" == "true" ]]; then
        status="Account-$num ($email) is already active"
        return 0
    fi
    if ! jq -e 'any(.active)' >/dev/null <<<"$snapshot"; then
        status="The logged-in Claude Code account is not managed; run --add-account first"
        return 0
    fi

    status="Switch to Account-$num ($email)? [y/N]"
    dashboard_draw
    answer=""
    IFS= read -rsn1 answer || true
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        status="Switch cancelled"
        return 0
    fi

    # perform_switch exits on error, so it runs in a subshell with errexit kept on
    set +e
    output=$(
        set -e
        perform_switch "$num" 2>&1
    )
    rc=$?
    set -e
    if ((rc == 0)); then
        status="Switched to Account-$num. Restart Claude Code to use it."
    else
        status="Switch failed: $(grep -m1 '^Error:' <<<"$output" || tail -n1 <<<"$output")"
    fi
    dashboard_reload
}

# Run the claude -p test for the selected account and show the verdict
dashboard_test_selected() {
    local num email active verdict code=32

    if ! command -v claude >/dev/null 2>&1; then
        status="Cannot test: 'claude' is not on PATH"
        return 0
    fi
    IFS=$'\t' read -r num email active < <(dashboard_selected_account)
    status="Testing Account-$num with claude -p (haiku)..."
    dashboard_draw
    verdict=$(test_account_inference "$num" "$email" "$active") || code=31
    if [[ "$color" == "true" ]]; then
        verdict=$'\033['"$code"m"$verdict"$'\033[0m'
    fi
    status="Account-$num test: $verdict"
}

dashboard_restore_terminal() {
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
}

# Interactive dashboard: token expiry, 5-hour and 7-day usage, testing, and switching.
# Without a terminal it prints one snapshot.
cmd_dashboard() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        first_run_setup
        exit 1
    fi

    local snapshot count=0 selected=0 status="" color=false key rest target
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        color=true
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        dashboard_render "$(dashboard_collect)" -1 "$color" "" false
        return
    fi

    trap dashboard_restore_terminal EXIT
    trap 'exit 130' INT TERM
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true

    dashboard_reload
    selected=$(jq '(map(.active) | index(true)) // 0' <<<"$snapshot")

    while true; do
        dashboard_draw
        key=""
        if ! IFS= read -rsn1 -t "$DASHBOARD_REFRESH_SECONDS" key; then
            status=""
            dashboard_reload
            continue
        fi
        case "$key" in
            $'\e')
                rest=""
                IFS= read -rsn2 -t 0.05 rest || true
                case "$rest" in
                    '[A') ((selected > 0)) && selected=$((selected - 1)) ;;
                    '[B') ((selected < count - 1)) && selected=$((selected + 1)) ;;
                    '') break ;;
                esac
                ;;
            k) ((selected > 0)) && selected=$((selected - 1)) ;;
            j) ((selected < count - 1)) && selected=$((selected + 1)) ;;
            '') ((count > 0)) && dashboard_switch_selected ;;
            [1-9])
                target=$(jq --arg num "$key" '(map(.num) | index($num)) // -1' <<<"$snapshot")
                if ((target >= 0)); then
                    selected="$target"
                    dashboard_switch_selected
                else
                    status="No account #$key"
                fi
                ;;
            t | T) ((count > 0)) && dashboard_test_selected ;;
            r | R)
                status=""
                dashboard_reload
                ;;
            q | Q) break ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

show_usage() {
    cat <<EOF
Multi-Account Switcher for Claude Code
Usage: $0 [COMMAND]

Commands:
  --add-account                    Add current account to managed accounts
  --remove-account <num|email>     Remove account by number or email
  --list                           List all managed accounts
  --switch                         Rotate to next account in sequence
  --switch-to <num|email>          Switch to specific account number or email
  --dashboard                      Show token expiry and 5-hour/7-day usage; switch interactively
  --test [num|email]               Check that each account's token really works (claude -p, haiku)
  --help                           Show this help message

Examples:
  $0 --add-account
  $0 --list
  $0 --switch
  $0 --switch-to 2
  $0 --switch-to user@example.com
  $0 --dashboard
  $0 --test 2
  $0 --remove-account user@example.com
EOF
}

main() {
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    check_bash_version
    require_command jq
    require_command curl

    case "${1:-}" in
        --add-account) cmd_add_account ;;
        --remove-account) shift; cmd_remove_account "$@" ;;
        --list) cmd_list ;;
        --switch) cmd_switch ;;
        --switch-to) shift; cmd_switch_to "$@" ;;
        --dashboard) cmd_dashboard ;;
        --test) shift; cmd_test "$@" ;;
        --help | "") show_usage ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
