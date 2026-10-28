# 231 — FM-Agent 導入評估（實測）

> **問題**：FM-Agent（arXiv 2604.11556v2，LLM 驅動的 Hoare 式推理）能否導入 software_factory？
> **第一階段範圍**（grilling 共識）：本機手動實測、只准報告、不接 CI、不動任何 repo 版控；本檔置於 repo 外。
> **實測日期**：2026-09-25。**讀者**：決定是否進入第二階段（CI advisory）的人。

---

## 0. 結論先講

1. **FM-Agent 確實找得到審查與 Quint 路線都漏掉的真 bug**——Opus 5.5 與 qwen3.8-flash **各自獨立**找到一個 F1–F9 之外、可實際重現的**新活性缺陷**（偶數節點平票時 `acquire()` 永久 pending，§3.3），並都抓到 Quint 表達不了的 **F6 timer 洩漏**。
2. **但它系統性地漏掉「意圖型」缺陷**：三顆模型都沒抓到 F1／F5（Redlock 有效期檢查）、F2、S1；對照組也只命中「會拋例外」型 bug，漏掉兩個意圖型 bug。根因是結構性的（§4.1）：**公開 API 沒有呼叫端，規格只能照實作寫**——論文的核心洞見 I 在函式庫類專案上失效。
3. **模型決定一切**：同一份程式碼，deepseek-flash 0 個嚴格命中、Opus 5.5 與 qwen 各 1 個嚴格命中 ＋ 1 個新真 bug；驗證器對同一行為的判定也隨模型翻轉（§4.3）。qwen 另有**營運不穩定**：同一推理請求在 DashScope 端重複逾時，兩度卡死需人工中止，最終僅完成 10/18 函式（§5.4）。
4. **準確率低**：驗證器「confirmed」不等於真 bug——deepseek 4 個 confirmed 中 3 個是自編規格或 monkey-patch 注入不可達條件（§4.2）。
5. **建議**：可作為 Verify 階段的 **advisory 第二意見**，**不可當閘門**；與 Quint **互補而非替代**。進第二階段前需先解決 §5 的供應鏈與隔離問題。是否進入第二階段由你裁決（Q10 = 不預設門檻）。

---

## 1. 實驗設計（grilling 共識 Q1–Q23）

| 項目 | 設定 |
|---|---|
| 標的 | 上游 `mike-marcacci/node-redlock@afe5cf9`（乾淨 clone；770 行 TS，FM-Agent 抽出 18 個函式） |
| Ground truth | `agent-playground/node-redlock` 分支 `factory/quint-verified-v2` 的 F1–F9 ＋ PR #369 的 S1 |
| 主分母（程式碼層，6 條） | F1 acquire 有效期、F2 Lua 自我阻塞、F5 extend 有效期、F6 timer 洩漏、F7 錯誤遮蔽、S1 settings 未傳遞 |
| 設計層（另列，4 條） | F3 extend 不修復少數節點、F4 abort 諮詢式、F8 崩潰遺失 key、F9 時鐘跳躍 |
| Domain knowledge | 僅 redis.io distributed-locks 頁（sha256 `2289451d…`） |
| 驗證器 | 自訂 `bug_validator_redlock.md`（內建版＋本機 Redis 4 台說明；sha256 `6ae15896…`） |
| 模型 | deepseek-flash（直連 API）、qwen3.8-flash（直連 API）、**claude-opus-5-5（claude-cli 後端，隔離執行，見 §5.3）** |
| FM-Agent 版本 | `fmagent-project/FM-Agent@74a6124`（2026-09-20）、OpenCode 1.18.32、codegraph v1.6.0-fmagent.1 |
| 旗標 | `--submodule src --all-bugs --domain-knowledge … --bug-validator …` |
| 命中口徑 | 嚴格（函式正確＋根因一致）／函式層（函式正確） |
| 對照組 | 本 repo 歷史 bug 重播：`8ff5f1c`、`3c9dca0`、`f53a20d`（`--submodule src/work-item-history`，deepseek） |

### 1.1 事前預測（實驗前寫定，Q11 後）

| 條目 | 預測 | 理由 |
|---|---|---|
| F1、F5、F7、S1 | ✅ 可抓 | 循序邏輯、規格與實作不符 |
| F2 | ⚠️ 邊緣 | 缺陷在 TS 字串內的 Lua，抽取器看不到 |
| F6 | ❌ 抓不到 | 非同步競態，論文明言不支援併發 |
| F3/F4/F8/F9 | ❌ | 系統層性質，非函式契約 |

---

## 2. 成本與時間

| 執行 | 牆鐘 | LLM 呼叫 | tokens | 成本 |
|---|---|---|---|---|
| redlock × deepseek-flash | 69 分（其中 ~30 分為 codegraph 首次下載，GitHub ~100 KB/s） | 258 | 24.5 M | FM-Agent 估 $1.61；**實際帳單 ¥5.10 ≈ $0.71**（DeepSeek 離峰半價） |
| redlock × qwen3.8-flash | **未完成**：12:26–14:07 ＋ resume 14:13–14:30 共 ~118 分，完成 10/18 函式後因 `_execute` 推理請求重複逾時中止（Q24=a） | 未取得（中止無 `run_summary.json`） | 未取得 | 未取得（DashScope 帳單未查詢） |
| redlock × Opus 5.5（claude-cli） | **15 分** | 36（CLI session，每次內含多步） | 不可得（訂閱額度，CLI 不回報） | 以訂閱額度支付，無法換算美元 |
| 對照 `8ff5f1c`（2 函式） | 5 分 | 60 | 4.6 M | 估 $0.28 |
| 對照 `3c9dca0`（1 函式） | 14 分 | 157 | 13.7 M | 估 $0.79 |
| 對照 `f53a20d`（3 函式） | 15 分 | 174 | 15.0 M | 估 $0.85 |

> 比較：工廠 Quint 路線的兩個 agent run（Issue #4、#6）各約 **$0.10**（deepseek-flash，DSH session log）。
> 論文比例（34 億 tokens／277k 行 ≈ 1.2 萬 tokens/行）對 redlock 預估約 900 萬，實測 2,450 萬——**小專案每行成本約為論文均值的 2.7 倍**（固定開銷：setup、domain context、驗證器 agent）。

---

## 3. 結果

### 3.1 Ground truth 命中表

| 條目 | deepseek-flash | qwen3.8-flash | Opus 5.5 | 預測 |
|---|---|---|---|---|
| F1 acquire 有效期 | ❌（acquire 判 MATCH） | ❌（acquire 只報 `Infinity` 邊界） | ❌（MATCH） | ✅ → **錯** |
| F2 Lua 自我阻塞 | ❌ | ❌ | ❌ | ⚠️ |
| F5 extend 有效期 | ❌（MATCH） | ❌（extend 只報 `Infinity` 邊界） | ❌（MATCH） | ✅ → **錯** |
| F6 timer 洩漏 | ❌ | ✅ 嚴格（using.bug-001） | ✅ 嚴格（using.bug-001） | ❌ → **錯（低估）** |
| F7 錯誤遮蔽 | 🟡 函式層／嚴格部分：報「routine 忽略 abort 時 using() 以 routine 值 resolve、signal.error 從未拋出」——正是 PR #369 新增的 `if (signal.aborted && signal.error) throw signal.error`；但「release 錯誤遮蔽 routine 錯誤」那半未提 | ❌ | ❌ | ✅ |
| S1 settings 未傳遞 | ❌ | ⬜ 未涵蓋（`using::extend`／`Lock::extend` 未跑到） | ❌ | ✅ → **錯** |
| **主分母嚴格命中** | **0/6**（F7 部分） | **1/6**（涵蓋 5/6） | **1/6** | |
| 設計層 F3/F4/F8/F9 | 0/4（F7 部分那條同時觸及 F4 的「臨界區在失鎖後繼續」） | 0/4 | 0/4 | |

### 3.2 全部候選的逐則判定

判定類別：**GT**＝命中 ground truth｜**NEW**＝F1–F9 以外的真實可達缺陷｜**EDGE**＝技術上成立但影響可忽略｜**FP-spec**＝依模型自編規格而成立｜**FP-mock**＝需 monkey-patch 注入實際不可能的條件｜**濾除**＝驗證器正確判 not_confirmed。

**deepseek-flash（5 候選／4 confirmed）**

| 候選 | 驗證器 | 判定 | 說明 |
|---|---|---|---|
| `using.bug-001` | confirmed | **GT（F7 部分）** | 見上 |
| `quit.bug-001` | confirmed | FP-mock | probe 把 `client.quit` 換成同步 throw；ioredis `quit()` 回 Promise，不會同步拋錯 |
| `_attemptOperation.bug-001` | confirmed | FP-spec | 模型自編「每方票數 ≤ quorumSize」不變式（B5），驗證器照假規格「確認」 |
| `using::extend.bug-001` | confirmed | FP-mock | 覆寫 `extend` 丟 `Symbol('boom')`，使 `${error}` 拋 TypeError |
| `_execute.bug-001` | not_confirmed | 濾除 | 「client 錯誤未 emit」——驗證器正確反證 |

**Opus 5.5（4 候選／3 confirmed）**

| 候選 | 驗證器 | 判定 | 說明 |
|---|---|---|---|
| `using.bug-001` | confirmed | **GT（F6 嚴格）** | in-flight extension 成功後 `queue()` 重排 timer，`using()` 結束後又 extend 並 abort。probe 以包裝 `extend` 加 200 ms 延遲製造 in-flight 狀態（等同網路延遲，真實可達；qwen 的 probe 則延遲 `evalsha`），非 FP-mock |
| `_attemptOperation.bug-001` | confirmed | **NEW** | 偶數節點平票永久 pending，見 §3.3 |
| `_execute.bug-001` | confirmed | EDGE | `floor(rand*2J)-J` 取不到 +J 端點；delay 分佈差一格，無實害 |
| `Lock::extend.bug-001` | not_confirmed | 濾除 | `duration=Infinity` 通過 `Math.floor` 檢查（行為屬實，但被 Redis 拒絕，無害） |

**qwen3.8-flash（10 候選／9 confirmed；部分執行）**

| 候選 | 驗證器 | 判定 | 說明 |
|---|---|---|---|
| `using.bug-001` | confirmed | **GT（F6 嚴格）** | 同 Opus；probe 延遲 `evalsha` 製造 in-flight |
| `_attemptOperation.bug-001` | confirmed | **NEW** | 4 client、2:2 平票永久 pending——與 Opus **獨立**重現同一缺陷 |
| `acquire.bug-001` | confirmed | EDGE | `duration=Infinity` 通過 `Math.floor` 檢查（最終被 Redis 拒絕） |
| `extend.bug-001` | confirmed | EDGE | 同上 |
| `quit.bug-001` | confirmed | EDGE | `Promise.all` 首個失敗即短路，其餘 client 關閉結果不被等待——屬實但影響小 |
| `Lock::release.bug-001` | confirmed | FP-spec | 模型自訂「已失效 Lock 不得再 release」；第二次 release 刪除的仍是自己的 key，無害 |
| `_execute.bug-001` | confirmed | FP-spec | `retryCount=-1` 無限重試——**README L175 明載為設計行為** |
| `_random.bug-001` | confirmed | FP-mock | 模擬 `randomBytes` 拋錯 |
| `_hash.bug-001` | not_confirmed | 濾除 | |

> qwen 的驗證器 9/10 confirmed，是三者中最寬鬆的：連 README 明載的設計行為都被「確認」為 bug。

### 3.3 新發現：偶數節點平票導致 `acquire()` 永久 pending

- **位置**：`src/index.ts` `_attemptOperation()`（上游 `afe5cf9`；PR #369 未觸及）。
- **機制**：`quorumSize = floor(N/2)+1`。N 為偶數且票數 N/2 : N/2 時兩方都到不了 quorum；「All votes are in」分支只呼叫 `done()`（resolve `statsPromise`），**外層 Promise 永不 resolve**，無逾時。`_execute` → `acquire()`／`extend()`／`release()`／`using()` 全部永久懸掛。
- **可達性**：2 或 4 台 Redis、兩個 client 競爭同一資源各拿到一半節點即觸發——競爭正是分散式鎖的常態。Redlock 建議奇數節點，但函式庫未拒絕偶數設定。
- **重現**：Opus 的 probe（N=2、6380 投 for、6381 預置他人 value 投 against）；**本人親自重跑，3 秒後仍 pending，確認**。qwen 以不同 probe（N=4、2:2，含 3 client 與 4 client 3:1 兩組對照正常 settle）**獨立重現**。
- **上游**：搜尋既有 issue（#58、#83、#169「promise never resolves」）皆早於 v5 重寫或原因不明、已關閉；**無一指出此根因**。
- **待你裁決**：是否開 upstream issue（Q15 決議：經你確認後由我開）。

### 3.4 對照組（本 repo 歷史 bug 重播，deepseek）

| 快照 | 目標 bug（後續 fix） | 結果 | 其他候選 |
|---|---|---|---|
| `8ff5f1c` | `ccaf034` normalizeRepo 遇 `%` 丟 URIError | ✅ **嚴格命中** | `isFactoryWorkItemTask` 陣列未拒（EDGE） |
| `3c9dca0` | `848c85a` repo 欄自帶 `owner/repo` 時重複補 owner | ❌ 主 bug 未中；🟡 次要修正（summarize maxChars 邊界、formatTimestamp 過度接受）部分命中 | 3 則「throwing getter／Proxy」對抗輸入 FP |
| `f53a20d` | `ebe9a54` log 取第一個 issue URL（應取最後一個） | ❌ | `logLines=42` 不可迭代、throwing getter 等 FP |

**型態**：命中的是「**會拋例外**」型；漏掉的兩個都是「**程式照規格跑、規格本身背離意圖**」型——與 redlock 漏 F1/F5 同一失敗模式。

---

## 4. 分析

### 4.1 為何漏掉 F1／F5（最關鍵的發現）

FM-Agent 自己產生的 `engine_overview.txt` **明確寫出**「quorum 通過**且**經過時間在有效期內才算取得」；domain knowledge（redis.io 步驟 3–5）也在 prompt 內。但 `acquire` 的生成規格只寫 `expiration = start + duration − drift`，從未要求 `expiration > now`——**照實作寫規格**，推理器自然判 MATCH（兩顆模型皆然）。

根因：`acquire`／`extend` 是**公開 API，在函式庫內沒有呼叫端**。論文 §4.3 自承入口函式的規格「主要來自實作與 domain knowledge」——論文 Insight I（從呼叫端推導規格、不被 buggy 實作誤導）**只對內部函式有效**。函式庫／SDK 的缺陷恰好多半在公開 API 上，這是結構性限制，非模型能力問題。對照組的兩個漏網（`normalizeRepo`、`extractIssueUrl` 同為模組公開函式）印證同一點。

> 對工廠的意涵：工廠 agent 產出的程式碼多為「被其他模組呼叫的內部函式」時，FM-Agent 的優勢較能發揮；若是公開 API 或 CLI 入口，需要以人寫意圖（Quint 規格、Issue 需求）補足規格來源。

### 4.2 「驗證器 confirmed」不等於真 bug

驗證器的 oracle 是**生成的規格**。規格錯了，驗證器會忠實地「確認」一個不存在的缺陷（deepseek `_attemptOperation` B5）；probe 也可以 monkey-patch 出實際呼叫路徑到不了的輸入（`quit`、`using::extend`）。這與官方 self-improve 部落格自述的兩大誤報來源完全一致。驗證器仍有價值——三個 run 都正確濾掉至少一則——但其 confirmed 率不能當準確率。

### 4.3 模型差異大於方法差異

| | deepseek-flash | qwen3.8-flash（部分） | Opus 5.5 |
|---|---|---|---|
| 主分母嚴格命中 | 0 | 1（F6） | 1（F6） |
| NEW 真 bug | 0 | 1 | 1 |
| 有用候選比例（GT＋NEW）／全部候選 | 1/5 | 2/10 | 2/4 |
| EDGE | 0 | 3 | 1 |
| FP-spec＋FP-mock | 3 | 3 | 0 |
| 驗證器 confirmed／候選 | 4/5 | 9/10 | 3/4 |
| 完成度 | 18/18 | 10/18 | 18/18 |

**審查負擔視角**：審查者每讀到一則 confirmed 報告，得到真價值的機率——deepseek 1/4、qwen 2/9、Opus 2/3。只有 Opus 級的訊噪比，能避免把 Verify 瓶頸惡化（docs/00 §7）。

同一行為（`duration=Infinity` 通過整數檢查）：Opus 驗證器判 not_confirmed、qwen 驗證器判 confirmed——**結論本身隨模型翻轉**。與官方部落格「兩模型僅 16/108 函式完全重疊」一致。任何導入都必須固定模型並記錄版本，否則結果不可比較、不可回歸。

### 4.4 與 Quint 路線的並列比較（Q21）

| 面向 | Quint＋UPPAAL 路線（agent-playground） | FM-Agent 路線（本實驗） |
|---|---|---|
| 缺陷**發現**來源 | F1–F9 在 Issue #4 開單時（09-13 02:20）即為「已定位疑點（程式碼分析結果）」——**發現早於 Quint**，來源未記錄於 repo | 自動，無人工輸入（除 domain knowledge 頁） |
| Quint 的角色 | **確認與存證**：F1/F2/F5/F7 反例→修復後不變式成立＋witness；F3/F4/F8 仍有反例；F9 改由 UPPAAL | — |
| 命中 F1/F5 | ✅（反例＋修復後證明） | ❌（三模型皆漏） |
| 命中 F6 | ❌ Quint 表達不了，改由回歸測試 | ✅（Opus、qwen） |
| F1–F9 以外新發現 | 無 | ✅ 偶數節點平票 hang |
| 設計層 F3/F4/F8/F9 | ✅ 形式化並有反例 | ❌ |
| 假象／誤報 | as-is F7 反例為**模型假象**（README 自承更正） | FP-spec、FP-mock 共 3 則（deepseek） |
| 成本 | agent run 2 × ~$0.10；其後 09-13→09-17 約 20 個人工 commit（人力未計） | deepseek ~$0.71；Opus 訂閱額度；零人工規格 |
| 保證 | 模型檢查在有界深度內窮盡 | 不 sound，無保證 |

**判讀**：兩條路線**互補**——Quint 擅長人已知意圖的關鍵不變式與系統層性質；FM-Agent 擅長廣度掃描、會找到人沒想到要建模的問題（本例的 F6 與平票 hang）。FM-Agent **不能**替代 Quint，也不能取代「先有人理解意圖」這一步。

---

## 5. 導入風險（實測中遇到的）

### 5.1 供應鏈
- `uv sync --locked` **失敗**：必要依賴 `tree-sitter-arkts` 的 git 子模組指向已不存在的 commit（上游破損）。本次以「匯出 requirements 並排除 arkts」繞過（arkts 為延遲載入，TS 分析不受影響）。
- `install.sh` 以 `curl | bash` 安裝 opencode 並預設改寫 `~/.zshrc`；本次改用 `bun add` 本地安裝。
- **oh-my-openagent**（OpenCode 增強 plugin，`@latest` 未鎖版）：**匿名遙測預設開啟**（本次以 `OMO_SEND_ANONYMOUS_TELEMETRY=0` 關閉）；執行中**自動遷移設定**到 `~/.omo/omo.jsonc`，導致 FM-Agent 環境檢查誤報；其子 agent 預設模型為 **`opencode/gpt-5-nano`（OpenCode 託管）**——若被觸發，程式碼會送往未同意的第四方。本次 trace 檢核：deepseek run 444 次請求**全部**送往 `api.deepseek.com`，gpt-5-nano 0 次；但風險存在。
- codegraph 首次執行自 GitHub release 下載 55 MB（本次 ~30 分鐘）。

### 5.2 全域設定變更
會改寫 `~/.config/opencode/`（已備份於 `backup-opencode-config-20260925105532/`）、新增 `~/.omo/`、`~/.cache/fm-agent/`、`~/.cache/opencode/`。CI runner 可接受，開發者本機需告知。

### 5.3 claude-cli 後端的隔離（Opus 路徑）
FM-Agent 以 `claude -p --dangerously-skip-permissions` 呼叫，**無沙箱**。實測發現兩個污染源並已處置（未改 FM-Agent 任何檔案，以 PATH 前置 wrapper `claude-shim/claude` 實現）：
1. 從父 session 繼承的 `CLAUDE*` 環境變數 → wrapper 全數 unset。
2. **使用者全域 `~/.claude/CLAUDE.md` 仍被載入**（`CLAUDE_CONFIG_DIR`、`--setting-sources project,local`、覆寫 `HOME` 皆無效；Opus 以中文回覆即為證據）→ 以 `claudeMdExcludes` 排除後回報「NONE」並改用英文。

另以 `--settings` 開啟 Bash 沙箱：實測可連本機 Redis、寫出工作目錄被 `Operation not permitted` 擋下。**若未做這兩步，Opus 的規格與報告會被使用者個人偏好污染，實驗無效。**

### 5.4 無人值守的可靠性（qwen 實證）
qwen 的 `_execute` 推理請求在 DashScope 端**兩次都在同一處逾時**（`APITimeoutError`）。FM-Agent 的 OpenAI 相容路徑為 SDK 預設逾時 600 s × SDK 重試 2 次，外層再 `_MAX_LLM_RETRIES = 5`——單一請求最長可卡 ~2.5 小時，且期間主日誌完全靜默（階段輸出在結束時才 flush）。放進 CI 必須：外層 job timeout、改短 SDK 逾時、以 `fm_agent/trace/events.jsonl` 的 mtime 做看門狗。

### 5.5 治理對齊
- 不 sound、模型間結論翻轉 → **不可當 required check**（docs/06 §4.3、ADR-005）。
- 官方 Claude Code／Codex plugin 的 `/fm-agent:auto-fix` 為「發現—修—自驗」閉環 → 與 ADR-016 的「產出與生效分離」衝突，**不採用**（Q4）。

---

## 6. 建議與待裁決

**建議的第二階段形態（若你決定進入）**：
1. `factory-run` 完成後，對 agent PR 以 `--incremental <Issue 需求>` 跑 FM-Agent，**只貼 PR 留言**（advisory），不影響 gate。
2. 模型固定 Opus 級（本實驗 deepseek 的有用率 1/5、FP 3 則，噪音會稀釋審查者注意力——正是 docs/00 §7 警告的 Verify 瓶頸）。需先以 API key 量測 Opus 的實際美元成本。
3. 對公開 API／入口函式，把 Issue 需求與既有 Quint 不變式作為 `--domain-knowledge` 餵入，補足 §4.1 的規格來源缺口（待驗證）。
4. 供應鏈：鎖 FM-Agent commit、自維護 arkts 繞道或上游修復、oh-my-openagent 鎖版並關遙測、子 agent 模型改為本方 provider。

**待你裁決**：
- [ ] 是否進入第二階段（CI advisory）。
- [ ] §3.3 偶數節點平票 hang 是否開 upstream issue。
- [ ] F1–F9 最初「程式碼分析」的發現方法與成本（repo 未記錄），以補完 §4.4 比較。

---

## 附錄：可重現性

- 評估目錄：`~/lab/playground/fm-agent-eval/`（`run.sh`、`claude-shim/`、`claude-config/settings.json`、`inputs/`、`runs/<run>/fm_agent/`）。
- 各 run 的 `fm_agent/report.html`、`run_summary.json`、`bug_validation/` probe 與結果均保留。
- Redis：`docker run redis:6` × 4（127.0.0.1:6379–6382，容器名 `fmeval-redis-*`）。
