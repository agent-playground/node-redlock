// specs/oracle/real-redis.test.mjs — 反例的**端到端真 Redis** 重現。
//
// 為什麼還需要這個檔案：
//   counterexamples.test.mjs 跑在 fakeRedis.mjs 上。真 Redis 只用於
//   lua-parity.test.mjs 驗證「假 Redis 的 script 語意是否忠實」——也就是說
//   反例本身從未端到端跑在真 Redis 上。本檔補上這一層，針對**會破壞互斥**
//   的三項（F3 / F4 / F8）用真 Redis 重跑一次。
//
// 三個獨立節點的模擬方式：同一個 Redis 伺服器的 db 0 / 1 / 2。
//   → key 空間、TTL、持久化都各自獨立，對這三段 script 而言等價於三個實例。
//   ⚠️ 但它們**共用同一個 process 與同一個時鐘**，因此這不是真正獨立的節點；
//      「節點之間時鐘不同步」這類假設無法用這種方式測（那正是 F9 的範疇）。
//
// 需要 Docker：
//   docker run -d --rm -p 6399:6379 --name redlock-oracle-redis redis:7-alpine
// 若連不上 Redis，本檔的測試會 graceful skip。
//
// 執行：node --test specs/oracle/real-redis.test.mjs

import test from "node:test";
import assert from "node:assert/strict";

import Redis from "ioredis";
import Redlock from "../../dist/esm/index.js";
import { sleep } from "./fakeRedis.mjs";

const PORT = Number(process.env.ORACLE_REDIS_PORT ?? 6399);
const HOST = process.env.ORACLE_REDIS_HOST ?? "127.0.0.1";
const RES = "r";
const QUORUM = 2;
const drift = (d) => Math.round(0.01 * d) + 2;

/** 三個獨立節點 = 同一個 Redis 的三個 db。 */
function makeRealNodes() {
  return [0, 1, 2].map((db) => new Redis({ host: HOST, port: PORT, db, lazyConnect: true }));
}

async function connectAll(nodes) {
  for (const n of nodes) await n.connect();
}

async function flushAll(nodes) {
  for (const n of nodes) await n.flushdb();
}

async function tryConnect() {
  const probe = new Redis({ host: HOST, port: PORT, lazyConnect: true, maxRetriesPerRequest: 1 });
  try {
    await probe.connect();
    await probe.ping();
    probe.disconnect();
    return true;
  } catch {
    try { probe.disconnect(); } catch {}
    return false;
  }
}

async function pollUntil(pred, timeoutMs, label) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (await pred()) return true;
    await sleep(10);
  }
  throw new Error(`pollUntil 逾時（${label}，${timeoutMs}ms）`);
}

const available = await tryConnect();
const skip = !available;
if (skip) console.error(`[real-redis] 連不上 Redis ${HOST}:${PORT} —— 全部略過。`);

/** 真正持有該 value 的節點數（直接向真 Redis 查詢）。 */
async function realCoverage(nodes, value) {
  let n = 0;
  for (const node of nodes) if ((await node.get(RES)) === value) n += 1;
  return n;
}

// ---------------------------------------------------------------------------
// F3 — 節點遺失 key（Kleppmann）→ client 仍相信自己持有，真實覆蓋率已跌破 quorum
// 對應 Quint: INV_VIOLATED_quorumCoverageDecay
// ---------------------------------------------------------------------------
test("真 Redis / F3: 兩節點遺失 key 後，client 仍相信自己持有而覆蓋率 < quorum", { skip }, async () => {
  const nodes = makeRealNodes();
  await connectAll(nodes);
  await flushAll(nodes);
  const redlock = new Redlock(nodes);

  const duration = 5_000;
  const lock = await redlock.acquire([RES], duration);
  assert.equal(await realCoverage(nodes, lock.value), 3, "先決條件：三節點都持有");

  // 模擬兩個節點崩潰重啟、遺失尚未同步的 key（Kleppmann）
  await nodes[0].del(RES);
  await nodes[1].del(RES);

  assert.ok(lock.expiration > Date.now(), "client 仍然相信自己持有有效鎖");
  const coverage = await realCoverage(nodes, lock.value);
  assert.equal(coverage, 1, "真 Redis 上的實際覆蓋率剩 1");
  assert.ok(coverage < QUORUM, `真實覆蓋率 ${coverage} < quorum ${QUORUM} → 靜默失去 quorum`);

  for (const n of nodes) n.disconnect();
});

// ---------------------------------------------------------------------------
// F8 — 同一時刻有兩個 client 相信自己持有鎖（Kleppmann 的原始主張）
// 對應 Quint: INV_VIOLATED_twoClientsBelieveLock
// ---------------------------------------------------------------------------
test("真 Redis / F8: 兩個 client 同時相信自己持有鎖", { skip }, async () => {
  const nodes = makeRealNodes();
  await connectAll(nodes);
  await flushAll(nodes);
  const redlock = new Redlock(nodes);

  const duration = 5_000;
  // 先讓 node3（db2）被「別人的鎖」佔住一段時間，使 A 只拿到 2 個節點（剛好 quorum）
  await nodes[2].set(RES, "FOREIGN", "PX", 300);

  const a = await redlock.acquire([RES], duration, { retryCount: 0 });
  assert.equal(await realCoverage(nodes, a.value), 2, "先決條件：A 只拿到 2 節點");

  // node1（db0）崩潰重啟、遺失未同步的 key
  await nodes[0].del(RES);

  // 等 node3 的外來鎖過期，讓 B 有機會湊到 quorum
  await sleep(400);

  const b = await redlock.acquire([RES], duration, { retryCount: 0 });

  assert.ok(a.expiration > Date.now(), "A 仍然相信自己持有有效鎖");
  assert.ok(b.expiration > Date.now(), "B 也相信自己持有有效鎖");
  assert.notEqual(a.value, b.value, "兩把鎖的 value 不同 → 兩個不同的持有者");
  const aCoverage = await realCoverage(nodes, a.value);
  assert.ok(aCoverage < QUORUM, `A 的真實覆蓋率 ${aCoverage} < quorum ${QUORUM}`);

  for (const n of nodes) n.disconnect();
});

// ---------------------------------------------------------------------------
// F4 — 兩個 client 的臨界區重疊（abort 是諮詢式的）
// 對應 Quint: INV_VIOLATED_concurrentCriticalSections（承載安全性結論的那一條）
// ---------------------------------------------------------------------------
test("真 Redis / F4: 兩個 client 的臨界區實際重疊", { skip }, async () => {
  const nodes = makeRealNodes();
  await connectAll(nodes);
  await flushAll(nodes);

  const duration = 400; // using() 要求 duration - 100 >= automaticExtensionThreshold
  const redlock = new Redlock(nodes, {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 150,
  });

  let aInside = false;
  let aSignal = null;
  const pA = redlock.using([RES], duration, async (signal) => {
    aSignal = signal;
    aInside = true;
    await sleep(1_200); // 遠長於 duration：鎖會在臨界區執行途中失效
    aInside = false;
    return "A";
  });

  await pollUntil(async () => aInside, 2_000, "A 進入臨界區");

  // 兩個節點遺失 key → A 的後續續期必然失敗 → 鎖到期 → abort 被設定
  // （對應模型中的 failExtend；用真 Redis 的 DEL 製造，不需注入假延遲）
  await nodes[0].del(RES);
  await nodes[1].del(RES);

  await pollUntil(async () => aSignal !== null && aSignal.aborted, 5_000, "A 的 abort signal 被設定");
  assert.equal(aInside, true, "abort 之後 A 仍在臨界區內（signal 不被強制執行）");

  // B 進場前確認 A 的 key 已全部消失
  await pollUntil(
    async () => (await Promise.all(nodes.map((n) => n.get(RES)))).every((v) => v === null),
    5_000,
    "A 的節點 key 全部消失"
  );

  let bEnteredWhileAInside = false;
  const pB = redlock.using([RES], duration, async () => {
    bEnteredWhileAInside = aInside; // 關鍵觀測
    await sleep(60);
    return "B";
  });

  // A 最後必然以 release 失敗收場（鎖早已失效，RELEASE 刪不到 key）→ 那是 F7
  const [a, b] = await Promise.all([pA.catch((e) => e), pB]);
  assert.equal(b, "B", "B 正常完成");
  assert.equal(bEnteredWhileAInside, true, "B 進入臨界區時 A 仍在臨界區內 → 互斥被破壞");
  assert.equal(aSignal.aborted, true, "A 的 signal 全程為 aborted");
  assert.ok(a instanceof Error, "A 的 using() 最終以 release 失敗收場（F7 的另一面）");

  for (const n of nodes) n.disconnect();
});

// ---------------------------------------------------------------------------
// 陰性對照 — 沒有節點遺失 key 時，真 Redis 上不會出現第二個持有者
// ---------------------------------------------------------------------------
test("真 Redis / 陰性對照: 沒有節點崩潰時，第二個 client 拿不到 quorum", { skip }, async () => {
  const nodes = makeRealNodes();
  await connectAll(nodes);
  await flushAll(nodes);
  const redlock = new Redlock(nodes);

  const duration = 5_000;
  await nodes[2].set(RES, "FOREIGN", "PX", 300);

  const a = await redlock.acquire([RES], duration, { retryCount: 0 });
  assert.equal(await realCoverage(nodes, a.value), 2);

  // 關鍵差異：**不**讓 node1 遺失 key
  await sleep(400);

  let error = null;
  try {
    await redlock.acquire([RES], duration, { retryCount: 0 });
  } catch (e) {
    error = e;
  }
  assert.ok(error !== null, "B 無法取得 quorum（node1/node2 仍被 A 持有）");
  assert.ok(a.expiration > Date.now(), "A 仍是唯一的持有者");

  for (const n of nodes) n.disconnect();
});
