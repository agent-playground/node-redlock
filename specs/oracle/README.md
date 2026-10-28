# specs/oracle/ — 反例神諭（把 Quint 反例接地到真實實作）

`specs/redlock.qnt` 用模型檢查找到的反例，**必須在真實的 `src/index.ts` 上重現一次**，
否則無法排除「那只是模型的假象」。本目錄就是做這件事：每個反例對應一個
用**真實實作**（編譯後的 `dist/esm/index.js`）執行的測試案例。

> **狀態（F1/F5/F2/F6 已修復後）** > `src/index.ts` 已修復 F1 / F5 / F2 / F6 / F7（部分）。因此本目錄的測試分成兩類：
>
> - **【已修復】F1 / F5 / F2 / F6** — 反例描述的是**修復前**的行為（base `38f792e`，
>   也就是上游 `mike-marcacci/node-redlock` 至今的行為）。ITF 軌跡保留在
>   `../traces/` 作為歷史證據，但測試已改寫為**回歸測試**，斷言修復後的正確行為。
> - **【仍成立】F3 / F4 / F4(b) / F4(c) / F7 / F8** — 修復後**依然重現**。它們不是
>   實作瑕疵，而是演算法層與環境假設層的性質（節點遺失 key、諮詢式 abort 的
>   TOCTOU、無 fencing token）。修復沒有、也不該碰它們。
>
> 判別力由**紅綠對照**保證：把整套測試對修復前的 `src/index.ts` 執行，
> 上面第一類會全部轉紅、第二類維持綠。實測見「紅綠對照」一節。

## 檔案

| 檔案                       | 內容                                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `fakeRedis.mjs`            | 可控的假 Redis：依**傳入的 script 原文**決定三段 Lua script 的語意，並支援時序／故障注入與「擋住我的 key 是不是我自己的」觀測。 |
| `counterexamples.test.mjs` | **11 個測試**：F1/F2/F3/F4/F5/F6/F7/F8 ＋ F4(b) ＋ F4(c) ＋ 1 個陰性對照（跑在假 Redis，無外部依賴）。                          |
| `lua-parity.test.mjs`      | 14 個測試：用**真 Redis** 執行**真實的 script 原文**，逐情境證明假 Redis 的語意一致。                                           |
| `real-redis.test.mjs`      | 4 個測試：真 Redis 端到端（F3/F4/F8 ＋ 陰性對照）。                                                                             |

## 如何執行

```bash
# 全部（會先 build；真 Redis 由 ORACLE_REDIS_PORT 指定，預設 6399）
yarn oracle

# 只跑反例（不需要任何外部服務，約 3 秒）
yarn oracle:mock

# 只跑需要真 Redis 的兩支
ORACLE_REDIS_PORT=6379 yarn oracle:redis
```

> **⚠️ CI 下略過是硬失敗。** `node --test` 在測試被略過時**仍然 exit 0**，
> 所以「連不上 Redis 就 graceful skip」等於讓 `lua-parity` 這道**防止循環論證**
> 的保證靜默消失——與 `quint run --witnesses` 在 0% 時 exit 0 是同一種假綠燈。
> 因此這兩支 Redis 測試在 `CI` 環境變數存在時，連不上會**直接讓檔案失敗**
> （`if (process.env.CI) throw`），而不是 skip。

實測結果（Node 22 / Redis 7-alpine，本機）：

```
counterexamples: 11 pass / 0 fail   （跑在假 Redis，無外部依賴）
lua-parity:      14 pass / 0 fail   （真 Redis 驗證假 Redis 的語意）
real-redis:       4 pass / 0 fail   （真 Redis 端到端）
--------------------------------------------------------------
合計             29 pass / 0 fail / 0 skipped
```

## 紅綠對照（判別力的證據）

把**同一套**測試對修復前的 `src/index.ts`（`git show 38f792e:src/index.ts`）
重建後執行，與對修復後執行的結果並列：

| 套件                       | 修復前 `38f792e`                                      | 修復後 HEAD      |
| -------------------------- | ----------------------------------------------------- | ---------------- |
| `counterexamples.test.mjs` | **7 pass / 4 fail**                                   | 11 pass / 0 fail |
| `lua-parity.test.mjs`      | 11 pass / **3 fail**（2 個 ACQUIRE 情境 ＋ 其父測試） | 14 pass / 0 fail |
| `src/fixes.test.ts`（ava） | **0 pass / 8 fail**                                   | 8 pass / 0 fail  |

修復前轉紅的正是 F1 / F5 / F2 / F6 四條；F3 / F4 / F4(b) / F4(c) / F7 / F8 與陰性
對照維持綠——**修復前後都成立**，正如它們應該的那樣。

> 註：`src/fixes.test.ts` 對修復前的 `src/index.ts` 會有 2 個 TypeScript 錯誤
> （`Lock#extend` 與 `using()` 的簽章在修復中從 1 參數變成 2 參數）。`tsc` 仍會產出
> JS，所以上表的執行結果有效；型別錯誤本身也是 API 變更的證據。

## 對照表：Quint 不變式 → 神諭測試

| Quint（模型）                                                       | 神諭測試                                       | 斷言的核心事實                                                                                                                                            |
| ------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `neverHandsOutExpiredLock`（F1，as-fixed 模型）                     | `F1（已修復）: …丟 ExecutionError…`            | 先決條件：往返超過 TTL、模型述詞 `acquireBelieved <= now` 成立。回歸斷言：`acquire()` 丟 `ExecutionError` 而**不回傳 Lock**，且補償釋放對每個節點都執行過 |
| `neverHandsOutExpiredLock`（F5，as-fixed 模型）                     | `F5（已修復）: …丟 ExecutionError…`            | 同上；另斷言失敗路徑**主動釋放**已失效的鎖（修復前完全不呼叫 release）                                                                                    |
| `neverSelfBlocked`（F2，as-fixed 模型）                             | `F2（已修復）: 重試不再被自己的 key 擋住`      | 不得再出現任何 `selfBlocked`；且必須真的走到「在**同一顆**節點上覆寫自己舊 key」的路徑（`reacquiredOwn`）；同時對照：別人的 `FOREIGN` 鎖仍然擋得住        |
| `INV_VIOLATED_quorumCoverageDecay`（F3）                            | `F3: 節點遺失 key 後…`                         | `lock.expiration > Date.now()`（client 相信）**且**實際持有 value 的節點數 `< quorum`                                                                     |
| `INV_VIOLATED_concurrentCriticalSections`（F4）                     | `F4: 兩個 client 的臨界區重疊`                 | B 進入臨界區的瞬間 A **仍在臨界區內**，且 A 的 `signal.aborted === true`（abort 是諮詢式的）                                                              |
| `INV_VIOLATED_concurrentCriticalSections`（F4，**routine 有檢查**） | `F4(b): routine 檢查了 signal.aborted 才派送…` | A **確實做了**檢查且檢查當時未 abort；`派送 < abort < 效果落地`；B 仍在 A 的臨界區內進入 → **不是「沒檢查」造成的**                                       |
| （F4 的對照組）                                                     | `F4(c) 對照: 每次 await 後都複查…`             | 逐次複查確實讓 A 不再做**新的**臨界工作，但**單一在途操作的效果仍落地於 abort 之後** → 「照 README 做」只能界定、無法消除                                 |
| （F6，建模決策 9 排除於 Quint 之外，**已修復**）                    | `F6（已修復）: …返回後不留任何 timer`          | 先決條件：續期確實被觸發、且 routine 返回時它仍在途。回歸斷言：`using()` 返回後殘留 timer 數 **=== 0**（修復前為 1）                                      |
| `abortReasonNeverMasked`（F7，as-fixed 模型）                       | `F7: release 失敗吃掉 routine 的正常回傳值`    | routine 已產出 `"ROUTINE_RESULT"`、`signal.aborted === true`。⚠️ **as-is 模型的 F7 反例是假象**（見 `../README.md`），真實證據在 `src/fixes.test.ts`      |
| `INV_VIOLATED_twoClientsBelieveLock`（F8）                          | `F8: 兩個 client 同時相信自己持有鎖`           | 同一瞬間兩者的 `lock.expiration > Date.now()`，value 不同，且 A 的真實覆蓋率 `< quorum`                                                                   |
| （陰性對照，非反例）                                                | `陰性對照: 沒有節點崩潰時…`                    | **不**讓節點遺失 key 時，第二個 client 拿不到 quorum → 證明上一個測試的違反來自崩潰，不是測試手法                                                         |

## 端到端真 Redis 重現（`real-redis.test.mjs`）

`counterexamples.test.mjs` 跑在假 Redis 上，因此「反例是否在**真 Redis** 上也成立」
需要另一個檔案回答。`real-redis.test.mjs` 針對**會破壞互斥**的三項，用真 Redis
端到端重跑：

| 測試         | 在真 Redis 上觀測到什麼                                                                                                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **F3**       | `acquire()` 成功後 `DEL` 掉兩個 db 的 key（模擬節點崩潰遺失未同步資料）→ client 的 `lock.expiration > Date.now()`，而 `GET` 查到的實際覆蓋率為 1 `< quorum 2`                            |
| **F8**       | `db2` 先被外來鎖佔住 → A 只拿到 2 節點（剛好 quorum）→ `DEL` 掉 `db0` → 等外來鎖過期 → **B 也取得 quorum**。此時兩人 `expiration > Date.now()`、value 不同，且 A 的實際覆蓋率 `< quorum` |
| **F4**       | `using()` 的 A 進入臨界區 → `DEL` 掉兩個 db 的 key → A 的續期失敗、鎖到期、`signal.aborted === true` → **B 進入臨界區時 A 仍在臨界區內**（`bEnteredWhileAInside === true`）              |
| **陰性對照** | 同樣設定但**不** `DEL` → B 拿不到 quorum → 證明違反來自節點遺失 key，不是測試手法                                                                                                        |

**三個獨立節點的模擬方式**：同一個 Redis 伺服器的 `db 0 / 1 / 2`——key 空間、TTL、
持久化各自獨立，對這三段 script 而言等價於三個實例。
⚠️ 但它們**共用同一個 process 與同一個時鐘**，所以這不是真正獨立的節點；
「節點之間時鐘不同步」這類假設無法用這種方式測（那正是 F9 的範疇）。

**與假 Redis 版本的關鍵差異**：`real-redis.test.mjs` 對 F3/F8 **完全沒有注入延遲**，
只用了真 Redis 的 `DEL`（模擬節點崩潰）與 `SET ... PX`（模擬別人的鎖）。
也就是說「A 相信自己持鎖、實際覆蓋率跌破 quorum」與「B 同時也相信自己持鎖」
這兩個結果，不是假 Redis 造出來的。F4 仍需「讓續期失敗」這個觸發，
但失敗是用真 Redis 的 `DEL` 造成的，不是假延遲。

## 為什麼這不是循環論證（假 Redis 的忠實度）

`counterexamples.test.mjs` 依賴 `fakeRedis.mjs`，而後者是以 JS **重新實作**三段
Lua script。若那份重寫有誤，測試就會變成「我的假 Redis 有這個行為，所以真實
程式碼有這個行為」。`lua-parity.test.mjs` 就是為了堵住這個漏洞：

- 它從 `Redlock` 建構子取出**真實的 script 原文**（`redlock.scripts.*.value`，
  即 `src/index.ts:12-58`，未經任何修改）；
- 在**真 Redis 7-alpine** 上以 `EVAL` 執行；
- 對同一組初始 key 狀態，比對真 Redis 與假 Redis 的回傳值，逐情境斷言一致。

覆蓋的 12 個情境：ACQUIRE 空／同 value／**多 key 中一個是自己的 value**／不同 value／
多 key 部分被別人佔用／已過期，EXTEND 相符／不符／key 已遺失（**不修復**），
RELEASE 相符／不符（**不誤刪**）／不存在，外加「EXTEND 真的把 TTL 往後推」的獨立驗證。

**其中三個情境就是結論的語意基礎**：ACQUIRE 的「同 value 放行」（F2 已修復）、
EXTEND 的「key 已遺失回 0 且不修復」（F3 仍成立）、RELEASE 的「value 不符不刪」（不誤刪他人）。

假 Redis 另外刻意讓 `evalsha` 一律回 `NOSCRIPT`，逼真實程式碼走
`eval` fallback（`src/index.ts:574-595`），因此那條路徑也被測到
（測試中斷言 `evalsha > 0 && eval > 0`）。

### 這道防線真的擋下過一次漂移（F2 修復時的實例）

F2 修好之後，`src/index.ts` 的 `ACQUIRE_SCRIPT` 從「`exists` 就擋」改成「value 不同才擋」，
但 `fakeRedis.mjs` 當時**沒有跟著改**。結果是：

- `counterexamples.test.mjs` 的 F2 測試**照樣綠燈**——它「重現」了一個在真實程式碼裡
  **已經不存在**的缺陷，因為假 Redis 還停在舊語意。這正是循環論證的樣子。
- `lua-parity.test.mjs` **抓到了**：情境「ACQUIRE key 已存在（同 value）」在真 Redis 上
  回 `1`，假 Redis 回 `0` → 不一致 → 失敗。

兩個對策已經落地：

1. **假 Redis 的 ACQUIRE 語意改為由 script 原文推導**（`_acquire` 的 `valueAware`）。
   寫死任何一版語意，都等於把 mock 凍結在某一版 src 上，紅綠對照會失去意義。
2. **script 判別式集中管理**（`isAcquireScript` / `isExtendScript` / `isReleaseScript`）。
   起因是一個很容易踩的陷阱：修復後的 **ACQUIRE_SCRIPT 也含有
   `redis.call("get", key) ~= ARGV[1]`**，而多處測試正是用這個字串辨識 EXTEND。
   誤判的後果不是測試失敗，而是**測試在「從未發生續期」的情況下綠燈**。
   只有 `redis.call("exists"` 是 ACQUIRE 獨有的，而且修復前後都存在。

> **給後續維護者**：動了 `src/index.ts` 的任何一段 Lua，就必須跑
> `ORACLE_REDIS_PORT=<port> yarn oracle:redis`。只跑 `oracle:mock` **不會**發現漂移。

## F4 的真正結論：檢查 signal 只能「界定」，不能「消除」（F4(b) / F4(c)）

原本的 F4 用的是「routine 完全不檢查 `signal.aborted`」的版本。那個版本很容易被
反駁成「README 早就叫你要檢查，是你自己的錯」。**F4(b) 才是不可約的那一半**：

```
A 檢查 signal.aborted → false（此時尚未 abort）
A 在「同一個 tick 內」派送臨界區寫入   ← 檢查與派送之間沒有 await 點
        …abort 發生（續期失敗且鎖已到期）…
        派送出去的操作效果才落地        ← 落在鎖失效之後
```

三個時點由測試直接觀測並斷言：**`派送 < abort < 效果落地`**。
因為檢查與派送之間沒有 await 點，abort **沒有機會**被觀察到——任何
「先檢查再動作」的寫法都存在這個縫。這個測試同時斷言 `checkPassed === true`，
所以「A 沒檢查」這個反駁在斷言層級上就被排除了。

**F4(c) 是對照組**：routine 在**每次 await 之後**都複查。結果是
`didMoreWork === false`（不再做新的臨界工作），但
`effectLandedAt > abortedAt` **仍然成立**——那個已經派送出去的操作，效果照樣落在
鎖失效之後。

**所以 README 的建議是不充分的**：`if (signal.aborted) throw signal.error` 能
**界定**暴露（不再做新工作），但**不能消除**它。要真正消除需要 fencing token
（Kleppmann 的論證：讓下游資源拒絕過期持有者的寫入），而那不是這個函式庫能提供的。

> 這與 `INV_VIOLATED_concurrentCriticalSections` 是同一件事的兩個層次：模型說
> 「臨界區會重疊」，F4(b)/(c) 說「**即使你照文件做，還是會重疊**」。
> 這是本目錄資訊量最高的一條，也是對 README 那句
> "Make sure any attempted lock extension has not failed" 的直接反例。

## 一個額外發現（不在 F1–F9 之內）——**已修復**

寫 F4/F7 時發現：**`using()` 的 per-call `settings` 不會傳給續期**。

修復前，`using()` 內部是 `lock = await lock.extend(duration)`，而
`Lock.extend(duration)` 呼叫 `this.redlock.extend(this, duration)`——**沒有把
settings 帶進去**，因此續期永遠使用**建構子層**的設定。

修復後：`Lock.extend(duration, settings?)` 新增第二參數，`using()` 會把
「建構子設定 ⊕ per-call 設定」的合併結果傳下去。回歸測試見
`src/fixes.test.ts` 的兩條 `settings pass-through`（一條攔截 `Lock#extend` 直接
觀測傳入的參數，一條斷言 `extend` 真的遵守拿到的 `retryCount`）。

本目錄的 F4/F7 測試**仍然把設定放在建構子**——不是因為 per-call 不管用，而是
這樣讀起來就不必再依賴合併規則。

> **順帶記下一個計數陷阱**：不能用「續期的 eval 次數」去推斷 `retryCount` 有沒有
> 傳到。續期失敗時 `using()` 會在 `running && lock.expiration > Date.now()` 期間
> **遞迴重試**；`retryDelay: 0` 時那是一段純 microtask 迴圈，實測在約 50ms 內產生
> **4149 次** eval。要驗證 `retryCount`，得直接呼叫 `lock.extend(...)`，避開
> `using()` 的迴圈。

## 本神諭**不**證明的事（誠實界線）

| 項目                              | 說明                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **不是 ITF 軌跡重放**             | 本目錄重現的是**同一個情境**並斷言**同一個述詞**，不是把 `specs/traces/*.itf.json` 的每一步餵給實作。真正的逐步重放需要控制 `Date.now()` 與逐節點故障注入，而真實程式碼沒有為此暴露介面。                                                                                                                                                                                                                                               |
| **三個 db 不是三個真正的節點**    | `real-redis.test.mjs` 用同一個 Redis 的三個 db 模擬獨立節點，共用 process 與時鐘。對這三段 script 的語意等價，但無法表達「節點之間時鐘不同步」或真正的網路分割。                                                                                                                                                                                                                                                                        |
| **假 Redis 只對三段 script 對等** | 對等性已驗證於本規格使用的 ACQUIRE/EXTEND/RELEASE 與 TTL 行為；不含 Redis 的其他語意（複寫、持久化、cluster redirection、NOSCRIPT 以外的錯誤）。                                                                                                                                                                                                                                                                                        |
| **F6 已有神諭**                   | F6（timer 洩漏）依建模決策 9 排除於 Quint 之外，但**已有真實測試**：`F6（已修復）…` 用「routine 等到續期真的開始才返回」使「返回時續期在途」**確定成立**（不靠 sleep 猜時序），再追蹤全域 `setTimeout` 斷言 `using()` 返回後殘留 timer 為 0。⚠️ 測試手法本身**不得建立任何 `setTimeout`**——原本用 `sleep()` 製造時間窗，那個 sleep 的 timer 會被算進殘留數，使修復前的 `leaked > 0` 可能只是測到自己的 sleep。現已改用純 Promise 閘門。 |
| **F9 沒有神諭**                   | 時鐘跳躍在目前的單一時鐘模型下**無法證否**（見 `../README.md` 的「F9 的建模缺陷」），因此也沒有可重現的反例。                                                                                                                                                                                                                                                                                                                           |
| **時序測試用真實牆鐘**            | F4/F7 有毫秒級的時間邊界。緩解方式：以 `pollUntil` 輪詢狀態而非固定 `sleep`，且斷言留有裕度。在極度負載的機器上仍可能需要重跑一次。                                                                                                                                                                                                                                                                                                     |
| **用的是建構子設定**              | 為了讓續期時序可預測，F4/F7 把設定放在建構子。per-call 設定現已可用（見上節），這只是讀起來比較直接。                                                                                                                                                                                                                                                                                                                                   |
| **本目錄只給實作層證據**          | F1/F5/F2/F6 的修復在**實作層**由本目錄的回歸測試背書。**模型層**的證據在 `../README.md`：`specs/redlock.qnt` 已改寫為 as-fixed，`neverHandsOutExpiredLock` / `neverSelfBlocked` / `abortReasonNeverMasked` 經 `quint verify` 無違反，且 witness 證明危險狀態確實可達（非空跑）。⚠️ **F6 不在 Quint 內**（建模決策 9），它**只有**本目錄的測試背書。                                                                                     |
