#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Chạy công cụ ký "zsign" (biên dịch sẵn trong app) với tham số dòng lệnh kiểu CLI.
// `log` được gọi từng dòng log zsign in ra. Trả về 0 nếu ký thành công.
// extern "C": file triển khai (ZSignBridge.mm) là Objective-C++ nên nếu không ép
// linkage kiểu C, tên hàm sẽ bị đổi (mangle) kiểu C++ và Swift sẽ không thấy symbol.
int ZSignRun(NSArray<NSString *> *args, void (^ _Nullable log)(NSString *line));

// Chẩn đoán: mở trực tiếp file zip bằng chính thư viện minizip mà zsign dùng (bỏ qua hết
// logic của zsign), trả về mô tả kết quả. Dùng để biết chính xác bước nào trong "giải nén"
// bị lỗi khi zsign báo "Unzip failed".
NSString *ZSignProbeZip(NSString *path);

// Chẩn đoán sâu hơn: thử giải nén TOÀN BỘ file zip ra một thư mục tạm thật (y hệt cách
// archive.cpp của zsign làm — tạo thư mục, mở từng mục, đọc rồi ghi ra), dừng lại và báo rõ
// mục nào/bước nào lỗi đầu tiên (kèm errno) thay vì chỉ nói chung chung "Unzip failed".
NSString *ZSignProbeExtract(NSString *path, NSString *outDir);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
