# shellcheck shell=bash
# ccswitch: Commands: add, remove, list, switch

cmd_add_account() {
    setup_directories
    init_sequence_file

    local current_email account_num current_creds config
    current_email=$(get_current_account)
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi
    current_creds=$(read_secret live)
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi
    config=$(get_claude_config_path)

    # A managed account keeps its number: saving again stores a fresh login after a revoked one
    account_num=$(account_number_for_email "$current_email")
    if [[ -n "$account_num" ]]; then
        write_secret "$account_num-$current_email" "$current_creds"
        write_account_config "$account_num" "$current_email" "$(cat "$config")"
        write_json "$SEQUENCE_FILE" "$(jq --arg num "$account_num" --arg now "$(timestamp)" \
            '.activeAccountNumber = ($num | tonumber) | .lastUpdated = $now' "$SEQUENCE_FILE")"
        echo "Updated Account $account_num: $current_email (current login saved)"
        return 0
    fi

    account_num=$(jq -r '(.accounts | keys | map(tonumber) | max // 0) + 1' "$SEQUENCE_FILE")
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

# Save the live login to its managed account when it changed, so a /login inside Claude Code
# needs no --add-account. The active account's backup is not read while it is active, so
# replacing it loses nothing. An unmanaged or empty login is left alone.
save_live_login() {
    local email num live config
    [[ -f "$SEQUENCE_FILE" ]] || return 0
    email=$(get_current_account)
    [[ "$email" != "none" ]] || return 0
    num=$(account_number_for_email "$email")
    [[ -n "$num" ]] || return 0
    live=$(read_secret live)
    jq -e '.claudeAiOauth.accessToken | strings' >/dev/null 2>&1 <<<"$live" || return 0
    [[ "$live" != "$(read_secret "$num-$email")" ]] || return 0

    write_secret "$num-$email" "$live" || return 0
    config=$(get_claude_config_path)
    write_account_config "$num" "$email" "$(cat "$config")"
    if [[ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" != "$num" ]]; then
        write_json "$SEQUENCE_FILE" "$(jq --arg num "$num" --arg now "$(timestamp)" \
            '.activeAccountNumber = ($num | tonumber) | .lastUpdated = $now' "$SEQUENCE_FILE")"
    fi
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
    save_live_login
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

    # Rotate from the live login; the recorded active number goes stale after an outside /login
    active_account=$(account_number_for_email "$current_email")
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

    target_email=$(account_email "$target_account")
    current_email=$(get_current_account)
    # The live login decides which backup it goes to; the recorded active number goes stale
    # after a /login outside ccswitch, and a backup under another number is never read again
    current_account=""
    if [[ "$current_email" != "none" ]]; then
        current_account=$(account_number_for_email "$current_email")
        if [[ -z "$current_account" ]]; then
            echo "Error: The current login $current_email is not managed."
            echo "Run '$0 --add-account' to keep it, then switch again. Nothing was switched."
            exit 1
        fi
    fi

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
    if [[ -n "$current_account" ]]; then
        write_secret "$current_account-$current_email" "$(read_secret live)"
        write_account_config "$current_account" "$current_email" "$(cat "$config")"
    fi

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
