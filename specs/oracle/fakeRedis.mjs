// specs/oracle/fakeRedis.mjs — 可控的假 Redis 客戶端，供反例神諭測試使用。
//
// 目的：把 specs/redlock.qnt 找到的反例，用**真實的 src/index.ts**（編譯後的
// dist/esm/index.js）重現一次。為此需要一個能被控制時序、能注入故障、
// 且忠實實作三段 Lua script 語意的 Redis 替身。
//
// 忠實度聲明（重要）：
//   本檔以 JS 重新實作 ACQUIRE_SCRIPT / EXTEND_SCRIPT / RELEASE_SCRIPT 的語意
//   （逐行對照 src/index.ts:12-58），**不是**執行真的 Lua。它刻意保留三個關鍵
//   性質，因為反例全都建立在它們之上：
//     1. ACQUIRE 用 `exists` 判斷，**不問 key 是誰的**
//     2. EXTEND 必須「所有 key 的 value 都相符」才在該節點投贊成，且**不修復**已遺失的 key
//     3. RELEASE 只刪除 value 相符的 key，回傳「刪掉的 key 數」
//   evalsha 一律丟 NOSCRIPT，逼真實程式碼走 `eval` 的 fallback 路徑
//   （src/index.ts:574-595），因此該路徑也被測到。

const NOSCRIPT = "NOSCRIPT No matching script. Please use EVAL.";

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class FakeRedis {
  constructor(name) {
    this.name = name;
    /** @type {Map<string, {value: string, expiresAt: number}>} */
    this.store = new Map();
    // --- 故障注入 ---
    this.delayMs = 0;
    this.failExtend = false;
    this.failRelease = false;
    // --- 觀測記錄（與 Quint 模型觀測同一件事）---
    this.log = { acquire: [], extend: [], release: [], evalsha: 0, eval: 0 };
  }

  // --- 內部：key 狀態 ---
  _entry(key) {
    const e = this.store.get(key);
    if (!e) return undefined;
    if (e.expiresAt <= Date.now()) {
      this.store.delete(key);
      return undefined;
    }
    return e;
  }

  exists(key) {
    return this._entry(key) !== undefined;
  }

  get(key) {
    const e = this._entry(key);
    return e === undefined ? null : e.value;
  }

  set(key, value, ttlMs) {
    this.store.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  del(key) {
    return this.store.delete(key);
  }

  // --- 故障注入 API ---
  /** 模擬節點崩潰重啟、遺失尚未同步的 key（F8 / Kleppmann）。 */
  crashLoseKey(key) {
    this.store.delete(key);
  }

  /** 在 test 外部預先佔用一個 key（扮演「別人的鎖」）。 */
  occupy(key, value, ttlMs) {
    this.set(key, value, ttlMs);
  }

  /** 目前實際持有該 value 的 key 數（= 真實覆蓋率）。 */
  holdingCount(value, keys) {
    return keys.filter((k) => this.get(k) === value).length;
  }

  async quit() {
    return "OK";
  }

  // --- ioredis 介面 ---
  // 真實程式碼先試 evalsha，收到 NOSCRIPT 才 fallback 到 eval。
  async evalsha() {
    this.log.evalsha += 1;
    throw new Error(NOSCRIPT);
  }

  async eval(script, numKeys, args) {
    this.log.eval += 1;
    const keys = args.slice(0, numKeys);
    const argv = args.slice(numKeys);

    // 節點**先處理請求**（Lua 在抵達時執行），回應才經過網路延遲回傳。
    // 這個順序是 F1/F5 能成立的前提：key 在請求抵達時被寫入／續期，
    // 而 client 端算出的 expiration 是從「送出前」的 start 起算的。
    let result;
    if (script.includes('redis.call("exists"')) result = this._acquire(keys, argv);
    else if (script.includes('redis.call("get", key) ~= ARGV[1]')) result = this._extend(keys, argv);
    else if (script.includes('redis.pcall("del"')) result = this._release(keys, argv);
    else throw new Error(`FakeRedis: 認不得的 script：${script.slice(0, 60)}`);

    if (this.delayMs > 0) await sleep(this.delayMs); // 回應延遲
    return result;
  }

  // ACQUIRE_SCRIPT：任一 key 存在即回 0（**不問是誰的**）；否則全部 SET 並回 #KEYS
  _acquire(keys, argv) {
    const value = argv[0];
    const ttl = Number(argv[1]);
    for (const k of keys) {
      if (this.exists(k)) {
        const blocker = this.get(k);
        // 與 Quint 模型的 isSelfBlock 同一定義：擋住我的 key 是不是我自己的 value
        this.log.acquire.push({
          node: this.name,
          key: k,
          granted: false,
          blocker,
          selfBlocked: blocker === value,
        });
        return 0;
      }
    }
    for (const k of keys) this.set(k, value, ttl);
    this.log.acquire.push({ node: this.name, key: keys[0], granted: true, blocker: null, selfBlocked: false });
    return keys.length;
  }

  // EXTEND_SCRIPT：所有 key 的 value 都相符才更新；任一不符即整顆腳本回 0
  // **不對該節點做任何修復**（F3）
  _extend(keys, argv) {
    const value = argv[0];
    const ttl = Number(argv[1]);
    if (this.failExtend) {
      this.log.extend.push({ node: this.name, renewed: false, forced: true });
      return 0;
    }
    for (const k of keys) {
      if (this.get(k) !== value) {
        this.log.extend.push({ node: this.name, renewed: false, forced: false });
        return 0;
      }
    }
    for (const k of keys) this.set(k, value, ttl);
    this.log.extend.push({ node: this.name, renewed: true, forced: false });
    return keys.length;
  }

  // RELEASE_SCRIPT：只刪 value 相符的 key，回傳刪掉的數量
  _release(keys, argv) {
    const value = argv[0];
    if (this.failRelease) {
      this.log.release.push({ node: this.name, deleted: 0, forced: true });
      return 0;
    }
    let count = 0;
    for (const k of keys) {
      if (this.get(k) === value) {
        this.del(k);
        count += 1;
      }
    }
    this.log.release.push({ node: this.name, deleted: count, forced: false });
    return count;
  }
}

/** 建立 N 個獨立的假節點（模擬獨立的 Redis 實例）。 */
export function makeNodes(n) {
  return Array.from({ length: n }, (_, i) => new FakeRedis(`node${i + 1}`));
}

/** 彙總所有節點的觀測記錄。 */
export function mergedLog(nodes) {
  return {
    acquire: nodes.flatMap((n) => n.log.acquire),
    extend: nodes.flatMap((n) => n.log.extend),
    release: nodes.flatMap((n) => n.log.release),
    evalsha: nodes.reduce((a, n) => a + n.log.evalsha, 0),
    eval: nodes.reduce((a, n) => a + n.log.eval, 0),
  };
}

/** 在所有節點上重置故障注入與觀測記錄。 */
export function resetNodes(nodes) {
  for (const n of nodes) {
    n.delayMs = 0;
    n.failExtend = false;
    n.failRelease = false;
    n.log = { acquire: [], extend: [], release: [], evalsha: 0, eval: 0 };
  }
}
