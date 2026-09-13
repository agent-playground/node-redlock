import test from "ava";
import type { Redis as Client } from "ioredis";
import Redlock, { ExecutionError } from "./index.js";

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

interface KeyEntry {
  value: string;
  expiresAt: number;
}

class MockRedisClient {
  public store = new Map<string, KeyEntry>();
  public delayMs = 0;
  public failExtend = false;
  public failRelease = false;

  private _entry(key: string): KeyEntry | undefined {
    const e = this.store.get(key);
    if (!e) return undefined;
    if (e.expiresAt <= Date.now()) {
      this.store.delete(key);
      return undefined;
    }
    return e;
  }

  public get(key: string): string | null {
    const e = this._entry(key);
    return e ? e.value : null;
  }

  public set(key: string, value: string, ttlMs: number): void {
    this.store.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  public evalsha(): Promise<number> {
    throw new Error("NOSCRIPT No matching script.");
  }

  public async eval(
    script: string,
    numKeys: number,
    args: (string | number)[]
  ): Promise<number> {
    if (this.delayMs > 0) {
      await sleep(this.delayMs);
    }

    const keys = args.slice(0, numKeys).map(String);
    const argv = args.slice(numKeys).map(String);

    if (
      script.includes("ACQUIRE_SCRIPT") ||
      script.includes("Create or update the entry")
    ) {
      const lockValue = argv[0];
      const ttl = Number(argv[1]);

      for (const key of keys) {
        const e = this._entry(key);
        if (e && e.value !== lockValue) {
          return 0;
        }
      }

      for (const key of keys) {
        this.set(key, lockValue, ttl);
      }
      return keys.length;
    }

    if (
      script.includes("EXTEND_SCRIPT") ||
      script.includes('redis.call("get", key) ~= ARGV[1]')
    ) {
      if (this.failExtend) {
        return 0;
      }
      const lockValue = argv[0];
      const ttl = Number(argv[1]);

      for (const key of keys) {
        const e = this._entry(key);
        if (!e || e.value !== lockValue) {
          return 0;
        }
      }

      for (const key of keys) {
        this.set(key, lockValue, ttl);
      }
      return keys.length;
    }

    if (
      script.includes("RELEASE_SCRIPT") ||
      script.includes("Only remove entries for *this* lock value")
    ) {
      if (this.failRelease) {
        return 0;
      }
      const lockValue = argv[0];
      let deleted = 0;
      for (const key of keys) {
        const e = this._entry(key);
        if (e && e.value === lockValue) {
          this.store.delete(key);
          deleted++;
        }
      }
      return deleted;
    }

    throw new Error("Unknown script in mock");
  }
}

function makeClients(n: number): MockRedisClient[] {
  return Array.from({ length: n }, () => new MockRedisClient());
}

test("F1 fix: acquire() throws ExecutionError when round-trip takes longer than validity", async (t) => {
  const clients = makeClients(3);
  for (const c of clients) {
    c.delayMs = 100;
  }

  const redlock = new Redlock(clients as unknown as Client[]);
  const duration = 50; // duration 50ms, delay 100ms -> validity < 0

  await t.throwsAsync(
    async () => {
      await redlock.acquire(["test-resource"], duration);
    },
    {
      instanceOf: ExecutionError,
      message:
        /The lock validity time has elapsed before quorum was achieved\./,
    }
  );

  // Compensation release must have cleaned up the acquired keys
  for (const c of clients) {
    t.is(
      c.get("test-resource"),
      null,
      "Partial key must be released on failure"
    );
  }
});

test("F5 fix: extend() throws ExecutionError when extension round-trip exceeds validity", async (t) => {
  const clients = makeClients(3);
  const redlock = new Redlock(clients as unknown as Client[]);

  const lock = await redlock.acquire(["extend-resource"], 500);
  t.true(lock.expiration > Date.now(), "Lock initially valid");

  // Inject delay exceeding duration
  for (const c of clients) {
    c.delayMs = 120;
  }

  await t.throwsAsync(
    async () => {
      await lock.extend(60);
    },
    {
      instanceOf: ExecutionError,
      message:
        /The lock validity time has elapsed before extension was achieved\./,
    }
  );
});

test("F2 fix: retry is NOT blocked by keys left by the client's own previous attempt", async (t) => {
  const clients = makeClients(3);

  // Client 2 and 3 occupied by a foreign lock for 50ms
  clients[1].set("retry-resource", "FOREIGN", 50);
  clients[2].set("retry-resource", "FOREIGN", 50);

  const redlock = new Redlock(clients as unknown as Client[]);

  // Attempt 1: succeeds on client 0, fails on 1 and 2 (no quorum).
  // Attempt 2: retry after 60ms when foreign locks expire.
  // Prior to fix, client 0 would be blocked by its own key from attempt 1!
  const lock = await redlock.acquire(["retry-resource"], 2000, {
    retryCount: 2,
    retryDelay: 60,
    retryJitter: 0,
  });

  t.truthy(lock, "Acquire succeeded on retry without self-blocking");
  t.is(clients[0].get("retry-resource"), lock.value);
  t.is(clients[1].get("retry-resource"), lock.value);
  t.is(clients[2].get("retry-resource"), lock.value);
});

test.serial(
  "F6 fix: using() cleans up all timers and leaves no unhandled timeout after return",
  async (t) => {
    const clients = makeClients(3);
    const redlock = new Redlock(clients as unknown as Client[], {
      retryCount: 0,
      retryDelay: 0,
      retryJitter: 0,
      automaticExtensionThreshold: 50,
    });

    const duration = 200;
    let extendStartedResolve: () => void;
    const extendStarted = new Promise<void>((r) => (extendStartedResolve = r));

    // Delay extend slightly so routine can return while extend is in flight
    for (const c of clients) {
      const origEval = c.eval.bind(c);
      c.eval = async (script, numKeys, args) => {
        if (
          script.includes("EXTEND_SCRIPT") ||
          script.includes('redis.call("get", key) ~= ARGV[1]')
        ) {
          extendStartedResolve();
          await sleep(60);
        }
        return origEval(script, numKeys, args);
      };
    }

    // Track global setTimeout / clearTimeout
    const activeTimers = new Set<NodeJS.Timeout>();
    const origSetTimeout = globalThis.setTimeout;
    const origClearTimeout = globalThis.clearTimeout;

    globalThis.setTimeout = ((
      fn: (...args: unknown[]) => void,
      ms?: number,
      ...args: unknown[]
    ) => {
      const handle = origSetTimeout(() => {
        activeTimers.delete(handle);
        fn(...args);
      }, ms);
      activeTimers.add(handle);
      return handle;
    }) as typeof setTimeout;

    globalThis.clearTimeout = ((handle?: NodeJS.Timeout) => {
      if (handle) activeTimers.delete(handle);
      return origClearTimeout(handle);
    }) as typeof clearTimeout;

    const baseline = new Set(activeTimers);

    try {
      const result = await redlock.using(
        ["leak-resource"],
        duration,
        async () => {
          await extendStarted;
          return "ROUTINE_DONE";
        }
      );

      t.is(result, "ROUTINE_DONE");

      // Give microtasks and in-flight handlers a moment to settle
      await sleep(80);

      const leaked = [...activeTimers].filter((h) => !baseline.has(h));
      t.is(leaked.length, 0, "No lingering timers after using() completes");
    } finally {
      globalThis.setTimeout = origSetTimeout;
      globalThis.clearTimeout = origClearTimeout;
    }
  }
);

test("F7 fix: using() propagates routine error without masking when release fails", async (t) => {
  const clients = makeClients(3);
  for (const c of clients) {
    c.failRelease = true; // release will fail
  }

  const redlock = new Redlock(clients as unknown as Client[], {
    retryCount: 0,
    automaticExtensionThreshold: 100,
  });

  const customError = new Error("Custom Business Logic Error");

  await t.throwsAsync(
    async () => {
      await redlock.using(["err-resource"], 500, async () => {
        throw customError;
      });
    },
    {
      is: customError,
      message: "Custom Business Logic Error",
    }
  );
});

test("F7 fix: using() propagates signal.error when abort occurs rather than release error", async (t) => {
  const clients = makeClients(3);
  for (const c of clients) {
    c.failExtend = true;
    c.failRelease = true;
  }

  const redlock = new Redlock(clients as unknown as Client[], {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
    automaticExtensionThreshold: 50,
  });

  // Lock duration 160ms, extension fails -> abort signal triggered
  await t.throwsAsync(
    async () => {
      await redlock.using(["abort-resource"], 160, async (signal) => {
        await sleep(250); // wait for extension to fail and lock to expire
        t.true(signal.aborted, "Signal aborted");
        return "ROUTINE_FINISH";
      });
    },
    {
      instanceOf: ExecutionError,
      message:
        /The operation was unable to achieve a quorum during its retry window\./,
    }
  );
});

test("settings pass-through: using() passes per-call settings to extend", async (t) => {
  const clients = makeClients(3);
  // Redlock configured with retryCount 5
  const redlock = new Redlock(clients as unknown as Client[], {
    retryCount: 5,
    retryDelay: 200,
  });

  let extendAttemptsCount = 0;
  for (const c of clients) {
    const origEval = c.eval.bind(c);
    c.eval = async (script, numKeys, args) => {
      if (
        script.includes("EXTEND_SCRIPT") ||
        script.includes('redis.call("get", key) ~= ARGV[1]')
      ) {
        extendAttemptsCount++;
        return 0; // force failure
      }
      return origEval(script, numKeys, args);
    };
  }

  const duration = 200;
  // using() with retryCount: 0
  await t.throwsAsync(
    async () => {
      await redlock.using(
        ["settings-resource"],
        duration,
        {
          retryCount: 0,
          retryDelay: 0,
          retryJitter: 0,
          automaticExtensionThreshold: 50,
        },
        async () => {
          await sleep(250);
        }
      );
    },
    { instanceOf: Error }
  );

  // If settings were not passed, retryCount 5 would try 6 times across 3 nodes = 18 attempts.
  // With retryCount: 0 passed, it tries exactly 1 attempt across 3 nodes = 3 attempts.
  t.is(
    extendAttemptsCount,
    3,
    "Only 1 attempt was made on each client due to retryCount: 0"
  );
});
