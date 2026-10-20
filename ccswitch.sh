#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Dashboard configuration (Claude Code OAuth endpoints)
readonly OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
readonly OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
readonly OAUTH_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
readonly OAUTH_BETA_HEADER="oauth-2025-04-20"
readonly DASHBOARD_REFRESH_SECONDS=300
readonly SWITCH_RENEW_MARGIN_SECONDS=3600
readonly HTTP_USER_AGENT="ccswitch/1.0"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Look up account number by email
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi
    
    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi
    
    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi
    
    local account_num
    account_num=$(get_next_account_number)
    
    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi
    
    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")
    
    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local account_num
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi
        
        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi
    
    local email
    email=$(echo "$account_info" | jq -r '.email')
    
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    
    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi
    
    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
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
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi
    
    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)
    
    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi
    
    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        if "\($num)" == $active then
            "  \($num): \(.email) (active)"
        else
            "  \($num): \(.email)"
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close
    
    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local target_account
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi
        
        # Resolve email to account number
        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    
    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi
    
    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # The live credentials already belong to the target; renewing its stale backup would
    # rotate the refresh token that the running Claude Code still holds
    if [[ "$target_email" == "$current_email" ]]; then
        echo "Account-$target_account ($target_email) is already active"
        return 0
    fi
    
    # Step 1: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi

    # Step 2: Renew the target login before touching anything when its access token is
    # expired or close to it, so a dead login never replaces a working one and Claude Code
    # starts with a usable token. A token with time left is kept: renewing rotates the
    # refresh token, which breaks any running session that still holds the old one.
    local renewed_creds renew_status=0 expires_at
    expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0 | floor' <<<"$target_creds" 2>/dev/null || echo 0)
    if ((expires_at - SWITCH_RENEW_MARGIN_SECONDS * 1000 > $(date +%s) * 1000)); then
        renew_status=-1
    else
        echo "Renewing Account-$target_account login..."
        renewed_creds=$(refresh_oauth_credentials "$target_creds") || renew_status=$?
    fi
    case "$renew_status" in
        -1) ;;
        0)
            if ! write_account_credentials "$target_account" "$target_email" "$renewed_creds"; then
                echo "Error: Renewed Account-$target_account credentials could not be saved; log in with $target_email and run --add-account"
                exit 1
            fi
            target_creds="$renewed_creds"
            ;;
        2)
            echo "Error: The login for Account-$target_account ($target_email) has expired or was revoked."
            echo "Log in to Claude Code with $target_email, run --add-account, then switch again."
            exit 1
            ;;
        3)
            echo "Error: Could not renew Account-$target_account: token endpoint rate limited. Try again later."
            exit 1
            ;;
        *)
            echo "Error: Could not renew Account-$target_account (network or server error). Nothing was switched."
            exit 1
            ;;
    esac
    
    # Step 3: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    
    # Step 4: Activate target account
    write_credentials "$target_creds"
    
    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    
    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi
    
    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    
    # Step 5: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Switched to Account-$target_account ($target_email)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
    
}

# Exchange a refresh token for a new access token.
# Prints the updated credentials JSON. Returns 2 when the login itself is dead,
# 3 when the token endpoint rate limits us, and 1 on any other failure.
refresh_oauth_credentials() {
    local credentials="$1"
    local body response status

    body=$(jq -c --arg client_id "$OAUTH_CLIENT_ID" \
        '{grant_type: "refresh_token", refresh_token: .claudeAiOauth.refreshToken, client_id: $client_id}' \
        <<<"$credentials") || return 1
    response=$(printf '%s' "$body" | curl -sS --max-time 15 -w '\n%{http_code}' -A "$HTTP_USER_AGENT" \
        -H 'Content-Type: application/json' --data-binary @- "$OAUTH_TOKEN_URL" 2>/dev/null) || return 1
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"

    if [[ "$status" != "200" ]]; then
        if [[ "$status" == "400" || "$status" == "401" ]] && grep -q 'invalid_grant' <<<"$response"; then
            return 2
        fi
        if [[ "$status" == "429" ]]; then
            return 3
        fi
        return 1
    fi

    # Credentials and response travel on stdin so no token shows up in the process list
    printf '%s\n%s\n' "$credentials" "$response" | jq -ce -s --argjson now "$(($(date +%s) * 1000))" '
        .[0] as $creds | .[1] as $r |
        if ($r.access_token | type) != "string" then error("no access token in response") else
            $creds | .claudeAiOauth |= (
                .accessToken = $r.access_token
                | .expiresAt = ($now + $r.expires_in * 1000)
                | if $r.refresh_token then .refreshToken = $r.refresh_token else . end
                | if $r.refresh_token_expires_in then .refreshTokenExpiresAt = ($now + $r.refresh_token_expires_in * 1000) else . end
                | if $r.scope then .scopes = ($r.scope | split(" ")) else . end
            )
        end' 2>/dev/null || return 1
}

# Fetch 5-hour and 7-day usage for an access token.
# Prints the usage JSON, or a short error message and returns 1.
fetch_usage() {
    local access_token="$1"
    local response status

    if ! response=$(curl -sS --max-time 15 -w '\n%{http_code}' -A "$HTTP_USER_AGENT" \
        -H @<(printf 'Authorization: Bearer %s\n' "$access_token") \
        -H "anthropic-beta: $OAUTH_BETA_HEADER" "$OAUTH_USAGE_URL" 2>/dev/null); then
        echo "usage request failed (network)"
        return 1
    fi
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"

    case "$status" in
        200)
            if ! jq -ce . <<<"$response" 2>/dev/null; then
                echo "usage response is not JSON"
                return 1
            fi
            ;;
        401|403) echo "usage request unauthorized (HTTP $status)"; return 1 ;;
        429) echo "usage API rate limited, try again later"; return 1 ;;
        *) echo "usage request failed (HTTP $status)"; return 1 ;;
    esac
}

# Collect one account's token and usage state as a JSON object.
# The active account uses the live credentials, which Claude Code owns, so they are never refreshed here.
dashboard_snapshot_account() {
    local index="$1" num="$2" email="$3" active="$4"
    local credentials token_state="valid" usage="null" error="" meta="null"
    local expires_at refreshed output rc now_ms

    if [[ "$active" == "true" ]]; then
        credentials=$(read_credentials)
    else
        credentials=$(read_account_credentials "$num" "$email")
    fi

    if [[ -z "$credentials" ]] || ! jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1 <<<"$credentials"; then
        token_state="missing"
    else
        now_ms=$(($(date +%s) * 1000))
        expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0 | floor' <<<"$credentials")
        if ((expires_at - 300000 <= now_ms)); then
            if [[ "$active" == "true" ]]; then
                token_state="expired-active"
            else
                rc=0
                refreshed=$(refresh_oauth_credentials "$credentials") || rc=$?
                if ((rc == 0)); then
                    if write_account_credentials "$num" "$email" "$refreshed"; then
                        credentials="$refreshed"
                        token_state="refreshed"
                    else
                        token_state="save-failed"
                    fi
                elif ((rc == 2)); then
                    token_state="relogin"
                elif ((rc == 3)); then
                    token_state="refresh-rate-limited"
                else
                    token_state="refresh-failed"
                fi
            fi
        fi

        if [[ "$token_state" == "valid" || "$token_state" == "refreshed" ]]; then
            rc=0
            output=$(fetch_usage "$(jq -r '.claudeAiOauth.accessToken' <<<"$credentials")") || rc=$?
            if ((rc == 0)); then
                usage="$output"
            else
                error="$output"
            fi
        fi
        meta=$(jq -c '.claudeAiOauth | {plan: .subscriptionType, tier: .rateLimitTier, expiresAt, refreshTokenExpiresAt}' <<<"$credentials")
    fi

    jq -cn --argjson index "$index" --arg num "$num" --arg email "$email" --argjson active "$active" \
        --arg token_state "$token_state" --arg error "$error" --argjson meta "$meta" --argjson usage "$usage" \
        '{index: $index, num: $num, email: $email, active: $active, token_state: $token_state,
          error: (if $error == "" then null else $error end), meta: $meta, usage: $usage}'
}

# Collect every managed account in parallel and print them as a JSON array in sequence order
dashboard_collect() {
    local work_dir="$1"
    local current_email index=0 num email active

    current_email=$(get_current_account)
    rm -f "$work_dir"/*.json
    while IFS=$'\t' read -r num email; do
        active=false
        if [[ "$email" == "$current_email" ]]; then
            active=true
        fi
        {
            dashboard_snapshot_account "$index" "$num" "$email" "$active" ||
                jq -cn --argjson index "$index" --arg num "$num" --arg email "$email" --argjson active "$active" \
                    '{index: $index, num: $num, email: $email, active: $active, token_state: "unknown", error: "could not read this account", meta: null, usage: null}'
        } >"$work_dir/$index.json" &
        index=$((index + 1))
    done < <(jq -r '.sequence[] as $n | "\($n)\t\(.accounts["\($n)"].email)"' "$SEQUENCE_FILE")
    wait

    if ((index == 0)); then
        echo '[]'
    else
        jq -cs 'sort_by(.index)' "$work_dir"/*.json
    fi
}

# Render the dashboard frame from a snapshot array
dashboard_render() {
    local snapshot="$1" selected="$2" color="$3" status="$4" interactive="$5"
    local columns bar_width

    # Usage lines are 52 columns plus the bar; the bar takes what the terminal has left
    columns=$(tput cols 2>/dev/null || echo 80)
    bar_width=$((columns - 54))
    ((bar_width < 8)) && bar_width=8
    ((bar_width > 30)) && bar_width=30

    jq -r --argjson selected "$selected" --argjson color "$color" --arg status "$status" \
        --argjson bar_width "$bar_width" --argjson interactive "$interactive" --arg updated "$(date +%H:%M:%S)" --argjson now "$(date +%s)" '
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
            elif .token_state == "expired-active" then "token expired, Claude Code renews it on use" | c("33")
            elif .token_state == "relogin" then "login dead: log in again, then --add-account" | c("31")
            elif .token_state == "refresh-failed" then "token refresh failed, try r again" | c("33")
            elif .token_state == "refresh-rate-limited" then "refresh rate limited, try r later" | c("33")
            elif .token_state == "save-failed" then "token not saved: log in again, then --add-account" | c("31")
            elif .token_state == "missing" then "no stored credentials" | c("31")
            else .token_state | c("31") end;
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
            ("↑/↓ select   enter switch   1-9 switch to #   r refresh   q quit" | c("2")),
            (if $status != "" then $status else empty end)
         else empty end)
    ' <<<"$snapshot"
}

# Interactive dashboard: token expiry, 5-hour and 7-day usage, and switching
cmd_dashboard() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        first_run_setup
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: Required command 'curl' not found"
        exit 1
    fi

    local work_dir color=false snapshot
    work_dir=$(mktemp -d)
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        color=true
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        snapshot=$(dashboard_collect "$work_dir")
        rm -rf "$work_dir"
        dashboard_render "$snapshot" -1 "$color" "" false
        return
    fi

    DASHBOARD_WORK_DIR="$work_dir"
    trap dashboard_restore_terminal EXIT
    trap 'exit 130' INT TERM
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true

    local selected=0 count status="" key rest target
    dashboard_reload() {
        printf '\033[H\033[2J%s\n' "Loading accounts and usage..."
        snapshot=$(dashboard_collect "$work_dir")
        count=$(jq 'length' <<<"$snapshot")
    }
    dashboard_draw() {
        local frame
        frame=$(dashboard_render "$snapshot" "$selected" "$color" "$status" true)
        printf '\033[H\033[2J%s\n' "$frame"
    }

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
            r | R)
                status=""
                dashboard_reload
                ;;
            q | Q) break ;;
        esac
    done
}

# Ask for confirmation, then switch to the selected dashboard account
dashboard_switch_selected() {
    local num email active answer output rc

    IFS=$'\t' read -r num email active < <(jq -r --argjson i "$selected" '.[$i] | [.num, .email, .active] | @tsv' <<<"$snapshot")
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
        status="Switch failed: $(tail -n1 <<<"$output")"
    fi
    dashboard_reload
    return 0
}

# Leave the alternate screen and remove the dashboard work directory
dashboard_restore_terminal() {
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    if [[ -n "${DASHBOARD_WORK_DIR:-}" ]]; then
        rm -rf "$DASHBOARD_WORK_DIR"
    fi
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account                    Add current account to managed accounts"
    echo "  --remove-account <num|email>    Remove account by number or email"
    echo "  --list                           List all managed accounts"
    echo "  --switch                         Rotate to next account in sequence"
    echo "  --switch-to <num|email>          Switch to specific account number or email"
    echo "  --dashboard                      Show token expiry and 5-hour/7-day usage; switch interactively"
    echo "  --help                           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --dashboard"
    echo "  $0 --remove-account user@example.com"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --dashboard)
            cmd_dashboard
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi