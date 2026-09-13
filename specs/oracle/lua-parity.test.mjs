// specs/oracle/lua-parity.test.mjs — 假 Redis 與真 Redis 的**語意對等**驗證。
//
// 為什麼需要這個檔案：
//   counterexamples.test.mjs 依賴 fakeRedis.mjs，而後者是以 JS 重新實作三段
//   Lua script 的語意。若那份重寫有誤，反例測試就變成循環論證——「我的假 Redis
//   有這個行為，所以真實程式碼有這個行為」。本檔以**真實的 Redis** 執行
//   **真實的 script 原文**（由 Redlock 建構子保存於 redlock.scripts.*.value，
//   即 src/index.ts:12-58 的 ACQUIRE/EXTEND/RELEASE），逐情境比對兩者的回傳值。
//
// 需要 Docker：
//   docker run -d --rm -p 6399:6379 --name redlock-oracle-redis redis:7-alpine
// 若連不上 Redis，本檔的測試會 graceful skip（不讓整份測試套件紅燈）。
//
// 執行：node --test specs/oracle/lua-parity.test.mjs

import test from "node:test";
import assert from "node:assert/strict";

import Redis from "ioredis";
import Redlock from "../../dist/esm/index.js";
import { FakeRedis, sleep } from "./fakeRedis.mjs";

const PORT = Number(process.env.ORACLE_REDIS_PORT ?? 6399);
const HOST = process.env.ORACLE_REDIS_HOST ?? "127.0.0.1";
const PREFIX = "oracle:parity:";

/** 取得真實的 script 原文（由 Redlock 建構子保存，未經任何修改）。 */
function realScripts() {
  const probe = new Redlock([new FakeRedis("probe")]);
  return probe.scripts;
}

async function tryConnect() {
  const client = new Redis({ host: HOST, port: PORT, lazyConnect: true, maxRetriesPerRequest: 1 });
  try {
    await client.connect();
    await client.ping();
    return client;
  } catch {
    try { client.disconnect(); } catch {}
    return null;
  }
}

/** 真 Redis 驅動：與 FakeRedis 相同的呼叫介面，方便逐情境對照。 */
function realDriver(client, scripts) {
  return {
    kind: "real-redis",
    evalScript: (which, keys, args) => client.eval(scripts[which].value, keys.length, [...keys, ...args]),
    set: (key, value, ttlMs) => client.set(key, value, "PX", ttlMs),
    del: (key) => client.del(key),
    get: (key) => client.get(key),
    pttl: (key) => client.pttl(key),
  };
}

/** 假 Redis 驅動：同一介面。 */
function fakeDriver(node, scripts) {
  return {
    kind: "fake",
    evalScript: (which, keys, args) => node.eval(scripts[which].value, keys.length, [...keys, ...args]),
    set: async (key, value, ttlMs) => node.set(key, value, ttlMs),
    del: async (key) => node.del(key),
    get: async (key) => node.get(key),
    pttl: async (key) => {
      const e = node.store.get(key);
      return e ? e.expiresAt - Date.now() : -2;
    },
  };
}

const client = await tryConnect();
const skip = client === null;
if (skip) {
  const msg = `[lua-parity] 連不上 Redis ${HOST}:${PORT}`;
  // CI 下**不得**略過：node --test 在 skip 時仍然 exit 0，那會讓
  // 「假 Redis 的忠實度」這道**防止循環論證**的保證靜默消失——同一種假綠燈。
  if (process.env.CI) {
    throw new Error(`${msg}；CI 環境下必須提供 Redis（設定 ORACLE_REDIS_PORT）`);
  }
  console.error(`${msg} —— 全部略過。`);
}

const S = realScripts();

// 每個情境：準備好初始 key 狀態 → 對兩邊執行同一 script → 比對回傳值。
const SCENARIOS = [
  {
    name: "ACQUIRE 空 key → 回 #KEYS 並寫入",
    script: "acquireScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [],
    expected: 1,
  },
  {
    name: "ACQUIRE key 已存在（**同 value**）→ 回 0（F2 的自我阻塞語意）",
    script: "acquireScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [{ key: "a", value: "V1", ttl: 5000 }],
    expected: 0,
  },
  {
    name: "ACQUIRE key 已存在（**不同 value**）→ 回 0",
    script: "acquireScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [{ key: "a", value: "OTHER", ttl: 5000 }],
    expected: 0,
  },
  {
    name: "ACQUIRE 多 key 只要一個存在 → 回 0（all-or-nothing）",
    script: "acquireScript",
    keys: ["a", "b"],
    argv: ["V1", "5000"],
    seed: [{ key: "b", value: "OTHER", ttl: 5000 }],
    expected: 0,
  },
  {
    name: "ACQUIRE key 已**過期** → 視為不存在，回 #KEYS",
    script: "acquireScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [{ key: "a", value: "V1", ttl: 40 }],
    waitMs: 90,
    expected: 1,
  },
  {
    name: "EXTEND value 相符 → 回 #KEYS（續期成功）",
    script: "extendScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [{ key: "a", value: "V1", ttl: 5000 }],
    expected: 1,
  },
  {
    name: "EXTEND value 不符 → 回 0",
    script: "extendScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [{ key: "a", value: "OTHER", ttl: 5000 }],
    expected: 0,
  },
  {
    name: "EXTEND key 已遺失（**不修復**）→ 回 0（F3 的語意）",
    script: "extendScript",
    keys: ["a"],
    argv: ["V1", "5000"],
    seed: [],
    expected: 0,
  },
  {
    name: "RELEASE value 相符 → 回刪除數 1",
    script: "releaseScript",
    keys: ["a"],
    argv: ["V1"],
    seed: [{ key: "a", value: "V1", ttl: 5000 }],
    expected: 1,
  },
  {
    name: "RELEASE value 不符 → 回 0（**不會誤刪別人的鎖**）",
    script: "releaseScript",
    keys: ["a"],
    argv: ["V1"],
    seed: [{ key: "a", value: "OTHER", ttl: 5000 }],
    expected: 0,
  },
  {
    name: "RELEASE key 不存在 → 回 0",
    script: "releaseScript",
    keys: ["a"],
    argv: ["V1"],
    seed: [],
    expected: 0,
  },
];

test("假 Redis 與真 Redis 對三段 script 的語意一致", { skip }, async (t) => {
  for (const sc of SCENARIOS) {
    await t.test(sc.name, async () => {
      const results = {};
      for (const driver of [realDriver(client, S), fakeDriver(new FakeRedis("node1"), S)]) {
        const keys = sc.keys.map((k) => PREFIX + driver.kind + ":" + k);
        for (const k of keys) await driver.del(k);
        for (const sd of sc.seed) {
          const key = PREFIX + driver.kind + ":" + (sc.keys[sd.key === "a" ? 0 : 1] ?? sd.key);
          await driver.set(key, sd.value, sd.ttl);
        }
        if (sc.waitMs) await sleep(sc.waitMs);
        results[driver.kind] = Number(await driver.evalScript(sc.script, keys, sc.argv));
      }
      assert.equal(
        results["real-redis"],
        sc.expected,
        `真 Redis 的結果不符預期（情境：${sc.name}）`
      );
      assert.equal(
        results.fake,
        results["real-redis"],
        `假 Redis 與真 Redis 不一致：fake=${results.fake} real=${results["real-redis"]}`
      );
    });
  }
});

test("EXTEND 真的會把 TTL 往後推（不只回傳值相同）", { skip }, async () => {
  for (const driver of [realDriver(client, S), fakeDriver(new FakeRedis("node1"), S)]) {
    const key = PREFIX + driver.kind + ":ttl";
    await driver.del(key);
    await driver.set(key, "V1", 300);
    const before = await driver.pttl(key);
    await driver.evalScript("extendScript", [key], ["V1", "5000"]);
    const after = await driver.pttl(key);
    assert.ok(
      after > before,
      `${driver.kind}: EXTEND 後 TTL 應變長（before=${before} after=${after}）`
    );
    assert.ok(after > 4000, `${driver.kind}: 續期後的 TTL 應接近新的 5000ms（實際 ${after}）`);
  }
});

test.after(async () => {
  if (client) {
    const keys = await client.keys(PREFIX + "*");
    if (keys.length) await client.del(keys);
    client.disconnect();
  }
});
