# iOS Toolkit — Cleaner tích hợp từ 3105

Bản này bổ sung Cleaner quét ứng dụng đã cài, tìm kiếm và sắp xếp theo dung lượng. Khi quét và dọn, thanh tiến trình hiển thị phần trăm cùng ứng dụng đang xử lý. Trước khi xóa, ứng dụng hiển thị xác nhận và dung lượng ước tính.

Cleaner chỉ xóa nội dung bên trong `Library/Caches` và `tmp` của ứng dụng được chọn. Nó không quét hoặc xóa tài liệu người dùng, dữ liệu đăng nhập hay thư mục ứng dụng khác. Tệp liên kết tượng trưng và tệp đặc biệt được giữ nguyên.

## Cài đặt và tương thích

- Bundle ID được đặt là `com.apple.mobile.MobileHouseArrest`, theo yêu cầu của cầu nối MCM trong 3105. ID `com.realmios.ioskit` không được cầu nối này chấp nhận.
- Phần truy cập container dùng cơ chế đặc quyền của 3105. Theo hướng dẫn 3105, bản thiết bị cần ký bằng chứng chỉ doanh nghiệp; SideStore, AltStore, 3uTools và LiveContainer không được hỗ trợ.
- Quy trình chỉ chạy trên các phiên bản/build iOS được 3105 xác nhận. Phiên bản không được hỗ trợ sẽ bị chặn trước khi quét.
- Mã nguồn 3105 được cấp phép GPL-3.0. Các tệp `LICENSE` và `THIRD_PARTY_NOTICES.md` đi kèm để giữ thông tin giấy phép và ghi công.

Tham chiếu: https://github.com/YangJiiii/3105/releases

