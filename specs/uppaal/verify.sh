#!/usr/bin/env bash
#
# specs/uppaal/verify.sh —— F9 UPPAAL 模型的驗證閘門
#
# ⚠️ 為什麼不能只看 verifyta 的退出碼：
#     verifyta 在「Formula is NOT satisfied」時**仍然回傳 0**（實測）。
#     只有模型本身有型別/語法錯誤時才回傳非 0。
#     因此「跑得動」與「結論正確」是兩回事，閘門必須**逐條解析輸出**
#     並與預期比對——這與 `quint run --witnesses` 在 0% 時仍 exit 0
#     是同一類陷阱。
#
# 用法：
#     specs/uppaal/verify.sh                  # 自動尋找 verifyta
#     VERIFYTA=/path/to/verifyta specs/uppaal/verify.sh
#
# 退出碼：0 = 全部符合預期；1 = 任一條不符（或模型無法驗證）

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${MODEL:-$HERE/redlock_f9.xml}"
QUERIES="${QUERIES:-$HERE/redlock_f9.q}"

# --- 找出 verifyta ---------------------------------------------------------
if [ -z "${VERIFYTA:-}" ]; then
  VERIFYTA="$(command -v verifyta 2>/dev/null || true)"
fi
if [ -z "$VERIFYTA" ]; then
  for cand in /Applications/UPPAAL-*.app/Contents/Resources/uppaal/bin/verifyta \
              "$HOME"/uppaal*/bin/verifyta /opt/uppaal*/bin/verifyta; do
    [ -x "$cand" ] && VERIFYTA="$cand" && break
  done
fi
if [ -z "$VERIFYTA" ] || [ ! -x "$VERIFYTA" ]; then
  echo "[uppaal] 找不到 verifyta。請安裝 UPPAAL 或設定 VERIFYTA=<路徑>。" >&2
  # CI 下**不得**靜默略過：那會讓這道保證消失，與 node --test 的 skip 同病。
  if [ -n "${CI:-}" ]; then
    echo "[uppaal] CI 環境必須提供 verifyta。" >&2
    exit 1
  fi
  exit 1
fi

# --- 預期結果：順序必須與 redlock_f9.q 中的查詢一致 ------------------------
EXPECTED=(
  "NOT satisfied"   # 1 陰性對照：無任何時鐘異常 → 互斥成立
  "satisfied"       # 2 F9 本體：只有客戶端時鐘突跳（node_jumps == 0）
  "satisfied"       # 3 對照：只有節點時鐘突跳（≡ F8）
  "NOT satisfied"   # 4 整體互斥性被打破
  "satisfied"       # 5 無死鎖
  "satisfied"       # 6 活性：Client0 取得過鎖
  "satisfied"       # 7 活性：Client1 取得過鎖
)
LABELS=(
  "陰性對照（無時鐘異常 → 互斥成立）"
  "F9 本體（純客戶端時鐘突跳，node_jumps == 0）"
  "對照組（純節點時鐘突跳，≡ F8）"
  "整體互斥性"
  "無死鎖"
  "活性：Client0"
  "活性：Client1"
)

echo "[uppaal] $("$VERIFYTA" --version 2>&1 | head -1)"
echo "[uppaal] 模型：$MODEL"

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
"$VERIFYTA" "$MODEL" "$QUERIES" >"$OUT" 2>&1
RC=$?

# 模型層級的錯誤（型別/語法）——verifyta 這時才會回傳非 0
if grep -q "\[error\]" "$OUT"; then
  echo "[uppaal] ✗ 模型無法驗證："
  grep "\[error\]" "$OUT" | head -5
  exit 1
fi
if [ "$RC" -ne 0 ]; then
  echo "[uppaal] ✗ verifyta 退出碼 $RC"; tail -20 "$OUT"; exit 1
fi

# 注意：不用 mapfile —— macOS 內建的是 bash 3.2，沒有這個指令。
ACTUAL=()
while IFS= read -r line; do
  ACTUAL+=("$line")
done < <(grep -oE "Formula is NOT satisfied|Formula is satisfied" "$OUT" \
         | sed 's/^Formula is //')

if [ "${#ACTUAL[@]}" -ne "${#EXPECTED[@]}" ]; then
  echo "[uppaal] ✗ 查詢數不符：預期 ${#EXPECTED[@]} 條，實際解析到 ${#ACTUAL[@]} 條"
  echo "         （查詢檔與本腳本的 EXPECTED 陣列必須同步）"
  exit 1
fi

FAIL=0
for i in "${!EXPECTED[@]}"; do
  n=$((i + 1))
  if [ "${ACTUAL[$i]}" = "${EXPECTED[$i]}" ]; then
    printf "[uppaal] ✓ 查詢 %d  %-46s %s\n" "$n" "${LABELS[$i]}" "${ACTUAL[$i]}"
  else
    printf "[uppaal] ✗ 查詢 %d  %-46s 預期 %-14s 實際 %s\n" \
           "$n" "${LABELS[$i]}" "${EXPECTED[$i]}" "${ACTUAL[$i]}"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "[uppaal] ✗ 有查詢不符預期——模型或性質已經改變，請更新模型或同步預期值。"
  exit 1
fi
echo "[uppaal] ✓ 全部 ${#EXPECTED[@]} 條符合預期。"
