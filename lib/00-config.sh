# shellcheck shell=bash
# ccswitch: Configuration

readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Claude Code OAuth endpoints
readonly OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
readonly OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
readonly OAUTH_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
readonly OAUTH_BETA_HEADER="oauth-2025-04-20"
readonly HTTP_USER_AGENT="ccswitch/${CCSWITCH_VERSION:-dev}"

# Releases: install.sh, ccswitch, and ccswitch.sha256 are attached to every tagged release
readonly CCSWITCH_REPO="wayne930242/cc-account-switcher"

# An inactive token this close to expiry is renewed before use
readonly RENEW_MARGIN_SECONDS=300
# A switch target this close to expiry is renewed first; one with more time left is kept,
# because renewing rotates the refresh token and breaks running sessions that hold the old one
readonly SWITCH_RENEW_MARGIN_SECONDS=3600
readonly DASHBOARD_REFRESH_SECONDS=300
# The dashboard frame is at most this wide; wider terminals center it
readonly DASHBOARD_MAX_WIDTH=78
