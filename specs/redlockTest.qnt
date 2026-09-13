// specs/redlockTest.qnt — redlock.qnt 的實例模組與 run 測試。
//
// 依 quint-modeling 的要求：**測試場景不得混入主模組**，故獨立成本檔。
// 主模組 redlock 的 const 在此以具體值實例化；沒有實例化的 const
// 會讓 `quint run` 失敗（Uninitialized const），因此每個要跑的模組都必須實例化。
//
// 規模上限（建模決策 10）：N=3 / M=2 / K=1 / --max-steps 12。
// 時間常數：DURATION=2、DRIFT=1、EXTENSION_THRESHOLD=1
//（調小以縮短反例路徑，讓四條 INV_VIOLATED_* 都落在 max-steps 12 內）。
//
// 三種情境（見 specs/README.md 的 F3 說明）：
//   redlockDefault   —— F8/F9 關閉（預設）：F1/F4/F7 可違反，F3 不可
//   redlockCrashLoss —— F8 開啟：F3 才可違反（需非對稱的節點失效）
//   redlockClockJump —— F9 開啟：時鐘跳躍

// ---------------------------------------------------------------------------
// 實例模組
// ---------------------------------------------------------------------------

// 預設情境。routine 採 CHECKED_LATE（第 (c) 態），以滿足 REQ-4 對 F4 的要求。
module redlockDefault {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "CHECKED_LATE",
    RETRY_BUDGET = 1,
  ).* from "./redlock"
}

// 對照組：routine 為 CHECKED（每步檢查且在同一步重新求值，理論上無縫隙）。
// 用途：證明 F4 **不只**來自 stale check——臨界區執行途中鎖失效同樣會違反互斥。
module redlockChecked {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "CHECKED",
    RETRY_BUDGET = 1,
  ).* from "./redlock"
}

// 對照組：routine 完全不檢查（README 明說的錯用）。
module redlockUnchecked {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "UNCHECKED",
    RETRY_BUDGET = 1,
  ).* from "./redlock"
}

// 敵意環境：節點崩潰重啟遺失 key（F8 / Kleppmann）。F3 需要這個開關。
module redlockCrashLoss {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = true,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "CHECKED_LATE",
    RETRY_BUDGET = 1,
  ).* from "./redlock"
}

// 敵意環境：時鐘跳躍（F9）。
module redlockClockJump {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = true,
    ROUTINE = "CHECKED_LATE",
    RETRY_BUDGET = 1,
  ).* from "./redlock"
}

// ---------------------------------------------------------------------------
// run 測試
// ---------------------------------------------------------------------------

// 前提條件（const）的斷言。assume 只「記錄」前提而不強制，故以 run 測試檢查。
module redlockAssumptions {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "CHECKED_LATE",
    RETRY_BUDGET = 1,
  ).* from "./redlock"

  // quorum 前提：N=3、f=1 時 2f < n 成立，且 quorum = floor(n/2)+1 = 2。
  run quorumAssumptionTest = all {
    assert(NODES.size() == 3),
    assert(quorumSize == 2),
    assert(2 * 1 < NODES.size()),
    assert(NODES.size() % 2 == 1),
  }

  // 規模上限（建模決策 10）與 REQ-2 的可執行前提。
  run scaleBoundTest = all {
    assert(CLIENTS.size() == 2),
    assert(RESOURCES.size() == 1),
    assert(DURATION == 2),
    assert(DRIFT == 1),
    // client 相信的到期時間必須嚴格早於節點端的實際到期時間（DRIFT 的作用）
    assert(DURATION - DRIFT < DURATION),
  }

  // 純函數的隔離測試（quint-modeling Step 3：先在 REPL/測試中驗證純函數）。
  run pureFunctionTest = all {
    assert(not(keyExists(emptyEntry, 0))),
    assert(withExpiry(emptyEntry, 3, 5).expiresAt == 8),
    assert(keyExists(withExpiry(emptyEntry, 3, 5), 7)),
    assert(not(keyExists(withExpiry(emptyEntry, 3, 5), 8))),
    assert(emptyLock.value == 0),
    assert(emptyLock.permits.size() == 0),
  }

  // INIT 後的形狀：所有 map 都已預先填入，`.get()` 不會踩到未定義行為。
  run initShapeTest =
    init
      // init 必須為每個 map 預先填入，`.get()` 才不會踩到未定義行為
      .expect(nodes.keys().size() == NODES.size())
      .expect(CLIENTS.forall(c => clients.get(c).lock == emptyLock))
      .expect(CLIENTS.forall(c => clients.get(c).acquirePhase == IDLE))
      .expect(NODES.forall(n => RESOURCES.forall(r => nodes.get(n).get(r).value == 0)))
      .expect(CLIENTS.forall(c => not(believesHolds(mkState(now, nodes, clients), c))))
      .expect(not(mutualExclusionOnNodes == false))
      .expect(not(INV_VIOLATED_returnsExpiredLock == false))
}

// F2(b) 的**決定性**可達性證明。
//
// 這個狀態在隨機走訪下機率極低（實測 `--witnesses` 只有 6/400000 ≈ 0.0015%），
// 不適合作為 CI 的百分比斷言。改用決定性的 run 測試：`attemptAcquire` 的
// `chosen` 是動作參數，測試可以直接指定搶到哪些節點，把 F2 的交錯腳本化。
//
// 劇本：兩個 client 各搶到一半節點（各 1 個，都未達 quorum 2），各自 retry；
// 下一輪 attempt 都撞到**自己上一輪留下的 key**（`exists` 只問存在、不問是誰的），
// 於是雙方都再也拿不到 quorum —— 互相卡死到 TTL。
module redlockF2Scenario {
  import redlock(
    NODES = Set(1, 2, 3),
    CLIENTS = Set(1, 2),
    RESOURCES = Set("r"),
    DURATION = 2,
    DRIFT = 1,
    EXTENSION_THRESHOLD = 1,
    STALL_BOUND = 3,
    ENABLE_CRASH_LOSS = false,
    ENABLE_CLOCK_JUMP = false,
    ROUTINE = "CHECKED_LATE",
    RETRY_BUDGET = 1,
  ).* from "./redlock"

  run bothClientsStarveTest =
    init
      // client 1 只搶到節點 1（1 票 < quorum 2）→ retry（仍在 AWAIT_ACQUIRE 之內）
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1)))
      .then(retryAcquire(1))
      // client 2 只搶到節點 2 → retry
      .then(startAcquire(2))
      .then(attemptAcquire(2, Set(2)))
      .then(retryAcquire(2))
      // 第二次 attempt：節點 1／2 上是**自己的** key，被 exists 擋住。
      // 注意這裡**不再呼叫 startAcquire**——真實的重試不是新的 acquire() 呼叫，
      // 而是 _execute 的 while 迴圈（src/index.ts:436-470），client 沒有回到 caller。
      .then(attemptAcquire(1, Set()))
      .then(attemptAcquire(2, Set()))
      // 兩人都還在重試窗口內、都被自己的 key 擋過、都沒有 quorum
      .expect(bothClientsFailWithinRetryWindow)
      .expect(selfBlockedByOwnValue)
      .expect(clients.get(1).selfBlocked)
      .expect(clients.get(2).selfBlocked)
      .expect(clients.get(1).acquirePhase == AWAIT_ACQUIRE)
      .expect(clients.get(2).acquirePhase == AWAIT_ACQUIRE)
      .expect(clients.get(1).retriesLeft == 0)
      .expect(clients.get(2).retriesLeft == 0)
      // 殘留的 key 仍在節點上（value 各為 100 / 200）—— 這正是自我阻塞的來源
      .expect(nodes.get(1).get("r").value == 100)
      .expect(nodes.get(2).get("r").value == 200)
      // 而且沒有任何一方真正持有鎖
      .expect(not(trulyHolds(mkState(now, nodes, clients), 1)))
      .expect(not(trulyHolds(mkState(now, nodes, clients), 2)))
      // 預算耗盡 → 唯一的出口是「補償釋放 + 回到 IDLE」，兩者是同一個動作
      .then(failAcquire(1))
      .then(failAcquire(2))
      .expect(clients.get(1).acquirePhase == IDLE)
      .expect(clients.get(2).acquirePhase == IDLE)
      // 補償釋放把殘留 key 清掉了。舊版模型允許「IDLE + 殘留 key」，
      // 那是真實程式碼到不了的狀態；這裡把它證明為不可停留。
      .expect(nodes.get(1).get("r").value == 0)
      .expect(nodes.get(2).get("r").value == 0)
      .expect(not(holdsSomething(clients.get(1))))
      .expect(not(holdsSomething(clients.get(2))))
}
