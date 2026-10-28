#import "ZSignBridge.h"
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <string>
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

// mkdir -p đơn giản, giống hệt vòng lặp mkdir() từng cấp mà ZFile::CreateFolder của zsign làm.
static bool rs_mkdirp(const std::string &path, int *outErrno) {
    size_t pos = 0;
    while ((pos = path.find('/', pos)) != std::string::npos) {
        std::string sub = path.substr(0, pos++);
        if (!sub.empty()) {
            if (0 != mkdir(sub.c_str(), 0755) && errno != EEXIST) { if (outErrno) *outErrno = errno; return false; }
        }
    }
    if (0 != mkdir(path.c_str(), 0755) && errno != EEXIST) { if (outErrno) *outErrno = errno; return false; }
    return true;
}

NSString *ZSignProbeExtract(NSString *path, NSString *outDir) {
    const char *cpath = path.fileSystemRepresentation;
    unzFile uf = unzOpen64(cpath);
    if (!uf) return @"unzOpen64 trả về NULL ngay từ đầu — không mở lại được file (lạ, vì bước chẩn đoán trước đã mở OK).";

    unz_global_info64 gi;
    memset(&gi, 0, sizeof(gi));
    if (UNZ_OK != unzGetGlobalInfo64(uf, &gi)) { unzClose(uf); return @"unzGetGlobalInfo64 lỗi."; }

    [[NSFileManager defaultManager] removeItemAtPath:outDir error:nil];
    std::string root = outDir.fileSystemRepresentation;
    int mkErrno = 0;
    if (!rs_mkdirp(root, &mkErrno)) {
        unzClose(uf);
        return [NSString stringWithFormat:@"Không tạo được thư mục gốc %@ — mkdir lỗi errno=%d (%s)", outDir, mkErrno, strerror(mkErrno)];
    }

    uint64_t nFiles = 0, nFolders = 0;
    int rc = unzGoToFirstFile(uf);
    for (uint64_t i = 0; i < gi.number_entry; i++) {
        if (rc != UNZ_OK) { unzClose(uf); return [NSString stringWithFormat:@"unzGoToFirstFile/NextFile lỗi mã %d tại mục thứ %llu", rc, i]; }

        char szName[1024] = { 0 };
        unz_file_info64 fi; memset(&fi, 0, sizeof(fi));
        if (UNZ_OK != unzGetCurrentFileInfo64(uf, &fi, szName, sizeof(szName), NULL, 0, NULL, 0)) {
            unzClose(uf);
            return [NSString stringWithFormat:@"unzGetCurrentFileInfo64 lỗi tại mục thứ %llu", i];
        }
        std::string name = szName;
        bool isFolder = !name.empty() && name.back() == '/';
        if (isFolder) name.pop_back();
        if (name.empty()) { rc = unzGoToNextFile(uf); continue; }

        std::string full = root + "/" + name;
        if (isFolder) {
            nFolders++;
            int e = 0;
            if (!rs_mkdirp(full, &e)) {
                unzClose(uf);
                return [NSString stringWithFormat:@"Tạo thư mục LỖI tại mục #%llu \"%s\" -> %s | mkdir errno=%d (%s)",
                        i, name.c_str(), full.c_str(), e, strerror(e)];
            }
        } else {
            // đảm bảo thư mục cha tồn tại trước (như _ReadFileFromZip làm: PathRemoveFileSpec rồi CreateFolder)
            size_t slash = full.find_last_of('/');
            if (slash != std::string::npos) {
                int e = 0;
                std::string parent = full.substr(0, slash);
                if (!rs_mkdirp(parent, &e) ) {
                    unzClose(uf);
                    return [NSString stringWithFormat:@"Tạo thư mục CHA lỗi cho mục #%llu \"%s\" -> %s | errno=%d (%s)",
                            i, name.c_str(), parent.c_str(), e, strerror(e)];
                }
            }
            if (UNZ_OK != unzOpenCurrentFile(uf)) {
                unzClose(uf);
                return [NSString stringWithFormat:@"unzOpenCurrentFile LỖI tại mục #%llu \"%s\"", i, name.c_str()];
            }
            FILE *fp = fopen(full.c_str(), "wb");
            if (!fp) {
                int e = errno;
                unzCloseCurrentFile(uf);
                unzClose(uf);
                return [NSString stringWithFormat:@"fopen (ghi) LỖI tại mục #%llu \"%s\" -> %s | errno=%d (%s)",
                        i, name.c_str(), full.c_str(), e, strerror(e)];
            }
            char buf[65536];
            int readBytes;
            bool writeFail = false;
            while ((readBytes = unzReadCurrentFile(uf, buf, sizeof(buf))) > 0) {
                if (fwrite(buf, 1, (size_t)readBytes, fp) != (size_t)readBytes) { writeFail = true; break; }
            }
            fclose(fp);
            bool readFail = readBytes < 0;
            unzCloseCurrentFile(uf);
            if (writeFail || readFail) {
                unzClose(uf);
                return [NSString stringWithFormat:@"%@ LỖI tại mục #%llu \"%s\" (unzReadCurrentFile=%d)",
                        writeFail ? @"Ghi file" : @"Đọc file nén", i, name.c_str(), readBytes];
            }
            nFiles++;
        }

        if (i < gi.number_entry - 1) {
            rc = unzGoToNextFile(uf);
        } else {
            rc = UNZ_OK;
        }
    }
    unzClose(uf);
    [[NSFileManager defaultManager] removeItemAtPath:outDir error:nil];
    return [NSString stringWithFormat:@"Giải nén thủ công THÀNH CÔNG: %llu thư mục, %llu tệp.", nFolders, nFiles];
}
