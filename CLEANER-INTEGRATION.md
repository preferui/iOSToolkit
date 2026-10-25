# iOS Toolkit — Cleaner tích hợp từ 3105

Bản này bổ sung Cleaner quét ứng dụng đã cài, tìm kiếm và sắp xếp theo dung lượng. Khi quét và dọn, thanh tiến trình hiển thị phần trăm cùng ứng dụng đang xử lý. Trước khi xóa, ứng dụng hiển thị xác nhận và dung lượng ước tính.

Cleaner chỉ xóa nội dung bên trong `Library/Caches` và `tmp` của ứng dụng được chọn. Nó không quét hoặc xóa tài liệu người dùng, dữ liệu đăng nhập hay thư mục ứng dụng khác. Tệp liên kết tượng trưng và tệp đặc biệt được giữ nguyên.

## Cài đặt và tương thích

- Bundle ID được đặt là `com.apple.mobile.MobileHouseArrest`, theo yêu cầu của cầu nối MCM trong 3105. ID `com.realmios.ioskit` không được cầu nối này chấp nhận.
- Phần truy cập container dùng cơ chế đặc quyền của 3105. Theo hướng dẫn 3105, bản thiết bị cần ký bằng chứng chỉ doanh nghiệp; SideStore, AltStore, 3uTools và LiveContainer không được hỗ trợ.
- Trước khi vào giao diện Cleaner, ứng dụng hiển thị màn hình kiểm tra phiên bản iOS và build hiện tại. Nút tiếp tục bị khóa nếu thiết bị không được hỗ trợ; chỉ sau khi người dùng tiếp tục, Cleaner mới chuẩn bị quyền truy cập và quét.
- iOSToolkit hiện chỉ cho phép iOS/iPadOS 17.0–17.7.x, 18.0–18.7.1 và 26.0.x. Các bản 26.1 trở lên và iOS 27 bị chặn vì chưa có offsets được xác nhận trong bản tích hợp này.
- Tài liệu offsets của 3105 mô tả giới hạn tổng quát 17.0–26.0.x và nêu các thiết bị/build đã thử nghiệm. Dải được bật ở đây hẹp hơn; phiên bản trong dải không đồng nghĩa mọi mẫu máy đã được kiểm chứng.
- Mã nguồn 3105 được cấp phép GPL-3.0. Các tệp `LICENSE` và `THIRD_PARTY_NOTICES.md` đi kèm để giữ thông tin giấy phép và ghi công.

Tham chiếu: https://github.com/YangJiiii/3105/releases
