// wirecheck.m — protobuf wire 构造/解析 helpers（仅测试用）
// 被 test_logic.m #import 进同一翻译单元：构造 helper 用于造样本，
// 解析 helper 用于结构化断言（不依赖字符串嗅探）。

#import <Foundation/Foundation.h>
#import <stdint.h>

#pragma mark - 构造 helpers

static void pv(NSMutableData *d, NSUInteger v) {
    while (v >= 128) {
        uint8_t c = (uint8_t)(v & 0x7f) | 0x80;
        [d appendBytes:&c length:1];
        v >>= 7;
    }
    uint8_t c = (uint8_t)v;
    [d appendBytes:&c length:1];
}

static void putTag(NSMutableData *d, uint32_t field, uint32_t wt) {
    pv(d, ((NSUInteger)field << 3) | wt);
}

static void putStr(NSMutableData *d, uint32_t field, NSString *s) {
    putTag(d, field, 2);
    NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding];
    pv(d, b.length);
    [d appendData:b];
}

static void putSub(NSMutableData *d, uint32_t field, NSMutableData *sub) {
    putTag(d, field, 2);
    pv(d, sub.length);
    [d appendData:sub];
}

#pragma mark - 解析 helpers

// 提取 message 中第一个匹配 field 的 LEN 字段字节
static NSData *WCExtractField(NSData *msg, uint32_t wantField) {
    const uint8_t *b = msg.bytes;
    NSUInteger len = msg.length, i = 0;
    while (i < len) {
        uint64_t tag = 0;
        NSUInteger shift = 0, tl = 0;
        while (i + tl < len && shift < 63) {
            uint8_t c = b[i + tl++];
            tag |= (uint64_t)(c & 0x7f) << shift;
            if (!(c & 0x80)) break;
            shift += 7;
        }
        i += tl;
        uint32_t field = (uint32_t)(tag >> 3), wt = (uint32_t)(tag & 7);
        if (wt == 2) {
            uint64_t flen = 0;
            NSUInteger fl = 0; shift = 0;
            while (i + fl < len && shift < 63) {
                uint8_t c = b[i + fl++];
                flen |= (uint64_t)(c & 0x7f) << shift;
                if (!(c & 0x80)) break;
                shift += 7;
            }
            i += fl;
            if (field == wantField) {
                return [msg subdataWithRange:NSMakeRange(i, (NSUInteger)MIN((uint64_t)(len - i), flen))];
            }
            i += (NSUInteger)flen;
        } else if (wt == 0) {
            while (i < len && (b[i] & 0x80)) i++;
            i++;
        } else if (wt == 1) i += 8;
        else if (wt == 5) i += 4;
        else return nil;
    }
    return nil;
}

static NSString *WCExtractString(NSData *msg, uint32_t field) {
    NSData *v = WCExtractField(msg, field);
    if (!v) return nil;
    return [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
}
