/-!
# Redlock.Basic

此模組定義 Redlock 分散式鎖的小步操作語意（Small-Step LTS）：
對齊 Quint 規格（specs/redlock.qnt、specs/redlockTest.qnt）的基準配置：
- 節點數 N = 3 (Quorum = 2)
- 客戶端數 M = 2 (Client 0, Client 1)
- 租約過期時長 DURATION = 2
- 時鐘漂移與計算開銷 DRIFT = 1
- 相信的有效時長 = DURATION - DRIFT = 1
-/

namespace Redlock

abbrev NodeId := Fin 3
abbrev ClientId := Fin 2

inductive ClientPhase where
  | IDLE
  | AWAIT_ACQUIRE
  | AFTER_ACQUIRE
  | ISOLATION_CHECK
  | CRITICAL
  deriving Repr, DecidableEq

structure NodeState where
  val : Nat
  expiresAt : Nat
  deriving Repr, DecidableEq

def NodeState.hasKey (n : NodeState) (now : Nat) : Bool :=
  n.val ≠ 0 ∧ n.expiresAt > now

structure ClientState where
  phase : ClientPhase
  lockVal : Nat
  lockExpiry : Nat
  grantedNodes : List NodeId
  inCritical : Bool
  releasing : Bool
  deriving Repr, DecidableEq

/-- 判定客戶端是否在當下時間確信持有有效鎖 -/
def ClientState.believesHoldsBool (c : ClientState) (now : Nat) : Bool :=
  (c.phase == ClientPhase.AFTER_ACQUIRE || c.phase == ClientPhase.ISOLATION_CHECK || c.phase == ClientPhase.CRITICAL) &&
  (c.lockExpiry > now) &&
  (c.grantedNodes.length ≥ 2)

structure State where
  now : Nat
  nodes : NodeId → NodeState
  clients : ClientId → ClientState

def initNodeState : NodeState :=
  { val := 0, expiresAt := 0 }

def initClientState : ClientState :=
  { phase := ClientPhase.IDLE
  , lockVal := 0
  , lockExpiry := 0
  , grantedNodes := []
  , inCritical := false
  , releasing := false
  }

def initState : State :=
  { now := 0
  , nodes := fun _ => initNodeState
  , clients := fun _ => initClientState
  }

inductive Action where
  | advanceTime
  | startAcquire (c : ClientId) (token : Nat)
  | attemptGrant (c : ClientId) (n : NodeId)
  | completeAcquire (c : ClientId)
  | checkIsolation (c : ClientId)
  | enterCritical (c : ClientId)
  | startRelease (c : ClientId)
  | completeRelease (c : ClientId)
  | leaveCritical (c : ClientId)
  | crashAndRestart (n : NodeId)
  deriving Repr, DecidableEq

/-- 決定性操作轉移語意函數 -/
def nextState (s : State) (a : Action) : Option State :=
  match a with
  | Action.advanceTime =>
      some { s with now := s.now + 1 }

  | Action.startAcquire c token =>
      if (s.clients c).phase == ClientPhase.IDLE && token > 0 then
        some { s with clients := fun i =>
          if i == c then
            { (s.clients c) with
                phase := ClientPhase.AWAIT_ACQUIRE
                lockVal := token
                grantedNodes := []
                lockExpiry := 0
                inCritical := false
                releasing := false }
          else s.clients i }
      else none

  | Action.attemptGrant c n =>
      let client := s.clients c
      let node := s.nodes n
      if client.phase == ClientPhase.AWAIT_ACQUIRE &&
         (! node.hasKey s.now || node.val == client.lockVal) &&
         (! client.grantedNodes.contains n) then
        some { s with
          nodes := fun j =>
            if j == n then { val := client.lockVal, expiresAt := s.now + 2 }
            else s.nodes j
          clients := fun i =>
            if i == c then
              { client with grantedNodes := n :: client.grantedNodes }
            else s.clients i }
      else none

  | Action.completeAcquire c =>
      let client := s.clients c
      if client.phase == ClientPhase.AWAIT_ACQUIRE && client.grantedNodes.length ≥ 2 then
        some { s with clients := fun i =>
          if i == c then
            { client with
                phase := ClientPhase.AFTER_ACQUIRE
                lockExpiry := s.now + 1 }
          else s.clients i }
      else none

  | Action.checkIsolation c =>
      let client := s.clients c
      if client.phase == ClientPhase.AFTER_ACQUIRE then
        some { s with clients := fun i =>
          if i == c then { client with phase := ClientPhase.ISOLATION_CHECK }
          else s.clients i }
      else none

  | Action.enterCritical c =>
      let client := s.clients c
      if client.phase == ClientPhase.ISOLATION_CHECK then
        some { s with clients := fun i =>
          if i == c then { client with phase := ClientPhase.CRITICAL, inCritical := true }
          else s.clients i }
      else none

  | Action.startRelease c =>
      let client := s.clients c
      if client.phase == ClientPhase.CRITICAL then
        some { s with clients := fun i =>
          if i == c then { client with releasing := true }
          else s.clients i }
      else none

  | Action.completeRelease c =>
      let client := s.clients c
      if client.releasing == true then
        some { s with
          nodes := fun j =>
            if (s.nodes j).val == client.lockVal then { val := 0, expiresAt := 0 }
            else s.nodes j
          clients := fun i =>
            if i == c then
              { client with
                  releasing := false
                  lockExpiry := 0
                  grantedNodes := [] }
            else s.clients i }
      else none

  | Action.leaveCritical c =>
      let client := s.clients c
      if client.phase == ClientPhase.CRITICAL then
        some { s with clients := fun i =>
          if i == c then
            { client with
                phase := ClientPhase.IDLE
                inCritical := false
                lockVal := 0 }
          else s.clients i }
      else none

  | Action.crashAndRestart n =>
      some { s with nodes := fun j =>
        if j == n then { val := 0, expiresAt := 0 }
        else s.nodes j }

/-- 小步操作語意（Small-Step LTS）轉移關係 -/
inductive Step (s : State) (a : Action) (s' : State) : Prop where
  | of_next : nextState s a = some s' → Step s a s'

/-- 可達狀態歸納定義 -/
inductive Reachable : State → Prop where
  | init : Reachable initState
  | step {s s' : State} {a : Action} : Reachable s → Step s a s' → Reachable s'

/-- 客戶端輔助識別常數 -/
def c0 : ClientId := ⟨0, by decide⟩
def c1 : ClientId := ⟨1, by decide⟩

/-- 節點輔助識別常數 -/
def n0 : NodeId := ⟨0, by decide⟩
def n1 : NodeId := ⟨1, by decide⟩
def n2 : NodeId := ⟨2, by decide⟩

/-- F4 安全不變式：不存在兩位客戶端同時處於臨界區（互斥性） -/
def inv_f4_no_concurrent_critical (s : State) : Prop :=
  ¬ ((s.clients c0).inCritical && (s.clients c1).inCritical)

/-- F8 安全不變式：不存在兩位客戶端同時確信自己持有有效鎖 -/
def inv_f8_no_two_clients_believe_lock (s : State) : Prop :=
  ¬ ((s.clients c0).believesHoldsBool s.now && (s.clients c1).believesHoldsBool s.now)

end Redlock
