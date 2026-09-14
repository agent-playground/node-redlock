# specs/traces/as-is/ — 修復前（as-is）模型的反例軌跡

本目錄的 7 條 ITF 軌跡由**修復前**的 `specs/redlock.qnt` 產生
（`git show 691c0e3:specs/redlock.qnt`），對應修復前的 `src/index.ts`
（base `38f792e`，也就是上游 `mike-marcacci/node-redlock` 至今的行為）。

**它們是歷史證據，不是現況。** 其中四條所對應的不變式在修復後已經成立，
因此不再有反例可產生：

| 軌跡                                              | 對應發現 | 修復後的狀態                                        |
| ------------------------------------------------- | -------- | --------------------------------------------------- |
| `INV_VIOLATED_acquireReturnsExpiredLock.itf.json` | F1       | 已修復 → `neverHandsOutExpiredLock` 成立            |
| `INV_VIOLATED_extendReturnsExpiredLock.itf.json`  | F5       | 已修復 → `neverHandsOutExpiredLock` 成立            |
| `INV_VIOLATED_returnsExpiredLock.itf.json`        | F1 ∪ F5  | 同上（合併版述詞）                                  |
| `INV_VIOLATED_releaseErrorMasksAbort.itf.json`    | F7       | 已修復 → `abortReasonNeverMasked` 成立              |
| `INV_VIOLATED_quorumCoverageDecay.itf.json`       | F3       | **仍成立** → 新軌跡在上層目錄                       |
| `INV_VIOLATED_concurrentCriticalSections.itf.json`| F4       | **仍成立** → 新軌跡在上層目錄                       |
| `INV_VIOLATED_twoClientsBelieveLock.itf.json`     | F8       | **仍成立** → 新軌跡在上層目錄                       |

上層 `specs/traces/` 只放**目前**的 as-fixed 模型所產生的軌跡。
