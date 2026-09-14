// ==============================================================================
// Redlock F9（時鐘突跳）UPPAAL TCTL 查詢
//
// 設計要點：**陰性對照是查詢條件，不是檔案版本**。
// 模型裡的 node_jumps / client_jumps 兩個計數器，讓「沒有時鐘異常」與
// 「只有客戶端時鐘異常」都能直接寫進公式，因此同一份 .xml 就能同時給出
// 正例與對照，不需要編輯 const 再跑第二次——那種做法無法保證兩次跑的是
// 同一個模型。
//
// 執行：
//   verifyta specs/uppaal/redlock_f9.xml specs/uppaal/redlock_f9.q
//   （退出碼非 0 即代表有查詢不符預期，可直接當 CI 閘門）
// ==============================================================================

/*
 * 查詢 1【陰性對照】——沒有任何時鐘異常時，Redlock 的互斥性成立。
 *
 * 這條是整份模型的地基：若它被滿足，代表違反來自建模錯誤而非時鐘突跳，
 * 後面所有結論都不成立。
 *
 * 預期：NOT satisfied
 */
E<> (Client0.InCritical && Client1.InCritical && node_jumps == 0 && client_jumps == 0)

/*
 * 查詢 2【F9 本體】——只靠**客戶端**時鐘往後跳，且**完全沒有動過任何節點**
 * （node_jumps == 0），就足以讓兩個客戶端同時進入臨界區。
 *
 * 機制：客戶端量到的經過時間 = c_client - client_skew。時鐘往後跳讓它低估
 * 已流逝的時間，於是賴在臨界區超過鎖的真實有效期；同時節點上的 key 依
 * **真實時間**自然到期，第二個客戶端完全合法地取得 quorum。
 *
 * 這條與查詢 3 一起，證明 F9 **不是 F8 的換皮**：它不需要任何節點異常。
 *
 * 預期：SATISFIED
 */
E<> (Client0.InCritical && Client1.InCritical && node_jumps == 0)

/*
 * 查詢 3【對照組：F8 等價變體】——只靠**節點**時鐘往前跳（key 提前過期），
 * 不動任何客戶端時鐘，同樣能破壞互斥。
 *
 * ⚠️ 這條在效果上等同於「節點崩潰遺失 key」，Quint 模型已用 crashAndLoseKey
 * 證過同一個違反（INV_VIOLATED_twoClientsBelieveLock）。列在這裡是為了與
 * 查詢 2 對比，而**不是** F9 的證據。
 *
 * 預期：SATISFIED
 */
E<> (Client0.InCritical && Client1.InCritical && client_jumps == 0)

/*
 * 查詢 4【整體互斥性】——在允許時鐘突跳的環境下，互斥性不成立。
 * 預期：NOT satisfied（UPPAAL 會產出診斷反例軌跡）
 */
A[] not (Client0.InCritical && Client1.InCritical)

/*
 * 查詢 5【模型健全性】——不得有非預期的死鎖。
 *
 * 這條會抓到「節點在某些狀態下既不能 grant 也不能 reject，
 * 讓客戶端卡死在 ReqNode」這類建模錯誤。
 *
 * 預期：SATISFIED
 */
A[] not deadlock

/*
 * 查詢 6、7【活性 sanity check】——兩個客戶端都確實取得過鎖。
 *
 * 若這兩條不成立，代表模型根本走不到臨界區，前面所有的
 * 「NOT satisfied」都會是空跑得來的假安全。
 *
 * 預期：皆為 SATISFIED
 */
E<> Client0.InCritical
E<> Client1.InCritical
