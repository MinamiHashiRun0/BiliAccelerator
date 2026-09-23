// test_logic.m — 核心逻辑单元测试（macOS 上运行，验证纯逻辑层的确定性正确）
// 编译：clang -fobjc-arc -framework Foundation tests/test_logic.m -o build/test_logic
// Tweak.m 以 #import 并入同一翻译单元；constructor 通过 BA_NO_CONSTRUCTOR 禁用。

#import <Foundation/Foundation.h>
#import <stdio.h>
#import "../src/Tweak.m"

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, name) do { \
    if (cond) { g_pass++; printf("PASS  %s\n", name); } \
    else { g_fail++; printf("FAIL  %s\n", name); } \
} while (0)

// ---- protobuf wire 构造 helper ----
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

int main(void) {
    @autoreleasepool {
        printf("== Tweak.m logic tests (macOS host) ==\n");

        // ---------- 1. 媒体 URL 判定 ----------
        CHECK(BAIsMediaURL([NSURL URLWithString:@"https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/83/04/abc/1000-1-30064.m4s?e=1"]),
              "isMediaURL: upgcxcode");
        CHECK(BAIsMediaURL([NSURL URLWithString:@"https://x.bilivideo.com/a/b/30216.m4s"]),
              "isMediaURL: m4s file");
        CHECK(!BAIsMediaURL([NSURL URLWithString:@"https://example.com/foo/bar.mp3"]),
              "isMediaURL: non-media rejected");
        CHECK(BAIsLiveMedia([NSURL URLWithString:@"https://upos.example.com/live-bvc/1234.m4s"]),
              "isLiveMedia: live path detected");

        // ---------- 2. 主机分类 ----------
        BAVerdict v1 = BAClassify([NSURL URLWithString:@"https://123.45.67.89:4483/upgcxcode/a.m4s"]);
        CHECK(v1.isPcdn, "classify: IP-like host -> pcdn");
        BAVerdict v2 = BAClassify([NSURL URLWithString:@"https://xy123x456x789x0xy.mcdn.bilivideo.cn:4483/upgcxcode/a.m4s"]);
        CHECK(v2.isMcdn, "classify: xy mcdn host");
        BAVerdict v3 = BAClassify([NSURL URLWithString:@"https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/a.m4s"]);
        CHECK(!v3.isSlow, "classify: overseas mirror NOT slow");
        BAVerdict v4 = BAClassify([NSURL URLWithString:@"https://upos-sz-302ppio.bilivideo.com/upgcxcode/a.m4s"]);
        CHECK(v4.isPcdn, "classify: upos-302 P2P host");
        BAVerdict v5 = BAClassify([NSURL URLWithString:@"https://xxx.szbdyd.com/upgcxcode/a.m4s?xy_usource=upos-sz-mirrorali.bilivideo.com"]);
        CHECK(v5.isScheduler && [v5.schedulerSource isEqualToString:@"upos-sz-mirrorali.bilivideo.com"],
              "classify: scheduler source extracted");

        // ---------- 3. Range 头解析 ----------
        long long f = -9, t = -9;
        CHECK(BAParseRange(@"bytes=100-", &f, &t) && f == 100 && t == -1, "Range: bytes=100-");
        CHECK(BAParseRange(@"bytes=100-200", &f, &t) && f == 100 && t == 200, "Range: bytes=100-200");
        CHECK(BAParseRange(@"bytes=-50", &f, &t) && f == -1 && t == 50, "Range: bytes=-50 (suffix)");
        CHECK(!BAParseRange(@"chunks=1-2", &f, &t), "Range: non-bytes rejected");
        CHECK(!BAParseRange(nil, &f, &t), "Range: nil header rejected");

        // ---------- 4. protobuf 改写（PlayViewUnite 结构，音频豁免） ----------
        NSMutableData *audio = [NSMutableData data];
        putStr(audio, 2, @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/ab/ab/cid/30216.m4s?a=1");

        NSMutableData *dashVideo = [NSMutableData data];
        putStr(dashVideo, 1, @"https://123.45.67.89:4483/upgcxcode/83/04/abc/1000-1-30064.m4s?e=1");
        putStr(dashVideo, 2, @"https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/83/04/abc/1000-1-30064.m4s?e=1");

        NSMutableData *stream = [NSMutableData data];
        putSub(stream, 1, [NSMutableData data]);   // StreamInfo 占位
        putSub(stream, 2, dashVideo);              // DashVideo（视频）

        NSMutableData *vodInfo = [NSMutableData data];
        putSub(vodInfo, 5, stream);                // stream_list
        putSub(vodInfo, 6, audio);                 // dash_audio —— 音频必须原样

        NSMutableData *top = [NSMutableData data];
        putSub(top, 1, vodInfo);                   // VodInfo

        BOOL changed = NO;
        NSData *out = BARewriteProtobufBody(top, &changed);
        CHECK(changed, "protobuf: rewrite reported change");

        NSString *outStr = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
        CHECK([outStr containsString:@"http://127.0.0.1"],
              "protobuf: video URL routed to local proxy");
        CHECK(![outStr containsString:@"123.45.67.89"],
              "protobuf: PCDN host eliminated");
        CHECK([outStr containsString:@"30216.m4s"] && [outStr containsString:@"upos-sz-mirrorcos"],
              "protobuf: audio stream host preserved verbatim");
        // 音频部分不应被包代理：音频 URL 之后不应再出现 127.0.0.1
        NSRange audioLoc = [outStr rangeOfString:@"30216.m4s"];
        BOOL audioProxied = NO;
        if (audioLoc.location != NSNotFound) {
            NSRange tail = [outStr rangeOfString:@"127.0.0.1" options:0 range:NSMakeRange(audioLoc.location, outStr.length - audioLoc.location)];
            audioProxied = tail.location != NSNotFound;
        }
        CHECK(!audioProxied, "protobuf: audio NOT wrapped in proxy");

        // 改写后的 protobuf 仍需是合法 wire 格式（round-trip 解析）：
        // 重新用 BARewriteProtobufBody 处理输出——幂等（已改写内容不变）
        BOOL changed2 = NO;
        NSData *out2 = BARewriteProtobufBody(out, &changed2);
        CHECK(!changed2, "protobuf: rewrite idempotent");

        // ---------- 5. JSON 深改写（音频豁免） ----------
        NSDictionary *payload = @{
            @"code": @0,
            @"data": @{@"dash": @{
                @"video": @[@{@"baseUrl": @"https://123.45.67.89:4483/upgcxcode/a/1/30064.m4s"}],
                @"audio": @[@{@"baseUrl": @"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/83/04/30216.m4s"}],
            }},
        };
        NSData *jd = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        NSString *json = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
        BOOL jch = NO;
        NSString *jout = BARewriteJsonPayload(json, &jch);
        CHECK(jch, "json: rewrite triggered");
        CHECK([jout containsString:@"http://127.0.0.1"],
              "json: video URL proxied");
        NSRange aJ = [jout rangeOfString:@"30216.m4s"];
        CHECK(aJ.location != NSNotFound, "json: audio present");
        if (aJ.location != NSNotFound) {
            NSRange tail = [jout rangeOfString:@"127.0.0.1" options:0 range:NSMakeRange(aJ.location, jout.length - aJ.location)];
            CHECK(tail.location == NSNotFound, "json: audio NOT wrapped in proxy");
        }

        printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
