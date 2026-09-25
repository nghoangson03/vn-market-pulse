# Nhịp Sàn Việt

Trang theo dõi VN-Index và HNX-Index hằng ngày, một file HTML tĩnh đọc dữ liệu từ `data.json` cùng thư mục.

Mở trang: https://nghoangson03.github.io/vn-market-pulse/

## Dữ liệu

- Nguồn: VNDirect (`dchart-api.vndirect.com.vn`), lấy giá đóng/mở/cao/thấp/khối lượng theo phiên.
- `data.json` chứa 2 chuỗi: `vnindex` và `hnx`, mỗi chuỗi có `points` (mảng `{d,o,h,l,c,v}` sắp theo ngày tăng dần) và `updatedAt`.
- Được cập nhật tự động mỗi ngày (Thứ Hai–Thứ Sáu, sau khi thị trường đóng cửa ~15:30 giờ VN) bởi một tác vụ chạy trên máy cục bộ — xem `automation/`.

## Cập nhật thủ công

```powershell
automation\run_daily_update.ps1
```
