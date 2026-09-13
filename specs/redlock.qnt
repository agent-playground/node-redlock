// specs/redlock.qnt — node-redlock (src/index.ts) 的 as-is Quint 可執行規格。
//
// 定位：**as-is**，忠實描述現況（含缺陷），不描述「正確的 Redlock 應該如何」。
// 因此：預期會被違反的不變式一律以 `INV_VIOLATED_` 開頭，使 quint 輸出自我說明。
//
// 對應的 9 項疑點（F1–F9）與驗證結果見 specs/README.md。
//
// 建模決策（不得自行變更，見 .factory/work-item-quint-spec.md）：
//   1. as-is          2. INV_VIOLATED_ 命名契約   3. 純 Quint，不用 Choreo
//   4. 邊界含 using()  5. 三層時間               6. F8/F9 為預設 false 的開關
//   7. truly/believes 雙判準                     8. routine 三態
//   9. F6 排除於 Quint 之外                      10. 規模上限 N=3/M=2/K=1
//
// ---------------------------------------------------------------------------
// 一個關鍵的建模取捨（R5/R6：狀態空間預算）
//
// 每次 attempt 對所有節點的 RPC 以**單一動作原子完成**（attemptAcquire /
// attemptExtend / attemptRelease），而不是「每個節點一次動作」。
// 理由：`_attemptOperation` 本來就是一次平行送出所有請求（src/index.ts:485-489
// 的 for 迴圈不 await），逐節點建模只是把**回應的抵達順序**展開，而那個順序
// 不是任何一項發現的成因；卻會讓 Apalache 的狀態空間爆炸（實測逐節點版本
// 8 步就要 64 秒、12 步約 40 分鐘，即原始 factory run 逾時的同一個坑）。
//
// 往返延遲仍然保留：`startAcquire` 與 `completeAcquire` 之間可以插入任意次
// `advanceTime`，這正是 F1/F5「到期時間從過期的 start 算出」的成因。
//
// 競賽造成的**部分搶佔**以 `chosen` 參數建模（非確定性留在 step），
// 因此「兩 client 各搶到一半節點、互相卡死」（F2）仍然可達。
// ---------------------------------------------------------------------------

module redlock {
  // ===========================================================================
  // 型別
  // ===========================================================================

  type NodeId = int
  type ClientId = int
  type Resource = str
  type LockValue = int

  // 節點上單一 key 的內容。expiresAt 是**節點上的真實到期時間**。
  type Entry = { value: LockValue, expiresAt: int }

  // using() 的 routine 生命週期階段。
  type AcquirePhase =
    | IDLE
    | AWAIT_ACQUIRE
    | AFTER_ACQUIRE
    | ISOLATION_CHECK
    | CRITICAL

  // routine 的檢查行為（建模決策 8）。
  //   "UNCHECKED"     —— 完全不檢查 signal.aborted（README 明說的錯用）
  //   "CHECKED"       —— 檢查，且在**進入臨界區的同一步**重新求值（無縫隙）
  //   "CHECKED_LATE"  —— 檢查後凍結結果，隔一步以上才進入臨界區 → F4 的 TOCTOU
  //
  // 註：刻意寫成 `type X = str` 而非 sum type。Quint 0.32.0 有一個工具鏈 bug——
  // **以 variant 實例化 sum type 的 const**（`import m(ROUTINE = CHECKED_LATE)`）會
  // 誤報 `QNT099 Found cyclic declarations`，即使該定義完全沒有遞迴。
  // 最小重現見 specs/README.md「工具鏈限制」。改用 str 常數可完全避開。
  type RoutineKind = str

  type ExtendPhase = | EXTEND_IDLE | AWAIT_EXTEND

  // as-is 的 acquire 結算**沒有** validity <= 0 檢查（src/index.ts:318-329）。
  // 正確的 Redlock 會在此加上 `and start + DURATION - DRIFT > now`。
  // 這個型別存在只是為了讓「缺少的檢查」在規格中具名可見。
  type AcquireKind = | NO_VALIDITY_CHECK

  // 鎖的可觀測狀態。value == 0 表示 client 目前不持有任何鎖（以 sentinel 取代
  // Option 型別：少一層代數資料型別，Apalache 的狀態空間明顯較小）。
  type LockState = {
    resources: Set[Resource],
    value: LockValue,
    // client **相信**的到期時間（Lock.expiration，src/index.ts:152）。
    expiresAt: int,
    // client 的帳：曾對這把鎖投贊成的節點，**只增不減**。
    // 真實歸屬以 nodes 為準，兩者取交集見 permitsOf。
    permits: Set[NodeId],
  }

  type ClientState = {
    routine: RoutineKind,
    acquirePhase: AcquirePhase,
    acquireKind: AcquireKind,
    acquireStart: int,
    // 本次 acquire() 還剩幾次重試（src/index.ts:431-432 的 retryCount 預算）。
    // 歸零時唯一的出口是 failAcquire（補償釋放與「回到 caller」是同一個 await）。
    retriesLeft: int,
    // 本次 attempt 是否已執行過（attempt 為原子動作，只能跑一次）。
    attemptDone: bool,
    // 本次 attempt 實際搶到的節點（= 投贊成的節點 = 寫入 key 的節點）。
    grantedNodes: Set[NodeId],
    lock: LockState,
    // 對應 signal.aborted：**只由 extend 失敗且鎖已失效時設為 true**。
    signalAbort: bool,
    // 是否曾出現「被自己上一輪留下的 key 擋住」（F2 的觀測點，只增不減）。
    selfBlocked: bool,
    // acquire/extend 結算時就「已經過期」的觀測點。
    // 拆成兩個來源，才能分別證明 F1（acquire）與 F5（extend）各自可違反。
    returnedExpired: bool,
    expiredViaAcquire: bool,
    expiredViaExtend: bool,
    // --- using() 的延伸狀態 ---
    extendPhase: ExtendPhase,
    extendStart: int,
    extendDone: bool,
    extendGranted: Set[NodeId],
    // --- release 狀態 ---
    // release 是否正在進行中。沒有這個旗標時，`holdsSomething` 在 AWAIT_ACQUIRE
    // 期間也為真（startAcquire 已寫入 value），會讓 client 在 acquire 途中「釋放」
    // 而刪掉節點上的 key，製造出不存在的反例——真實碼此時 Lock 物件尚未產生。
    releasing: bool,
    releaseDone: bool,
    // 投贊成票的節點數（該節點的所有 key 都被刪掉才算贊成）。
    releaseForCount: int,
    // release() 是否失敗（F7）。
    releaseFailed: bool,
  }

  type State = {
    // 全域單調整數時鐘（建模決策 5）。F9 開啟時由 jumpClock 製造跳躍。
    now: int,
    // 每個節點上每個 resource 的真實內容。
    nodes: NodeId -> (Resource -> Entry),
    clients: ClientId -> ClientState,
  }

  // ===========================================================================
  // 實例參數（const）—— 由 specs/redlockTest.qnt 以具體值實例化
  // ===========================================================================

  const NODES: Set[NodeId]
  const CLIENTS: Set[ClientId]
  // 被鎖定的資源集合（K = 1，見建模決策 10）。
  const RESOURCES: Set[Resource]
  // 要求的鎖持續時間。
  const DURATION: int
  // drift 補償 = Math.round(driftFactor * duration) + 2（src/index.ts:318-321）。
  const DRIFT: int
  // 自動續期的提前量（automaticExtensionThreshold）。
  const EXTENSION_THRESHOLD: int
  // client 可停頓的時間上界（GC pause，建模決策 6 的 ④，**預設開啟**）。
  // 這是 F1 的觸發條件，也是 jumpClock 的跳躍量。
  const STALL_BOUND: int
  // F8：節點崩潰重啟遺失未同步的 key（Kleppmann）。**預設 false**。
  const ENABLE_CRASH_LOSS: bool
  // F9：Date.now() 被 NTP／管理員跳躍。**預設 false**。
  const ENABLE_CLOCK_JUMP: bool
  // 全體 client 的 routine 檢查行為（建模決策 8）。實例化時選擇。
  const ROUTINE: RoutineKind
  // acquire() 的重試預算（src/index.ts:431-432：maxAttempts = retryCount + 1）。
  // 真實預設 retryCount = 10（11 次 attempt）；模型只取 K 次以壓縮狀態空間
  // （jitter/backoff 的時間分佈不影響任何安全性不變式，只保留「可重試」這件事）。
  //
  // **這個 const 的存在是為了保真度**：沒有它，模型無法區分「重試中」與
  // 「預算耗盡、補償釋放後回到 caller」，於是 releaseResidual 只能是一個
  // 自由動作，允許 client 停在 IDLE 且帶著殘留 key —— 那是真實程式碼到不了的
  // 狀態（acquire() 是 await 完補償釋放才 reject，src/index.ts:330-340）。
  const RETRY_BUDGET: int

  // ===========================================================================
  // 狀態變數（Step 2）—— 三個獨立關注點，刻意不塞進單一 State 記錄
  // ===========================================================================

  // 全域單調時鐘。
  var now: int
  // 每個節點上每個 resource 的真實內容（Redis 端）。
  var nodes: NodeId -> (Resource -> Entry)
  // 每個 client 的本地狀態（client 記憶體端）。
  var clients: ClientId -> ClientState

  // ===========================================================================
  // 純函數層（Step 3）—— 守衛與狀態更新分離
  // ===========================================================================

  pure def quorumSize: int = NODES.size() / 2 + 1

  pure def mkState(nw: int, nd: NodeId -> (Resource -> Entry), cl: ClientId -> ClientState): State =
    { now: nw, nodes: nd, clients: cl }

  pure def emptyEntry: Entry = { value: 0, expiresAt: 0 }

  pure def emptyLock: LockState =
    { resources: RESOURCES, value: 0, expiresAt: 0, permits: Set() }

  pure def valOf(cs: ClientState): LockValue = cs.lock.value

  pure def holdsSomething(cs: ClientState): bool = cs.lock.value != 0

  // 真實碼的 expire 語意：SET key value PX ttl 把到期時間設為 now + ttl。
  pure def withExpiry(e: Entry, nw: int, ttl: int): Entry =
    { value: e.value, expiresAt: nw + ttl }

  pure def keyExists(e: Entry, nw: int): bool = e.expiresAt > nw

  // _attemptOperation 的投票判定：只數**贊成票數**是否達 quorum
  // （src/index.ts:515）。**不看**反對票數，也不要求全數到齊。
  pure def hasQuorum(forCount: int): bool = forCount >= quorumSize

  // 「該節點目前是否持有 client 的這把鎖」——**以 nodes 為準**。
  pure def nodeHolds(s: State, n: NodeId, c: ClientId): bool =
    val lock = s.clients.get(c).lock
    lock.value != 0 and
    RESOURCES.forall(r =>
      val e = s.nodes.get(n).get(r)
      keyExists(e, s.now) and e.value == lock.value
    )

  // client 相信仍持有的節點（lock.permits）再以真實狀態過濾。
  // F3 的核心：permits 只增不減，但 nodes 會隨到期而失去 key，
  // 因此這個交集可以單調衰減到低於 quorum，而 client 的帳上覆蓋率仍看似完好。
  pure def permitsOf(s: State, c: ClientId): Set[NodeId] =
    s.clients.get(c).lock.permits.filter(n => nodeHolds(s, n, c))

  // trulyHolds(c)：至少 quorum 個節點上該 key 值 = c.value 且未到期。
  pure def trulyHolds(s: State, c: ClientId): bool =
    permitsOf(s, c).size() >= quorumSize

  // believesHolds(c)：c.lock.expiration > now（建模決策 7）。
  pure def believesHolds(s: State, c: ClientId): bool =
    s.clients.get(c).lock.value != 0 and s.clients.get(c).lock.expiresAt > s.now

  pure def isCritical(s: State, c: ClientId): bool =
    s.clients.get(c).acquirePhase == CRITICAL

  pure def criticalCount(s: State): int =
    CLIENTS.fold(0, (acc, c) => acc + (if (isCritical(s, c)) 1 else 0))

  // F8（Kleppmann）：同時**相信自己**持有鎖的 client 數。
  // 這與 trulyHolds 的差別就是整份規格的主題——使用者在乎的是有幾個 client
  // 自認可以進臨界區，而不是 Redis 上實際有幾把鎖。
  pure def believerCount(s: State): int =
    CLIENTS.fold(0, (acc, c) => acc + (if (believesHolds(s, c)) 1 else 0))

  pure def isSilentlyUnderQuorum(s: State, c: ClientId): bool =
    believesHolds(s, c) and permitsOf(s, c).size() < quorumSize

  // --- acquire 的節點端語意（ACQUIRE_SCRIPT，src/index.ts:12-27）-------------

  // F2：exists 只問存在、不問是誰的——因此**自己**上一輪留下的 key 也會擋住自己。
  pure def acquireBlockedBy(s: State, c: ClientId, n: NodeId): Set[Resource] =
    RESOURCES.filter(r => keyExists(s.nodes.get(n).get(r), s.now))

  pure def acquireOk(s: State, c: ClientId, n: NodeId): bool =
    acquireBlockedBy(s, c, n).size() == 0

  pure def acquireSelfBlockNodes(s: State, c: ClientId): Set[NodeId] =
    val v = valOf(s.clients.get(c))
    NODES.filter(n =>
      v != 0 and
      acquireBlockedBy(s, c, n).exists(r => s.nodes.get(n).get(r).value == v)
    )

  // --- extend 的節點端語意（EXTEND_SCRIPT，src/index.ts:29-44）---------------

  // 所有 key 的 value 都相符才回傳 #KEYS；任一不符即整顆腳本在該節點投反對，
  // 且**不對該節點做任何修復**——這是 F3。
  pure def extendOk(s: State, c: ClientId, n: NodeId): bool =
    val v = valOf(s.clients.get(c))
    v != 0 and
    RESOURCES.forall(r =>
      val e = s.nodes.get(n).get(r)
      keyExists(e, s.now) and e.value == v
    )

  pure def extendGrantedNodes(s: State, c: ClientId): Set[NodeId] =
    NODES.filter(n => extendOk(s, c, n))

  // --- release 的節點端語意（RELEASE_SCRIPT，src/index.ts:46-58）-------------

  // 只刪除 value 相符的 key——**不會誤刪別人的鎖**。
  pure def releaseMine(s: State, c: ClientId, n: NodeId): Set[Resource] =
    val v = valOf(s.clients.get(c))
    RESOURCES.filter(r =>
      val e = s.nodes.get(n).get(r)
      keyExists(e, s.now) and e.value == v
    )

  // 該節點是否投贊成票：`_attemptOperationOnClient` 只在
  // `result === keys.length` 時投贊成（src/index.ts:598-602）。
  pure def releaseVotesFor(s: State, c: ClientId, n: NodeId): bool =
    releaseMine(s, c, n).size() == RESOURCES.size()

  // --- 守衛與結算用的純函數 --------------------------------------------------

  // acquire() 算出的 client 端到期時間（src/index.ts:318-321）。
  pure def acquireBelieved(cs: ClientState): int =
    cs.acquireStart + DURATION - DRIFT

  // extend() 算出的 client 端到期時間（src/index.ts:395-398）。
  pure def extendBelieved(cs: ClientState): int =
    cs.extendStart + DURATION - DRIFT

  // using() 的 extend() 失敗後用來決定「重試或 abort」的判準（src/index.ts:734）。
  pure def stillValidAt(cs: ClientState, nw: int): bool =
    cs.lock.value != 0 and cs.lock.expiresAt > nw

  // 是否可以開始自動續期：using() 的 queue() 在到期前 EXTENSION_THRESHOLD 觸發
  // （src/index.ts:716-721）。
  pure def canStartExtend(s: State, c: ClientId): bool =
    val cs = s.clients.get(c)
    cs.extendPhase == EXTEND_IDLE and not(cs.releasing) and
    cs.acquirePhase == AFTER_ACQUIRE and
    cs.lock.value != 0 and
    cs.lock.expiresAt > s.now and cs.lock.expiresAt - s.now <= EXTENSION_THRESHOLD

  // 進入臨界區的門檻依 routine 型態不同：
  //   "UNCHECKED"     —— 只要能到 AFTER_ACQUIRE 就進
  //   "CHECKED"       —— **同一步**重新求值 believesHolds（無 TOCTOU 縫隙）
  //   "CHECKED_LATE"  —— 用 doIsolationCheck 凍結的舊結果（有縫隙）
  pure def canEnterCritical(s: State, c: ClientId): bool =
    val cs = s.clients.get(c)
    if (cs.routine == "UNCHECKED")
      cs.acquirePhase == AFTER_ACQUIRE
    else if (cs.routine == "CHECKED")
      cs.acquirePhase == ISOLATION_CHECK and believesHolds(s, c)
    else
      cs.acquirePhase == ISOLATION_CHECK and not(cs.signalAbort)

  // 是否可以開始 release：using() 的 finally 只在 routine 結束後執行。
  pure def canStartRelease(cs: ClientState): bool =
    (cs.acquirePhase == AFTER_ACQUIRE or cs.acquirePhase == CRITICAL) and
    holdsSomething(cs) and not(cs.releasing) and
    cs.extendPhase == EXTEND_IDLE

  // ===========================================================================
  // 初始化與狀態機（Step 4）
  // ===========================================================================

  action init: bool = all {
    now' = 0,
    nodes' = NODES.mapBy(n => RESOURCES.mapBy(r => emptyEntry)),
    clients' = CLIENTS.mapBy(c => {
      routine: ROUTINE,
      acquirePhase: IDLE,
      acquireKind: NO_VALIDITY_CHECK,
      acquireStart: 0,
      retriesLeft: 0,
      attemptDone: false,
      grantedNodes: Set(),
      lock: emptyLock,
      signalAbort: false,
      selfBlocked: false,
      returnedExpired: false,
      expiredViaAcquire: false,
      expiredViaExtend: false,
      extendPhase: EXTEND_IDLE,
      extendStart: 0,
      extendDone: false,
      extendGranted: Set(),
      releasing: false,
      releaseDone: false,
      releaseForCount: 0,
      releaseFailed: false,
    }),
  }

  // 時間前進。所有到期語意都由 now 與各 expiresAt 的比較導出。
  action advanceTime: bool = all {
    now' = now + 1,
    nodes' = nodes,
    clients' = clients,
  }

  // F9：時鐘跳躍（**預設關閉**）。Date.now() 非單調；
  // driftFactor=0.01 只補償速率漂移，不處理跳躍。
  action jumpClock: bool = all {
    ENABLE_CLOCK_JUMP,
    now' = now + 1 + STALL_BOUND,
    nodes' = nodes,
    clients' = clients,
  }

  // F8：某節點崩潰重啟、遺失尚未同步的 key（**預設關閉**）。
  // Kleppmann 場景：該節點的 key 直接消失，其他節點不受影響。
  action crashAndLoseKey(n: NodeId): bool = all {
    ENABLE_CRASH_LOSS,
    nodes' = nodes.set(n, RESOURCES.mapBy(r => emptyEntry)),
    now' = now,
    clients' = clients,
  }

  // --- acquire（F1 / F2）-----------------------------------------------------

  // 送出 acquire 請求（`_attemptOperation` 的起點）。
  //
  // **不修改 nodes**——真實的 SET 發生在節點端（attemptAcquire），
  // client 停頓造成的往返延遲（F1）才有位置可放。
  //
  // value 的產生對應 src/index.ts:306：**一次 acquire() 呼叫只產生一次**，
  // 其後的 retry 全部重用。這正是 F2 自我阻塞的成因（retryAcquire 保留 value）。
  action startAcquire(c: ClientId): bool = all {
    clients.get(c).acquirePhase == IDLE,
    clients' = clients.set(c, {
      ...clients.get(c),
      acquirePhase: AWAIT_ACQUIRE,
      acquireStart: now,
      attemptDone: false,
      grantedNodes: Set(),
      retriesLeft: RETRY_BUDGET,
      // IDLE 保證手上沒有任何殘留 key（唯一回到 IDLE 的 acquire 路徑是
      // failAcquire，它會原子地補償釋放），所以每次 acquire() 都產生新 value。
      // 一次呼叫之內的重試由 retryAcquire 保留同一個 value（F2 的機制）。
      lock: { ...emptyLock, value: c * 100 + now },
      signalAbort: false,
      releasing: false,
      releaseDone: false,
      releaseForCount: 0,
      releaseFailed: false,
    }),
    now' = now,
    nodes' = nodes,
  }

  // 節點端執行 `ACQUIRE_SCRIPT`——一次 attempt 對所有節點的 RPC 原子完成
  // （見檔頭的建模取捨）。
  //
  // `chosen` 代表**競賽的結果**：兩個 client 同時搶時，各自只會拿到一部分節點。
  // 沒有這個非確定性就無法產生「各搶一半、互相卡死」（F2）的情境。
  //
  // `chosen` 是**動作參數**而非內部的 `nondet`：非確定性留在 `step`
  // （`NODES.powerset().oneOf()`），但測試可以直接指定子集，
  // 用決定性的 `run` 測試證明 F2(b) 可達——該狀態在隨機走訪下機率只有
  // 約 0.0015%（實測 6/400000），不適合當作 CI 的 witness 斷言。
  action attemptAcquire(c: ClientId, chosen: Set[NodeId]): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    not(clients.get(c).attemptDone),
    chosen.subseteq(NODES),
    // 只有當時空閒的節點可能被搶到
    chosen.forall(n => acquireOk(mkState(now, nodes, clients), c, n)),
    clients' = clients.set(c, {
      ...clients.get(c),
      attemptDone: true,
      grantedNodes: chosen,
      // F2：被自己上一輪留下的 key 擋住
      selfBlocked: clients.get(c).selfBlocked or
        acquireSelfBlockNodes(mkState(now, nodes, clients), c).size() > 0,
    }),
    nodes' = chosen.fold(nodes, (acc, n) =>
      acc.set(n, RESOURCES.mapBy(r => {
        value: valOf(clients.get(c)),
        expiresAt: now + DURATION,
      }))
    ),
    now' = now,
  }

  // 結算 acquire：`_execute` 的 quorum 判定 ＋ `acquire()` 建構 Lock。
  //
  // **F1 就在這裡**：expiresAt = acquireStart + DURATION - DRIFT，而程式碼
  // 從不比對它與 Date.now()。若往返期間 client 停頓使該值 <= now，
  // 呼叫端就拿到一把「已過期卻無錯誤」的鎖（src/index.ts:318-329）。
  // returnedExpired 就是「缺少的檢查」的精確觀測點。
  action completeAcquire(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    clients.get(c).attemptDone,
    hasQuorum(clients.get(c).grantedNodes.size()),
    clients' = clients.set(c, {
      ...clients.get(c),
      acquirePhase: AFTER_ACQUIRE,
      lock: {
        resources: RESOURCES,
        value: valOf(clients.get(c)),
        expiresAt: acquireBelieved(clients.get(c)),
        permits: clients.get(c).grantedNodes,
      },
      // 正確的實作會在此拒絕並解鎖；as-is 直接回傳（src/index.ts:323-329）。
      // F1：來源是 acquire 結算。
      expiredViaAcquire: clients.get(c).expiredViaAcquire or
        acquireBelieved(clients.get(c)) <= now,
      returnedExpired: clients.get(c).returnedExpired or
        acquireBelieved(clients.get(c)) <= now,
    }),
    now' = now,
    nodes' = nodes,
  }

  // 本次 attempt 未達 quorum → retry 迴圈再跑一輪（src/index.ts:436-470）。
  // **保留 lock.value 與節點上的殘留 key**：真實碼的 value 在一次 acquire() 內
  // 固定不變，這正是 F2 自我阻塞的機制來源。
  action retryAcquire(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    clients.get(c).attemptDone,
    not(hasQuorum(clients.get(c).grantedNodes.size())),
    clients.get(c).retriesLeft > 0,
    // **留在 AWAIT_ACQUIRE**：真實的 retry 是 `_execute` 的 while 迴圈
    // （src/index.ts:436-470），client 仍在 acquire() 之內，沒有回到 caller。
    // 保留 lock.value 與節點上的殘留 key —— 這正是 F2 自我阻塞的機制來源。
    clients' = clients.set(c, {
      ...clients.get(c),
      attemptDone: false,
      grantedNodes: Set(),
      retriesLeft: clients.get(c).retriesLeft - 1,
    }),
    now' = now,
    nodes' = nodes,
  }

  // acquire() 的重試預算耗盡 → 補償釋放**之後**才回到 caller
  // （src/index.ts:330-340：`await this._execute(releaseScript, ..., {retryCount: 0})`
  // 完成後才 `throw error`）。
  //
  // **這個動作取代了原本自由的 `releaseResidual`**：真實程式碼沒有「放棄但不清理」
  // 這個選項——補償釋放與「回到 IDLE」是同一個 await 的兩半。寫成同一個動作，
  // 模型才不會允許「IDLE + 殘留 key」這個真實到不了的狀態。
  action failAcquire(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    clients.get(c).attemptDone,
    not(hasQuorum(clients.get(c).grantedNodes.size())),
    clients.get(c).retriesLeft == 0,
    nodes' = NODES.fold(nodes, (acc, n) =>
      acc.set(n, RESOURCES.mapBy(r =>
        if (releaseMine(mkState(now, nodes, clients), c, n).contains(r))
          emptyEntry
        else
          nodes.get(n).get(r)
      ))
    ),
    clients' = clients.set(c, {
      ...clients.get(c),
      acquirePhase: IDLE,
      attemptDone: false,
      grantedNodes: Set(),
      lock: emptyLock,
    }),
    now' = now,
  }

  // --- routine 三態與 abort（F4）--------------------------------------------

  // 執行 `if (signal.aborted)` 檢查（src/index.ts:748-749）。
  //
  // "CHECKED" 的檢查結果不在此凍結——canEnterCritical 會在同一步重新求值，
  // 因此沒有縫隙。"CHECKED_LATE" 則把結果凍結在此（signalAbort），
  // 之後任何 advanceTime 都會讓它變 stale → F4 的 TOCTOU。
  action doIsolationCheck(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AFTER_ACQUIRE,
    clients.get(c).routine != "UNCHECKED",
    clients' = clients.set(c, {
      ...clients.get(c),
      acquirePhase: ISOLATION_CHECK,
      signalAbort: not(believesHolds(mkState(now, nodes, clients), c)),
    }),
    now' = now,
    nodes' = nodes,
  }

  // 進入臨界區。
  action enterCritical(c: ClientId): bool = all {
    canEnterCritical(mkState(now, nodes, clients), c),
    clients' = clients.set(c, { ...clients.get(c), acquirePhase: CRITICAL }),
    now' = now,
    nodes' = nodes,
  }

  // 臨界區內的工作。**不重新驗證鎖**——這是 routine 的責任（README:65-78）。
  // 這一步讓時間前進，因此鎖可以在臨界區執行**途中**失效；
  // 而 abort 是諮詢式的，client 不會被強制退出臨界區。
  action criticalWork(c: ClientId): bool = all {
    clients.get(c).acquirePhase == CRITICAL,
    now' = now + 1,
    nodes' = nodes,
    clients' = clients,
  }

  action exitCritical(c: ClientId): bool = all {
    clients.get(c).acquirePhase == CRITICAL,
    clients' = clients.set(c, { ...clients.get(c), acquirePhase: AFTER_ACQUIRE }),
    now' = now,
    nodes' = nodes,
  }

  // --- extend（F3 / F5）------------------------------------------------------

  action startExtend(c: ClientId): bool = all {
    canStartExtend(mkState(now, nodes, clients), c),
    clients' = clients.set(c, {
      ...clients.get(c),
      extendPhase: AWAIT_EXTEND,
      extendStart: now,
      extendDone: false,
      extendGranted: Set(),
    }),
    now' = now,
    nodes' = nodes,
  }

  // 節點端執行 `EXTEND_SCRIPT`——一次 attempt 原子完成（見檔頭的建模取捨）。
  // 所有 key 的 value 都相符才在該節點投贊成，且**不對該節點做任何修復**（F3）。
  action attemptExtend(c: ClientId): bool = all {
    clients.get(c).extendPhase == AWAIT_EXTEND,
    not(clients.get(c).extendDone),
    clients' = clients.set(c, {
      ...clients.get(c),
      extendDone: true,
      extendGranted: extendGrantedNodes(mkState(now, nodes, clients), c),
    }),
    // 只有投贊成的節點其 TTL 被更新；已遺失的節點不會被補回
    nodes' = extendGrantedNodes(mkState(now, nodes, clients), c).fold(nodes, (acc, n) =>
      acc.set(n, RESOURCES.mapBy(r => withExpiry(nodes.get(n).get(r), now, DURATION)))
    ),
    now' = now,
  }

  // 結算 extend。**F3 的關鍵**：`_execute` 只要 quorum 為 for 就算成功
  // （src/index.ts:515-521），因此少數節點上已遺失的 key **永遠不會被補回**。
  // permits 只 += 本次投 for 的節點（只增不減），真實覆蓋率要等 permitsOf 才揭曉。
  //
  // F5：與 acquire 一樣**沒有** validity <= 0 檢查（src/index.ts:400-406）。
  action completeExtend(c: ClientId): bool = all {
    clients.get(c).extendPhase == AWAIT_EXTEND,
    clients.get(c).extendDone,
    hasQuorum(clients.get(c).extendGranted.size()),
    clients' = clients.set(c, {
      ...clients.get(c),
      extendPhase: EXTEND_IDLE,
      lock: {
        ...clients.get(c).lock,
        expiresAt: extendBelieved(clients.get(c)),
        permits: clients.get(c).lock.permits.union(clients.get(c).extendGranted),
      },
      // F5：來源是 extend 結算（replacement Lock 同樣缺 validity 檢查）。
      expiredViaExtend: clients.get(c).expiredViaExtend or
        extendBelieved(clients.get(c)) <= now,
      returnedExpired: clients.get(c).returnedExpired or
        extendBelieved(clients.get(c)) <= now,
    }),
    now' = now,
    nodes' = nodes,
  }

  // extend 未達 quorum。using() 的 extend() 檢查
  // lock.expiration > Date.now()（src/index.ts:734）後決定重試或 abort（L735-739）。
  action failExtend(c: ClientId): bool = all {
    clients.get(c).extendPhase == AWAIT_EXTEND,
    clients.get(c).extendDone,
    not(hasQuorum(clients.get(c).extendGranted.size())),
    clients' = clients.set(c, {
      ...clients.get(c),
      extendPhase: EXTEND_IDLE,
      signalAbort: if (stillValidAt(clients.get(c), now))
        clients.get(c).signalAbort
      else
        true,
    }),
    now' = now,
    nodes' = nodes,
  }

  // --- release（F7）----------------------------------------------------------

  // release()：先 lock.expiration = 0（src/index.ts:355）再執行 `RELEASE_SCRIPT`。
  // 這一步是 fail-safe 的（讓 client 不再相信自己持有）。
  action startRelease(c: ClientId): bool = all {
    canStartRelease(clients.get(c)),
    clients' = clients.set(c, {
      ...clients.get(c),
      releasing: true,
      releaseDone: false,
      releaseForCount: 0,
      lock: { ...clients.get(c).lock, expiresAt: 0 },
    }),
    now' = now,
    nodes' = nodes,
  }

  // `RELEASE_SCRIPT`：只刪除 value 相符的 key（**不會誤刪別人的鎖**）。
  action attemptRelease(c: ClientId): bool = all {
    clients.get(c).releasing,
    not(clients.get(c).releaseDone),
    clients' = clients.set(c, {
      ...clients.get(c),
      releaseDone: true,
      releaseForCount: NODES.fold(0, (acc, n) =>
        acc + (if (releaseVotesFor(mkState(now, nodes, clients), c, n)) 1 else 0)
      ),
    }),
    nodes' = NODES.fold(nodes, (acc, n) =>
      acc.set(n, RESOURCES.mapBy(r =>
        if (releaseMine(mkState(now, nodes, clients), c, n).contains(r))
          emptyEntry
        else
          nodes.get(n).get(r)
      ))
    ),
    now' = now,
  }

  // 結算 release。投贊成的節點數 < quorum 即視為失敗。
  //
  // F7：失敗的 release 會從 using() 的 finally 拋出
  // （src/index.ts:354-363 + 767），吃掉 routine 的正常回傳值與 signal.error。
  action completeRelease(c: ClientId): bool = all {
    clients.get(c).releasing,
    clients.get(c).releaseDone,
    clients' = clients.set(c, {
      ...clients.get(c),
      releaseFailed: not(hasQuorum(clients.get(c).releaseForCount)),
      lock: emptyLock,
      releasing: false,
    }),
    now' = now,
    nodes' = nodes,
  }

  // --- step -----------------------------------------------------------------

  action step: bool = {
    nondet c = CLIENTS.oneOf()
    nondet n = NODES.oneOf()
    nondet chosen = NODES.powerset().oneOf()
    any {
      advanceTime,
      jumpClock,
      crashAndLoseKey(n),
      startAcquire(c),
      attemptAcquire(c, chosen),
      completeAcquire(c),
      retryAcquire(c),
      failAcquire(c),
      doIsolationCheck(c),
      enterCritical(c),
      criticalWork(c),
      exitCritical(c),
      startExtend(c),
      attemptExtend(c),
      completeExtend(c),
      failExtend(c),
      startRelease(c),
      attemptRelease(c),
      completeRelease(c),
    }
  }

  // ===========================================================================
  // 性質（Step 5）—— 不變式
  // ===========================================================================

  // **R1：structural sanity check，不承載安全性結論。**
  // 兩個 quorum 必有交集節點，而單一節點只存一個 value → 由鴿籠原理保證。
  // 它能抓的是**建模錯誤**（quorum 計數寫成 size/2、nodeHolds 到期判斷寫反），
  // 與 F1/F3/F4 是否修好無關。
  // 安全性結論由 INV_VIOLATED_concurrentCriticalSections 承載。
  val mutualExclusionOnNodes: bool =
    val s = mkState(now, nodes, clients)
    CLIENTS.forall(c1 => CLIENTS.forall(c2 =>
      c1 == c2 or not(trulyHolds(s, c1) and trulyHolds(s, c2))
    ))

  // **F1 / F5**：acquire() 或 extend() 在結算時，算出的 expiration 已經過去了，
  // 而程式碼**沒有任何檢查**就把它回傳給呼叫端。
  // 這是 catalog-info.yaml 所述「鎖已過期後仍被認為持有」的上游。
  val INV_VIOLATED_returnsExpiredLock: bool =
    CLIENTS.forall(c => not(clients.get(c).returnedExpired))

  // **F3**：client 相信持有有效鎖，但真實覆蓋率已跌破 quorum（靜默失去 quorum）。
  //
  // 注意：在**預設情境**（F8/F9 關閉）下此條不可違反——因為 client 相信的到期
  // 時間（start + DURATION - DRIFT）永遠早於節點端 key 的實際到期時間
  // （setTime + DURATION >= start + DURATION），所以「相信」會先失效。
  // 它需要**非對稱的節點失效**才會成立，見 redlockCrashLoss 實例。
  val INV_VIOLATED_quorumCoverageDecay: bool =
    val s = mkState(now, nodes, clients)
    CLIENTS.forall(c => not(isSilentlyUnderQuorum(s, c)))

  // **F1 專屬**：來源限縮在 acquire 結算，證明「回傳已過期的鎖」不需靠 extend 路徑。
  val INV_VIOLATED_acquireReturnsExpiredLock: bool =
    CLIENTS.forall(c => not(clients.get(c).expiredViaAcquire))

  // **F5 專屬**：來源限縮在 extend 結算（replacement Lock）。
  // 這條與 F1 分開，才能回答「extend() 的 check-then-act 是否獨立成立」。
  val INV_VIOLATED_extendReturnsExpiredLock: bool =
    CLIENTS.forall(c => not(clients.get(c).expiredViaExtend))

  // **F8（Kleppmann）**：不存在兩個 client **同時相信自己持有鎖**。
  // 節點崩潰重啟遺失未同步的 key 後，另一個 client 可以取得 quorum，
  // 而前者仍在自己相信的有效期內——這是最經典的「同時兩人自認持鎖」。
  // 注意：此條在 ENABLE_CRASH_LOSS=false 的預設情境下不應被違反。
  val INV_VIOLATED_twoClientsBelieveLock: bool =
    believerCount(mkState(now, nodes, clients)) <= 1

  // **F4 —— 承載安全性結論的那一條。**
  // 不存在兩個 client 同時在臨界區。這才是使用者在乎的事：
  // 不是 Redis 上是否真有兩把鎖，而是**兩段程式碼有沒有同時跑**。
  val INV_VIOLATED_concurrentCriticalSections: bool =
    criticalCount(mkState(now, nodes, clients)) <= 1

  // **F7**：release 失敗吃掉了已發生的 abort 錯誤
  // （routine 想回報的問題被 release 的例外覆蓋）。
  val INV_VIOLATED_releaseErrorMasksAbort: bool =
    CLIENTS.forall(c =>
      not(clients.get(c).releaseFailed and clients.get(c).signalAbort)
    )

  // ===========================================================================
  // 性質（Step 5）—— 正向 witness（要求 trace 數 > 0）
  // ===========================================================================

  // **F2(a)**：某 client 曾被**自己上一輪 attempt 留下的 key** 擋住。
  val selfBlockedByOwnValue: bool =
    CLIENTS.exists(c => clients.get(c).selfBlocked)

  // **F2(b)**：兩個 client 都曾被自己的殘留 key 擋住，且兩人都**仍在同一次
  // acquire() 的重試迴圈內**（AWAIT_ACQUIRE、本次 attempt 已完成、未達 quorum）
  // ——即雙方在重試窗口內互相卡死。
  //
  // ⚠️ 保真度修正：舊版把這個述詞寫成「兩人都已退回 IDLE 且仍帶著殘留 value」。
  // 那是**真實到不了的狀態**——acquire() 的補償釋放與「回到 caller」是同一個
  // await 的兩半（src/index.ts:330-340），所以 IDLE 必然代表手上沒有殘留 key。
  // 危害確實存在，但它的位置是**重試窗口之內**，不是窗口之外。
  //
  // ⚠️ 此狀態在隨機走訪下機率約 0.0015%，**不應**作為 CI 的百分比斷言。
  // 可達性由 redlockTest.qnt 的 redlockF2Scenario::bothClientsStarveTest
  // 以決定性腳本證明。
  val bothClientsFailWithinRetryWindow: bool =
    CLIENTS.size() == 2 and
    CLIENTS.forall(c =>
      clients.get(c).selfBlocked and
      clients.get(c).acquirePhase == AWAIT_ACQUIRE and
      clients.get(c).attemptDone and
      not(hasQuorum(clients.get(c).grantedNodes.size()))
    )
}
