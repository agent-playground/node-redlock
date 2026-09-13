# node-redlock 納管提案 — 給審核者的一頁說明

> 本目錄**不是任何機制的讀取路徑**：`factory-score` 讀 repo 根的 `catalog-info.yaml`、
> `factory-run` 讀 `.github/factory/risk-paths.yml`，都不看 `proposals/`。
> 因此誤合併也不會改變任何評級——三軸要由人類親手搬檔才生效（docs/05 §1.1、docs/27 §2）。

工作項：Issue #1 `[factory-onboard] agent-playground/node-redlock`（任務類型 `agent-onboard`）。
本 PR 為**單層 PR**，base = `software-factory`，只新增 `proposals/onboarding/` 下三個檔案，
未修改任何既有檔案、未寫入 `catalog-info.yaml` 或 `.github/`。

---

## 1. 掃描摘要

| 項目                      | 結果（證據）                                                                                                                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 語言／建置                | TypeScript ~4.6.2；`package.json` scripts：`build` = `tsc` + `tsc -p tsconfig.cjs.json`（ESM + CJS 雙輸出）；建置/測試以 yarn 驅動                                                                |
| 測試框架                  | **ava ^4.1.0**；`src/single.test.ts`（550 行）、`src/multi.test.ts`（329 行），`scripts.test` 在 `dist/esm` 執行                                                                                  |
| 執行期相依                | `ioredis ^4.28.5`（Redis client）、`node-abort-controller`                                                                                                                                        |
| 目錄結構                  | `src/` 僅 3 檔：`index.ts`（770 行，唯一實作）、`single.test.ts`、`multi.test.ts`。無 `src/shared/`、`src/core/`、`libs/`、`api/`                                                                 |
| migrations/schema         | **無** `migrations/`、無 `*.sql`、無 ORM/schema 檔——本 repo 無資料庫                                                                                                                              |
| API 定義                  | **無** `openapi.yaml`、無 `*.proto`；對外 API 全在 `src/index.ts` 的 exports 與 `package.json` 的 `exports`/`main`/`module`/`types`                                                               |
| 認證授權／金流／加密／PII | **無** authn/authz、無 payment/billing、無 PII/憑證檔。`src/index.ts` import `crypto` 只為 `randomBytes`（產生隨機 lock 值）與 `createHash("sha1")`（算 Lua script hash），**不是**加密或密鑰處理 |
| 服務數量／跨服務協調      | repo 本身**不部署任何服務**。`docker-compose.yml` 有 23 個 `redis` 容器（single/multi instance、single/multi cluster 四種拓撲）+ installer/builder/runner，全部是**測試 fixture**，非產品服務     |
| CI                        | `.github/workflows/ci.yml` 以 docker compose 跑 lint/build/test；另有 `codeql-analysis.yml`、`dependabot.yml`                                                                                     |

**關鍵發現**：這是一個單檔、無資料庫、無網路服務的函式庫；其本質風險是**演算法正確性**
（quorum 判定、`extend()`、時序），而這些風險的失效模式是**靜默的**——不會拋錯，只會讓
兩個呼叫端同時持有同一把鎖。硬規則（H1–H7）以**檔案路徑**判定，捕捉不到這種語意風險，
因此三軸的 `risk-profile` 與是否需要「核心檔硬規則」是本提案要請人類裁定的重點。

---

## 2. 三軸建議值與理由（裁定權在人類）

三軸一律先填 `TODO`；下表為建議。合法值見 docs/27 §7.2——**值缺席或非法一律 fail-safe 計 2**。

| 軸                     | 建議             | 為什麼不是更高                                                                                                                                                                                                                                                         | 為什麼不是更低                                                                                                               |
| ---------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `business-criticality` | **tactical (0)** | 此 fork 是 agent-playground 內部實驗；無部署、無客戶端、無營收。若人類認定本 fork 就是下游使用的 npm `redlock`（`package.json`：`name: redlock`、`repository: mike-marcacci/node-redlock`、`v5.0.0-beta.2`），故障即信譽損失，應改判 **strategic (2)**（待裁定事項 1） | 不是 operational (1)：它不是支撐同仁作業的內部業務系統，故障不擋任何工廠流程                                                 |
| `risk-profile`         | **medium (1)**   | 無 H1–H4/H6/H7 對應路徑（見 `risk-paths.yml` 逐條）；high 需硬性規則觸發。若人類把核心檔 `src/index.ts` 納入 H4/H7，變更即強制 high（待裁定事項 2）                                                                                                                    | 不是 low (0)：low 指純文件/格式化/測試新增；本 repo 核心是並行/時序邏輯，變更會改行為                                        |
| `complexity`           | **low (0)**      | 無跨服務/跨系統、無新架構模式、無共用抽象變更。單一實作模組                                                                                                                                                                                                            | 無更低值；medium 需要「跨數個模組」，而本 repo 只有一個實作檔（對照 docs/16 §5.1：factory-scoreboard 15 檔、6 端點仍評 low） |

**建議值下的預期 baseline**：`tactical + medium + low = 0 + 1 + 0 = 1` → tier `on-loop`。
但 `factory.io/agent-automerge: "false"` 會擋下自動合併（docs/06 §4.1），實務上每個 PR 仍須人類核准。

---

## 3. 待裁定事項（提請人類決定）

1. **business-criticality**：本 fork 是否即對外 npm `redlock`？是 → 改判 `strategic`。
2. **核心檔是否納入硬規則**：`src/index.ts` 是唯一實作檔、也是對外 API 的全部。納入 H4/H7
   可讓每次核心變更強制 `risk=2`（人類審查），但代價是幾乎每次程式變更都升級。本提案
   **未**納入，留待裁定；若要納入，建議併同評估是否也保護 `package.json` 的 `exports`。
3. **三軸合法值提醒**：本工作項的任務描述把 business-criticality 的合法值寫成
   `strategic | tactical | supporting`，但機制原始碼（`src/scoring/types.ts`）與 docs/27 §7.2
   的合法值是 `tactical | operational | strategic`——**`supporting` 非法，會 fail-safe 計 2**。
   本提案的註解已採合法值集合；搬檔時請勿填入 `supporting`。

---

## 4. 搬檔指令（**人類審核後**親自執行）

先完成第 2 節的三軸裁定，把 `catalog-info.yaml` 內 3 個 `TODO` 換成實際值，然後：

```bash
git mv proposals/onboarding/catalog-info.yaml .
mkdir -p .github/factory
git mv proposals/onboarding/risk-paths.yml .github/factory/risk-paths.yml
git rm -r proposals/onboarding
```

> `git rm -r proposals/onboarding` 會一併移除本 README（它只是審查用，不需進正位）。

**搬檔後請複查每條 glob 是否誤中無關檔**（docs/27 §7.1）：

```bash
gh api "repos/agent-playground/node-redlock/contents/src?ref=software-factory" --jq '.[].name'
```

本提案的 `risk-paths.yml` 中，H1–H4、H6、H7 皆為**空陣列**（掃描未發現對應結構，逐條已註明
「待人類確認」）；唯一有效的硬規則是 **H5**（四條 guardrail 自身路徑）。這是刻意的：
依 docs/16 §5.3，寧可精準而少，也不要用會誤報的樣式削弱防護。

---

## 5. 合併後的驗證（docs/16 §5.2 雙向探測，**兩個方向都要驗**）

設定檔在 `proposals/` 時工廠讀不到它；「寫對了」與「工廠讀得到」在合併前無法區分。
搬檔合併後，各開一個 `factory/*` 探測 PR，對 `philipz/software_factory` 的
`factory-rescore.yml` 發 dispatch：

```bash
gh workflow run factory-rescore.yml --repo philipz/software_factory \
  -f repo=agent-playground/node-redlock -f base_branch=software-factory -f pr_number=<PR>
```

| 方向          | 探測 PR 改什麼                                                                     | 預期                                                                           |
| ------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| A：一般檔案   | 只改一般檔（例如 `README.md` 或 `src/multi.test.ts` 的測試）                       | 基準分 `total 1`、`triggeredHardRules: []`、`escalated: false`、tier `on-loop` |
| B：硬規則路徑 | 改任一 **H5** 路徑（例如 `catalog-info.yaml` 或 `.github/factory/risk-paths.yml`） | `triggeredHardRules: ["H5"]`、`escalated: true`、risk 強制 2                   |

> **為何方向 B 用 H5**：本 repo 掃描後沒有 migrations/auth/金流等結構，非 H5 硬規則全為空陣列，
> 因此唯一能驗證「硬規則確實被載入」的就是 H5。只驗方向 A 無法區分「硬規則正確」與
> 「硬規則根本沒載入」。

**若三軸最終不是 tactical/medium/low**，方向 A 的預期 `total` 請以裁定值重算
（risk-profile 可能因硬規則被拉到 2）。

驗證通過後，把此 repo 補進 `docs/16` §5 的已納管清單。
