// tests/personal_removal_test.mm — PersonalRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（PersonalRemoval.h）与**真实** FeatureRemoval.h 安装器，
// 只有开关、日志和替换实现用假的：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemovePersonalBanner（FeatureRemoval.h 与 PersonalRemoval.h 都按同名静态函数引用）
//   - BDFRInstallAll() 会引用这些假开关，但旧三个 hook 的类/方法在这里不存在，会逐条 skip；
//     它**不会**碰 bannerSwitch（那由 BDPRInstallData 单独装）。
// 动态 fake 类 BDPanPersonalConfig 的元类上注册 bannerSwitch（B 编码），原返回值与调用次数可调。
//
// 这不是真机测试：只证明「安装前透传原值 / 开关组合决定是否抑制 / 关闭时逐次透传原实现 /
// 幂等不递归不自指 / 签名或类不符就 skip」。真机上「轮播 section 真的不再创建、请求是否归零」
// 仍需实测，host 测试不承诺。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/personal_removal_test tests/personal_removal_test.mm
//   /tmp/personal_removal_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志（两个产品 header 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gRemovePersonalBanner = YES;
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
static BOOL BDRemovePersonalBanner(void) { return gRemovePersonalBanner; }

// 顺序即真实接线顺序：先 FeatureRemoval.h（安装器 + 三个旧 hook），再 PersonalRemoval.h。
#include "../FeatureRemoval.h"
#include "../PersonalRemoval.h"

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
static Class BDPRMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

// 本测试自用的 spec 描述（产品 header 里那条是静态的，不在这里造第二套安装器）。
static BDFRSpec BDPRTestSpec(const char *cls, const char *sel, BOOL isClassMethod,
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

// 取「当前生效的 IMP」直接调用：避免 objc_msgSend 声明/ARC 家族的坑，
// 同时验证安装后运行时查到的就是替换实现。B 编码的返回用内建 bool。
static bool BDPRSendBool(id receiver, SEL sel) {
    bool (*imp)(id, SEL) =
        (bool (*)(id, SEL))class_getMethodImplementation(object_getClass(receiver), sel);
    return imp(receiver, sel);
}

#pragma mark - 替身实现

static bool gBannerOrigResult = true;   // 原实现的返回值，可调
static unsigned gBannerOrigCalls = 0;   // 原实现被调次数

static bool PhBannerSwitch(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gBannerOrigCalls++;
    return gBannerOrigResult;
}

static Class gPersonalCfg;

static void setup_real_class(void) {
    gPersonalCfg = BDPRMakeClass("BDPanPersonalConfig", Nil);
    // 类方法：注册在 metaclass 自己的方法表里，编码与真方法一致。
    CHECK(class_addMethod(object_getClass(gPersonalCfg),
                          sel_registerName("bannerSwitch"),
                          (IMP)PhBannerSwitch, "B16@0:8"));
}

#pragma mark - 测试

static void test_before_install(void) {
    CHECK(objc_getClass("BDPanPersonalConfig") == NULL);   // 还没建 fake 类
    setup_real_class();
    SEL sel = sel_registerName("bannerSwitch");

    CHECK(BDPRSpecBannerSwitch.installed == NO);
    gBannerOrigResult = true;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);   // 安装前就是原返回值
    CHECK(gBannerOrigCalls == 1);

    gBannerOrigResult = false;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);  // 原返回 false 也照实
    CHECK(gBannerOrigCalls == 2);

    // 旧三个 hook 的类不存在：BDFRInstallAll() 逐条 skip，且绝不碰 bannerSwitch
    unsigned logsBefore = gLogLines;
    BDFRInstallAll();
    CHECK(gLogLines > logsBefore);                        // 至少有 skip 日志
    CHECK(BDPRSpecBannerSwitch.installed == NO);          // 它由 BDPRInstallData 单独装
    CHECK(gBannerOrigCalls == 2);                         // 安装过程不调用任何替换实现
}

static void test_install_and_gate(void) {
    SEL sel = sel_registerName("bannerSwitch");
    unsigned logsBefore = gLogLines;
    BDPRInstallData();
    CHECK(BDPRSpecBannerSwitch.installed == YES);
    CHECK(*BDPRSpecBannerSwitch.orig == (IMP)PhBannerSwitch);   // orig 存的是原实现
    CHECK(method_getImplementation(class_getClassMethod(gPersonalCfg, sel))
          == (IMP)BDPRBannerSwitch);
    CHECK(gLogLines == logsBefore + 1);                       // 一行 installed

    // 1) 三个开关都开 + 原实现本来说 true -> 被抑制成 false，且只打一行 hit
    gBannerOrigResult = true;
    gBannerOrigCalls = 0;
    logsBefore = gLogLines;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);
    CHECK(gBannerOrigCalls == 0);                             // 抑制时压根不碰原实现
    CHECK(gLogLines == logsBefore + 1);                       // 首次真正抑制才 hit
    for (int i = 0; i < 3; i++) CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);
    CHECK(gLogLines == logsBefore + 1);                       // dispatch_once，不再打

    // 2) 总开关关 -> 透传原返回值（true），并且原实现被调一次
    gEnabled = NO;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);
    CHECK(gBannerOrigCalls == 1);
    gEnabled = YES;

    // 3) 诊断开启 -> 同样透传
    gDumpOnly = YES;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);
    CHECK(gBannerOrigCalls == 1);
    gDumpOnly = NO;

    // 4) 独立开关关 -> 同样透传；顺带证明其它 promo 开关互不影响
    gRemovePersonalBanner = NO;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);
    CHECK(gBannerOrigCalls == 1);
    gRemoveGameCenter = NO;
    gRemoveJobNovel = NO;
    gRemoveRecommend = NO;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);
    CHECK(gBannerOrigCalls == 1);
    gRemoveRecommend = YES;
    gRemoveGameCenter = YES;
    gRemoveJobNovel = YES;
    gRemovePersonalBanner = YES;

    // 5) 原实现本来说 false 时，透传 false（不是「再抑制一次」）
    gBannerOrigResult = false;
    gBannerOrigCalls = 0;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);   // 开关全开 -> 直接抑制，原实现没被调
    gEnabled = NO;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);   // 关总开关 -> 原 false 原样透传
    CHECK(gBannerOrigCalls == 1);
    gBannerOrigResult = true;
    gEnabled = YES;

    // 6) 幂等：重复安装不重装、不递归，orig 槽不被写成替换实现
    gBannerOrigResult = true;
    gBannerOrigCalls = 0;
    CHECK(BDFRResolve(&BDPRSpecBannerSwitch) != NULL);      // 仍是同一个 Method
    BDPRInstallData();
    CHECK(BDPRSpecBannerSwitch.installed == YES);
    CHECK(*BDPRSpecBannerSwitch.orig == (IMP)PhBannerSwitch);
    CHECK(*BDPRSpecBannerSwitch.orig != (IMP)BDPRBannerSwitch);   // orig 不能自指
    CHECK(method_getImplementation(class_getClassMethod(gPersonalCfg, sel))
          == (IMP)BDPRBannerSwitch);
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == false);    // 抑制照旧
    CHECK(gBannerOrigCalls == 0);
    gEnabled = NO;
    CHECK(BDPRSendBool((id)gPersonalCfg, sel) == true);     // 透传只穿透一次原实现
    CHECK(gBannerOrigCalls == 1);
    gEnabled = YES;
}

// 失败路径：独立 phantom 类，绝不 class_addMethod 覆盖已存在的方法，也不改 runtime encoding。
static void test_skip_paths(void) {
    // 1) 签名不符（真注册的是 B24@0:8，spec 期望 B16@0:8）-> 不装
    Class wrongEnc = BDPRMakeClass("BDPRPhantomWrongEnc", Nil);
    CHECK(class_addMethod(object_getClass(wrongEnc),
                          sel_registerName("bannerSwitch"),
                          (IMP)PhBannerSwitch, "B24@0:8"));
    IMP origWrong = NULL;
    BDFRSpec s1 = BDPRTestSpec("BDPRPhantomWrongEnc", "bannerSwitch", YES,
                               "B16@0:8", 2, (IMP)BDPRBannerSwitch, &origWrong, "t-wrong-enc");
    CHECK(BDFRInstallSpec(&s1) == NO);
    CHECK(s1.installed == NO);
    CHECK(origWrong == NULL);
    gBannerOrigResult = true;
    CHECK(BDPRSendBool((id)wrongEnc, sel_registerName("bannerSwitch")) == true);

    // 2) 参数个数不符（期望 argc 3，真值 2）-> 不装
    IMP origArgc = NULL;
    BDFRSpec s2 = BDPRTestSpec("BDPRPhantomWrongEnc", "bannerSwitch", YES,
                               "B24@0:8", 3, (IMP)BDPRBannerSwitch, &origArgc, "t-wrong-argc");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO);
    CHECK(origArgc == NULL);

    // 3) 当实例方法装（同名 selector 在 metaclass，不在类自己的实例方法表）-> 不装
    IMP origKind = NULL;
    BDFRSpec s3 = BDPRTestSpec("BDPRPhantomWrongEnc", "bannerSwitch", NO,
                               "B24@0:8", 2, (IMP)BDPRBannerSwitch, &origKind, "t-wrong-kind");
    CHECK(BDFRInstallSpec(&s3) == NO);
    CHECK(s3.installed == NO);
    CHECK(origKind == NULL);

    // 4) 类缺失 -> 不装
    IMP origMissing = NULL;
    BDFRSpec s4 = BDPRTestSpec("BDPRPhantomMissingClass", "bannerSwitch", YES,
                               "B16@0:8", 2, (IMP)BDPRBannerSwitch, &origMissing, "t-missing-class");
    CHECK(BDFRInstallSpec(&s4) == NO);
    CHECK(s4.installed == NO);
    CHECK(origMissing == NULL);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        test_before_install();
        test_install_and_gate();
        test_skip_paths();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}