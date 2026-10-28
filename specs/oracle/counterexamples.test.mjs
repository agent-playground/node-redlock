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
//
// ---------------------------------------------------------------------------
// 本檔的測試分成兩類，標題已標示，不要混為一談：
//
//   【已修復】F1 / F5 / F2 / F6 —— 這些反例描述的是**修復前**的行為
//       （base 38f792e，也就是上游 mike-marcacci/node-redlock 至今的行為）。
//       對應的 ITF 軌跡保留在 specs/traces/ 作為歷史證據，但本檔的測試已改為
//       **回歸測試**：斷言修復後的正確行為。把它們對修復前的 dist 執行會失敗
//       ——那正是它們的判別力來源。
//
//   【仍成立】F3 / F4 / F4(b) / F4(c) / F7 / F8 —— 這些反例在修復後**依然重現**，
//       因為它們不是實作瑕疵，而是演算法層與環境假設層的性質（節點遺失 key、
//       諮詢式 abort 的 TOCTOU、無 fencing token）。修復沒有、也不該碰它們。
// ---------------------------------------------------------------------------

import test from "node:test";
import assert from "node:assert/strict";

import Redlock, { ExecutionError } from "../../dist/esm/index.js";
import {
  isExtendScript,
  makeNodes,
  mergedLog,
  resetNodes,
  sleep,
} from "./fakeRedis.mjs";

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
// F1【已修復】— acquire() 缺 validity <= 0 檢查
// 對應 Quint: INV_VIOLATED_acquireReturnsExpiredLock
// 軌跡：specs/traces/INV_VIOLATED_acquireReturnsExpiredLock.itf.json
//
// 修復前：往返超過 TTL 時，acquire() 仍回傳一個 expiration 已在過去的 Lock，
//         而且**完全不報錯**——呼叫端以為自己持有鎖。
// 修復後：偵測到 validity 已耗盡即丟 ExecutionError，並走既有的補償釋放路徑。
//
// 判別力：對修復前的 dist 執行會失敗（它不丟錯，而是回傳過期鎖）。
// ---------------------------------------------------------------------------
test("F1（已修復）: acquire() 在往返超過 TTL 時丟 ExecutionError，不再回傳過期鎖", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  // 模擬慢網路／GC pause：Redis 端在 120ms 後才回應
  for (const n of nodes) n.delayMs = 120;

  const duration = 60;
  const t0 = Date.now();
  let lock;
  let error;
  try {
    lock = await redlock.acquire([RES], duration);
  } catch (e) {
    error = e;
  }
  const t1 = Date.now();

  // 先決條件：本測試真的落在 F1 的情境裡（往返超過 TTL、模型述詞成立）。
  // 模型的述詞：acquireBelieved(cs) = acquireStart + DURATION - DRIFT。
  assert.ok(t1 - t0 >= 120, `acquire 應該真的慢（實際 ${t1 - t0}ms）`);
  assert.ok(
    t0 + duration - drift(duration) <= t1,
    "先決條件：acquireBelieved <= now（F1 的反例條件成立）"
  );

  // 回歸斷言：不得再回傳過期鎖，而要明確失敗
  assert.equal(lock, undefined, "不得回傳任何 Lock");
  assert.ok(error instanceof ExecutionError, `應丟 ExecutionError，實際 ${error}`);
  assert.match(
    error.message,
    /The lock validity time has elapsed before quorum was achieved\./
  );

  // 補償釋放確實被觸發（修復前這條路徑根本不會執行，因為 acquire 成功了）
  const log = mergedLog(nodes);
  assert.ok(
    log.release.length >= nodes.length,
    `失敗路徑應對每個節點嘗試釋放（實際 ${log.release.length} 次）`
  );
  assert.equal(
    nodes.every((n) => n.get(RES) === null),
    true,
    "所有節點上都不得留下本次的殘留 key"
  );
});

// ---------------------------------------------------------------------------
// F5【已修復】— extend() 的 check-then-act；replacement Lock 同樣缺 validity 檢查
// 對應 Quint: INV_VIOLATED_extendReturnsExpiredLock
// 軌跡：specs/traces/INV_VIOLATED_extendReturnsExpiredLock.itf.json
//
// 修復前：extend() 回傳一個已過期的 replacement Lock，且不報錯。
// 修復後：丟 ExecutionError，並主動釋放這把已經失效的鎖（避免它繼續佔住節點
//         直到 TTL 自然到期）。
// ---------------------------------------------------------------------------
test("F5（已修復）: extend() 在慢往返下丟 ExecutionError，並釋放已失效的鎖", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  const duration = 60;
  const lock = await redlock.acquire([RES], duration);
  assert.ok(lock.expiration > Date.now(), "先決條件：取得時鎖仍有效");

  resetNodes(nodes); // 只觀測 extend 階段產生的記錄

  // 讓 extend 的往返超過 TTL
  for (const n of nodes) n.delayMs = 120;
  const t0 = Date.now();
  let replacement;
  let error;
  try {
    replacement = await lock.extend(duration);
  } catch (e) {
    error = e;
  }
  const t1 = Date.now();

  assert.ok(t1 - t0 >= 120, `extend 應該真的慢（實際 ${t1 - t0}ms）`);
  assert.ok(
    t0 + duration - drift(duration) <= t1,
    "先決條件：replacement 的 validity 已耗盡（F5 的反例條件成立）"
  );

  assert.equal(replacement, undefined, "不得回傳任何 replacement Lock");
  assert.ok(error instanceof ExecutionError, `應丟 ExecutionError，實際 ${error}`);
  assert.match(
    error.message,
    /The lock validity time has elapsed before extension was achieved\./
  );

  // 修復後的 extend 失敗路徑會主動釋放；修復前完全不會呼叫 release
  const log = mergedLog(nodes);
  assert.ok(
    log.release.length >= nodes.length,
    `失敗路徑應對每個節點嘗試釋放（實際 ${log.release.length} 次）`
  );
});

// ---------------------------------------------------------------------------
// F2【已修復】— ACQUIRE_SCRIPT 原本用 exists 比對，不問 key 是誰的
// 對應 Quint: witness selfBlockedByOwnValue / bothClientsFailWithinRetryWindow
//
// 修復前：同一次 acquire() 的第 2 次 attempt，會被**自己第 1 次 attempt 寫下的
//         key** 擋住（`exists` 不看 value）——演算法明確要求「重試前釋放所有
//         實例」，實作兩者都沒做。
// 修復後：ACQUIRE_SCRIPT 只在「存在且 value 不同」時才擋；同 value 視為自己的
//         殘留 key，放行並覆寫 TTL。等價於演算法要求的「重試前先清乾淨」。
//
// 判別力（兩條互相獨立）：
//   1. 不得再出現任何 selfBlocked
//   2. 必須真的走到「node1 上帶著自己的舊 key 再次取得」這條路徑（reacquiredOwn）
// 對修復前的 dist 執行時兩條都會失敗——注意假 Redis 是**依 script 原文**決定
// 語意的（見 fakeRedis.mjs 檔頭），所以這個紅綠對照是有效的。
// ---------------------------------------------------------------------------
test("F2（已修復）: 重試不再被『自己上一輪留下的 key』擋住", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes);

  // node2 / node3 被別人佔住，但只佔 120ms；node1 空閒。
  // attempt1（t≈0）  ：只拿到 node1（1 票 < quorum 2）→ 失敗
  // attempt2（t≈200）：FOREIGN 已到期，而 node1 上還留著自己上一輪的 key
  nodes[1].occupy(RES, "FOREIGN", 120);
  nodes[2].occupy(RES, "FOREIGN", 120);

  const lock = await redlock.acquire([RES], 2000, {
    retryCount: 2,
    retryDelay: 200,
    retryJitter: 0,
  });

  const log = mergedLog(nodes);

  // --- 回歸斷言（一）：自我阻塞已消失 ---
  const selfBlocked = log.acquire.filter((e) => e.selfBlocked);
  assert.equal(
    selfBlocked.length,
    0,
    `不得再被自己的 value 擋住，實際 blocker=${selfBlocked.map((e) => e.blocker)}`
  );

  // --- 回歸斷言（二）：必須真的經過「覆寫自己舊 key」的路徑 ---
  // 少了這條，本測試在「第 2 次 attempt 根本沒碰到 node1」時也會綠燈，
  // 就變成沒有判別力的斷言。
  const node1 = log.acquire.filter((e) => e.node === "node1");
  assert.ok(
    node1.some((e) => e.granted && !e.reacquiredOwn),
    "attempt1 在 node1 上是全新取得"
  );
  assert.ok(
    node1.some((e) => e.granted && e.reacquiredOwn),
    "attempt2 在**同一顆** node1 上覆寫了自己的舊 key（F2 修復的路徑）"
  );

  // --- 對照：別人的鎖仍然擋得住，一般競爭沒有被這個修復削弱 ---
  const foreignBlocked = log.acquire.filter((e) => e.blocker === "FOREIGN");
  assert.ok(foreignBlocked.length > 0, "node2/node3 曾由 FOREIGN 擋住（一般競爭）");
  assert.ok(
    foreignBlocked.every((e) => e.granted === false),
    "被 FOREIGN 擋住時一律不得放行"
  );

  // --- 結果：三個節點最終都持有本次的 value ---
  assert.equal(
    nodes.every((n) => n.get(RES) === lock.value),
    true,
    "三節點都持有本次 acquire 的 value"
  );

  // NOSCRIPT fallback 路徑確實被走到（src/index.ts:574-595）
  assert.ok(log.evalsha > 0 && log.eval > 0, "evalsha→NOSCRIPT→eval fallback 被執行");
});

// ---------------------------------------------------------------------------
// F6【已修復】— using() 的 timer 洩漏：routine 在「續期仍在途中」時結束
// 對應建模決策 9：F6 刻意不在 Quint 內建模（需 JS event loop），改用本測試涵蓋。
//
// 修復前的機制：
//   queue() 設定 timeout → extend() 一開頭把 timeout 設成 undefined → await 續期
//   → 成功後再呼叫 queue() 設一個**新的** timeout。
//   若 routine 在 await 期間結束，finally 的 `if (timeout) clearTimeout` 已經
//   無事可做（timeout 是 undefined），但 finally 又 await extension，
//   於是 queue() 在清理之後才跑，留下一個沒有人清除的 timer——它會在鎖**已經
//   釋放之後**才觸發 extend()。
// 修復後：用 `running` 旗標讓在途的 extend() 完成後不再 queue()，並在 await
//   extension 之後再清一次 timeout。
//
// 本測試**不靠時序猜測**：routine 等到「續期真的開始了」才返回，因此
// 「返回時續期在途」是確定成立的，而非靠 sleep 碰運氣。
// ---------------------------------------------------------------------------
test("F6（已修復）: routine 在續期途中結束 → using() 返回後不留任何 timer", async () => {
  const nodes = makeNodes(3);
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 100,
  });

  const duration = 300;

  // --- 追蹤全域 setTimeout，辨識「本次呼叫期間建立且仍然存活」的 timer ---
  //
  // 注意：**測試手法本身不得建立任何 setTimeout**。若用 sleep() 來製造
  // 「續期在途」的時間窗，那個 sleep 的 timer 也會被算進殘留數——修復前的
  // `leaked > 0` 就可能只是測到自己的 sleep，而不是 Redlock 洩漏的 timer。
  // 因此這裡改用一道**明確的閘門**（純 Promise，不含計時器）來控制續期何時完成。
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
  let openExtendGate;
  const extendGate = new Promise((r) => (openExtendGate = r));
  let extendInFlightAtReturn = false;
  let extendFinished = false;
  let extendIntercepted = 0;

  // 讓 EXTEND 這條路徑停在閘門上，並在它「已經開始」時通知 routine。
  // 判別式必須用 isExtendScript()：修復後的 ACQUIRE_SCRIPT 也含有 EXTEND 的
  // 比對字串，若只比對那一段，acquire 會被誤判成續期，整個情境根本不會發生。
  for (const n of nodes) {
    const originalEval = n.eval.bind(n);
    n.eval = async (script, numKeys, args) => {
      const isExtend = isExtendScript(script);
      if (isExtend) {
        extendIntercepted += 1;
        markExtendStarted();
        await extendGate; // 續期在途的時間窗（不使用計時器）
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
      // 讓 using() 先進入「routine 已結束、續期仍在途」的狀態，再放行續期。
      // setImmediate 不是 setTimeout，不會被計入殘留 timer。
      setImmediate(openExtendGate);
      return "ROUTINE_DONE";
    });

    const leaked = [...pending].filter((h) => !baseline.has(h));

    // 先決條件：本測試真的落在 F6 的情境裡。三條缺一不可，否則
    // 「沒有殘留 timer」會在**從未發生續期**的情況下也成立（假綠燈）。
    assert.ok(
      extendIntercepted > 0,
      "先決條件：自動續期確實被觸發（若為 0，代表判別式誤判或時序沒對上）"
    );
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

    // 回歸斷言：修復前這裡會留下 1 個沒人清除的 timer
    assert.equal(
      leaked.length,
      0,
      `using() 返回後不得留下任何 timer，實際殘留 ${leaked.length} 個`
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
