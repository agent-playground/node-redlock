# 12 — node-redlock 的測試結構與 CI 盤點：README「建置與測試」段落的前置分析（agent-analyze）

> **任務類型**：`agent-analyze`（factory 任務模板；docs/20 §4 C1）——僅分析、不實作。
> **分析對象**：Issue #12（repo `agent-playground/node-redlock`，工廠 trunk `software-factory`）。
> **日期**：2026-10-13 · **分析時 HEAD**：`b624bbf`（`fix: resolve even-node tie votes…`，trunk `software-factory`）。
> **環境**：node 22.21.1、npm 10.9.4、yarn 1.22.22、docker 28.0.4（Compose v2，**無** `docker-compose` v1）。
> **狀態**：分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。

---

## 0. 本 run 的範圍宣告（必讀）

Issue #12 的 PRD 要求「在 README 的 Contributing 段落補上建置與測試說明」，且「範圍：只改 `README.md`」。
本 run 的 `task_type` 是 `agent-analyze`，`factory-crosscheck --analyze-only` **只允許 `docs/**`下的報告檔**，
因此**直接編輯`README.md`不在本 run 可交付的範圍內**（違反即`analyze-code-change` → needs-human）。

本報告據此定位為**該文件工作項的前置分析**：

1. 逐條核實 Issue 的三條驗證方式（REQ-1 ～ REQ-3），每一條都給出**檔案＋行號＋本 run 實測退出碼**（§2、§5）。
2. 盤點「建置／測試／測試所需外部服務／CI 實際檢查項目」的**事實清單**，包含三項**Issue 未預期但直接影響文件內容**的發現（§1 條 4、5、7）。
3. 交出可直接插入 README 的**段落草稿全文**（§7 附錄 A），讓後續 `agent-write-docs` 工作項可以照抄而不是重新調查。

Issue 標題（「盤點測試結構與 CI 設定」）與 PRD（「改 README」）在產出形態上不同：本報告同時滿足兩者——
**盤點即本體，README 內容以草稿形式附錄**，實際檔案編輯由 §6 工作項 1 執行。這屬於 docs/06 §4
「僅可產出分析與方案，不得實作」的正常分工，**不是**停手條件（Issue 有可驗證的驗收條件，且無規則衝突）。

---

## 1. 結論摘要（一頁）

1. **建置與測試的正確順序是 `build` → `test`，而且必須成對。** `test` script 執行的是**編譯產物**
   （`package.json:68` = `cd dist/esm && ava --verbose *.test.js`），不是 `src/*.test.ts`。
   未建置時 `dist/esm/` 內沒有 `*.test.js`，`npm test` 無東西可跑。實測：`npm run build` **exit 0，4.24s**（node 22）。
2. **測試分兩類，且只有一類不需要 Redis**：
   - `src/single.test.ts`、`src/multi.test.ts`：在**模組載入期**就以 docker-compose 的**服務名稱**建立連線
     （`src/single.test.ts:548,550`、`src/multi.test.ts:316-328`，如 `redis-single-instance`、`redis-multi-cluster-a-1`）。
   - `src/fixes.test.ts`：用純記憶體 `MockRedisClient`（`src/fixes.test.ts:42`），**不需要任何外部服務**。
     實測：`cd dist/esm && npx ava --verbose fixes.test.js` → **exit 0，1.44s，9 tests passed**。
3. **在沒有 Redis 的機器上 `npm test` 不是「快速失敗」，而是「掛死」。** 實測：240 秒未結束（wrapper exit 124），
   輸出不斷重複 `[ioredis] Unhandled error event: Error: getaddrinfo EAI_AGAIN redis-multi-instance-a`（…/-b/-c/`redis-single-instance`）。
   根因：主機名稱解析不了 → ioredis 自動重連永不放棄 → redlock 的 retry 迴圈不收斂，且該檔**沒有任何 skip 機制**。
   → 這正是新加入者最需要的警告，README 段落**必須**把「需要 Redis」寫成硬性前提，並給出不需要 Redis 的子集命令。
4. **CI 實際檢查三項：lint、build、test，全部在 docker compose 裡用 yarn 執行**（REQ-3 對照表見 §2.5）。
   ⚠️ 但 `ci.yml` 的觸發條件只有 `branches: [main]`（`.github/workflows/ci.yml:4-7`），而工廠 trunk 是
   `software-factory` → **工廠的 PR 不會跑到這套 CI**。實證：`gh pr checks 8` = `no checks reported`；
   `gh run list --branch software-factory` = `[]`。文件如實描述 CI 內容即可，但「CI 綠燈」**不能**當作本 trunk 的放行信號（§6 工作項 2）。
5. **`npm run lint` 在 trunk 目前是紅的**（實測 exit 1）：`prettier -c` 對 **4 個既有檔案**列出不合格式——
   `.github/factory/risk-paths.yml`、`docs/research/4-quint-spec-feasibility.md`、
   `docs/research/6-quint-executable-spec-analysis.md`、`specs/FM-agent/231-fm-agent-adoption-analysis.md`。
   `npx eslint src --ext ts` 單獨跑是綠的（exit 0）。→ 後續文件工作項**只能**要求「自己新增的檔案 prettier 綠」，
   並**不得**為了湊綠燈去動既有檔案（範圍外的格式化會污染 diff）。本報告已用 `prettier --write` 校過自己的檔案。
6. **Contribution 文件的缺口在哪：** README 的 Contributing 只有**一個連結**（`README.md:144-146` →
   `CONTRIBUTING.md`），且它在 `## Guidance` 之下、不在 TOC（`README.md:9-13`）中。
   `CONTRIBUTING.md`（全文 19 行）只講 docker compose 開發迴圈與 `docker compose run --rm runner yarn test`，
   **未**說明：對應的 npm scripts、build 先於 test、哪些測試需要 Redis、CI 檢查哪些項目。
7. **文件化任何「照著做就綠」的命令之前必須先修一件事：目前 `docker compose up` 裝不起來。**
   實測 `docker compose run --rm --no-TTY builder yarn build`（= `ci.yml:24` 那一步）**不會結束，只會無限等待**：
   `installer`（`docker-compose.yml:226-238`，`image: node:16`，`command: yarn`）啟動後 **exit 1**——
   ```
   error @informalsystems/quint@0.32.0: The engine "node" is incompatible with this module.
     Expected version ">=18". Got "16.20.2"
   error Found incompatible module.
   ```
   named volume `node_modules` 因此是空的（`docker-compose.yml:4,236-238`），`builder` 的 entrypoint
   `./scripts/await.sh node_modules/.bin/tsc …`（`docker-compose.yml:246`）無限等待 → CI 的 lint/build/test 三步全部卡死。
   **因果鏈已核實**：`@informalsystems/quint` 只存在於 trunk 的 devDependencies
   （`git diff origin/main..HEAD -- package.json` → `+ "@informalsystems/quint": "0.32.0",`），
   而 `image: node:16`（`docker-compose.yml:227,244,286`）在 main 與 trunk 相同 → trunk 新增的 devDep 打爆了沿用自 upstream 的 node 錨定。
8. **零 lockfile**：`.npmrc:1` `package-lock=false`，且 `.gitignore` 忽略 `/yarn.lock`、`/package-lock.json`。
   → 依 Issue「只改 README」的原則，文件**不得**宣稱可重現的安裝結果；建議段落避免使用 `npm ci`（根本沒有 lockfile）。
9. **兩個遺留 CI 檔不得作為「CI 檢查項目」的依據**：
   `.travis.yml:8` 執行 `npm run test-ci`，但 `package.json:63-75` **沒有** `test-ci` script（死檔）；
   `ci.yml:19` 的 `docker-compose pull` 用的是 v1 CLI——本沙箱與目前 GitHub runner 上都**沒有** `docker-compose`，
   該步靠 `continue-on-error: true`（`ci.yml:20`）靜默失效。`ci.yml:16` 的
   `satackey/action-docker-layer-caching@v0.0.11` 同為 continue-on-error。
10. **建議**：以**方案 A**（§4）執行單一 `agent-write-docs` 工作項——只改 `README.md`，在 Contributing 段落補
    「建置與測試」子段落，內容即 §7 附錄 A 草稿（逐字可用）。另有 3 項需人類裁決的事（ci.yml 觸發分支、
    docker node 版本、測試的 Redis 依賴顯性化）**不屬於**該文件工作項。

---

## 2. 證據與根因

### 2.1 分析環境

| 項目   | 值                                                       |
| ------ | -------------------------------------------------------- |
| repo   | `agent-playground/node-redlock`                          |
| 分支   | `software-factory` @ `b624bbf`（clone 深度 1 個 commit） |
| node   | v22.21.1                                                 |
| npm    | 10.9.4                                                   |
| yarn   | 1.22.22                                                  |
| docker | 28.0.4（Compose v2）；**無** `docker-compose` v1 執行檔  |
| Redis  | 本機無（測試需要的是 compose 網路內的服務名稱）          |

### 2.2 可重現步驟與實測結果

所有命令在 repo 根目錄執行；「結果」欄是本 run 實際觀測到的退出碼/輸出摘要。

| #   | 命令                                                                                                                                      | 結果                                                                                                                                                         |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `npm install --ignore-scripts --no-audit --no-fund`                                                                                       | exit 0，`added 325 packages in 10s`                                                                                                                          |
| 2   | `npm run build`                                                                                                                           | exit 0，牆鐘 `real 0m4.240s`；產出 `dist/esm/{index,fixes.test,multi.test,single.test}.js` 與 `dist/cjs/`                                                    |
| 3   | `npm test`（無 Redis）                                                                                                                    | **240s 未結束**（wrapper exit 124）；持續輸出 `[ioredis] Unhandled error event: Error: getaddrinfo EAI_AGAIN redis-*`；僅 mock 類測試先通過後被 kill         |
| 4   | `cd dist/esm && npx ava --verbose fixes.test.js`                                                                                          | exit 0，牆鐘 `real 0m1.437s`，`9 tests passed`                                                                                                               |
| 5   | `npm run lint`                                                                                                                            | exit 1（`prettier -c` 對 4 個既有檔案 warn）；見 §1 條 5 清單                                                                                                |
| 6   | `npx eslint src --ext ts`                                                                                                                 | exit 0                                                                                                                                                       |
| 7   | `docker-compose --version`                                                                                                                | `command not found`（v1 不存在）→ `ci.yml:19` 無法執行                                                                                                       |
| 8   | `docker compose config --quiet`                                                                                                           | exit 0 + warning：`the attribute version is obsolete`（`docker-compose.yml:1`）                                                                              |
| 9   | `docker pull redis:6` / `docker pull node:16`                                                                                             | exit 0 / exit 0                                                                                                                                              |
| 10  | `docker compose up -d redis-single-instance redis-multi-instance-a redis-multi-instance-b redis-multi-instance-c`                         | exit 0，4 個 redis 容器 `Up`                                                                                                                                 |
| 11  | `docker compose run --rm --no-TTY builder yarn build`（= `ci.yml:24`）                                                                    | **無限等待**：實測 ≥3 分鐘無任何進展（`builder` 日誌重複 `Waiting for 'node_modules/.bin/tsc' to exist...`），本 run 手動中止                                |
| 12  | `docker logs target-installer-1`                                                                                                          | **exit 1**：`error @informalsystems/quint@0.32.0: The engine "node" is incompatible with this module. Expected version ">=18". Got "16.20.2"`                |
| 13  | `node -e "const p=require('./node_modules/@informalsystems/quint/package.json');console.log(p.name,p.version,JSON.stringify(p.engines))"` | `@informalsystems/quint 0.32.0 {"node":">=18"}`（quint 自身的 engines 宣告）                                                                                 |
| 14  | `git show origin/main:package.json \| grep quint`                                                                                         | 無命中；`git diff origin/main..HEAD -- package.json` → `+ "@informalsystems/quint": "0.32.0",`                                                               |
| 15  | `gh pr checks 8`（trunk 上已合併的 analyze PR）                                                                                           | `no checks reported on the 'factory/6-01-analyze' branch`                                                                                                    |
| 16  | `gh run list --branch software-factory`                                                                                                   | `[]`                                                                                                                                                         |
| 17  | `git status --porcelain`（步驟 2/4 之後）                                                                                                 | 空——`/dist/**/*.js`、`/node_modules` 受 `.gitignore` 保護，建置與 ava 未弄髒被追蹤的檔案（含被追蹤的 `dist/esm/node_modules/.cache/ava/failing-tests.json`） |
| 18  | `docker compose down -v`                                                                                                                  | exit 0，容器與 named volume 清理乾淨                                                                                                                         |

> 腳註（環境細節，非 repo 問題）：步驟 1 需 `--ignore-scripts` 是因為 `prepare`（`package.json:73` = `yarn build`）
> 會在 install 期隱式觸發建置；本 run 要把建置順序顯性化所以繞過。另：本沙箱的 `~/.npm/_cacache` 屬 root，
> 需加 `--cache /tmp/npm-cache`。

### 2.3 建置 → 測試的真實依賴鏈（根因之一：測試跑的是產物）

```
src/*.ts  --(tsc, tsconfig.json:6 outDir=./dist/esm)-->  dist/esm/*.js
          --(tsc -p tsconfig.cjs.json)                -->  dist/cjs/*.js
                                                        ↓
                        npm test = cd dist/esm && ava --verbose *.test.js   (package.json:68)
```

- `package.json:66` `build` = `rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json`。
- `package.json:68` `test` = `cd dist/esm && ava --verbose *.test.js`——**沒有** `pretest` 之類的钩子，
  所以「改完直接 `npm test`」跑的會是**舊的產物**（或根本沒產物）。這是新人最容易誤解的一點。
- `package.json:69` `test:development` = 同上但 `--watch`；`package.json:67` `build:development` = `tsc --watch`。
  這兩條是 `docker-compose.yml` 裡 `builder`/`runner` 實際跑的命令（`docker-compose.yml:247,289`）。
- `tsconfig.json:22` `"types": ["node"]` 上方有一段註解（`tsconfig.json:15-21`）說明：
  不限定 `types` 時，`@informalsystems/quint` 傳入的 `@types/lodash` 會讓 `tsc` 以 TS 4.6 解析失敗（TS1005）。
  → **建置能否成功取決於這一行**，文件若教人改 tsconfig 會踩坑；本報告建議 README 段落保留一句提醒。
- `package.json:43-47` 的 ava 設定帶 `--experimental-specifier-resolution=node`（本 run 在 node 22 實測仍可用，見步驟 4）。

### 2.4 測試盤點：誰需要什麼外部服務（REQ-2 的事實基礎）

| 測試檔                                                                                                              | 測試數                                                                 | 外部服務                                                | 連線方式（程式碼位置）                                                                                                                                          | 無 Redis 時                                                                                      |
| ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `src/single.test.ts`                                                                                                | 9 個 `test()` × 2 命名空間（`run("instance")` + `run("cluster")`）= 18 | 1 個 standalone Redis、1 個 Redis **cluster**（6 節點） | `src/single.test.ts:548` `new Redis({ host: "redis-single-instance" })`；`:550` `new Cluster([{ host: "redis-single-cluster-1" }])`                             | 掛死（§2.2 步驟 3）                                                                              |
| `src/multi.test.ts`                                                                                                 | 3 個 `test()` × 2 命名空間 = 6                                         | 3 個 standalone（quorum）、3 個 cluster（各 3 節點）    | `src/multi.test.ts:316-328`：`redis-multi-instance-a/b/c`、`redis-multi-cluster-{a,b,c}-1`                                                                      | 掛死                                                                                             |
| `src/fixes.test.ts`                                                                                                 | 9（實測 `9 tests passed`）                                             | **無**                                                  | `src/fixes.test.ts:42` `class MockRedisClient`（記憶體實作三段 Lua 語意）                                                                                       | **綠**（1.44s）                                                                                  |
| `specs/oracle/counterexamples.test.mjs`（`npm run oracle:mock`，`package.json:71`）                                 | —                                                                      | **無**（`specs/oracle/fakeRedis.mjs`）                  | 需先 `npm run build`（`package.json:71` 內含 `npm run build &&`）                                                                                               | 不適用本工作項                                                                                   |
| `specs/oracle/lua-parity.test.mjs`、`specs/oracle/real-redis.test.mjs`（`npm run oracle:redis`，`package.json:72`） | —                                                                      | 1 個可直連的 Redis，**由環境變數決定**                  | `specs/oracle/lua-parity.test.mjs:23-24`、`specs/oracle/real-redis.test.mjs:27-28`：`ORACLE_REDIS_HOST`（預設 `127.0.0.1`）、`ORACLE_REDIS_PORT`（預設 `6399`） | 優雅 skip（`specs/oracle/real-redis.test.mjs:16,69-74`；`CI` 環境下會改為**丟錯**，見 `:72-74`） |

**對照發現**：`specs/oracle/*` 有「連不上就 skip、CI 就丟錯」的顯性處理，
而 `src/single.test.ts`/`src/multi.test.ts` 完全沒有——主機名稱硬編碼在 `run()` 呼叫點，
既無法用環境變數覆寫，也沒有 unreachable 時的出口（唯一的「redis 連不上」測試
`src/single.test.ts:202` 是故意指向 `127.0.0.1` 並把重連關掉，`maxRetriesPerRequest: 0`、`retryStrategy: () => null`，
恰好說明「要做優雅降級是寫得出來的，只是套件級測試沒做」）。
→ 這決定了 README 段落**只能**寫「跑 `npm test` 之前必須有可用的 Redis 網路（docker compose）」，
不能教讀者「沒有 Redis 也能跑，只是會失敗」。

外部服務的唯一實務來源：`docker-compose.yml` 共 **21 個 redis 容器** + `installer`/`builder`/`runner`
（`docker-compose.yml:15-223` 是 redis 群；`:226` installer；`:241` builder；`:260` runner，
其 `depends_on` 列出全部 23 個服務 `:261-285`，並同時掛在 `default` 與 `redis` 兩個網路 `:300-302`）。
啟動命令與 `CONTRIBUTING.md:7-11` 一致：`docker compose up`（一次性 one-off 則是 `CONTRIBUTING.md:18` 的
`docker compose run --rm runner yarn test`）。

### 2.5 CI 檢查項目逐條對照（REQ-3 的事實基礎）

`ci.yml` 的 job 只有一個（`test`，`name: Build & Test`，`ci.yml:10-11`）。

| `ci.yml` 行 | step 名稱                 | 實際指令                                              | 對應 `package.json` script   | 本 run 實測                                                                                                                                        |
| ----------- | ------------------------- | ----------------------------------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:14`       | `actions/checkout@v2`     | checkout                                              | —                            | 未測（版本過時，見 §3）                                                                                                                            |
| `:15-17`    | Enable docker layer cache | `satackey/action-docker-layer-caching@v0.0.11`        | —                            | `continue-on-error: true` → 失敗不影響終態                                                                                                         |
| `:18-20`    | Pull docker images        | `docker-compose pull`（v1 CLI）                       | —                            | v1 執行檔不存在（§2.2 步驟 7）；`continue-on-error: true` 掩蓋                                                                                     |
| `:21-22`    | **Lint the source**       | `docker compose run --rm --no-TTY builder yarn lint`  | `lint`（`package.json:65`）  | 指令等價 `prettier -c … && eslint src --ext ts`：prettier **exit 1**（既有 4 檔）、eslint **exit 0**；在 compose 內則根本進不到（§2.2 步驟 11/12） |
| `:23-24`    | **Transpile into dist**   | `docker compose run --rm --no-TTY builder yarn build` | `build`（`package.json:66`） | host 端 `npm run build` exit 0（4.24s）；compose 端無限等待                                                                                        |
| `:25-26`    | **Run tests**             | `docker compose run --rm --no-TTY runner yarn test`   | `test`（`package.json:68`）  | 需 Redis（§2.4）；compose 端無限等待                                                                                                               |
| `:27-29`    | Stop containers           | `docker compose down`（`if: always()`）               | —                            | `docker compose down -v` exit 0                                                                                                                    |

**CI 沒有檢查的事**（寫文件時要避免讓讀者誤以為有）：`format`（`package.json:64`，寫入式 prettier）、
`oracle`／`oracle:mock`／`oracle:redis`（`package.json:70-72`）、`specs/` 的 quint 模型驗證、
`build:development`。另有**獨立 workflow** `.github/workflows/codeql-analysis.yml`（CodeQL，`:1-30`）——
它不在 `ci.yml` 裡，因此**不該**出現在「CI 檢查項目」清單中（否則 REQ-3 的「都能在 `.github/workflows/ci.yml`
找到對應步驟」會失敗）。

**觸發範圍（關鍵）**：`ci.yml:4-7` 與 `codeql-analysis.yml:3-8` 都只有 `branches: [main]` →
工廠 trunk `software-factory` 的 push／PR **不會**觸發（§2.2 步驟 15、16 的實證）。
本 run 的 PR 因此不會有「Build & Test」檢查；報告中列出的 CI 內容是**給讀者的事實說明**，不是本 PR 的放行依據。

### 2.6 文件現況（缺口定位）

- `README.md:9-13` TOC：`Installation / Usage / Error Handling / API / Guidance`——**沒有** Development 條目。
- `README.md:144-146`：`## Guidance` 之下的 `### Contributing`，內容只有一句
  「Please see `CONTRIBUTING.md` for information on developing, running, and testing this library.」
- `CONTRIBUTING.md`（19 行）：`:3` docker、`:5` runner 服務會 watch、`:7-11` `docker compose up`、
  `:13` 改檔自動重建重跑、`:15-18` one-off `docker compose run --rm runner yarn test`。
  **未**出現：`npm`/`yarn` 的 script 名稱對應、build 與 test 的先後、Redis 名詞、CI 檢查項目。
- `README.md:1` 的 CI badge 指向 `mike-marcacci/node-redlock`（upstream），`package.json:10-12` 的
  repository/homepage/bugs 亦然 → fork 內「本 repo 的 CI 長什麼樣」沒有任何入口線索。

### 2.7 根因（為什麼新加入者跑不起來）

| #   | 根因                                                                                                                                                                                                                                  | 證據                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| R1  | **資訊不在 README**：唯一的測試資訊藏在 `CONTRIBUTING.md`，且從 `README.md:144` 兩層深（Guidance 之下）                                                                                                                               | `README.md:9-13,144-146`                                                                        |
| R2  | **建置與測試是配對關係卻被寫成兩個獨立 script**：`test` 只跑 `dist/esm` 的產物，無 `pretest` 钩子                                                                                                                                     | `package.json:66,68`；§2.2 步驟 2-3                                                             |
| R3  | **Redis 依賴是隱性的**：主機名稱硬編碼在模組載入期；無 env 覆寫、無 skip、無快速失敗                                                                                                                                                  | `src/single.test.ts:548,550`、`src/multi.test.ts:316-328`；§2.2 步驟 3                          |
| R4  | **唯一的官方外部服務方案（compose）在 trunk 目前裝不起來**：devDep `@informalsystems/quint@0.32.0` 要求 node>=18，compose 錨 `node:16`，yarn v1 對 engines 是**硬錯誤**；`await.sh` 又把失敗轉成無限等待（無 timeout、無 error 出口） | `package.json:49`、`docker-compose.yml:227,244,286`、`scripts/await.sh:3-9`、§2.2 步驟 11/12/13 |
| R5  | **CI 的警訊被 continue-on-error 吃掉，且 trunk 根本不觸發 CI** → 上述 R4 不會被任何自動檢查擋住                                                                                                                                       | `ci.yml:4-7,20,17`；§2.2 步驟 15/16                                                             |

R4 ＋ R5 是本 run 最重要的發現：**「補上文件」與「文件是真的」之間還隔著一個必須由人類決定的修復項**（§6 工作項 2/3）。

### 2.8 本 run 未驗證之事（誠實聲明）

1. **未取得 `single.test.js`／`multi.test.js` 的綠燈**（被 R4 擋住）。Redis 依賴的結論來自
   **負向實測**（無 Redis → 掛死）＋程式碼硬編碼名稱；正向綠燈留給 §6 工作項 3 完成後驗證。
2. **未驗證「把 compose 的 `node:16` 升到 20/22 就能全綠」**——那需要改 `docker-compose.yml`，超出分析範圍。
   本 run 只核實了失敗點（yarn engines 檢查）與其機械原因。
3. **未執行 `specs/oracle/*`**（不屬於 Issue 的三條驗證方式）。
4. **未驗證 GitHub Actions 上的實際執行**（沙箱內無法觸發 main 分支的 workflow）。

---

## 3. 影響範圍

**受影響對象**

- **新加入的貢獻者**（Issue 的直接訴求對象）：目前最常見的兩種卡住方式——(a) 直接 `npm test` → 掛死；
  (b) 照 `CONTRIBUTING.md:10` 執行 `docker compose up` → 卡在 `Waiting for 'node_modules/.bin/tsc' to exist...`（實測）。
- **工廠 agent（本 repo 的後續工作項）**：任何假設「CI 會告訴我測試有沒有壞」的工作項都是空轉——trunk 不觸發 `ci.yml`。
  `agent-add-tests`／`agent-fix-bug` 若要驗證自己的改動，目前只有兩條可靠路徑：
  `npm run build` ＋ `cd dist/esm && npx ava --verbose fixes.test.js`（mock 子集，實測 1.44s 綠）。
  這是本報告可以直接降低的成本（**把可跑的無 Redis 路徑寫進文件**）。
- **本機開發者體驗**：`scripts/await.sh` 無 timeout → 失敗以「無限等待」呈現，不是錯誤訊息（`scripts/await.sh:3-9`）。
- **終端使用者（npm `redlock`）**：**無影響**——本 run 與擬議的文件工作項都不動 `src/`、不動 `package.json`、不動 `dist/` 內容。

**受影響模組／檔案（只讀分析，未修改）**

- `README.md`（擬議編輯點：`:144-146`）
- `CONTRIBUTING.md`（事實來源，擬議**不改**，見 §4 方案 B）
- `package.json`（`:49,63-75`）、`tsconfig.json`（`:6,10,22`）、`.npmrc`（`:1`）、`.gitignore`（lockfile 條目）
- `src/single.test.ts`、`src/multi.test.ts`（Redis 依賴）、`src/fixes.test.ts`（可獨立跑）
- `docker-compose.yml`、`scripts/await.sh`、`cluster.redis.conf`（外部服務）
- `.github/workflows/ci.yml`、`.github/workflows/codeql-analysis.yml`、`.travis.yml`（CI 事實）

**高風險路徑（H1–H7）**：本 run **未觸及**任何檔案；擬議的文件工作項只改 `README.md`，
不在 `.github/factory/risk-paths.yml` 的 H5 清單（`:56-61`：`.github/**`、`CODEOWNERS`、`catalog-info.yaml`、
`.dsh/skills/**`）之內 → 低風險。反之，§6 的工作項 2/3/4 要動 `ci.yml`（H5，`risk-paths.yml:57`）
與 `docker-compose.yml`，依 stop rules 第 3 條屬**人類/需單獨核准**的變更。

**下游一致性**：README 是 npm 頁面的入口（`package.json:11` homepage 指向上游 README），
文件若宣稱 `docker compose up` 可用而目前不可用（R4），等於把壞路徑寫成官方路徑——
所以 §7 草稿**明確**標註該已知問題，而不是假裝綠。

---

## 4. 方案比較

### 方案 A（建議）：只改 `README.md`，在 Contributing 段落補「建置與測試」子段落（內容＝附錄 A 草稿）

- 位置：`README.md:144` 的 `### Contributing` 之下新增 `#### Building and testing`（含命令、外部服務表、CI 清單）。
- 優點：符合 Issue「範圍：只改 `README.md`」；三條驗證方式逐條可驗（§5）；不動任何設定／CI／測試；
  並把 R4（compose 目前不可用）以「Known issue」形式如實記錄，不寫假話。
- 成本：單檔、約 25–40 行；prettier 校格式即可。
- 風險：讀者仍可能踩 R4 → 用草稿中的「Two ways to run the tests」結構（先给 mock 子集，再给完整 compose 路徑）降低。

### 方案 B（被拒）：內容寫進 `CONTRIBUTING.md`，README 只留一句連結

- 拒因：Issue 明確「範圍：只改 `README.md`」，且問題陳述是「新加入者無法**從 README** 得知」；
  REQ-1 ～ 3 的受體驗證主體也是「**新段落**」。把內容放 CONTRIBUTING 等於維持現狀的兩層深入口（R1）。
- 保留價值：若人類認為 README 應精簡，方案 B 是可行的退路（內容可 1:1 搬移），但**需要人類改 Issue 範圍**才可執行。

### 方案 C（被拒）：一次把 README ＋ `ci.yml`（讓 trunk 也跑 CI）＋ `docker-compose.yml`（node 版本）一起修

- 拒因：(1) 超出 Issue 範圍；(2) `.github/**` 屬 H5（`risk-paths.yml:57`）→ stop rules 第 3 條「需要修改 CI 設定」必須交人類；
  (3) 三件事的審查者不同（文件 vs 護欄 vs 開發環境），stacked 後仍需要兩次人類裁決，合併成一顆 PR 反而讓文件被 CI 變更卡住。
- 處置：拆給 §6 工作項 2（人類裁決）與工作項 3（需 `.github/**`／compose 權限）。

### 方案 D（被拒）：README 教「不用 docker 也能跑完整測試」的步驟（自行 `docker run redis:6` ＋ host 別名/env 覆寫）

- 拒因：**這條路今天走不通**——測試的主機名稱硬編碼（R3），且 `redis-single-cluster-*` 需要 6 節點 cluster 與
  靜態 IP（`docker-compose.yml:27-99`）＋ 自建網路 DNS；實測 host 端解析 `redis-*` 一律 `EAI_AGAIN`（§2.2 步驟 3）。
  文件化一條要改程式碼才走得通的路，比不寫更糟。
- 正面價值：草稿裡保留「只需 Redis 的完整測試 vs 完全不需要 Redis 的子集」的區分——子集命令是**實測綠**的（步驟 4）。

### 方案 E（被拒）：順手把 §1 條 5 的 4 個 prettier 違例檔案一起格式化，讓 `npm run lint` 變綠

- 拒因：範圍外的 diff（`risk-paths.yml` 更是 H5 保護檔），且會掩蓋「lint 在 trunk 本就紅」這個必須讓人類看見的事實。
  文件工作項只要求**自己新增/修改的檔案** prettier 綠。

---

## 5. 驗收條件逐條涵蓋（`report.json` 的 `requirements`）

| id    | Issue 驗收條件                                                               | 本報告的涵蓋方式                                                                                                                                                        | status   |
| ----- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| REQ-1 | 新段落列出的命令與 `package.json` 的 `build`、`test` script 一致             | §2.3 逐字引用 `package.json:66,68`；§7 草稿使用的命令即 `npm run build`／`npm test`／`npx ava --verbose fixes.test.js`，且步驟 2、3、4 為實測退出碼                     | `passed` |
| REQ-2 | 新段落說明測試需要 Redis，並寫出 `docker compose` 的啟動命令                 | §2.4 盤點（哪個測試需要、程式碼行號）＋ §2.2 步驟 3 的負向實測；啟動命令取自 `CONTRIBUTING.md:10`，草稿照抄 `docker compose up`（含 one-off 變體 `CONTRIBUTING.md:18`） | `passed` |
| REQ-3 | 新段落列出的每個 CI 檢查項目，都能在 `.github/workflows/ci.yml` 找到對應步驟 | §2.5 對照表（lint/build/test → `ci.yml:22`/`:24`/`:26`，含「CI 未檢查什麼」與「CodeQL 不列入」的裁決理由）                                                              | `passed` |

**誠實邊界**：以上 `passed` 指「**報告已明確涵蓋並完成驗證**」。三條在「README 檔案真的被改了」這個意義上尚未達成——
那需要 §6 工作項 1（本 run 因 `agent-analyze` 白名單不得編輯 `README.md`，見 §0）。

DoD 三項（Issue 的 `- [x]`）對應：可驗證方式＝ REQ-1 ～ 3（已涵蓋）；不觸碰高風險路徑＝§3（本 run 未觸及任何受保護路徑）；
跑測試確認綠燈＝本 run 以「不依賴外部服務」的路徑驗證（`npm run build` 綠、`fixes.test.js` 9 綠、eslint 綠），
需 Redis 的 `single`／`multi` 未跑綠並已在 §2.8 如實聲明。

---

## 6. 建議下一步（可直接開成工作項）

### 工作項 1 —（`agent-write-docs`，in-loop 可派）README 補「建置與測試」段落

**描述**：依本報告 §7 附錄 A，在 `README.md:144`（`### Contributing`）之下新增 `#### Building and testing` 子段落。
**範圍**：只改 `README.md`；**不得**改 `CONTRIBUTING.md`、`package.json`、`docker-compose.yml`、`.github/**`、任何測試檔。
**驗收條件草案**：

- `REQ-1`：段落中出現的每一條命令，都能在 `package.json:63-75` 找到**逐字相同**的 script 定義（`build`、`test`、
  以及不經 script 直接下給 ava 的子集命令）；並明確寫出「**必须先 `build` 再 `test`**，因為 `test` 跑 `dist/esm` 的產物」。
- `REQ-2`：段落明確寫出「`src/single.test.ts` 與 `src/multi.test.ts` 需要 Redis（以 docker compose 服務名稱連線）」，
  並給出啟動命令 `docker compose up`（另给 one-off：`docker compose run --rm runner yarn test`）；
  同時給出**不需要 Redis** 的子集命令。
- `REQ-3`：段落列出的 CI 檢查項目每一條都能在 `.github/workflows/ci.yml` 找到對應 step（lint／build／test 三項），
  且**不得**列 `ci.yml` 沒有的項目（CodeQL、oracle、quint 驗證、`format`）。
- `REQ-4`（新增，来自 §1 條 5/7）：段落**不得**宣稱「照做即綠」；須以一行標明已知問題——
  `installer` 用的 `node:16` 與 devDep `@informalsystems/quint` 的 `engines: node>=18` 衝突，
  因此 `docker compose up` 目前無法安裝依賴（引用本報告 §2.2 步驟 12）。
- `REQ-5`（新增）：`npx prettier -c README.md` exit 0；`npx eslint src --ext ts` 與 `npm run build` 保持 exit 0；
  **不要求** `npm run lint` 全綠（trunk 既有 4 檔違例，見 §1 條 5——若該工作項順手改掉，即屬範圍外 diff）。
- `REQ-6`（新增）：`cd dist/esm && npx ava --verbose fixes.test.js` 仍 exit 0（證明文件沒有弄壞東西）。

**DoD**：以上 6 條逐條在 PR 描述對照；單層 PR `factory/<issue>-01-docs`；不改 `src/`、不改 CI。

### 工作項 2 —（人類裁決／`needs-human`）工廠 trunk 沒有任何 CI 在跑

事實：`ci.yml:4-7`／`codeql-analysis.yml:3-8` 只對 `main` 觸發；`gh run list --branch software-factory` = `[]`；
PR #8 零檢查（§2.2 步驟 15/16）。影響：本 repo 每個工作項的「測試綠燈」自報**沒有獨立驗證來源**（docs/18 §2.3 的 crosscheck 失去比對對象）。
選項：(a) 在 `ci.yml` 的 `branches:` 加入 `software-factory`；(b) 新增 `.github/workflows/factory-ci.yml` 以相同步驟跑 trunk；
(c) 維持現狀並把工廠 run 的驗證明確定義為「沙箱內 `build` + mock 子集」。**屬 `.github/**`（H5）→ 必須人類\*\*，不由 agent 自行放寬。

### 工作項 3 —（`agent-fix-bug` 或人類；開發環境）`docker compose up` 裝不起來

根因與實測：§2.7 R4／§2.2 步驟 11-13。最小修復候選（**皆未在本 run 驗證**）：
(a) `docker-compose.yml:227,244,286` 的 `image: node:16` → `node:22`（與本機實測通過的 node 22 一致）；
(b) `docker-compose.yml:229` → `command: yarn --ignore-engines`；
(c) 把 `@informalsystems/quint` 移出主 devDependencies（specs 工具鏈獨立化）。
驗收條件草案：`docker compose up -d` 後 `docker compose run --rm --no-TTY builder yarn lint`、
`… yarn build`、`docker compose run --rm --no-TTY runner yarn test` **全部 exit 0**（即首次取得 `single`/`multi` 的綠燈，
填上 §2.8 條 1 的缺口）；並在 `scripts/await.sh` 失能時有明確錯誤而非無限等待。

### 工作項 4 —（低優先，`agent-analyze`→`agent-add-tests`）把「需要 Redis」變成顯性契約

把 `src/single.test.ts:548,550`、`src/multi.test.ts:316-328` 的主機/端口抽成環境變數（參照
`specs/oracle/real-redis.test.mjs:27-28` 的 `ORACLE_REDIS_HOST/PORT` 慣例），或加「探測不到 Redis 即 skip」的護欄
（參照同檔 `:16,69-74` 的 `CI 下不得 skip` 反饋機制）。**屬 `src/` 測試檔變更，另開工作項，不在文件工作項內**。

### 清理項（可與工作項 2 併入同一次人類裁決）

`.travis.yml:8` 引用不存在的 `test-ci` script（死檔，宜刪除或標註）；`ci.yml:19` 的 `docker-compose`（v1）改 `docker compose`；
`ci.yml:14` `actions/checkout@v2`、`codeql-analysis.yml` 的 `@v1` 版本過時；`docker-compose.yml:1` `version:` 已過時（§2.2 步驟 8 的 warning）。

---

## 7. 附錄 A：建議插入 `README.md` 的段落草稿

> 語言：**英文**——`README.md` 全文為英文（Issue 未指定語言；factory 的「繁體中文」規則適用於本報告與
> repo 自有文件，面向 npm 使用者的 README 以檔案現有語言為準）。若人類要求中文版，本草稿可 1:1 對應翻譯。
> 插入點：`README.md:146`（現有 Contributing 那一句）**之後**、`### High-Availability Recommendations`（`:148`）之前。

````markdown
### Contributing

Please see [`CONTRIBUTING.md`](./CONTRIBUTING.md) for information on developing, running, and testing this library.

#### Building and testing

Tests run against the **compiled output**, so a build must precede every test run:

```bash
npm install          # `prepare` already runs `yarn build` (see package.json)
npm run build        # tsc -> dist/esm (ESM) and dist/cjs (CommonJS)
npm test             # cd dist/esm && ava --verbose *.test.js
```

`npm run build` transpiles `src/*.ts` into `dist/esm/*.js`; `npm test` executes
`dist/esm/*.test.js` — it does **not** read `src/`, so editing a test without
rebuilding silently tests the previous code.

**External services.** Two of the three test suites talk to real Redis, using the
docker compose service names as hostnames (`redis-single-instance`,
`redis-multi-instance-a|b|c`, `redis-single-cluster-1`, `redis-multi-cluster-*-1`).
Without those containers they will not fail fast — they hang while ioredis retries:

```bash
docker compose up                                  # redis + build + test watcher
docker compose run --rm runner yarn test           # one-off run of the full suite
```

**Without Redis** you can still run the suites that use the in-memory mock client
(`src/fixes.test.ts`):

```bash
npm run build
cd dist/esm && npx ava --verbose fixes.test.js     # no external services needed
```

**Known issue:** `docker compose up` currently fails to install dependencies — the
`installer`/`builder`/`runner` services pin `image: node:16`
(`docker-compose.yml`), while the `@informalsystems/quint` dev dependency requires
`node >= 18`, so `yarn` aborts and the services wait forever on
`node_modules/.bin/tsc`. Use the host-side flow above until that is fixed.

**What CI checks.** `.github/workflows/ci.yml` (job `Build & Test`) runs three checks,
each inside the compose environment:

1. `yarn lint` — `prettier -c '**/*.{json,yml,md,ts}' && eslint src --ext ts`
2. `yarn build` — transpile into `dist/`
3. `yarn test` — the full AVA suite, against the compose Redis containers

It triggers on `main` pushes and pull requests targeting `main`. Code scanning
(CodeQL), the `specs/oracle` counterexample tests, and the Quint model checks are
**not** part of this workflow.
````

（草稿中的每一條命令與每個 CI 項目都對應到 §2 的行號證據：`npm run build`＝`package.json:66`、
`npm test`＝`package.json:68`、`docker compose up`＝`CONTRIBUTING.md:10`、
one-off ＝`CONTRIBUTING.md:18`、mock 子集＝§2.2 步驟 4、CI 三項＝`ci.yml:22,24,26`、觸發分支＝`ci.yml:4-7`。）

---

## 8. 變更清單

- 新增：`docs/research/12-readme-build-test-ci-inventory.md`（本檔）
- 修改：**無**（`src/`、`dist/`、`package.json`、`docker-compose.yml`、`.github/**`、測試檔皆未改動）
- 本 run 在沙箱內產生的**未追蹤**建置/安裝產物（`node_modules/`、`dist/**/*.js{,.map}`、`dist/**/*.d.ts`）
  一律受 `.gitignore` 保護，未進入 diff；已以 `git status --porcelain` 覆核為空（§2.2 步驟 17），
  並在驗證結束後以 `docker compose down -v` 清理容器與 named volume（§2.2 步驟 18）。
