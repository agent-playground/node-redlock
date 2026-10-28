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
      .expect(not(neverHandsOutExpiredLock == false))
      .expect(not(neverSelfBlocked == false))
      .expect(CLIENTS.forall(c => clients.get(c).reported == NOT_FINISHED))
}

// 三個修復（F1 / F5 / F2）的**決定性**驗證。
//
// 為什麼要決定性腳本而不只靠 witness 百分比：`attemptAcquire` 的 `chosen` 是
// 動作參數，測試可以直接指定「誰搶到哪些節點」，把交錯完全腳本化。這比隨機
// 走訪抽到的 witness 更強——它可重現，而且能斷言路徑上的每一個中間狀態。
module redlockFixScenario {
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

  // --- F2：修復前會卡死的那個劇本，現在能走出來 ---------------------------
  //
  // 劇本與 as-is 版本的 bothClientsStarveTest **完全相同**（兩個 client 各搶到
  // 一半節點、各自 retry），差別只在第二輪：
  //   修復前：節點 1／2 上是自己的 key，被 `exists` 擋住 → 雙方卡死到 TTL。
  //   修復後：自己的 key 不再擋自己 → client 1 補上節點 3 就達成 quorum。
  run retryEscapesSelfBlockTest =
    init
      // client 1 只搶到節點 1（1 票 < quorum 2）→ retry（仍在 AWAIT_ACQUIRE 之內）
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1)))
      .then(retryAcquire(1))
      // client 2 只搶到節點 2 → retry
      .then(startAcquire(2))
      .then(attemptAcquire(2, Set(2)))
      .then(retryAcquire(2))
      // 殘留 key 確實還在節點上（value 各為 100 / 200）
      .expect(nodes.get(1).get("r").value == 100)
      .expect(nodes.get(2).get("r").value == 200)
      // **修復的本體**：帶著自己殘留 key 的節點 1 是可取得的，
      // 而帶著別人 key 的節點 2 仍然擋得住 —— 兩者必須分開，否則
      // 「不再自我阻塞」與「鎖根本不互斥」在斷言上無法區分。
      .expect(retryFacesOwnResidualKey)
      .expect(acquireOk(mkState(now, nodes, clients), 1, 1))
      .expect(not(acquireOk(mkState(now, nodes, clients), 1, 2)))
      // 第二次 attempt：重新取得自己的節點 1，再補上空閒的節點 3 → quorum
      .then(attemptAcquire(1, Set(1, 3)))
      .expect(not(clients.get(1).selfBlocked))
      .then(completeAcquire(1))
      .expect(clients.get(1).acquirePhase == AFTER_ACQUIRE)
      .expect(trulyHolds(mkState(now, nodes, clients), 1))
      // client 2 則被 client 1 的鎖**正當地**擋住：它只拿得回自己的節點 2，
      // 達不到 quorum，預算耗盡後補償釋放並回到 IDLE。
      .then(attemptAcquire(2, Set(2)))
      .expect(not(hasQuorum(clients.get(2).grantedNodes.size())))
      .then(failAcquire(2))
      .expect(clients.get(2).acquirePhase == IDLE)
      .expect(not(holdsSomething(clients.get(2))))
      .expect(nodes.get(2).get("r").value == 0)
      // 全程沒有任何一方被自己的 value 擋住
      .expect(neverSelfBlocked)

  // --- F1：acquire 的 validity 檢查確實會觸發，且會補償釋放 -----------------
  //
  // DURATION=2 / DRIFT=1 → acquireBelieved = acquireStart + 1。
  // 在 attempt 與結算之間插入一次 advanceTime，validity 就恰好耗盡。
  run acquireValidityCheckTest =
    init
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1, 2)))
      // 節點上的 key 到 now+DURATION=2 才到期，但 client 相信的到期是 1
      .expect(nodes.get(1).get("r").expiresAt == 2)
      .then(advanceTime)
      // now=1，acquireBelieved=1 → validity 已耗盡
      .expect(acquireExpiryDetectable)
      .then(abortAcquireExpired(1))
      // 修復後：不交出鎖，而是回到 IDLE
      .expect(clients.get(1).acquirePhase == IDLE)
      .expect(not(holdsSomething(clients.get(1))))
      .expect(not(clients.get(1).handedExpiredLock))
      .expect(neverHandsOutExpiredLock)
      // 補償釋放清掉了部分節點上的 key（修復前這些 key 會留到 TTL 自然到期）
      .expect(nodes.get(1).get("r").value == 0)
      .expect(nodes.get(2).get("r").value == 0)

  // --- F5：extend 的 validity 檢查確實會觸發，且會釋放已失效的鎖 ------------
  run extendValidityCheckTest =
    init
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1, 2)))
      .then(completeAcquire(1))
      .expect(clients.get(1).lock.expiresAt == 1)
      // 到期前 EXTENSION_THRESHOLD=1 觸發自動續期
      .then(startExtend(1))
      .then(attemptExtend(1))
      .then(advanceTime)
      // now=1，extendBelieved=1 → replacement 的 validity 已耗盡
      .expect(extendExpiryDetectable)
      .then(abortExtendExpired(1))
      .expect(clients.get(1).extendPhase == EXTEND_IDLE)
      .expect(not(clients.get(1).handedExpiredLock))
      .expect(neverHandsOutExpiredLock)
      // 修復後的 extend() 在丟錯前主動釋放這把已失效的鎖
      .expect(nodes.get(1).get("r").value == 0)
      .expect(nodes.get(2).get("r").value == 0)

  // --- F7：release 失敗**且**已 abort 時，回報的是 abort 的原因 --------------
  //
  // 這條是四個「修復後成立」的不變式裡**唯一不是結構同義反覆**的一條，因此
  // 它的可達性最值得用決定性腳本釘死（隨機 witness 只有 0.18%）。
  //
  // 劇本：取得鎖 → 續期時節點上的 key 已自然到期 → 續期拿不到 quorum 且鎖已
  // 失效 → signalAbort；此時 release 也因為沒有 key 可刪而拿不到 quorum → 失敗。
  run abortReasonSurvivesReleaseFailureTest =
    init
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1, 2)))
      .then(completeAcquire(1))
      .then(startExtend(1))
      .then(advanceTime)
      .then(advanceTime) // now=2：節點上的 key（expiresAt=2）已自然到期
      .then(attemptExtend(1))
      .expect(clients.get(1).extendGranted.size() == 0)
      .then(failExtend(1))
      .expect(clients.get(1).signalAbort)
      .then(startRelease(1))
      .then(attemptRelease(1))
      .then(completeRelease(1))
      // **兩件事同時成立——修復前後都會發生。**
      // 下面這兩個 expect 正是 as-is 版本 INV_VIOLATED_releaseErrorMasksAbort
      // 的違反條件：若沿用那條述詞，修復後仍會「找到反例」，並得出
      // 「F7 沒修好」的假結論。
      .expect(clients.get(1).releaseFailed)
      .expect(clients.get(1).signalAbort)
      .expect(releaseFailedWhileAborted)
      // **修復真正改變的事**：回報的是 abort 的原因，不是 release 的錯誤。
      .expect(clients.get(1).reported == SIGNAL_ERROR)
      .expect(abortReasonNeverMasked)

  // --- 保真度回歸：using() 在 release 完成後就返回，routine 不得再執行 -------
  //
  // 這條測試存在的原因是一個**真實發生過的模型缺陷**：`completeRelease` 原本
  // 不改 `acquirePhase`，於是 client 可以在 release 完成之後再做一次
  // `doIsolationCheck`，把 `signalAbort` 設成 true——而 `reported` 早就決定了。
  // 那會憑空製造出「abort 被 release 的錯誤遮蔽」的假反例。
  // **as-is 版本的 F7 反例正是這個假象**（見 specs/README.md）。
  run usingCycleEndsAtReleaseTest =
    init
      .then(startAcquire(1))
      .then(attemptAcquire(1, Set(1, 2)))
      .then(completeAcquire(1))
      .then(advanceTime)
      .then(advanceTime) // now=2：節點 key（expiresAt=2）已到期 → release 會失敗
      .then(startRelease(1))
      .then(attemptRelease(1))
      .then(completeRelease(1))
      .expect(clients.get(1).releaseFailed)
      .expect(clients.get(1).reported == RELEASE_ERROR)
      .expect(not(clients.get(1).signalAbort))
      // **保真度斷言**：using() 已返回，client 回到 IDLE，
      // 因此 doIsolationCheck / enterCritical / startExtend 全部不再 enabled。
      .expect(clients.get(1).acquirePhase == IDLE)
      .expect(not(canEnterCritical(mkState(now, nodes, clients), 1)))
      .expect(not(canStartExtend(mkState(now, nodes, clients), 1)))
      .expect(abortReasonNeverMasked)
}
