# Multi-Account Switcher for Claude Code

English | [繁體中文](README.zh-TW.md)

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

> This is a maintained fork of [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher), which has been archived. It adds a usage dashboard and renews a login before switching to it.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Quick switching**: Switch between accounts with simple commands
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged
- **Usage dashboard**: See every account's login expiry and 5-hour/7-day usage, and switch from the same screen
- **Safe switching**: An expired target login is renewed before the switch; a dead login stops the switch and leaves the current account in place

## Installation

Download the script directly:

```bash
curl -O https://raw.githubusercontent.com/wayne930242/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

## Usage

### Basic Commands

```bash
# Add current account to managed accounts
./ccswitch.sh --add-account

# List all managed accounts
./ccswitch.sh --list

# Switch to next account in sequence
./ccswitch.sh --switch

# Switch to specific account by number or email
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com

# Remove an account
./ccswitch.sh --remove-account user2@example.com

# Interactive usage dashboard
./ccswitch.sh --dashboard

# Check that tokens really work (all accounts, or one)
./ccswitch.sh --test
./ccswitch.sh --test 2

# Show help
./ccswitch.sh --help
```

### Dashboard

`--dashboard` shows each managed account with:

- **Login expiry**: when the stored login (refresh token) lapses and you must log in again
- **Token state**: whether the access token is valid, was just renewed, or the login is dead
- **5-hour and 7-day usage**: percent used, with the time until each window resets, plus any per-model weekly limits

Keys: `↑`/`↓` (or `j`/`k`) select, `Enter` switches to the selected account, `1`-`9` switch to that account number, `t` tests the selected account (see below), `r` reloads, `q` quits. Every switch asks for confirmation. The screen reloads every 5 minutes.

To show usage for inactive accounts, the dashboard renews an inactive account's expired access token and saves the result back to that account's backup. It never renews the active account's live token, because Claude Code holds it; when that token has expired, the dashboard says so and Claude Code renews it on its next request.

When stdin or stdout is not a terminal, `--dashboard` prints one snapshot and exits, so it also works in scripts. Set `NO_COLOR` to disable colors.

### Token Test

`--test [num|email]` checks that a stored token actually works, not just that it has not expired: it sends one tiny prompt to Haiku with `claude -p`, using that account's access token through `CLAUDE_CODE_OAUTH_TOKEN`. Without an argument it tests every account in parallel and exits non-zero when any test fails. The test runs in an empty directory with no settings, MCP servers, or tools. It needs the `claude` CLI on `PATH` and uses a few tokens of each account's quota.

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `./ccswitch.sh --add-account` to add it to managed accounts
3. **Log out** and log into Claude Code with your second account
4. Run `./ccswitch.sh --add-account` again
5. Now you can switch between accounts with `./ccswitch.sh --switch`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials change. Your themes, settings, preferences, and chat history remain exactly the same.

## Requirements

- Bash 4.4+
- `jq` (JSON processor)
- `curl` (login renewal and the usage dashboard)
- `claude` (only for `--test` and the dashboard's `t` key)

### Installing Dependencies

**macOS:**

```bash
brew install bash jq
```

macOS ships Bash 3.2, so install a newer one with Homebrew.

**Ubuntu/Debian:**

```bash
sudo apt install jq curl
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Renews the target account's login when its access token expires within an hour, and stops without changing anything when the login is dead
2. Backs up the current account's authentication data
3. Restores the target account's authentication data
4. Updates Claude Code's authentication files

A target token with more than an hour left is kept as is: renewing rotates the refresh token, which would break any running session that still holds the old one.

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./ccswitch.sh --list`
- Read the error message: when the target login has expired or was revoked, log in to Claude Code with that account and run `--add-account`
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Claude Code first
- Check that you have `jq` and `curl` installed
- Verify you have write permissions to your home directory

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `./ccswitch.sh --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `./ccswitch.sh --list`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Delete the script: `rm ccswitch.sh`

Your current Claude Code login will remain active. On macOS, also delete the Keychain items named "Claude Code-Account-…", which removing the backup directory leaves behind.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- Login renewal and usage requests send tokens through stdin, and `--test` passes them through the environment, never as command arguments. Saving credentials to the macOS Keychain still passes them to `security -w` as an argument, so they briefly appear in the process list, as in the original script

## Development

`bash tests/run.sh` runs the offline regression tests: each one uses a sandbox `HOME` with the file-based credential store and stub `curl` and `claude` commands, so it never touches a real Keychain, account, or network.

## License

MIT License - see LICENSE file for details
