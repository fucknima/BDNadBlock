// tests/search_data_test.mm — SearchDataRemoval.h 的 macOS host 机制测试
//
// 用动态 fake 类 + 真实同名 selector 跑真实安装器；开关用内存里的假函数，
// 不碰 NSUserDefaults，不写任何文件，不连网，也不启动 App。
//
// 覆盖的是「数据层机制」：开关开且入参非空数组 -> 原 setter 收到非 nil 空数组且只被调一次；
// nil / 空数组 / 非数组 / 关总开关 / 诊断开 / 关 SearchPromo -> 原对象原样透传；
// 重复安装幂等不递归；签名不符不 attach。
//
// 这不是真机测试：只证明上述机制。搜索框的真实布局、轮播标签视觉、点击行为仍需真机实测。
// SearchViewRemoval.h 是 UIKit-only，本机（macOS）不编译、不伪造 UI 行为。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/search_data_test tests/search_data_test.mm
//   /tmp/search_data_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志（FeatureRemoval.h 与 SearchDataRemoval.h 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = NO;
static BOOL gRemoveGameCenter = NO;
static BOOL gRemoveJobNovel = NO;
static BOOL gRemoveSearchPromo = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;          // 只数行数；测试不比对日志文本
    gLogLines++;
}
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveSearchPromo(void) { return gRemoveSearchPromo; }

#include "../FeatureRemoval.h"
#include "../SearchDataRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

// 引用 FeatureRemoval 的静态安装器（顺带让 FeatureRemoval.h 里「另一个开关」的假函数被用上，
// 避免 -Wunused-function；数量不依赖别的 agent 对 FeatureRemoval.h 的改动）。
static void BDSRTestTouchFeatureRemoval(void) {
    (void)BDRemoveRecommend();
    (void)BDRemoveGameCenter();
    (void)BDRemoveJobNovel();
    BDFRInstallAll();          // 三个真实类都不存在 -> 全部 skip；只验证它能被引用
}

static Class BDSRMakeClass(const char *name) {
    Class c = objc_allocateClassPair([NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

#pragma mark - fake 类里的原实现（记录收到的参数）

static unsigned gOrigCalls = 0;
static id gSeenWords = nil;
static void BDSRPhSetStaticWordList(id self, SEL _cmd, id words) {
    (void)self; (void)_cmd;
    gOrigCalls++;
    gSeenWords = words;
}

// 取「当前生效的 IMP」直接调用：既避开 objc_msgSend 声明/ARC 家族的坑，
// 又正好验证安装后运行时查到的就是替换实现。
static void BDSRSendSetWords(id receiver, SEL sel, id words) {
    void (*imp)(id, SEL, id) =
        (void (*)(id, SEL, id))class_getMethodImplementation(object_getClass(receiver), sel);
    imp(receiver, sel, words);
}

#pragma mark - 失败路径：签名不符必须 skip 且不改任何东西

static void test_wrong_encoding_skips(void) {
    IMP orig = NULL;
    BDFRSpec probe;
    probe.cls = "BDPanSearchManager";
    probe.sel = "setStaticWordList:";
    probe.isClassMethod = NO;
    probe.enc = "v24@0:8@16";
    probe.argc = 3;
    probe.hook = NULL;
    probe.orig = &orig;
    probe.name = "probe";
    probe.installed = NO;
    // 类还不存在：resolve 必须返回 NULL，且不碰任何 IMP。
    CHECK(BDFRResolve(&probe) == NULL);
    CHECK(orig == NULL);

    // 类存在但 encoding 不符 -> 同样 skip。
    Class c = BDSRMakeClass("BDSRTestBadEnc");
    CHECK(class_addMethod(c, sel_registerName("setStaticWordList:"),
                          (IMP)BDSRPhSetStaticWordList, "v24@0:8q16"));
    probe.cls = "BDSRTestBadEnc";
    CHECK(BDFRResolve(&probe) == NULL);
    CHECK(orig == NULL);
    // probe.sel 是 const char *，class_getInstanceMethod 要的是 SEL，必须过一遍 sel_registerName。
    SEL badSel = sel_registerName(probe.sel);
    CHECK(method_getImplementation(class_getInstanceMethod(c, badSel))
          == (IMP)BDSRPhSetStaticWordList);
}

#pragma mark - 真实 spec

static void test_real_spec(void) {
    Class mgr = BDSRMakeClass("BDPanSearchManager");
    SEL sel = sel_registerName("setStaticWordList:");
    CHECK(class_addMethod(mgr, sel, (IMP)BDSRPhSetStaticWordList, "v24@0:8@16"));
    id obj = [[mgr alloc] init];

    // 安装前：原实现原样收到入参。
    NSArray *words = @[@"徐涛独家资料", @"扫描文档"];
    gSeenWords = nil;
    gOrigCalls = 0;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gOrigCalls == 1 && gSeenWords == words);

    unsigned logsBefore = gLogLines;
    BDSRInstallData();
    CHECK(BDSRSpecStaticWordList.installed == YES);
    CHECK(*BDSRSpecStaticWordList.orig == (IMP)BDSRPhSetStaticWordList);
    CHECK(method_getImplementation(class_getInstanceMethod(mgr, sel))
          == (IMP)BDSRSetStaticWordList);
    CHECK(gLogLines == logsBefore + 1);              // 一条 installed

    // 1) 开关开 + 非空数组 -> 原 setter 收到「非 nil 的空 NSArray」，且只被调一次。
    logsBefore = gLogLines;
    unsigned calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gOrigCalls == calls + 1);                  // 原实现仍然被调（不跳过）
    CHECK(gSeenWords != nil);
    CHECK([gSeenWords isKindOfClass:[NSArray class]]);
    CHECK(((NSArray *)gSeenWords).count == 0);
    CHECK(gSeenWords != words);                       // 不是原对象
    CHECK(gLogLines == logsBefore + 1);               // 一条首次 hit

    // 2) 再次抑制不再打日志（dispatch_once）。
    BDSRSendSetWords(obj, sel, @[@"a"]);
    BDSRSendSetWords(obj, sel, @[@"b"]);
    CHECK(gLogLines == logsBefore + 1);

    // 3) nil / 空数组 / 非数组 -> 原对象原样透传。
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, nil);
    CHECK(gSeenWords == nil && gOrigCalls == calls + 1);

    NSArray *empty = @[];
    BDSRSendSetWords(obj, sel, empty);
    CHECK(gSeenWords == empty && gOrigCalls == calls + 2);

    NSString *notArray = @"不是数组";
    BDSRSendSetWords(obj, sel, notArray);
    CHECK(gSeenWords == notArray && gOrigCalls == calls + 3);

    // 3b) 非空 NSMutableArray 也是 NSArray 且非空 -> 同样清成空数组，
    //     并且调用方那个可变数组自身必须毫发无损（不原地改调用方对象）。
    NSMutableArray *mutableWords = [NSMutableArray arrayWithObjects:@"x", nil];
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, mutableWords);
    CHECK(gOrigCalls == calls + 1);
    CHECK(gSeenWords != nil);
    CHECK([gSeenWords isKindOfClass:[NSArray class]]);
    CHECK(((NSArray *)gSeenWords).count == 0);
    CHECK(gSeenWords != mutableWords);
    CHECK([mutableWords count] == 1);                    // 原始对象没被改
    CHECK([[mutableWords objectAtIndex:0] isEqualToString:@"x"]);

    // 4) 关掉 SearchPromo -> 原对象原样透传。
    gRemoveSearchPromo = NO;
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gSeenWords == words && gOrigCalls == calls + 1);
    gRemoveSearchPromo = YES;

    // 5) 诊断开 -> 透传；总开关关 -> 透传。
    gDumpOnly = YES;
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gSeenWords == words && gOrigCalls == calls + 1);
    gDumpOnly = NO;

    gEnabled = NO;
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gSeenWords == words && gOrigCalls == calls + 1);
    gEnabled = YES;

    // 6) 幂等：再装一次不重复包装、不递归；透传路径下原实现只被调一次。
    BDSRInstallData();
    CHECK(*BDSRSpecStaticWordList.orig == (IMP)BDSRPhSetStaticWordList);
    CHECK(method_getImplementation(class_getInstanceMethod(mgr, sel))
          == (IMP)BDSRSetStaticWordList);
    gRemoveSearchPromo = NO;
    calls = gOrigCalls;
    BDSRSendSetWords(obj, sel, words);
    CHECK(gSeenWords == words && gOrigCalls == calls + 1);
    gRemoveSearchPromo = YES;
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        BDSRTestTouchFeatureRemoval();
        test_wrong_encoding_skips();
        test_real_spec();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}