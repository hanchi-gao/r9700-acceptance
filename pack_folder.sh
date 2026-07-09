#!/usr/bin/env bash
# pack_folder.sh — 打包燒機套件為獨立資料夾 (r9700-suite/)
# 輸出可直接複製到新 SSD，雙擊 啟動燒機GUI.sh 即可運行
#
# 用法:
#   ./pack_folder.sh              # 產出 r9700-suite/ 資料夾
#   ./pack_folder.sh --tar        # 額外產出 r9700-suite.tar.gz

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="$REPO_ROOT/r9700-suite"
WITH_TAR=0
[[ "${1:-}" == "--tar" ]] && WITH_TAR=1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
say() { printf "${YELLOW}==> %s${NC}\n" "$*"; }
ok()  { printf "  ${GREEN}[ok]${NC} %s\n" "$*"; }

# ── 1. 確認 vk_burn 已 build ─────────────────────────────────────────
say "確認 build artifacts"
if [[ ! -x "$REPO_ROOT/build/vk_burn" ]]; then
  echo "ERROR: build/vk_burn 不存在，請先執行 ./deploy.sh" >&2; exit 1
fi
if [[ ! -f "$REPO_ROOT/build/vk_burn.comp.spv" ]]; then
  echo "ERROR: build/vk_burn.comp.spv 不存在，請先執行 ./deploy.sh" >&2; exit 1
fi
ok "vk_burn + shader ready"

# ── 2. 清空並重建輸出資料夾 ──────────────────────────────────────────
say "建立 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/build"

# ── 3. 複製專案檔案 ──────────────────────────────────────────────────
say "複製專案檔案"
rsync -a --exclude='.git' \
         --exclude='__pycache__' \
         --exclude='*.pyc' \
         --exclude='r9700-suite' \
         --exclude='r9700-suite.tar.gz' \
         --exclude='r9700-acceptance.run' \
         --exclude='安裝R9700燒機套件.sh' \
         --exclude='pack_folder.sh' \
         --exclude='results/' \
         --exclude='results_path.conf' \
         --exclude='third_party/' \
         --exclude='models/' \
         --exclude='build/gemm_burn' \
         --exclude='build/gpu_burn' \
         --exclude='build/llama-cli' \
         "$REPO_ROOT/" "$OUT/"
ok "rsync 完成"

# ── 4. 複製 build artifacts ──────────────────────────────────────────
cp "$REPO_ROOT/build/vk_burn"         "$OUT/build/vk_burn"
cp "$REPO_ROOT/build/vk_burn.comp.spv" "$OUT/build/vk_burn.comp.spv"
chmod +x "$OUT/build/vk_burn"
ok "vk_burn binary 已包入"

# ── 5. 建立 GUI 啟動腳本 ─────────────────────────────────────────────
say "建立啟動腳本"
LAUNCHER="$OUT/啟動燒機GUI.sh"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# 啟動燒機GUI.sh — 雙擊或在 terminal 執行，啟動 R9700 燒機監控 GUI
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if [[ $EUID -eq 0 ]]; then
  exec python3 "$DIR/gui/main.py"
elif [[ -t 0 ]]; then
  exec sudo -E python3 "$DIR/gui/main.py"
else
  CMD="sudo -E python3 '$DIR/gui/main.py'; echo; read -rp 'Press Enter to close...' _"
  if command -v gnome-terminal &>/dev/null; then
    exec gnome-terminal -- bash -c "$CMD"
  elif command -v xterm &>/dev/null; then
    exec xterm -e bash -c "$CMD"
  else
    exec sudo -E python3 "$DIR/gui/main.py"
  fi
fi
LAUNCHER_EOF
chmod +x "$LAUNCHER"
ok "啟動燒機GUI.sh 建立完成"

# ── 6. 確保所有 .sh 有執行權限 ───────────────────────────────────────
chmod +x "$OUT"/*.sh "$OUT"/stress/*.sh 2>/dev/null || true

# ── 7. 產出 tar.gz (可選) ────────────────────────────────────────────
if (( WITH_TAR )); then
  say "壓縮 r9700-suite.tar.gz"
  tar -czf "$REPO_ROOT/r9700-suite.tar.gz" -C "$REPO_ROOT" "r9700-suite"
  ok "r9700-suite.tar.gz ($(du -sh "$REPO_ROOT/r9700-suite.tar.gz" | cut -f1))"
fi

# ── 完成 ─────────────────────────────────────────────────────────────
say "完成"
echo ""
echo "  輸出資料夾: $OUT"
echo "  大小: $(du -sh "$OUT" | cut -f1)"
echo ""
echo "  複製到新 SSD 後："
echo "    1. 執行 ./deploy.sh         # 安裝 apt 套件 (首次)"
echo "    2. 雙擊 啟動燒機GUI.sh      # 開啟 GUI"
echo "    或直接: sudo -E python3 gui/main.py"
echo ""
