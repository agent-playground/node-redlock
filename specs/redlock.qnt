// specs/redlock.qnt — node-redlock (src/index.ts) 的 **as-fixed** Quint 可執行規格。
//
// 定位：**as-fixed**，忠實描述**修復後**的 src/index.ts（F1/F5/F2/F6/F7 已修）。
// 修復前的 as-is 版本見 git 歷史（`git show 691c0e3:specs/redlock.qnt`），
// 其反例軌跡保留在 specs/traces/ 作為歷史證據。
//
// 命名契約仍然成立：預期**會**被違反的不變式以 `INV_VIOLATED_` 開頭。
// 修復後轉為成立的那幾條**已改名去掉前綴**，讓 quint 的輸出自我說明。
//
// ---------------------------------------------------------------------------
// 反空跑契約（as-fixed 版本最重要的一件事）
//
// 「不變式成立」有兩種可能：(a) 實作真的正確；(b) 模型根本到不了危險狀態。
// 後者是假綠燈。因此每一條**因修復而成立**的不變式，都必須配一個
// **witness 證明它守的那個危險狀態確實可達**：
//
//   acquireNeverReturnsExpiredLock  ⟵ witness acquireExpiryDetectable
//   extendNeverReturnsExpiredLock   ⟵ witness extendExpiryDetectable
//   neverSelfBlocked                ⟵ witness retryFacesOwnResidualKey
//   abortReasonNeverMasked          ⟵ witness releaseFailedWhileAborted
//
// 缺了 witness，那幾條不變式就只是「模型沒走到那裡」的同義反覆。
// ---------------------------------------------------------------------------
//
// 對應的 9 項疑點（F1–F9）與驗證結果見 specs/README.md。
//
// 建模決策（不得自行變更，見 .factory/work-item-quint-spec.md）：
//   1. as-fixed（本次由 as-is 轉換）            2. INV_VIOLATED_ 命名契約
//   3. 純 Quint，不用 Choreo
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

  // 修復後的 acquire 結算**有** validity 檢查：
  // `if (Date.now() >= start + duration - drift) throw ExecutionError`（src/index.ts）。
  // 這個型別讓「檢查存在」在規格中具名可見（as-is 版本此處是 NO_VALIDITY_CHECK）。
  type AcquireKind = | VALIDITY_CHECKED

  // using() 最終向呼叫端回報什麼（修復後的優先序，src/index.ts 結尾）：
  //   1. routine 拋錯        → 原樣拋出（本模型的 routine 不拋錯，故未建模）
  //   2. signal.aborted      → 拋 signal.error      ← SIGNAL_ERROR
  //   3. release 失敗        → 拋 release 的錯       ← RELEASE_ERROR
  //   4. 否則                → 回傳 routine 的結果   ← RESULT
  //
  // **F7 的修復就在這個優先序裡**：abort 的原因排在 release 的錯誤之前，
  // 因此不再被它遮蔽。沒有這個欄位，模型就無法區分「兩件事同時發生」
  // （修復前後都會發生）與「哪一件被回報」（修復真正改變的東西）。
  type UsingOutcome =
    | NOT_FINISHED
    | RESULT
    | SIGNAL_ERROR
    | RELEASE_ERROR

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
    // **修復後恆為 false**——由 neverSelfBlocked 檢查，其非空跑性由
    // witness retryFacesOwnResidualKey 保證。
    selfBlocked: bool,
    // **曾把一把「結算當下就已過期」的鎖交給呼叫端**（F1 / F5 的精確觀測點）。
    //
    // 修復後 completeAcquire / completeExtend 的 guard 已排除這種情形，因此本旗標
    // 恆為 false——這正是 neverHandsOutExpiredLock 要斷言的事。它是**回歸防線**：
    // 若日後有人拿掉那兩個 guard，這條不變式立刻會被違反。
    //
    // ⚠️ 注意「結算當下」：鎖在 AFTER_ACQUIRE 期間**自然到期**是正常行為，
    // 不是缺陷，所以不能寫成「任何時刻 expiresAt 都 > now」那種過強的述詞。
    handedExpiredLock: bool,
    // using() 最終回報了什麼（F7）。
    reported: UsingOutcome,
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

  // --- acquire 的節點端語意（ACQUIRE_SCRIPT，src/index.ts:12-29）-------------

  // **F2 的修復就在這裡。**
  //   修復前：`if exists(key) then return 0`——只問存在、不問是誰的，
  //           因此自己上一輪留下的 key 也會擋住自己。
  //   修復後：`if exists(key) and get(key) ~= ARGV[1] then return 0`——
  //           只有**別人的** key 才構成阻擋；自己的 key 放行並覆寫 TTL。
  //           等價於演算法要求的「重試前先把自己的殘留清乾淨」。
  pure def acquireBlockedBy(s: State, c: ClientId, n: NodeId): Set[Resource] =
    val v = valOf(s.clients.get(c))
    RESOURCES.filter(r =>
      val e = s.nodes.get(n).get(r)
      keyExists(e, s.now) and e.value != v
    )

  pure def acquireOk(s: State, c: ClientId, n: NodeId): bool =
    acquireBlockedBy(s, c, n).size() == 0

  // 「擋住我的 key 帶著我自己的 value」——修復後 acquireBlockedBy 已把同 value
  // 濾掉，所以這個集合**由建構恆為空**。保留它是為了讓「不再自我阻塞」成為一條
  // 可檢查的不變式，而不是把觀測點直接刪掉（刪掉就無從驗證）。
  pure def acquireSelfBlockNodes(s: State, c: ClientId): Set[NodeId] =
    val v = valOf(s.clients.get(c))
    NODES.filter(n =>
      v != 0 and
      acquireBlockedBy(s, c, n).exists(r => s.nodes.get(n).get(r).value == v)
    )

  // 某節點上已經有「自己的」未到期 key（= 上一輪 attempt 留下的殘留）。
  // 修復前這種節點會擋住自己；修復後可被重新取得（TTL 覆寫）。
  pure def hasOwnResidualKey(s: State, c: ClientId, n: NodeId): bool =
    val v = valOf(s.clients.get(c))
    v != 0 and
    RESOURCES.exists(r =>
      val e = s.nodes.get(n).get(r)
      keyExists(e, s.now) and e.value == v
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
      acquireKind: VALIDITY_CHECKED,
      acquireStart: 0,
      retriesLeft: 0,
      attemptDone: false,
      grantedNodes: Set(),
      lock: emptyLock,
      signalAbort: false,
      selfBlocked: false,
      handedExpiredLock: false,
      reported: NOT_FINISHED,
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
      // 新的一次 using() 呼叫：尚未回報任何結果。
      reported: NOT_FINISHED,
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
      // F2 的觀測點：被自己上一輪留下的 key 擋住。
      // 修復後 acquireBlockedBy 已濾掉同 value，故此集合恆空 → 由
      // neverSelfBlocked 檢查。
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
  // **F1 的修復就在這裡**：修復後多了 `if (Date.now() >= expiration) throw`，
  // 因此「達成 quorum」不再足以交出一把鎖——還必須 validity 未耗盡。
  // 過期的那一支走 abortAcquireExpired。
  action completeAcquire(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    clients.get(c).attemptDone,
    hasQuorum(clients.get(c).grantedNodes.size()),
    // 修復後新增的檢查（as-is 版本沒有這一行，這正是 F1）。
    acquireBelieved(clients.get(c)) > now,
    clients' = clients.set(c, {
      ...clients.get(c),
      acquirePhase: AFTER_ACQUIRE,
      lock: {
        resources: RESOURCES,
        value: valOf(clients.get(c)),
        expiresAt: acquireBelieved(clients.get(c)),
        permits: clients.get(c).grantedNodes,
      },
      // 由上面的 guard 保證恆為 false；保留賦值是為了讓
      // neverHandsOutExpiredLock 成為可檢查的回歸防線（拿掉 guard 就會紅）。
      handedExpiredLock: clients.get(c).handedExpiredLock or
        acquireBelieved(clients.get(c)) <= now,
    }),
    now' = now,
    nodes' = nodes,
  }

  // **F1 修復後新增的路徑**：已達 quorum，但往返期間 client 停頓，使算出的
  // validity 已經耗盡。修復後的程式碼丟 ExecutionError，而那個 throw 落在
  // acquire() 既有的 catch 內 → **補償釋放**部分節點上的 key → 才 reject。
  //
  // 與 failAcquire 一樣，「補償釋放」與「回到 caller」是同一個 await 的兩半，
  // 因此寫成同一個原子動作（不得讓模型停在「已放棄但未清理」）。
  action abortAcquireExpired(c: ClientId): bool = all {
    clients.get(c).acquirePhase == AWAIT_ACQUIRE,
    clients.get(c).attemptDone,
    hasQuorum(clients.get(c).grantedNodes.size()),
    acquireBelieved(clients.get(c)) <= now,
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
  // F5 的修復：與 acquire 一樣新增 validity 檢查（src/index.ts 的 extend()）。
  // 過期的那一支走 abortExtendExpired。
  action completeExtend(c: ClientId): bool = all {
    clients.get(c).extendPhase == AWAIT_EXTEND,
    clients.get(c).extendDone,
    hasQuorum(clients.get(c).extendGranted.size()),
    // 修復後新增的檢查（as-is 版本沒有這一行，這正是 F5）。
    extendBelieved(clients.get(c)) > now,
    clients' = clients.set(c, {
      ...clients.get(c),
      extendPhase: EXTEND_IDLE,
      lock: {
        ...clients.get(c).lock,
        expiresAt: extendBelieved(clients.get(c)),
        permits: clients.get(c).lock.permits.union(clients.get(c).extendGranted),
      },
      // 同 completeAcquire：由 guard 保證恆為 false，作為回歸防線保留。
      handedExpiredLock: clients.get(c).handedExpiredLock or
        extendBelieved(clients.get(c)) <= now,
    }),
    now' = now,
    nodes' = nodes,
  }

  // **F5 修復後新增的路徑**：續期達成 quorum，但 validity 已耗盡。
  // 修復後的 extend() 會**主動釋放**這把已失效的鎖，然後丟 ExecutionError。
  //
  // 那個 throw 落在 using() 內 extend() 的 catch，與任何其他續期失敗走同一條路：
  // 若舊的 lock.expiration 仍在未來就重試（此時 key 已被釋放，必然再失敗），
  // 否則設定 signal.error 並 abort（src/index.ts 的 catch 區塊）。
  // 因此這裡的 signalAbort 判定與 failExtend 完全一致。
  action abortExtendExpired(c: ClientId): bool = all {
    clients.get(c).extendPhase == AWAIT_EXTEND,
    clients.get(c).extendDone,
    hasQuorum(clients.get(c).extendGranted.size()),
    extendBelieved(clients.get(c)) <= now,
    // 修復後的 extend() 在丟錯前先釋放（避免這把鎖佔住節點直到 TTL 自然到期）
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
      extendPhase: EXTEND_IDLE,
      signalAbort: if (stillValidAt(clients.get(c), now))
        clients.get(c).signalAbort
      else
        true,
    }),
    now' = now,
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
  // **F7 的修復就在這裡。**
  //   修復前：release 失敗會從 `finally` 拋出，**吃掉** routine 的回傳值與
  //           signal.error——呼叫端拿到的是「釋放失敗」，而不是「鎖掉了」。
  //   修復後：改用明確的優先序——signal.error 排在 release 的錯誤**之前**，
  //           因此 abort 的原因不再被遮蔽（src/index.ts 結尾）。
  //
  // 注意：`releaseFailed and signalAbort` 這個**狀態組合修復前後都會發生**，
  // 修復改變的是**回報哪一個**。所以 F7 的不變式必須寫在 reported 上，
  // 寫在 releaseFailed/signalAbort 上只會得到一條修復後仍然被違反的假結論。
  // **保真度（本次新增的 guard）**：`await lock.release()` 之後 `using()` 就返回了，
  // routine 已經結束——因此 client 必須離開 routine 的所有階段，回到 IDLE。
  //
  // 沒有這一行的話，模型允許 client 在 release 完成之後**再做一次
  // `doIsolationCheck`**（它的 guard 只要求 `acquirePhase == AFTER_ACQUIRE`），
  // 於是 `signalAbort` 會在 `reported` 已經決定之後才變成 true，憑空製造出
  // 「abort 被 release 的錯誤遮蔽」的假象。
  //
  // ⚠️ **as-is 版本的 F7 反例正是這個假象**（見 traces/as-is 的解碼：
  // 第 8 狀態 release 已失敗完成、`signalAbort=false`，第 9 狀態才由
  // doIsolationCheck 把 `signalAbort` 設為 true）。詳見 specs/README.md
  // 「as-is 的 F7 反例是模型假象」。
  action completeRelease(c: ClientId): bool = all {
    clients.get(c).releasing,
    clients.get(c).releaseDone,
    clients' = clients.set(c, {
      ...clients.get(c),
      releaseFailed: not(hasQuorum(clients.get(c).releaseForCount)),
      lock: emptyLock,
      releasing: false,
      // using() 返回：routine 的所有階段都已結束
      acquirePhase: IDLE,
      reported:
        if (clients.get(c).signalAbort)
          SIGNAL_ERROR
        else if (not(hasQuorum(clients.get(c).releaseForCount)))
          RELEASE_ERROR
        else
          RESULT,
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
      abortAcquireExpired(c),
      retryAcquire(c),
      failAcquire(c),
      doIsolationCheck(c),
      enterCritical(c),
      criticalWork(c),
      exitCritical(c),
      startExtend(c),
      attemptExtend(c),
      completeExtend(c),
      abortExtendExpired(c),
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

  // **F1 / F5（修復後成立）**：從來沒有一把「結算當下就已過期」的鎖被交給呼叫端。
  //
  // ⚠️ 這條若單獨看是**結構上必然成立**的（completeAcquire / completeExtend 的
  // guard 直接排除了它）。它的價值有兩個，都不在於「證明了什麼新東西」：
  //   1. **回歸防線**：日後若有人拿掉那兩個 guard，這條立刻紅。
  //   2. 配合下方的 witness 才有內容——witness 證明「validity 已耗盡」這個
  //      危險狀態**確實可達**，所以本條不是「模型根本沒走到那裡」。
  val neverHandsOutExpiredLock: bool =
    CLIENTS.forall(c => not(clients.get(c).handedExpiredLock))

  // **F3**：client 相信持有有效鎖，但真實覆蓋率已跌破 quorum（靜默失去 quorum）。
  //
  // 注意：在**預設情境**（F8/F9 關閉）下此條不可違反——因為 client 相信的到期
  // 時間（start + DURATION - DRIFT）永遠早於節點端 key 的實際到期時間
  // （setTime + DURATION >= start + DURATION），所以「相信」會先失效。
  // 它需要**非對稱的節點失效**才會成立，見 redlockCrashLoss 實例。
  val INV_VIOLATED_quorumCoverageDecay: bool =
    val s = mkState(now, nodes, clients)
    CLIENTS.forall(c => not(isSilentlyUnderQuorum(s, c)))

  // **F2（修復後成立）**：從來沒有 client 被「自己的 value」擋住。
  //
  // ⚠️ 同樣是結構上必然成立的（acquireBlockedBy 已把同 value 濾掉）。
  // 內容由 witness retryFacesOwnResidualKey 提供：它證明「重試時節點上還留著
  // 自己上一輪的 key」這個情境確實會發生，而且此時該節點是**可取得的**
  // ——修復前那正是卡死的來源。
  val neverSelfBlocked: bool =
    CLIENTS.forall(c => not(clients.get(c).selfBlocked))

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

  // **F7（修復後成立）**：abort 的原因**永遠不會被 release 的錯誤遮蔽**。
  //
  // 這條與前兩條不同，它**不是**結構上的同義反覆：`releaseFailed ∧ signalAbort`
  // 這個狀態組合修復前後都會發生（見 witness releaseFailedWhileAborted）。
  // 修復改變的是**回報哪一個**——因此本條寫在 reported 上。
  //
  // 對照組：若把述詞寫成 as-is 版本的 `not(releaseFailed and signalAbort)`，
  // 修復後**仍然會被違反**，並得出「F7 沒修好」的假結論。
  val abortReasonNeverMasked: bool =
    CLIENTS.forall(c =>
      not(clients.get(c).signalAbort and clients.get(c).reported == RELEASE_ERROR)
    )

  // ===========================================================================
  // 性質（Step 5）—— 正向 witness（要求 trace 數 > 0）
  //
  // **這一節是 as-fixed 規格的重點。** 上面那些「修復後成立」的不變式，若沒有
  // 對應的 witness 證明其守護的危險狀態可達，就只是「模型沒走到那裡」的空跑。
  // 以下四個 witness 全部寫成**純狀態述詞**（不新增任何狀態變數）。
  // ===========================================================================

  // **F1 的檢查確實會觸發**：已達 quorum，但算出的 validity 已經耗盡。
  // 這正是 abortAcquireExpired 的 guard；修復前這個狀態會直接走進
  // completeAcquire 並交出一把過期的鎖。
  val acquireExpiryDetectable: bool =
    CLIENTS.exists(c =>
      val cs = clients.get(c)
      cs.acquirePhase == AWAIT_ACQUIRE and
      cs.attemptDone and
      hasQuorum(cs.grantedNodes.size()) and
      acquireBelieved(cs) <= now
    )

  // **F5 的檢查確實會觸發**：續期已達 quorum，但 replacement 的 validity 已耗盡。
  val extendExpiryDetectable: bool =
    CLIENTS.exists(c =>
      val cs = clients.get(c)
      cs.extendPhase == AWAIT_EXTEND and
      cs.extendDone and
      hasQuorum(cs.extendGranted.size()) and
      extendBelieved(cs) <= now
    )

  // **F2 的修復確實走在真實的路徑上**：client 正要重試，某節點上還留著
  // **自己上一輪**的 key，而且該節點此刻是**可取得的**（acquireOk）。
  //
  // 最後那個合取項就是修復本身：修復前同一個狀態下 acquireOk 為 false
  // （`exists` 不問是誰的），client 會被自己的殘留 key 擋住。
  val retryFacesOwnResidualKey: bool =
    val s = mkState(now, nodes, clients)
    CLIENTS.exists(c =>
      val cs = clients.get(c)
      cs.acquirePhase == AWAIT_ACQUIRE and
      not(cs.attemptDone) and
      cs.lock.value != 0 and
      NODES.exists(n => hasOwnResidualKey(s, c, n) and acquireOk(s, c, n))
    )

  // **F7 的危險組合確實可達**：release 失敗**且**已經 abort。
  // 沒有這個 witness，abortReasonNeverMasked 就可能只是因為兩者從未同時成立。
  val releaseFailedWhileAborted: bool =
    CLIENTS.exists(c =>
      clients.get(c).releaseFailed and clients.get(c).signalAbort
    )

  // **F7 的修復路徑確實被走到**：確實有 client 以 SIGNAL_ERROR 收場。
  val reportedSignalError: bool =
    CLIENTS.exists(c => clients.get(c).reported == SIGNAL_ERROR)
}
