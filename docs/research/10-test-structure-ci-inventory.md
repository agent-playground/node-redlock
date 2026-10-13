# 10 — node-redlock 測試結構與 CI 設定現況盤點（agent-analyze）

> **任務類型**：`agent-analyze`——僅分析、不實作；變更只允許 `docs/research/` 下的報告檔。
> **分析對象**：Issue #10（repo `agent-playground/node-redlock`，工廠 trunk `software-factory`）。
> **日期**：2026-10-13 · **目標 repo HEAD**：`b624bbf`（fix: resolve even-node tie votes as against…）。
> **測量環境**：node 22.21.1、npm 10.9.4、prettier 2.8.8、ava 4.3.3、typescript 4.6.x（無 lockfile，浮動安裝）。
> **狀態**：分析報告，**不具放行效力**；「建議下一步」供人類裁決後另開工作項。

---

## 0. 結論摘要（一頁）

node-redlock 的測試由三個互相獨立的層構成，但**工廠 trunk 上的 PR 不會執行其中任何一層的 CI**：

| 層              | 框架／入口                                                                     | 規模             | 外部依賴                                                                                  | 何時被執行                                        |
| --------------- | ------------------------------------------------------------------------------ | ---------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------- |
| ava 整合測試    | `src/{single,multi,fixes}.test.ts` → 編譯到 `dist/esm` 執行                    | 33 個測試        | single/multi 需 23 個 docker redis 容器；**fixes 用 mock、零外部依賴**                    | 僅 `ci.yml`（只在 `main` 觸發）與本機 `yarn test` |
| 反例神諭 oracle | `specs/oracle/*.test.mjs`（node:test）                                         | 29 個測試        | counterexamples(11) 用假 Redis、**零外部依賴**；lua-parity(14)＋ real-redis(4) 需真 Redis | 僅手動 `yarn oracle*`，**不在任何 CI**            |
| 形式化規格      | `specs/redlock.qnt`／`redlockTest.qnt`（Quint 0.32.0）＋ `specs/uppaal/`（F9） | 不變式＋ witness | 需 Java（Apalache）                                                                       | 僅手動，**不在任何 CI**                           |

**四個關鍵現況發現**（證據見 §1）：

1. **CI 與 trunk 脫節**：`ci.yml` 與 `codeql-analysis.yml` 的觸發條件都是 `branches: [main]`，而工廠 PR 的合併目標是 `software-factory`。兩條線已分岔——`origin/main` 的樹中**沒有** `docs/`、`specs/`、`catalog-info.yaml`、`.github/factory/`。因此：**每一顆 factory PR 與每一次 trunk push 都不跑 repo 自己的 CI**，「CI 綠燈」在此 repo 對工廠流程是空集合。
2. **lint 閘門在 trunk HEAD 即是紅的**：`npm run lint`（prettier 檢查）在 `b624bbf` 實測 **exit 1**，4 個既有檔案未通過格式檢查（見 §1.3）。這不是本報告造成；且 `prepublishOnly` 含 `yarn lint`，代表**目前此分支無法 publish**。
3. **無 lockfile → 工具與相依浮動**：`.npmrc` 寫 `package-lock=false`，`.gitignore` 忽略 `yarn.lock`。dependabot 設定存在但 **remote 上看不到任何 `dependabot/*` 分支**（npm ecosystem 缺 lockfile 無法運作）；CI 每次浮動安裝，lint 結果可能隨 prettier 版本漂移。
4. **可驗證子集全綠（本次實測）**：不需外部服務的測試——`yarn build` ✓、`ava fixes.test.js` **9/9 pass**、`node --test specs/oracle/counterexamples.test.mjs` **11/11 pass**。需外部服務者（single/multi 33 個中的 24 個、oracle redis 18 個）依 DoD「不跑需外部服務的 E2E」未執行，但其依賴已在 §1.1 以檔案行號定位。

**風險定性**：測試資產本身健康（分層清楚、mock 可獨立跑、反例接地設計良好），問題在**接線**——CI 觸發、格式閘門基線、lockfile、元資料四處脫落，使「 mechanically 驗證過的綠燈」在工廠流中不存在。修法都是小變更，但其中三處（`.github/**`、`catalog-info.yaml`）受 H5 硬規則保護，**agent 不得自行修改，需人類執行或明確授權**。

---

## 1. 證據與根因

### 1.1 測試結構盤點（可重現：下列路徑與行號取自 HEAD `b624bbf`）

**ava 整合測試（`src/`，TypeScript，ESM）**

- 執行鏈：`yarn build`（tsc → `dist/esm`＋`dist/cjs`）→ `yarn test` = `cd dist/esm && ava --verbose *.test.js`（`package.json:68`）。**測試從編譯產物執行，不直接跑 `src/*.ts`**；改測試後忘記 build 會跑到舊碼。
- `src/single.test.ts`：`run()` 模板函式定義 9 個測試（行 80、98、138、202、248、281、336、422、465），以兩個 namespace 各跑一次：`run("instance", new Redis({ host: "redis-single-instance" }))`（行 548）與 `run("cluster", new Cluster([{ host: "redis-single-cluster-1" }]))`（行 550）。主機名單是 **docker compose 網路的 DNS 名稱**，容器網路外無法解析 → 18 個測試全部需要 `docker compose` 環境（唯一例外：行 202「redis is unreachable」測試的是連線失敗路徑，但仍需 ioredis 可載入）。
- `src/multi.test.ts`：3 個測試（行 95、177、263）× 2 個 namespace：instance（3 台 `redis-multi-instance-a/b/c`，行 319-321）＋ cluster（3 集群 `redis-multi-cluster-*-1`，行 326-328）→ 6 個測試，同樣需 docker 網路。
- `src/fixes.test.ts`：**9 個測試**（行 165、195、219、261、361、387、438、506、551，含 2 個 `test.serial`），用自帶 `MockRedisClient`（行 41 起）在記憶體實作三段 Lua script 語意，`ioredis` 僅 `import type`——**完全不需要外部服務**。腳本判別式（行 14-30）註明刻意兼容修復前／後兩種 script 原文，使同一 mock 可做紅綠對照。此檔是 PR #9／HEAD `b624bbf` 修復（F1/F5/F2/F6/F7 ＋偶數節 tie）的回歸測試。
- ava 設定僅 `nodeArguments: ["--experimental-specifier-resolution=node"]`（`package.json:43-47`）——node 22 已移除該旗標；實測 `ava fixes.test.js` 在本機仍正常（9/9 綠），但這是上游 beta 遺留設定，屬脆弱點。

**反例神諭（`specs/oracle/`，node:test，直接跑 `.mjs`）**

- `counterexamples.test.mjs`：11 個測試，import `dist/esm/index.js`（真實實作）＋ `fakeRedis.mjs`（按 script 原文推導語意的假 Redis，`evalsha` 一律 NOSCRIPT 逼出 eval fallback）。**零外部依賴**，需先 build。
- `lua-parity.test.mjs`：14 個測試，需真 Redis（`ORACLE_REDIS_PORT`，預設 6399；`specs/oracle/README.md` 給 docker 一行啟動法）。防「循環論證」的語意公證：證假 Redis 與真 Lua 逐情境一致。
- `real-redis.test.mjs`：4 個測試，真 Redis 端到端。
- 反假綠燈設計：`node --test` 在 skip 時仍 exit 0，故兩支 Redis 測試在 `process.env.CI` 存在時**連不上直接 throw**（`lua-parity.test.mjs:76-79`），拒絕靜默略過。
- npm scripts：`oracle`／`oracle:mock`／`oracle:redis`（`package.json:70-72`）。**三支都不在 `ci.yml`**。

**形式化規格（`specs/`，不在任何測試自動化內）**

- `redlock.qnt`（參數化規格，不可直接 run）＋ `redlockTest.qnt`（實例＋ run 測試）；`specs/README.md` 給完整重跑指令（`npx quint typecheck`、`npx quint run specs/redlockTest.qnt --main=redlockDefault --max-steps 12`）與 CI 草稿——**草稿尚未接進 `.github/workflows/`**。
- `specs/uppaal/`：F9 專屬時間自動機＋`verify.sh` 閘門；`specs/traces/`（as-fixed 反例）＋`specs/traces/as-is/`（歷史證據）。
- 工具鏈是 devDependency `@informalsystems/quint@0.32.0`（唯一 lockstep 釘死的版本）。

**docker-compose.yml（測試環境本體）**

- 23 個 redis 容器（1 single ＋ 3 multi-instance ＋ 6 ＋ 1 集群建群＋ 9 multi-cluster ＋ 3 建群）＋ `installer`（`yarn`）＋ `builder`／`runner`（node:16）。
- `builder`/`runner` 用 `scripts/await.sh` 輪詢等檔案出現再執行（`docker-compose.yml:246、288`）；CI 以 `docker compose run --rm --no-TTY runner yarn test` 覆蓋 `command`，entrypoint 的 await 鏈保留——設計可用的同時也很脆弱（await 無 timeout）。
- 注意 `redis-single-cluster` 建群命令重複了 `10.0.0.14`、漏了 `10.0.0.15`（`docker-compose.yml:89`）——6 個位址搭配 `--cluster-replicas 1` 本應形成 3 主 3 從，但重複位址使 `redis-cli --cluster create` 無效（實務上應直接報錯或錯配）；屬**測試環境設定缺陷**（本次未跑 E2E，無法從綠燈與否判定其實際影響面）。

### 1.2 CI 設定盤點

| 檔案                                    | 觸發                                           | 實際檢查                                                                                    | 現況判定                                                                                                                                                           |
| --------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `.github/workflows/ci.yml`              | `push`/`pull_request` **僅 `main`**（行 5、7） | docker：`yarn lint` → `yarn build` → `yarn test`（行 22-26）                                | 對工廠 trunk **永不觸發**；且 lint 步驟依 §1.3 於 sf HEAD 會紅                                                                                                     |
| `.github/workflows/codeql-analysis.yml` | 僅 `main`＋每週排程                            | CodeQL **javascript**（`autobuild`）；actions/checkout@v2、codeql-action@v1（皆過時）       | 僅 `main` 觸發＝對 sf 永不執行；v1 已在上游棄用週期之外                                                                                                            |
| `.github/dependabot.yml`                | npm，每日                                      | `open-pull-requests-limit: 10`                                                              | **形同虛設**：repo 無 lockfile（見下）；remote 分支清單中 `dependabot/*` 數量為 0                                                                                  |
| `.travis.yml`＋`.coveralls.yml`         | —                                              | `script: npm run test-ci`；node 10/12/14 matrix                                             | **死設定**：`package.json` 沒有 `test-ci` script（`grep '"test-ci"' package.json` 零命中），Travis 亦未接管                                                        |
| `.github/factory/risk-paths.yml`        | 工廠 crosscheck 消費                           | H1–H4、H6–H7 空清單；H5 ＝`.github/**`、`CODEOWNERS`、`catalog-info.yaml`、`.dsh/skills/**` | 現況文件；**H5 意味上表三項修復 agent 都不能自行做**                                                                                                               |
| `catalog-info.yaml`                     | 工廠評分/分派消費                              | `agent-automerge: "false"`、`test-framework: ava`、`stack: typescript`                      | 元資料已漂移：行 80 註明「掃描未發現 specs/ 或 .qnt」——**不實**，`specs/redlock.qnt` 等已隨 PR #5/#8 合併進 trunk；`test-framework: ava` 也未涵蓋 node:test 神諭層 |
| 工廠 CI（harness 側）                   | 每顆 PR                                        | `factory-crosscheck --analyze-only`：分支前綴、白名單路徑、`requirements` 欄位              | 只驗**結構**（改了哪些檔、回報是否誠實），**不執行 build/lint/test**                                                                                               |

lockfile 證據：`ls yarn.lock package-lock.json` → 兩者皆不存在；`.npmrc`＝`package-lock=false`；`.gitignore` 明列 `/package-lock.json`、`/yarn.lock`。CI 的 `installer` 每次 `yarn` 浮動解析 `^` range（prettier 2.x、ava 4.x、typescript ~4.6.2、quint 0.32.0 唯一釘死）。

### 1.3 實測驗證（本次 run 實際執行，全部可在本機重現）

| 命令（本機，不需外部服務）                                                   | 結果                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm install --ignore-scripts`（無 lockfile）                                | rc 0，325 packages，node v22.21.1                                                                                                                                                                                                                                                |
| `npm run build`（tsc ＋ tsc -p tsconfig.cjs.json）                           | **rc 0**，產出 `dist/esm/{index,single.test,multi.test,fixes.test}.js`                                                                                                                                                                                                           |
| `cd dist/esm && CI=true ../../node_modules/.bin/ava --verbose fixes.test.js` | **9 tests passed**（含偶數節 tie 存活測試）                                                                                                                                                                                                                                      |
| `node --test specs/oracle/counterexamples.test.mjs`                          | **11 pass / 0 fail / 0 skipped**（與 `specs/oracle/README.md` 實測紀錄一致）                                                                                                                                                                                                     |
| `npm run lint`                                                               | **exit 1**——prettier 警告 4 檔：`.github/factory/risk-paths.yml`、`docs/research/4-quint-spec-feasibility.md`、`docs/research/6-quint-executable-spec-analysis.md`、`specs/FM-agent/231-fm-agent-adoption-analysis.md`（均為既有檔案，非本報告；本報告提交前已過 `prettier -c`） |
| `ava single.test.js`／`multi.test.js`、`oracle:redis`                        | **依 DoD 未執行**（需外部 Redis／docker DNS；依賴點已定位至 §1.1 行號）                                                                                                                                                                                                          |

紅 → 綠判準（供後續工作項驗收）：lint 由 exit 1 → 0 即為上述 4 檔轉綠；CI 觸發修復的判準是「對 `software-factory` 開 PR 時 Actions 頁出現 `Continuous Integration` 執行紀錄」。

### 1.4 根因分析

- **RC1（CI 對工廠流失效）**：repo 由上游 fork 納管，工廠 trunk 設為 `software-factory`，但 `.github/workflows/` 的觸發分支沿用上游 `[main]` 未同步。納管工作項（#1/#2）盤點了風險路徑與 catalog，未涵蓋 workflow 觸發条件——此为範圍缺口而非設定錯誤。證據：`ci.yml:5、7`；`git ls-tree origin/main` 無 `docs/`、`specs/`、`catalog-info.yaml`（即 main 是上游血統）。
- **RC2（lint 紅基線）**：`docs/research/*`（PR #5/#8）、`.github/factory/risk-paths.yml`（PR #2）、`specs/FM-agent/*` 合併時，**沒有任何機械閘門會跑 lint**（RC1），格式漂移得以累積；此 workspace 為 shallow clone（`git rev-list --count software-factory` ＝ 1），無法逐 commit 驗證「合併當時是否綠」，亦無法排除 prettier 浮動版本（RC4）造成的「昔日綠、今日紅」。兩因至少其一成立，主因無法從现有證據區分——**如實回報**。
- **RC3（dependabot 無效）**：npm ecosystem 需要可解析的 lockfile；本 repo 刻意忽略兩者 → dependabot 無 PR 可提（remote 零 `dependabot/*` 分支與之一致）。
- **RC4（版本不可重現）**：上游 node-redlock 即無 lockfile 政策；納管後未補。工具閘門（lint）的判定基準因而會漂移——這是 RC2「無法判定昔日是否綠」的直接原因。
- **RC5（元資料漂移）**：`catalog-info.yaml` 掃描紀錄日期 2026-09-13，早於 specs 文獻合併；無任何機制在 `specs/` 出現後要求更新 annotation。

### 1.5 限制（誠實聲明）

本次未執行任何需外部服務測試；未啟動 docker compose（DoD 明文排除，且 23 容器矩陣耗時）；未驗證 `origin/main` 上 CI 的近期實際狀態（shallow ＋未跑 github CLI run 查詢）；Quint/UPPAAL 層本次未重跑（其重跑紀錄在 `specs/README.md`）。

---

## 2. 影響範圍

- **工廠流程（直接）**：所有以 `software-factory` 為 base 的 PR（未來每個工作項）得不到 repo CI 訊號；人類審查者看到的「綠」只有 crosscheck 結構訊號，易誤讀為「測試通過」。lint 紅基線讓「跑 lint 驗證」這類步驟**先天失敗**，未來的 agent 可能把自己的 PR 誤歸因成紅燈來源。
- **發布鏈**：`prepublishOnly: yarn install && yarn lint && yarn build`（`package.json:74`）在 sf HEAD 會因 lint 紅而**擋死 publish**（若此 fork 有發佈需求）。
- **測試資產的使用者**：fixes/oracle:mock 是唯一可零依賴驗證的迴歸網（20 斷言），但文件上無一處說明「本地怎麼只跑綠的子集」——本報告補上（§1.3）。不知情的貢獻者只能整套 docker compose。
- **下游相依者**：無 lockfile ＋ dependabot 失效＝安全修補與向後相容性更新全靠手動；`node >= 12` engines 與 CI node:16、本機 node 22 三者不一致（beta 版 ava 旗標見 §1.1）。
- **修正可行性的邊界**：RC1/RC2/RC5 的修復位置全在 H5（`.github/**`、`catalog-info.yaml`）或需先修 H5 內檔案（risk-paths.yml 是 prettier 警告檔案之一）——**agent 依停手規則不得自行修改**，只能開出工作項由人類執行或明確核准。

---

## 3. 方案比較（修復接線的方式）

**方案 A：repo 內對齊——擴大觸發分支＋修 lint 基線＋補 lockfile（推薦）**

1. `ci.yml`／`codeql` 觸發加 `software-factory`（或改用 trunk 變數）；2. 修 4 個 prettier 警告檔；3. 提交 lockfile（同時調整 `.npmrc`/`.gitignore`）讓 lint 判定不再漂移；4. dependabot 複活（順帶加 `docker` ecosystem 管 node:16/redis:6）。
   成本：一個小型 PR 鏈；`.github/**`＋`catalog-info.yaml` 部分必須人類出手或逐 PR 核准。收益：機械閘門回到 factory 流，之後所有工作項（含 fix-bug 的紅 → 綠流程）才有「CI 綠」可言。**注意**：觸發打開後 `yarn lint` 若未先修，ci.yml 的 lint 步驟就會在 sf PR 上紅——A 的內部順序必須是先修 lint 基線、再開觸發。

**方案 B：不動 repo——factory dispatch 端代跑可零依賴子集**

在工廠 workflow 內對 analyze/fix 型工作項統一執行 `npm run build && ava dist/esm/fixes.test.js && node --test specs/oracle/counterexamples.test.mjs`（本報告實測 <30 秒全綠）。
被拒為**唯一**方案，理由：(1) 驗證訊號掛在 dispatch run，不掛在 PR check runs，審查者仍看不到；(2) 改的是 software_factory（工廠自身）而非本 repo，超出本 Issue 範圍並增加跨 repo 耦合；(3) 治標——lint/dependabot/元資料漂移照舊。**可作為 A 落地前的臨時補充**，與 A 不互斥。

**方案 C：測試框架統一——ava 遷移到 node:test、移除 docker compose 矩陣（被拒）**

理由：改動核心測試語意（33 個測試＋ 23 容器契約），風險與範圍都超出「盤點＋接線」；mock 層（fixes、counterexamples）本來就能獨立跑，E2E 矩陣是 Redlock 演算法驗證的必要環境，移除它等於放棄多節點／集群真實行為的覆蓋。違反本工作項「不產生程式碼變更」，亦無對應收益。

**方案 D：本次 run 直接起 docker compose 全綠驗證（被拒）**

理由：DoD 明文「不跑需外部服務的 E2E」；且 23 容器矩陣屬上游 CI 的既有成本，分析 run 不需要也買不到额外證據（§1.3 子集已足以支撐結論）。

---

## 4. 建議下一步（可直接開成工作項）

> 每項附驗收條件草案。路徑標記：**H5 ＝需人類執行或明確核准**（依 `.github/factory/risk-paths.yml`）；agent 型別沿用工廠命名。

**WI-1（先行，人類或核准後 agent-fix）：修 lint 紅基線——4 個 prettier 警告檔**

- 內容：對 `.github/factory/risk-paths.yml`（H5 內）、`docs/research/4-*.md`、`docs/research/6-*.md`、`specs/FM-agent/231-*.md` 跑 `prettier --write`，**純格式、零語意變更**。
- 驗收：(1) `npx prettier -c '**/*.{json,yml,md,ts}'` exit 0；(2) diff 逐檔為格式性（無字串內容語意變化，risk-paths.yml 需人類複核正則模式未被折行破壞）；(3) `git diff --stat` 不含 `src/`。

**WI-2（人類，H5）：CI 觸發對齊工廠 trunk**

- 內容：`ci.yml` 與 `codeql-analysis.yml` 的 `branches: [main]` 加入 `software-factory`；順手升級 `actions/checkout@v2→v4`、`codeql-action/init@v1`（棄用）、CodeQL `language` 由 `javascript` 改 `javascript-typescript`。依賴 WI-1 先綠，否則觸發即紅。
- 驗收：(1) 對 sf 開一個無害 PR，Actions 頁出現 `Continuous Integration` run 且通過；(2) CodeQL run 出現且非弃用警告；(3) main 上原有行為不退化。

**WI-3（agent-update-deps ＋人類確認）：lockfile 落地，dependabot 複活**

- 內容：決定包管理器（repo 文件多用 yarn，CI installer 用 yarn——建議 `yarn.lock`），移除 `.gitignore` 的 lockfile 行與 `.npmrc` 的 `package-lock=false`（如選 npm），提交 lockfile。
- 驗收：(1) `yarn install --frozen-lockfile`（或 `npm ci`）在乾淨 checkout exit 0；(2) `docker compose run installer yarn install --frozen-lockfile` 於 CI 綠；(3) 合併後 24 小時內 dependabot 出現 ≥1 個更新 PR，或在 Issue 紀錄「掃描週期內確無可更新項」的證據。

**WI-4（人類，H5）：catalog-info 元資料校正**

- 內容：`catalog-info.yaml` 補 `factory.io/quint-spec`（specs/redlock.qnt 已存在）；修「掃描未發現 specs/」註解與 `test-framework` 描述（ava ＋ node:test 神諭層）。
- 驗收：(1) annotation 與 `git ls-files specs/` 實況一致；(2) 註解更新日期與證據 commit 對齊。

**WI-5（agent-write-docs）：把本報告 §1.3 提煉成貢獻者速查**

- 內容：README 或 `CONTRIBUTING.md` 增「本地怎麼跑測試」一節：零依賴子集（WI-1 後含 lint）、docker compose 全矩陣、oracle 三檔、quint 手動指令。
- 驗收：(1) 文中每條命令由审稿人原樣複製跑過或引用本報告實測表；(2) 只改文件。

**WI-6（擇一，人類裁決）：`docker-compose.yml:89` 建群參數瑕疵**

- `redis-single-cluster` 的 `--cluster create` 重複 `10.0.0.14`、漏 `10.0.0.15`。修復屬設定變更（非 docs），建議先以一個可跑 `oracle:redis`／compose 的驗證工作項確認其對 cluster 測試的實際影響（重複位址下建群是否直接失敗），再由人類決定是否連同 WI-3 一起修。

### Issue #10 驗收條件（DoD）對應

| DoD 條目                                     | 狀態       | 涵蓋說明                                                                                                                                                                   |
| -------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 有可驗證的測試/驗證方式                      | **passed** | §1.3 附精確命令與實測結果（build 綠、fixes 9/9、oracle:mock 11/11、lint exit 1 如實回報）；§1.3 末段給後續修復的紅 → 綠判準                                                |
| 不觸碰高風險路徑（H1–H3，見 risk-paths.yml） | **passed** | 本交付僅新增 `docs/research/10-test-structure-ci-inventory.md`；H1–H3 為空清單、H5 路徑（`.github/**`、`catalog-info.yaml`）零觸碰；§4 已將 H5 修復全部標記為人類工作項    |
| 跑測試確認綠燈（不跑需外部服務的 E2E）       | **passed** | 零外部依賴測試全綠：`ava fixes.test.js` 9/9、`counterexamples` 11/11、`build` rc 0；需 Redis 的 single/multi/oracle:redis 依條目括號排除未跑，依賴位置已定位至行號（§1.1） |

---

## 附錄 A：盤點命令清單（本 run 實際使用）

```bash
# 結構
git ls-files | sed -n '1,200p'
grep -n "test(" src/single.test.ts src/multi.test.ts src/fixes.test.ts
grep -n '"test"\|"lint"\|"oracle' package.json
# 零依賴驗證
npm install --ignore-scripts && npm run build
cd dist/esm && CI=true ../../node_modules/.bin/ava --verbose fixes.test.js
node --test specs/oracle/counterexamples.test.mjs
npm run lint          # 現況 exit 1，4 檔見 §1.3
# 分支拓撲（shallow clone 下）
git ls-tree --name-only origin/main
git rev-list --left-right --count origin/main...software-factory   # 123 / 1（深度受限，僅方向性參考）
```
