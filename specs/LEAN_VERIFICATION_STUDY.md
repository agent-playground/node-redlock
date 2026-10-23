# Redlock 分散式鎖的形式化反例數學證明研究報告（Lean 4）

本報告旨在探討並實踐使用 **Lean 4 定理證明器（Interactive Theorem Prover）**，對 [specs/README.md](file:///Users/cfh00805122/lab/playground/node-redlock/specs/README.md) 與 [specs/uppaal/README.md](file:///Users/cfh00805122/lab/playground/node-redlock/specs/uppaal/README.md) 所記錄的 Redlock 演算法固有缺陷進行**數學反例存在性定理證明（Constructive Counterexample Proof）**。

專案完整形式化規格與定理證明程式碼位於 [`specs/lean/`](file:///Users/cfh00805122/lab/playground/node-redlock/specs/lean)。

---

## 一、研究動機與核心結論

### 1. 為何需要 Lean 4 的數學證明？
在目前的規格體系中：
- **Quint + Apalache** 採用有界模型檢驗（Bounded Model Checking, BMC）與符號執行（`--max-steps=12`）。它能有效探索出反例狀態並輸出 ITF 軌跡（如 `traces/*.itf.json`）。但其全域單一時鐘架構（建模決策 5）**無法表達 F9 時鐘突跳**。
- **UPPAAL** 採用連續時間自動機與 DBM zone 抽象，成功透過查詢 2 驗證了 F9；但其時鐘變數無法被讀取或位移，必須依賴偏移量變數，且檢驗結果仰賴外部二進制工具 `verifyta`。
- **Lean 4** 透過**依值型別論（Dependent Type Theory, DTT）**，將離散狀態空間與多時鐘自動機統一納入嚴格的一階邏輯演繹體系。透過建構性證明，直接證明存在性定理：
  $$\exists s \in \text{State},\; \text{Reachable}(s) \land \neg \text{Invariant}(s)$$
  從純數學層面確鑿證實：**F8（崩潰遺失 Key）、F4（臨界區重疊）以及 F9（UPPAAL 時鐘突跳）均為 Redlock 在給定環境假設下的必然數學反例**。

### 2. 核心成果一覽
本專案已在 [`specs/lean/Redlock/Counterexamples.lean`](file:///Users/cfh00805122/lab/playground/node-redlock/specs/lean/Redlock/Counterexamples.lean) 中完成了三大核心固有缺陷的無 `sorry`、全量編譯通過的數學證明：

| 缺陷項目 | 定理名稱 | 數學意義 | 證明形式 |
| :--- | :--- | :--- | :--- |
| **F8（Kleppmann 缺陷）** | `counterexample_f8_two_clients_believe_lock` | 當節點崩潰重啟並遺失記憶體狀態時，**必然存在兩位客戶端同時相信自己持有合法有效鎖的可達狀態**。 | 建構性 9 步微步轉移推導 |
| **F4（臨界區重疊）** | `counterexample_f4_concurrent_critical_sections` | 在缺乏 fencing token 與非同步延遲下，**必然存在兩位客戶端同時處於受保護臨界區內（互斥性徹底失效）的可達狀態**。 | 建構性 14 步微步轉移推導 |
| **F9（UPPAAL 時鐘突跳）** | `counterexample_f9_uppaal_clock_jump` | 在**完全無節點異常（`nodeJumps = 0`）**下，僅靠客戶端時鐘往後跳 5ms，**必然存在兩位客戶端同時處於臨界區的可達狀態**。 | 建構性 12 步多時鐘轉移推導 |

---

## 二、小步操作語意架構（Small-Step LTS）

### 1. 基準離散模型（[Basic.lean](file:///Users/cfh00805122/lab/playground/node-redlock/specs/lean/Redlock/Basic.lean)）
對齊 Quint 的基準模型配置：
- **節點規模**：$N = 3$（Quorum = 2）。
- **客戶端規模**：$M = 2$（Client 0 與 Client 1）。
- **租約參數**：$\text{DURATION} = 2$，$\text{DRIFT} = 1$，有效時長為 $2 - 1 = 1$。
- **操作轉移**：透過決定性轉移函數 `nextState : State → Action → Option State` 定義歸納關係 `Step` 與 `Reachable`。

### 2. 多時鐘時間自動機模型（[Timed.lean](file:///Users/cfh00805122/lab/playground/node-redlock/specs/lean/Redlock/Timed.lean)）
專門對齊 UPPAAL（[specs/uppaal/README.md](file:///Users/cfh00805122/lab/playground/node-redlock/specs/uppaal/README.md)）的模型設計：
- **時鐘解耦**：
  - `realNow : Nat`：物理真實單調時鐘，決定節點端 key 的 TTL 到期時間。
  - `clientSkew : ClientId → Nat`：客戶端本地 `Date.now()` 的突跳偏差量（往後跳 5ms 造成本地量測時長變短）。
- **異常分類隔離**：
  - `nodeJumps : Nat`：節點時鐘突跳次數（在 F9 證明中**嚴格約束恆為 0**）。
  - `clientJumps : Nat`：客戶端時鐘突跳次數。
- **UPPAAL 基準參數**：
  - $\text{DURATION} = 20 \text{ ms}$
  - $\text{DRIFT} = 2 \text{ ms}$
  - $\text{MAX\_LEASE} = \text{DURATION} - \text{DRIFT} = 18 \text{ ms}$

---

## 三、三大核心反例定理詳解

### 1. F8 缺陷：節點重啟遺失 Key 導致雙重持鎖
- **定理**：
  ```lean
  theorem counterexample_f8_two_clients_believe_lock :
      ∃ s : State, Reachable s ∧ ¬ inv_f8_no_two_clients_believe_lock s
  ```
- **9 步推導精要**：
  Client 1 取得 Node 0, Node 1 達 Quorum 後，Node 1 崩潰重啟（清空 key）。Client 0 接著取得重啟後的 Node 1 與空閒的 Node 2 亦達 Quorum。兩者結算後在 $t=0$ 同時確信持有有效鎖。

---

### 2. F4 缺陷：臨界區並行重疊（互斥性失效）
- **定理**：
  ```lean
  theorem counterexample_f4_concurrent_critical_sections :
      ∃ s : State, Reachable s ∧ ¬ inv_f4_no_concurrent_critical s
  ```
- **14 步推導精要**：
  Client 0 取得鎖進入臨界區後，其持有的鎖被釋放或到期，但因缺乏 fencing token 且任務未退出（`inCritical = true`），Client 1 合法取得新鎖並進入臨界區，兩者並行重疊。

---

### 3. F9 缺陷：UPPAAL 多時鐘突跳（零節點異常下的互斥破壞）

#### (1) 背景說明與 UPPAAL 查詢 2
在 UPPAAL 模型檢驗中，最重要的結論是查詢 2：
```tctl
E<> (Client0.InCritical && Client1.InCritical && node_jumps == 0)
```
這條性質證明：**完全不碰節點時鐘、無節點崩潰、無網路分割**，僅靠客戶端時鐘往後跳 5ms，互斥性即崩潰。

#### (2) Lean 4 形式化定理
```lean
/-- 互斥性：不存在兩位客戶端同時在臨界區且自認持鎖有效 -/
def inv_timed_mutual_exclusion (s : TimedState) : Prop :=
  ¬ ((s.clients c0).believesInLease s.realNow (s.clientSkew c0) &&
     (s.clients c1).believesInLease s.realNow (s.clientSkew c1))

/-- F9 反例數學定理：在零節點異常（nodeJumps = 0）下，僅靠客戶端時鐘突跳即打破互斥性 -/
theorem counterexample_f9_uppaal_clock_jump :
    ∃ s : TimedState, TimedReachable s ∧
        s.nodeJumps = 0 ∧
        ¬ inv_timed_mutual_exclusion s
```

#### (3) 12 步建構性推導鏈（完全復刻 UPPAAL 軌跡）
1. **$s_0 \to s_1$**：Client 0 於 $t=0$ 發起取鎖（`acquiredAt = 0`）。
2. **$s_1 \to s_2$**：**客戶端時鐘對手發動突跳**（`TimedAction.clientClockJump c0 5`），`clientSkew c0 = 5`，而 `nodeJumps = 0`。
3. **$s_2 \to s_5$**：Client 0 順利取得 Node 0, Node 1, Node 2（節點 key 過期時間分別設定為真實時間 $0 + 20 = 20$）。
4. **$s_5 \to s_6$**：Client 0 進入臨界區（此時量測經過時間 $(0 - 0) - 5 = 0 \le 18$，合法進入）。
5. **$s_6 \to s_7$**：**真實物理時間流逝 21ms**（`TimedAction.advanceRealTime 21`，`realNow = 21`）。
   - 此時節點上三把 key 依真實物理時間**全部自然過期**（$20 \le 21$）！
6. **$s_7 \to s_8$**：Client 1 於真實時間 $t=21$ 發起取鎖（`acquiredAt = 21`）。
7. **$s_8 \to s_{11}$**：Client 1 向 Node 0, Node 1, Node 2 請求鎖。由於舊 key 已自然過期，三個節點**完全合法地授予** Client 1。
8. **$s_{11} \to s_{12}$**：Client 1 進入臨界區（`perceivedElapsedTime = 0 ≤ 18`）。

**狀態 $s_{12}$ 的數學檢驗**：
- **零節點異常**：`s12.nodeJumps = 0`（完全沒有動過任何節點時鐘，由 `rfl` 證得）。
- **Client 1**：在臨界區，且自認租約有效（`believesInLease = true`）。
- **Client 0**：仍在臨界區！其量測到的經過時間為：
  $$\text{realNow} - \text{acquiredAt} - \text{skew} = 21 - 0 - 5 = 16 \text{ ms} \le 18 \text{ ms}$$
  Client 0 毫不知情，確信自己還在 18ms 的安全租約內（`believesInLease = true`）。
- **結論**：兩者同時在臨界區，互斥性徹底失效！

---

## 四、驗證工具鏈重跑步驟

本專案所有 Lean 4 程式碼均已編譯通過，零報錯、零警告、無 `sorry`。

### 重跑指令：
```bash
export PATH="$HOME/.elan/bin:$PATH"
cd specs/lean
lake clean
lake build
lake exe redlock
```

### 執行輸出：
```console
Build completed successfully (12 jobs).
Lean 4 Redlock Specification and Counterexample Proofs
Formal verification of F4 (Concurrent Critical Sections), F8 (Crash Loss Key), and F9 (UPPAAL Clock Jump).
```

---

## 五、綜合評估與理論意義

| 工具 | 時間模型 | 擅長面向 | 限制 |
| :--- | :--- | :--- | :--- |
| **Quint** | 離散單一時鐘 | 快速符號執行探索 ITF 軌跡 | 單一時鐘無法表達客戶端/伺服器時間倒流解耦（F9 空開關） |
| **UPPAAL** | 連續多時鐘 DBM Zone | 時間自動機 TCTL 公式驗證 | 時鐘變數不可讀/不可位移，仰賴外部模型檢驗器數值輸出 |
| **Lean 4** | 任意抽象操作語意（LTS） | 數學級別定理演繹證明（Constructive Proof） | 需手動構造或引導形式化推導鏈 |

透過本研究，我們證實了：**藉由 Lean 4 依值型別論，不僅能證明 Quint 有界檢驗發現的 F4 與 F8，更能無縫納入 UPPAAL 的多時鐘時間自動機語意，在統一的數學邏輯體系下完成 F9 的嚴密反例證明**。
