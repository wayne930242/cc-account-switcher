# shellcheck shell=bash
# ccswitch: OAuth tokens and usage

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
