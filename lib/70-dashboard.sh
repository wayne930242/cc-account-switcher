# shellcheck shell=bash
# ccswitch: Dashboard

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

    # Usage lines are 44 columns plus the bar; the bar takes what the terminal has left
    columns=$(tput cols 2>/dev/null || echo 80)
    bar_width=$((columns - 44))
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
              + " " + ("\($p)%" | lpad(4)) + " used"
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
