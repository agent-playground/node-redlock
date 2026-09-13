# specs/ — node-redlock 的 Quint 可執行規格

本目錄是 `src/index.ts`（node-redlock，770 行）的 **as-is 形式化規格**：忠實描述
**現況（含缺陷）**，不描述「正確的 Redlock 應該如何」。

> **⚠️ 讀者必讀：這份規格描述的是一個有缺陷的系統。**
> 預期會被違反的不變式一律以 `INV_VIOLATED_` 開頭，這是刻意的命名契約——
> `quint` 的輸出本身就會說明它的語意。若 `quint run` 對某條
> `INV_VIOLATED_*` 回報「無違反」，代表**規格已與程式碼脫節**，不是好消息。

## 檔案

| 檔案 | 內容 |
|---|---|
| `redlock.qnt` | 參數化規格（`const` 未實例化，單獨 `quint run` 會失敗）。型別、純函數、狀態機、不變式、witness。**不含任何 `run` 測試**。 |
| `redlockTest.qnt` | 具體實例模組 + `run` 測試。要跑任何東西都是跑這個檔案，用 `--main=<實例>` 選情境。 |
| `traces/*.itf.json` | 四條 `INV_VIOLATED_*` 的反例軌跡（ITF 格式，由 `quint verify --out-itf` 產出）。 |
| `README.md` | 本檔：驗證報告、覆蓋範圍、CI 草稿、工具鏈限制。 |

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

### 3. `run` 測試（前提條件、純函數、init 形狀、F2 劇本）

```console
$ npx quint test specs/redlockTest.qnt --main=redlockAssumptions
  redlockAssumptions
    ok quorumAssumptionTest passed 1 test(s)
    ok scaleBoundTest passed 1 test(s)
    ok pureFunctionTest passed 1 test(s)
    ok initShapeTest passed 1 test(s)
  4 passing

$ npx quint test specs/redlockTest.qnt --main=redlockF2Scenario
  redlockF2Scenario
    ok bothClientsStarveTest passed 1 test(s)
  1 passing
```

### 4. 不變式（REQ-3 / REQ-4）

| 不變式 | 實例 | `--max-steps` | 實測牆鐘 | 預期 | 實測 |
|---|---|---|---|---|---|
| `mutualExclusionOnNodes` | `redlockDefault` | 8 | **164–194 s**（兩次實測） | 無違反 | ✅ 無違反 |
| `INV_VIOLATED_returnsExpiredLock` | `redlockDefault` | 5 | **12 s** | 必須找到反例 | ✅ 反例 + ITF |
| `INV_VIOLATED_quorumCoverageDecay` | `redlockCrashLoss` | 5 | **10 s** | 必須找到反例 | ✅ 反例 + ITF |
| `INV_VIOLATED_releaseErrorMasksAbort` | `redlockDefault` | 10 | **95 s** | 必須找到反例 | ✅ 反例 + ITF |
| `INV_VIOLATED_concurrentCriticalSections` | `redlockDefault` | 12 | **676 s** | 必須找到反例 | ✅ 反例 + ITF |

```console
# 真不變式：必須「無違反」、退出碼 0
$ npx quint verify specs/redlockTest.qnt --main=redlockDefault \
    --invariants mutualExclusionOnNodes --max-steps 8
[ok] No violation found

# 被違反的不變式：必須退出碼 ≠ 0 且產出 ITF（不可依賴 stdout 判讀，見 R2）
$ npx quint verify specs/redlockTest.qnt --main=redlockDefault \
    --invariants INV_VIOLATED_returnsExpiredLock --max-steps 5 \
    --out-itf specs/traces/INV_VIOLATED_returnsExpiredLock.itf.json
[violation] Found an issue
error: found a counterexample        # 退出碼 1
```

### 5. 正向 witness（REQ-5）

```console
$ npx quint run specs/redlockTest.qnt --main=redlockDefault --max-steps 12 \
    --max-samples 10000 --witnesses selfBlockedByOwnValue bothClientsFailWithinRetryWindow
selfBlockedByOwnValue was witnessed in 119 trace(s) out of 10000 explored (1.19%)
bothClientsFailWithinRetryWindow was witnessed in 0 trace(s) out of 10000 explored (0.00%)
```

**⚠️ 第二個 witness 的實測值刻意留在 0%：它不該被當成 CI 斷言。**
`bothClientsFailWithinRetryWindow` 在隨機走訪下機率極低（加大樣本後實測
`6/400000 ≈ 0.0015%`），把它放進「百分比必須 > 0」的 CI 閘門會**不穩定地紅燈**。
可達性改用**決定性**的 `run` 測試證明（`redlockF2Scenario::bothClientsStarveTest`，
見上方 §3）——那比隨機抽到的 witness 更強，因為它是可重現的腳本。
CI 的百分比斷言只保留 `selfBlockedByOwnValue`。

### 6. 環境注意

`quint verify` 需要 **Java**（本機實測 Java 25 可用；Apalache 0.56.1 由 quint
首次執行時自動下載，需要可寫的 `$HOME` 與網路）。`quint run` 的 Rust 後端同樣
需要可寫的 `$HOME`。CI runner 一般滿足；沙箱環境需 `HOME=<可寫目錄>`。

---

## 已涵蓋（REQ-7）

| 項目 | 說明 |
|---|---|
| **F1** 缺 `validity <= 0` 檢查 | `acquire()` 結算（`src/index.ts:318-329`）。`returnedExpired` 在 `completeAcquire` 以 `acquireStart + DURATION - DRIFT <= now` 判定。 |
| **F2** `exists` 造成的自我阻塞 | `ACQUIRE_SCRIPT`（L12-27）。`attemptAcquire` 以 `exists` 語意判定 `acquireOk`，`selfBlocked` 記錄「被自己上一輪留下的 key 擋住」。 |
| **F3** extend 不修復少數節點 | `EXTEND_SCRIPT`（L29-44）。`attemptExtend` 只更新投贊成的節點；`permits` 只增不減，真實覆蓋率由 `permitsOf` 以 `nodes` 過濾。 |
| **F4** abort 諮詢式 / 臨界區重疊 | routine 三態（`UNCHECKED` / `CHECKED` / `CHECKED_LATE`）＋ `criticalWork` 讓鎖可在臨界區執行途中失效。**安全性結論由此條承載。** |
| **F5** `extend()` 的 check-then-act | `failExtend` 的 `stillValidAt` guard（L734-739）＋ `completeExtend` 同樣缺 validity 檢查（L400-406，併入 F1 的 `returnedExpired`）。 |
| **F7** release 失敗遮蔽錯誤 | `startRelease` 先設 `expiration = 0`（L355）＋ `completeRelease` 判定 `releaseForCount < quorum`（L354-363 + 767）。 |
| **F8** 節點崩潰遺失 key（Kleppmann） | `crashAndLoseKey`，由 `ENABLE_CRASH_LOSS` 控制（**預設 false**）。 |
| **F9** 時鐘跳躍 | `jumpClock`，由 `ENABLE_CLOCK_JUMP` 控制（**預設 false**）。 |
| 三層時間 | 全域 `now` ＋ 每節點 key 的真實到期 ＋ 每 client 相信的 `expiration`。 |
| quorum 前提 | `redlockAssumptions::quorumAssumptionTest`（`2f < n`、`quorum = ⌊n/2⌋+1`）。 |

## 刻意未涵蓋（REQ-7）

| 項目 | 為何不做 |
|---|---|
| **F6（`using()` 的 timer 洩漏，L716-765）** | 它是**單執行緒 JS event loop 的排程缺陷**：in-flight `extension` 在 `clearTimeout` 之後呼叫 `queue()`，重設了一個新的 timeout 而無人清除。要在 Quint 建模它必須引入 JS 事件迴圈與 timer 佇列，成本遠超收益，而且模型本身會比被驗的程式碼更複雜。**替代方案：改用 ava 測試涵蓋**——這個缺陷不需要精確時序交錯即可穩定重現（在 routine 結束時讓 `lock.extend` 懸置，斷言 `using()` 返回後沒有殘留 timer）。建議另開 `agent-add-tests` 工作項。 |
| **`K >= 2` 的多資源鎖** | 多資源的 all-or-nothing 由**單一 Lua script 的原子性**保證，那是 Redis 的性質、不是這 770 行的性質。建 `K=2` 只會驗證我們當作公理的東西。代價：`acquire(["a","b"])` 失敗路徑上「部分資源 × 部分節點」的交叉狀態未被涵蓋。 |
| **ITF 神諭測試（模型 vs 實作 trace 重放）** | `src/index.ts` 依賴真實時間、網路與 Redis；要把一條 Quint 軌跡重放進去，得先建一個能控制時鐘與逐節點注入故障的假 Redis——harness 的複雜度會超過被驗的 770 行，且 harness 自身的缺陷會使結論無法歸因。 |
| **jitter / backoff 的時間分佈** | `_execute` 的重試延遲（L451-463）只被抽象成「可重試 K 次」的非確定性選擇。延遲分佈不影響任何安全性不變式。 |
| **崩潰重啟後的 AOF 同步細節** | F8 只建模「key 消失」這個後果，不建模 Redis 的持久化機制本身。 |
| **`driftFactor` 的速率漂移** | 以 `DRIFT` 這個已算好的常數呈現；漂移的**速率**建模不會改變任何不變式。 |

---

## 不變式清單

| 名稱 | 類型 | 意義 |
|---|---|---|
| `mutualExclusionOnNodes` | 真不變式 | 不存在兩個 client 同時 `trulyHolds`（至少 quorum 個節點上 key 值相符且未到期）。 |
| `INV_VIOLATED_returnsExpiredLock` | **預期違反** | `acquire()` / `extend()` 結算時算出的 `expiration` 已經成為過去，而程式碼沒有任何檢查就回傳（F1 / F5）。 |
| `INV_VIOLATED_quorumCoverageDecay` | **預期違反** | client 相信持有有效鎖，但真實覆蓋率已跌破 quorum（F3）。 |
| `INV_VIOLATED_concurrentCriticalSections` | **預期違反** | 兩個 client 同時在臨界區（F4）。**這是承載安全性結論的那一條。** |
| `INV_VIOLATED_releaseErrorMasksAbort` | **預期違反** | release 失敗吃掉了已發生的 abort 錯誤（F7）。 |

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

## 規模與界（REQ-11 / REQ-12）

### 規模上限（建模決策 10）

節點 `N=3`、client `M=2`、resource `K=1`、`DURATION=2`、`DRIFT=1`、
`EXTENSION_THRESHOLD=1`。`N=3` 是能形成 quorum 又容忍 1 故障的最小值；
`M=2` 是互斥性違反所需的最小 client 數。

### `--max-steps 12` 的充分性（REQ-11）

最短反例所需步數（`quint run` 抽樣量測，`--max-samples 20000`）：

| 不變式 | 最短步數 | 落在 12 內？ |
|---|---|---|
| `INV_VIOLATED_returnsExpiredLock` | 4 | ✅ |
| `INV_VIOLATED_quorumCoverageDecay`（`redlockCrashLoss`） | 4 | ✅ |
| `INV_VIOLATED_releaseErrorMasksAbort` | 10 | ✅ |
| `INV_VIOLATED_concurrentCriticalSections` | 12 | ✅（恰好在邊界） |

**四條都落在 `--max-steps 12` 之內**，因此 REQ-2 的界是充分的。
但要注意：F4 的最短反例**恰好等於 12**，沒有任何餘裕；若模型再增加任何一步
（例如加入 `using()` 的 timer 模型），這個界就會失守。CI 的 F4 檢查直接使用 12。

### 真不變式的界必須下修：REQ-3 的「12 步 ≤10 分鐘」**不可行**

`mutualExclusionOnNodes` 的實測規模曲線（`quint verify`，本機）：

| `--max-steps` | 牆鐘 |
|---|---|
| 4 | 12 s |
| 5 | 13 s |
| 6 | 22 s |
| 7 | 25 s |
| 8 | **164 s**（第二次實測 194 s，差異來自機器負載） |
| 10 | **> 600 s（未完成，逾時終止）** |
| 12 | 未嘗試（依曲線外推約需數十分鐘至數小時） |

成長率約每步 ×2.5。**REQ-3 要求 12 步在 10 分鐘內完成，這是做不到的。**
原始 factory run（`34735315950`）耗盡 50 分鐘預算，正是撞上這面牆。

### 四條反例的實測牆鐘（REQ-12 的驗證紀錄）

| 反例 | `--max-steps` | 實測牆鐘 | ITF 狀態數 |
|---|---|---|---|
| F1 / F5 `returnsExpiredLock` | 5 | 12 s | 5 |
| F3 `quorumCoverageDecay`（`redlockCrashLoss`） | 5 | 10 s | 5 |
| F7 `releaseErrorMasksAbort` | 10 | 95 s | 10 |
| F4 `concurrentCriticalSections` | 12 | **676 s（11.3 分鐘）** | 13 |

F4 的 676 秒**超過 REQ-3 的 10 分鐘門檻**，但 REQ-3 的門檻是針對
「真不變式」而非反例搜尋，REQ-4 對反例只要求「退出碼 ≠ 0 ＋ ITF 存在」。
F4 的 ITF 已驗證含 **13 個狀態、2 個 client 同時處於 `CRITICAL`**。

### CI 的總牆鐘預算

上列步驟相加：真不變式 164 s ＋ F1 12 s ＋ F3 10 s ＋ F7 95 s ＋ F4 676 s
＋ typecheck/run/test 約 15 s ≈ **約 16 分鐘**（未計安裝與 Apalache 首次下載）。
CI 草稿的 job 逾時因此設為 **45 分鐘**，留給冷啟動快取與 runner 變異的餘裕。

**採用的替代證據（依 REQ-11 的授權）**：以 **`--max-steps 8`（164–194 秒）**
作為 CI 的界。這在方法論上是充分的，因為 `mutualExclusionOnNodes` 是
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
    # 實測總牆鐘約 16 分鐘（F4 的 verify 單獨就要 676 s）；留冷啟動與 runner 變異餘裕
    timeout-minutes: 45
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
          npx quint test specs/redlockTest.qnt --main=redlockF2Scenario

      # (1) 真不變式：必須「無違反」。
      #     界為 8 而非 12 —— 12 步依實測需數十分鐘以上（見 specs/README.md §規模）。
      - name: Invariant holds — mutualExclusionOnNodes
        run: |
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants mutualExclusionOnNodes --max-steps 8

      # (2) 被違反的不變式：必須 exit != 0 且產出 ITF。
      #     R2：--out-itf 會抑制 console 輸出，不可依賴 stdout 字串判讀。
      - name: Invariant violated — F1 / F5 returnsExpiredLock
        run: |
          set +e
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants INV_VIOLATED_returnsExpiredLock --max-steps 5 \
            --out-itf specs/traces/INV_VIOLATED_returnsExpiredLock.itf.json
          rc=$?
          set -e
          [ "$rc" -ne 0 ] || { echo "::error::反例消失了——規格已與程式碼脫節，請更新規格"; exit 1; }
          [ -s specs/traces/INV_VIOLATED_returnsExpiredLock.itf.json ]

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

      - name: Invariant violated — F7 releaseErrorMasksAbort
        run: |
          set +e
          npx quint verify specs/redlockTest.qnt --main=redlockDefault \
            --invariants INV_VIOLATED_releaseErrorMasksAbort --max-steps 10 \
            --out-itf specs/traces/INV_VIOLATED_releaseErrorMasksAbort.itf.json
          rc=$?
          set -e
          [ "$rc" -ne 0 ] || { echo "::error::反例消失了——請更新規格"; exit 1; }
          [ -s specs/traces/INV_VIOLATED_releaseErrorMasksAbort.itf.json ]

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

      # (3) 正向 witness：**必須解析百分比**。
      #     R3：quint run --witnesses 在 0% 時仍然 exit 0，只看退出碼會漏掉失效的 witness。
      #     注意：bothClientsFailWithinRetryWindow 刻意不列入（隨機走訪下約 0.0015%，
      #     會不穩定紅燈）；F2 的可達性由 redlockF2Scenario::bothClientsStarveTest 決定性證明。
      - name: Witness reachable — selfBlockedByOwnValue
        run: |
          out=$(npx quint run specs/redlockTest.qnt --main=redlockDefault \
                  --max-steps 12 --max-samples 10000 \
                  --witnesses selfBlockedByOwnValue 2>&1)
          echo "$out"
          pct=$(printf '%s' "$out" | grep -oE '\(([0-9]+\.[0-9]+)%\)' | tr -d '()%' | head -1)
          [ -n "$pct" ] || { echo "::error::解析不到 witness 百分比輸出"; exit 1; }
          awk -v p="$pct" 'BEGIN { if (p+0 <= 0) { print "::error::witness 為 0%，自我阻塞路徑已不可達"; exit 1 } }'
```

### 套用步驟（人類）

1. 建立 `.github/factory/quint-paths.yml`（複製上方內容）。
2. 建立 `.github/workflows/quint-verify.yml`（複製上方內容）。
3. 將 `quint-verify` 登記為 required check（`config/github/main-ruleset.json` 對應位置）。
4. 於 `catalog-info.yaml` 新增 `factory.io/quint-spec: specs/`。
5. 確認 runner 可下載 Apalache（快取或網路）並有 Java。

---

## 與程式碼同步（維護契約）

**規格是 ground truth，不是程式碼的附屬品。** 兩個方向都要處理：

- **改 `src/index.ts` 的行為** → 必須先更新 `specs/redlock.qnt` 並重跑本檔的
  全部指令。若某條 `INV_VIOLATED_*` 的反例消失，CI 會紅燈——**那是設計**：
  它強迫規格被同步更新，而不是默默腐爛。
- **規格本身要改** → 依 `docs/06 §4.3`，agent **不得**在同一 run 內用自己寫的
  規格去驗證自己寫的程式碼。本單只交付規格、未改 `src/`，天然滿足此分離。
- 依 `docs/ADR/008`，本目錄的 `.qnt` 是 **agent 撰寫的草稿**，合併後才生效。
