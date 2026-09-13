# 4 — node-redlock 的 Quint 可執行規格：實作前置分析（agent-analyze）

> **任務類型**：`agent-analyze`（factory 任務模板 `task-template-analyze.txt`；docs/20 §4 C1）——僅分析、不實作。
> **分析對象**：Issue #4（repo `agent-playground/node-redlock`，trunk `software-factory`）。
> **日期**：2026-09-13 · **目標 repo HEAD**：`8185f1f`（`Merge pull request #3`）。
> **環境**：node 22.21.1、`@informalsystems/quint` 0.32.0、Temurin JDK 17.0.20、Apalache 0.56.1（自動下載）。
> **狀態**：分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。

---

## 0. 本 run 的範圍宣告（必讀）

Issue #4 的 DoD（REQ-1～REQ-9）要求**新增** `specs/redlock.qnt`、`specs/redlockTest.qnt`、
`specs/README.md`、`specs/traces/*.itf.json`。本 run 的 `task_type` 是 `agent-analyze`，
factory 的機械護欄 `factory-crosscheck --analyze-only` **只允許 `docs/**` 變更**：

> `src/cli/factory-crosscheck.ts:159-169`
> ```ts
> if (analyzeOnly) {
>   const forbidden = actualPaths.filter((p) => !p.startsWith('docs/'))
>   // ... kind: 'analyze-code-change'
> }
> ```

且 `factory-run` workflow 對 `agent-analyze` 固定帶上 `--analyze-only`
（`.github/workflows/factory-run.yml:500-504`）。因此在 `specs/` 產出任何檔案都會觸發
`analyze-code-change` → needs-human。

**結論**：本 run 不可能交付 Issue #4 的 `specs/` 產物。本報告據此定位為**實作前置分析**：
驗證 F1–F9 的真實性與根因、實測 Quint 工具鏈可行性、指出建模計畫的風險，並提出可直接
開成工作項的下一步。REQ-1～REQ-9 的逐條狀態見 §8。

> 這**不是**「以分析替代實作」的取巧，而是護欄的必然結果：Issue 的檔案配置（建模決策 11）
> 指向 `specs/`，與 `agent-analyze` 的 `docs/**` 白名單互斥。此差異需人類做範圍決策（§6 方案 A）。

---

## 1. 結論摘要（一頁）

1. **F1–F9 全部與實際碼對照成立**（§2）。除個別行號需校正外，九項疑點的描述與程式碼一致；
   本報告補上每條的精確位置與最小重現推理。
2. **Quint 工具鏈在本環境可行**（§3，實測）：`typecheck` exit 0；`verify` 對真不變式 exit 0、
   對被違反的不變式 exit 1 並以 `--out-itf` 產出合法 ITF；`run --witnesses` 可印百分比。
   Java 17＋Apalache 0.56.1 可自動取得。
3. **建模計畫有 4 個開工前必須處理的風險／修正**（§4）：
   - **R1** `mutualExclusionOnNodes`（truly↔truly）在 `N=3`、quorum=2 下是**鴿籠結構性成立**，
     REQ-3 的「無反例」資訊量低；真正的安全落差在 **believes↔truly**（F1/F4）。F4 不變式
     （`INV_VIOLATED_concurrentCriticalSections`）才是承載安全性的那一條。
   - **R2** `quint verify` 對「被違反的不變式」**回傳 exit 1**（實測）。REQ-4 的 CI 斷言必須
     以「exit ≠ 0 ＋ ITF 檔存在」表達；`--out-itf` 會抑制 console，不能同時靠 stdout 判讀。
   - **R3** `quint run --witnesses` **即使 witness 0% 仍 exit 0**（實測）。REQ-5／REQ-8 的 CI
     必須**解析百分比輸出**，否則「witness 消失」不會 failsafe。
   - **R4** node-redlock 的 `package.json` **沒有** `@informalsystems/quint`。REQ-1～5 的
     `npx quint` 會即時自網路抓取（供應鏈／可重現性風險）；依 ADR-008 應把
     `@informalsystems/quint@0.32.0` **精確鎖版加入 devDependencies**——此變更需動
     `package.json`，不屬本 analyze run。
4. **建議（§6 方案 A）**：不要在本 analyze run 硬塞 `specs/`；開一個**允許 `specs/**` 與
   `package.json` devDeps** 的新工作項，以 Issue #4 的 REQ-1～9 為基礎並納入 R1–R4 修正。
   方案 B（本 run 直接實作 specs/）與方案 C（把規格草稿塞進 `docs/`）均應被拒絕，理由見 §6。

---

## 2. 證據與根因：F1–F9 逐條對照

### 2.1 對照總表

| # | 位置（實際） | 問題（核實結果） | 性質 |
|---|---|---|---|
| F1 | `src/index.ts:297-341`（核心 308-329） | 缺 `validity <= 0` 檢查，回傳已過期的 `Lock` 且無錯誤 | 安全性（silent） |
| F2 | `src/index.ts:12-27`（`exists` 在 15） | 用 `exists` 而非 value 比對 → 自我阻塞 | 存活性 |
| F3 | `src/index.ts:29-44`（不符即 return 0 在 32-33） | 少數節點遺失的 key 不被修復 → 覆蓋率單調衰減 | 安全性（silent） |
| F4 | `src/index.ts:674-769`（abort 在 739、routine 在 748-749） | `signal.aborted` 是諮詢式；check-then-act 非原子 | 安全性（silent） |
| F5 | `src/index.ts:378-388` | `expiration < Date.now()` 為 check-then-act；Lua value 比對兜底不完備 | 安全性 |
| F6 | `src/index.ts:716-765` | in-flight extension 在 `clearTimeout` 之後 `queue()` → timer 洩漏 | 資源洩漏 |
| F7 | `src/index.ts:354-363`＋`767` | `release()` 失敗自 `finally` 拋出，吃掉回傳值／`signal.error` | 錯誤遮蔽 |
| F8 | 系統模型 | 節點崩潰重啟遺失 key（Kleppmann）→ 兩 client 同時持鎖 | 環境假設 |
| F9 | 系統模型 | `Date.now()` 非單調；`driftFactor` 只涵蓋速率漂移 | 環境假設 |

### 2.2 逐條證據

**F1 — `acquire()` 無 validity 檢查。**
`acquire()` 於 `_execute` 成功後計算 drift 並直接建構 `Lock`：

```
src/index.ts:318-329
  const drift = Math.round((settings?.driftFactor ?? this.settings.driftFactor) * duration) + 2;
  return new Lock(this, resources, value, attempts, start + duration - drift);
```

`start` 是成功那一次 attempt 的起點（`_attemptOperation` 的 `start = Date.now()`，L481，
經 `_execute` 的 `return { attempts, start }`，L448）。若 attempt 的網路往返或 client 停頓
使 `Date.now() > start + duration - drift`，回傳的 `Lock.expiration` **已小於 now**，呼叫端
拿到一個「已過期但沒有錯誤」的鎖。`Lock.expiration` 為 public mutable（L152）。
→ 這正是 catalog-info 所述「鎖已過期後仍被認為持有」的上游。

**F2 — `ACQUIRE_SCRIPT` 用 `exists` 而非 value 比對。**

```
src/index.ts:14-18
  for i, key in ipairs(KEYS) do
    if redis.call("exists", key) == 1 then return 0 end
  end
```

同一 client 上一次 attempt 在少數節點成功留下的**自己的** key，會被下一次 attempt 的
`exists` 判為「別人持有」而擋下。`_execute` 的 retry 迴圈（L436-469）只重試同一 value
（`value = this._random()` 在 acquire 前生成一次，L306），因此這些 key 在 TTL 到期前
一直阻擋自己。兩 client 各佔一半節點時，雙方都無法湊到 quorum，直到 TTL。
→ 存活性缺陷（不會破壞互斥），對應 REQ-5 的 `selfBlockedByOwnValue`。

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

`using()` 內 `controller.abort()` 只在自動續期失敗且鎖已過期時觸發（L734-739），
而 routine 是否停止完全取決於 routine 自己輪詢 `signal.aborted`（README.md:65-78）。
從「routine 讀 `signal.aborted` 為 false」到「routine 真正執行臨界區動作」之間，
鎖可能失效、另一 client 可能取得鎖——互斥於是被破壞，而 client 的 critical section
仍繼續。Issue 的 routine 三態中第 (iii) 種（檢查後再隔一步）正對應此 TOCTOU。
對應 `INV_VIOLATED_concurrentCriticalSections`。

**F5 — `extend()` 的 check-then-act。**

```
src/index.ts:378-388
  if (existing.expiration < Date.now()) { throw new ExecutionError("Cannot extend an already-expired lock.", []); }
  const { attempts, start } = await this._execute(this.scripts.extendScript, existing.resources, [existing.value, duration], settings);
```

`<` 為 check-then-act：檢查與 `extendScript` 之間鎖可能過期。Lua 的 `get ~= ARGV[1]`
兜底**只保證「不會在該節點 key 已消失時把它復活」**（key 已到期 → `get` 回 nil ≠ ARGV[1]
→ 該節點投反對）；它**不檢查** `duration` 到期後 `validity` 是否仍為正。因此：
(i) 兜底在「Redis 端不復活已過期 key」這層是完備的；
(ii) 但 `extend()` 與 `acquire()` 一樣**沒有** `validity <= 0` 檢查（L400-406 直接以
`start + duration - drift` 建 Lock），慢速 extend 仍可回傳已過期的 replacement Lock。
→ 建模決策 7 要求以 F5 動作／guard 呈現，且應把 (ii) 一併納入 F1 類不變式。

**F6 — timer 洩漏（單執行緒排程）。**

```
src/index.ts:716-721  function queue() { timeout = setTimeout(() => (extension = extend()), lock.expiration - Date.now() - settings.automaticExtensionThreshold); }
src/index.ts:750-755  finally { if (timeout) { clearTimeout(timeout); timeout = undefined; } ... }
```

若 routine 完成時剛好有一個 in-flight `extension`（`lock.extend` 尚未 resolve），
`finally` 先清掉舊 timeout，接著 `await extension`（L757-765）；該 extension 成功後在
L728 呼叫 `queue()`，**設定了一個新的 timeout**，而 finally 之後不再有 `clearTimeout`。
計時器因此洩漏，並可能在 routine 已結束後觸發多餘的 extend/release 競爭。
→ 建模決策 9 已正確排除此項（需 JS event loop，成本超收益）；建議改以 ava 測試涵蓋。

**F7 — `release()` 失敗自 `finally` 拋出。**

```
src/index.ts:354-363  lock.expiration = 0; return this._execute(this.scripts.releaseScript, lock.resources, [lock.value], settings);
src/index.ts:767       await lock.release();   // 位於 using() 的 finally
```

`release()` 用呼叫端 settings（預設 `retryCount=10`、`retryDelay=200`、`retryJitter=100`，
L106-112），失敗時 `_execute` 最多 11 次嘗試、10 次延遲，實測阻塞約 **1–3 秒**
（Issue 寫 2–3 秒；精確範圍為 `10 × (200±100)ms`，即 1.0–3.0 秒）。若最終仍失敗，
exception 自 `finally` 拋出，**覆蓋 routine 的正常回傳值**，也讓 `signal.error`
（若已因 abort 設定）失去意義。此為 F7 的雙重傷害：延遲＋錯誤歸因錯誤。

**F8 / F9 — 環境假設。**
F8（節點重啟遺失未同步的 key）與 F9（`Date.now()` 被 NTP／管理員跳躍）都是**環境假設**，
不是 `src/index.ts` 的實作缺陷。`driftFactor=0.01` 只補償速率漂移（L316-321、L395-398），
不處理時鐘跳躍。Issue 把它們做成預設 `false` 的獨立 const 開關是正確取捨：預設開啟會讓
反例淹沒 F1/F3 這類實作層缺陷。

### 2.3 可重現性

F1/F3/F5/F7 需要精確時序交錯，**無法**用既有 ava 測試穩定重現（`src/single.test.ts`、
`src/multi.test.ts` 依賴真實 Redis 與時間）；這正是本 Issue 要以模型檢查窮盡的理由。
本報告的「重現」是**程式碼路徑＋算術**層級（上列 `file:line` 足以逐條重建失敗前提）；
真正的可執行 witness 需待 §7 的新工作項交付。這是**分析層證據**，非已完成的 ITF 反例。

### 2.4 行號核實

Issue 表格引用的行號與實際 `src/index.ts`（共 770 行）**逐條吻合**，無需校正：
F2 的 `ACQUIRE_SCRIPT` L14-18 正是 `exists` 迴圈；F3 的 `EXTEND_SCRIPT` L31-35 正是
value 比對迴圈；F1 的 `acquire()` L318-329 正是 drift 計算＋`new Lock`（缺少的
`validity <= 0` 檢查應落在 L314 之後、L323 之前）；F5 的 `extend()` L379、F6 的
`using()` finally L750-765、F7 的 `release()` L355 ＋ L767 均正確。§2.1 另補上各函式
的完整範圍，供新工作項作為建模錨點。

---

## 3. 工具鏈可行性實測（本環境）

以最小規格（單一 `var x: int`）在 `/tmp` 實測（**未**在 repo 內留下任何檔案）：

| 命令 | 結果 | 退出碼 |
|---|---|---|
| `quint typecheck basic.qnt` | 類型檢查通過 | **0** |
| `quint run ... --invariants <被違反>` | 印出 `[violation] Found an issue`、`error: Invariant violated` | **1** |
| `quint run ... --witnesses <w1> <w2>` | `w1 was witnessed in 6518/10000 (65.18%)`；`w2` 為 0% 時**仍** exit 0 | **0** |
| `quint verify ... --invariants <被違反> --out-itf bad.itf.json` | 印 `found a counterexample`，`bad.itf.json` 為合法 ITF | **1** |
| `quint verify ... --invariants <真不變式>` | `[ok] No violation found` | **0** |

補充事實：
- `quint verify` 預設後端為 Apalache 0.56.1，會自動下載並需 **Java**（本機 Temurin 17 可用）。
  首次下載需網路；暖機後小模型 verify 約 5 秒。
- `quint run` 的 rust 後端與 Apalache 都需要可寫的 `~/.quint`。本 run 的 DSH 檔案沙箱
  不允許寫 workspace 外的 `$HOME`，故實測時以 `HOME=/tmp/qt-home` 執行；一般 CI runner
  的 `$HOME` 可寫，這點**不是** CI 風險，但 CI 需確保 runner 可下載 Apalache（快取或網路）。
- Issue REQ 用到的 CLI 旗標在 0.32.0 全部存在：`--main`、`--invariants`（array）、
  `--max-steps`、`--out-itf`、`--witnesses`。

> 注意 `--invariants`（複數 array，REQ-3/4/8 使用）與 `--invariant`（單數）不同；
> Issue 的 REQ-3/4 寫 `--invariants` 是對的。

---

## 4. 建模計畫的風險與修正建議

> 建模決策 1–11 已與需求方確認，**本報告不變更**；以下為實作前應在 Issue 或新工作項中
> 明確化的事項。

- **R1（不變式的鑑別力）**：`mutualExclusionOnNodes`（`trulyHolds` ∧ `trulyHolds`）在
  `N=3`、quorum=2 下由鴿籠原理保證：兩個 quorum 必有交集節點，而單一節點只存一個 value。
  因此 REQ-3 的「無反例」幾乎必然成立，且**與 F1/F3/F4 是否修好無關**。真正的安全落差是
  `believesHolds(c) ∧ (¬trulyHolds(c))`，以及 F4 的「critical section 在鎖失效後仍執行」。
  **建議**：保留 REQ-3 作為結構性 sanity check，但把 §7 的驗收重心放在 F4 不變式，並
  新增／明示「believes 但非 truly 持有」與「critical section 重疊」的關係。
- **R2（反例的 CI 斷言）**：REQ-4 要求「找不到反例即失敗」。實測 `quint verify` 找到反例時
  **exit 1**，故 CI 應斷言 `exit != 0` **且** `specs/traces/<inv>.itf.json` 存在。因
  `--out-itf` 抑制 console 輸出，不可再依賴 stdout 字串判讀。
- **R3（witness 的 CI 斷言）**：`quint run --witnesses` 在 witness 0% 時 exit 0（實測），
  所以 REQ-5／REQ-8 的「witness 數 > 0」必須以**解析百分比輸出**實現，否則斷言形同虛設。
- **R4（依賴與可重現性）**：node-redlock `package.json` 目前 dependencies 僅
  `node-abort-controller`，**無** `@informalsystems/quint`。REQ 的 `npx quint` 會即時抓取
  未鎖版本，違反 ADR-008 的「精確鎖版加入 devDependencies」。新工作項應新增
  `@informalsystems/quint@0.32.0`（devDependency，精確版），並在 CI 快取 Apalache。
- **R5（規模與界）**：`N=3/M=2/K=1/time 0..10/max-steps 12` 的狀態空間小，REQ-3 的
  ≤10 分鐘應可達成；但 in-flight RPC 集合＋每節點 TTL＋每 client `expiration` 三者分離
  會放大交錯數。建議在 02-impl 早期先跑一次 `verify` 量測時間（REQ-3 的下限保護）。
- **R6（witness 的可達性）**：`INV_VIOLATED_*` 若最短反例長度 > `max-steps`，`verify` 會
  回「無反例」而 REQ-4 失敗。F1/F4 需靠 routine 三態第 (iii) 種延長一步（建模決策 8）；
  開工時應先確認 `max-steps 12` 足以容納最短反例，否則在**不違反建模決策 10** 的前提下
  調整界並記錄。

---

## 5. 影響範圍

- **受影響模組**：`src/index.ts` 的 `acquire`（297-341）、`release`（350-364）、
  `extend`（369-409）、`_execute`（416-471）、`_attemptOperation`（473-550）、
  `_attemptOperationOnClient`（552-625）、`using`（674-769），以及三段 Lua script
  （12-58）。共約 770 行中的核心路徑。
- **受影響使用者／下游**：所有以 `using()` 取得互斥的呼叫端。F1/F3/F4/F5 的失效是
  **靜默**的（無錯誤、無非零退出），呼叫端只會看到「routine 正常完成」，不會看到互斥
  已被破壞——與 `catalog-info.yaml:56` 記載的失效模式一致。
- **repo 現況**：`specs/` 不存在、無任何 `.qnt`；`catalog-info.yaml:80` 明載
  「無 `factory.io/quint-spec`」。既有 ava 測試（`src/single.test.ts`、`multi.test.ts`）
  未涵蓋 F1–F9（需真實 Redis 與時序）。
- **工廠機制**：本 Issue 是跨 repo 的 quint-spec 試點。依 ADR-008，agent 產出的 `.qnt`
  是**草稿**，合併後才生效；且 agent 不得於同一 run 以自己的規格驗證自己的碼
  （docs/06 §4.3）——本單不改 `src/`，天然滿足此分離。

---

## 6. 方案比較

| 方案 | 內容 | 判定 | 理由 |
|---|---|---|---|
| **A（建議）** | 本 analyze run 只交付本報告；另開允許 `specs/**` 與 `package.json` devDeps 的工作項 | **採納** | 符合 analyze 護欄；把高風險的規格撰寫交給可審查的獨立工作項；符合 ADR-008 草稿／審查分離 |
| **B** | 在本 analyze run 直接新增 `specs/**` | **拒絕** | `--analyze-only` 白名單只有 `docs/**`（`factory-crosscheck.ts:159-169`）→ `analyze-code-change` needs-human；等於繞過護欄 |
| **C** | 把規格草稿放進 `docs/research/quint/` 以滿足 `docs/` 前綴 | **拒絕** | 通過機械檢查但**違反建模決策 11** 與 ADR-008 的 `factory.io/quint-spec` 規格根目錄語意；把可執行規格混入研究報告目錄，會使其狀態（草稿／生效、由誰套用）無法辨識 |
| **D** | 依 factory-stop-rules #8 直接停手、不產報告 | **拒絕** | 任務模板明確允許 in-loop 的 analyze 產出報告（`task-template-analyze.txt` 步驟 6）；報告能精確記錄範圍差異並給出下一步，優於空手停手。範圍差異以 §0／§8 誠實揭露 |

**方案 A 的「為什麼現在不做」**：Issue 的 `specs/` 產物是「可執行規格＋ITF 反例」，
屬 ADR-008 的 spec 草稿生命週期，需要人類審查後才生效；把它綁進一個當下被護欄限制為
`docs/**` 的 analyze run，只會製造 needs-human 的假完成。拆成獨立工作項，審查者可以
只審 `specs/**` 的技術正確性。

---

## 7. 建議下一步（可直接開成工作項）

### 7.1 工作項描述

> **標題**：為 node-redlock 建立 as-is Quint 可執行規格，形式化 F1–F9 並存證反例
> **類型**：需要一個**允許 `specs/**` 與 `package.json` devDependencies** 的型別
> （例如 docs/19/docs/21 已列為候選的 `agent-write-spec`），或由人類明確授權一個
> 後繼工作項。**不可**再用 `agent-analyze` 承載此交付。
> **內容**：沿用 Issue #4 的建模決策 1–11 與 REQ-1～REQ-9，並納入 §4 的 R1–R6。

### 7.2 驗收條件草案（REQ-1～REQ-9 修訂版）

- **REQ-1**：`npx quint typecheck specs/redlock.qnt` 退出碼 0。
- **REQ-2**：`npx quint run specs/redlock.qnt --main=<instance 模組> --max-steps 12` 退出碼 0；
  instance 以 `N=3/M=2/K=1/time 0..10` 實例化，無 `Uninitialized const`。
- **REQ-3**：`npx quint verify specs/redlock.qnt --invariants mutualExclusionOnNodes
  --max-steps 12` 無反例、exit 0、單次牆鐘 ≤ 10 分鐘。**（R1：此條為結構性 sanity check；
  另須新增「believes 但非 truly 持有」或 critical-section 重疊的關係說明。）**
- **REQ-4**：`INV_VIOLATED_returnsExpiredLock`（F1）、`INV_VIOLATED_quorumCoverageDecay`（F3）、
  `INV_VIOLATED_concurrentCriticalSections`（F4，須由 routine 第 (iii) 態觸發）各自
  **exit ≠ 0** 且 `--out-itf` 產生 `specs/traces/<inv 名>.itf.json`。**（R2）**
- **REQ-5**：`selfBlockedByOwnValue`、`bothClientsFailWithinRetryWindow` 兩個 witness 的
  trace 數 **> 0**；以 `quint run --witnesses` 取得，**解析輸出百分比**（不可依賴 exit code），
  百分比貼入 `specs/README.md`。**（R3）**
- **REQ-6**：F5 與 F7 以動作／guard 呈現（`specs/README.md` 指明定義名）；F8、F9 各對應一個
  預設 `false` 的 const 開關，README 記錄開啟後結果。
- **REQ-7**：`specs/README.md` 含「已涵蓋／刻意未涵蓋」兩份清單，明載 F6 排除理由與
  「改以 ava 測試涵蓋」的替代建議。
- **REQ-8**：`specs/README.md` 附可直接複製的 `.github/factory/quint-paths.yml` 與
  `.github/workflows/quint-verify.yml` **草稿**；quint-verify 須含兩類斷言——真不變式須綠、
  `INV_VIOLATED_*` 須確實被違反（**依 R2：`exit ≠ 0` ＋ ITF 存在**）；positive witness
  須 > 0（**依 R3：解析百分比**）。草稿僅存放於 `specs/` 之下，不寫入 `.github/`。
- **REQ-9**：`git diff --name-only origin/software-factory...HEAD` 不含 `src/`、`.github/`、
  `catalog-info.yaml`、`CODEOWNERS`。
- **REQ-10（新增，R4）**：`@informalsystems/quint@0.32.0` 精確鎖版加入 devDependencies；
  CI 有 Apalache 快取／Java 17 前置。
- **REQ-11（新增，R6）**：記錄 `max-steps 12` 足以容納三條 `INV_VIOLATED_*` 最短反例的
  實測證據（或記錄在建模決策 10 界內的必要調整）。

### 7.3 人類待辦（沿用 Issue #4，agent 無權執行）

於 `catalog-info.yaml` 登錄 `factory.io/quint-spec: specs/`；依讀者草稿建立
`.github/factory/quint-paths.yml` 與 `.github/workflows/quint-verify.yml`；把 `quint-verify`
登記為 required check；依 ADR-008 確認 `.qnt` 草稿審查流程；評估是否依 F1/F3/F4 反例
開立修復工單。

---

## 8. Requirements 對照（`report.json`）

| REQ | 本 run 狀態 | 說明 |
|---|---|---|
| REQ-1 | `failed` | 未交付 `specs/redlock.qnt`；`typecheck` 無標的。工具鏈本身可行（§3）。 |
| REQ-2 | `failed` | 未交付 instance 模組與 `specs/redlock.qnt`。 |
| REQ-3 | `failed` | 未交付真不變式與 verify；§4 R1 指出此條鑑別力有限。 |
| REQ-4 | `failed` | 未交付三條 `INV_VIOLATED_*` 與 ITF 反例；§3 已實測驗證行為（R2）。 |
| REQ-5 | `failed` | 未交付 witness 與百分比輸出；§3 已實測 witness 語意（R3）。 |
| REQ-6 | `failed` | 未交付模型與 `specs/README.md`；F5/F7/F8/F9 之分析見 §2。 |
| REQ-7 | `failed` | 未交付 `specs/README.md`。 |
| REQ-8 | `failed` | 未交付 CI 草稿（且草稿不得寫入 `.github/`）。 |
| REQ-9 | `passed` | 本 run diff **僅** `docs/research/4-quint-spec-feasibility.md`，不含 `src/`、`.github/`、`catalog-info.yaml`、`CODEOWNERS`。 |

> REQ-9 是本 run 唯一能滿足的條目，因為它是一條**負向路徑約束**；其餘 REQ 均要求
> `specs/` 產物，受 `agent-analyze` 護欄阻擋（§0）。此為誠實自報，`factory-crosscheck`
> 以 analyze 模式驗證無 `src/` 變更。

---

## 9. 變更清單

本 run 無任何 `src/`、測試或設定變更；唯一變更是本報告
`docs/research/4-quint-spec-feasibility.md`。符合 `--analyze-only` 白名單與
factory-stop-rules #8 的「不自行擴大範圍」。
