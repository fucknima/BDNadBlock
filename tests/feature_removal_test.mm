// tests/feature_removal_test.mm — FeatureRemoval.h 的 macOS host 机制测试
//
// 用动态 fake 类 + 真实同名 selector 跑真实安装器；开关用内存里的假函数，
// 不碰 NSUserDefaults，不写任何文件，不连网。
//
// 这不是真机测试：只证明「匹配时抑制 / 签名或方法不符时 skip / 透传原实现 / 幂等不递归 /
// 不动父类 / 一对校验不完整就一个都不装」这些机制。真机布局与网络行为仍需实测。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/feature_removal_test tests/feature_removal_test.mm
//   /tmp/feature_removal_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志（FeatureRemoval.h 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;          // 只数行数；测试不比对日志文本
    gLogLines++;
}
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }

#include "../FeatureRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

// 动态 fake 类：名字必须唯一，注册失败（重名或已被占用）要立刻暴露。
static Class BDFRMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

// 取「当前生效的 IMP」直接调用：既避免 objc_msgSend 声明/ARC 家族的坑，
// 又正好验证安装后运行时查到的就是替换实现。B 编码的返回用内建 bool（见 FeatureRemoval.h）。
static bool BDFRSendBool(id receiver, SEL sel) {
    bool (*imp)(id, SEL) =
        (bool (*)(id, SEL))class_getMethodImplementation(object_getClass(receiver), sel);
    return imp(receiver, sel);
}
static NSInteger BDFRSendCount(id receiver, SEL sel, id first, NSInteger second) {
    NSInteger (*imp)(id, SEL, id, NSInteger) =
        (NSInteger (*)(id, SEL, id, NSInteger))class_getMethodImplementation(object_getClass(receiver), sel);
    return imp(receiver, sel, first, second);
}

static BDFRSpec BDFRTestSpec(const char *cls, const char *sel, BOOL isClassMethod,
                             const char *enc, unsigned argc, IMP hook,
                             IMP *orig, const char *name) {
    BDFRSpec s;
    s.cls = cls;
    s.sel = sel;
    s.isClassMethod = isClassMethod;
    s.enc = enc;
    s.argc = argc;
    s.hook = hook;
    s.orig = orig;
    s.name = name;
    s.installed = NO;
    return s;
}

#pragma mark - 替身实现

// B 编码的替身实现用内建 bool 作为返回值（与 "B16@0:8" 一致，不用 BOOL）。
static unsigned gBoolNoCalls = 0;
static bool PhBoolNo(id self, SEL _cmd) {          // 当「原实现」：恒 false
    (void)self; (void)_cmd;
    gBoolNoCalls++;
    return false;
}
static bool PhBoolYes(id self, SEL _cmd) {         // 当「替换实现」：恒 true
    (void)self; (void)_cmd;
    gBoolNoCalls++;
    return true;
}

// 三个真实目标方法在 fake 类里的原实现：返回值可调，记录收到的参数。
static bool gHomeRecommend = true;
static unsigned gHomeRecommendCalls = 0;
static bool PhHomeRecommend(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gHomeRecommendCalls++;
    return gHomeRecommend;
}

static NSInteger gRowCount = 7;
static id gSeenTableView = nil;
static NSInteger gSeenSection = -1;
static NSInteger PhRowCount(id self, SEL _cmd, id tableView, NSInteger section) {
    (void)self; (void)_cmd;
    gSeenTableView = tableView;
    gSeenSection = section;
    return gRowCount;
}

static bool gGameCenter = true;
static bool PhGameCenter(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return gGameCenter;
}

#pragma mark - 机制测试（失败路径：类/方法/签名不符必须 skip 且不改任何东西）

static void test_missing_class_or_selector(void) {
    // 类不存在
    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomMissing", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-missing");
    CHECK(BDFRInstallSpec(&s) == NO);
    CHECK(s.installed == NO);
    CHECK(orig == NULL);

    // 类存在，但 selector 不在它自己的方法表里 -> 同样 skip，什么都不改
    Class c = BDFRMakeClass("BDFRPhantomNoSel", Nil);
    IMP orig2 = NULL;
    BDFRSpec s2 = BDFRTestSpec("BDFRPhantomNoSel", "phantomMissing", NO,
                               "B16@0:8", 2, (IMP)PhBoolYes, &orig2, "t-nosel");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO);
    CHECK(orig2 == NULL);
    CHECK(class_getInstanceMethod(c, sel_registerName("phantomMissing")) == NULL);
}

static void test_inherited_method_not_touched(void) {
    Class parent = BDFRMakeClass("BDFRPhantomParent", Nil);
    CHECK(class_addMethod(parent, sel_registerName("phantomInherited"), (IMP)PhBoolNo, "B16@0:8"));
    Class child = BDFRMakeClass("BDFRPhantomChild", parent);   // child 自己没实现，只有继承

    SEL sel = sel_registerName("phantomInherited");
    IMP before = method_getImplementation(class_getInstanceMethod(parent, sel));
    CHECK(before == (IMP)PhBoolNo);

    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomChild", "phantomInherited", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-inherited");
    CHECK(BDFRInstallSpec(&s) == NO);             // child 自己没有这个方法 -> 跳过
    CHECK(s.installed == NO);
    // 父类的 Method 槽没被碰过，child 仍走父类实现
    CHECK(method_getImplementation(class_getInstanceMethod(parent, sel)) == before);
    CHECK(method_getImplementation(class_getInstanceMethod(child, sel)) == before);
    CHECK(BDFRSendBool([[child alloc] init], sel) == false);   // 走的是原实现，不是替换实现
}

static void test_encoding_and_argc_mismatch(void) {
    Class c = BDFRMakeClass("BDFRPhantomBadEnc", Nil);
    CHECK(class_addMethod(c, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP orig = NULL;
    BDFRSpec bad = BDFRTestSpec("BDFRPhantomBadEnc", "phantomBool", NO,
                                "B24@0:8@16", 2, (IMP)PhBoolYes, &orig, "t-badenc");
    CHECK(BDFRInstallSpec(&bad) == NO);

    IMP orig2 = NULL;
    BDFRSpec badArgc = BDFRTestSpec("BDFRPhantomBadEnc", "phantomBool", NO,
                                    "B16@0:8", 3, (IMP)PhBoolYes, &orig2, "t-argc");
    CHECK(BDFRInstallSpec(&badArgc) == NO);

    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolNo);
    CHECK(BDFRSendBool([[c alloc] init], sel) == false);
    CHECK(orig == NULL && orig2 == NULL);
}

// H1+H2 那种「一对」：任一条校验失败，两条都不许装。
static void test_pair_checked_before_install(void) {
    Class ok = BDFRMakeClass("BDFRPhantomPairOk", Nil);
    CHECK(class_addMethod(ok, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP origA = NULL;
    IMP origB = NULL;
    BDFRSpec a = BDFRTestSpec("BDFRPhantomPairOk", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origA, "t-pair-ok");
    BDFRSpec b = BDFRTestSpec("BDFRPhantomPairMissing", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origB, "t-pair-missing");
    CHECK(BDFRInstallPair(&a, &b) == NO);
    CHECK(a.installed == NO && b.installed == NO);
    CHECK(origA == NULL && origB == NULL);
    // 通过校验的那条也不许被装
    CHECK(method_getImplementation(class_getInstanceMethod(ok, sel)) == (IMP)PhBoolNo);
    CHECK(BDFRSendBool([[ok alloc] init], sel) == false);      // 抑制开着也走原实现
}

// A 的槽里已经就是「本 hook」，但 A 没标 installed（例如另一个 spec 用同一个 hook 装过）：
// Pair 必须整体拒绝，B 不许被改，两个 orig 都不许被写。
static void test_pair_refuses_when_slot_is_our_hook(void) {
    Class ca = BDFRMakeClass("BDFRPhantomCollideA", Nil);
    Class cb = BDFRMakeClass("BDFRPhantomCollideB", Nil);
    SEL sel = sel_registerName("phantomBool");
    CHECK(class_addMethod(ca, sel, (IMP)PhBoolYes, "B16@0:8"));   // 槽已是替换实现，但没走安装器
    CHECK(class_addMethod(cb, sel, (IMP)PhBoolNo, "B16@0:8"));

    IMP origA = NULL;
    IMP origB = NULL;
    BDFRSpec a = BDFRTestSpec("BDFRPhantomCollideA", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origA, "t-collide-a");
    BDFRSpec b = BDFRTestSpec("BDFRPhantomCollideB", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origB, "t-collide-b");
    CHECK(BDFRInstallPair(&a, &b) == NO);
    CHECK(a.installed == NO && b.installed == NO);
    CHECK(origA == NULL && origB == NULL);
    CHECK(method_getImplementation(class_getInstanceMethod(ca, sel)) == (IMP)PhBoolYes);  // A 没被动
    CHECK(method_getImplementation(class_getInstanceMethod(cb, sel)) == (IMP)PhBoolNo);   // B 没被改
    CHECK(BDFRSendBool([[cb alloc] init], sel) == false);                                 // B 仍是原实现
}

static void test_install_success_and_idempotent(void) {
    Class c = BDFRMakeClass("BDFRPhantomOk", Nil);
    CHECK(class_addMethod(c, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomOk", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-ok");
    CHECK(BDFRInstallSpec(&s) == YES);
    CHECK(s.installed == YES);
    CHECK(orig == (IMP)PhBoolNo);                 // 存的是原实现，不是 replacement
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    id obj = [[c alloc] init];
    CHECK(BDFRSendBool(obj, sel) == true);        // 抑制开 -> replacement

    // 同一 spec 重复安装：认幂等，不重复包装
    CHECK(BDFRInstallSpec(&s) == YES);
    CHECK(orig == (IMP)PhBoolNo);
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    // 另一个 spec 对象但同一个 hook 函数：绝不把自己（或别人的 replacement）存成 original
    IMP again = NULL;
    BDFRSpec s2 = BDFRTestSpec("BDFRPhantomOk", "phantomBool", NO,
                               "B16@0:8", 2, (IMP)PhBoolYes, &again, "t-ok-dup");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(again == NULL);
    CHECK(s2.installed == NO);
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    // 装了替换实现后，原实现不再被调用；重复安装也不会让它被调两次（这里 hook 是哑替身，
    // 真正「透传 + 不递归」的验证在 test_real_specs 用真实 hook 做）
    unsigned before = gBoolNoCalls;
    CHECK(BDFRSendBool(obj, sel) == true);
    CHECK(gBoolNoCalls == before);
}

#pragma mark - 三个真实 spec + 真实同名类/selector

static Class gHomeCfg;      // BHSettings
static Class gRowsCtrl;     // BDPanNewMSHContentViewController
static Class gPersonalCfg;  // BDPanPersonalConfig

static void test_real_specs(void) {
    CHECK(objc_getClass("BHSettings") == NULL);
    CHECK(objc_getClass("BDPanNewMSHContentViewController") == NULL);
    CHECK(objc_getClass("BDPanPersonalConfig") == NULL);

    gHomeCfg = BDFRMakeClass("BHSettings", Nil);
    gRowsCtrl = BDFRMakeClass("BDPanNewMSHContentViewController", Nil);
    gPersonalCfg = BDFRMakeClass("BDPanPersonalConfig", Nil);
    CHECK(class_addMethod(object_getClass(gHomeCfg),
                          sel_registerName("isMSHSwitchTypeHomeRecommend"),
                          (IMP)PhHomeRecommend, "B16@0:8"));
    CHECK(class_addMethod(gRowsCtrl,
                          sel_registerName("tableView:numberOfRowsInSection:"),
                          (IMP)PhRowCount, "q32@0:8@16q24"));
    CHECK(class_addMethod(object_getClass(gPersonalCfg),
                          sel_registerName("gameCenterSwitch"),
                          (IMP)PhGameCenter, "B16@0:8"));

    SEL homeSel = sel_registerName("isMSHSwitchTypeHomeRecommend");
    SEL rowSel = sel_registerName("tableView:numberOfRowsInSection:");
    SEL gameSel = sel_registerName("gameCenterSwitch");
    id rows = [[gRowsCtrl alloc] init];
    NSObject *tv = [NSObject new];

    // 0) 安装前：三个目标都还是原实现的原值（说明后面的抑制确实来自替换实现）
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 3) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 3);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);

    unsigned logsBefore = gLogLines;
    BDFRInstallAll();     // H1+H2 一对 + H3 独立
    CHECK(BDFRSpecHomeRecommend.installed && BDFRSpecHomeRowCount.installed
          && BDFRSpecGameCenter.installed);
    CHECK(*BDFRSpecHomeRecommend.orig == (IMP)PhHomeRecommend);
    CHECK(*BDFRSpecHomeRowCount.orig == (IMP)PhRowCount);
    CHECK(*BDFRSpecGameCenter.orig == (IMP)PhGameCenter);
    CHECK(gLogLines == logsBefore + 3);           // 三条 installed 日志
    logsBefore = gLogLines;                       // 往后只数 hit 日志

    // 1) 默认（三个开关都开）：首页整块与游戏都被抑制
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == false);
    CHECK(BDFRSendCount(rows, rowSel, (id)@"tv", 5) == 0);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == false);

    // 2) 各自关掉抑制 -> 透传原实现原值；H2 还要把参数原样传下去
    gRemoveRecommend = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 9) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 9);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == false);   // 推荐开关不影响游戏
    gRemoveRecommend = YES;

    gRemoveGameCenter = NO;
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == false);       // 游戏开关不影响首页
    gRemoveGameCenter = YES;

    // 3) dump-only 与总开关都要透传（H2 连参数一起透传）
    gDumpOnly = YES;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 11) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 11);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    gDumpOnly = NO;

    gEnabled = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 1) == 7);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    gEnabled = YES;

    // 4) hit 日志每个 hook 只打一次（dispatch_once），多打几次不再增加
    for (int i = 0; i < 5; i++) {
        (void)BDFRSendBool((id)gHomeCfg, homeSel);
        (void)BDFRSendCount(rows, rowSel, tv, i);
        (void)BDFRSendBool((id)gPersonalCfg, gameSel);
    }
    CHECK(gLogLines == logsBefore + 3);           // 三个 hook 各一行首次 hit

    // 5) 幂等：再装一次不重复包装、不递归
    BDFRInstallAll();
    CHECK(*BDFRSpecHomeRowCount.orig == (IMP)PhRowCount);
    CHECK(method_getImplementation(class_getClassMethod(gHomeCfg, homeSel))
          == (IMP)BDFRHomeRecommend);
    CHECK(method_getImplementation(class_getInstanceMethod(gRowsCtrl, rowSel))
          == (IMP)BDFRHomeRowCount);

    unsigned calls = gHomeRecommendCalls;
    gRemoveRecommend = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(gHomeRecommendCalls == calls + 1);      // 原实现只被调一次
    gRemoveRecommend = YES;
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        test_missing_class_or_selector();
        test_inherited_method_not_touched();
        test_encoding_and_argc_mismatch();
        test_pair_checked_before_install();
        test_pair_refuses_when_slot_is_our_hook();
        test_install_success_and_idempotent();
        test_real_specs();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}
