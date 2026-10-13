# 12 — node-redlock 測試結構與 CI 設定盤點：README「建置與測試」前置分析（agent-analyze）

> **任務類型**：`agent-analyze`（factory 任務模板 `task-template-analyze.txt`；docs/20 §4 C1）——僅分析、不實作。
> **分析對象**：Issue #12（repo `agent-playground/node-redlock`，trunk `software-factory`）。
> **日期**：2026-10-13 · **目標 repo HEAD**：`b624bbf`（`software-factory`）。
> **環境**：node v22.21.1、npm 10.9.4、yarn 1.22.22、Docker 28.0.4 / Compose v2.38.2。
> **狀態**：分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。

---

## 0. 本 run 的範圍宣告（必讀）

Issue #12 的 PRD 指定**唯一**目標檔為 `README.md`，要求在 README 的 Contributing 段落補上「建置與測試」說明；Issue 的三條驗證方式（issue-check bot 對應為 `REQ-1`～`REQ-3`）全部是對**那個新段落**的驗收。

本 run 的 `task_type` 是 `agent-analyze`。依 factory 主流程與 docs/06 §4，analyze 型別**只可產出分析與方案、不得實作**；機械護欄 `factory-crosscheck --analyze-only` 的變更白名單是 `docs/**`（同一護欄的說明見 `docs/research/4-quint-spec-feasibility.md` §0）。`README.md` **不在**白名單內。

**結論**：本 run 不可能交付 README 的新段落本身。本報告因此定位為**該段落的實作前置分析**：把「測試結構、Redis 依賴、建置/測試指令、CI 檢查項目」盤點清楚，逐條核對 `REQ-1`～`REQ-3`，並在 §6 提供可直接貼進 README 的草稿與後續工作項。逐條狀態見 §7。

> 這不是「以分析替代實作」的取巧，而是護欄的必然結果：Issue 的目標檔（`README.md`）與 `agent-analyze` 的 `docs/**` 白名單互斥。此範圍差異以 §0／§7 誠實揭露，並依 factory-stop-rules #8「不自行擴大範圍」處理。

---

## 1. 結論摘要（一頁）

1. **README 目前完全沒有建置/測試說明**。`README.md:144-146` 的「Contributing」只有一行連到 `CONTRIBUTING.md`；`CONTRIBUTING.md:3-19` 有 docker compose 說明，但**缺** `build` 指令、**沒有明講測試需要 Redis**、**沒有 CI 檢查清單**。新加入者確實無法從 README 得知怎麼建置與跑測試。
2. **`package.json` 的權威指令**：`build`（`package.json:66`）= `tsc`（清 dist 後編 ESM，再編 CJS 一份）；`test`（`package.json:68`）= `cd dist/esm && ava --verbose *.test.js`。**測試跑的是編譯產物**，所以「先 build 再 test」是硬性順序。
3. **測試需要 Redis，而且不是 localhost**。測試以 docker compose 的**服務名稱**連線（`src/single.test.ts:548,550`、`src/multi.test.ts:319-328`）；`docker-compose.yml` 提供 **23 個 redis 容器**（single/multi × instance/cluster 四種拓撲）。啟動命令是 `docker compose up`（`CONTRIBUTING.md:10`）或一次性 `docker compose run --rm runner yarn test`（`CONTRIBUTING.md:18`）。在 host 直接 `yarn test` 會因服務名稱無法解析而失敗。
4. **CI 的實質檢查有 3 項**：lint、build（transpile）、test（`.github/workflows/ci.yml:21-26`），全部透過 `docker compose run ... builder/runner` 執行；另有 checkout、image cache、`docker-compose pull` 三個基礎步驟與一個 `if: always()` 的 `docker compose down`。逐條對照見 §2.4。
5. **實測發現一個會讓上述 docker 指令在現況下直接失敗的問題**（§3）：
   `installer` 服務使用 `node:16`（`docker-compose.yml:226-239`），但 devDependency `@informalsystems/quint@0.32.0`
   宣告 `engines.node >= 18`；`yarn install` 因此以 `Found incompatible module` 失敗，而 `builder`/`runner`
   的 entrypoint（`scripts/await.sh`）會永遠等不到 `node_modules/.bin/tsc`（實測 builder 容器空轉 5 分鐘）。
   **README 若照抄 `docker compose ... yarn build/test`，讀者會踩到同一個坑。** 此點必須在後續工作項一併處理（或明列為已知限制）。
6. **可建置性已實測**：在 host（node 22）以 `npx tsc`＋`npx tsc -p tsconfig.cjs.json` 建置 exit 0，且不需外部服務的 mock 測試 `src/fixes.test.ts` **9/9 綠燈**（§3.2）。需 Redis 的 `single`/`multi` E2E 依 DoD 略過。因此 §3.1 的 docker 失敗可確定是 image node 版本問題，而非程式碼問題。
7. **建議（§6）**：另開一個允許 `README.md` 的 `agent-write-docs` 工作項，把 §6.2 的草稿段落寫進 README，並納入 §6.3 的驗收條件（含 node 版本/引擎不相容的揭露方式）。本 run 只交付本報告。

---

## 2. 證據與根因：測試結構、Redis 依賴與 CI 步驟盤點

### 2.1 測試檔與拓撲盤點

| 測試檔 | 行數 | 測試案例數 | 需要的 redis 拓撲（服務名） | 備註 |
|---|---|---|---|---|
| `src/single.test.ts` | 550 | 9 × 2 namespace = **18** | `redis-single-instance`、`redis-single-cluster-1`（6 節點叢集） | `run("instance", …)`／`run("cluster", …)`（L548／L550）；其中 1 個負向案例連 `127.0.0.1`（L204-209）驗證不可達 |
| `src/multi.test.ts` | 329 | 3 × 2 namespace = **6** | `redis-multi-instance-a/b/c`、`redis-multi-cluster-a-1/b-1/c-1` | `run(...)` ×2（L317／L324）；測多數/少數節點失敗時的 quorum 行為 |
| `src/fixes.test.ts` | 574 | **9** | **無**（全部用 `MockRedisClient`，L41） | F1/F2/F5/F6/F7 與 liveness 修復的回歸測試，不需要外部服務 |
| **合計（ava）** | | **33** | | `test` script 一次跑完 `dist/esm/*.test.js` |
| `specs/oracle/*.test.mjs` | | 另計 | `lua-parity.test.mjs`、`real-redis.test.mjs` 需要 redis | 走 `node --test`，**不屬於** `yarn test`；見 `package.json:70-72` |

- `src/single.test.ts` 的 9 個案例：non-integer duration、acquire/extend/release（單一資源與多資源）、redis 不可達、自動過期、個別鎖互斥、多資源重疊互斥、`using` helper（成功路徑與互斥）。
- `src/multi.test.ts` 的 3 個案例：單一鎖生命週期、少數 client 失敗仍成功、多數 client 失敗則失敗。
- `src/fixes.test.ts` 以 `MockRedisClient` 攔截 `evalsha`（L41、L161-163），因此不需要 Redis；這是本 repo **唯一**可在 host 離線執行的測試檔。

### 2.2 建置與測試的必要條件（為什麼「直接 yarn test」不可行）

- **編譯先行**：`tsconfig.json` 的 `include: ["./src/**/*"]` 會把 `src/*.test.ts` 一起編到 `dist/esm/`；`test` script 先 `cd dist/esm`，故 `yarn build` 必須先跑。
- **ESM/CJS 雙輸出**：`build` = `tsc`（ESM，`tsconfig.json`）+ `tsc -p tsconfig.cjs.json`（CJS）。`dist/esm/package.json`（`{"type":"module"}`）與 `dist/cjs/package.json`（`{"type":"commonjs"}`）是**入版控**的關鍵檔（`git ls-files dist`），少了它們編譯產物會被 node 依 root `"type": "module"` 當成錯誤模組格式。
- **Redis 為硬依賴**：見 §2.1；測試用 docker compose 服務名解析，只有 compose 網路內可解析。
- **執行指令（現行文件）**：
  - 常駐開發：`docker compose up`（`CONTRIBUTING.md:10`；會建置、起 redis、持續重跑測試）
  - 一次性測試：`docker compose run --rm runner yarn test`（`CONTRIBUTING.md:18`）
  - CI 等價：`docker compose run --rm --no-TTY runner yarn test`（`ci.yml:26`）
- **`runner` 服務自動備妥 Redis**：`docker-compose.yml:260-...` 的 `runner` 以 `depends_on` 列出全部 23 個 redis 服務，因此 `docker compose run --rm runner yarn test` 會先拉起依賴。

### 2.3 README / CONTRIBUTING / CI 的落差（根因）

| 面向 | `README.md`（現況） | `CONTRIBUTING.md`（現況） | `ci.yml`（現況） |
|---|---|---|---|
| build 指令 | **無** | **無** | `docker compose run --rm --no-TTY builder yarn build`（L24） |
| test 指令 | **無** | `docker compose run --rm runner yarn test`（L18） | `docker compose run --rm --no-TTY runner yarn test`（L26） |
| 「需要 Redis」 | **未提** | 只說 compose 會初始化 redis（L3），未明講測試硬依賴 | runner `depends_on` 23 個 redis 服務（`docker-compose.yml:260` 以下） |
| CI 檢查清單 | **無** | **無** | lint / build / test（L21-26） |
| 過時殘留 | — | — | `.travis.yml:8` 仍寫 `script: npm run test-ci`，該 script 已不存在於 `package.json` |

**根因**：README 的 Contributing 段落自始只是一行連結，`CONTRIBUTING.md` 與 CI 的實際內容從未被回填，而 `.travis.yml` 是未清理的舊 CI 殘留。三者疊加造成「看 README 學跑測試」的入口完全缺失；`CONTRIBUTING.md` 雖有片段資訊，卻不足以回答「測試需要什麼」。Issue #12 要補的正是這個缺口。

### 2.4 REQ 逐條證據核對

#### REQ-1：新段落列出的命令與 `package.json` 的 `build`、`test` script 一致

權威來源：

- `package.json:66` → `"build": "rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json"`
- `package.json:68` → `"test": "cd dist/esm && ava --verbose *.test.js"`

核對表（草稿段落所列命令 ↔ `package.json`）：

| 草稿列出的命令 | 出處 | 是否一致 |
|---|---|---|
| `yarn build` | `package.json:66` | 一致（`yarn build` ≡ `npm run build`） |
| `yarn test` | `package.json:68` | 一致 |
| `docker compose run --rm --no-TTY builder yarn build` | `ci.yml:24` 呼叫同一 `build` script | 一致（僅多一層容器） |
| `docker compose run --rm --no-TTY runner yarn test` | `ci.yml:26` 呼叫同一 `test` script | 一致（僅多一層容器） |
| `yarn lint`（附帶提供，非 REQ 要求） | `package.json:65` | 一致 |

#### REQ-2：新段落說明測試需要 Redis，並寫出 `docker compose` 的啟動命令

- 測試連線目標即 compose 服務名：
  - `src/single.test.ts:548` `new Redis({ host: "redis-single-instance" })`、`:550` `new Cluster([{ host: "redis-single-cluster-1" }])`
  - `src/multi.test.ts:319-321` `redis-multi-instance-a/b/c`、`:326-328` `redis-multi-cluster-a-1/b-1/c-1`
- `docker-compose.yml` 的服務定義：`redis-single-instance`（L15）、`redis-multi-instance-a/b/c`（L19/L21/L23）、single cluster 6 節點（L27-L96）、multi cluster a/b/c 各 3 節點 + 1 個 cluster 初始化容器（L102-L224）；合計 **23 個 redis 容器**。
- 啟動命令（證據）：`docker compose up`（`CONTRIBUTING.md:10`）或一次性 `docker compose run --rm runner yarn test`（`CONTRIBUTING.md:18`；依 `runner.depends_on` 自動拉起 Redis）。
- 反例（必須寫進 README 的警告）：在 host 直接 `yarn test` 不可行——`redis-single-instance` 等名稱無法由 host DNS 解析。

#### REQ-3：新段落列出的每個 CI 檢查項目，都能在 `.github/workflows/ci.yml` 找到對應步驟

| `ci.yml` 行號 | 步驟名 | 命令 | 類別 |
|---|---|---|---|
| L14 | `actions/checkout@v2` | — | 基礎 |
| L15-17 | Enable docker layer cache | `satackey/action-docker-layer-caching@v0.0.11` | 快取（`continue-on-error: true`） |
| L18-20 | Pull docker images | `docker-compose pull` | 預抓映像（`continue-on-error: true`） |
| **L21-22** | **Lint the source** | `docker compose run --rm --no-TTY builder yarn lint` | **檢查** |
| **L23-24** | **Transpile into dist** | `docker compose run --rm --no-TTY builder yarn build` | **檢查** |
| **L25-26** | **Run tests** | `docker compose run --rm --no-TTY runner yarn test` | **檢查** |
| L27-29 | Stop containers | `docker compose down`（`if: always()`） | 清理 |

即 README 要列的「CI 檢查項目」= **lint、build、test 三項**（其餘為基礎/清理步驟，不列入檢查清單也對得上）。

> **附加事實（供人類判斷是否揭露）**：`ci.yml:3-7` 的觸發條件是 `push`/`pull_request` 到 **`main`**；本 repo 的工廠 trunk 是 `software-factory`，因此針對 `software-factory` 開的 PR **不會**觸發這個 workflow。這也是 §3 的引擎問題能長時間未被 CI 擋下的原因之一。

---

## 3. 本環境實測（工具鏈與現況）

> 本節所有數字均為本 run 在本 workspace（HEAD `b624bbf`）實際執行所得，指令與輸出可重跑。

### 3.1 Docker 路徑（repo 的官方建置/測試路徑）：**失敗**

執行 `docker compose run --rm --no-TTY builder yarn build`（CI `ci.yml:24` 的同一命令）：

1. `installer` 服務（`node:16`，`docker-compose.yml:226-239`）執行 `yarn install`，在 `[3/5] Fetching packages...` 後失敗：
   ```
   error @informalsystems/quint@0.32.0: The engine "node" is incompatible with this module.
         Expected version ">=18". Got "16.20.2"
   error Found incompatible module.
   ```
2. `builder` 服務的 entrypoint `scripts/await.sh node_modules/.bin/tsc` 因此永遠等不到 `tsc`，容器空轉（實測 `Up 5 minutes`、日誌持續印 `Waiting for 'node_modules/.bin/tsc' to exist...`），最後由本 run 手動中止。

**判定**：`@informalsystems/quint@0.32.0`（`package.json` devDependencies，由先前的 Quint 規格工作項引入）要求 node ≥ 18，而 `installer`/`builder`/`runner` image 全部固定 `node:16`（`docker-compose.yml:227`、`:244`、`:286`）。**repo 現況的 docker 建置/測試路徑無法完成**。這不是本 Issue 造成的，但直接影響 README 該段落的正確性。

### 3.2 Host 路徑（離線 mock 測試）：**通過**

在 host 端（node v22.21.1）以 `npm install --ignore-scripts`（325 packages）安裝依賴後，**不使用 docker**、直接以 repo 自己的 `tsc` 與 `ava` 驗證：

| 指令 | 結果 |
|---|---|
| `npx tsc`（ESM） | exit **0**，產出 `dist/esm/*.test.js`、`dist/esm/index.js` |
| `npx tsc -p tsconfig.cjs.json`（CJS） | exit **0**，產出 `dist/cjs/*.js` |
| `cd dist/esm && npx ava --verbose fixes.test.js` | exit **0**，**9 tests passed**（`src/fixes.test.ts`，全部用 `MockRedisClient`、不需 Redis） |

**範圍說明**：`single.test.js`、`multi.test.js` 需要 compose 網路內的 23 個 Redis 服務（§2.1），在 host 上無法解析服務名；依 Issue DoD「跑測試確認綠燈（**不跑需外部服務的 E2E**）」，本 run 只執行不需外部服務的 mock 測試，並未執行該兩檔。這與 §2.1 的拓撲分析一致：可離線驗證的測試僅 `src/fixes.test.ts`。

> 附註（環境特性，非 repo 發現）：本 workspace 的 `target/` 巢狀於 software_factory 專案之下，上層 `package.json` 帶有 `packageManager` 欄位，會讓 `yarn`／`npm install` 觸發的 `prepare`（`yarn build`）誤判版本而失敗；故本實測以 `npm install --ignore-scripts` 略過 `prepare` 後手動呼叫 `tsc`。一般開發者照 README 使用 `yarn` 不會遇到此巢狀問題。

### 3.3 小結

- 「測試需要 Redis」是**設計上的硬依賴**，不是選項；README 必須寫明。
- **程式碼本身可建置、可測**：host（node 22）`tsc`（ESM/CJS）exit 0、mock 測試 9/9 綠燈（§3.2）。故 §3.1 的失敗**純粹是 docker image 的 node 版本問題**（`installer`/`builder`/`runner` 固定 `node:16`），不是程式碼或本 Issue 的缺陷。
- repo 目前**沒有**任何在 host 上安裝依賴後即可跑**全部**測試的路徑；`src/fixes.test.ts`（mock）是唯一不需外部服務的測試檔。
- 後續 README 工作項若要提供「可照著做」的指令，必須先由人類決定怎麼處理 docker 路徑的 node 引擎問題（§6.3 AC-5、§6.4）。

---

## 4. 影響範圍

- **直接受益者**：新加入的開發者（README 是唯一入口）。
- **受影響檔案（若後續工作項執行）**：`README.md`（必要）；`CONTRIBUTING.md`（建議同步，避免兩份文件對同一指令描述分歧）。
- **不受影響**：`src/`、`src/*.test.ts`、`docker-compose.yml`、`.github/workflows/`、`catalog-info.yaml`、建置產物、執行期行為。本 run 亦**零程式變更**。
- **下游風險**：
  1. 只寫 `yarn build`/`yarn test` 而不寫 Redis 與 docker compose → 讀者仍會失敗。
  2. 照抄 `docker compose ... yarn build/test` 而未處理 node:16 引擎問題 → 讀者會卡在 §3.1 的 `installer` 失敗。
  3. 若同步改 `CONTRIBUTING.md`，需注意其中沒有 build 指令、且用了 `--rm runner`（CI 用的是 container 內的 `--rm --no-TTY runner`）。
- **高風險路徑**（`.github/factory/risk-paths.yml` H1–H7）：本 run 只動 `docs/research/`，**無一命中**。後續的 README 變更也不在 H1–H7（H5 僅涵蓋 `.github/**`、`CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/**`）。

---

## 5. 方案比較

| 方案 | 內容 | 判定 | 理由 |
|---|---|---|---|
| **A（建議）** | 本 analyze run 只交付本報告；另開允許 `README.md` 的 `agent-write-docs` 工作項 | **採納** | 符合 analyze 護欄（`docs/**`）；報告已把 REQ-1～REQ-3 所需的全部事實與草稿備齊，後續工作項可單純做「貼上並驗證」 |
| **B** | 在本 run 直接改 `README.md` | **拒絕** | `--analyze-only` 白名單是 `docs/**`，`README.md` 不符 → `analyze-code-change` → needs-human；即繞過 guardrail |
| **C** | 把 README 內容寫進 `docs/` 報告即宣稱滿足 REQ | **拒絕** | REQ 的驗證對象是 README 的「**新段落**」；報告不具放行效力，也不能取代 README 的可發現性。此方案會製造「假完成」 |
| **D** | 依 factory-stop-rules #8／#12 停手，不產報告 | **拒絕** | Issue 標題本身即「盤點測試結構與 CI 設定」；任務模板明確允許 in-loop analyze 產出報告（`task-template-analyze.txt` 步驟 6）。報告能精確記錄落差與下一步，優於空手停手，且沿用 #4／#6 的先例 |
| **E** | 另建 `docs/README-draft.md` 之類的獨立草稿檔 | **拒絕** | 草稿內嵌於本報告即可；多開一份 docs 檔會與未來的 README 形成雙份來源，且仍不能滿足 REQ 的「新段落」 |

**方案 A 的「為什麼現在不做」**：README 是可發現性的門面，其內容正確性（尤其 §3.1 的引擎問題）需要人類先決定揭露策略——是要修 `docker-compose.yml` 的 node 版本（屬設定變更，需另開非 docs 工作項），還是先在 README 標明已知限制。把這個決策綁進一個被 `docs/**` 限制的 analyze run，只會製造 needs-human 的假完成。

---

## 6. 建議下一步（可直接開成工作項）

### 6.1 工作項描述

> **標題**：在 README 的 Contributing 段落補上「建置與測試」說明
> **類型**：`agent-write-docs`（需允許修改 `README.md`；必要時一併允許 `CONTRIBUTING.md`）
> **範圍**：只改 `README.md`（＋可選 `CONTRIBUTING.md`）；**不動** `src/`、測試、`docker-compose.yml`、`.github/`、`catalog-info.yaml`。
> **內容**：採用 §6.2 的草稿，並處理 §6.3 AC-5（node 引擎限制的揭露）。
> **前置依賴**：人類需先決定 §3.1 的處理方式（修 compose 或標限制）——見 §6.4。

### 6.2 README 草稿段落（可直接貼上，供後續工作項起點）

以下草稿的所有命令已與 `package.json:65-68` 及 `ci.yml:21-26` 逐條核對（§2.4）：

````markdown
#### Building and testing

This library is built with TypeScript and tested with [ava](https://github.com/avajs/ava).
Build output goes to `dist/` in both ESM and CommonJS formats. **Build before testing** —
the test script runs the compiled files in `dist/esm`:

```bash
yarn build   # rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json
yarn test    # cd dist/esm && ava --verbose *.test.js
```

**The tests require Redis.** They connect to several Redis topologies (a single instance,
multiple independent instances, a single cluster, and multiple clusters) by their
`docker compose` service names, so they must run inside the compose network — running
`yarn test` directly on your host will fail to resolve those hosts. `docker-compose.yml`
starts all 23 Redis containers the suite needs:

```bash
docker compose up                            # start redis + watch/rebuild/test continuously
docker compose run --rm runner yarn test     # one-off test run (starts its redis dependencies)
```

CI (`.github/workflows/ci.yml`) runs three checks, all inside the same compose environment:

- **Lint** — `docker compose run --rm --no-TTY builder yarn lint`
- **Build** — `docker compose run --rm --no-TTY builder yarn build`
- **Test** — `docker compose run --rm --no-TTY runner yarn test`
````

> 註：草稿刻意**不**宣稱「host 上直接 `yarn build && yarn test` 可行」，因為測試硬依賴 compose 服務名。若 §6.4 決定不修 `docker-compose.yml`，需在草稿末尾加一段「已知限制：`installer` 使用 node 16，而 `@informalsystems/quint` 需要 node ≥ 18，docker 路徑目前會在此失敗」的警語。

### 6.3 驗收條件草案（沿用並修訂 Issue 的 REQ-1～REQ-3）

- **AC-1（對應 REQ-1）**：README 的新段落列出 `yarn build` 與 `yarn test`，且與 `package.json:66,68` 的 script 一致；可另列容器版本（`ci.yml:24,26`）。驗證：逐字比對 `package.json`。
- **AC-2（對應 REQ-2）**：README 的新段落明講「測試需要 Redis」，並寫出 `docker compose up` 與 `docker compose run --rm runner yarn test`。驗證：檢查字串存在且命令與 `CONTRIBUTING.md:10,18`／`docker-compose.yml` 一致。
- **AC-3（對應 REQ-3）**：README 的新段落列出 CI 的三個檢查（Lint / Build / Test），每一項都能對回 `.github/workflows/ci.yml:21-26` 的步驟。驗證：逐條對照。
- **AC-4（路徑約束）**：`git diff --name-only` 只含 `README.md`（＋可選 `CONTRIBUTING.md`），不含 `src/`、`.github/`、`catalog-info.yaml`、`CODEOWNERS`。
- **AC-5（可執行性，建議新增）**：在乾淨 checkout 上照 README 操作一次。若 §3.1 的 node:16 引擎問題未修，README 必須明列該限制或指向修復工作項；**不得**讓讀者照做後卡在 `installer` 失敗而無說明。

### 6.4 人類待辦（agent 無權執行）

1. **決定 §3.1 的處理方式**：(a) 另開非 docs 工作項把 `installer`/`builder`/`runner` 的 `node:16` 換成 ≥ 18（或於 `installer` 加 `yarn install --ignore-engines`）；或 (b) 在 README 明列為已知限制。
2. 派工 §6.1 的 `agent-write-docs` 工作項（需允許 `README.md`）。
3. 決定是否同步 `CONTRIBUTING.md`（避免雙份來源分歧）。
4. 評估是否清理 `.travis.yml`（`npm run test-ci` 已不存在）。

---

## 7. Requirements 對照（`report.json`）

| REQ | 本 run 狀態 | 說明 |
|---|---|---|
| REQ-1 | `failed` | **未交付 README 新段落**（analyze 護欄只允許 `docs/**`）。報告已備齊權威命令與逐條對照（§2.4），草稿見 §6.2。 |
| REQ-2 | `failed` | **未交付 README 新段落**。報告已證實測試硬依賴 Redis、列出 23 個 compose 服務與啟動命令（§2.4、§3）。 |
| REQ-3 | `failed` | **未交付 README 新段落**。報告已把 CI 三個檢查逐條對回 `ci.yml:21-26`（§2.4），供後續段落直接引用。 |

> 三條 REQ 的驗證對象都是 README 的「新段落」，而本 run 無法修改 `README.md`（§0），故誠實回報為 `failed`：報告已涵蓋「該段落應有的內容」，但**該段落本身尚未存在**，無法通過其驗證。此為自報，`factory-crosscheck` 以 analyze 模式驗證本 run 無 `docs/` 以外變更（§8）。沿用 Issue #4／#6 報告的同一處理方式。

---

## 8. 變更清單

本 run 無任何 `src/`、測試或設定變更；唯一變更是本報告
`docs/research/12-test-structure-and-ci-inventory.md`。符合 analyze 護欄（`docs/**`）與
factory-stop-rules #8 的「不自行擴大範圍」。
