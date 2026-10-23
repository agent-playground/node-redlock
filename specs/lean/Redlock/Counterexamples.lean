import Redlock.Basic
import Redlock.Timed

namespace Redlock

/-!
# Redlock.Counterexamples

此模組形式化證明 Redlock 演算法固有缺陷的數學反例：
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

/-- 執行單步轉移並驗證成功 -/
theorem reach_step (a : Action) {s s' : State} (hr : Reachable s) (hn : nextState s a = some s') :
    Reachable s' :=
  Reachable.step hr (Step.of_next hn)

/-!
## 一、F8 反例證明：節點重啟遺失 Key 導致雙重持鎖（Kleppmann 反例）
-/

-- s0: 初始狀態
def f8_s0 : State := initState

-- s1: Client 1 發起 acquire (token = 200)
def f8_s1 : State := match nextState f8_s0 (Action.startAcquire c1 200) with | some s => s | none => f8_s0

-- s2: Client 1 成功獲取 Node 0
def f8_s2 : State := match nextState f8_s1 (Action.attemptGrant c1 n0) with | some s => s | none => f8_s1

-- s3: Client 1 成功獲取 Node 1
def f8_s3 : State := match nextState f8_s2 (Action.attemptGrant c1 n1) with | some s => s | none => f8_s2

-- s4: Node 1 崩潰重啟並遺失 memory key
def f8_s4 : State := match nextState f8_s3 (Action.crashAndRestart n1) with | some s => s | none => f8_s3

-- s5: Client 0 發起 acquire (token = 100)
def f8_s5 : State := match nextState f8_s4 (Action.startAcquire c0 100) with | some s => s | none => f8_s4

-- s6: Client 1 結算 completeAcquire (拿到 2 節點達 quorum，lockExpiry = 1)
def f8_s6 : State := match nextState f8_s5 (Action.completeAcquire c1) with | some s => s | none => f8_s5

-- s7: Client 0 成功獲取已重啟的 Node 1
def f8_s7 : State := match nextState f8_s6 (Action.attemptGrant c0 n1) with | some s => s | none => f8_s6

-- s8: Client 0 成功獲取 Node 2
def f8_s8 : State := match nextState f8_s7 (Action.attemptGrant c0 n2) with | some s => s | none => f8_s7

-- s9: Client 0 結算 completeAcquire (拿到 2 節點達 quorum，lockExpiry = 1)
def f8_s9 : State := match nextState f8_s8 (Action.completeAcquire c0) with | some s => s | none => f8_s8

theorem f8_s9_reachable : Reachable f8_s9 := by
  have r0 : Reachable f8_s0 := Reachable.init
  have r1 : Reachable f8_s1 := reach_step (Action.startAcquire c1 200) r0 (by rfl)
  have r2 : Reachable f8_s2 := reach_step (Action.attemptGrant c1 n0) r1 (by rfl)
  have r3 : Reachable f8_s3 := reach_step (Action.attemptGrant c1 n1) r2 (by rfl)
  have r4 : Reachable f8_s4 := reach_step (Action.crashAndRestart n1) r3 (by rfl)
  have r5 : Reachable f8_s5 := reach_step (Action.startAcquire c0 100) r4 (by rfl)
  have r6 : Reachable f8_s6 := reach_step (Action.completeAcquire c1) r5 (by rfl)
  have r7 : Reachable f8_s7 := reach_step (Action.attemptGrant c0 n1) r6 (by rfl)
  have r8 : Reachable f8_s8 := reach_step (Action.attemptGrant c0 n2) r7 (by rfl)
  have r9 : Reachable f8_s9 := reach_step (Action.completeAcquire c0) r8 (by rfl)
  exact r9

/-- F8 反例數學定理：存在可達狀態違反雙客戶端不同時持鎖的性質 -/
theorem counterexample_f8_two_clients_believe_lock :
    ∃ s : State, Reachable s ∧ ¬ inv_f8_no_two_clients_believe_lock s := by
  exists f8_s9
  constructor
  · exact f8_s9_reachable
  · intro h_inv
    have h_viol : ((f8_s9.clients c0).believesHoldsBool f8_s9.now && (f8_s9.clients c1).believesHoldsBool f8_s9.now) = true := by rfl
    exact h_inv h_viol

/-!
## 二、F4 反例證明：無 Fencing Token 下臨界區重疊並行
-/

-- c0 acquire
def f4_s0 : State := initState
def f4_s1 : State := match nextState f4_s0 (Action.startAcquire c0 100) with | some s => s | none => f4_s0
def f4_s2 : State := match nextState f4_s1 (Action.attemptGrant c0 n0) with | some s => s | none => f4_s1
def f4_s3 : State := match nextState f4_s2 (Action.attemptGrant c0 n1) with | some s => s | none => f4_s2
def f4_s4 : State := match nextState f4_s3 (Action.completeAcquire c0) with | some s => s | none => f4_s3
def f4_s5 : State := match nextState f4_s4 (Action.checkIsolation c0) with | some s => s | none => f4_s4
def f4_s6 : State := match nextState f4_s5 (Action.enterCritical c0) with | some s => s | none => f4_s5

-- c0 release while routine is still running in critical section
def f4_s7 : State := match nextState f4_s6 (Action.startRelease c0) with | some s => s | none => f4_s6
def f4_s8 : State := match nextState f4_s7 (Action.completeRelease c0) with | some s => s | none => f4_s7

-- c1 acquire
def f4_s9  : State := match nextState f4_s8  (Action.startAcquire c1 200) with | some s => s | none => f4_s8
def f4_s10 : State := match nextState f4_s9  (Action.attemptGrant c1 n0) with | some s => s | none => f4_s9
def f4_s11 : State := match nextState f4_s10 (Action.attemptGrant c1 n2) with | some s => s | none => f4_s10
def f4_s12 : State := match nextState f4_s11 (Action.completeAcquire c1) with | some s => s | none => f4_s11
def f4_s13 : State := match nextState f4_s12 (Action.checkIsolation c1) with | some s => s | none => f4_s12
def f4_s14 : State := match nextState f4_s13 (Action.enterCritical c1) with | some s => s | none => f4_s13

theorem f4_s14_reachable : Reachable f4_s14 := by
  have r0  : Reachable f4_s0  := Reachable.init
  have r1  : Reachable f4_s1  := reach_step (Action.startAcquire c0 100) r0 (by rfl)
  have r2  : Reachable f4_s2  := reach_step (Action.attemptGrant c0 n0) r1 (by rfl)
  have r3  : Reachable f4_s3  := reach_step (Action.attemptGrant c0 n1) r2 (by rfl)
  have r4  : Reachable f4_s4  := reach_step (Action.completeAcquire c0) r3 (by rfl)
  have r5  : Reachable f4_s5  := reach_step (Action.checkIsolation c0) r4 (by rfl)
  have r6  : Reachable f4_s6  := reach_step (Action.enterCritical c0) r5 (by rfl)
  have r7  : Reachable f4_s7  := reach_step (Action.startRelease c0) r6 (by rfl)
  have r8  : Reachable f4_s8  := reach_step (Action.completeRelease c0) r7 (by rfl)
  have r9  : Reachable f4_s9  := reach_step (Action.startAcquire c1 200) r8 (by rfl)
  have r10 : Reachable f4_s10 := reach_step (Action.attemptGrant c1 n0) r9 (by rfl)
  have r11 : Reachable f4_s11 := reach_step (Action.attemptGrant c1 n2) r10 (by rfl)
  have r12 : Reachable f4_s12 := reach_step (Action.completeAcquire c1) r11 (by rfl)
  have r13 : Reachable f4_s13 := reach_step (Action.checkIsolation c1) r12 (by rfl)
  have r14 : Reachable f4_s14 := reach_step (Action.enterCritical c1) r13 (by rfl)
  exact r14

/-- F4 反例數學定理：存在可達狀態違反臨界區互斥性 -/
theorem counterexample_f4_concurrent_critical_sections :
    ∃ s : State, Reachable s ∧ ¬ inv_f4_no_concurrent_critical s := by
  exists f4_s14
  constructor
  · exact f4_s14_reachable
  · intro h_inv
    have h_viol : ((f4_s14.clients c0).inCritical && (f4_s14.clients c1).inCritical) = true := by rfl
    exact h_inv h_viol

/-!
## 三、F9 反例證明：UPPAAL 多時鐘模型（零節點異常下的時鐘突跳）
對應 UPPAAL 查詢 2：E<> (both InCritical && node_jumps == 0)
-/

open Redlock.Timed

/-- 執行單步多時鐘轉移並驗證成功 -/
theorem reach_timed_step (a : TimedAction) {s s' : TimedState} (hr : TimedReachable s) (hn : nextTimedState s a = some s') :
    TimedReachable s' :=
  TimedReachable.step hr (TimedStep.of_next hn)

def f9_s0  : TimedState := initTimedState
def f9_s1  : TimedState := match nextTimedState f9_s0  (TimedAction.startAcquire c0 100) with | some s => s | none => f9_s0
def f9_s2  : TimedState := match nextTimedState f9_s1  (TimedAction.clientClockJump c0 5) with | some s => s | none => f9_s1
def f9_s3  : TimedState := match nextTimedState f9_s2  (TimedAction.grantNode c0 n0) with | some s => s | none => f9_s2
def f9_s4  : TimedState := match nextTimedState f9_s3  (TimedAction.grantNode c0 n1) with | some s => s | none => f9_s3
def f9_s5  : TimedState := match nextTimedState f9_s4  (TimedAction.grantNode c0 n2) with | some s => s | none => f9_s4
def f9_s6  : TimedState := match nextTimedState f9_s5  (TimedAction.enterCritical c0) with | some s => s | none => f9_s5
def f9_s7  : TimedState := match nextTimedState f9_s6  (TimedAction.advanceRealTime 21) with | some s => s | none => f9_s6
def f9_s8  : TimedState := match nextTimedState f9_s7  (TimedAction.startAcquire c1 200) with | some s => s | none => f9_s7
def f9_s9  : TimedState := match nextTimedState f9_s8  (TimedAction.grantNode c1 n0) with | some s => s | none => f9_s8
def f9_s10 : TimedState := match nextTimedState f9_s9  (TimedAction.grantNode c1 n1) with | some s => s | none => f9_s9
def f9_s11 : TimedState := match nextTimedState f9_s10 (TimedAction.grantNode c1 n2) with | some s => s | none => f9_s10
def f9_s12 : TimedState := match nextTimedState f9_s11 (TimedAction.enterCritical c1) with | some s => s | none => f9_s11

theorem f9_s12_reachable : TimedReachable f9_s12 := by
  have r0  : TimedReachable f9_s0  := TimedReachable.init
  have r1  : TimedReachable f9_s1  := reach_timed_step (TimedAction.startAcquire c0 100) r0 (by rfl)
  have r2  : TimedReachable f9_s2  := reach_timed_step (TimedAction.clientClockJump c0 5) r1 (by rfl)
  have r3  : TimedReachable f9_s3  := reach_timed_step (TimedAction.grantNode c0 n0) r2 (by rfl)
  have r4  : TimedReachable f9_s4  := reach_timed_step (TimedAction.grantNode c0 n1) r3 (by rfl)
  have r5  : TimedReachable f9_s5  := reach_timed_step (TimedAction.grantNode c0 n2) r4 (by rfl)
  have r6  : TimedReachable f9_s6  := reach_timed_step (TimedAction.enterCritical c0) r5 (by rfl)
  have r7  : TimedReachable f9_s7  := reach_timed_step (TimedAction.advanceRealTime 21) r6 (by rfl)
  have r8  : TimedReachable f9_s8  := reach_timed_step (TimedAction.startAcquire c1 200) r7 (by rfl)
  have r9  : TimedReachable f9_s9  := reach_timed_step (TimedAction.grantNode c1 n0) r8 (by rfl)
  have r10 : TimedReachable f9_s10 := reach_timed_step (TimedAction.grantNode c1 n1) r9 (by rfl)
  have r11 : TimedReachable f9_s11 := reach_timed_step (TimedAction.grantNode c1 n2) r10 (by rfl)
  have r12 : TimedReachable f9_s12 := reach_timed_step (TimedAction.enterCritical c1) r11 (by rfl)
  exact r12

/-- F9 反例數學定理：在零節點異常（nodeJumps = 0）下，僅靠客戶端時鐘突跳即打破互斥性 -/
theorem counterexample_f9_uppaal_clock_jump :
    ∃ s : TimedState, TimedReachable s ∧
        s.nodeJumps = 0 ∧
        ¬ inv_timed_mutual_exclusion s := by
  exists f9_s12
  constructor
  · exact f9_s12_reachable
  · constructor
    · rfl -- 確鑿證明 nodeJumps 嚴格為 0！
    · intro h_inv
      have h_viol : ((f9_s12.clients c0).believesInLease f9_s12.realNow (f9_s12.clientSkew c0) &&
                     (f9_s12.clients c1).believesInLease f9_s12.realNow (f9_s12.clientSkew c1)) = true := by rfl
      exact h_inv h_viol

end Redlock
