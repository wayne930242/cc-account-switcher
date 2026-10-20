# shellcheck shell=bash
# ccswitch: Entry point

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
  --self-update [version]          Update ccswitch to the latest (or the given) release
  --version                        Show the installed version
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
  $0 --self-update
EOF
}

main() {
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    case "${1:-}" in
        --version) cmd_version; return ;;
        --help | "") show_usage; return ;;
    esac

    check_bash_version
    require_command jq
    require_command curl

    case "$1" in
        --add-account) cmd_add_account ;;
        --remove-account) shift; cmd_remove_account "$@" ;;
        --list) cmd_list ;;
        --switch) cmd_switch ;;
        --switch-to) shift; cmd_switch_to "$@" ;;
        --dashboard) cmd_dashboard ;;
        --test) shift; cmd_test "$@" ;;
        --self-update) shift; cmd_self_update "$@" ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}
