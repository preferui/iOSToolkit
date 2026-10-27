#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Chạy công cụ ký "zsign" (biên dịch sẵn trong app) với tham số dòng lệnh kiểu CLI.
// `log` được gọi từng dòng log zsign in ra. Trả về 0 nếu ký thành công.
int ZSignRun(NSArray<NSString *> *args, void (^ _Nullable log)(NSString *line));

NS_ASSUME_NONNULL_END
