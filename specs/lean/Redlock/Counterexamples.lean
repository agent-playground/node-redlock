import Redlock.Basic
import Redlock.Timed

namespace Redlock

/-!
# Redlock.Counterexamples

依據 Carl M. Kadie《Nine Rules for Vibe Validation》Rule 2（消除 Proof Slop），
重構為高階 Trace 執行抽象：
1. `counterexample_f8_two_clients_believe_lock`：
   證明在節點崩潰重啟遺失 memory key（F8）的情境下，
   存在可達狀態使得兩位客戶端同時確信自己持有合法分散式鎖。
2. `counterexample_f4_concurrent_critical_sections`：
   證明在非同步時間與缺乏 fencing token（F4）的狀況下，
   存在可達狀態使得兩位客戶端同時處於受保護的臨界區內。
3. `counterexample_f9_uppaal_clock_jump`：
   證明在完全無節點異常（nodeJumps = 0）的情境下，
   僅靠客戶端時鐘往後突跳（F9 / UPPAAL 查詢 2），即可打破互斥性。
-/

open ClientPhase
open Redlock.Timed

/-!
## 一、F8 反例證明：節點重啟遺失 Key 導致雙重持鎖（Kleppmann 反例）
-/

/-- F8 反例 Action 轉移序列（9 步） -/
def f8_trace : List Action := [
  Action.startAcquire c1 200,
  Action.attemptGrant c1 n0,
  Action.attemptGrant c1 n1,
  Action.crashAndRestart n1,
  Action.startAcquire c0 100,
  Action.completeAcquire c1,
  Action.attemptGrant c0 n1,
  Action.attemptGrant c0 n2,
  Action.completeAcquire c0
]

/-- F8 反例終態 -/
def f8_finalState : State :=
  match runTrace initState f8_trace with
  | some s => s
  | none => initState

/-- F8 反例數學定理：存在可達狀態違反雙客戶端不同時持鎖的性質 -/
theorem counterexample_f8_two_clients_believe_lock :
    ∃ s : State, Reachable s ∧ ¬ inv_f8_no_two_clients_believe_lock s := by
  exists f8_finalState
  constructor
  · exact reachable_of_runTrace f8_trace Reachable.init (by rfl)
  · intro h_inv
    have h_viol : ((f8_finalState.clients c0).believesHoldsBool f8_finalState.now &&
                   (f8_finalState.clients c1).believesHoldsBool f8_finalState.now) = true := by rfl
    exact h_inv h_viol

/-!
## 二、F4 反例證明：無 Fencing Token 下臨界區重疊並行
-/

/-- F4 反例 Action 轉移序列（14 步） -/
def f4_trace : List Action := [
  Action.startAcquire c0 100,
  Action.attemptGrant c0 n0,
  Action.attemptGrant c0 n1,
  Action.completeAcquire c0,
  Action.checkIsolation c0,
  Action.enterCritical c0,
  Action.startRelease c0,
  Action.completeRelease c0,
  Action.startAcquire c1 200,
  Action.attemptGrant c1 n0,
  Action.attemptGrant c1 n2,
  Action.completeAcquire c1,
  Action.checkIsolation c1,
  Action.enterCritical c1
]

/-- F4 反例終態 -/
def f4_finalState : State :=
  match runTrace initState f4_trace with
  | some s => s
  | none => initState

/-- F4 反例數學定理：存在可達狀態違反臨界區互斥性 -/
theorem counterexample_f4_concurrent_critical_sections :
    ∃ s : State, Reachable s ∧ ¬ inv_f4_no_concurrent_critical s := by
  exists f4_finalState
  constructor
  · exact reachable_of_runTrace f4_trace Reachable.init (by rfl)
  · intro h_inv
    have h_viol : ((f4_finalState.clients c0).inCritical &&
                   (f4_finalState.clients c1).inCritical) = true := by rfl
    exact h_inv h_viol

/-!
## 三、F9 反例證明：UPPAAL 多時鐘模型（零節點異常下的時鐘突跳）
對應 UPPAAL 查詢 2：E<> (both InCritical && node_jumps == 0)
-/

/-- F9 反例 TimedAction 轉移序列（12 步） -/
def f9_trace : List TimedAction := [
  TimedAction.startAcquire c0 100,
  TimedAction.clientClockJump c0 5,
  TimedAction.grantNode c0 n0,
  TimedAction.grantNode c0 n1,
  TimedAction.grantNode c0 n2,
  TimedAction.enterCritical c0,
  TimedAction.advanceRealTime 21,
  TimedAction.startAcquire c1 200,
  TimedAction.grantNode c1 n0,
  TimedAction.grantNode c1 n1,
  TimedAction.grantNode c1 n2,
  TimedAction.enterCritical c1
]

/-- F9 反例終態 -/
def f9_finalState : TimedState :=
  match runTimedTrace initTimedState f9_trace with
  | some s => s
  | none => initTimedState

/-- F9 反例數學定理：在零節點異常（nodeJumps = 0）下，僅靠客戶端時鐘突跳即打破互斥性 -/
theorem counterexample_f9_uppaal_clock_jump :
    ∃ s : TimedState, TimedReachable s ∧
        s.nodeJumps = 0 ∧
        ¬ inv_timed_mutual_exclusion s := by
  exists f9_finalState
  constructor
  · exact reachable_of_runTimedTrace f9_trace TimedReachable.init (by rfl)
  · constructor
    · rfl -- 確鑿證明 nodeJumps 嚴格為 0！
    · intro h_inv
      have h_viol : ((f9_finalState.clients c0).believesInLease f9_finalState.realNow (f9_finalState.clientSkew c0) &&
                     (f9_finalState.clients c1).believesInLease f9_finalState.realNow (f9_finalState.clientSkew c1)) = true := by rfl
      exact h_inv h_viol

end Redlock
