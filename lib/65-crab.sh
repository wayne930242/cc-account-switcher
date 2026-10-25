# shellcheck shell=bash
# ccswitch: Clawd, the crab in the dashboard header
#
# Clawd is the Claude Code start-up logo, drawn as an 18x6 pixel grid packed two by two into quadrant characters
# (9 columns, 3 rows). Working in pixels lets the eyes and legs move by one pixel. The crab walks a whole column at
# a time: shifted by half a column the quadrants no longer trace its outline. Idea from clawd-line (https://github.com/quazar-queso/clawd-line, MIT).
#
# The dashboard frame leaves a blank lane in its header; the crab is painted over it with cursor moves, so an
# animation tick redraws three short lines instead of the whole frame.

readonly CRAB_WIDTH=9
readonly CRAB_PIXELS=$((CRAB_WIDTH * 2))
# The lane is at most this many columns wider than the crab
# shellcheck disable=SC2034  # read by the dashboard
readonly CRAB_MAX_TRAVEL=12
# shellcheck disable=SC2034  # read by the dashboard
readonly CRAB_TICK_SECONDS=0.25
readonly CRAB_BUSY_TICK_SECONDS=0.2
# Quadrant character for top-left*8 + top-right*4 + bottom-left*2 + bottom-right
readonly CRAB_GLYPHS=(" " "▗" "▖" "▄" "▝" "▐" "▞" "▟" "▘" "▚" "▌" "▙" "▀" "▜" "▛" "█")

# Print a CRAB_PIXELS-wide row of 0s with 1s at the given columns and ranges, e.g. crab_bits 3-4 6-11
crab_bits() {
    local row="" token from to i
    for ((i = 0; i < CRAB_PIXELS; i++)); do
        row+="0"
    done
    for token in "$@"; do
        from="${token%-*}"
        to="${token#*-}"
        for ((i = from; i <= to; i++)); do
            row="${row:0:i}1${row:i+1}"
        done
    done
    printf '%s' "$row"
}

# Pixel rows by part. Eyes are one-pixel gaps in the second row; the legs hang below the body.
CRAB_TOP=$(crab_bits 3-14)
CRAB_EYES_CENTER=$(crab_bits 3-4 6-11 13-14)
CRAB_EYES_LEFT=$(crab_bits 3 5-10 12-14)
CRAB_EYES_RIGHT=$(crab_bits 3-5 7-12 14)
CRAB_EYES_SHUT=$(crab_bits 3-14)
CRAB_CLAWS_OUT=$(crab_bits 1-16)
CRAB_CLAWS_TUCKED=$(crab_bits 2-15)
CRAB_BODY=$(crab_bits 3-14)
CRAB_LEGS_A=$(crab_bits 4 6 11 13)
CRAB_LEGS_B=$(crab_bits 3 5 12 14)
CRAB_NONE=$(crab_bits)
readonly CRAB_TOP CRAB_EYES_CENTER CRAB_EYES_LEFT CRAB_EYES_RIGHT CRAB_EYES_SHUT CRAB_CLAWS_OUT CRAB_CLAWS_TUCKED \
    CRAB_BODY CRAB_LEGS_A CRAB_LEGS_B CRAB_NONE

# Placement on screen (1-based row and column of the lane's top-left cell) and lane width; CRAB_LANE=0 means hidden
CRAB_ROW=0
CRAB_COL=0
CRAB_LANE=0
# Idle state: column offset in the lane, where it is walking to, ticks left to rest, and the current glance
CRAB_X=0
CRAB_TARGET=0
CRAB_REST=8
CRAB_GLANCE=""
CRAB_GLANCE_TICKS=0
CRAB_STEP=0
CRAB_EYES=center
# SGR code for the crab, or empty for no color; the last painted lines, so an unchanged pose is not repainted
CRAB_COLOR=""
CRAB_PAINTED=""
CRAB_BUSY_PID=""

# Claude Code's orange, rgb(215,119,87); 256-color 173 is the nearest where 24-bit color is not advertised
crab_color_code() {
    if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        echo "38;2;215;119;87"
    else
        echo "38;5;173"
    fi
}

# crab_place <row> <column> <lane width>: where the frame left the lane; a lane of 0 hides the crab
crab_place() {
    CRAB_ROW="$1"
    CRAB_COL="$2"
    CRAB_LANE="$3"
    CRAB_PAINTED=""
    local travel=$((CRAB_LANE > CRAB_WIDTH ? CRAB_LANE - CRAB_WIDTH : 0))
    ((CRAB_X > travel)) && CRAB_X=$travel
    ((CRAB_TARGET > travel)) && CRAB_TARGET=$travel
    return 0
}

# Advance the idle animation one tick: rest with an occasional blink or glance, then walk sideways to a new spot
crab_tick() {
    local travel=$((CRAB_LANE > CRAB_WIDTH ? CRAB_LANE - CRAB_WIDTH : 0))

    if ((CRAB_X != CRAB_TARGET)); then
        if ((CRAB_X < CRAB_TARGET)); then
            CRAB_X=$((CRAB_X + 1))
            CRAB_EYES=right
        else
            CRAB_X=$((CRAB_X - 1))
            CRAB_EYES=left
        fi
        CRAB_STEP=$((1 - CRAB_STEP))
        if ((CRAB_X == CRAB_TARGET)); then
            CRAB_STEP=0
            CRAB_REST=$((12 + RANDOM % 28))
        fi
        return 0
    fi

    CRAB_EYES=center
    if ((CRAB_GLANCE_TICKS > 0)); then
        CRAB_GLANCE_TICKS=$((CRAB_GLANCE_TICKS - 1))
        CRAB_EYES="$CRAB_GLANCE"
    elif ((RANDOM % 32 == 0)); then
        CRAB_EYES=shut
    elif ((RANDOM % 40 == 0)); then
        CRAB_GLANCE=$( ((RANDOM % 2 == 0)) && echo left || echo right)
        CRAB_GLANCE_TICKS=$((3 + RANDOM % 6))
        CRAB_EYES="$CRAB_GLANCE"
    fi

    CRAB_REST=$((CRAB_REST - 1))
    if ((CRAB_REST <= 0)); then
        CRAB_GLANCE_TICKS=0
        if ((travel > 0)); then
            CRAB_TARGET=$((RANDOM % (travel + 1)))
        fi
        CRAB_REST=$((12 + RANDOM % 28))
    fi
}

# Print the lane's three lines for a pose: crab_lines <eyes center|left|right|shut> <legs A|B> <claws out|tucked>
crab_lines() {
    local eyes="$1" legs="$2" claws="$3"
    local -a pixels lane
    local pad_left pad_right row r c top bottom index line

    case "$eyes" in
        left) eyes="$CRAB_EYES_LEFT" ;;
        right) eyes="$CRAB_EYES_RIGHT" ;;
        shut) eyes="$CRAB_EYES_SHUT" ;;
        *) eyes="$CRAB_EYES_CENTER" ;;
    esac
    [[ "$legs" == "B" ]] && legs="$CRAB_LEGS_B" || legs="$CRAB_LEGS_A"
    [[ "$claws" == "tucked" ]] && claws="$CRAB_CLAWS_TUCKED" || claws="$CRAB_CLAWS_OUT"
    pixels=("$CRAB_TOP" "$eyes" "$claws" "$CRAB_BODY" "$legs" "$CRAB_NONE")

    # Place the crab CRAB_X columns into the lane
    printf -v pad_left '%*s' "$((CRAB_X * 2))" ""
    printf -v pad_right '%*s' "$(((CRAB_LANE - CRAB_WIDTH - CRAB_X) * 2))" ""
    for row in "${pixels[@]}"; do
        lane+=("${pad_left// /0}${row}${pad_right// /0}")
    done

    for ((r = 0; r < 3; r++)); do
        top="${lane[r * 2]}"
        bottom="${lane[r * 2 + 1]}"
        line=""
        for ((c = 0; c < CRAB_LANE; c++)); do
            index=$((${top:c * 2:1} * 8 + ${top:c * 2 + 1:1} * 4 + ${bottom:c * 2:1} * 2 + ${bottom:c * 2 + 1:1}))
            line+="${CRAB_GLYPHS[index]}"
        done
        printf '%s\n' "$line"
    done
}

# Paint the current pose over the lane, unless it is hidden or already on screen.
# crab_paint busy <phase> paints the busy pose instead: legs shuffling, claws pinching, eyes scanning.
crab_paint() {
    local lines out="" r=0 line
    ((CRAB_LANE > 0)) || return 0

    if [[ "${1:-}" == "busy" ]]; then
        local phase="$2" eyes=left legs=A claws=out
        ((phase / 4 % 2 == 1)) && eyes=right
        ((phase % 2 == 1)) && legs=B
        ((phase % 4 == 1 || phase % 4 == 2)) && claws=tucked
        lines=$(crab_lines "$eyes" "$legs" "$claws")
    else
        lines=$(crab_lines "$CRAB_EYES" "$([[ "$CRAB_STEP" == 1 ]] && echo B || echo A)" out)
    fi
    [[ "$lines" == "$CRAB_PAINTED" ]] && return 0
    CRAB_PAINTED="$lines"

    while IFS= read -r line; do
        if [[ -n "$CRAB_COLOR" ]]; then
            line=$'\033['"${CRAB_COLOR}m${line}"$'\033[0m'
        fi
        out+=$'\033['"$((CRAB_ROW + r));${CRAB_COL}H${line}"
        r=$((r + 1))
    done <<<"$lines"
    printf '%s' "$out"
}

# Keep the crab busy while the dashboard waits on something slow. A background loop paints only the lane; it
# finishes the frame it is painting before it exits, so no half-written escape sequence is left behind.
crab_busy_start() {
    ((CRAB_LANE > 0)) || return 0
    crab_busy_stop
    (
        stop=false
        trap 'stop=true' TERM
        phase=0
        # $$ is the dashboard: if it was killed without running its EXIT trap, stop painting over the shell
        while [[ "$stop" != "true" ]] && kill -0 "$$" 2>/dev/null; do
            crab_paint busy "$phase"
            phase=$((phase + 1))
            # A trapped TERM interrupts wait at once, where it would wait out a foreground sleep
            sleep "$CRAB_BUSY_TICK_SECONDS" &
            wait $! || true
        done
    ) &
    CRAB_BUSY_PID=$!
}

crab_busy_stop() {
    [[ -n "$CRAB_BUSY_PID" ]] || return 0
    kill -TERM "$CRAB_BUSY_PID" 2>/dev/null || true
    wait "$CRAB_BUSY_PID" 2>/dev/null || true
    CRAB_BUSY_PID=""
    CRAB_PAINTED=""
}
