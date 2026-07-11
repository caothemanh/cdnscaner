# cdnscan

Panel dòng lệnh (CLI) cho Ubuntu để quét/resolve các domain CDN của một dịch vụ
(ví dụ: YouTube, Facebook, TikTok...) ra danh sách IP, lưu lịch sử thay đổi theo
thời gian, và xuất cấu hình dùng cho `ipset` / `iptables` hoặc `mwan3` (OpenWrt)
phục vụ định tuyến / cân bằng tải nhiều đường mạng.

## Yêu cầu

```bash
sudo apt install -y dnsutils ipset
```

## Cài đặt

```bash
git clone https://github.com/<ten-cua-ban>/cdnscan.git
cd cdnscan
chmod +x cdnscan.sh
./cdnscan.sh init
```

## Cách dùng

```bash
# Khởi tạo cấu hình mẫu (sẵn danh sách domain cho youtube)
./cdnscan.sh init

# Resolve domain -> IP cho 1 dịch vụ
./cdnscan.sh resolve youtube

# Resolve tất cả dịch vụ đã cấu hình
./cdnscan.sh resolve-all

# So sánh IP mới nhất với lần quét trước (IP mới thêm / đã mất)
./cdnscan.sh diff youtube

# In danh sách IP hiện tại
./cdnscan.sh list youtube

# Xuất file restore cho ipset
./cdnscan.sh export-ipset youtube
sudo ipset restore < data-export/youtube.ipset   # xem đường dẫn thật ở export/

# Xuất cấu hình mẫu cho mwan3 (OpenWrt)
./cdnscan.sh export-mwan3 youtube

# Theo dõi liên tục (dùng để test; khuyến nghị chạy qua cron thay vì foreground)
./cdnscan.sh watch youtube 3600
```

## Thêm dịch vụ mới

```bash
./cdnscan.sh add-service facebook facebook.com fbcdn.net fbstatic-a.akamaihd.net
./cdnscan.sh resolve facebook
```

Danh sách domain của từng dịch vụ được lưu tại `services/<ten>.conf`, mỗi dòng
một domain — bạn có thể chỉnh sửa trực tiếp file này.

## Chạy định kỳ bằng cron

```bash
crontab -e
# Quét youtube mỗi giờ
0 * * * * /duong-dan-toi/cdnscan.sh resolve youtube >> /duong-dan-toi/cron.log 2>&1
```

## Cấu trúc thư mục

```
cdnscan.sh              # script chính
services/<ten>.conf     # danh sách domain theo dịch vụ
data/<ten>/latest.txt   # IP mới nhất
data/<ten>/history/     # snapshot IP theo timestamp
export/<ten>.ipset      # file xuất cho ipset
export/<ten>.mwan3      # cấu hình mẫu cho mwan3
```

Mặc định thư mục làm việc là `~/cdnscan` (đổi bằng biến môi trường `CDNSCAN_HOME`).

## Lưu ý

- Vì các CDN dùng anycast/GeoDNS, danh sách IP resolve được có thể không đầy đủ
  100% và có thể thay đổi theo thời gian/khu vực — nên chạy `resolve` định kỳ
  qua cron thay vì chỉ resolve một lần.
- Script chỉ resolve các domain do bạn khai báo trong `services/*.conf`, không
  tự động dò quét toàn bộ hạ tầng của bên thứ ba.

## License

MIT
