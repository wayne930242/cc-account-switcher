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

# Print "<rows> <columns>" of the controlling terminal, or 24 80 without one. tput cannot be used here: inside $(...)
# its output is a pipe, so it reports its 80x24 default instead of the real size.
dashboard_terminal_size() {
    local size
    if size=$(stty size 2>/dev/null </dev/tty) && [[ "$size" =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]]; then
        echo "$size"
    else
        echo "24 80"
    fi
}

# Render the dashboard frame from a snapshot array.
# The frame fits the terminal: it is at most DASHBOARD_MAX_WIDTH columns wide, never wraps, and in interactive mode
# it is centered and shows only the accounts that fit, always including the selected one.
# In interactive mode the header leaves a blank lane for the crab when every account still fits below it. With
# placement=true the first line is "<row> <column> <lane width>" of that lane on screen, or "0 0 0" without one.
dashboard_render() {
    local snapshot="$1" selected="$2" color="$3" status="$4" status_tone="$5" interactive="$6" placement="${7:-false}"
    local columns rows

    read -r rows columns < <(dashboard_terminal_size)

    jq -r --argjson selected "$selected" --argjson color "$color" --arg status "$status" \
        --arg status_tone "$status_tone" --argjson columns "$columns" --argjson rows "$rows" \
        --argjson max_width "$DASHBOARD_MAX_WIDTH" \
        --argjson interactive "$interactive" --argjson placement "$placement" \
        --argjson crab_width "$CRAB_WIDTH" --argjson crab_travel "$CRAB_MAX_TRAVEL" \
        --arg updated "$(date +%H:%M:%S)" --argjson now "$(date +%s)" '
        # A line is an array of segments {t: text, c: SGR code or null}, so widths are measured without escapes
        def seg($t; $code): {t: $t, c: $code};
        def seg($t): seg($t; null);
        def rep($s; $n): if $n > 0 then [range(0; $n) | $s] | join("") else "" end;
        def pad($n): . + rep(" "; $n - length);
        def lpad($n): rep(" "; $n - length) + .;
        def trunc($n): if length > $n then .[0:([$n - 1, 0] | max)] + "…" else . end;
        def width: map(.t | length) | add // 0;
        def fit($w):
            reduce .[] as $s ({out: [], left: $w};
                if .left <= 0 then .
                elif ($s.t | length) <= .left then .out += [$s] | .left -= ($s.t | length)
                else .left as $left | .out += [seg($s.t | trunc($left); $s.c)] | .left = 0 end)
            | .out;
        def paint: map(if $color and .c != null and .t != "" then "\u001b[\(.c)m\(.t)\u001b[0m" else .t end) | join("");
        # Left segments, then right segments pushed to the right edge of a $w-wide line
        def spread($left; $right; $w): $left + [seg(rep(" "; $w - ($left | width) - ($right | width)))] + $right;

        def dur:
            floor as $s
            | if $s <= 0 then "now"
              elif $s < 3600 then "\($s / 60 | floor)m"
              elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
              else "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h" end;
        def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
        def level($p): if $p >= 80 then "31" elif $p >= 50 then "33" else "32" end;

        ([$columns, $max_width] | min) as $w
        # Usage row: 6 indent, 13 label, bar, 5 percent, 5 " used", 2 gap, then "resets 13h8m" or just "13h8m"
        | ($w >= 64) as $roomy
        | ($w >= 52) as $say_used
        | ([[$w - 6 - 13 - 5 - (if $say_used then 5 else 0 end) - 2 - (if $roomy then 13 else 6 end) - 1, 32] | min, 6]
            | max) as $bar_width

        # Slim bar with half-cell precision: heavy line for the used part, light grey line for the rest
        | def bar($p):
            # Any usage at all shows at least a half cell
            ($bar_width * 2 * $p / 100 | round | [., $bar_width * 2] | min
                | if . == 0 and $p > 0 then 1 else . end) as $halves
            | ($halves / 2 | floor) as $full
            | ($halves % 2) as $half
            | [seg(rep("━"; $full) + (if $half == 1 then "╸" else "" end); level($p)),
               seg(rep("─"; $bar_width - $full - $half); "90")];
          def window($label; $pct; $resets):
            ($pct // 0 | round) as $p
            | [seg("      " + ($label | trunc(12) | pad(13)))] + bar($p)
              + [seg("\($p)%" | lpad(5); level($p))]
              + (if $say_used then [seg(" used"; "2")] else [] end)
              + (if $resets then
                    ($resets | epoch - $now | dur) as $left
                    | [seg("  " + (if $roomy then "resets " else "" end) + $left; "2")]
                 else [] end);
          def plan:
            if .meta == null then ""
            elif (.meta.tier // "" | test("max_[0-9]+x")) then "Max " + (.meta.tier | capture("max_(?<x>[0-9]+x)").x)
            elif .meta.plan then .meta.plan | ascii_upcase[0:1] + .[1:]
            else "" end;
          def login:
            if .meta.refreshTokenExpiresAt == null then seg("login expiry unknown"; "2")
            else (.meta.refreshTokenExpiresAt / 1000 - $now) as $left
                | if $left <= 0 then seg("login expired"; "31")
                  else seg("login expires in " + ($left | dur);
                      if $left < 3 * 86400 then "31" elif $left < 7 * 86400 then "33" else "2" end)
                  end
            end;
          def token:
            if .token_state == "valid" then seg("token valid " + ((.meta.expiresAt / 1000 - $now) | dur); "2")
            elif .token_state == "refreshed" then seg("token refreshed"; "32")
            elif (.token_state | IN("expired-active", "refresh-failed", "refresh-rate-limited")) then seg(.token_message; "33")
            else seg(.token_message; "31") end;
          def head:
            (.index == $selected and $interactive) as $sel
            | ((if .active then [seg("● active"; "1;32")] else [] end)
                + (plan as $plan | if $plan == "" then [] else [seg((if .active then "  " else "" end) + $plan; "35")] end)
                + [seg(" ")]) as $right
            | [seg(if $sel then " ❯" else "  " end; "1;36"),
               seg(.num | lpad(2); if $sel then "1;36" else "2" end),
               seg("  "),
               seg(.email | trunc([$w - 6 - ($right | width) - 2, 8] | max); if $sel then "1;36" else "1" end)] as $left
            | spread($left; $right; $w);
          def account_lines:
            head,
            [seg("      "), login, seg(" · "; "2"), token],
            (if .usage then
                window("5-hour"; .usage.five_hour.utilization; .usage.five_hour.resets_at),
                window("7-day"; .usage.seven_day.utilization; .usage.seven_day.resets_at),
                (.usage.limits // [] | .[] | select(.kind == "weekly_scoped" and .scope.model.display_name != null)
                    | window("7-day " + .scope.model.display_name; .percent; .resets_at))
             elif .error then [seg("      "), seg(.error; "31")]
             else empty end);
          # Key hints: the widest variant that fits, down to the bare keys
          def hints($pairs; $sep): [seg(" ")] + ($pairs | map([seg(.[0]; "1")] + (if .[1] then [seg(" " + .[1]; "2")] else [] end))
                | .[0] + ([.[1:][] | [seg($sep; "2")] + .] | add));
          def keys:
            [hints([["↑↓", "select"], ["⏎", "switch"], ["1-9", "switch to #"], ["t", "test"], ["r", "refresh"], ["q", "quit"]];
                   " · "),
             hints([["↑↓", "select"], ["⏎", "switch"], ["1-9", "#"], ["t", "test"], ["r", "refresh"], ["q", "quit"]]; "  "),
             hints([["↑↓"], ["⏎"], ["1-9"], ["t"], ["r"], ["q"]]; " ")]
            | first(.[] | select(width <= $w)) // last;

        # Frame parts
          (if length == 0 then [[[seg("  No managed accounts. Run --add-account first.")]]]
           else [.[] | [account_lines]] end) as $blocks
        | (if $interactive then
              [[seg(" " + rep("─"; $w - 2); "90")]]
              + (if $status != "" then [[seg(" "), seg($status; if $status_tone == "" then null else $status_tone end)]]
                 else [] end)
              + [keys]
           else [] end) as $bottom

        # Accounts that fit between the top and bottom parts; the blank line between accounts belongs to the
        # account above it. Interactive mode keeps the selected account in view and marks what is cut off.
        | [$blocks | to_entries[] | .value + (if .key < ($blocks | length) - 1 then [[]] else [] end)] as $blocks
        | ($blocks | map(length)) as $heights

        # The crab gets a three-line header when every account still fits under it and the title still fits beside
        # it; its lane is the crab plus up to $crab_travel columns to walk in
        | ($w - 1 - $crab_width - 2 - 20 - 2 - 16 - 1) as $spare
        | (if $interactive and $spare >= 0 and ($heights | add // 0) <= $rows - 4 - 1 - ($bottom | length)
           then $crab_width + ([$spare, $crab_travel] | min) else 0 end) as $lane
        | [seg("updated " + $updated; "2"), seg(" ")] as $updated_seg
        | (if $lane > 0
           then [[], spread([seg(" " + rep(" "; $lane) + "  "), seg("Claude Code accounts"; "1")]; $updated_seg; $w), []]
           else [spread([seg(" "), seg("Claude Code accounts"; "1")]; $updated_seg; $w)] end
           + [[seg(" " + rep("─"; $w - 2); "90")]]) as $top
        | ($rows - ($top | length) - 1 - ($bottom | length)) as $room
        | (if ($interactive | not) or ($heights | add // 0) <= $room then $blocks | add // []
           else ([$room - 2, 1] | max) as $fit
             | ([$selected, 0] | max) as $sel
             | (first(range(0; $sel + 1) as $s | select(($heights[$s:$sel + 1] | add) <= $fit) | $s) // $sel) as $start
             | (reduce range($start; $heights | length) as $i ({used: 0, end: $start, stop: false};
                   if .stop then . elif .used + $heights[$i] <= $fit then .used += $heights[$i] | .end = $i + 1
                   else .stop = true end)
                | [.end, $start + 1] | max) as $end
             | (if $start > 0 then [[seg("   ↑ \($start) more"; "2")]] else [] end)
               + ($blocks[$start:$end] | add | .[0:$fit])
               + (if $end < ($blocks | length) then [[seg("   ↓ \(($blocks | length) - $end) more"; "2")]] else [] end)
           end) as $body
        | ($top + [[]] + $body + $bottom | map(fit($w))) as $lines

        # Center the frame in interactive mode; a snapshot prints flush left
        | (if $interactive then [($columns - $w) / 2 | floor, 0] | max else 0 end) as $left_margin
        | (if $interactive then [($rows - ($lines | length)) / 2 | floor, 0] | max else 0 end) as $top_margin
        | (if $placement then (if $lane > 0 then "\($top_margin + 1) \($left_margin + 2) \($lane)" else "0 0 0" end)
           else empty end),
          (range(0; $top_margin) | ""),
          ($lines[] | rep(" "; $left_margin) + paint | sub(" +$"; ""))
    ' <<<"$snapshot"
}

# The helpers below share cmd_dashboard's locals: snapshot, count, selected, status, status_tone, color

# Set the status line: dashboard_status <SGR code or ""> <message>
dashboard_status() {
    status_tone="$1"
    status="$2"
}

# Reload accounts and usage. The first load shows a centered message; later loads keep the current frame on screen
# and say they are refreshing, so the screen does not go blank every few minutes.
dashboard_reload() {
    local message="Loading accounts and usage…" kept_status="$status" kept_tone="$status_tone" rows columns
    if [[ -z "$snapshot" ]]; then
        printf '\033[H\033[2J'
        read -r rows columns < <(dashboard_terminal_size)
        printf '\033[%d;%dH%s' "$((rows / 2 + 1))" "$(((columns - ${#message}) / 2 + 1))" "$message"
    else
        dashboard_status 2 "Refreshing usage…"
        dashboard_draw
        crab_busy_start
    fi
    snapshot=$(dashboard_collect)
    crab_busy_stop
    count=$(jq 'length' <<<"$snapshot")
    if ((selected >= count)); then
        selected=$((count > 0 ? count - 1 : 0))
    fi
    dashboard_status "$kept_tone" "$kept_status"
}

# Draw over the previous frame in place: each line clears only its own tail and the rest of the screen is cleared
# after the last line, which avoids the flicker of clearing the whole screen first. The crab goes on top.
dashboard_draw() {
    local frame placement
    frame=$(dashboard_render "$snapshot" "$selected" "$color" "$status" "$status_tone" true true)
    placement="${frame%%$'\n'*}"
    frame="${frame#*$'\n'}"
    printf '\033[H%s\033[K\033[J' "${frame//$'\n'/$'\033[K\n'}"
    # shellcheck disable=SC2086  # placement is three numbers
    crab_place $placement
    crab_paint
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
        dashboard_status "" "Account-$num ($email) is already active"
        return 0
    fi
    if ! jq -e 'any(.active)' >/dev/null <<<"$snapshot"; then
        dashboard_status 33 "The logged-in Claude Code account is not managed; run --add-account first"
        return 0
    fi

    dashboard_status "1;33" "Switch to Account-$num ($email)? [y/N]"
    dashboard_draw
    answer=""
    IFS= read -rsn1 answer || true
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        dashboard_status 2 "Switch cancelled"
        return 0
    fi

    # perform_switch exits on error, so it runs in a subshell with errexit kept on
    dashboard_status 2 "Switching to Account-$num…"
    dashboard_draw
    crab_busy_start
    set +e
    output=$(
        set -e
        perform_switch "$num" 2>&1
    )
    rc=$?
    set -e
    crab_busy_stop
    if ((rc == 0)); then
        dashboard_status 32 "✓ Switched to Account-$num. Restart Claude Code to use it."
    else
        dashboard_status 31 "✗ Switch failed: $(grep -m1 '^Error:' <<<"$output" || tail -n1 <<<"$output")"
    fi
    dashboard_reload
}

# Run the claude -p test for the selected account and show the verdict
dashboard_test_selected() {
    local num email active verdict

    if ! command -v claude >/dev/null 2>&1; then
        dashboard_status 31 "Cannot test: 'claude' is not on PATH"
        return 0
    fi
    IFS=$'\t' read -r num email active < <(dashboard_selected_account)
    dashboard_status 2 "Testing Account-$num with claude -p (haiku)…"
    dashboard_draw
    crab_busy_start
    if verdict=$(test_account_inference "$num" "$email" "$active"); then
        crab_busy_stop
        dashboard_status 32 "✓ Account-$num test: $verdict"
    else
        crab_busy_stop
        dashboard_status 31 "✗ Account-$num test: $verdict"
    fi
}

dashboard_restore_terminal() {
    crab_busy_stop
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
}

# Interactive dashboard: token expiry, 5-hour and 7-day usage, testing, and switching.
# Without a terminal it prints one snapshot.
# Print the dashboard snapshot as a JSON array, one object per account, for status bars and scripts
cmd_json() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet" >&2
        exit 1
    fi
    dashboard_collect
}

cmd_dashboard() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        first_run_setup
        exit 1
    fi

    local snapshot="" count=0 selected=0 status="" status_tone="" color=false key rest target
    local resized=false next_reload
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        color=true
        # shellcheck disable=SC2034  # read by crab_paint
        CRAB_COLOR=$(crab_color_code)
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        dashboard_render "$(dashboard_collect)" -1 "$color" "" "" false
        return
    fi

    trap dashboard_restore_terminal EXIT
    trap 'exit 130' INT TERM
    # read is not interrupted by SIGWINCH, so the loop reads with a short timeout, redraws after a resize, and moves
    # the crab on the ticks in between
    trap 'resized=true' WINCH
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true

    dashboard_reload
    selected=$(jq '(map(.active) | index(true)) // 0' <<<"$snapshot")
    next_reload=$((SECONDS + DASHBOARD_REFRESH_SECONDS))

    dashboard_draw
    while true; do
        key=""
        if ! IFS= read -rsn1 -t "$CRAB_TICK_SECONDS" key; then
            if ((SECONDS >= next_reload)); then
                dashboard_status "" ""
                dashboard_reload
                next_reload=$((SECONDS + DASHBOARD_REFRESH_SECONDS))
            elif [[ "$resized" != "true" ]]; then
                crab_tick
                crab_paint
                continue
            fi
            resized=false
            dashboard_draw
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
                    dashboard_status 33 "No account #$key"
                fi
                ;;
            t | T) ((count > 0)) && dashboard_test_selected ;;
            r | R)
                dashboard_status "" ""
                dashboard_reload
                next_reload=$((SECONDS + DASHBOARD_REFRESH_SECONDS))
                ;;
            q | Q) break ;;
        esac
        dashboard_draw
    done
}
