# 6 — node-redlock 的 as-is Quint 可執行規格：實作前置分析（agent-analyze）

> **任務類型**：`agent-analyze`（factory 任務模板 `task-template-analyze.txt`；docs/20 §4 C1）——僅分析、不實作。
> **分析對象**：Issue #6（repo `agent-playground/node-redlock`，trunk `software-factory`）。
> **日期**：2026-09-13 · **目標 repo HEAD**：`a5cd6a4`（`Merge pull request #5`）。
> **環境**：node 22.21.1、`@informalsystems/quint` 0.32.0、Temurin JDK 17.0.20、Apalache 0.56.1（自動下載）。
> **狀態**：分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。

---

## 0. 本 run 的範圍宣告（必讀）

Issue #6 的 PRD 要求**新增** `specs/redlock.qnt`、`specs/redlockTest.qnt`、`specs/README.md`、
`specs/traces/*.itf.json`（建模決策 11），且 REQ-1～REQ-9 是針對這些檔案的驗證命令。
本 run 的 `task_type` 是 `agent-analyze`，factory 的機械護欄
`factory-crosscheck --analyze-only` **只允許 `docs/**` 變更**；`factory-run` workflow 對
`agent-analyze` 固定帶上 `--analyze-only`。因此在 `specs/` 產出任何檔案都會觸發
`analyze-code-change` → needs-human。

**結論**：本 run 不可能交付 Issue #6 的 `specs/` 產物。本報告據此定位為**實作前置分析**：

1. 逐條核實 F1–F9 與實際碼（§2）。
2. 以最小忠實模型實測 REQ-1～REQ-5 的核心機制是否可在建模型預算內達成，並找出兩個**會讓驗證假通過**的陷阱（§3）。
3. 逐條檢視建模決策 D1–D11 的落地要求（§4）。
4. 提出可直接開成工作項的下一步與修訂版驗收條件（§7）。

> 這不是「以分析替代實作」的取巧，而是護欄的必然結果：Issue 的檔案配置（建模決策 11）
> 指向 `specs/`，與 `agent-analyze` 的 `docs/**` 白名單互斥。此差異需人類做範圍決策（§6 方案 A）。

---

## 1. 結論摘要（一頁）

1. **F1–F9 與實際碼逐條吻合**（§2）。Issue 表格引用的行號**全數正確**，無需校正；本報告
   補上各函式完整範圍與最小重現推理，作為建模錨點。
2. **工具鏈可行**（§3，本環境實測）：`typecheck` exit 0；instance 模組可 `run`；
   `verify` 對被違反的安全性質回傳 exit 1 並以 `--out-itf` 產出合法 ITF；兩個正向 witness
   在 `--max-steps 12` 可達（實測 78.99% / 14.50%）。
3. **新發現 A — 不變式極性陷阱（會讓 REQ-4 假通過）**：`INV_VIOLATED_*` 若被寫成
   「缺陷條件」（`exists c: ...`）並直接交給 `--invariant`，`quint verify` 會在**初始狀態**
   秒回反例（exit 1 ＋ 1-state ITF），讓 REQ-4 的機械斷言（exit≠0 ＋ 檔案存在）通過，
   但**什麼都沒證明**。正確寫法是：`INV_VIOLATED_*` 是**被 as-is 模型違反的安全性質本身**
   （初始為真、缺陷態為假）。實測證據見 §3.4。這是本報告最高價值的發現。
4. **新發現 B — REQ-3 是最大成本風險**：真不變式 `mutualExclusionOnNodes` 的 `verify`
   遠比找反例慢。未簡化模型 depth 12 在 **>10 分鐘**未完成；簡化模型 depth 6 亦未在
   ~6 分鐘內完成（§3.3）。REQ-3 的「單次牆鐘 ≤ 10 分鐘」**不可假定**，必須在 02-impl
   最早期量測，並預留界／Apalache 調校的修正空間。
5. **新發現 C — F4 反例較難找**：F3/F1 反例分別在 ~9s/~14s 找到；F4
   （`INV_VIOLATED_concurrentCriticalSections`，routine 第 (iii) 態）在同一模型 ~200s
   逾時（§3.3）。REQ-4 對 F4 的「必須產出反例」需較寬的時間預算或更長深度。
6. **建模決策 D1–D11 內部一致、可在 Quint 實作**，但 D5／D8／D10 有具體落地要求（§4）。
7. **建議（§6 方案 A）**：不要在本 analyze run 硬塞 `specs/`；另開一個允許 `specs/**`
   與 `package.json` devDeps 的工作項，以 Issue #6 的 REQ-1～9 為基礎並納入 §7 的修訂。

---

## 2. 證據與根因：F1–F9 逐條對照

### 2.1 對照總表

| # | 位置（本報告核實） | 問題（核實結果） | 性質 |
|---|---|---|---|
| F1 | `src/index.ts:297-341`（核心 318-329） | 缺 `validity <= 0` 檢查，回傳已過期的 `Lock` 且無錯誤 | 安全性（silent） |
| F2 | `src/index.ts:12-27`（`exists` 在 15） | 用 `exists` 而非 value 比對 → 自我阻塞 | 存活性 |
| F3 | `src/index.ts:29-44`（不符即 `return 0` 在 32-33） | 少數節點遺失的 key 不被修復 → 覆蓋率單調衰減 | 安全性（silent） |
| F4 | `src/index.ts:674-769`（`abort` 在 739、routine 在 748-749） | `signal.aborted` 是諮詢式；check-then-act 非原子 | 安全性（silent） |
| F5 | `src/index.ts:378-388`（另見 400-406） | `expiration < Date.now()` 為 check-then-act；Lua value 比對兜底不完備 | 安全性 |
| F6 | `src/index.ts:716-765` | in-flight extension 在 `clearTimeout` 之後 `queue()` → timer 洩漏 | 資源洩漏 |
| F7 | `src/index.ts:354-363`＋`767` | `release()` 失敗自 `finally` 拋出，吃掉回傳值／`signal.error` | 錯誤遮蔽 |
| F8 | 系統模型 | 節點崩潰重啟遺失 key（Kleppmann）→ 兩 client 同時持鎖 | 環境假設 |
| F9 | 系統模型 | `Date.now()` 非單調；`driftFactor` 只涵蓋速率漂移 | 環境假設 |

### 2.2 逐條證據

**F1 — `acquire()` 無 `validity <= 0` 檢查。**
`acquire()` 於 `_execute` 成功後直接以「成功那一次 attempt 的起點 `start`」計算到期時間：

```
src/index.ts:318-329
  const drift = Math.round((settings?.driftFactor ?? this.settings.driftFactor) * duration) + 2;
  return new Lock(this, resources, value, attempts, start + duration - drift);
```

`start` 來自 `_attemptOperation` 的 `const start = Date.now()`（L481），經 `_execute` 的
`return { attempts, start }`（L448）。若 attempt 的網路往返或 client 停頓使
`Date.now() > start + duration - drift`，回傳的 `Lock.expiration` **已小於 now**，呼叫端
拿到一個「已過期但沒有錯誤」的鎖（`Lock.expiration` 為 public mutable，L152）。
→ 這正是 `catalog-info.yaml` 所述「鎖已過期後仍被認為持有」的上游。

**F2 — `ACQUIRE_SCRIPT` 用 `exists` 而非 value 比對。**

```
src/index.ts:14-18
  for i, key in ipairs(KEYS) do
    if redis.call("exists", key) == 1 then return 0 end
  end
```

同一 client 上一次 attempt 在少數節點成功留下的**自己的** key，會被下一次 attempt 的
`exists` 判為「別人持有」而擋下。`_execute` 的 retry 迴圈（L436-469）只重試同一 value
（`value = this._random()` 在 acquire 前生成一次，L306），因此這些 key 在 TTL 到期前一直
阻擋自己；兩 client 各佔一半節點時，雙方都無法湊到 quorum，直到 TTL。
→ 存活性缺陷（不破壞互斥），對應 REQ-5 的 `selfBlockedByOwnValue`。

**F3 — `EXTEND_SCRIPT` 不對少數節點修復。**

```
src/index.ts:31-35
  for i, key in ipairs(KEYS) do
    if redis.call("get", key) ~= ARGV[1] then return 0 end
  end
```

單一節點 value 不符即「整顆腳本」對該節點投反對；`_attemptOperationOnClient` 只在
`result === keys.length` 時投贊成（L598-602），但 `_execute` **只要 quorum 為 for 即成功**
（L515-521）。因此少數節點上已遺失的 key（例如該節點 key 已到期）**永遠不會被後續
`extend` 補回**；節點覆蓋率隨每次 extend 單調衰減，直到某次連 quorum 都湊不到才「靜默
失去 quorum」。對應 `INV_VIOLATED_quorumCoverageDecay`。

**F4 — abort signal 是諮詢式。**
`using()` 內 `controller.abort()` 只在自動續期失敗且鎖已過期時觸發（L734-739），而 routine
是否停止完全取決於 routine 自己輪詢 `signal.aborted`（`README.md:65-78` 即為此範例）。
從「routine 讀 `signal.aborted` 為 false」到「routine 真正執行臨界區動作」之間，鎖可能
失效、另一 client 可能取得鎖——互斥於是被破壞，而 client 的 critical section 仍繼續。
Issue 的 routine 三態中第 (iii) 種（檢查後再隔一步）正對應此 TOCTOU。對應
`INV_VIOLATED_concurrentCriticalSections`。

**F5 — `extend()` 的 check-then-act。**

```
src/index.ts:378-388
  if (existing.expiration < Date.now()) { throw new ExecutionError("Cannot extend an already-expired lock.", []); }
  const { attempts, start } = await this._execute(this.scripts.extendScript, existing.resources, [existing.value, duration], settings);
```

`<` 為 check-then-act：檢查與 `extendScript` 之間鎖可能過期。Lua 的 `get ~= ARGV[1]`
兜底**只保證「不會在該節點 key 已消失時把它復活」**（key 已到期 → `get` 回 nil ≠ ARGV[1]
→ 該節點投反對）；它**不檢查** `duration` 到期後 `validity` 是否仍為正。因此：

- (i) 兜底在「Redis 端不復活已過期 key」這層是完備的；
- (ii) 但 `extend()` 與 `acquire()` 一樣**沒有** `validity <= 0` 檢查（L400-406 直接以
  `start + duration - drift` 建 replacement Lock），慢速 extend 仍可回傳已過期的 Lock。

→ 建模決策 7 要求以 F5 動作／guard 呈現，且應把 (ii) 一併納入 F1 類不變式。

**F6 — timer 洩漏（單執行緒排程）。**

```
src/index.ts:716-721  function queue() { timeout = setTimeout(() => (extension = extend()), lock.expiration - Date.now() - settings.automaticExtensionThreshold); }
src/index.ts:750-765  finally { if (timeout) { clearTimeout(timeout); ... } if (extension) { await extension.catch(...); } await lock.release(); }
```

若 routine 完成時剛好有一個 in-flight `extension`（`lock.extend` 尚未 resolve），`finally`
先清掉舊 timeout，接著 `await extension`；該 extension 成功後在 L728 呼叫 `queue()`，
**設定了一個新的 timeout**，而 finally 之後不再有 `clearTimeout`。計時器因此洩漏，並可能
在 routine 已結束後觸發多餘的 extend/release 競爭。
→ 建模決策 9 已正確排除此項（需 JS event loop，成本超收益）；建議改以 ava 測試涵蓋。

**F7 — `release()` 失敗自 `finally` 拋出。**

```
src/index.ts:354-363  lock.expiration = 0; return this._execute(this.scripts.releaseScript, lock.resources, [lock.value], settings);
src/index.ts:767       await lock.release();   // 位於 using() 的 finally
```

`release()` 用呼叫端 settings（預設 `retryCount=10`、`retryDelay=200`、`retryJitter=100`，
`src/index.ts:106-112`），失敗時 `_execute` 最多 11 次嘗試、10 次延遲，即
`10 × (200±100)ms` = **1.0–3.0 秒**阻塞（Issue 寫 2–3 秒；精確範圍為 1.0–3.0 秒）。若最終
仍失敗，exception 自 `finally` 拋出，**覆蓋 routine 的正常回傳值**，也讓 `signal.error` 失去
意義。此為 F7 的雙重傷害：延遲＋錯誤歸因錯誤。

**F8 / F9 — 環境假設。**
F8（節點重啟遺失未同步的 key）與 F9（`Date.now()` 被 NTP／管理員跳躍）都是**環境假設**，
不是 `src/index.ts` 的實作缺陷。`driftFactor=0.01` 只補償速率漂移（L318-321、L395-398），
不處理時鐘跳躍。Issue 把它們做成預設 `false` 的獨立 const 開關是正確取捨：預設開啟會讓
反例淹沒 F1/F3 這類實作層缺陷。

### 2.3 可重現性

F1/F3/F4/F5/F7 需要精確時序交錯，**無法**用既有 ava 測試穩定重現（`src/single.test.ts`、
`src/multi.test.ts` 依賴真實 Redis 與時間）；這正是本 Issue 要以模型檢查窮盡的理由。本報告的
「重現」是**程式碼路徑＋算術**層級（上列 `file:line` 足以逐條重建失敗前提），加上 §3 的
**最小模型 witness／ITF** 佐證機制可達；真正屬於 Issue 的產物仍是 `specs/` 下的規格與反例。

### 2.4 行號核實

Issue 表格引用的行號與實際 `src/index.ts`（共 770 行）**逐條吻合**，無需校正：
F2 的 `ACQUIRE_SCRIPT` L14-18 正是 `exists` 迴圈；F3 的 `EXTEND_SCRIPT` L31-35 正是 value
比對迴圈；F1 的 `acquire()` L318-329 正是 drift 計算＋`new Lock`；F5 的 `extend()` L379、
F6 的 `using()` finally L750-765、F7 的 `release()` L355 ＋ L767 均正確。§2.1 另補上各函式
的完整範圍（`acquire` 297-341、`release` 350-364、`extend` 369-409、`_execute` 416-471、
`_attemptOperation` 473-550、`_attemptOperationOnClient` 552-625、`using` 674-769），
供新工作項作為建模錨點。

---

## 3. 工具鏈與可行性實測（本環境）

> 以下為**唯讀探針**：在 `/tmp/qprobe/`（workspace 外、**不進 repo**）建立一個最小忠實
> 模型 `toy.qnt`，把 Issue 決策 5 的**三層時間**（全域 `now` ＋ 每節點真實到期 ＋ 每 client
> 相信的 `expiration`）與 F1/F2/F3/F4 機制、兩個 witness 具體化，用來量測 REQ-3/4/5 的可達性
> 與成本。它不是 Issue 的交付物，只是可行性證據。

### 3.1 探針設定

- `N=3`、`M=2`、`QUORUM=2`、`DURATION=4`、`DRIFT=2`、`MAX_TIME=10`，`--max-steps 12`。
- `hidden` 語意與 Issue 一致：`trulyHolds(c)`（≥ quorum 節點 value=c 且未到期）、
  `believesHolds(c)`（`lock.expiration > now`）。
- F1 以 `acquireSlow`（attempt 起點在過去、`exp = now - back + DURATION - DRIFT`）呈現；
  F2 以 `failAcquire`（留下自己的 key 但未取鎖）呈現；F3 以 `extendPartial`（只續存活的
  quorum 節點、不修復遺失節點）呈現；F4 以 routine 三態第 (iii) 種
  （`checkSignal` → 隔一步 `enterCritical`，中間允許 `tick`／對手 `acquire`）呈現。

### 3.2 實測結果

| 命令 | 結果 | 退出碼 |
|---|---|---|
| `quint typecheck toy.qnt` | 型別檢查通過 | **0** |
| `quint run toy.qnt --main=toylockConcrete --max-steps 12` | `[ok] No violation found`，trace 13 | **0** |
| `quint run … --witnesses selfBlockedByOwnValue bothClientsFailWithinRetryWindow` | `78.99%` / `14.50%`（皆 > 0） | **0** |
| `quint verify … --invariants INV_VIOLATED_returnsExpiredLock --out-itf` | `found a counterexample`，ITF **5 states**（~13.9s） | **1** |
| `quint verify … --invariants INV_VIOLATED_quorumCoverageDecay --out-itf` | `found a counterexample`，ITF **3 states**（~9.3s） | **1** |
| `quint verify … --invariants INV_VIOLATED_concurrentCriticalSections` | **200s 逾時未產出反例**（見 §3.3） | 124（timeout） |
| `quint verify … --invariants mutualExclusionOnNodes` | **>10 分鐘未完成**（見 §3.3） | — |

補充事實：

- `quint verify` 預設後端為 Apalache 0.56.1，需 Java（本機 Temurin 17 可用），首次會下載。
- `quint verify` 找到反例時**回傳 exit 1**；`--out-itf` 會抑制 console 的逐步輸出，CI 應以
  「exit ≠ 0 ＋ ITF 檔存在 ＋ ITF 至少 2 個 state」判讀（見 §3.4）。
- `--invariants`（複數 array，REQ-3/4/8 使用）與 `--invariant`（單數）不同；Issue 用複數是對的。

### 3.3 成本量測：找反例 vs 證明安全

- **找反例很快**：F1/F3 在 **~9–14 秒**內找到，ITF 狀態數 5 / 3（非初始態，機制真實）。
- **證明真不變式很慢**：`mutualExclusionOnNodes`（`trulyHolds` ∧ `trulyHolds`）在
  **未簡化**模型 depth 12 執行 >10 分鐘仍未完成（到達 State 5 後持續研磨）；**簡化**
  （移除 `nondet back`）模型 depth 6 亦未在 ~6 分鐘內完成。
- **F4 反例較難**：`INV_VIOLATED_concurrentCriticalSections` 需要「檢查 → 時間前進／對手
  取鎖 → 進入臨界區」的較長路徑，在 depth 12 下 200 秒逾時未找到。

**意義**：REQ-3 的「單次牆鐘 ≤ 10 分鐘」是本 Issue 最不確定的驗收條目；REQ-4 對 F4 的
「必須產出反例」也可能需要更寬的預算或更深的界。這與 Issue #4 報告的 R5/R6 一致，且本
run 給出了量化下限：**不是「暖機後幾秒」等級**，忠實的三層時間模型會讓 Apalache 的
安全性質證明顯著變慢。**建議在 02-impl 第一個里程碑就先跑一次 verify 量測**，必要時在
**不違反建模決策 10** 的前提下調整界（例如縮小 `MAX_TIME` 或把真不變式拆成獨立 verify），
並把量測記錄進 `specs/README.md`。

### 3.4 新發現 A：不變式極性陷阱（會讓 REQ-4 假通過）

本 run 第一次實作探針時，曾把 `INV_VIOLATED_returnsExpiredLock` 寫成**缺陷條件**：

```
// 錯誤寫法：缺陷條件（初始為 false）
val INV_VIOLATED_returnsExpiredLock: bool =
  (0.to(M - 1)).exists(c => clients.get(c).hasLock and now > clients.get(c).exp)
```

結果：`quint run --invariant INV_VIOLATED_returnsExpiredLock --max-steps 1` 在
**Initial State（65ms）**即報 `[violation] Found an issue`；`quint verify` 亦在 State 0 回
exit 1 並寫出**只有 1 個 state** 的 ITF。REPL 直接求值可證該缺陷條件在初始狀態為 `false`
——工具沒有錯，是**極性用反**：`--invariant` 檢查的是「此性質是否恆真」，缺陷條件在初始
狀態就不恆真，於是被判違反。

正確寫法（`INV_VIOLATED_*` ＝ **被 as-is 模型違反的安全性質本身**）：

```
// 正確寫法：安全性質（初始為 true，缺陷態為 false）
val INV_VIOLATED_returnsExpiredLock: bool =
  not((0.to(M - 1)).exists(c => clients.get(c).hasLock and now > clients.get(c).exp))
```

修正後，反例才由真實機制在 **5 個 state** 後取得（§3.2）。**這是對 REQ-4/REQ-8 的具體
修正建議**：CI 的「`INV_VIOLATED_*` 必須被違反」斷言，除了 exit≠0 ＋ ITF 存在，**還必須
斷言 ITF 的 state 數 ≥ 2**（或等價地：驗證初始狀態滿足該不變式），否則一個寫反的
不變式會讓 CI 全綠而毫無鑑別力。

> 註：`quint run --witnesses` 的正向 witness 不受此陷阱影響（witness 本來就是「想達到的
> 狀態」），仍是 REQ-5 的正確工具。

---

## 4. 建模決策 D1–D11 落地檢視

> 決策 1–11 已與需求方確認，**本報告不變更**；以下為實作前應明確化的事項。

| 決策 | 判定 | 落地要求／風險 |
|---|---|---|
| D1 as-is | 可行 | 不加入「修正版」const；反例即缺陷證據。 |
| D2 `INV_VIOLATED_*` 命名 | **可行但需補強** | 見 §3.4：命名契約要搭配「初始狀態須滿足不變式」的 CI 斷言，否則極性寫反會假通過。 |
| D3 純 Quint、不用 Choreo | 正確 | N 個 Redis 節點是被動 KV、不互相通訊，投票發生在 client 記憶體；共享狀態模型（`ewd426` 形狀）而非 message passing。RPC 中間態以 in-flight 集合自行建模。 |
| D4 模型邊界 | 可行 | `_execute` retry 抽象為「可重試 K 次」的非確定性選擇；不建 jitter/backoff 分佈（不影響安全性）。 |
| D5 三層時間 | **必需，且是本模型核心** | 每節點 key 到期**不要**用「清除」動作建模，而是以 `now < nodeExp` 判有效，可少一組 transition；`believes` 與 `truly` 分離才證得出 F1/F3/F4。 |
| D6 故障模型 | 可行 | 崩潰停止／分割／client 停頓預設開啟；F8/F9 各自獨立 const 預設 `false`。 |
| D7 雙重判準 | 正確 | `trulyHolds` / `believesHolds` 兩個述詞；落差即主題。 |
| D8 routine 三態 | 可行 | 第 (iii) 態需**兩個動作**（check 與 act 之間可插一步 `tick`／對手 `acquire`），會拉長 F4 最短反例（§3.3）。 |
| D9 F6 排除 | 正確 | 需 JS event loop，成本超收益；`specs/README.md` 記明並建議 ava 涵蓋。 |
| D10 規模上限 | **需量測** | `N=3/M=2/K=1/time 0..10/max-steps 12` 狀態空間小，但 `verify` 證明真不變式的成本仍可能 >10 分鐘（§3.3）。 |
| D11 檔案配置 | 可行 | const 須以**具名 instance module** 實例化才可 `run`（否則 `Uninitialized const`）；主模組不得混入測試場景。 |

---

## 5. 影響範圍

- **受影響模組**：`src/index.ts` 的 `acquire`（297-341）、`release`（350-364）、
  `extend`（369-409）、`_execute`（416-471）、`_attemptOperation`（473-550）、
  `_attemptOperationOnClient`（552-625）、`using`（674-769），以及三段 Lua script
  （12-58）。這是全檔 770 行的核心路徑。
- **受影響使用者／下游**：所有以 `using()` 取得互斥的呼叫端。F1/F3/F4/F5 的失效是
  **靜默**的（無錯誤、無非零退出），呼叫端只會看到「routine 正常完成」，不會看到互斥已被
  破壞——與 `catalog-info.yaml:56` 記載的失效模式一致。
- **repo 現況**：`specs/` 不存在、無任何 `.qnt`；`catalog-info.yaml:80` 明載「無
  `factory.io/quint-spec`」。既有 ava 測試（`src/single.test.ts`、`multi.test.ts`）未涵蓋
  F1–F9（需真實 Redis 與時序）。
- **工廠機制**：本 Issue 是跨 repo 的 quint-spec 試點。依 ADR-008，agent 產出的 `.qnt` 是
  **草稿**，合併後才生效；且 agent 不得於同一 run 以自己的規格驗證自己的碼（docs/06 §4.3）
  ——本單不改 `src/`，天然滿足此分離。

---

## 6. 方案比較

| 方案 | 內容 | 判定 | 理由 |
|---|---|---|---|
| **A（建議）** | 本 analyze run 只交付本報告；另開允許 `specs/**` 與 `package.json` devDeps 的工作項 | **採納** | 符合 analyze 護欄；把高風險的規格撰寫交給可審查的獨立工作項；符合 ADR-008 草稿／審查分離 |
| **B** | 在本 analyze run 直接新增 `specs/**` | **拒絕** | `--analyze-only` 白名單只有 `docs/**` → `analyze-code-change` needs-human；等於繞過護欄 |
| **C** | 把規格草稿放進 `docs/research/quint/` 以滿足 `docs/` 前綴 | **拒絕** | 通過機械檢查但**違反建模決策 11** 與 ADR-008 的 `factory.io/quint-spec` 規格根目錄語意；可執行規格混入研究報告目錄會使其狀態（草稿／生效、由誰套用）無法辨識 |
| **D** | 依 factory-stop-rules #8 直接停手、不產報告 | **拒絕** | 任務模板明確允許 in-loop 的 analyze 產出報告；報告能精確記錄範圍差異並給出下一步，優於空手停手。範圍差異以 §0／§8 誠實揭露 |

**方案 A 的「為什麼現在不做」**：Issue 的 `specs/` 產物是「可執行規格＋ITF 反例」，屬
ADR-008 的 spec 草稿生命週期，需要人類審查後才生效；把它綁進一個當下被護欄限制為
`docs/**` 的 analyze run，只會製造 needs-human 的假完成。拆成獨立工作項，審查者可以只審
`specs/**` 的技術正確性。

---

## 7. 建議下一步（可直接開成工作項）

### 7.1 工作項描述

> **標題**：為 node-redlock 建立 as-is Quint 可執行規格，形式化 F1–F9 並存證反例
> **類型**：需要一個**允許 `specs/**` 與 `package.json` devDependencies** 的型別
> （例如 docs/19/docs/21 已列為候選的 `agent-write-spec`），或由人類明確授權一個後繼
> 工作項。**不可**再用 `agent-analyze` 承載此交付。
> **內容**：沿用 Issue #6 的建模決策 1–11 與 REQ-1～REQ-9，並納入 §3.3／§3.4／§4 的修正。

### 7.2 驗收條件草案（REQ-1～REQ-9 修訂版）

- **REQ-1**：`npx quint typecheck specs/redlock.qnt` 退出碼 0。
- **REQ-2**：`npx quint run specs/redlock.qnt --main=<instance 模組> --max-steps 12` 退出碼 0；
  instance 以 `N=3/M=2/K=1/time 0..10` 實例化，無 `Uninitialized const`。
- **REQ-3**：`npx quint verify specs/redlock.qnt --invariants mutualExclusionOnNodes
  --max-steps 12` 無反例、exit 0、單次牆鐘 ≤ 10 分鐘。**（新增 R3-A：開工即量測並把
  實測秒數記入 `specs/README.md`；若 >10 分鐘，須在建模決策 10 界內提出並記錄替代界
  〔縮小 `MAX_TIME` 或拆 verify〕，不得默默放寬。）**
- **REQ-4**：`INV_VIOLATED_returnsExpiredLock`（F1）、`INV_VIOLATED_quorumCoverageDecay`（F3）、
  `INV_VIOLATED_concurrentCriticalSections`（F4，須由 routine 第 (iii) 態觸發）各自
  **exit ≠ 0** 且 `--out-itf` 產生 `specs/traces/<inv 名>.itf.json`。
  **（新增 R4-A：每個 ITF 的 state 數 ≥ 2，且初始狀態滿足該不變式；用以排除 §3.4 的極性
  陷阱。新增 R4-B：F4 反例須在設定的時間預算內取得，並記錄實測秒數。）**
- **REQ-5**：`selfBlockedByOwnValue`、`bothClientsFailWithinRetryWindow` 兩個 witness 的
  trace 數 **> 0**；以 `quint run --witnesses` 取得，**解析輸出百分比**（不可依賴 exit code），
  百分比貼入 `specs/README.md`。
- **REQ-6**：F5 與 F7 以動作／guard 呈現（`specs/README.md` 指明定義名）；F8、F9 各對應一個
  預設 `false` 的 const 開關，README 記錄開啟後結果。
- **REQ-7**：`specs/README.md` 含「已涵蓋／刻意未涵蓋」兩份清單，明載 F6 排除理由與
  「改以 ava 測試涵蓋」的替代建議。
- **REQ-8**：`specs/README.md` 附可直接複製的 `.github/factory/quint-paths.yml` 與
  `.github/workflows/quint-verify.yml` **草稿**；quint-verify 須含兩類斷言——真不變式須綠、
  `INV_VIOLATED_*` 須確實被違反（**exit ≠ 0 ＋ ITF 存在 ＋ ITF state 數 ≥ 2，見 R4-A**）；
  positive witness 須 > 0（**解析百分比**）。草稿僅存放於 `specs/` 之下，不寫入 `.github/`。
- **REQ-9**：`git diff --name-only origin/software-factory...HEAD` 不含 `src/`、`.github/`、
  `catalog-info.yaml`、`CODEOWNERS`。
- **REQ-10（新增，依賴）**：`@informalsystems/quint@0.32.0` 精確鎖版加入 `devDependencies`；
  CI 有 Apalache 快取與 Java 17 前置（避免 `npx` 即時抓取的供應鏈／可重現性風險）。
- **REQ-11（新增，量測）**：記錄 `max-steps 12` 足以容納三條 `INV_VIOLATED_*` 最短反例的
  實測證據（含 §3.3 的 F4 成本警示），或記錄在建模決策 10 界內的必要調整。

### 7.3 人類待辦（沿用 Issue #6，agent 無權執行）

1. 於 `catalog-info.yaml` 新增 `factory.io/quint-spec: specs/`（值為規格根目錄）。
2. 依 REQ-8 草稿建立 `.github/factory/quint-paths.yml`（至少含 `specs/**` 與 `src/index.ts`）。
3. 依 REQ-8 草稿建立 `.github/workflows/quint-verify.yml`。
4. 將 `quint-verify` 登記為 required check。
5. 依 ADR-008 確認 `.qnt` 草稿審查流程；評估是否依 F1/F3/F4 反例開立修復工單。

---

## 8. Requirements 對照（`report.json`）

| REQ | 本 run 狀態 | 說明 |
|---|---|---|
| REQ-1 | `failed` | 未交付 `specs/redlock.qnt`；`typecheck` 無標的。工具鏈本身可行（§3.2）。 |
| REQ-2 | `failed` | 未交付 instance 模組與 `specs/redlock.qnt`；instance 形狀見 §4 D11。 |
| REQ-3 | `failed` | 未交付真不變式與 verify；§3.3 指出此條成本風險最高。 |
| REQ-4 | `failed` | 未交付三條 `INV_VIOLATED_*` 與 ITF 反例；§3.4 指出極性陷阱並提出 R4-A 修正。 |
| REQ-5 | `failed` | 未交付 specs witness；探針中兩 witness 可達（78.99% / 14.50%）。 |
| REQ-6 | `failed` | 未交付模型與 `specs/README.md`；F5/F7/F8/F9 之分析見 §2、落地要求見 §4。 |
| REQ-7 | `failed` | 未交付 `specs/README.md`。 |
| REQ-8 | `failed` | 未交付 CI 草稿（且草稿不得寫入 `.github/`）；修正建議見 §7.2 REQ-8。 |
| REQ-9 | `passed` | 本 run diff **僅** `docs/research/6-quint-executable-spec-analysis.md`，不含 `src/`、`.github/`、`catalog-info.yaml`、`CODEOWNERS`。 |

> REQ-9 是本 run 唯一能滿足的條目，因為它是一條**負向路徑約束**；其餘 REQ 均要求 `specs/`
> 產物，受 `agent-analyze` 護欄阻擋（§0）。此為誠實自報，`factory-crosscheck` 以 analyze
> 模式驗證無 `src/` 變更。

---

## 9. 變更清單

本 run 無任何 `src/`、測試或設定變更；唯一變更是本報告
`docs/research/6-quint-executable-spec-analysis.md`。符合 `--analyze-only` 白名單與
factory-stop-rules #8 的「不自行擴大範圍」。
