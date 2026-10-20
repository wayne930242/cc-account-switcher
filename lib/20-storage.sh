# shellcheck shell=bash
# ccswitch: Storage: Claude Code config, credential slots, and backups

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
