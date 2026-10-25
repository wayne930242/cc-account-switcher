# Claude Code 多帳號切換工具

[English](README.md) | 繁體中文

在 macOS、Linux 和 WSL 上管理多個 Claude Code 帳號，並在帳號之間切換。

> 這是 [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher) 的分支。原專案已封存，這個分支繼續維護，並加上用量看板，以及切換前先更新登入的功能。

## 功能

- **管理多個帳號**：新增、移除、列出 Claude Code 帳號
- **快速切換**：一行指令就能切到下一個或指定的帳號
- **跨平台**：支援 macOS、Linux 和 WSL
- **安全保存**：macOS 存在鑰匙圈（Keychain），Linux 和 WSL 存在權限 600 的檔案
- **保留設定**：只切換登入資料，佈景主題、設定和偏好都不會變
- **用量看板**：列出每個帳號的登入到期時間、5 小時與 7 天用量，並能在同一個畫面切換帳號
- **安全切換**：目標帳號的 token 快到期時先更新再切換；登入已失效就不切換，維持目前的帳號

## 安裝

安裝最新版（裝到 `~/.local/bin/ccswitch`）：

```bash
curl -fsSL https://github.com/wayne930242/cc-account-switcher/releases/latest/download/install.sh | bash
```

安裝器會下載該版本的 `ccswitch`，先驗證 SHA256 checksum 再安裝。也可以指定版本和安裝位置：

```bash
# 指定版本，裝到其他目錄
curl -fsSL https://github.com/wayne930242/cc-account-switcher/releases/latest/download/install.sh | bash -s -- --version v1.0.0 --dir ~/bin
```

`--version`、`--dir`、`--name` 也可以改用環境變數 `CCSWITCH_INSTALL_VERSION`、`CCSWITCH_INSTALL_DIR`、`CCSWITCH_INSTALL_NAME` 設定。

已安裝的 ccswitch 可以直接更新：

```bash
ccswitch --self-update          # 更新到最新版
ccswitch --self-update v1.0.0   # 更新到指定版本
ccswitch --version
```

所有版本都列在 [Releases 頁面](https://github.com/wayne930242/cc-account-switcher/releases)。

## 使用方式

### 基本指令

```bash
# 把目前登入的帳號加入管理
ccswitch --add-account

# 列出所有帳號
ccswitch --list

# 切到下一個帳號
ccswitch --switch

# 用編號或 email 切到指定帳號
ccswitch --switch-to 2
ccswitch --switch-to user2@example.com

# 移除帳號
ccswitch --remove-account user2@example.com

# 互動式用量看板
ccswitch --dashboard

# 同一份資料的 JSON，給狀態列與腳本用
ccswitch --json

# 實際測試 token 能不能用（全部帳號或指定一個）
ccswitch --test
ccswitch --test 2

# 顯示說明
ccswitch --help
```

### 用量看板

![用量看板](docs/dashboard.png)

`--dashboard` 會列出每個帳號的：

- **登入到期時間**：儲存的登入（refresh token）多久後失效，失效後就得重新登入
- **token 狀態**：access token 是否有效、是否剛更新，或登入已經失效
- **5 小時與 7 天用量**：已用百分比和距離重置的時間，也會列出各模型的每週額度

按鍵：`↑`／`↓`（或 `j`／`k`）選擇帳號，`Enter` 切到選取的帳號，`1`–`9` 切到該編號的帳號，`t` 測試選取的帳號（見下方），`r` 重新整理，`q` 離開。每次切換都會先詢問確認，畫面每 5 分鐘自動更新，並隨終端機大小調整：視窗小時會縮窄，放不下所有帳號時會捲動，讓選取的帳號一直留在畫面上。

空間夠的時候，標題旁邊會有一隻 Claude 橘色的 Clawd 螃蟹：平常會眨眼、左右張望，偶爾橫著走幾步；看板在重新整理、測試或切換帳號時，牠的腳會一直動。終端機矮到放不下全部帳號時，牠會自己讓位。點子來自 [clawd-line](https://github.com/quazar-queso/clawd-line)。

為了查到非使用中帳號的用量，看板會更新這些帳號已過期的 access token，並存回該帳號的備份。使用中帳號的 token 由 Claude Code 持有，看板不會去更新它；這個 token 過期時，看板只會標示出來，Claude Code 下次發出請求時會自己更新。

標準輸入或輸出不是終端機時，`--dashboard` 只印出一次快照就結束，所以也能用在腳本裡。設定 `NO_COLOR` 可以關閉顏色。

`--json` 把同一份快照印成 JSON 陣列，每個帳號一個物件：`num`、`email`、`active`、`token_state`、`error`、`meta`（方案、等級與到期時間），以及用量 API 原樣回傳的 `usage`（`five_hour` 與 `seven_day`，各有百分比的 `utilization` 與 `resets_at`）。它和 dashboard 一樣會更新非使用中帳號過期的 token，所以狀態列應該每隔幾分鐘跑一次，不要每幾秒就跑。

#### 在 Herdr 裡開啟

`herdr-plugin/` 是 [Herdr](https://herdr.dev) 的 plugin，會在畫面中央用浮動 popup 開啟看板，不動到原本的 pane，離開後 popup 自動關閉。

```bash
herdr plugin install wayne930242/cc-account-switcher/herdr-plugin
```

再到 `~/.config/herdr/config.toml` 綁定它的 action：

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "wayne930242.ccswitch.dashboard"
description = "open the ccswitch dashboard"
```

plugin 依序找 `$CCSWITCH_BIN`、`PATH` 上的 `ccswitch`、`~/.local/bin/ccswitch`、`~/bin/ccswitch`、`~/bin/ccswitch.sh`，都沒有就用 plugin 內附的版本。它會把 `/opt/homebrew/bin` 和 `/usr/local/bin` 放到 `PATH` 最前面，所以從 macOS app 啟動的 Herdr 也找得到 Bash 4.4+ 和 `jq`。

### token 測試

token 沒過期，不代表它真的能用。`--test [編號|email]` 會用該帳號的 access token（透過 `CLAUDE_CODE_OAUTH_TOKEN` 傳入），以 `claude -p` 向 Haiku 送出一個很短的提示，確認真的拿得到回應。不帶參數時會平行測試所有帳號，只要有一個失敗就以非 0 結束。測試在空目錄中執行，不載入任何設定、MCP 伺服器或工具。需要 `PATH` 裡有 `claude` 指令，每次測試會用掉各帳號一點點額度。

### 第一次設定

1. 用第一個帳號**登入 Claude Code**
2. 執行 `ccswitch --add-account`，把它加入管理
3. **登出**，再用第二個帳號登入 Claude Code
4. 再執行一次 `ccswitch --add-account`
5. 之後就能用 `ccswitch --switch` 切換帳號
6. **注意**：每次切換後都要重新啟動 Claude Code，新的登入才會生效

> **切換的範圍**：只有登入資料會改變，佈景主題、設定、偏好和對話紀錄都維持原樣。

## 需求

- Bash 4.4 以上
- `jq`（處理 JSON）
- `curl`（更新登入和用量看板）
- `claude`（只有 `--test` 和看板的 `t` 鍵需要）

### 安裝相依套件

**macOS：**

```bash
brew install bash jq
```

macOS 內建的 Bash 是 3.2 版，需要另外用 Homebrew 安裝新版。

**Ubuntu／Debian：**

```bash
sudo apt install jq curl
```

## 運作方式

帳號的登入資料分開保存：

- **macOS**：憑證存在鑰匙圈，OAuth 資訊存在 `~/.claude-switch-backup/`
- **Linux／WSL**：憑證和 OAuth 資訊都存在 `~/.claude-switch-backup/`，並限制存取權限

切換帳號時會依序：

1. 目標帳號的 access token 剩不到 1 小時就先更新登入；登入已失效時直接停止，什麼都不改
2. 備份目前帳號的登入資料
3. 還原目標帳號的登入資料
4. 更新 Claude Code 的登入檔

目標帳號的 token 還有 1 小時以上就沿用，不另外更新。因為每次更新都會換掉 refresh token，還拿著舊 refresh token 的執行中 session 就會失效。

## 疑難排解

### 切換失敗

- 用 `ccswitch --list` 確認帳號已經加入
- 看錯誤訊息：如果是登入已失效，用該帳號重新登入 Claude Code，再執行 `--add-account`
- 試著切回原本的帳號

### 無法新增帳號

- 確認已經登入 Claude Code
- 確認已安裝 `jq` 和 `curl`
- 確認家目錄有寫入權限

### Claude Code 沒有認出新帳號

- 確認切換後有重新啟動 Claude Code
- 用 `ccswitch --list` 查看目前的帳號（標示「(active)」的那個）

## 移除

停用這個工具並刪除所有資料：

1. 用 `ccswitch --list` 記下目前使用的帳號
2. 刪除備份目錄：`rm -rf ~/.claude-switch-backup`
3. 刪除腳本：`rm ccswitch.sh`

目前的 Claude Code 登入會維持有效。macOS 鑰匙圈裡名稱為「Claude Code-Account-…」的項目需要另外刪除。

## 安全性

- 憑證存在 macOS 鑰匙圈，或權限 600 的檔案
- 更新登入和查詢用量時，token 經由標準輸入傳遞；`--test` 則透過環境變數傳遞，都不會出現在指令參數裡。不過存進 macOS 鑰匙圈時，憑證仍是以參數交給 `security -w`，會短暫出現在行程清單（process list）裡，這點和原專案相同

## 開發

原始碼拆成 `lib/` 底下的模組，依檔名順序載入。從原始碼執行時用 `bin/ccswitch`（`ccswitch --version` 會顯示 `dev`）；`scripts/build.sh <版本>` 會把模組組成單一檔案 `dist/ccswitch`，並產生 `dist/ccswitch.sha256`。

```
bin/ccswitch        開發用的進入點
lib/*.sh            模組：設定、環境、儲存、帳號清單、OAuth、指令、token 測試、看板、更新、進入點
scripts/build.sh    建置發布用的單檔
install.sh          隨每個版本發布的安裝器
tests/run.sh        離線回歸測試
```

`bash tests/run.sh` 會執行離線回歸測試。每個測試都在沙盒 `HOME` 中使用檔案型的憑證儲存，並以假的 `curl` 和 `claude` 指令代替，不會碰到真正的鑰匙圈、帳號或網路。`CCSWITCH_SCRIPT=dist/ccswitch bash tests/run.sh` 則是對建置好的單檔跑同一套測試。

要發布新版時，推一個像 `v1.2.0` 的 tag。發布流程會用這個版本號建置 `dist/ccswitch`，對它跑 shellcheck 和測試，再建立 GitHub Release，附上 `ccswitch`、`ccswitch.sha256` 和 `install.sh`。

## 授權

MIT License，詳見 LICENSE 檔案。
