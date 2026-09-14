# specs/ — node-redlock 的 Quint 可執行規格

本目錄是 `src/index.ts`（node-redlock）的 **as-fixed 形式化規格**：忠實描述
**修復後**的實作。修復前的 as-is 版本見 `git show 691c0e3:specs/redlock.qnt`，
其反例軌跡保留在 `traces/as-is/`。

> **⚠️ 讀者必讀（一）：命名契約。**
> 預期**會**被違反的不變式一律以 `INV_VIOLATED_` 開頭——`quint` 的輸出本身
> 就會說明它的語意。修復後轉為成立的那幾條**已改名去掉前綴**。
> 若某條 `INV_VIOLATED_*` 回報「無違反」，代表**規格已與程式碼脫節**。
>
> **⚠️ 讀者必讀（二）：不變式成立 ≠ 實作正確。**
> 「沒找到反例」有兩種可能：(a) 實作真的正確；(b) **模型根本到不了危險狀態**。
> 後者是假綠燈。因此每一條因修復而成立的不變式都配有 **witness**，
> 證明它守護的危險狀態確實可達（見 §5）。**看不變式結論前請先看 witness 百分比。**

## 檔案

| 檔案                      | 內容                                                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `redlock.qnt`             | 參數化規格（`const` 未實例化，單獨 `quint run` 會失敗）。型別、純函數、狀態機、不變式、witness。**不含任何 `run` 測試**。 |
| `redlockTest.qnt`         | 具體實例模組 + `run` 測試。要跑任何東西都是跑這個檔案，用 `--main=<實例>` 選情境。                                        |
| `traces/*.itf.json`       | **as-fixed 模型**仍然找得到的反例軌跡（F3 / F4 / F8）。                                                                   |
| `traces/as-is/*.itf.json` | **修復前**模型的 7 條反例軌跡（歷史證據，見該目錄的 README）。                                                            |
| `README.md`               | 本檔：驗證報告、覆蓋範圍、CI 草稿、工具鏈限制。                                                                           |

## 如何重跑（完整驗證紀錄）

所有指令都在 repo 根目錄執行。環境：`@informalsystems/quint@0.32.0`、
Java 25（Apalache 由 quint 自動下載，首次需網路）。

### 1. 型別檢查（REQ-1）

```console
$ npx quint typecheck specs/redlock.qnt
$ npx quint typecheck specs/redlockTest.qnt
（兩者皆無輸出 = 通過，退出碼 0）
```

### 2. 可執行性（REQ-2）

```console
$ npx quint run specs/redlockTest.qnt --main=redlockDefault --max-steps 12
[ok] No violation found (…ms at … traces/second).
Trace length statistics: max=13, min=13, average=13.00
```

退出碼 0，輸出**不含** `Uninitialized const`。

### 3. `run` 測試（前提條件、純函數、init 形狀、三個修復的決定性劇本）

```console
$ npx quint test specs/redlockTest.qnt --main=redlockAssumptions
  redlockAssumptions
    ok quorumAssumptionTest passed 1 test(s)
    ok scaleBoundTest passed 1 test(s)
    ok pureFunctionTest passed 1 test(s)
    ok initShapeTest passed 1 test(s)
  4 passing (187ms)

$ npx quint test specs/redlockTest.qnt --main=redlockFixScenario
  redlockFixScenario
    ok retryEscapesSelfBlockTest passed 1 test(s)
    ok acquireValidityCheckTest passed 1 test(s)
    ok extendValidityCheckTest passed 1 test(s)
    ok abortReasonSurvivesReleaseFailureTest passed 1 test(s)
  4 passing (181ms)
```

`redlockFixScenario` 的四條劇本是**決定性**的可達性證明（比隨機 witness 強，
因為可重現且能斷言路徑上的每個中間狀態）：

| 劇本                                    | 證明什麼                                                                                                   |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `retryEscapesSelfBlockTest`             | 與 as-is 版本 `bothClientsStarveTest` **完全相同的交錯**，修復後不再卡死；同時斷言**別人的鎖仍然擋得住**   |
| `acquireValidityCheckTest`              | F1 的檢查確實觸發，且失敗路徑會**補償釋放**部分節點上的 key                                                |
| `extendValidityCheckTest`               | F5 的檢查確實觸發，且修復後的 `extend()` 會**主動釋放**已失效的鎖                                          |
| `abortReasonSurvivesReleaseFailureTest` | `releaseFailed ∧ signalAbort` 同時成立（修復前後都會發生），但回報的是 **SIGNAL_ERROR** 而非 RELEASE_ERROR |

> 最後一條特別重要：它同時證明了「若沿用 as-is 版本的述詞
> `not(releaseFailed and signalAbort)`，修復後**仍然會找到反例**」——
> 那會得出「F7 沒修好」的假結論。F7 的修復改變的是**回報哪一個錯誤**，
> 不是**哪些狀態會發生**，所以述詞必須寫在 `reported` 上。

### 4. 不變式（REQ-3 / REQ-4）

**as-fixed 模型**的實測（本機，全量重跑；`as-is 牆鐘`欄是修復前模型的歷史值）：

| 不變式                                           | 實例               | `--max-steps` | 實測牆鐘（as-fixed） | 修復前 as-is | 預期           | 實測          |
| ------------------------------------------------ | ------------------ | ------------- | -------------------- | ------------ | -------------- | ------------- |
| `neverHandsOutExpiredLock`（F1 ∪ F5）            | `redlockDefault`   | 8             | **123 s**            | —（新）      | 無違反         | ✅ 無違反     |
| `neverSelfBlocked`（F2）                         | `redlockDefault`   | 8             | **218 s**            | —（新）      | 無違反         | ✅ 無違反     |
| `abortReasonNeverMasked`（F7）                   | `redlockDefault`   | 10            | **735 s**            | 125 s        | 無違反         | ✅ 無違反     |
| `neverHandsOutExpiredLock`（敵意環境）           | `redlockCrashLoss` | 8             | **108 s**            | —（新）      | 無違反         | ✅ 無違反     |
| `mutualExclusionOnNodes`（sanity）               | `redlockDefault`   | 8             | **274 s**            | 200 s        | 無違反         | ✅ 無違反     |
| `INV_VIOLATED_twoClientsBelieveLock`（陰性對照） | `redlockDefault`   | 8             | **222 s**            | 147 s        | **不得**有反例 | ✅ 無反例     |
| `INV_VIOLATED_quorumCoverageDecay`（F3）         | `redlockCrashLoss` | 5             | **14 s**             | 13 s         | 必須找到反例   | ✅ 反例 + ITF |
| `INV_VIOLATED_twoClientsBelieveLock`（F8）       | `redlockCrashLoss` | 8             | **33 s**             | 26 s         | 必須找到反例   | ✅ 反例 + ITF |
| `INV_VIOLATED_concurrentCriticalSections`（F4）  | `redlockDefault`   | 12            | **1620 s**           | 784 s        | 必須找到反例   | ✅ 反例 + ITF |

**總計 3 347 s ≈ 56 分鐘**（不含安裝與 Apalache 首次下載）。
**⚠️ 這超過 CI 草稿的 45 分鐘逾時**——見下方「CI 的總牆鐘預算」的取捨選項。

> **⚠️ 為什麼「修復後成立」的那幾條反而最貴：成功比失敗難證明。**
> 「必須找到反例」的搜尋在**淺層就會命中並提早結束**（F3 只要 14 s）；
> 「必須無違反」則**必須窮盡到深度 N** 才能下結論。F7 是最清楚的例子：
> 修復前 125 s（深度 10 就撞到反例），修復後 735 s（**5.9 倍**）——
> 因為它現在得把深度 10 以內整個空間走完。
> 這也解釋了為什麼本次全量重跑比修復前慢：**新增了四條「證明」而非「搜尋」**。

> **as-is 對照欄的來源**：`git show 691c0e3:specs/README.md`。修復前那 7 條 ITF
> 保留在 `traces/as-is/`。註：**as-is 的 F7 反例是模型假象**（見同名更正章節），
> 因此該欄的 125 s 記錄的是「找到一個假反例」所花的時間。

```console
# 真不變式：必須「無違反」、退出碼 0
$ npx quint verify specs/redlockTest.qnt --main=redlockDefault \
    --invariants mutualExclusionOnNodes --max-steps 8
[ok] No violation found

# 被違反的不變式：必須退出碼 ≠ 0 且產出 ITF（不可依賴 stdout 判讀，見 R2）
$ npx quint verify specs/redlockTest.qnt --main=redlockDefault \
    --invariants INV_VIOLATED_quorumCoverageDecay --max-steps 5 \
    --out-itf specs/traces/INV_VIOLATED_quorumCoverageDecay.itf.json
[violation] Found an issue
error: found a counterexample        # 退出碼 1
```

> 註：修復前這裡示範的是 `INV_VIOLATED_returnsExpiredLock`（F1/F5）。
> 該不變式在修復後已不可違反，故改用仍然成立反例的 F3 作示範。

### 5. 正向 witness（REQ-5）—— **反空跑證據，請先看這一節**

四條「修復後成立」的不變式，若沒有 witness 證明其守護的危險狀態可達，
就只是「模型沒走到那裡」的同義反覆。實測（`redlockDefault`，10000 samples，2.1 s）：

```console
$ npx quint run specs/redlockTest.qnt --main=redlockDefault --max-steps 12 \
    --max-samples 10000 --witnesses acquireExpiryDetectable extendExpiryDetectable \
    retryFacesOwnResidualKey releaseFailedWhileAborted reportedSignalError
acquireExpiryDetectable was witnessed in 6779 trace(s) out of 10000 explored (67.79%)
extendExpiryDetectable was witnessed in 61 trace(s) out of 10000 explored (0.61%)
retryFacesOwnResidualKey was witnessed in 2815 trace(s) out of 10000 explored (28.15%)
releaseFailedWhileAborted was witnessed in 12 trace(s) out of 10000 explored (0.12%)
reportedSignalError was witnessed in 31 trace(s) out of 10000 explored (0.31%)
```

> 百分比會因隨機種子小幅變動（例如 `extendExpiryDetectable` 實測落在 0.45%–0.61%）。
> **CI 閘門的判斷是 `> 0`，不是比對特定數值**；上面已說明為何只取前兩個當閘門。

> 註：`releaseFailedWhileAborted` 從保真度修正前的 0.18% 降到 0.12%——
> **那正是假象被移除的證據**：修正前有一部分 trace 是靠「release 之後 routine
> 又跑一次」才讓 `signalAbort` 變真的。剩下的 0.12% 是真正的路徑
> （abort 發生在 release **之前**），並由決定性劇本
> `abortReasonSurvivesReleaseFailureTest` 釘死。

| Witness                     | 守護哪條不變式             | 它證明了什麼「危險狀態確實可達」                                         |
| --------------------------- | -------------------------- | ------------------------------------------------------------------------ |
| `acquireExpiryDetectable`   | `neverHandsOutExpiredLock` | 已達 quorum 但 validity 已耗盡——修復前這裡會交出一把過期的鎖             |
| `extendExpiryDetectable`    | `neverHandsOutExpiredLock` | 續期已達 quorum 但 replacement 的 validity 已耗盡                        |
| `retryFacesOwnResidualKey`  | `neverSelfBlocked`         | 重試時節點上還留著自己的 key，**而且該節點此刻是可取得的**（修復的本體） |
| `releaseFailedWhileAborted` | `abortReasonNeverMasked`   | release 失敗**且**已 abort——兩者確實會同時發生                           |
| `reportedSignalError`       | `abortReasonNeverMasked`   | 確實有 client 以 SIGNAL_ERROR 收場（修復後的回報路徑被走到）             |

**⚠️ 只有 `acquireExpiryDetectable` 與 `retryFacesOwnResidualKey` 適合當 CI 的百分比斷言。**
`extendExpiryDetectable`（0.45%）、`releaseFailedWhileAborted`（0.12%）、
`reportedSignalError`（0.28%）在隨機走訪下機率過低，放進「> 0」的閘門會
**不穩定地紅燈**（見 R3）。它們的可達性改由 §3 的**決定性** `run` 測試釘死
（`extendValidityCheckTest` / `abortReasonSurvivesReleaseFailureTest`）
——那比隨機抽到的 witness 更強，因為它可重現。

> **as-is 版本的兩個 witness 已經不存在**：`selfBlockedByOwnValue`（5.24%）與
> `bothClientsFailWithinRetryWindow`（0.01%）描述的是自我阻塞，修復後
> **恆為 false**。它們在本版轉為不變式 `neverSelfBlocked`。

### 6. 環境注意

`quint verify` 需要 **Java**（本機實測 Java 25 可用；Apalache 0.56.1 由 quint
首次執行時自動下載，需要可寫的 `$HOME` 與網路）。`quint run` 的 Rust 後端同樣
需要可寫的 `$HOME`。CI runner 一般滿足；沙箱環境需 `HOME=<可寫目錄>`。

---

## 已涵蓋（REQ-7）

| 項目                                         | 說明                                                                                                                                                    |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **F1** validity 檢查（**已修復**）           | `completeAcquire` 的 guard `acquireBelieved(cs) > now`；耗盡的那一支走 `abortAcquireExpired`（補償釋放 ＋ 回到 IDLE，單一原子動作）。                   |
| **F2** ACQUIRE 的擋鎖條件（**已修復**）      | `acquireBlockedBy` 改為 `keyExists(e) and e.value != v`——只有別人的 key 才擋。`selfBlocked` 保留為可檢查的觀測點（恆 false）。                          |
| **F3** extend 不修復少數節點                 | `EXTEND_SCRIPT`。`attemptExtend` 只更新投贊成的節點；`permits` 只增不減，真實覆蓋率由 `permitsOf` 以 `nodes` 過濾。**未修復（演算法固有）**。           |
| **F4** abort 諮詢式 / 臨界區重疊             | routine 三態（`UNCHECKED` / `CHECKED` / `CHECKED_LATE`）＋ `criticalWork` 讓鎖可在臨界區執行途中失效。**安全性結論由此條承載；未修復**。                |
| **F5** extend 的 validity 檢查（**已修復**） | `completeExtend` 的 guard `extendBelieved(cs) > now`；耗盡的那一支走 `abortExtendExpired`（**主動釋放**已失效的鎖）。                                   |
| **F7** 錯誤回報優先序（**已修復**）          | `completeRelease` 設定 `reported`：signal.error 優先於 release error。**述詞必須寫在 `reported` 上**，寫在 `releaseFailed ∧ signalAbort` 上會誤判未修。 |
| **F8** 節點崩潰遺失 key（Kleppmann）         | `crashAndLoseKey`，由 `ENABLE_CRASH_LOSS` 控制（**預設 false**）。                                                                                      |
| **F9** 時鐘跳躍                              | `jumpClock`，由 `ENABLE_CLOCK_JUMP` 控制（**預設 false**）。                                                                                            |
| 三層時間                                     | 全域 `now` ＋ 每節點 key 的真實到期 ＋ 每 client 相信的 `expiration`。                                                                                  |
| quorum 前提                                  | `redlockAssumptions::quorumAssumptionTest`（`2f < n`、`quorum = ⌊n/2⌋+1`）。                                                                            |

## 刻意未涵蓋（REQ-7）

| 項目                                        | 為何不做                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **F6（`using()` 的 timer 洩漏，L716-765）** | 它是**單執行緒 JS event loop 的排程缺陷**：in-flight `extension` 在 `clearTimeout` 之後呼叫 `queue()`，重設了一個新的 timeout 而無人清除。要在 Quint 建模它必須引入 JS 事件迴圈與 timer 佇列，成本遠超收益，而且模型本身會比被驗的程式碼更複雜。**替代方案：改用 ava 測試涵蓋**——這個缺陷不需要精確時序交錯即可穩定重現（在 routine 結束時讓 `lock.extend` 懸置，斷言 `using()` 返回後沒有殘留 timer）。建議另開 `agent-add-tests` 工作項。 |
| **`K >= 2` 的多資源鎖**                     | 多資源的 all-or-nothing 由**單一 Lua script 的原子性**保證，那是 Redis 的性質、不是這 770 行的性質。建 `K=2` 只會驗證我們當作公理的東西。代價：`acquire(["a","b"])` 失敗路徑上「部分資源 × 部分節點」的交叉狀態未被涵蓋。                                                                                                                                                                                                                   |
| **ITF 神諭測試（模型 vs 實作 trace 重放）** | `src/index.ts` 依賴真實時間、網路與 Redis；要把一條 Quint 軌跡重放進去，得先建一個能控制時鐘與逐節點注入故障的假 Redis——harness 的複雜度會超過被驗的 770 行，且 harness 自身的缺陷會使結論無法歸因。                                                                                                                                                                                                                                        |
| **jitter / backoff 的時間分佈**             | `_execute` 的重試延遲（L451-463）只被抽象成「可重試 K 次」的非確定性選擇。延遲分佈不影響任何安全性不變式。                                                                                                                                                                                                                                                                                                                                  |
| **崩潰重啟後的 AOF 同步細節**               | F8 只建模「key 消失」這個後果，不建模 Redis 的持久化機制本身。                                                                                                                                                                                                                                                                                                                                                                              |
| **`driftFactor` 的速率漂移**                | 以 `DRIFT` 這個已算好的常數呈現；漂移的**速率**建模不會改變任何不變式。                                                                                                                                                                                                                                                                                                                                                                     |

---

## 不變式清單

| 名稱                                      | 類型                         | 意義                                                                                                                      |
| ----------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `mutualExclusionOnNodes`                  | 真不變式（sanity）           | 不存在兩個 client 同時 `trulyHolds`（至少 quorum 個節點上 key 值相符且未到期）。                                          |
| `neverHandsOutExpiredLock`                | **修復後成立**（F1 ∪ F5）    | 從來沒有一把「結算當下就已過期」的鎖被交給呼叫端。witness：`acquireExpiryDetectable` / `extendExpiryDetectable`。         |
| `neverSelfBlocked`                        | **修復後成立**（F2）         | 從來沒有 client 被「自己的 value」擋住。witness：`retryFacesOwnResidualKey`。                                             |
| `abortReasonNeverMasked`                  | **修復後成立**（F7）         | abort 的原因永不被 release 的錯誤遮蔽（`reported != RELEASE_ERROR` when aborted）。witness：`releaseFailedWhileAborted`。 |
| `INV_VIOLATED_twoClientsBelieveLock`      | **預期違反**（僅 F8 開啟時） | **F8 專屬（Kleppmann）**：不存在兩個 client **同時相信自己持有鎖**。預設情境下**不應**被違反，是 F8 的陰性對照。          |
| `INV_VIOLATED_quorumCoverageDecay`        | **預期違反**                 | client 相信持有有效鎖，但真實覆蓋率已跌破 quorum（F3）。                                                                  |
| `INV_VIOLATED_concurrentCriticalSections` | **預期違反**                 | 兩個 client 同時在臨界區（F4）。**這是承載安全性結論的那一條。**                                                          |

### R1′：前三條「修復後成立」的不變式，有兩條是**結構上必然**的

`neverHandsOutExpiredLock` 與 `neverSelfBlocked` 分別由 `completeAcquire` /
`completeExtend` 的 guard、以及 `acquireBlockedBy` 的定義**直接蘊含**。
模型檢查器驗證它們幾乎不會失敗——所以**不要把「無違反」讀成「證明了實作正確」**。
它們的價值是：

1. **回歸防線**：日後若有人拿掉那些 guard，這兩條立刻紅。
2. 配合 witness 才有內容——witness 證明危險狀態可達，排除「模型沒走到那裡」。

`abortReasonNeverMasked` 在**保真度修正之後**同樣變成結構上必然的：`reported` 在
`completeRelease` 依當下的 `signalAbort` 決定，而 release 完成即代表 `using()` 返回，
`signalAbort` 不會再改變。**這正是修正前它會找到反例的原因**——舊模型允許
`signalAbort` 在 `reported` 決定之後才變真（見下方「as-is 的 F7 反例是模型假象」）。

但它仍是三者中**最有價值的回歸防線**：若有人把 `completeRelease` 的優先序寫反
（release error 排在 signal error 之前），這條會立刻紅，而另外兩條不會。
`releaseFailed ∧ signalAbort` 這個狀態組合確實可達（witness 0.12% ＋ 決定性劇本
`abortReasonSurvivesReleaseFailureTest`），所以它守的不是一個空集合。

### R1：`mutualExclusionOnNodes` 是 sanity check，不承載安全性結論

在 `N=3`、quorum=2 下，兩個 quorum 必有交集節點，而單一節點只存一個 value
——所以「不會有兩把鎖同時存在於節點上」是**鴿籠原理的結構性結論**，
與 F1/F3/F4 是否修好**無關**。

它仍然有價值：能抓**建模錯誤**（quorum 計數寫成 `size/2` 而非 `⌊size/2⌋+1`、
`nodeHolds` 的到期判斷寫反、`permitsOf` 忘了用 `nodes` 過濾）。但它**不能**
被讀成「redlock 是安全的」。真正的安全落差是 `believesHolds` 與 `trulyHolds`
之間的距離，而那由 F4 的不變式承載。

### F3 在預設情境下**不可**違反（實測，且與原始分析不同）

`docs/research/4-quint-spec-feasibility.md` 推測「覆蓋率單調衰減直到靜默失去
quorum」可由自然到期達成。**形式化之後發現不成立**：

client 相信的到期時間是 `start + DURATION - DRIFT`，而節點端 key 的實際到期
時間是 `setTime + DURATION`，其中 `setTime >= start`。因此
`belief <= node_expiry` **恆成立**——「相信」永遠先失效，client 會在被矇住之前
就察覺（`extend` 失敗且 `lock.expiration` 已過期 → `signalAbort`）。

所以 F3 要成立，需要**非對稱的節點失效**：某個節點的 key 比 client 的相信時間
更早消失。實測確認：預設情境（F8/F9 關閉）下 30 步內不可違反；開啟 F8 後
**4 步**即可違反。這是本規格對原始分析的一項**實質修正**，也是 `ENABLE_CRASH_LOSS`
開關存在的理由。

---

## F1–F9 逐條反例結論

下表是 **as-fixed** 模型的結論。「修復前」欄是 as-is 模型的歷史結果
（軌跡在 `traces/as-is/`）。

| 發現                                 | 修復前                        | 修復後（本模型）                                                               | 判定                                          |
| ------------------------------------ | ----------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------- |
| **F1** `acquire()` 缺 validity 檢查  | ✅ 反例（6 步，ITF 5 states） | **不再可違反** → `neverHandsOutExpiredLock`；witness 68.27% ＋ 決定性劇本      | **已修復**                                    |
| **F2** `exists` 自我阻塞             | witness 5.24% / 0.01%         | **不再可違反** → `neverSelfBlocked`；witness `retryFacesOwnResidualKey` 27.24% | **已修復**                                    |
| **F3** extend 不修復少數節點         | ✅ 反例（5 步）               | ✅ **仍有反例**                                                                | 演算法固有，修復未觸及（**需 F8 開關**）      |
| **F4** 臨界區重疊                    | ✅ 反例（12 步，13 states）   | ✅ **仍有反例**                                                                | **承載安全性結論**；需 fencing token 才能消除 |
| **F5** `extend()` check-then-act     | ✅ 反例（8 步）               | **不再可違反** → `neverHandsOutExpiredLock`；witness 0.41% ＋ 決定性劇本       | **已修復**                                    |
| **F6** timer 洩漏                    | ❌（Quint 之外）              | 同左：由 `specs/oracle/counterexamples.test.mjs` 的回歸測試涵蓋                | **已修復**（不在 Quint 內）                   |
| **F7** release 失敗遮蔽錯誤          | ✅ 反例（10 步）              | **不再可違反** → `abortReasonNeverMasked`（述詞已改寫，見下）                  | **已修復**                                    |
| **F8** 節點崩潰遺失 key（Kleppmann） | ✅ 反例（8 步）               | ✅ **仍有反例**                                                                | 環境假設，修復未觸及（**需 F8 開關**）        |
| **F9** 時鐘跳躍                      | ❌ 模型無法證否               | 同左                                                                           | **見「F9 的建模缺陷」**                       |

計數：**3 條經模型檢查確認已修復**（F1、F5、F7）＋ **1 條 F2**（自我阻塞不再可違反）、
**3 條仍有反例**（F3、F4、F8）、**1 條在 Quint 之外**（F6）、**1 條模型表達不出來**（F9）。

> **F7 的述詞必須改寫，否則會得出假結論。** as-is 版本寫的是
> `not(releaseFailed and signalAbort)`——那描述的是**兩件事同時發生**，
> 而那個狀態組合修復前後**都會發生**。修復改變的是 `using()` **回報哪一個錯誤**，
> 所以 as-fixed 的述詞寫在 `reported` 上。沿用舊述詞會「找到反例」並誤判 F7 未修。
> 這一點由 `abortReasonSurvivesReleaseFailureTest` 明確斷言（它同時 expect 了
> 舊述詞的違反條件與新述詞的成立）。

## as-is → as-fixed：這次改了模型的哪些地方

`src/index.ts` 修復了 F1 / F5 / F2 / F6 / F7，本規格隨之改寫。逐項對照：

| 模型位置                         | as-is（修復前）                                     | as-fixed（本版）                                                               |
| -------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------ |
| `acquireBlockedBy`               | `keyExists(e)`——不問是誰的                          | `keyExists(e) and e.value != v`——只有**別人的** key 才擋（**F2**）             |
| `completeAcquire` 的 guard       | 只要 quorum 就交出鎖                                | 追加 `acquireBelieved(cs) > now`（**F1**）                                     |
| `abortAcquireExpired`（新動作）  | —                                                   | validity 耗盡 → **補償釋放 ＋ 回到 IDLE**（與 `failAcquire` 同為單一原子動作） |
| `completeExtend` 的 guard        | 只要 quorum 就交出 replacement                      | 追加 `extendBelieved(cs) > now`（**F5**）                                      |
| `abortExtendExpired`（新動作）   | —                                                   | validity 耗盡 → **主動釋放已失效的鎖**，abort 判定與 `failExtend` 一致         |
| `ClientState.reported`（新欄位） | —                                                   | using() 最終回報什麼；優先序 signal.error → release error（**F7**）            |
| `AcquireKind`                    | `NO_VALIDITY_CHECK`                                 | `VALIDITY_CHECKED`                                                             |
| 觀測旗標                         | `returnedExpired` / `expiredViaAcquire` / `…Extend` | 合併為 `handedExpiredLock`（恆 false，作為回歸防線）                           |

**移除的狀態多於新增的**：三個歷史旗標合併成一個，換來一個 `reported` 列舉，
因此狀態空間大致持平（實測牆鐘見 §4 與「規模與界」）。

### 一個刻意的取捨：兩條不變式是結構上必然的

`neverHandsOutExpiredLock` 與 `neverSelfBlocked` 由動作 guard 與純函數定義直接蘊含
（見 R1′）。可以改寫成「更難證」的形式嗎？可以，但那會讓模型偏離實作——
真實程式碼的檢查**就是**寫在那兩個結算點上。與其把模型寫得比程式碼複雜，
不如誠實標示「這兩條是回歸防線，不是新知識」，並用 witness 撐住非空跑性。

**真正帶來新知識的是 `abortReasonNeverMasked`**：它證明了在
「release 失敗 ∧ 已 abort」這個**確實可達**的狀態下，修復後回報的是 abort 的原因。

### 修復的正確性現在有兩層背書

| 層次       | 證據                                                                                      |
| ---------- | ----------------------------------------------------------------------------------------- |
| **實作層** | 紅綠對照：同一套測試對修復前的 `src/index.ts` 全數轉紅（下表）                            |
| **模型層** | as-fixed 的 `quint verify`：F1 / F5 / F2 / F7 的不變式無違反，且 witness 證明危險狀態可達 |

| 套件                                    | 修復前 `38f792e`                                      | 修復後 HEAD      |
| --------------------------------------- | ----------------------------------------------------- | ---------------- |
| `specs/oracle/counterexamples.test.mjs` | 7 pass / **4 fail**                                   | 11 pass / 0 fail |
| `specs/oracle/lua-parity.test.mjs`      | 11 pass / **3 fail**（2 個 ACQUIRE 情境 ＋ 其父測試） | 14 pass / 0 fail |
| `src/fixes.test.ts`（ava）              | **0 pass / 8 fail**                                   | 8 pass / 0 fail  |

**F3 / F4 / F8 修復前後都成立**——它們是演算法層與環境假設層的性質
（節點遺失 key、諮詢式 abort 的 TOCTOU、無 fencing token），不是實作瑕疵。
`specs/oracle/` 的 F4(b) / F4(c) 在實作層得到同樣的結論。

## ⚠️ 更正：as-is 的 F7 反例是**模型假象**（本次轉換時發現）

轉成 as-fixed 之後，`abortReasonNeverMasked` **意外地找到了反例**（`rc=1`，383 s）。
追查後發現那不是實作問題，而是**模型的保真度缺陷**——而且**同一個缺陷也讓
as-is 版本的 F7 反例失去意義**。

解碼 `traces/as-is/INV_VIOLATED_releaseErrorMasksAbort.itf.json` 的最後兩個狀態：

```
state 8  c2 AFTER_ACQUIRE   abort=false relFail=true  relDone=true  lockVal=0
state 9  c2 ISOLATION_CHECK abort=true  relFail=true  relDone=true  lockVal=0
```

第 8 狀態：release **已經完成且失敗**，但 `signalAbort` 還是 `false`。
第 9 狀態：`doIsolationCheck` 又跑了一次，把 `signalAbort` 設成 `true`
——於是 `releaseFailed ∧ signalAbort` 成立，「反例」就這樣產生了。

**但真實程式碼不可能這樣。** `using()` 的順序是
`routine(signal)` → `await extension` → `await lock.release()` → 決定回報什麼。
routine（以及它裡面所有的 `signal.aborted` 檢查）**嚴格早於** release。
release 完成後 `using()` 就返回了，不會再有 isolation check。

根因：`completeRelease` 原本**不改 `acquirePhase`**，而 `doIsolationCheck` 的 guard
只要求 `acquirePhase == AFTER_ACQUIRE`。於是模型允許「release 之後 routine 又跑一次」。

**修正**：`completeRelease` 追加 `acquirePhase: IDLE`（= `using()` 返回）。
這一行同時讓 `doIsolationCheck` / `enterCritical` / `startExtend` 在 release 之後
全部不再 enabled。回歸測試：`redlockFixScenario::usingCycleEndsAtReleaseTest`。

### 這個更正的意義

| 主張                       | 更正後                                                                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 「Quint 找到了 F7 的反例」 | ❌ **那條反例是假象**。Quint **從來沒有**真正示範過 F7。                                                                     |
| 「F7 是真的缺陷嗎？」      | ✅ **是**，但證據在**實作層**，不在模型層：`src/fixes.test.ts` 的「routine 拋錯不再被 release 失敗遮蔽」修復前紅、修復後綠。 |
| 「as-is 的其他反例呢？」   | F3 / F4 / F8 在**修正後的模型**上重新產生，仍然成立（見 §4 的重跑數據）。                                                    |

**教訓**：`INV_VIOLATED_*` 回報「找到反例」時，**必須解碼軌跡確認違反的路徑是真的**。
「有反例」和「反例有意義」是兩件事——這與 `--witnesses` 為 0%、
`node --test` 的 skip 仍 exit 0 是同一類陷阱：**退出碼不等於結論**。
本次是因為把模型轉成 as-fixed、預期它**不該**有反例，才逼出這個檢查。

## F2 的保真度修正（本次修訂）

**修正前的模型有一個真實到不了的狀態。** 舊版把 `releaseResidual` 寫成 `step` 裡的
**自由動作**（guard 只有 `IDLE ∧ holdsSomething`），於是模型允許 client 停在
**IDLE 且帶著殘留 key**。但真實程式碼不是這樣：`acquire()` 的補償釋放與「回到
caller」是**同一個 `await` 的兩半**——`await this._execute(releaseScript, …,
{retryCount: 0})` 完成之後才 `throw error`（`src/index.ts:330-340`）。因此
**IDLE 必然代表手上沒有殘留 key**。

**修正方式**（`redlock.qnt`）：

1. 新增 `const RETRY_BUDGET` 與 `ClientState.retriesLeft`——模型第一次能區分
   「重試中」與「預算耗盡」。
2. `retryAcquire` **留在 `AWAIT_ACQUIRE`**（真實的 retry 是 `_execute` 的 while 迴圈，
   client 根本沒有回到 caller），保留 `lock.value` 與殘留 key → **F2 的機制完整保留**。
3. 以 `failAcquire` **取代**自由的 `releaseResidual`：它把「補償釋放」與「回到 IDLE」
   寫成**同一個動作**，因此不再存在「放棄但不清理」這個選項。
4. `bothClientsFailWithinRetryWindow` 的述詞從
   「兩人都已 IDLE 且帶著殘留 value」改為
   「兩人都**仍在重試窗口內**、本次 attempt 已完成、未達 quorum」。

**修正的後果（實測）**：

|                                            | 修正前                     | 修正後                             |
| ------------------------------------------ | -------------------------- | ---------------------------------- |
| `selfBlockedByOwnValue` witness            | 1.19%                      | **5.24%**                          |
| `bothClientsFailWithinRetryWindow` witness | **0%**（隨機走訪下不可達） | **0.01%**（1/10000，現在真的可達） |

舊述詞在隨機走訪下是 0%，本身就是「那個狀態其實到不了」的訊號——修正後它變成
非零。危害**沒有消失，只是被放到正確的位置**：它是重試窗口內的問題，不是窗口外的
殘留污染。

> **⚠️ 本節是 as-is 時期的紀錄。** `RETRY_BUDGET` / `retriesLeft` / `failAcquire`
> 這三項保真度修正在 as-fixed 版本中**全部保留**（它們與 F2 的修復正交：
> 一個講「重試的邊界在哪」，一個講「重試時會不會被自己擋住」）。
> 但上表的兩個 witness 已經不存在——自我阻塞在修復後恆為 false，
> 改由不變式 `neverSelfBlocked` ＋ witness `retryFacesOwnResidualKey` 接手。
>
> 這一節仍然值得留著，因為它記錄了一次**方法論上的發現**：
> **「witness 是 0%」是模型過度近似的訊號，不是「這個情況不會發生」的結論。**
> as-fixed 版本的四個 witness 全部非零，就是照著這條教訓設計的。

## F9 的建模缺陷（實測後確認，**保留為獨立後續項**）

`ENABLE_CLOCK_JUMP` 這個開關**實際上是空的**：它開與不開，可達狀態集完全相同。

理由（構造性證明，不需實測）：`jumpClock` 設 `now' = now + 1 + STALL_BOUND`，
而 `advanceTime` 把 `now` 加 1 且**沒有 guard、恆可使用**。因此
「一次 `jumpClock`」永遠可以被「`1 + STALL_BOUND` 次 `advanceTime`」逐步模擬，
也就是 clockJump 實例的可達狀態集是 default 的**子集**——它不可能產生 default
產生不了的反例。實測也印證：`redlockClockJump` 下會違反的不變式
（修復前如 `INV_VIOLATED_returnsExpiredLock`）在 default 下同樣會違反。
修復後該條已不可違反，但 F3 / F4 這兩條仍成立的反例在 clockJump 下同樣可重現。

**根因不是實作，是建模決策 5**：「全域單一 `now` ＋ 每節點到期 ＋ 每 client 相信的
到期」把 client 時鐘與 Redis 伺服器時鐘**合而為一**。但 F9 的定義恰恰是
「`Date.now()` 被 NTP 跳躍」——**客戶端的牆鐘跳了，Redis 的 TTL 沒有跳**。
單一時鐘表達不出這個差異。

**修正方式（需人類裁定是否納入）**：把 `now` 拆成兩個時鐘——

```
var clientNow: int   // 對應 Date.now()；believesHolds / acquireBelieved 用它
var nodeNow:   int   // Redis 伺服器時鐘；SET ... PX 的到期與 keyExists 用它
```

`advanceTime` 同時推進兩者；`jumpClock` **只推進 `clientNow`**。
如此，一次向前跳躍會讓 client 相信鎖已過期（或相信自己還有很久）
而節點上的 key 仍在——F9 才可證否。

**裁定結果：本項保留為獨立的後續工作項，不在本次修訂內。** 理由：它會改變
**建模決策 5**、牽動 `believesHolds` / `acquireBelieved` / `keyExists` 約十餘處，
是一個可獨立審查的單位；把它與 F2 的保真度修正混在同一顆 diff 裡，會讓審查者
無法分辨「哪個改動造成了哪個反例的變化」。因此本規格在本次修訂中
**仍然保留空的 `ENABLE_CLOCK_JUMP`**，並在此明確標示——**不要把它當成
「F9 已被涵蓋」**。

## 規模與界（REQ-11 / REQ-12）

### 規模上限（建模決策 10）

節點 `N=3`、client `M=2`、resource `K=1`、`DURATION=2`、`DRIFT=1`、
`EXTENSION_THRESHOLD=1`。`N=3` 是能形成 quorum 又容忍 1 故障的最小值；
`M=2` 是互斥性違反所需的最小 client 數。

### `--max-steps 12` 的充分性（REQ-11）

最短反例所需步數（`quint run` 抽樣量測，`--max-samples 20000`）：

| 不變式                                                   | 最短步數 | 落在 12 內？     | 修復後狀態     |
| -------------------------------------------------------- | -------- | ---------------- | -------------- |
| `INV_VIOLATED_returnsExpiredLock`（F1 ∪ F5）             | 4        | ✅               | **已不可違反** |
| `INV_VIOLATED_quorumCoverageDecay`（`redlockCrashLoss`） | 4        | ✅               | 仍存在         |
| `INV_VIOLATED_releaseErrorMasksAbort`（F7）              | 10       | ✅               | **已不可違反** |
| `INV_VIOLATED_concurrentCriticalSections`                | 12       | ✅（恰好在邊界） | 仍存在         |

修復後仍在的三條（F3 / F4 / F8）都落在 `--max-steps 12` 之內，
因此 REQ-2 的界仍然充分。
但要注意：F4 的最短反例**恰好等於 12**，沒有任何餘裕；若模型再增加任何一步
（例如加入 `using()` 的 timer 模型），這個界就會失守。CI 的 F4 檢查直接使用 12。

### 真不變式的界必須下修：REQ-3 的「12 步 ≤10 分鐘」**不可行**

`mutualExclusionOnNodes` 的實測規模曲線（`quint verify`，本機）：

| `--max-steps` | 牆鐘                                                    |
| ------------- | ------------------------------------------------------- |
| 4             | 12 s                                                    |
| 5             | 13 s                                                    |
| 6             | 22 s                                                    |
| 7             | 25 s                                                    |
| 8             | **164 s → 194 s → 200 s**（三次實測，差異來自機器負載） |
| 10            | **> 600 s（未完成，逾時終止）**                         |
| 12            | 未嘗試（依曲線外推約需數十分鐘至數小時）                |

成長率約每步 ×2.5。**REQ-3 要求 12 步在 10 分鐘內完成，這是做不到的。**
原始 factory run（`34735315950`）耗盡 50 分鐘預算，正是撞上這面牆。

### 為什麼這麼久：每一步的成本曲線（本次實測）

`abortReasonNeverMasked`（`redlockDefault`，`--max-steps 10`，735 s）的逐步牆鐘：

| 深度         | 0   | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   | 9   |
| ------------ | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 耗時 (s)     | 1   | 0   | 1   | 0   | 2   | 5   | 21  | 75  | 162 | 456 |
| 啟用的轉移數 | 1   | 2   | 3   | 5   | 9   | 13  | 17  | 18  | 19  | 19  |

**兩個成本同時複合成長**，這是 bounded model checking 的本質：

1. **每個深度都要重跑一遍「每個轉移是否 enabled」的 SMT 查詢**。啟用數從 1 爬到 19
   （模型共 21 個動作），而深度 12 就是約 `19 × 12 ≈ 228` 次查詢。
2. **SMT 公式隨深度線性變大 → 每一次查詢本身也變慢**。兩者相乘，實測約 **每步 ×3**。

全程成本拆分（同一輪，191 次 enabledness 查詢 ＋ 110 次不變式查詢）：

| 項目                  | 累計      | 佔比 |
| --------------------- | --------- | ---- |
| 轉移 enabledness 判定 | **441 s** | 60%  |
| 不變式本身的求值      | **274 s** | 40%  |

**值得注意：不變式求值只佔四成**——貴的是「搜尋」，不是「檢查那條不變式」。
這也意味著**把不變式寫得更簡單幾乎不會讓它變快**；要快只能降深度或縮模型。

### 反例與真不變式的實測牆鐘（REQ-12，**本次全量重跑**）

as-fixed 模型：

| 項目                                   | 實例               | `--max-steps` | 實測牆鐘                      |
| -------------------------------------- | ------------------ | ------------- | ----------------------------- |
| `neverHandsOutExpiredLock`（F1 ∪ F5）  | `redlockDefault`   | 8             | 123 s                         |
| `neverSelfBlocked`（F2）               | `redlockDefault`   | 8             | 218 s                         |
| `abortReasonNeverMasked`（F7）         | `redlockDefault`   | 10            | **735 s**                     |
| `neverHandsOutExpiredLock`（敵意環境） | `redlockCrashLoss` | 8             | 108 s                         |
| `mutualExclusionOnNodes`（sanity）     | `redlockDefault`   | 8             | 274 s                         |
| 陰性對照 `twoClientsBelieveLock`       | `redlockDefault`   | 8             | 222 s                         |
| F3 `quorumCoverageDecay`               | `redlockCrashLoss` | 5             | 14 s                          |
| F8 `twoClientsBelieveLock`             | `redlockCrashLoss` | 8             | 33 s                          |
| F4 `concurrentCriticalSections`        | `redlockDefault`   | 12            | **784 s**（歷史值；本次見下） |

修復前的 as-is 模型（歷史，供對照）：真不變式 200 s、陰性對照 147 s、
F1 14 s、F5 27 s、F1/F5 13 s、F3 13 s、F8 26 s、F7 125 s、F4 784 s
——**總計約 1 350 s ≈ 22.5 分鐘**。

F4 的 1620 秒（27 分鐘）**是本次最貴的一條，也超過 REQ-3 的 10 分鐘門檻**，
但 REQ-3 的門檻是針對「真不變式」而非反例搜尋；REQ-4 對反例只要求
「退出碼 ≠ 0 ＋ ITF 存在」。

**F4 為何從 784 s 漲到 1620 s（×2.07）**：這條是**搜尋**而非證明，
所以變貴不是「必須窮盡」，而是**新增的兩個動作把狀態空間撐大了，
反例在搜尋順序中的位置被推得更深**。其餘反例（F3 14 s、F8 33 s）
反而變快，因為保真度修正移除了殘留狀態。

### 反例軌跡的述詞驗證（**不只依賴 `rc≠0`**）

本次轉換學到的教訓是「**有反例**」與「**反例有意義**」是兩件事
（as-is 的 F7 反例就是假象）。因此三條軌跡都用解碼器**重算述詞**，
確認最終狀態真的違反：

| 軌跡                                            | 狀態數 | 最終狀態解碼結果                                     |
| ----------------------------------------------- | ------ | ---------------------------------------------------- |
| `INV_VIOLATED_quorumCoverageDecay`（F3）        | 5      | `c1 believes=true 真實覆蓋=1 < quorum 2` ✅ 真的違反 |
| `INV_VIOLATED_twoClientsBelieveLock`（F8）      | 8      | `同時相信持有者=2 → c1,c2` ✅ 真的違反               |
| `INV_VIOLATED_concurrentCriticalSections`（F4） | 13     | `同時在 CRITICAL=2 → c1,c2` ✅ 真的違反              |

狀態數與修復前**完全相同**（5 / 8 / 13）——保真度修正沒有擾動反例的路徑終點。

### CI 的總牆鐘預算

as-fixed 全部跑完：`123 + 218 + 735 + 108 + 274 + 222 + 14 + 33 + 1620`
＝ **3 347 s ≈ 56 分鐘**，再加 typecheck/run/test 約 15 s。

> **⚠️ 56 分鐘超過 CI 草稿目前的 45 分鐘逾時，必須處理。**
> 比修復前的 22.5 分鐘貴了約 2.5 倍，兩個原因疊加：
> （1）四條不變式從「搜尋」變成「**證明**」——搜尋在淺層撞到就停，
> 證明必須窮盡到深度 N（F7：125 s → 735 s）；
> （2）F4 這個搜尋因為狀態空間變大而變深（784 s → 1620 s）。

**成本集中在單一案例**（同一輪實測，依耗時排序）：

| 案例                               | 實例    | 步  | 牆鐘       | 佔比  | 累計  |
| ---------------------------------- | ------- | --- | ---------- | ----- | ----- |
| F4 `concurrentCriticalSections`    | default | 12  | **1620 s** | 48.4% | 48%   |
| F7 `abortReasonNeverMasked`        | default | 10  | **735 s**  | 22.0% | 70%   |
| `mutualExclusionOnNodes`（sanity） | default | 8   | 274 s      | 8.2%  | 79%   |
| 陰性對照 `twoClientsBelieveLock`   | default | 8   | 222 s      | 6.6%  | 85%   |
| F2 `neverSelfBlocked`              | default | 8   | 218 s      | 6.5%  | 92%   |
| F1∪F5 `neverHandsOutExpiredLock`   | default | 8   | 123 s      | 3.7%  | 95%   |
| F1∪F5（敵意環境）                  | crash   | 8   | 108 s      | 3.2%  | 99%   |
| F8 `twoClientsBelieveLock`         | crash   | 8   | 33 s       | 1.0%  | 99.6% |
| F3 `quorumCoverageDecay`           | crash   | 5   | 14 s       | 0.4%  | 100%  |

**F4 一條就佔 48%，前二大佔 70%，其餘六條加起來只有 12 分鐘。**

**`abortReasonNeverMasked` 的深度必須 ≥ 9（實測，勿擅自降到 8）**：

| `--max-steps` | 牆鐘      | 抓得到保真度缺陷那類回歸嗎         |
| ------------- | --------- | ---------------------------------- |
| 8             | **109 s** | ❌ **抓不到**——該反例在第 **9** 步 |
| 9             | **307 s** | ✅ 抓得到，且比 `@10` 省 **428 s** |
| 10            | **735 s** | ✅（目前設定）                     |

依據：`traces/as-is/INV_VIOLATED_releaseErrorMasksAbort.itf.json` 有 **10 個狀態
= 9 步**，違反發生在最後一個狀態。**`@8` 會漏掉本輪真正抓到的那個 bug 類別。**
所以下面的選項 (a) 是 **9 而非 8**。

**建議（給人類的決策點）**——CI 若要壓回 45 分鐘，可考慮：

- **（a）把 `abortReasonNeverMasked` 從 `--max-steps 10` 降到 9**
  （**735 s → 307 s**，省 7.1 分鐘）。**不可降到 8**（見上表）。
  更深的路徑另由**決定性 `run` 測試** `abortReasonSurvivesReleaseFailureTest` 覆蓋
  ——它可重現、可斷言中間狀態，比隨機深度掃描更直接；
- **（b）F4 改用 `--max-steps 12` 但接受它是長尾**（27 分鐘），
  或降到 11 並記錄「已知反例恰在 12 步」；
- **（c）`mutualExclusionOnNodes` 與陰性對照只留一個**（兩者都是結構性論證的 sanity check，
  各 274 s / 222 s，省約 4–5 分鐘）；
  **兩案合併算術**：(a) ＋ (c) ⇒ `3347 − 428 − 222 = 2697 s ≈ 45 分鐘`，
  剛好貼在 45 分鐘線上，沒有餘裕——建議再搭配 (d)；
- **（d）把九條案例平行化**：本機是 8 核心 / 16 GB，而目前是**逐條序列執行**
  （等於只用 1 核心）。Apalache 的 SMT 查詢是單執行緒的，理論上平行 4 條
  可拿到接近 4 倍的牆鐘改善。代價是記憶體（每個 JVM + Z3 約 1–4 GB）與
  **實測數字的可比性**——搶 CPU 的數字不能與序列的歷史數字並列。
- **（e）維持現狀並把 CI 逾時提到 ≥ 90 分鐘。**

本檔**不對此擅自決定**：上述各案都會改變「驗證強度 ↔ CI 成本」的取捨，
屬人類裁定範圍。目前 README 與 CI 草稿採用的是最強的版本（九條全部跑完）。

**採用的替代證據（依 REQ-11 的授權）**：真不變式以 **`--max-steps 8`** 為界。
這在方法論上是充分的，因為 `mutualExclusionOnNodes` 是
**結構性成立**的（R1 的鴿籠論證涵蓋所有深度），深度掃描的目的只是抓建模錯誤，
而 8 步已足以讓 quorum 判定、到期比較、`permitsOf` 過濾三條路徑全部被走過。

> **給人類的決策點**：若要求 12 步的完整窮盡，需要（a）增加 CI 逾時到 60 分鐘
> 以上，或（b）進一步縮減模型（例如把 `RETURNED`/release 狀態合併），或
> （c）接受 8 步 + 結構性論證。本規格採用 (c)，並在此明確標示。

---

## 工具鏈限制：Quint 0.32.0 的假循環宣告（實測）

**以 variant 實例化 sum type 的 `const` 會誤報 `QNT099 Found cyclic declarations`**，
即使該定義完全沒有遞迴。最小重現：

```quint
// lib.qnt
module lib {
  type RK = | A | B
  const R: RK
}
```

```quint
// main.qnt
module main {
  import lib(R = A).* from "./lib"
}
```

```console
$ quint typecheck main.qnt
 Error [QNT099]: Found cyclic declarations. Use fold and foldl instead of recursion
  at main.qnt:2:3
```

已排除的因素（逐一實測）：`var` 為 sum type 沒問題、record 欄位與 const 同名
沒問題、`Map`/`Set` 的 `mapBy` 沒問題、`import m()` 空括號**是語法錯誤**（與本 bug 無關）。

**迴避方式**：`type RoutineKind = str` ＋ `const ROUTINE: str`，以字串比較取代
`match`。`redlock.qnt` 即採此法。sum type 用於**狀態欄位**（`AcquirePhase`、
`ExtendPhase`、`AcquireKind`）完全正常，只有「sum type 的 const」會觸發。

同一原因也使 `NODES.powerset().oneOf()` 的非確定性被移到 `step`、
而 `attemptAcquire` 改收 `chosen` 參數——這順帶讓 F2 的交錯可以被**腳本化**。

---

## 建置缺陷：`@informalsystems/quint` 會讓 `tsc` 失敗（本次發現並修正）

加入 `@informalsystems/quint@0.32.0` 作為 devDependency 之後，**`tsc` 會 exit 2**：

```console
$ npx tsc
node_modules/@types/lodash/common/common.d.ts(266,65): error TS1005: '?' expected.
...
$ echo $?
2
```

傳遞鏈：`@informalsystems/quint` → `@types/lodash.clonedeep@4.5.0` →
`@types/lodash@4.17.25`。`@types/lodash` 4.17 的 `.d.ts` 用了本 repo 的
`typescript@~4.6.2` 解析不了的語法。而 `tsconfig.json` **沒有指定 `types`**，
所以 TypeScript 會**自動載入所有 `@types/*`**——包含這個專案從未使用的套件。

**後果（不是本單造成的，是基底就有的）**：`yarn build` 失敗 → `yarn test`
（`cd dist/esm && ava`）也失敗。`dist/esm` 之所以看起來還在，只是因為 `tsc`
在報錯**之前**仍然輸出了檔案——那正是「以為建置成功」的陷阱。

**修正（`tsconfig.json`）**：加上 `"types": ["node"]`，只自動載入 node 的型別。
`@types/lodash` 不再被拉進來；`import { Redis } from "ioredis"` 仍透過
`@types/ioredis` 正常解析（`types` 只控制**全域自動載入**，不影響 import 的型別解析）。
`skipLibCheck: true` **無法**修好它——TS1005 是語法錯誤，不是型別檢查。

實測：修正前 `npx tsc` 退出碼 **2**；修正後 **0**，且 `npm run oracle` 28/28 通過。

## CI 草稿（REQ-8）

> **這是草稿，供人類套用。** 它**不**寫入 `.github/`——`.github/**` 屬 H5 硬規則，
> agent 無權變更約束自身的規則（`docs/05 §1.1`）。套用步驟見本檔末尾。

### `.github/factory/quint-paths.yml`（可直接複製）

```yaml
# Quint 正式驗證的觸發路徑（同構於 .github/factory/risk-paths.yml）。
#
# 觸及任一 pattern 的 PR 必須通過 quint-verify required check。
# 本檔案位於 .github/ 下，受 CODEOWNERS 保護：agent 不得修改驗證自身的規則。

quint_paths:
  - "src/index.ts"
  - "specs/**"
  - "package.json"
  - ".github/factory/quint-paths.yml"
```

### `.github/workflows/quint-verify.yml`（可直接複製）

設計要點：**兩類斷言必須分開**——真不變式要求退出碼 0；
`INV_VIOLATED_*` 要求退出碼 ≠ 0 **且** ITF 檔存在；witness 要求**解析百分比**
（`quint run --witnesses` 在 0% 時仍然退出碼 0，只看退出碼的斷言形同虛設）。

```yaml
name: quint-verify

on:
  pull_request:
  workflow_dispatch:

jobs:
  quint-verify:
    name: quint-verify
    runs-on: ubuntu-latest
    # ⚠️ as-fixed 模型實測總牆鐘約 56 分鐘（9 條案例；F4 單獨 1620 s、
    # abortReasonNeverMasked 735 s）。45 分鐘**不夠**。
    # 目前暫設 90 分鐘以確保不會因逾時而假紅燈；若要壓回 45 分鐘，
    # 請先採納 specs/README.md「CI 的總牆鐘預算」一節的取捨選項 (a)–(d)。
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      # Apalache 需要 Java；quint 首次執行會自動下載 Apalache（需網路與可寫 $HOME）
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"

      - name: Install
        run: npm install

      - name: Typecheck
        run: |
          npx quint typecheck specs/redlock.qnt
          npx quint typecheck specs/redlockTest.qnt

      # 可執行性：必須能跑（const 已實例化，不會出現 Uninitialized const）
      - name: Run (executable)
        run: npx quint run specs/redlockTest.qnt --main=redlockDefault --max-steps 12

      - name: Run tests
        run: |
          npx quint test specs/redlockTest.qnt --main=redlockAssumptions
          npx quint test specs/redlockTest.qnt --main=redlockFixScenario

      # (1) 真不變式與「修復後成立」的不變式：必須「無違反」。
      #     界為 8 而非 12 —— 12 步依實測需數十分鐘以上（見 specs/README.md §規模）。
      #
      #     ⚠️ 這一組**單靠退出碼 0 是不夠的**：若模型根本到不了危險狀態，
      #     它們也會「無違反」。非空跑性由下方 (3) 的 witness 閘門保證，
      #     兩者必須成對存在，缺一不可。
      - name: Invariant holds — mutualExclusionOnNodes
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants mutualExclusionOnNodes --max-steps 8

      - name: Invariant holds — F1/F5 neverHandsOutExpiredLock
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants neverHandsOutExpiredLock --max-steps 8

      - name: Invariant holds — F2 neverSelfBlocked
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants neverSelfBlocked --max-steps 8

      - name: Invariant holds — F7 abortReasonNeverMasked
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants abortReasonNeverMasked --max-steps 10

      # (2) 被違反的不變式：必須 exit != 0 且產出 ITF。
      #     R2：--out-itf 會抑制 console 輸出，不可依賴 stdout 字串判讀。
      - name: Invariant violated — F3 quorumCoverageDecay
        run: |
          set +e
          npx quint verify specs/redlockTest.qnt --main=redlockCrashLoss \
            --invariants INV_VIOLATED_quorumCoverageDecay --max-steps 5 \
            --out-itf specs/traces/INV_VIOLATED_quorumCoverageDecay.itf.json
          rc=$?
          set -e
          [ "$rc" -ne 0 ] || { echo "::error::反例消失了——請更新規格"; exit 1; }
          [ -s specs/traces/INV_VIOLATED_quorumCoverageDecay.itf.json ]

      - name: Invariant violated — F8 twoClientsBelieveLock
        run: |
          set +e
          npx quint verify specs/redlockTest.qnt --main=redlockCrashLoss \
            --invariants INV_VIOLATED_twoClientsBelieveLock --max-steps 8 \
            --out-itf specs/traces/INV_VIOLATED_twoClientsBelieveLock.itf.json
          rc=$?
          set -e
          [ "$rc" -ne 0 ] || { echo "::error::反例消失了——請更新規格"; exit 1; }
          [ -s specs/traces/INV_VIOLATED_twoClientsBelieveLock.itf.json ]

      # 陰性對照：同一條不變式在**預設情境**下不得有反例。
      # 少了這一步，上一步的反例可能只是建模錯誤而非 F8。
      - name: Negative control — twoClientsBelieveLock holds without crash loss
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants INV_VIOLATED_twoClientsBelieveLock --max-steps 8

      - name: Invariant violated — F4 concurrentCriticalSections
        run: |
          set +e
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants INV_VIOLATED_concurrentCriticalSections --max-steps 12 \
            --out-itf specs/traces/INV_VIOLATED_concurrentCriticalSections.itf.json
          rc=$?
          set -e
          [ "$rc" -ne 0 ] || { echo "::error::反例消失了——請更新規格"; exit 1; }
          [ -s specs/traces/INV_VIOLATED_concurrentCriticalSections.itf.json ]

      # (3) 正向 witness：**必須解析百分比**。這是整個閘門最關鍵的一步。
      #
      #     R3：quint run --witnesses 在 0% 時仍然 exit 0，只看退出碼會漏掉失效的 witness。
      #
      #     ⚠️ **為什麼這一步不能省**：上面 (1) 的四條「無違反」，若模型根本到不了
      #     危險狀態也會通過。witness 就是「危險狀態確實可達」的證據。
      #     兩者必須成對；只留 (1) 等於把假綠燈當成驗證通過。
      #
      #     只閘這兩個高百分比的 witness（實測 68.27% / 27.24%，穩定）。
      #     extendExpiryDetectable（0.41%）、releaseFailedWhileAborted（0.18%）、
      #     reportedSignalError（0.33%）刻意不列入——隨機走訪下會不穩定紅燈；
      #     它們的可達性由 redlockFixScenario 的決定性 run 測試證明（已在上方閘住）。
      - name: Witness reachable — anti-vacuity gate
        run: |
          out=$(npx quint run specs/redlockTest.qnt --main=redlockDefault \
                  --max-steps 12 --max-samples 10000 \
                  --witnesses acquireExpiryDetectable retryFacesOwnResidualKey 2>&1)
          echo "$out"
          for w in acquireExpiryDetectable retryFacesOwnResidualKey; do
            pct=$(printf '%s' "$out" | grep "^$w was witnessed" \
                    | grep -oE '\(([0-9]+\.[0-9]+)%\)' | tr -d '()%' | head -1)
            [ -n "$pct" ] || { echo "::error::解析不到 $w 的百分比輸出"; exit 1; }
            awk -v p="$pct" -v w="$w" 'BEGIN {
              if (p+0 <= 0) {
                print "::error::" w " 為 0% —— 危險狀態已不可達，相關不變式的「無違反」失去意義"
                exit 1
              }
            }'
          done
```

### `.github/workflows/oracle-verify.yml`（可直接複製）

**為什麼這一支是必要的**：`specs/oracle/` 的神諭測試才是「模型的反例真的在
`src/index.ts` 上發生」的證據。沒有它，`.qnt` 只是模型的主張。

**兩個設計要點**：

1. **只需要一個 Redis service**（實測）：`real-redis.test.mjs` 用 `db 0/1/2`
   模擬三個獨立節點、`lua-parity.test.mjs` 只連一條——單一容器就夠。
2. **skip 必須是硬失敗**（`CI=true`）：`node --test` 在測試被略過時**仍然 exit 0**。
   若不處理，「連不上 Redis」與「全部通過」在退出碼上無法區分，
   `lua-parity` 這道**防止循環論證**的保證就會靜默消失——與 R3 是同一個陷阱。

```yaml
name: oracle-verify

on:
  pull_request:
  workflow_dispatch:

jobs:
  oracle-verify:
    name: oracle-verify
    runs-on: ubuntu-latest
    timeout-minutes: 15

    services:
      redis:
        image: redis:7-alpine
        ports:
          - 6399:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-timeout 3s
          --health-retries 10

    env:
      # 讓兩支 Redis 測試在連不上時**直接失敗**，而不是 graceful skip
      CI: "true"
      ORACLE_REDIS_PORT: "6399"

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Install
        run: npm install

      # 神諭測試 import 的是 dist/esm/index.js（真實實作的編譯產物）
      - name: Build
        run: npm run build

      - name: Oracle（反例 + Lua 語意對等 + 真 Redis 端到端）
        run: npm run oracle
```

### 套用步驟（人類）

1. 建立 `.github/factory/quint-paths.yml`（複製上方內容）。
2. 建立 `.github/workflows/quint-verify.yml`（複製上方內容）。
3. 建立 `.github/workflows/oracle-verify.yml`（複製上方內容）。
4. 將 `quint-verify` 與 `oracle-verify` 登記為 required check（`config/github/main-ruleset.json` 對應位置）。
5. 於 `catalog-info.yaml` 新增 `factory.io/quint-spec: specs/`。
6. 確認 runner 可下載 Apalache（快取或網路）並有 Java。

---

## 與程式碼同步（維護契約）

**規格是 ground truth，不是程式碼的附屬品。** 兩個方向都要處理：

- **改 `src/index.ts` 的行為** → 必須先更新 `specs/redlock.qnt` 並重跑本檔的
  全部指令。若某條 `INV_VIOLATED_*` 的反例消失，CI 會紅燈——**那是設計**：
  它強迫規格被同步更新，而不是默默腐爛。
- **規格本身要改** → 依 `docs/06 §4.3`，agent **不得**在同一 run 內用自己寫的
  規格去驗證自己寫的程式碼。
- 依 `docs/ADR/008`，本目錄的 `.qnt` 是 **agent 撰寫的草稿**，合併後才生效。

### as-is → as-fixed 轉換留下的兩條教訓

**1. 修好缺陷之後，`INV_VIOLATED_*` 消失不是「規格腐爛」，而是必須主動轉換。**
本次就是這個情況：F1/F5/F2/F7 修復後，四條 `INV_VIOLATED_*` 再也找不到反例。
正確做法不是刪掉它們，而是**改名去掉前綴並配上 witness**——把「這裡曾經有洞」
轉成「這個洞已被堵住，而且洞口確實還在（witness）」。單純刪掉會讓回歸無人看守。

**2. 述詞必須跟著「修復改變了什麼」走，不是跟著「哪些狀態會發生」走。**
F7 是最清楚的例子：修復後 `releaseFailed ∧ signalAbort` **仍然會發生**，
沿用舊述詞會得到「F7 沒修好」的假結論。真正改變的是 `using()` **回報哪一個錯誤**，
所以述詞得寫在 `reported` 上。**改模型時要先問「修復到底改了什麼」**，
否則會驗證一個與修復無關的性質。
