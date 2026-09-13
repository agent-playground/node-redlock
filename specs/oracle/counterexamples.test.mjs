// specs/oracle/counterexamples.test.mjs — 反例神諭測試。
//
// 目的：證明 specs/redlock.qnt 找到的反例**不是模型的假象**，而是真實
// src/index.ts（此處用 dist/esm/index.js）的可觀測行為。
//
// 執行：node --test specs/oracle/
//
// 每個測試的標題都標明它對應的 Quint 不變式／witness 名稱。
// 斷言的內容刻意與模型中的述詞一致（例如「擋住我的 key 是不是我自己的」、
// 「相信自己持有的人數」、「真實覆蓋率是否跌破 quorum」）。

import test from "node:test";
import assert from "node:assert/strict";

import Redlock, { ExecutionError } from "../../dist/esm/index.js";
import { makeNodes, mergedLog, resetNodes, sleep } from "./fakeRedis.mjs";

const RES = "r";
const drift = (duration) => Math.round(0.01 * duration) + 2;
/** N=3 的 quorum（src/index.ts 的 floor(n/2)+1）。 */
const QUORUM = 2;

async function pollUntil(pred, timeoutMs, label) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (pred()) return true;
    await sleep(5);
  }
  throw new Error(`pollUntil 逾時（${label}，${timeoutMs}ms）`);
}

// ---------------------------------------------------------------------------
// F1 — acquire() 缺 validity <= 0 檢查
// 對應 Quint: INV_VIOLATED_acquireReturnsExpiredLock
// ---------------------------------------------------------------------------
test("F1: acquire() 在往返超過 TTL 時回傳『已過期卻無錯誤』的鎖", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  // 模擬慢網路／GC pause：Redis 端在 120ms 後才回應
  for (const n of nodes) n.delayMs = 120;

  const duration = 60;
  const t0 = Date.now();
  const lock = await redlock.acquire([RES], duration); // 不得拋錯
  const t1 = Date.now();

  assert.ok(t1 - t0 >= 120, `acquire 應該真的慢（實際 ${t1 - t0}ms）`);

  // 模型的述詞：acquireBelieved(cs) = acquireStart + DURATION - DRIFT。
  // 注意 start 是程式碼在 _attemptOperation 內部取的（src/index.ts:481），
  // 會 >= 這裡的 t0，故只斷言在數毫秒的排程裕度內相符。
  const expected = t0 + duration - drift(duration);
  assert.ok(
    Math.abs(lock.expiration - expected) <= 5,
    `expiration 的算法與模型一致（實際 ${lock.expiration}，預期約 ${expected}）`
  );

  // 反例本體（一）：回傳的鎖已經過期，而 acquire() 沒有任何報錯
  assert.ok(
    lock.expiration <= t1,
    `鎖已過期（expiration=${lock.expiration} <= now=${t1}）卻照樣回傳`
  );
  // 反例本體（二）：expiration 明顯**早於**回應抵達時間
  // → 它是由送出前的 start 算出的，而非回應抵達時間。這是 F1 的根因。
  assert.ok(
    t1 - lock.expiration >= 30,
    `expiration 應遠早於回應抵達（差距僅 ${t1 - lock.expiration}ms）`
  );
});

// ---------------------------------------------------------------------------
// F5 — extend() 的 check-then-act；replacement Lock 同樣缺 validity 檢查
// 對應 Quint: INV_VIOLATED_extendReturnsExpiredLock
// ---------------------------------------------------------------------------
test("F5: extend() 在慢往返下回傳已過期的 replacement Lock", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  const duration = 60;
  const lock = await redlock.acquire([RES], duration);
  assert.ok(lock.expiration > Date.now(), "先決條件：取得時鎖仍有效");

  // 讓 extend 的往返超過 TTL
  for (const n of nodes) n.delayMs = 120;
  const t0 = Date.now();
  const replacement = await lock.extend(duration); // 不得拋錯
  const t1 = Date.now();

  assert.ok(t1 - t0 >= 120, `extend 應該真的慢（實際 ${t1 - t0}ms）`);

  // 同 F1：start 由程式碼內部取得（src/index.ts:481），只斷言數毫秒裕度內相符
  const expected = t0 + duration - drift(duration);
  assert.ok(
    Math.abs(replacement.expiration - expected) <= 5,
    `replacement 的算法與模型一致（實際 ${replacement.expiration}，預期約 ${expected}）`
  );
  assert.ok(
    replacement.expiration <= t1,
    `replacement 已過期（expiration=${replacement.expiration} <= now=${t1}）`
  );
  assert.ok(
    t1 - replacement.expiration >= 30,
    `replacement 的 expiration 應遠早於回應抵達（差距僅 ${t1 - replacement.expiration}ms）`
  );
});

// ---------------------------------------------------------------------------
// F2 — ACQUIRE_SCRIPT 用 exists 比對，不問 key 是誰的
// 對應 Quint: witness selfBlockedByOwnValue / bothClientsFailWithinRetryWindow
// ---------------------------------------------------------------------------
test("F2: retry 被『自己上一輪留下的 key』擋住（selfBlocked）", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  // node2 / node3 被別人佔住；node1 空閒
  nodes[1].occupy(RES, "FOREIGN", 60_000);
  nodes[2].occupy(RES, "FOREIGN", 60_000);

  let error;
  try {
    // retryCount=1 → 兩次 attempt，第二次會撞到第一次留下的自己的 key
    await redlock.acquire([RES], 60_000, { retryCount: 1, retryDelay: 10, retryJitter: 0 });
  } catch (e) {
    error = e;
  }

  assert.ok(error instanceof ExecutionError, "兩次 attempt 都無法達成 quorum");
  const log = mergedLog(nodes);
  const selfBlocked = log.acquire.filter((e) => e.selfBlocked);
  assert.ok(
    selfBlocked.length > 0,
    "至少一次被『自己的 value』擋住（= 模型的 isSelfBlock）"
  );
  // 擋住我的不是 FOREIGN（別人的鎖），而是我自己上一輪寫進去的 value
  assert.ok(
    selfBlocked.every((e) => e.blocker !== "FOREIGN"),
    `擋住者應為自己的 value，實際 blocker=${selfBlocked.map((e) => e.blocker)}`
  );
  // NOSCRIPT fallback 路徑確實被走到（src/index.ts:574-595）
  assert.ok(log.evalsha > 0 && log.eval > 0, "evalsha→NOSCRIPT→eval fallback 被執行");

  // --- 判別力：擋住我的必須是**同一顆**我上一輪寫過的節點 ---
  // 「acquire 遇到既有 key 就失敗」是鎖的定義，不是缺陷；能證明 F2 的只有
  // 「第 1 次 attempt 拿到 node1，第 2 次 attempt 被 node1 上自己的 key 擋住」。
  const node1 = log.acquire.filter((e) => e.node === "node1");
  assert.ok(node1.some((e) => e.granted), "第 1 次 attempt 在 node1 上取得（vote for）");
  assert.ok(
    node1.some((e) => e.selfBlocked),
    "第 2 次 attempt 在**同一顆** node1 上被自己的 value 擋住"
  );
  // 反之，node2/node3 的擋住者是 FOREIGN（別人的鎖），不是自己 —— 兩類必須分開，
  // 否則「自我阻塞」與「一般競爭」在斷言上無法區分。
  const foreignBlocked = log.acquire.filter((e) => e.blocker === "FOREIGN");
  assert.ok(foreignBlocked.length > 0, "node2/node3 由 FOREIGN 擋住（一般競爭）");

  // --- 忠實度界線（Q9b）：危害只存在於「單次 acquire() 的重試窗口之內」---
  // acquire() 的失敗路徑會做補償釋放（src/index.ts:330-340），所以殘留 key
  // **不會**存活到呼叫返回之後。模型若允許 client 停在 IDLE 且帶著殘留 key
  // 自由停留，就是一個真實到不了的過度近似。
  assert.equal(nodes[0].get(RES), null, "補償釋放已清掉 node1 的殘留 key");
  assert.ok(
    log.release.some((e) => e.node === "node1" && e.deleted === 1),
    "node1 的殘留 key 是由 acquire() 的補償釋放清除的"
  );
});

// ---------------------------------------------------------------------------
// F6 — using() 的 timer 洩漏：routine 在「續期仍在途中」時結束
// 對應建模決策 9：F6 刻意不在 Quint 內建模（需 JS event loop），改用本測試涵蓋。
//
// 機制（src/index.ts:716-765）：
//   queue() 設定 timeout → extend() 一開頭把 timeout 設成 undefined → await 續期
//   → 成功後再呼叫 queue() 設一個**新的** timeout。
//   若 routine 在 await 期間結束，finally 的 `if (timeout) clearTimeout` 已經
//   無事可做（timeout 是 undefined），但 finally 又 await extension，
//   於是 queue() 在清理之後才跑，留下一個沒有人清除的 timer。
//
// 本測試**不靠時序猜測**：routine 等到「續期真的開始了」才返回，因此
// 「返回時續期在途」是確定成立的，而非靠 sleep 碰運氣。
// ---------------------------------------------------------------------------
test("F6: routine 在續期途中結束 → using() 返回後仍有殘留 timer", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 100,
  });

  const duration = 300;

  // --- 追蹤全域 setTimeout，辨識「本次呼叫期間建立且仍然存活」的 timer ---
  const pending = new Set();
  const origSetTimeout = globalThis.setTimeout;
  const origClearTimeout = globalThis.clearTimeout;
  globalThis.setTimeout = (fn, ms, ...rest) => {
    const handle = origSetTimeout(
      () => {
        pending.delete(handle);
        fn(...rest);
      },
      ms,
      ...rest
    );
    pending.add(handle);
    return handle;
  };
  globalThis.clearTimeout = (handle) => {
    pending.delete(handle);
    return origClearTimeout(handle);
  };

  let markExtendStarted;
  const extendStarted = new Promise((r) => (markExtendStarted = r));
  let extendInFlightAtReturn = false;
  let extendFinished = false;

  // 讓 EXTEND 這條路徑變慢，並在它「已經開始」時通知 routine
  for (const n of nodes) {
    const originalEval = n.eval.bind(n);
    n.eval = async (script, numKeys, args) => {
      const isExtend = script.includes('redis.call("get", key) ~= ARGV[1]');
      if (isExtend) {
        markExtendStarted();
        await sleep(80); // 續期在途的時間窗
        const r = await originalEval(script, numKeys, args);
        extendFinished = true;
        return r;
      }
      return originalEval(script, numKeys, args);
    };
  }

  const baseline = new Set(pending);

  try {
    await redlock.using([RES], duration, async () => {
      await extendStarted; // 等到自動續期真的開始
      extendInFlightAtReturn = !extendFinished; // 返回時它仍在途
      return "ROUTINE_DONE";
    });

    const leaked = [...pending].filter((h) => !baseline.has(h));

    assert.equal(
      extendInFlightAtReturn,
      true,
      "先決條件：routine 返回時，自動續期確實還在途中"
    );
    assert.equal(
      nodes.every((n) => n.get(RES) === null),
      true,
      "鎖已在所有節點上釋放"
    );
    assert.ok(
      leaked.length > 0,
      `using() 返回後仍有 ${leaked.length} 個殘留 timer（洩漏）——` +
        `它們會在鎖已釋放之後才觸發 extend()`
    );
  } finally {
    globalThis.setTimeout = origSetTimeout;
    globalThis.clearTimeout = origClearTimeout;
  }
});

// ---------------------------------------------------------------------------
// F3 — EXTEND 不修復少數節點已遺失的 key → 靜默失去 quorum
// 對應 Quint: INV_VIOLATED_quorumCoverageDecay
// ---------------------------------------------------------------------------
test("F3: 節點遺失 key 後，client 仍相信自己持有而真實覆蓋率已跌破 quorum", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  const duration = 2_000;
  const lock = await redlock.acquire([RES], duration);
  assert.equal(nodes.filter((n) => n.get(RES) === lock.value).length, 3, "先決條件：三節點都持有");

  // 兩個節點崩潰重啟、遺失未同步的 key（Kleppmann）
  nodes[0].crashLoseKey(RES);
  nodes[1].crashLoseKey(RES);

  // 模型的 believesHolds：client 相信的到期時間還沒到
  assert.ok(lock.expiration > Date.now(), "client 仍然相信自己持有有效鎖");
  // 模型的 permitsOf().size() < quorumSize
  const realCoverage = nodes.filter((n) => n.get(RES) === lock.value).length;
  assert.equal(realCoverage, 1, "真實覆蓋率剩 1 個節點");
  assert.ok(realCoverage < QUORUM, `真實覆蓋率 ${realCoverage} < quorum ${QUORUM} → 靜默失去 quorum`);
});

// ---------------------------------------------------------------------------
// F4 — abort 是諮詢式的；臨界區可以在鎖失效後繼續執行
// 對應 Quint: INV_VIOLATED_concurrentCriticalSections（承載安全性結論的那一條）
// ---------------------------------------------------------------------------
test("F4: 兩個 client 的臨界區重疊（abort 已觸發但 routine 仍在前進）", async () => {
  const nodes = makeNodes(3);

  // 注意：`using()` 的 per-call settings **不會**傳給 `lock.extend()`
  //（Lock.extend → redlock.extend(lock, duration)，未帶 settings，src/index.ts:159-161），
  // 續期用的是 **instance 層** 設定。因此這裡必須在建構子設定，
  // 否則預設 retryCount=10/retryDelay=200 會讓每次續期多花 2-3 秒。
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 100,
  });

  const duration = 300; // using() 要求 duration - 100 >= automaticExtensionThreshold

  // 讓自動續期一律失敗 → A 的鎖會自然到期（對應模型的 failExtend）
  for (const n of nodes) n.failExtend = true;

  let aInside = false;
  let aSignal = null;
  const pA = redlock.using([RES], duration, async (signal) => {
    aSignal = signal;
    aInside = true;
    await sleep(900); // 遠長於 duration：鎖會在臨界區執行途中失效
    aInside = false;
    return "A";
  });

  await pollUntil(() => aInside, 2_000, "A 進入臨界區");
  await pollUntil(() => aSignal !== null && aSignal.aborted, 3_000, "A 的 abort signal 被設定");

  // A 仍在前進 —— 這正是「諮詢式」的證據
  assert.equal(aInside, true, "abort 之後 A 仍在臨界區內（signal 不被強制執行）");

  // B 進場前必須確定 A 的 key 已全部隨 TTL 消失（EXTEND 失敗所以沒有被續期），
  // 否則 B 會因為節點仍被佔用而拿不到 quorum——那測到的就不是 F4 了。
  await pollUntil(
    () => nodes.every((n) => !n.exists(RES)),
    2_000,
    "A 的節點 key 全部過期"
  );

  let bEnteredWhileAInside = false;
  const pB = redlock.using([RES], duration, async () => {
    bEnteredWhileAInside = aInside; // 關鍵觀測：B 進來時 A 是否還在裡面
    await sleep(40);
    return "B";
  });

  // A 最後**必然**以 release 失敗收場：鎖早已過期，RELEASE_SCRIPT 在每個節點
  // 都刪不到 key（回傳 0 < keys.length）→ 沒有 quorum → ExecutionError 自 finally
  // 拋出。那是 F7 的另一面，由 F7 的測試單獨主張；此處不讓它掩蓋 F4 的觀測。
  const [a, b] = await Promise.all([pA.catch((e) => e), pB]);
  assert.equal(b, "B", "B 正常完成");
  assert.ok(
    a instanceof ExecutionError,
    `A 的 using() 應以 release 失敗收場（F7），實際 ${a}`
  );
  assert.equal(
    bEnteredWhileAInside,
    true,
    "B 進入臨界區時 A 仍在臨界區內 → 互斥被破壞"
  );
  assert.equal(aSignal.aborted, true, "A 的 signal 在整個過程中都是 aborted");

  // 收尾：關掉故障注入並等殘留的非同步活動結束，避免 unhandledRejection
  for (const n of nodes) n.failExtend = false;
  await sleep(60);
});

// ---------------------------------------------------------------------------
// F7 — release() 失敗自 finally 拋出，吃掉 routine 的回傳值與 signal.error
// 對應 Quint: INV_VIOLATED_releaseErrorMasksAbort
// ---------------------------------------------------------------------------
test("F7: release 失敗吃掉 routine 的正常回傳值（且 abort 已發生）", async () => {
  const nodes = makeNodes(3);
  // 同 F4：續期走 instance 設定（using 的 per-call settings 不會傳進 extend）
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 100,
  });

  const duration = 300;

  // 續期失敗（鎖到期 → abort 被設定）且 release 也失敗
  for (const n of nodes) {
    n.failExtend = true;
    n.failRelease = true;
  }

  let routineReturned = null;
  let signal = null;
  let error = null;
  try {
    await redlock.using([RES], duration, async (s) => {
      signal = s;
      await sleep(700);
      routineReturned = "ROUTINE_RESULT"; // routine 成功完成
      return routineReturned;
    });
  } catch (e) {
    error = e;
  }

  assert.equal(routineReturned, "ROUTINE_RESULT", "routine 本身成功完成並產出了結果");
  assert.ok(error instanceof ExecutionError, `using() 應以 ExecutionError 失敗，實際 ${error}`);
  assert.equal(signal.aborted, true, "abort 已經發生（signal.error 本應被回報）");
  // 模型的述詞：releaseFailed ∧ signalAbort → routine 的結果與 abort 原因都被遮蔽
  assert.ok(
    !(error && error.message === "ROUTINE_RESULT"),
    "回傳值被 release 的例外覆蓋"
  );
});

// ---------------------------------------------------------------------------
// F8 — 節點崩潰遺失 key（Kleppmann）：兩個 client 同時相信自己持鎖
// 對應 Quint: INV_VIOLATED_twoClientsBelieveLock
// ---------------------------------------------------------------------------
test("F8: 節點遺失 key 後，兩個 client 同時相信自己持有鎖", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  const duration = 2_000;
  // node3 先被「別人的鎖」佔住一小段時間，讓 A 只拿到 2 個節點（剛好 quorum）
  nodes[2].occupy(RES, "FOREIGN", 150);

  const a = await redlock.acquire([RES], duration, { retryCount: 0 });
  assert.equal(nodes.filter((n) => n.get(RES) === a.value).length, 2, "先決條件：A 只拿到 2 節點");

  // node1 崩潰重啟、遺失未同步的 key
  nodes[0].crashLoseKey(RES);

  // 等 node3 的外來鎖過期，讓 B 有機會湊到 quorum
  await sleep(200);

  const b = await redlock.acquire([RES], duration, { retryCount: 0 });

  // 模型的 believerCount(...) >= 2：兩人同時相信自己持有
  assert.ok(a.expiration > Date.now(), "A 仍然相信自己持有有效鎖");
  assert.ok(b.expiration > Date.now(), "B 也相信自己持有有效鎖");
  assert.notEqual(a.value, b.value, "兩把鎖的 value 不同 → 是兩個不同的持有者");
  // 同一個狀態下，A 的真實覆蓋率已跌破 quorum（F3 與 F8 是同一條路徑）
  const aCoverage = nodes.filter((n) => n.get(RES) === a.value).length;
  assert.ok(aCoverage < QUORUM, `A 的真實覆蓋率 ${aCoverage} < quorum ${QUORUM}`);
});

// ---------------------------------------------------------------------------
// 陰性對照 — 沒有崩潰時，同樣的設定**不會**產生第二個持有者
// 這個測試證明上一個測試的違反來自「節點遺失 key」，而不是測試手法本身。
// ---------------------------------------------------------------------------
test("陰性對照: 沒有節點崩潰時，第二個 client 拿不到 quorum", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  const duration = 2_000;
  nodes[2].occupy(RES, "FOREIGN", 150);

  const a = await redlock.acquire([RES], duration, { retryCount: 0 });
  assert.equal(nodes.filter((n) => n.get(RES) === a.value).length, 2);

  // 關鍵差異：**不**讓 node1 遺失 key
  await sleep(200); // node3 的外來鎖過期，但 node1/node2 仍被 A 持有

  let error = null;
  try {
    await redlock.acquire([RES], duration, { retryCount: 0 });
  } catch (e) {
    error = e;
  }
  assert.ok(error instanceof ExecutionError, "B 無法取得 quorum（只有 node3 空閒）");
  assert.ok(a.expiration > Date.now(), "A 仍是唯一的持有者");
});

// ===========================================================================
// F4 的加強版：routine 三態中的 CHECKED_LATE 與 CHECKED
//
// 原本的 F4 用的是「routine 完全不檢查 signal」的版本。那個版本會被合理反駁成
// 「README 早就叫你要檢查，是你自己的錯」。下面兩個測試才是關鍵：
//   (b) 檢查了就派送 —— 檢查與派送之間沒有 await，abort 沒有機會被觀察到，
//       派送早於鎖失效、效果卻晚於鎖失效。這是**不可約的 TOCTOU**。
//   (c) 每次 await 之後都複查 —— 在途操作的效果仍然落地，但不再做新的工作。
//       所以「照 README 做」只能**界定**暴露，不能**消除**它。
//
// 時序設計：`failExtend` 讓續期失敗 → 鎖自然到期 → abort。
// `delayMs = 20` 是必要的：`using()` 的 extend() 在失敗後會在
// `lock.expiration > Date.now()` 期間**遞迴重試**（src/index.ts:734-736），
// 沒有延遲的話那是一段純 microtask 迴圈，會餓死 timer、讓 pollUntil 失效。
// ===========================================================================

/** 建立 F4(b)/(c) 共用的情境：3 節點、續期必失敗、每次往返 20ms。 */
function makeF4Scenario() {
  const nodes = makeNodes(3);
  for (const n of nodes) {
    n.failExtend = true;
    n.delayMs = 20;
  }
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 100,
  });
  return { nodes, redlock, duration: 300 };
}

test("F4(b): routine 檢查了 signal.aborted 才派送，效果仍落在鎖失效之後", async () => {
  const { nodes, redlock, duration } = makeF4Scenario();

  let enteredAt = 0;
  let dispatchedAt = 0;
  let effectLandedAt = 0;
  let checkPassed = false;
  let inside = false;
  let signalRef = null;

  const pA = redlock.using([RES], duration, async (signal) => {
    signalRef = signal;
    enteredAt = Date.now();
    inside = true;

    await pollUntil(() => Date.now() >= enteredAt + 230, 5_000, "A 的派送時點");

    // ↓↓↓ 檢查與派送**緊鄰**，中間沒有任何 await —— 這是本測試的重點
    checkPassed = !signal.aborted;
    if (signal.aborted) throw signal.error;
    dispatchedAt = Date.now();

    await sleep(90); // 「寫入」的往返：跨越鎖失效
    effectLandedAt = Date.now();
    inside = false;
    return "A";
  });

  let abortedAt = 0;
  const pAbortWatch = (async () => {
    await pollUntil(() => signalRef !== null && signalRef.aborted, 6_000, "A 的 abort");
    abortedAt = Date.now();
  })();

  // B 等 A 的 key 全部過期（EXTEND 失敗所以沒有被續期）後進場。
  // 必須先確認 A 真的拿到鎖，否則「沒有 key」會在 A 取得之前就成立，
  // B 會和 A 搶鎖、兩邊都拿不到 quorum。
  await pollUntil(() => enteredAt !== 0, 3_000, "A 進入臨界區");
  await pollUntil(() => nodes.every((n) => !n.exists(RES)), 5_000, "A 的 key 全部過期");
  let bEnteredWhileAInside = false;
  const pB = redlock.using([RES], duration, async () => {
    bEnteredWhileAInside = inside;
    await sleep(40);
    return "B";
  });

  const [a, b] = await Promise.all([pA.catch((e) => e), pB, pAbortWatch.catch(() => {})]);

  assert.equal(b, "B", "B 正常完成");
  assert.equal(checkPassed, true, "A **確實**做了 signal.aborted 檢查，且檢查當時尚未 abort");
  assert.ok(dispatchedAt < abortedAt, `派送(${dispatchedAt}) 早於 abort(${abortedAt})`);
  assert.ok(
    effectLandedAt > abortedAt,
    `效果落地(${effectLandedAt}) 晚於 abort(${abortedAt}) → 檢查無法阻止它`
  );
  assert.equal(
    bEnteredWhileAInside,
    true,
    "B 進入臨界區時 A 仍在臨界區內 → 互斥被破壞（且 A 並非沒檢查）"
  );
  assert.ok(a instanceof ExecutionError, `A 以 release 失敗收場（F7），實際 ${a}`);
});

test("F4(c) 對照: 每次 await 後都複查 → 在途效果仍落地，但不再做新的臨界工作", async () => {
  const { nodes, redlock, duration } = makeF4Scenario();

  let enteredAt = 0;
  let effectLandedAt = 0;
  let recheckSawAbort = false;
  let didMoreWork = false;
  let signalRef = null;

  const pA = redlock.using([RES], duration, async (signal) => {
    signalRef = signal;
    enteredAt = Date.now();

    await pollUntil(() => Date.now() >= enteredAt + 230, 5_000, "A 的派送時點");
    if (signal.aborted) throw signal.error; // 檢查（通過）
    await sleep(90); // 一次在途操作，跨越鎖失效

    effectLandedAt = Date.now();
    // ↓ 每次 await 之後都複查 —— 這是 README 建議的寫法
    recheckSawAbort = signal.aborted;
    if (signal.aborted) throw signal.error;

    didMoreWork = true; // 不應被執行到
    return "A";
  });

  let abortedAt = 0;
  const pAbortWatch = (async () => {
    await pollUntil(() => signalRef !== null && signalRef.aborted, 6_000, "A 的 abort");
    abortedAt = Date.now();
  })();

  // 同 F4(b)：先確認 A 真的拿到鎖，否則 B 會在 A 之前就搶鎖
  await pollUntil(() => enteredAt !== 0, 3_000, "A 進入臨界區");
  await pollUntil(() => nodes.every((n) => !n.exists(RES)), 5_000, "A 的 key 全部過期");
  const pB = redlock.using([RES], duration, async () => {
    await sleep(40);
    return "B";
  });

  const [a, b] = await Promise.all([pA.catch((e) => e), pB, pAbortWatch.catch(() => {})]);

  assert.equal(b, "B", "B 正常完成");
  assert.equal(recheckSawAbort, true, "複查確實觀察到 abort");
  assert.ok(
    effectLandedAt > abortedAt,
    `即使逐次複查，單一在途操作的效果仍落地於 abort 之後` +
      `（落地 ${effectLandedAt} > abort ${abortedAt}）→ 只能界定、無法消除`
  );
  assert.equal(didMoreWork, false, "複查之後 A 沒有再做任何新的臨界工作");
  assert.ok(a instanceof ExecutionError, `A 以 release 失敗收場（F7），實際 ${a}`);
});
