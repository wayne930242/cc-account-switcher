#!/usr/bin/env bash
# Offline regression tests for ccswitch.sh.
# Each test runs in a sandbox HOME with the Linux file backend; curl and claude are stubs,
# so nothing touches a real keychain, account, or network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Test the development entry by default; CI also runs the suite against the built release file
SCRIPT="${CCSWITCH_SCRIPT:-$ROOT/bin/ccswitch}"
PASSED=0
FAILED=0

FUTURE_MS=$((($(date +%s) + 7200) * 1000))
PAST_MS=$((($(date +%s) - 60) * 1000))

fail() {
    echo "  FAIL: $*"
    FAILED=$((FAILED + 1))
}

pass() {
    PASSED=$((PASSED + 1))
}

expect_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass; else fail "$label: missing '$needle' in: $haystack"; fi
}

expect_equals() {
    local actual="$1" expected="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then pass; else fail "$label: expected '$expected', got '$actual'"; fi
}

creds() {
    # creds <access token> <expiresAt ms> <refresh token>
    jq -cn --arg at "$1" --argjson exp "$2" --arg rt "$3" \
        '{claudeAiOauth: {accessToken: $at, expiresAt: $exp, refreshToken: $rt,
          refreshTokenExpiresAt: ($exp + 86400000 * 20), subscriptionType: "max", rateLimitTier: "default_claude_max_20x"}}'
}

# Log Claude Code in as <email> with <credentials>
login_as() {
    local email="$1" credentials="$2"
    mkdir -p "$HOME/.claude"
    jq -n --arg email "$email" '{theme: "dark", oauthAccount: {emailAddress: $email, accountUuid: ("uuid-" + $email)}}' >"$HOME/.claude.json"
    printf '%s' "$credentials" >"$HOME/.claude/.credentials.json"
}

live_access_token() { jq -r '.claudeAiOauth.accessToken' "$HOME/.claude/.credentials.json"; }
live_email() { jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json"; }
backup_access_token() { jq -r '.claudeAiOauth.accessToken' "$HOME/.claude-switch-backup/credentials/.claude-credentials-$1-$2.json"; }
set_backup() { printf '%s' "$3" >"$HOME/.claude-switch-backup/credentials/.claude-credentials-$1-$2.json"; }
refresh_calls() { grep -c 'oauth/token' "$STUB_LOG" 2>/dev/null || true; }

# Run ccswitch with the Linux file backend
ccswitch() {
    bash -c 'source "$1"; shift; detect_platform() { echo linux; }; main "$@"' ccswitch "$SCRIPT" "$@"
}

write_stubs() {
    mkdir -p "$SANDBOX/bin"
    # curl: oauth/token answers per $STUB_REFRESH (ok, invalid, ratelimit); usage answers 200
    # unless the bearer token starts with "bad"
    cat >"$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
echo "$url" >>"$STUB_LOG"
# Release downloads (curl -fsSL <url> -o <file>) are served from $FAKE_RELEASES/<tag|latest>/<asset>
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == */releases/* ]]; then
        release_url="${args[i]}"
    elif [[ "${args[i]}" == "-o" ]]; then
        output="${args[i + 1]}"
    fi
done
if [[ -n "${release_url:-}" ]]; then
    echo "$release_url" >>"$STUB_LOG"
    if [[ "$release_url" == */releases/latest/download/* ]]; then
        asset_path="latest/${release_url##*/}"
    else
        tag="${release_url#*/releases/download/}"
        asset_path="${tag%%/*}/${release_url##*/}"
    fi
    [[ -f "$FAKE_RELEASES/$asset_path" ]] || exit 22
    cp "$FAKE_RELEASES/$asset_path" "$output"
    exit 0
fi
if [[ "$url" == *oauth/token* ]]; then
    cat >/dev/null
    case "${STUB_REFRESH:-ok}" in
        ok) printf '{"access_token":"good-renewed","refresh_token":"rt-renewed","expires_in":28800,"scope":"user:inference"}\n200' ;;
        invalid) printf '{"error":"invalid_grant"}\n400' ;;
        ratelimit) printf '{"error":{"type":"rate_limit_error"}}\n429' ;;
    esac
    exit 0
fi
header=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == "-H" && "${args[i + 1]}" == @* ]]; then
        header=$(cat "${args[i + 1]#@}")
    fi
done
if [[ "$header" == *"Bearer bad"* ]]; then
    printf '{"error":"unauthorized"}\n401'
else
    printf '{"five_hour":{"utilization":42.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":85.0,"resets_at":"2099-01-02T00:00:00+00:00"},"limits":[{"kind":"weekly_scoped","percent":3,"resets_at":"2099-01-02T00:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}\n200'
fi
EOF
    # claude: succeeds when CLAUDE_CODE_OAUTH_TOKEN starts with "good"
    cat >"$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" == good* ]]; then
    echo '[{"type":"system"},{"type":"result","is_error":false,"result":"OK"}]'
else
    echo '[{"type":"result","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]'
    exit 1
fi
EOF
    chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/claude"
}

# Fresh sandbox with two managed accounts: 1 a@example.com, 2 b@example.com (active)
setup() {
    SANDBOX=$(mktemp -d)
    export HOME="$SANDBOX/home" STUB_LOG="$SANDBOX/calls.log" STUB_REFRESH=ok
    export PATH="$SANDBOX/bin:$ORIGINAL_PATH"
    mkdir -p "$HOME"
    : >"$STUB_LOG"
    write_stubs
    login_as a@example.com "$(creds good-a "$FUTURE_MS" rt-a)"
    ccswitch --add-account >/dev/null
    login_as b@example.com "$(creds good-b "$FUTURE_MS" rt-b)"
    ccswitch --add-account >/dev/null
}

teardown() {
    rm -rf "$SANDBOX"
}

ORIGINAL_PATH="$PATH"

test_add_and_list() {
    local out
    out=$(ccswitch --list)
    expect_contains "$out" "1: a@example.com" "list"
    expect_contains "$out" "2: b@example.com (active)" "list"
    out=$(ccswitch --add-account)
    expect_contains "$out" "already managed" "add twice"
}

test_switch_keeps_valid_token() {
    local out
    out=$(ccswitch --switch-to 1)
    expect_contains "$out" "Switched to Account-1 (a@example.com)" "switch"
    expect_equals "$(live_email)" "a@example.com" "live email"
    expect_equals "$(live_access_token)" "good-a" "live token kept"
    expect_equals "$(backup_access_token 2 b@example.com)" "good-b" "previous account backed up"
    expect_equals "$(refresh_calls)" "0" "no renewal for a valid token"
    expect_equals "$(jq -r .theme "$HOME/.claude.json")" "dark" "settings preserved"
}

test_switch_renews_expired_token() {
    local out
    set_backup 1 a@example.com "$(creds good-a "$PAST_MS" rt-a)"
    out=$(ccswitch --switch-to a@example.com)
    expect_contains "$out" "Renewing Account-1 login" "renew message"
    expect_equals "$(live_access_token)" "good-renewed" "live token renewed"
    expect_equals "$(jq -r .claudeAiOauth.refreshToken "$HOME/.claude/.credentials.json")" "rt-renewed" "refresh token rotated"
    expect_equals "$(backup_access_token 1 a@example.com)" "good-renewed" "renewed token saved to backup"
}

test_switch_stops_on_dead_login() {
    local out status=0
    set_backup 1 a@example.com "$(creds good-a "$PAST_MS" rt-a)"
    STUB_REFRESH=invalid
    out=$(ccswitch --switch-to 1) || status=$?
    expect_equals "$status" "1" "dead login exit status"
    expect_contains "$out" "login expired or revoked" "dead login message"
    expect_contains "$out" "Nothing was switched" "dead login keeps current account"
    expect_equals "$(live_email)" "b@example.com" "live account untouched"
    expect_equals "$(live_access_token)" "good-b" "live token untouched"
}

test_switch_stops_when_rate_limited() {
    local out status=0
    set_backup 1 a@example.com "$(creds good-a "$PAST_MS" rt-a)"
    STUB_REFRESH=ratelimit
    out=$(ccswitch --switch-to 1) || status=$?
    expect_equals "$status" "1" "rate limited exit status"
    expect_contains "$out" "rate limited" "rate limited message"
    expect_equals "$(live_email)" "b@example.com" "live account untouched"
}

test_switch_to_active_account() {
    local out
    out=$(ccswitch --switch-to 2)
    expect_contains "$out" "already active" "already active"
    expect_equals "$(refresh_calls)" "0" "no renewal for the active account"
}

test_switch_rotates() {
    local out
    out=$(ccswitch --switch)
    expect_contains "$out" "Switched to Account-1" "rotate to next"
    out=$(ccswitch --switch)
    expect_contains "$out" "Switched to Account-2" "rotate wraps around"
}

test_switch_to_unknown() {
    local out status=0
    out=$(ccswitch --switch-to 9) || status=$?
    expect_equals "$status" "1" "unknown account exit status"
    expect_contains "$out" "does not exist" "unknown account message"
    status=0
    out=$(ccswitch --switch-to nobody@example.com) || status=$?
    expect_equals "$status" "1" "unknown email exit status"
    expect_contains "$out" "No account found" "unknown email message"
}

test_dashboard_snapshot() {
    local out
    set_backup 1 a@example.com "$(creds good-a "$PAST_MS" rt-a)"
    out=$(ccswitch --dashboard </dev/null)
    expect_contains "$out" "a@example.com" "dashboard account 1"
    expect_contains "$out" "● active" "dashboard active marker"
    expect_contains "$out" "token refreshed" "inactive expired token renewed"
    expect_contains "$out" "42% used" "5-hour usage"
    expect_contains "$out" "85% used" "7-day usage"
    if [[ "$out" == *" left"* ]]; then fail "dashboard still shows left"; else pass; fi
    expect_contains "$out" "7-day Fable" "per-model weekly limit"
    expect_contains "$out" "Max 20x" "plan"
    expect_equals "$(backup_access_token 1 a@example.com)" "good-renewed" "dashboard saved renewed token"
}

test_dashboard_never_renews_live_token() {
    local out
    login_as b@example.com "$(creds good-b "$PAST_MS" rt-b)"
    out=$(ccswitch --dashboard </dev/null)
    expect_contains "$out" "Claude Code renews it on use" "expired live token reported"
    expect_equals "$(refresh_calls)" "0" "live token not renewed"
}

test_dashboard_reports_dead_login() {
    local out
    set_backup 1 a@example.com "$(creds good-a "$PAST_MS" rt-a)"
    STUB_REFRESH=invalid
    out=$(ccswitch --dashboard </dev/null)
    expect_contains "$out" "login expired or revoked" "dead login shown"
}

test_token_test() {
    local out status=0
    out=$(ccswitch --test)
    expect_contains "$out" "1: a@example.com" "test lists account 1"
    expect_contains "$out" "OK: haiku replied" "test passes"
    set_backup 1 a@example.com "$(creds bad-a "$FUTURE_MS" rt-a)"
    out=$(ccswitch --test) || status=$?
    expect_equals "$status" "1" "failed test exit status"
    expect_contains "$out" "FAILED: Failed to authenticate" "failed test message"
    status=0
    out=$(ccswitch --test 2) || status=$?
    expect_equals "$status" "0" "single account test"
    if [[ "$out" == *"a@example.com"* ]]; then fail "single account test listed account 1"; else pass; fi
}

test_remove_account() {
    local out
    out=$(printf 'y\n' | ccswitch --remove-account a@example.com)
    expect_contains "$out" "has been removed" "remove"
    out=$(ccswitch --list)
    if [[ "$out" == *"a@example.com"* ]]; then fail "removed account still listed"; else pass; fi
    if [[ -e "$HOME/.claude-switch-backup/credentials/.claude-credentials-1-a@example.com.json" ]]; then
        fail "removed account credentials left behind"
    else
        pass
    fi
}

test_help() {
    local out
    out=$(ccswitch --help)
    expect_contains "$out" "--dashboard" "help lists dashboard"
    expect_contains "$out" "--test" "help lists test"
}

# Publish a fake release <tag> built from the current modules; "latest" points at the newest one
publish_release() {
    local tag="$1" dir="$FAKE_RELEASES/$1"
    mkdir -p "$dir"
    bash "$ROOT/scripts/build.sh" "${tag#v}" "$dir" >/dev/null
    cp "$ROOT/install.sh" "$dir/install.sh"
    rm -rf "$FAKE_RELEASES/latest"
    cp -R "$dir" "$FAKE_RELEASES/latest"
}

test_version() {
    local out
    out=$(ccswitch --version)
    if [[ "$out" =~ ^ccswitch\ (dev|[0-9]+\.[0-9]+\.[0-9]+.*)$ ]]; then pass; else fail "version output: $out"; fi
}

test_install_latest_and_pinned() {
    local out bin_dir="$SANDBOX/install"
    export FAKE_RELEASES="$SANDBOX/releases"
    publish_release v1.0.0
    publish_release v1.1.0
    out=$(bash "$ROOT/install.sh" --dir "$bin_dir")
    expect_contains "$out" "Installed ccswitch 1.1.0" "installs latest by default"
    expect_equals "$("$bin_dir/ccswitch" --version)" "ccswitch 1.1.0" "installed file runs"
    out=$(CCSWITCH_INSTALL_DIR="$bin_dir" bash "$ROOT/install.sh" --version 1.0.0)
    expect_contains "$out" "Installed ccswitch 1.0.0" "installs a pinned version"
    expect_equals "$(stat -c %a "$bin_dir/ccswitch" 2>/dev/null || stat -f %Lp "$bin_dir/ccswitch")" "755" "installed file is executable"
}

test_install_rejects_bad_checksum() {
    local out status=0 bin_dir="$SANDBOX/install"
    export FAKE_RELEASES="$SANDBOX/releases"
    publish_release v1.0.0
    echo "tampered" >>"$FAKE_RELEASES/latest/ccswitch"
    out=$(bash "$ROOT/install.sh" --dir "$bin_dir" 2>&1) || status=$?
    expect_equals "$status" "1" "bad checksum exit status"
    expect_contains "$out" "Checksum mismatch" "bad checksum message"
    if [[ -e "$bin_dir/ccswitch" ]]; then fail "tampered file was installed"; else pass; fi
}

test_install_unknown_version() {
    local out status=0
    export FAKE_RELEASES="$SANDBOX/releases"
    publish_release v1.0.0
    out=$(bash "$ROOT/install.sh" --dir "$SANDBOX/install" --version v9.9.9 2>&1) || status=$?
    expect_equals "$status" "1" "unknown version exit status"
    expect_contains "$out" "Could not download ccswitch v9.9.9" "unknown version message"
}

test_self_update() {
    local out bin_dir="$SANDBOX/install"
    export FAKE_RELEASES="$SANDBOX/releases"
    publish_release v1.0.0
    bash "$ROOT/install.sh" --dir "$bin_dir" --name ccswitch.sh >/dev/null
    ln -s "$bin_dir/ccswitch.sh" "$SANDBOX/ccswitch-link"
    publish_release v1.1.0
    out=$("$SANDBOX/ccswitch-link" --self-update)
    expect_contains "$out" "Installed ccswitch 1.1.0" "self-update installs latest"
    expect_equals "$("$bin_dir/ccswitch.sh" --version)" "ccswitch 1.1.0" "self-update replaced the real file"
    if [[ -L "$SANDBOX/ccswitch-link" ]]; then pass; else fail "self-update replaced the symlink"; fi
    out=$("$bin_dir/ccswitch.sh" --self-update 1.0.0)
    expect_contains "$out" "Installed ccswitch 1.0.0" "self-update to a pinned version"
}

test_self_update_refuses_source_checkout() {
    local out status=0
    out=$(bash "$ROOT/bin/ccswitch" --self-update) || status=$?
    expect_equals "$status" "1" "source checkout self-update exit status"
    expect_contains "$out" "source checkout" "source checkout self-update message"
}

for test in $(declare -F | awk '{print $3}' | grep '^test_'); do
    echo "$test"
    setup
    "$test"
    teardown
done

echo ""
echo "passed: $PASSED  failed: $FAILED"
((FAILED == 0))
