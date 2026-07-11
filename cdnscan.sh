#!/usr/bin/env bash
#
# cdnscan.sh — Panel dòng lệnh cho Ubuntu để quét/resolve domain CDN của một dịch vụ
# (VD: YouTube, Facebook...) ra danh sách IP/CIDR, lưu lịch sử thay đổi, và xuất
# cấu hình dùng cho ipset / iptables / mwan3 (OpenWrt) để định tuyến hoặc cân bằng tải.
#
# Yêu cầu: dig (dnsutils), ipset (tùy chọn, để tạo set thật trên máy), jq (tùy chọn)
#   sudo apt install -y dnsutils ipset jq
#
# Cấu trúc thư mục làm việc (mặc định: ~/cdnscan)
#   services/<ten-dich-vu>.conf   -> danh sách domain, mỗi dòng 1 domain
#   data/<ten-dich-vu>/latest.txt -> danh sách IP mới nhất (1 IP/dòng)
#   data/<ten-dich-vu>/history/<timestamp>.txt -> snapshot theo thời gian
#   export/<ten-dich-vu>.ipset    -> file restore cho ipset
#   export/<ten-dich-vu>.mwan3    -> đoạn cấu hình mẫu cho mwan3 (OpenWrt)
#
set -euo pipefail

BASE_DIR="${CDNSCAN_HOME:-$HOME/cdnscan}"
SERVICES_DIR="$BASE_DIR/services"
DATA_DIR="$BASE_DIR/data"
EXPORT_DIR="$BASE_DIR/export"
RESOLVERS=("8.8.8.8" "1.1.1.1" "9.9.9.9")   # nhiều resolver để bắt thêm IP CDN khác nhau

# ---------- Tiện ích in màu ----------
c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
c_red() { printf '\033[31m%s\033[0m\n' "$1"; }
c_blue() { printf '\033[34m%s\033[0m\n' "$1"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { c_red "Thiếu lệnh '$1'. Cài bằng: sudo apt install -y $2"; exit 1; }
}

init_dirs() {
  mkdir -p "$SERVICES_DIR" "$DATA_DIR" "$EXPORT_DIR"
}

# ---------- Quản lý danh sách domain theo dịch vụ ----------
# Vài dịch vụ phổ biến được gợi ý sẵn, bạn có thể chỉnh sửa/thêm trong services/*.conf
seed_defaults() {
  local f="$SERVICES_DIR/youtube.conf"
  if [[ ! -f "$f" ]]; then
    cat > "$f" <<'EOF'
youtube.com
www.youtube.com
m.youtube.com
googlevideo.com
ytimg.com
i.ytimg.com
yt3.ggpht.com
youtubei.googleapis.com
EOF
    c_green "Đã tạo mẫu: $f (bạn có thể chỉnh sửa thêm domain)"
  fi
}

# ---------- Resolve domain -> IP ----------
# Dùng nhiều resolver để lấy nhiều dải IP CDN khác nhau (mỗi resolver có thể trả
# về node CDN gần khác nhau tùy anycast/GeoDNS)
resolve_service() {
  local svc="$1"
  local conf="$SERVICES_DIR/$svc.conf"
  [[ -f "$conf" ]] || { c_red "Không tìm thấy $conf"; exit 1; }

  local tmp
  tmp=$(mktemp)

  while IFS= read -r domain; do
    [[ -z "$domain" || "$domain" == \#* ]] && continue
    for r in "${RESOLVERS[@]}"; do
      dig +short A "$domain" @"$r" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$tmp" || true
    done
  done < "$conf"

  mkdir -p "$DATA_DIR/$svc/history"
  sort -u "$tmp" -o "$tmp"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  cp "$tmp" "$DATA_DIR/$svc/history/$ts.txt"
  cp "$tmp" "$DATA_DIR/$svc/latest.txt"
  rm -f "$tmp"

  local count
  count=$(wc -l < "$DATA_DIR/$svc/latest.txt")
  c_green "[$svc] Resolve xong: $count IP (snapshot: $ts)"
}

resolve_all() {
  init_dirs
  shopt -s nullglob
  local any=0
  for conf in "$SERVICES_DIR"/*.conf; do
    any=1
    local svc
    svc=$(basename "$conf" .conf)
    resolve_service "$svc"
  done
  [[ $any -eq 0 ]] && c_yellow "Chưa có file cấu hình nào trong $SERVICES_DIR. Chạy: $0 add-service <ten> <domain1> [domain2 ...]"
}

# ---------- Thêm dịch vụ mới ----------
add_service() {
  local svc="$1"; shift
  [[ $# -ge 1 ]] || { c_red "Cần ít nhất 1 domain"; exit 1; }
  init_dirs
  local f="$SERVICES_DIR/$svc.conf"
  printf '%s\n' "$@" >> "$f"
  sort -u "$f" -o "$f"
  c_green "Đã cập nhật $f:"
  cat "$f"
}

# ---------- So sánh 2 snapshot gần nhất (phát hiện IP mới/mất) ----------
diff_service() {
  local svc="$1"
  local hist="$DATA_DIR/$svc/history"
  [[ -d "$hist" ]] || { c_red "Chưa có dữ liệu cho $svc"; exit 1; }
  local files
  files=($(ls -1 "$hist" | sort))
  local n=${#files[@]}
  if (( n < 2 )); then
    c_yellow "Chưa đủ 2 snapshot để so sánh (hiện có $n)"
    return
  fi
  local prev="$hist/${files[$((n-2))]}"
  local curr="$hist/${files[$((n-1))]}"
  c_blue "So sánh: $(basename "$prev") -> $(basename "$curr")"
  echo "IP mới thêm:"
  comm -13 "$prev" "$curr" | sed 's/^/  + /' || true
  echo "IP đã mất:"
  comm -23 "$prev" "$curr" | sed 's/^/  - /' || true
}

# ---------- Xuất cấu hình ----------
export_ipset() {
  local svc="$1"
  local latest="$DATA_DIR/$svc/latest.txt"
  [[ -f "$latest" ]] || { c_red "Chưa resolve $svc, chạy: $0 resolve $svc"; exit 1; }
  init_dirs
  local out="$EXPORT_DIR/$svc.ipset"
  {
    echo "create ${svc}_ips hash:ip family inet hashsize 1024 maxelem 65536 -exist"
    while IFS= read -r ip; do
      echo "add ${svc}_ips $ip -exist"
    done < "$latest"
  } > "$out"
  c_green "Đã xuất: $out"
  c_yellow "Áp dụng trên Ubuntu: sudo ipset restore < $out"
  c_yellow "Ví dụ dùng với iptables: sudo iptables -t mangle -A PREROUTING -m set --match-set ${svc}_ips dst -j MARK --set-mark 1"
}

export_mwan3() {
  local svc="$1"
  local latest="$DATA_DIR/$svc/latest.txt"
  [[ -f "$latest" ]] || { c_red "Chưa resolve $svc, chạy: $0 resolve $svc"; exit 1; }
  init_dirs
  local out="$EXPORT_DIR/$svc.mwan3"
  {
    echo "# Đoạn cấu hình mẫu cho /etc/config/mwan3 (OpenWrt), chỉnh interface theo hệ thống của bạn"
    local i=0
    while IFS= read -r ip; do
      i=$((i+1))
      echo "config rule '${svc}_rule_${i}'"
      echo "    option dest_ip '$ip'"
      echo "    option use_policy 'wan2_only'   # đổi thành policy bạn muốn"
      echo
    done < "$latest"
  } > "$out"
  c_green "Đã xuất: $out"
}

export_ipfw_list() {
  local svc="$1"
  local latest="$DATA_DIR/$svc/latest.txt"
  [[ -f "$latest" ]] || { c_red "Chưa resolve $svc, chạy: $0 resolve $svc"; exit 1; }
  cat "$latest"
}

# ---------- Watch: chạy định kỳ (nên đặt qua cron thay vì chạy foreground dài hạn) ----------
watch_service() {
  local svc="$1"
  local interval="${2:-3600}"   # giây, mặc định 1h
  c_blue "Theo dõi $svc mỗi ${interval}s. Nhấn Ctrl+C để dừng."
  while true; do
    resolve_service "$svc"
    diff_service "$svc" || true
    sleep "$interval"
  done
}

usage() {
  cat <<EOF
$(c_blue "cdnscan.sh — Panel CLI quét domain CDN trên Ubuntu")

Cách dùng:
  $0 init                              Khởi tạo thư mục + service mẫu (youtube)
  $0 add-service <ten> <d1> [d2 ...]    Thêm/cập nhật danh sách domain cho 1 dịch vụ
  $0 resolve <ten>                      Resolve domain -> IP cho 1 dịch vụ
  $0 resolve-all                        Resolve tất cả dịch vụ đã cấu hình
  $0 diff <ten>                         So sánh snapshot mới nhất với snapshot trước
  $0 list <ten>                         In danh sách IP mới nhất
  $0 export-ipset <ten>                 Xuất file restore cho ipset
  $0 export-mwan3 <ten>                 Xuất cấu hình mẫu cho mwan3 (OpenWrt)
  $0 watch <ten> [giay]                 Theo dõi liên tục, mặc định 3600s (dùng test; nên chạy qua cron)

Ví dụ:
  $0 init
  $0 resolve youtube
  $0 export-ipset youtube
  sudo ipset restore < ~/cdnscan/export/youtube.ipset

Chạy định kỳ qua cron (mỗi giờ):
  crontab -e
  0 * * * * $BASE_DIR/cdnscan.sh resolve youtube >> $BASE_DIR/cron.log 2>&1
EOF
}

main() {
  need_cmd dig dnsutils
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init) init_dirs; seed_defaults ;;
    add-service) add_service "$@" ;;
    resolve) resolve_service "$1" ;;
    resolve-all) resolve_all ;;
    diff) diff_service "$1" ;;
    list) export_ipfw_list "$1" ;;
    export-ipset) export_ipset "$1" ;;
    export-mwan3) export_mwan3 "$1" ;;
    watch) watch_service "$1" "${2:-3600}" ;;
    ""|help|-h|--help) usage ;;
    *) c_red "Lệnh không hợp lệ: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
