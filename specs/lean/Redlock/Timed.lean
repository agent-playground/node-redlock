/-!
# Redlock.Timed

此模組實作 Redlock 的多時鐘/時間自動機語意模型（對齊 specs/uppaal/redlock_f9.xml）：
解決 Quint 因「全域單一時鐘」而無法表達 F9（時鐘突跳）的建模缺陷。

核心設計：
1. 雙層時鐘解耦：
   - `realNow : Nat`：Redis 伺服器與物理世界的真實單調時間（決定 key 的真實 TTL）
   - `clientSkew : ClientId → Nat`：客戶端本地時鐘 Date.now() 的突跳偏差量（往後跳即時鐘變慢/時間倒流）
2. 節點與客戶端對手計數器：
   - `nodeJumps : Nat`：節點時鐘突跳次數（在 F9 證明中必須嚴格恆等於 0）
   - `clientJumps : Nat`：客戶端時鐘突跳次數
3. 對齊 UPPAAL 基準參數：
   - DURATION = 20 (ms)
   - DRIFT = 2 (ms)
   - 客戶端最大租約上限 = DURATION - DRIFT = 18 (ms)
-/

namespace Redlock.Timed

abbrev NodeId := Fin 3
abbrev ClientId := Fin 2

def DURATION : Nat := 20
def DRIFT : Nat := 2
def MAX_LEASE : Nat := DURATION - DRIFT -- 18 ms

structure TimedNode where
  val : Nat
  expiresAt : Nat -- 依真實時間 realNow 判定
  deriving Repr, DecidableEq

def TimedNode.hasValidKey (n : TimedNode) (realNow : Nat) : Bool :=
  n.val ≠ 0 ∧ n.expiresAt > realNow

inductive ClientPhase where
  | IDLE
  | REQ_NODE
  | IN_CRITICAL
  deriving Repr, DecidableEq

structure TimedClient where
  phase : ClientPhase
  lockVal : Nat
  acquiredAt : Nat -- 記錄取鎖時的真實時間戳
  grantedNodes : List NodeId
  deriving Repr, DecidableEq

structure TimedState where
  realNow : Nat
  nodeJumps : Nat
  clientJumps : Nat
  clientSkew : ClientId → Nat
  nodes : NodeId → TimedNode
  clients : ClientId → TimedClient

def initTimedNode : TimedNode :=
  { val := 0, expiresAt := 0 }

def initTimedClient : TimedClient :=
  { phase := ClientPhase.IDLE
  , lockVal := 0
  , acquiredAt := 0
  , grantedNodes := []
  }

def initTimedState : TimedState :=
  { realNow := 0
  , nodeJumps := 0
  , clientJumps := 0
  , clientSkew := fun _ => 0
  , nodes := fun _ => initTimedNode
  , clients := fun _ => initTimedClient
  }

/-- 客戶端根據本地時鐘量測到的持有經過時間：(realNow - acquiredAt) - skew -/
def TimedClient.perceivedElapsedTime (c : TimedClient) (realNow : Nat) (skew : Nat) : Nat :=
  (realNow - c.acquiredAt) - skew

/-- 客戶端是否仍在自認合法的租約窗口內 -/
def TimedClient.believesInLease (c : TimedClient) (realNow : Nat) (skew : Nat) : Bool :=
  c.phase == ClientPhase.IN_CRITICAL && (c.perceivedElapsedTime realNow skew ≤ MAX_LEASE)

inductive TimedAction where
  | advanceRealTime (dt : Nat)
  | clientClockJump (c : ClientId) (delta : Nat)
  | nodeClockJump (n : NodeId) (delta : Nat)
  | startAcquire (c : ClientId) (token : Nat)
  | grantNode (c : ClientId) (n : NodeId)
  | enterCritical (c : ClientId)
  | leaveCritical (c : ClientId)
  deriving Repr, DecidableEq

/-- 決定性多時鐘操作轉移函數 -/
def nextTimedState (s : TimedState) (a : TimedAction) : Option TimedState :=
  match a with
  | TimedAction.advanceRealTime dt =>
      some { s with realNow := s.realNow + dt }

  | TimedAction.clientClockJump c delta =>
      -- 客戶端時鐘往後跳 delta（Date.now() 倒流，導致量測時間變小）
      some { s with
        clientJumps := s.clientJumps + 1
        clientSkew := fun i => if i == c then s.clientSkew i + delta else s.clientSkew i }

  | TimedAction.nodeClockJump _n _delta =>
      -- 節點時鐘向前突跳（F8 變體）
      some { s with nodeJumps := s.nodeJumps + 1 }

  | TimedAction.startAcquire c token =>
      let client := s.clients c
      if client.phase == ClientPhase.IDLE && token > 0 then
        some { s with clients := fun i =>
          if i == c then
            { client with
                phase := ClientPhase.REQ_NODE
                lockVal := token
                acquiredAt := s.realNow
                grantedNodes := [] }
          else s.clients i }
      else none

  | TimedAction.grantNode c n =>
      let client := s.clients c
      let node := s.nodes n
      -- 節點判斷：key 不存在、key 是自己的、或 key 依 realNow 已過期
      if client.phase == ClientPhase.REQ_NODE &&
         (! node.hasValidKey s.realNow || node.val == client.lockVal) &&
         (! client.grantedNodes.contains n) then
        some { s with
          nodes := fun j =>
            if j == n then { val := client.lockVal, expiresAt := s.realNow + DURATION }
            else s.nodes j
          clients := fun i =>
            if i == c then { client with grantedNodes := n :: client.grantedNodes }
            else s.clients i }
      else none

  | TimedAction.enterCritical c =>
      let client := s.clients c
      -- 必須取得 Quorum (≥ 2) 且自身量到的耗時未超租約
      if client.phase == ClientPhase.REQ_NODE &&
         client.grantedNodes.length ≥ 2 &&
         client.perceivedElapsedTime s.realNow (s.clientSkew c) ≤ MAX_LEASE then
        some { s with clients := fun i =>
          if i == c then { client with phase := ClientPhase.IN_CRITICAL }
          else s.clients i }
      else none

  | TimedAction.leaveCritical c =>
      let client := s.clients c
      if client.phase == ClientPhase.IN_CRITICAL then
        some { s with clients := fun i =>
          if i == c then { client with phase := ClientPhase.IDLE, lockVal := 0, grantedNodes := [] }
          else s.clients i }
      else none

inductive TimedStep (s : TimedState) (a : TimedAction) (s' : TimedState) : Prop where
  | of_next : nextTimedState s a = some s' → TimedStep s a s'

inductive TimedReachable : TimedState → Prop where
  | init : TimedReachable initTimedState
  | step {s s' : TimedState} {a : TimedAction} : TimedReachable s → TimedStep s a s' → TimedReachable s'

def c0 : ClientId := ⟨0, by decide⟩
def c1 : ClientId := ⟨1, by decide⟩
def n0 : NodeId := ⟨0, by decide⟩
def n1 : NodeId := ⟨1, by decide⟩
def n2 : NodeId := ⟨2, by decide⟩

/-- 互斥性：不存在兩位客戶端同時在臨界區且自認持鎖有效 -/
def inv_timed_mutual_exclusion (s : TimedState) : Prop :=
  ¬ ((s.clients c0).believesInLease s.realNow (s.clientSkew c0) &&
     (s.clients c1).believesInLease s.realNow (s.clientSkew c1))

end Redlock.Timed
