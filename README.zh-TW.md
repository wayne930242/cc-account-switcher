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

直接下載腳本：

```bash
curl -O https://raw.githubusercontent.com/wayne930242/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

## 使用方式

### 基本指令

```bash
# 把目前登入的帳號加入管理
./ccswitch.sh --add-account

# 列出所有帳號
./ccswitch.sh --list

# 切到下一個帳號
./ccswitch.sh --switch

# 用編號或 email 切到指定帳號
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com

# 移除帳號
./ccswitch.sh --remove-account user2@example.com

# 互動式用量看板
./ccswitch.sh --dashboard

# 實際測試 token 能不能用（全部帳號或指定一個）
./ccswitch.sh --test
./ccswitch.sh --test 2

# 顯示說明
./ccswitch.sh --help
```

### 用量看板

`--dashboard` 會列出每個帳號的：

- **登入到期時間**：儲存的登入（refresh token）多久後失效，失效後就得重新登入
- **token 狀態**：access token 是否有效、是否剛更新，或登入已經失效
- **5 小時與 7 天用量**：已用百分比和距離重置的時間，也會列出各模型的每週額度

按鍵：`↑`／`↓`（或 `j`／`k`）選擇帳號，`Enter` 切到選取的帳號，`1`–`9` 切到該編號的帳號，`t` 測試選取的帳號（見下方），`r` 重新整理，`q` 離開。每次切換都會先詢問確認，畫面每 5 分鐘自動更新。

為了查到非使用中帳號的用量，看板會更新這些帳號已過期的 access token，並存回該帳號的備份。使用中帳號的 token 由 Claude Code 持有，看板不會去更新它；這個 token 過期時，看板只會標示出來，Claude Code 下次發出請求時會自己更新。

標準輸入或輸出不是終端機時，`--dashboard` 只印出一次快照就結束，所以也能用在腳本裡。設定 `NO_COLOR` 可以關閉顏色。

### token 測試

token 沒過期，不代表它真的能用。`--test [編號|email]` 會用該帳號的 access token（透過 `CLAUDE_CODE_OAUTH_TOKEN` 傳入），以 `claude -p` 向 Haiku 送出一個很短的提示，確認真的拿得到回應。不帶參數時會平行測試所有帳號，只要有一個失敗就以非 0 結束。測試在空目錄中執行，不載入任何設定、MCP 伺服器或工具。需要 `PATH` 裡有 `claude` 指令，每次測試會用掉各帳號一點點額度。

### 第一次設定

1. 用第一個帳號**登入 Claude Code**
2. 執行 `./ccswitch.sh --add-account`，把它加入管理
3. **登出**，再用第二個帳號登入 Claude Code
4. 再執行一次 `./ccswitch.sh --add-account`
5. 之後就能用 `./ccswitch.sh --switch` 切換帳號
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

- 用 `./ccswitch.sh --list` 確認帳號已經加入
- 看錯誤訊息：如果是登入已失效，用該帳號重新登入 Claude Code，再執行 `--add-account`
- 試著切回原本的帳號

### 無法新增帳號

- 確認已經登入 Claude Code
- 確認已安裝 `jq` 和 `curl`
- 確認家目錄有寫入權限

### Claude Code 沒有認出新帳號

- 確認切換後有重新啟動 Claude Code
- 用 `./ccswitch.sh --list` 查看目前的帳號（標示「(active)」的那個）

## 移除

停用這個工具並刪除所有資料：

1. 用 `./ccswitch.sh --list` 記下目前使用的帳號
2. 刪除備份目錄：`rm -rf ~/.claude-switch-backup`
3. 刪除腳本：`rm ccswitch.sh`

目前的 Claude Code 登入會維持有效。macOS 鑰匙圈裡名稱為「Claude Code-Account-…」的項目需要另外刪除。

## 安全性

- 憑證存在 macOS 鑰匙圈，或權限 600 的檔案
- 更新登入和查詢用量時，token 經由標準輸入傳遞，不會出現在行程清單（process list）裡

## 開發

`bash tests/run.sh` 會執行離線回歸測試。每個測試都在沙盒 `HOME` 中使用檔案型的憑證儲存，並以假的 `curl` 和 `claude` 指令代替，不會碰到真正的鑰匙圈、帳號或網路。

## 授權

MIT License，詳見 LICENSE 檔案。
