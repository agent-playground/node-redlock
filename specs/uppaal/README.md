# specs/uppaal/ — F9（時鐘突跳 / NTP Step）的 UPPAAL 時間自動機模型

本目錄回答一個 **Quint 模型回答不了的問題**：客戶端與 Redis 節點的物理時鐘不同步，
是否**獨立於**節點故障就足以破壞 Redlock 的互斥性？

**實測答案：是。** 在完全沒有動過任何節點（`node_jumps == 0`）的情況下，
只要客戶端的 `Date.now()` 往後跳 5ms，就能讓兩個客戶端同時進入臨界區。

---

## 1. 為什麼 Quint 答不了，要換 UPPAAL

`../README.md` 的「F9 的建模缺陷」記載了根因：Quint 模型採用**建模決策 5**
（全域單一 `now`），把客戶端時鐘與 Redis 伺服器時鐘**合而為一**。
其 `jumpClock` 動作因此是**空的**——`now' = now + 1 + STALL_BOUND` 永遠可以被
`1 + STALL_BOUND` 次 `advanceTime` 逐步模擬，所以 clockJump 實例的可達狀態集
是 default 的**子集**，不可能產生 default 產生不了的反例。

|                                                | Quint（離散、單一時鐘）            | UPPAAL（連續實數、多時鐘）               |
| :--------------------------------------------- | :--------------------------------- | :--------------------------------------- |
| 時間語意                                       | 離散整數 `now`，`advanceTime` 步進 | 連續 $\mathbb{R}_{\ge 0}$，DBM zone 抽象 |
| 時鐘數量                                       | **1 個全域時鐘**                   | 每節點、每客戶端各自獨立                 |
| 能否表達「節點與客戶端對『現在幾點』看法不同」 | ❌ 表達不出                        | ✅ 這正是它的原生語意                    |

> **但 UPPAAL 也有它的硬限制**，而且這個限制直接決定了本模型怎麼寫——見下一節。

---

## 2. 建模關鍵一：UPPAAL 的 clock **不能被位移**

UPPAAL 的 clock 只能「重設為 0」，**不能被讀進算術式**。把時鐘突跳直覺地寫成

```c
c_node[1] := c_node[1] + JUMP_DELTA   // ✗ 非法
```

會被型別檢查直接擋下（實測）：

```
[error] When using symbolic methods clock cannot be read as double value:
        clock c_node[1] cannot be read as double.
```

這是 DBM（Difference Bound Matrix）zone 抽象的**固有限制**，不是語法糖問題：
zone 只能表達 `x - y ~ c` 形式的約束，任意位移會破壞這個結構。

**正確做法：把位移搬到 guard 的常數側，用整數偏移量表達。**

| 概念                     | 實作                                                                                            |
| :----------------------- | :---------------------------------------------------------------------------------------------- |
| 節點的有效經過時間       | `c_node[i] + node_ofs[i]` → TTL 判斷寫成 `c_node[i] >= DURATION - node_ofs[i]`                  |
| 客戶端**量到**的經過時間 | `c_client[c] - client_skew[c]` → 租約判斷寫成 `c_client[c] < DURATION - DRIFT + client_skew[c]` |

---

## 3. 建模關鍵二：兩種時鐘異常必須分開，否則 F9 與 F8 無法區分

這是本模型最重要的設計決定。

| 對手                   | 方向                 | 效果                               | 這是什麼                                                                            |
| :--------------------- | :------------------- | :--------------------------------- | :---------------------------------------------------------------------------------- |
| `NodeClockAdversary`   | 節點時鐘**往前**跳   | key 比客戶端預期更早過期           | ⚠️ **效果等同 F8**（節點崩潰遺失 key），Quint 已用 `crashAndLoseKey` 證過同一個違反 |
| `ClientClockAdversary` | 客戶端時鐘**往後**跳 | 客戶端**高估**剩餘租約，賴在臨界區 | ✅ **這才是 F9 本體**——不需要任何節點異常                                           |

若只建模前者（早期版本就是如此），得到的反例與 F8 在觀測上**不可區分**，
等於換個觸發器把 F8 重證一次，答不了「F9 是不是獨立的問題」——
而那正是 F9 被單獨列一條的理由。

### 陰性對照是**查詢條件**，不是檔案版本

模型維護兩個計數器 `node_jumps` / `client_jumps`，於是「沒有任何時鐘異常」與
「只有客戶端時鐘異常」都能直接寫進 TCTL 公式：

```tctl
E<> (Client0.InCritical && Client1.InCritical && node_jumps == 0 && client_jumps == 0)  // 應為 NOT satisfied
E<> (Client0.InCritical && Client1.InCritical && node_jumps == 0)                        // 應為 SATISFIED ← F9
```

這比「改 `const bool` 再跑第二次」強：**同一份模型、同一次執行**就同時給出
正例與對照，不可能出現「兩次跑的其實不是同一個模型」。

---

## 4. 檔案清單

| 檔案             | 內容                                                            |
| :--------------- | :-------------------------------------------------------------- |
| `redlock_f9.xml` | 時間自動機模型：3 個 `RedisNode`、2 個 `Client`、2 個時鐘對手。 |
| `redlock_f9.q`   | 7 條 TCTL 查詢（含陰性對照與 F9/F8 分離）。                     |
| `verify.sh`      | **驗證閘門**：逐條解析結果並與預期比對（見 §7 的退出碼陷阱）。  |
| `README.md`      | 本檔。                                                          |

### 模型參數

```c
const int N = 3, M = 2, QUORUM = 2;
const int DURATION = 20;       // 鎖的 TTL（ms）
const int DRIFT = 2;           // 客戶端相信的租約 = DURATION - DRIFT = 18ms
const int MIN_NET_DELAY = 1, MAX_NET_DELAY = 3;
const int MAX_STEP  = 15;      // 單次突跳幅度，於 [1, MAX_STEP] 非確定性選取
const int MAX_JUMPS = 1;       // 每種對手最多發動幾次（狀態空間控制旋鈕）
```

### 對手的泛化程度

早期版本的對手是**手動瞄準**的：只跳 `node 1`、只在 `lock_holder[1] == 0` 時、
幅度固定 15、且只能跳一次（`Ready → Jumped` 無回邊）。那會讓
「無跳躍時互斥成立」這個結論比看起來弱——若反例需要跳別的節點就會被漏掉。

現在兩個對手都是：

- `select n : node_id_t` / `select c : client_id_t` —— 可作用於**任一**節點／客戶端
- `select d : int[1, MAX_STEP]` —— 幅度**非確定性**選取
- 自迴圈 + 計數器 —— 可發動最多 `MAX_JUMPS` 次

> **誠實界線**：`MAX_JUMPS = 1` 是**狀態空間的取捨**，不是理論主張。
> 提高它會擴大搜尋但也會顯著變慢（目前全 7 條查詢約 128 秒）。
> 本模型證明的是「**1 次**時鐘突跳已足以破壞互斥」——這比「需要多次」更強，
> 所以這個上界不削弱結論。

### 節點的授予語意對齊修復後的實作

`RedisNode` 的授予條件是：

```
key 不存在 ── 或 ── key 是自己的（同 value）── 或 ── key 已過期   → 授予
key 是別人的且未過期                                              → 拒絕
```

「key 是自己的也授予」對應**修復後**的 `ACQUIRE_SCRIPT`（F2 已修）。
它同時讓兩條 guard **互補且涵蓋全部情形**，因此節點永遠能回應——
早期版本缺了這一支，客戶端請求自己持有的節點時會兩條 guard 都不成立，
卡死在 `ReqNode` 造成假死鎖。

---

## 5. 驗證結果（實測）

環境：UPPAAL 5.0.0 (rev. 714BA9DB36F49691)，macOS。全部 7 條約 **128 秒**。

|  #  | 查詢                                                        | 預期          | 實測                 |
| :-: | :---------------------------------------------------------- | :------------ | :------------------- |
|  1  | `E<> (both InCritical && node_jumps==0 && client_jumps==0)` | NOT satisfied | ✅ **NOT satisfied** |
|  2  | `E<> (both InCritical && node_jumps==0)` ← **F9 本體**      | satisfied     | ✅ **satisfied**     |
|  3  | `E<> (both InCritical && client_jumps==0)` ← F8 等價變體    | satisfied     | ✅ **satisfied**     |
|  4  | `A[] not (both InCritical)`                                 | NOT satisfied | ✅ **NOT satisfied** |
|  5  | `A[] not deadlock`                                          | satisfied     | ✅ **satisfied**     |
|  6  | `E<> Client0.InCritical`                                    | satisfied     | ✅ **satisfied**     |
|  7  | `E<> Client1.InCritical`                                    | satisfied     | ✅ **satisfied**     |

**查詢 1 與查詢 2 合起來才是結論**：沒有任何時鐘異常時互斥**成立**（1），
而只要客戶端時鐘往後跳、**完全不動任何節點**，互斥就**崩潰**（2）。

查詢 6、7 是反空跑保險：若它們不成立，代表模型根本走不到臨界區，
查詢 1 的「NOT satisfied」就只是「沒走到」而非「安全」。

### 這四條其實是同一條性質的四個切片

`A[] not P` 與 `E<> P` 是**對偶**的（`A[] not P` 成立 ⟺ `E<> P` 不成立）。
因此查詢 1–4 是**互斥性這一條性質在不同環境下的切片**：

|  #  | 等價說法                           | 允許哪種時鐘異常 | 結果               |
| :-: | :--------------------------------- | :--------------- | :----------------- |
|  1  | 互斥性，**限制在無任何異常的狀態** | 無               | **成立**           |
|  2  | 互斥性，**只禁止節點異常**         | 僅客戶端時鐘     | **不成立** ← F9    |
|  3  | 互斥性，**只禁止客戶端異常**       | 僅節點時鐘       | **不成立**（≡ F8） |
|  4  | 互斥性，**完全不限制**             | 全部             | **不成立**         |

**查詢 1 與查詢 4 是同一條性質的兩端**：乾淨環境下成立，開放時鐘突跳後崩潰。
這兩者的落差就是本模型的全部結論。

### ⚠️ 查詢 4 是門面，不是證據——單獨看它會被誤導

**（一）它在邏輯上是多餘的。** 查詢 2 為 `satisfied`（存在一個兩者同時在臨界區
的可達狀態）就已經**蘊含**查詢 4 為 `NOT satisfied`。留著它只是因為
`A[] not (兩者同時在臨界區)` 是大家認得的那條安全性質的標準寫法。

**（二）它不告訴你是哪一種時鐘壞的。** 查詢 4 **沒有任何 `jumps` 限制**，
所以它的「NOT satisfied」只說「互斥會壞」。實測它的最短反例目前**剛好**是
F9 那條：

```text
node_ofs = {0,0,0}   node_jumps = 0   client_skew[0] = 5   client_jumps = 1
```

但那是**搜尋順序的巧合，不是保證**——只要改個參數或多一個動作，讓 F8 那條
路徑變短，查詢 4 就會改給你節點時鐘的軌跡，而讀的人很容易把它當成 F9。

> **這正是本模型前一版踩的坑。** 舊版只有 `E<> (兩者同時在臨界區)` 與
> `A[] not (兩者同時在臨界區)` 兩條**毫無限定**的查詢，因此「找到反例」
> 根本無法區分 F9 與 F8——而它的對手又只跳節點時鐘，實際上是在證 F8。
>
> **判讀 F9 永遠要看帶 `node_jumps == 0` 的那一條（查詢 2），並且必須與
> 查詢 1 配對。** 查詢 4 只能回答「互斥性在這個環境下成不成立」，
> **不能**回答「是什麼破壞了它」。

---

## 6. F9 反例：UPPAAL 實際產生的軌跡

以下是 `verifyta -t1` 對查詢 2 產生的**最短**反例，逐步解碼而來
（不是手寫的示意圖）：

```text
 t(ms)  動作
     0  Client0: Idle → ReqNode          （開始取鎖，c_client[0] 歸零）
     0  ClientAdv 發動：client_skew[0] += 5     ★ 客戶端時鐘往後跳 5ms
     1  Client0 ← Node0  req_grant        （node0 授予，c_node[0] 歸零）
     2  Client0 ← Node1  req_grant
     3  Client0 ← Node2  req_grant        （votes = 3 ≥ quorum 2）
     3  Client0: Evaluate → InCritical     （量到經過 3-5 → 遠小於 18，進入臨界區）

        ── 此後沒有任何節點異常。三把 key 依「真實時間」自然到期 ──
        node0 於 t=21 到期、node1 於 t=22、node2 於 t=23

    20  Client1: Idle → ReqNode
    21  Client1 ← Node0  req_grant        （c_node[0] = 20 ≥ DURATION → 已過期，合法授予）
    22  Client1 ← Node1  req_grant
    23  Client1 ← Node2  req_grant        （votes = 3）
    23  Client1: Evaluate → InCritical     ★ 互斥崩潰

最終狀態：
  ( Client0.InCritical  Client1.InCritical )
  node_ofs   = {0, 0, 0}        ← 完全沒有動過任何節點時鐘
  node_jumps = 0                ← 零節點異常
  client_skew[0] = 5            ← 唯一的擾動：客戶端時鐘往後 5ms
  lock_holder = {1, 1, 1}       ← 三個節點現在都「合法地」屬於 Client1
  c_client[0] = 23              ← 真實已過 23ms，但 Client0 以為只過了 18ms
```

**這條軌跡的殺傷力在於它有多平凡**：

- Client1 的取鎖**完全合法**——它拿到的三把 key 都已依真實時間自然過期。
- 沒有節點崩潰、沒有資料遺失、沒有網路分割、沒有 GC pause。
- 唯一的異常是 Client0 的 `Date.now()` 往後跳了 **5 毫秒**。
- Client0 對此**毫不知情**：它量到的經過時間是 18ms，剛好卡在租約上限。

`driftFactor`（本模型的 `DRIFT`）救不了這件事——它補償的是**速率漂移**，
不是**階躍**。把 `DRIFT` 調大只是把需要的跳躍幅度等量放大而已。

---

## 7. 如何執行

### 建議：用閘門腳本（會檢查結論，不只看它有沒有跑完）

```bash
specs/uppaal/verify.sh
# 或指定路徑
VERIFYTA=/path/to/verifyta specs/uppaal/verify.sh
```

### ⚠️ 退出碼陷阱：`verifyta` 對「NOT satisfied」仍然回傳 0

實測：

```console
$ verifyta model.xml <(echo 'E<> (...unreachable...)')
Formula is NOT satisfied
$ echo $?
0
```

`verifyta` **只有在模型本身有型別／語法錯誤時才回傳非 0**。
「跑得動」與「結論正確」是兩回事，因此閘門**必須逐條解析輸出**並與預期比對——
這與 `quint run --witnesses` 在 0% 時仍 exit 0、`node --test` 的 skip 仍 exit 0
是**同一類陷阱**。`verify.sh` 就是為此存在的。

`verify.sh` 的紅綠對照（實測）：

| 情境                                    | 結果                              |
| :-------------------------------------- | :-------------------------------- |
| 正式模型                                | ✓ 全部 7 條符合預期，退出碼 **0** |
| 把 `MAX_JUMPS` 改為 0（關掉對手）       | ✗ 查詢 2/3/4 不符，退出碼 **1**   |
| 放回非法的 `c_node[n] := c_node[n] + d` | ✗ 報告模型無法驗證，退出碼 **1**  |

### 手動執行

```bash
verifyta specs/uppaal/redlock_f9.xml specs/uppaal/redlock_f9.q   # 全部查詢
verifyta -t1 specs/uppaal/redlock_f9.xml /tmp/one.q              # 產生最短反例軌跡
```

GUI：`File → Open System...` 選 `redlock_f9.xml`，於 Verifier 分頁載入 `.q`，
再切到 Simulator 分頁單步重現反例。

---

## 8. 本模型**不**證明的事（誠實界線）

| 項目                               | 說明                                                                                                         |
| :--------------------------------- | :----------------------------------------------------------------------------------------------------------- |
| **不是 `src/index.ts` 的神諭**     | 本模型驗的是**演算法**在多時鐘環境下的性質，不是 node-redlock 這 770 行的行為。實作層的證據在 `../oracle/`。 |
| **`MAX_JUMPS = 1` 是狀態空間取捨** | 提高上界會擴大搜尋。目前的結論是「1 次突跳已足夠」，不是「多次突跳無新反例」。                               |
| **突跳幅度上界 `MAX_STEP = 15`**   | 相對於 `DURATION = 20` 是同一量級。真實世界的 NTP step 可達數百毫秒至數秒，只會**更容易**觸發。              |
| **未建模續期（`extend`）**         | 客戶端取鎖後不做自動續期。續期會縮短暴露窗口但不消除它——續期本身也用同一個壞掉的時鐘判斷。                   |
| **未建模 fencing token**           | 本模型證明「鎖會重疊」；它**不**評估下游資源用 fencing token 擋下過期寫入的效果。那正是 §9 的建議。          |
| **N=3 / M=2 的規模**               | 與 Quint 模型一致（建模決策 10）。更大規模不改變機制，只增加狀態。                                           |

---

## 9. 工程結論

F9 與 F3／F4／F8 同屬 **Redlock 設計層**的問題，**不是 node-redlock 的實作缺陷**
（實作缺陷是 F1/F2/F5/F6/F7，已修復）。本模型證明它**獨立於**節點故障成立，
因此「把 Redis 持久化調好」或「修函式庫」都堵不住它。

1. **Fencing token**——由儲存層發放單調遞增 token，資源端拒絕小於已見最大值的寫入。
   這是唯一能真正消除重疊危害的方法（Kleppmann 的論點），Redlock 不提供。
2. **NTP 用 slew 不用 step**——禁用 `ntpdate` 之類會造成階躍的工具；
   `chrony`／`ntpd` 設定平滑校時。但這是**運維約定，不是保證**。
3. **安全關鍵場景改用共識鎖**——etcd／ZooKeeper 的 lease + revision，
   其正確性不依賴各節點的本機物理時鐘。
