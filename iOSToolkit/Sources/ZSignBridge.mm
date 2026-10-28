#import "ZSignBridge.h"
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <string.h>
#include "unzip.h"

// zsign.cpp đã được vá sẵn trong CI: đổi "int main(...)" thành "int zsign_main(...)"
// để không đụng main() của chính app, và vô hiệu hoá đoạn fork()/execlp() không dùng được
// trong sandbox của iOS. KHÔNG bọc extern "C" ở đây: zsign.cpp là C++ thuần (không có
// extern "C" trong định nghĩa thật), nên khai báo ở đây cũng phải là C++ thuần (không có
// extern "C") để linker khớp đúng tên đã bị mangle — khác với ZSignRun ở trên.
int zsign_main(int argc, char *argv[]);

int ZSignRun(NSArray<NSString *> *args, void (^log)(NSString *line)) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];

    int pfd[2];
    if (pipe(pfd) != 0) { [lock unlock]; return -1; }
    int saved = dup(1);
    fflush(stdout);
    dup2(pfd[1], 1);
    int rd = pfd[0];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *buf = [NSMutableData data];
        char tmp[2048];
        ssize_t n;
        while ((n = read(rd, tmp, sizeof tmp)) > 0) {
            [buf appendBytes:tmp length:n];
            for (;;) {
                const char *b = (const char *)buf.bytes;
                NSUInteger len = buf.length, i = 0;
                BOOL found = NO;
                for (; i < len; i++) if (b[i] == '\n') { found = YES; break; }
                if (!found) break;
                NSString *line = [[NSString alloc] initWithBytes:b length:i encoding:NSUTF8StringEncoding] ?: @"";
                [buf replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
                if (log && line.length) log(line);
            }
        }
        if (buf.length && log) {
            NSString *l = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
            if (l.length) log(l);
        }
        dispatch_semaphore_signal(done);
    });

    int argc = (int)args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    argv[0] = strdup("zsign");
    for (int i = 0; i < (int)args.count; i++) argv[i + 1] = strdup(args[i].UTF8String);
    optind = 1;
#if defined(__APPLE__)
    optreset = 1;
#endif
    int rc = zsign_main(argc, argv);
    fflush(stdout);
    dup2(saved, 1);
    close(saved);
    close(pfd[1]);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    close(rd);
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);

    [lock unlock];
    return rc;
}

NSString *ZSignProbeZip(NSString *path) {
    const char *cpath = path.fileSystemRepresentation;
    FILE *raw = fopen(cpath, "rb");
    NSString *rawInfo = raw ? [NSString stringWithFormat:@"fopen thường: OK"] : [NSString stringWithFormat:@"fopen thường: LỖI errno=%d (%s)", errno, strerror(errno)];
    if (raw) fclose(raw);

    unzFile uf = unzOpen64(cpath);
    if (!uf) {
        return [NSString stringWithFormat:@"%@ | unzOpen64: trả về NULL (minizip không mở được file)", rawInfo];
    }
    unz_global_info64 gi;
    memset(&gi, 0, sizeof(gi));
    int rc = unzGetGlobalInfo64(uf, &gi);
    if (rc != UNZ_OK) {
        unzClose(uf);
        return [NSString stringWithFormat:@"%@ | unzOpen64: OK | unzGetGlobalInfo64: lỗi mã %d", rawInfo, rc];
    }
    int gf = unzGoToFirstFile(uf);
    NSString *firstName = @"(?)";
    if (gf == UNZ_OK) {
        char szName[1024] = { 0 };
        unz_file_info64 fi;
        memset(&fi, 0, sizeof(fi));
        if (UNZ_OK == unzGetCurrentFileInfo64(uf, &fi, szName, sizeof(szName), NULL, 0, NULL, 0)) {
            firstName = [NSString stringWithUTF8String:szName] ?: @"(?)";
        }
    }
    unzClose(uf);
    return [NSString stringWithFormat:@"%@ | unzOpen64: OK | unzGetGlobalInfo64: OK, %llu mục | unzGoToFirstFile: mã %d, mục đầu=%@",
            rawInfo, gi.number_entry, gf, firstName];
}
