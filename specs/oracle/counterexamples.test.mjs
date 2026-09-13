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
