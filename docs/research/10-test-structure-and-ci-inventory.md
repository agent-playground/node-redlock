# 10 — node-redlock 測試結構與 CI 設定現況盤點（agent-analyze）

> **任務類型**：`agent-analyze`（factory 任務模板分析型；docs/06 §4「僅可產出分析與方案，不得實作」）——**不產生任何程式碼變更**，本檔是唯一產物。
> **分析對象**：Issue #10（repo `agent-playground/node-redlock`，trunk `software-factory`）。
> **目標 repo HEAD**：`b624bbfb7eaa84a5e752a105f6e13ce6bba22dcf`（`software-factory`）。
> **本 run 環境**：node `v22.21.1`、npm `10.9.4`、TypeScript 4.6.2、AVA 4.1.0（自 `package.json` devDependencies 安裝）。
> **狀態**：現況分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。
> **範圍**：只讀取 repository 根目錄、`src/`、`specs/`、`.github/`、`docker-compose.yml`；只新增本報告。

---

## 1. 結論摘要

node-redlock 有**兩套彼此獨立的測試系統**，都必須先編譯再執行，且都高度依賴外部 Redis：

| 系統               | 檔案 / harness               | 執行指令                           | 測試數                                  | 外部依賴                        |
| ------------------ | ---------------------------- | ---------------------------------- | --------------------------------------- | ------------------------------- |
| AVA（主測試）      | `src/*.test.ts` → `dist/esm` | `yarn test`（`package.json:68`）   | 33（18 single + 6 multi + 9 fixes）     | 23 個 docker Redis 容器         |
| Oracle（反例神諭） | `specs/oracle/*.test.mjs`    | `yarn oracle`（`package.json:70`） | 29（11 mock + 14 lua-parity + 4 redis） | 真 Redis（`ORACLE_REDIS_PORT`） |

主要現況發現（依衝擊排序）：

1. **目標 repo 的 CI 不會在工廠 PR 上執行。** `.github/workflows/ci.yml:3-7` 只在 `push`/`pull_request` 對 `main` 時觸發；工廠 PR 的 base 是 `software-factory`（本 run 的 `BASE_BRANCH`）。因此 `Build & Test` 與 CodeQL 對所有 `factory/*` PR 都是**未觸發**狀態。
2. **即使觸發，`Lint the source` 這一步今天就已經會失敗。** `package.json:65` 的 `lint` 先跑 `prettier -c '**/*.{json,yml,md,ts}'`；實測有 **4 個既有檔案**格式不合規（見 §4.2），而 `ci.yml:22` 未加 `continue-on-error`，會讓後續 build/test 步驟不執行。
3. **測試對 docker-compose 網路有硬依賴，host 上直接 `yarn test` 一定失敗。** 測試連的是固定 hostname（`redis-single-instance`、`redis-multi-instance-a/b/c`、`redis-*-cluster-1`，見 `src/single.test.ts:548,550`、`src/multi.test.ts:317-328`），這些只在 `docker-compose.yml` 的 bridge network 內可解析。
4. **`docker-compose.yml:89` 的 single-cluster 初始化位址疑似有誤**：列出 `10.0.0.11,12,13,14,14,16`（`.14` 重複、漏 `.15`），與 `redis-single-cluster-5`（`docker-compose.yml:67-78`，IP `10.0.0.15`）不一致。若 cluster 因此建不起來，`waitForCluster()`（`src/single.test.ts:34-65`）會**無限等待**。此項未在本 run 實測（無 docker），列為候選缺陷。
5. **工具鏈與 CI action 版本偏舊且部分為死設定**：容器固定 `node:16`（`docker-compose.yml:227,244,286`）；`actions/checkout@v2`、`github/codeql-action@v1`、`satackey/action-docker-layer-caching@v0.0.11`（`ci.yml:14,16`、`codeql-analysis.yml:21,23,27,29`）皆已過時；`.travis.yml:7` 的 `npm run test-ci` 在 `package.json` 中**不存在**；`.coveralls.yml` 指向 Travis 但沒有 coverage 工具。

**一句話**：這個 repo 的測試在「有 docker + 有 Redis」的環境下設計完整，但**在工廠流程下沒有任何自動測試防線**——PR 到 `software-factory` 不觸發 CI，且 CI 的 lint 步驟本身已紅。

---

## 2. 測試結構盤點

### 2.1 目錄與建置管線

- **沒有 `test/` 目錄**：測試檔與被測程式碼同放 `src/`（`single.test.ts`、`multi.test.ts`、`fixes.test.ts`），由 `tsconfig.json` 的 `"include": ["./src/**/*"]` 一起編譯。
- `yarn build`（`package.json:66`）→ `tsc`（ESM，outDir `dist/esm`）＋ `tsc -p tsconfig.cjs.json`（CJS，outDir `dist/cjs`）。
- `dist/esm/package.json`（`{"type":"module"}`）與 `dist/cjs/package.json`（`{"type":"commonjs"}`）**有入版控**，用途是讓輸出目錄的模組型別正確。
- 測試執行時**必須先 build**：`test` 腳本切到 `dist/esm` 跑 `ava --verbose *.test.js`（`package.json:68`）——注意 `*.test.js` 是靠 shell glob，換 cwd 或直接 `npx ava` 不會自動找到測試。

### 2.2 AVA 主測試（`src/*.test.ts`）

| 檔案                 | 行數 | 測試註冊                                                                                                | 參數化                                                        | 實際案例數 |
| -------------------- | ---- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ---------- |
| `src/single.test.ts` | 550  | 9 個 `test()`（:80, :98, :138, :202, :248, :281, :336, :422, :465）                                     | `run(namespace, redis)` 呼叫兩次：`"instance"`、`"cluster"`   | 18         |
| `src/multi.test.ts`  | 329  | 3 個 `test()`（:95, :177, :263）                                                                        | `run(namespace, A, B, C)` 呼叫兩次：`"instance"`、`"cluster"` | 6          |
| `src/fixes.test.ts`  | 574  | 9 個 `test()`（:165, :195, :219, :261, :361, :387, :438, :506, :551；其中 :261、:438 為 `test.serial`） | 無（用 `MockRedisClient`，:41）                               | 9          |

- AVA 設定在 `package.json:43-46`：`nodeArguments: ["--experimental-specifier-resolution=node"]`。此旗標在 node 22 仍可用但已屬實驗/淘汰路徑；`node:16` 容器內則正常。
- `fixes.test.ts` 是**唯一不需要外部 Redis** 的 AVA 檔：以 `MockRedisClient`（:41）與 `makeClients()`（:161）注入假 client。

### 2.3 Oracle 反例神諭（`specs/oracle/*.mjs`，`node:test`）

`package.json:70-72` 定義三種跑法：

| 腳本           | 指令                                                                                             | 需要外部服務   | 測試數         |
| -------------- | ------------------------------------------------------------------------------------------------ | -------------- | -------------- |
| `oracle`       | `npm run build && node --test specs/oracle/*.test.mjs`                                           | 是（部分）     | 29             |
| `oracle:mock`  | `npm run build && node --test specs/oracle/counterexamples.test.mjs`                             | 否             | 11（假 Redis） |
| `oracle:redis` | `npm run build && node --test specs/oracle/lua-parity.test.mjs specs/oracle/real-redis.test.mjs` | 是（真 Redis） | 14 + 4         |

- `counterexamples.test.mjs`：11 個測試，以 `fakeRedis.mjs` 驅動，無外部依賴。
- `lua-parity.test.mjs`：2 個頂層 `test()`（:188、:216），內部用 `t.test` 展開成 14 個子情境；**必須連真 Redis**，用來證明假 Redis 的語意與真 script 一致（防止循環論證）。
- `real-redis.test.mjs`：4 個測試（:90, :116, :150, :210），真 Redis 端到端。
- `specs/oracle/README.md` 記載：在 `CI` 環境變數存在時，連不上 Redis 會**直接讓檔案失敗**（不 graceful skip），避免 `node --test` 在 skip 時仍 exit 0 的假綠燈。

### 2.4 測試執行環境（`docker-compose.yml`）

- 共 **23 個 Redis 服務**：1 standalone、3 standalone multi、6 節點 single cluster + 1 個 cluster-create、3×3 節點 multi cluster + 3 個 cluster-create。
- 三個 node:16 工具容器（`scripts/await.sh` 負責等待檔案出現）：
  - `installer`（:227-233）：`command: yarn`，把依賴裝進 `node_modules` volume。
  - `builder`（:244-254）：`entrypoint: ./scripts/await.sh node_modules/.bin/tsc`，`command: yarn build:development`（watch）。
  - `runner`（:286-298）：`entrypoint: ./scripts/await.sh node_modules/.bin/ava ./scripts/await.sh dist/esm/index.js`，`command: yarn test:development`（watch）。
- CI 用 `docker compose run --rm --no-TTY <svc> <cmd>` 覆寫 command；entrypoint 的 `await.sh` 仍會先等待再 `eval` 後續參數（`scripts/await.sh:1-8`）。
- `CONTRIBUTING.md` 指向 `docker compose up` 作為開發/測試入口；README 沒有測試章節，只在 `README.md:146` 指向 `CONTRIBUTING.md`。

---

## 3. CI 設定盤點

### 3.1 作用中的 workflow

**`.github/workflows/ci.yml`（Continuous Integration / Build & Test）**

| 行    | 內容                                                                        |
| ----- | --------------------------------------------------------------------------- |
| 3-7   | 觸發：`push` 與 `pull_request`，**都限定 `main`**                           |
| 14    | `actions/checkout@v2`                                                       |
| 15-17 | `satackey/action-docker-layer-caching@v0.0.11`（`continue-on-error: true`） |
| 18-20 | `docker-compose pull`（v1 語法；`continue-on-error: true`）                 |
| 21-22 | `Lint the source`：`docker compose run --rm --no-TTY builder yarn lint`     |
| 23-24 | `Transpile into dist`：`... builder yarn build`                             |
| 25-26 | `Run tests`：`... runner yarn test`                                         |
| 27-29 | `Stop containers`：`docker compose down`（`if: always()`）                  |

**`.github/workflows/codeql-analysis.yml`（CodeQL）**：觸發 `push`/`pull_request` 對 `main`＋每週排程；`actions/checkout@v2`（:21）、`github/codeql-action/{init,autobuild,analyze}@v1`（:23,27,29）。

### 3.2 死設定 / 未接線設定

- **`.travis.yml`**：`script: npm run test-ci`（:7），但 `package.json` **沒有 `test-ci`** 腳本；node 10/12/14 也已不符 `engines: node>=12` 之外的現況。屬殘留。
- **`.coveralls.yml`**：`service_name: travis-ci`，但 repo 沒有 coverage 產生器（無 nyc / c8）與上傳步驟。
- **`.github/dependabot.yml`**：每日 npm 更新，未設 `target-branch`，因此 PR 預設打向 `main`（與工廠 trunk `software-factory` 分岐）。
- **`.jshintrc`**：無 jshint 依賴，殘留。
- 本 repo **沒有 CODEOWNERS**（`risk-paths.yml` 的 H5 保留未來保護）。

### 3.3 工廠護欄

- `.github/factory/risk-paths.yml`：H1–H3 經人類裁定**留空**（無授權、無金流、無敏感資料）；H5 無條件保護 `.github/**`、`CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/**`。
- `catalog-info.yaml` 設定 `factory.io/agent-automerge: "false"`（依 `risk-paths.yml` 註解），每個 PR 都需人類核准。

---

## 4. 證據與根因

> 本節是分析型的「可重現步驟／引用檔案與行號」。因為這是現況盤點（非缺陷修復），「根因」表述為「現況事實及其成因（設計選擇／漂移）」。

### 4.1 驗證方式與實測結果（明確驗證命令）

在 `HEAD=b624bbf`、node `v22.21.1` 的 workspace 內以既有 devDependencies 安裝後執行（**不跑需外部服務的 E2E**）：

```bash
npm run build                                    # exit 0（tsc ESM + CJS）
./node_modules/.bin/ava --verbose dist/esm/fixes.test.js
#   → 9 tests passed / 0 failed
node --test specs/oracle/counterexamples.test.mjs
#   → # tests 11 / # pass 11 / # fail 0 / # skipped 0（約 3.8s）
```

**未執行**（依 Issue DoD「不跑需外部服務的 E2E」，且本環境無 docker daemon）：

- `yarn test` 全量 AVA（需 `docker-compose.yml` 的 23 個 Redis 與固定 hostname）。
- `oracle:redis`（需真 Redis）。
- `.github/workflows/ci.yml` 的 docker compose 流程。

> 環境註記：本 harness 的 `yarn` 因上層 `package.json` 宣告 `packageManager: pnpm@…` 而拒絕執行，故以 `npm run build` 與直接呼叫 `node_modules/.bin/ava` 取代；在 CI 的 `node:16` 容器內 `yarn` 正常。這是 harness 環境差異，不是 repo 缺陷。

### 4.2 事實 F1：CI 觸發分支不含工廠 trunk

- `ci.yml:3-7` 的 `push`/`pull_request` 都限定 `branches: [main]`。
- `git ls-remote --heads origin` 顯示 `refs/heads/main = afe5cf9…`、`refs/heads/software-factory = b624bbf…`；工廠工作項的 PR base 是 `software-factory`（本 run 的 `BASE_BRANCH`）。
- 因此 `pull_request` 事件不匹配 `main`，`Build & Test` 與 CodeQL 都不會對 factory PR 執行。
- 佐證：本 run 以 repo 權限查 `gh run list` 回傳空清單（不論是「確實沒有執行」或 token 無 Actions:read，至少無法觀察到任何執行紀錄）。
- **成因**：`ci.yml` 沿用上游 `mike-marcacci/node-redlock` 的 `main` 觸發設定，未隨工廠納管把 trunk 改為 `software-factory`。

### 4.3 事實 F2：`Lint the source` 步驟現況必紅

`package.json:65`：

```
"lint": "prettier -c '**/*.{json,yml,md,ts}' && eslint src --ext ts"
```

在 `HEAD=b624bbf`、未加入本報告前實測：

```bash
./node_modules/.bin/prettier -c '**/*.{json,yml,md,ts}'
# exit 1；4 個既有檔案格式不合規：
#   [warn] .github/factory/risk-paths.yml
#   [warn] docs/research/4-quint-spec-feasibility.md
#   [warn] docs/research/6-quint-executable-spec-analysis.md
#   [warn] specs/FM-agent/231-fm-agent-adoption-analysis.md
```

`ci.yml:22` 的 lint 步驟沒有 `continue-on-error`，`&& eslint` 也不會被執行；由於 lint 是 build/test 之前的步驟，整個 job 在第一步就中止。

### 4.4 事實 F3：測試與 docker-compose 網路耦合

- `src/single.test.ts:548` `run("instance", new Redis({ host: "redis-single-instance" }))`；`:550` `run("cluster", new Cluster([{ host: "redis-single-cluster-1" }]))`。
- `src/multi.test.ts:317-328` 連 `redis-multi-instance-a/b/c` 與 `redis-multi-cluster-a-1/b-1/c-1`。
- 這些名稱只存在於 `docker-compose.yml` 的服務定義（例如 :17-18、:89-99、:134、:175、:216）。在 host 上直接 `yarn test` 會 DNS 解析失敗；`CONTRIBUTING.md` 也明確要求走 docker compose。
- **成因**：作者刻意用 docker compose 提供「真 Redis / 真 cluster」的一致性環境（`CHANGELOG.md` v5.0.0-beta.1：Use docker compose to test against real clusters）。代價是測試無法在沒有 docker 的環境（含部分 CI runner 與工廠 sandbox）執行。

### 4.5 候選缺陷 F4：single cluster 初始化位址重複／遺漏

`docker-compose.yml:89`：

```
redis-cli -p 6379 --cluster create 10.0.0.11:6379 10.0.0.12:6379 10.0.0.13:6379 10.0.0.14:6379 10.0.0.14:6379 10.0.0.16:6379 --cluster-replicas 1 --cluster-yes
```

- 位址序列是 `…13, 14, 14, 16`：`.14` 出現兩次、`.15` 缺席；而 `redis-single-cluster-5` 定義在 `docker-compose.yml:67-78`，IP 為 `10.0.0.15`（:76）。
- compose 仍會在 `depends_on`（:94-98）中啟動 5 號機，但它不會被加入 cluster。
- 可能的後果（**本 run 未實測，無 docker**）：`--cluster-replicas 1` 需要偶數且足夠的節點，重複位址會讓 `--cluster create` 失敗或只建出非預期拓樸，`cluster_state:ok` 不成立；而 `waitForCluster()`（`src/single.test.ts:34-65`）是無上限的 `while` 迴圈，會讓 cluster namespace 的測試**無限等待**而非快速失敗。

### 4.6 事實 F5：工具鏈與 action 版本漂移

- 固定 `node:16`（`docker-compose.yml:227,244,286`），`engines: node>=12`（`package.json`）；本 run 的 node 22 已能編譯與跑測試，但 `--experimental-specifier-resolution=node`（`package.json:45`）是淘汰路徑。
- `actions/checkout@v2`、`codeql-action@v1`（2022 年版本）、`action-docker-layer-caching@v0.0.11` 皆已停止維護；`docker-compose`（v1 指令，`ci.yml:19`）與 `docker compose`（v2 指令，`ci.yml:22,24,26,29`）在同一 workflow 混用。

### 4.7 事實 F6：AVA 快取檔被入版控

`git ls-files dist` 顯示追蹤了三個非輸出檔：

```
dist/cjs/package.json
dist/esm/package.json
dist/esm/node_modules/.cache/ava/failing-tests.json   # AVA 的失敗測試快取（內容 []）
```

`.gitignore` 只排除 `/dist/**/*.js|.js.map|.d.ts`，未排除 dist 下的 `.json` 或 `.cache`。任何在本機跑過 AVA 的人都可能改動這個追蹤檔、汙染 `git status`。

### 4.8 事實 F7：無 coverage 與 `test/` 慣例

- 無 coverage 產生器、無 CI coverage 上傳；`.coveralls.yml` 是孤兒設定。
- 測試與 src 同目錄，對熟悉 `test/` 慣例的 agent/contributor 是隱性知識（本報告 §2.1 顯式記錄）。

---

## 5. 影響範圍

**受影響**

- **貢獻者／開發者**：`CONTRIBUTING.md` 與 README 只說「用 docker compose」，沒有列出測試分層（AVA vs oracle）、哪些需要 Redis、如何在 host 只跑無外部依賴的子集。新進者容易直接 `yarn test` 失敗。
- **PR 審查者**：factory PR 到 `software-factory` **沒有 target repo 的自動測試訊號**；審查者只能依賴 software_factory repo 的 factory crosscheck（格式/範圍）與人工閱讀。
- **後續 factory 工作項**：`agent-add-tests`／`agent-fix-bug` 若不知道「測試在 `src/`、需先 build、E2E 需 docker-compose」，會放錯路徑或誤以為可在 sandbox 跑全量測試。本報告即是該隱性知識的落點。
- **依賴更新**：`dependabot.yml` 未設 `target-branch`，每日 PR 預設對 `main`，與工廠 trunk `software-factory` 分岐，更新不會自動流到工廠分支。
- **CI 健康度**：`Lint the source` 現況已紅；`docker-compose.yml:89` 的 cluster 位址問題若成立會讓 `Run tests` 卡死至 job timeout。

**不受影響**

- `src/index.ts` 的執行期行為與對外 API（本 run 未改任何程式碼）。
- 套件發佈內容（`package.json` `files` 只含 dist 下 3 個產物）。
- H1–H3 高風險路徑：`risk-paths.yml` 中 H1/H2/H3 皆留空，且本變更只新增 `docs/research/` 檔案。

**未涵蓋／無法在本 run 判定**

- 實際 Actions 執行歷史（`gh run list` 空清單，權限或事實不明）。
- `docker-compose.yml` cluster 建立是否真的失敗（F4，需 docker daemon）。
- factory workflow 本體（位於 `software_factory` repo，不在本 repo）。

---

## 6. 方案比較

本 Issue 是 `agent-analyze`，產出必須是 `docs/` 下的報告，**不得實作**。以下比較「如何滿足本 Issue」以及「後續要開什麼工作項」。

### 方案 A（採用）：單一現況盤點報告於 `docs/research/`

- **做法**：本檔 `docs/research/10-test-structure-and-ci-inventory.md`，涵蓋測試結構、執行環境、CI 設定、可在沙箱重現的驗證命令、影響範圍與後續工作項草案。
- **優點**：完全符合 analyze 白名單與 Issue PRD「只新增文件」；不改 CI／程式；提供 file:line 可查核；可作為後續多個工作項的共同依據。
- **缺點**：不直接修好任何一條 CI/測試問題，需人類裁決後另開工作項。

### 方案 B（拒絕）：直接把「測試怎麼跑」寫進 README / CONTRIBUTING

- **優點**：讀者最直覺；文件更靠近入口。
- **拒絕理由**：(1) 本工作項明文「變更只允許 `docs/` 下的報告檔」，修改 `README.md`/`CONTRIBUTING.md` 已越界；(2) 屬 `agent-write-docs` 的職責，且目前尚未裁決 CI 觸發分支要不要改，先寫進主要文件會把未定案的現況固化成文件。→ 建議另開 `agent-write-docs`（見 §7 WI-D）。

### 方案 C（拒絕）：本 run 直接修 `ci.yml` 讓它跑 `software-factory` PR

- **優點**：一步解決 F1，讓工廠 PR 立刻有 Build & Test。
- **拒絕理由**：(1) 修改 CI 設定觸發 `factory-stop-rules` 第 3 條（需修改 CI 設定／branch protection）；(2) analyze 型別禁止實作，`factory-crosscheck --analyze-only` 只允許 `docs/`。→ 這只能是後續工作項，且 PR 需人類核准。

### 方案 D（拒絕）：把測試搬到 `test/` 並補 coverage

- **優點**：符合常見慣例、可接 coveralls。
- **拒絕理由**：範圍遠超本 Issue；搬家會動到 `tsconfig.json` include、`package.json` test glob、docker entrypoint 與全部 import 路徑，屬高風險重構，且與「盤點現況」無關。

### 方案 E（延後）：修 `docker-compose.yml:89` single cluster 位址

- **優點**：若 F4 成立，可讓 cluster namespace 測試穩定。
- **延後理由**：屬設定/程式變更，且**尚未實測**；應先以 docker 重現確認，再開 `agent-fix-bug`（見 §7 WI-C）。

---

## 7. 建議下一步（可直接開成工作項）

> 以下每個工作項都含草案驗收條件，供人類裁決後 dispatch；本報告不具放行效力。

### WI-A ｜讓 target repo CI 覆蓋工廠 trunk（建議 `agent-write-docs` 或 `agent-fix-bug`，需人審 CI 變更）

- **描述**：調整 `.github/workflows/ci.yml` 與 `.github/workflows/codeql-analysis.yml` 的觸發分支，使 PR/ push 到 `software-factory` 也會執行（或明確決策：維持 target CI 只在 `main`，於文件載明工廠 PR 的品質防線僅為 factory crosscheck）。
- **草案驗收條件**：
  - AC-A1：`ci.yml` 的 `on.pull_request.branches`（與 `on.push.branches`）涵蓋 `software-factory`，或工作項明確載明刻意不涵蓋並說明防線替代方案。
  - AC-A2：對一個 `factory/*` 分支開測試 PR，Actions 頁面可觀察到 `Continuous Integration / Build & Test` 被觸發。
  - AC-A3：`main` 的既有觸發語意不變，且未修改 branch protection / CODEOWNERS。
- **風險**：修改 CI 設定屬 `factory-stop-rules` 第 3 條；PR 必經人類核准（`agent-automerge: false`）。

### WI-B ｜修正既有 prettier 格式問題，讓 `Lint the source` 能前進（建議 `agent-fix-bug` 或 `agent-update-deps` 風格的單層 PR）

- **描述**：對 §4.3 列出的 4 個檔案執行 `prettier --write`（純格式），使 `yarn lint` 不再第一步失敗。
- **草案驗收條件**：
  - AC-B1：`npx prettier -c '**/*.{json,yml,md,ts}'` exit 0。
  - AC-B2：`git diff` 只含空白/排版變更，無語意變更（特別是 `risk-paths.yml` 的 pattern 與註解內容不得改動語意）。
  - AC-B3：`eslint src --ext ts` exit 0。

### WI-C ｜驗證並修正 docker-compose 的 single cluster 初始化（建議 `agent-fix-bug`，需 docker 環境）

- **描述**：以 docker 重現 F4；若 `redis-single-cluster-5`（`10.0.0.15`）確實被漏掉，修正 `docker-compose.yml:89` 的 `--cluster create` 位址清單。
- **草案驗收條件**：
  - AC-C1：`docker compose up -d` 後，`redis-cli -h 10.0.0.11 cluster info` 回 `cluster_state:ok`。
  - AC-C2：`redis-cli -h 10.0.0.11 cluster nodes` 可見 6 個節點（3 master / 3 replica）。
  - AC-C3：`yarn test` 的 `cluster` namespace（single 與 multi）全數綠燈，不再卡在 `waitForCluster()`。

### WI-D ｜在主要文件補「測試與 CI 現況」章節（建議 `agent-write-docs`）

- **描述**：把本報告 §2–§3 的可操作部分寫進 `CONTRIBUTING.md`（或 README 開發段），含可直接複製的指令與 CI 觸發現況。
- **草案驗收條件**：
  - AC-D1：文件含三個層級的可複製指令：全套 `docker compose run --rm runner yarn test`、無外部依賴的 `ava dist/esm/fixes.test.js`、`yarn oracle:mock`。
  - AC-D2：明確標示哪些測試需要真 Redis／docker，哪些可在無外部服務環境執行。
  - AC-D3：內容與本報告 §2、§3 的事實一致（含 `software-factory` 不被 `ci.yml` 觸發的現況，若 WI-A 已修正則同步更新）。

### WI-E ｜清理殘留設定（建議 `agent-update-deps` / `agent-write-docs`，低優先）

- **描述**：移除或更新 `.travis.yml`（`npm run test-ci` 不存在）、`.coveralls.yml`（無 coverage 接線）、`.jshintrc`（無 jshint）、未追蹤用途的 `dist/esm/node_modules/.cache/ava/failing-tests.json`（並在 `.gitignore` 排除 dist 下的快取）。
- **草案驗收條件**：
  - AC-E1：刪除/更新後 `git status` 乾淨，且不影響 `yarn test`、`yarn oracle`。
  - AC-E2：`.gitignore` 能涵蓋未來產生的 AVA 快取（以實際跑一次 AVA 驗證不再出現追蹤檔變更）。

---

## 8. 附錄：檔案與行號速查

| 主題              | 位置                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------- |
| AVA 設定          | `package.json:43-46`                                                                                    |
| 測試 / build 指令 | `package.json:66`、`:68`、`:69`；oracle `:70-72`                                                        |
| lint / format     | `package.json:64-65`                                                                                    |
| single 測試註冊   | `src/single.test.ts:80,98,138,202,248,281,336,422,465`；`run()` `:548,550`                              |
| multi 測試註冊    | `src/multi.test.ts:95,177,263`；`run()` `:317,324`                                                      |
| fixes 測試註冊    | `src/fixes.test.ts:165,195,219,261,361,387,438,506,551`；`MockRedisClient:41`                           |
| cluster 等待邏輯  | `src/single.test.ts:34-65`（`waitForCluster`，無上限 while）                                            |
| tsconfig          | `tsconfig.json:include ["./src/**/*"]`；`tsconfig.cjs.json`                                             |
| CI 觸發           | `.github/workflows/ci.yml:3-7`                                                                          |
| CI 步驟           | `.github/workflows/ci.yml:14,16,19,22,24,26,29`                                                         |
| CodeQL            | `.github/workflows/codeql-analysis.yml:3-8,21,23,27,29`                                                 |
| Travis（死設定）  | `.travis.yml:7`（`npm run test-ci` 未定義）                                                             |
| 工廠護欄          | `.github/factory/risk-paths.yml`（H1–H3 空、H5 保護 `.github/**` 等）                                   |
| docker 服務       | `docker-compose.yml:17-18,67-78,89,227,244,286`；`scripts/await.sh:1-8`                                 |
| 被追蹤的 dist     | `dist/cjs/package.json`、`dist/esm/package.json`、`dist/esm/node_modules/.cache/ava/failing-tests.json` |

### 本 run 的 DoD 對照

| 條目                                         | 狀態   | 說明                                                                                              |
| -------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------- |
| DoD-1 有可驗證的測試/驗證方式                | passed | §4.1 提供可在沙箱重現的明確驗證命令與實測結果                                                     |
| DoD-2 不觸碰高風險路徑（H1–H3）              | passed | 本 run 只新增 `docs/research/` 報告；`risk-paths.yml` 的 H1–H3 皆留空                             |
| DoD-3 跑測試確認綠燈（不跑需外部服務的 E2E） | passed | `npm run build` exit 0；AVA fixes 9/9 pass；oracle:mock 11/11 pass；redis/docker 依賴項依規不執行 |
