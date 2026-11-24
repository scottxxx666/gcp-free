# 評估:把 agent 搬到 Cloud Run 能不能免費跑

評估日期:2026-11-25。目標是從手機請 agent 在 PTT 發文、跑 Claude Code 繼續寫專案,並盡量不花錢。
標 **Unverified** 的是沒有查到第一手來源或沒有實測的項目。數字以官方定價頁為準,下決定前請重新確認。

## 結論

| 工作 | 搬到 Cloud Run 能免費嗎? | 依據 |
|---|---|---|
| Claude Code 寫專案(短任務) | 可以。每月約 62 小時(1 vCPU / 2 GiB) | 已實測可執行 |
| PTT 發文 | **未知**。PTT 擋 GCP IP,現在靠 VM 上的 Cloudflare WARP 繞過,WARP 能否在 Cloud Run 運作沒驗證 | 未測 |
| agent-a / agent-b 常駐 | 不行。要改成被觸發才執行 | 額度計算 |
| bbgo | 不行。常駐加 Binance IP 白名單,Cloud Run 出口 IP 不固定 | 額度計算、README |

VM 目前的成本只有外部 IPv4(約 3.6 USD/月,0.005 USD/小時)。拿掉外部 IP 就要加 Cloud NAT,
約 4.6 USD/月加每 GiB 0.045 USD,**更貴**。唯一省掉這筆費用的方式是不再用 VM,也就是 PTT 和 bbgo 都得離開 VM。

## 免費額度(us-central1)

| 項目 | 免費額度 | 備註 |
|---|---|---|
| Cloud Run Job 運算 | 240,000 vCPU 秒、450,000 GiB 秒 / 月 | 不同頁面有 180,000 / 360,000 的版本,以官方為準 |
| Cloud Run 出流量 | 1 GiB / 月(北美) | |
| Artifact Registry | 0.5 GB | 整個帳單帳戶共用。Node 加 Claude Code 的映像約 267 MB |
| Secret Manager | 6 個有效版本、10,000 次存取 / 月 | |
| Cloud Run Job 單次上限 | 168 小時;預設 10 分鐘 | |
| Cloud Run Service 單次請求上限 | 60 分鐘 | |

常駐容器(0.5 vCPU,24 小時)約 130 萬 vCPU 秒,是額度的 5 倍以上。免費額度只適合事件觸發的短任務。

**沒查到:** Cloud Scheduler 免費額度、Cloud Storage 5 GB 免費額度、Cloud Run 出站是否允許 port 22、
Cloud Run 預設出口是否另收 IP 費用(都是 Unverified)。

## 實測結果:Claude Code 在 Cloud Run Job

做法:映像為 `node:22-slim` 加 `@anthropic-ai/claude-code`,以非 root 使用者(`node`)執行;
token 用 `claude setup-token` 產生,存進 Secret Manager,以環境變數 `CLAUDE_CODE_OAUTH_TOKEN` 注入;
Job 設 `max-retries=0`、task timeout 600 秒、1 vCPU / 2 GiB。

- `claude -p` 純文字回覆和工具使用(寫檔)都成功,沒有出現文獻回報的 `401 Invalid bearer token`。
- `claude` 兩次呼叫共 9 秒;整個 Job 含容器啟動約 51 秒。
- **記憶體峰值沒量到**(容器內讀不到 `memory.peak`)。2 GiB 是保守設定。

### 踩到的坑

- `setup-token` 的輸出在終端機會自動換行,複製會帶入換行,token 變成兩行,
  錯誤訊息為 `Invalid Authorization header value from CLAUDE_CODE_OAUTH_TOKEN: it contains a line break`。
  存入 Secret Manager 前要用 `tr -d '\n\r '` 清掉換行和空白。
- `setup-token` 是互動式介面,在 Claude Code 的 `!` 裡執行看不到 token,要在一般終端機執行。
- `node:22-slim` 沒有 `git`、`ssh`、`curl`,做 git 流程要自己安裝。
- 有 `ANTHROPIC_API_KEY` 時,`claude -p` 永遠優先使用它,會繞過訂閱。
- `--bare` 模式不讀 `CLAUDE_CODE_OAUTH_TOKEN`。

## 條款(依官方 Claude Code 文件,非法律意見)

來源:[Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)、[Authentication](https://code.claude.com/docs/en/authentication)。**沒有讀完整的 Consumer Terms。**

- 文件記載 `setup-token` 用於「CI pipelines and scripts where browser login isn't available」,
  並允許終端使用者用自己的訂閱登入未修改的 Claude Code 二進位檔。
- 禁止的是第三方開發者代使用者轉送訂閱憑證,或收集、存放、中介他人的 Claude.ai 憑證。
- 灰色地帶:訂閱額度「assume ordinary, individual usage」,大量全天候自動化是否算 ordinary 沒有定義;
  文件建議做產品或服務的開發者(含使用 Agent SDK 的)改用 API key;Anthropic 保留不先通知就執法的權利。
- 做法:直接用 `claude -p`,不自己包 Agent SDK 服務;只供自己使用;token 只放自己的 Secret Manager;
  保留改用 API key 的備案。完全合規且不需 token 的做法是 Claude Code 雲端 session 與 `/schedule` routine。

## 若要做 git clone/push,要處理的事

- 映像要安裝 `git` 和 `ca-certificates`。
- Cloud Run 的檔案系統在記憶體裡,沒有大小限制,寫滿會讓實例崩潰。大 repo 用 `git clone --depth 1`。
  來源:[in-memory volume mounts](https://docs.cloud.google.com/run/docs/configuring/in-memory-volumes)。
- 容器結束或逾時後檔案全部消失,成果必須在結束前 push 到分支。
- GitHub 憑證二選一:Deploy key(單 repo、要開寫入權限、不能有 passphrase、需要 known_hosts;
  範例見 [Cloud Build 文件](https://docs.cloud.google.com/build/docs/access-github-from-build))
  或 fine-grained PAT(HTTPS,**沒查到文件**)。HTTPS 比 SSH 保險,因為 port 22 能否出站未驗證。
- 需設定 `git config user.name` 和 `user.email`。
- 安全:憑證只給單一 repo;`main` 設分支保護,只允許推分支再開 PR;注意 repo 內容的 prompt injection。

## 現狀與下一步

- 測試用的 Cloud Run Job、Artifact Registry 儲存庫、secret、服務帳戶都已刪除;三個 API
  (`run`、`artifactregistry`、`secretmanager`)仍啟用,沒有資源就沒有費用。測試用的 token 需到 Claude 帳號設定撤銷。
- 若要重啟,**先驗證 PTT 加 WARP 在 Cloud Run 能不能運作**,這決定整個搬遷是否可行;
  接著驗證 git clone/push 流程;最後才評估 bbgo 是否保留 VM。
- 其他保留項目:預設 VPC 的 `default-allow-ssh` 和 `default-allow-rdp`(來源 0.0.0.0/0)仍存在,
  VM 在自訂 VPC 不受影響,但建議刪除。
