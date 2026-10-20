# shellcheck shell=bash
# ccswitch: Account registry (sequence.json)

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
