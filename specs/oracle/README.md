# specs/oracle/ — 反例神諭（把 Quint 反例接地到真實實作）

`specs/redlock.qnt` 用模型檢查找到的反例，**必須在真實的 `src/index.ts` 上重現一次**，
否則無法排除「那只是模型的假象」。本目錄就是做這件事：每個反例對應一個
用**真實實作**（編譯後的 `dist/esm/index.js`）執行的測試案例。

## 檔案

| 檔案                       | 內容                                                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `fakeRedis.mjs`            | 可控的假 Redis：忠實實作三段 Lua script 的語意，並支援時序／故障注入與「擋住我的 key 是不是我自己的」觀測。 |
| `counterexamples.test.mjs` | 8 個測試：7 個重現反例 + 1 個陰性對照。                                                                     |
| `lua-parity.test.mjs`      | 13 個測試：用**真 Redis** 執行**真實的 script 原文**，逐情境證明假 Redis 的語意一致。                       |

## 如何執行

```bash
# 一次性：編譯真實實作
npx tsc            # 產出 dist/esm/index.js

# 反例測試（不需要外部服務）
node --test specs/oracle/counterexamples.test.mjs

# 語意對等測試（需要真 Redis）
docker run -d --rm -p 6399:6379 --name redlock-oracle-redis redis:7-alpine
node --test specs/oracle/lua-parity.test.mjs
# 連不上 Redis 時會 graceful skip，不會讓套件紅燈

# 全部
node --test specs/oracle/counterexamples.test.mjs specs/oracle/lua-parity.test.mjs
```

實測結果（quint 0.32.0 / Node 22 / Redis 7-alpine）：

```
counterexamples: 8 pass / 0 fail   （約 2.5s，跑在假 Redis）
lua-parity:     13 pass / 0 fail   （真 Redis 驗證假 Redis 的語意）
real-redis:      4 pass / 0 fail   （真 Redis 端到端，連續 6 次 0 失敗）
```

## 對照表：Quint 不變式 → 神諭測試

| Quint（模型）                                                      | 神諭測試                                    | 斷言的核心事實                                                                                                                          |
| ------------------------------------------------------------------ | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `INV_VIOLATED_acquireReturnsExpiredLock`（F1）                     | `F1: acquire() 在往返超過 TTL 時…`          | `acquire()` **不拋錯**地回傳 `lock.expiration <= Date.now()`；且 `expiration === start + duration - drift`（證明它由過期的 start 算出） |
| `INV_VIOLATED_extendReturnsExpiredLock`（F5）                      | `F5: extend() 在慢往返下…`                  | `lock.extend()` **不拋錯**地回傳 `replacement.expiration <= Date.now()`                                                                 |
| `selfBlockedByOwnValue` / `bothClientsFailWithinRetryWindow`（F2） | `F2: retry 被『自己上一輪留下的 key』擋住`  | 在 retry 的 attempt 中，擋住該節點的 `blocker` **等於 client 自己的 value**（不是別人的 `FOREIGN`）                                     |
| `INV_VIOLATED_quorumCoverageDecay`（F3）                           | `F3: 節點遺失 key 後…`                      | `lock.expiration > Date.now()`（client 相信）**且**實際持有 value 的節點數 `< quorum`                                                   |
| `INV_VIOLATED_concurrentCriticalSections`（F4）                    | `F4: 兩個 client 的臨界區重疊`              | B 進入臨界區的瞬間 A **仍在臨界區內**，且 A 的 `signal.aborted === true`（abort 是諮詢式的）                                            |
| `INV_VIOLATED_releaseErrorMasksAbort`（F7）                        | `F7: release 失敗吃掉 routine 的正確回傳值` | routine 已產出 `"ROUTINE_RESULT"`、`signal.aborted === true`，但 `using()` 以 `ExecutionError` 失敗                                     |
| `INV_VIOLATED_twoClientsBelieveLock`（F8）                         | `F8: 兩個 client 同時相信自己持有鎖`        | 同一瞬間兩者的 `lock.expiration > Date.now()`，value 不同，且 A 的真實覆蓋率 `< quorum`                                                 |
| （陰性對照，非反例）                                               | `陰性對照: 沒有節點崩潰時…`                 | **不**讓節點遺失 key 時，第二個 client 拿不到 quorum → 證明上一個測試的違反來自崩潰，不是測試手法                                       |

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

覆蓋的 11 個情境：ACQUIRE 空／同 value／不同 value／多 key 部分存在／已過期，
EXTEND 相符／不符／key 已遺失（**不修復**），RELEASE 相符／不符（**不誤刪**）／不存在，
外加「EXTEND 真的把 TTL 往後推」的獨立驗證。

**其中三個情境就是反例的語意基礎**：ACQUIRE 的「同 value 也回 0」（F2 的自我阻塞）、
EXTEND 的「key 已遺失回 0 且不修復」（F3）、RELEASE 的「value 不符不刪」（不誤刪他人）。

假 Redis 另外刻意讓 `evalsha` 一律回 `NOSCRIPT`，逼真實程式碼走
`eval` fallback（`src/index.ts:574-595`），因此那條路徑也被測到
（測試中斷言 `evalsha > 0 && eval > 0`）。

## 一個額外發現（不在 F1–F9 之內）

寫 F4/F7 時發現：**`using()` 的 per-call `settings` 不會傳給續期**。

`using()` 內部是 `lock = await lock.extend(duration)`（`src/index.ts:727`），
而 `Lock.extend(duration)` 呼叫 `this.redlock.extend(this, duration)`
（`src/index.ts:159-161`）——**沒有把 settings 帶進去**。因此續期永遠使用
**建構子層**的設定。

後果：`redlock.using(res, 1000, { retryCount: 0 }, routine)` 的 acquire 只試 1 次，
但續期失敗時仍會依預設 `retryCount: 10 / retryDelay: 200` 內部重試約 2–3 秒
才回到外層判斷 abort。本目錄的 F4/F7 測試因此必須把設定放在**建構子**才可預測
（見測試中的註解）。這是一個可觀測的行為落差，建議另開工單評估。

## 本神諭**不**證明的事（誠實界線）

| 項目                              | 說明                                                                                                                                                                                      |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **不是 ITF 軌跡重放**             | 本目錄重現的是**同一個情境**並斷言**同一個述詞**，不是把 `specs/traces/*.itf.json` 的每一步餵給實作。真正的逐步重放需要控制 `Date.now()` 與逐節點故障注入，而真實程式碼沒有為此暴露介面。 |
| **三個 db 不是三個真正的節點**    | `real-redis.test.mjs` 用同一個 Redis 的三個 db 模擬獨立節點，共用 process 與時鐘。對這三段 script 的語意等價，但無法表達「節點之間時鐘不同步」或真正的網路分割。                          |
| **假 Redis 只對三段 script 對等** | 對等性已驗證於本規格使用的 ACQUIRE/EXTEND/RELEASE 與 TTL 行為；不含 Redis 的其他語意（複寫、持久化、cluster redirection、NOSCRIPT 以外的錯誤）。                                          |
| **F6 沒有神諭**                   | timer 洩漏依建模決策 9 排除於 Quint 之外，本目錄自然也沒有對應反例。建議另以 ava 測試涵蓋（見 `../README.md`）。                                                                          |
| **F9 沒有神諭**                   | 時鐘跳躍在目前的單一時鐘模型下**無法證否**（見 `../README.md` 的「F9 的建模缺陷」），因此也沒有可重現的反例。                                                                             |
| **時序測試用真實牆鐘**            | F4/F7 有毫秒級的時間邊界。緩解方式：以 `pollUntil` 輪詢狀態而非固定 `sleep`，且斷言留有裕度。在極度負載的機器上仍可能需要重跑一次。                                                       |
| **用的是建構子設定**              | 為了讓續期時序可預測，F4/F7 把設定放在建構子——這正是上節「額外發現」所指的行為。                                                                                                          |
