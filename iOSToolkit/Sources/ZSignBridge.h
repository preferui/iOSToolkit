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

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
