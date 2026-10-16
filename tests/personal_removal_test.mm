// tests/personal_removal_test.mm — PersonalRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（PersonalRemoval.h）与**真实** FeatureRemoval.h 安装器，
// 只有开关、日志和替换实现用假的：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemovePersonalBanner（FeatureRemoval.h 与 PersonalRemoval.h 都按同名静态函数引用）
//   - BDFRInstallAll() 会引用这些假开关，但旧三个 hook 的类/方法在这里不存在，会逐条 skip；
//     它**不会**碰 bannerSwitch（那由 BDPRInstallData 单独装）。
// 动态 fake 类 BDPanPersonalConfig 的元类上注册 bannerSwitch（B 编码），原返回值与调用次数可调；
// 另有两个 fake 类 BDPanPersonalWalletSection / BDPanPersonalCenterWalletSection，各自注册
// 真实的 -heightForView（d16@0:8），原返回值与调用次数可调 —— 用来验证推广整排的收起值透传。
//
// 这不是真机测试：只证明「安装前透传原值 / 开关组合决定是否抑制 / 关闭时逐次透传原实现 /
// 幂等不递归不自指 / 签名或类不符就 skip」。真机上「轮播与推广整排真的不再显示、请求是否归零」
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
static BOOL gRemovePersonalPromotions = YES;
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
static BOOL BDRemovePersonalPromotions(void) { return gRemovePersonalPromotions; }

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

// 同上，但走**实例**方法表（-heightForView 不是类方法），返回类型是 d 编码的 double。
static double BDPRSendInstanceDouble(id obj, SEL sel) {
    double (*imp)(id, SEL) = (double (*)(id, SEL))class_getMethodImplementation([obj class], sel);
    return imp(obj, sel);
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

// 推广整排：两个 class 各自的 -heightForView 替身（d16@0:8）。
// 原返回值分别取 80.0 / 120.0（对应两个 class 在真机上的常态高度），
// 这样「收起值 -6.0 / -3.0」和「透传原值」在断言里不会互相混淆。
static double gWalletOrigResult = 80.0;
static unsigned gWalletOrigCalls = 0;
static double gCenterWalletOrigResult = 120.0;
static unsigned gCenterWalletOrigCalls = 0;

static double PhWalletHeight(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gWalletOrigCalls++;
    return gWalletOrigResult;
}

static double PhCenterWalletHeight(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gCenterWalletOrigCalls++;
    return gCenterWalletOrigResult;
}

static Class gWalletSection;
static Class gCenterWalletSection;

// 必须在第一次 BDPRInstallData() 之前建好：两个 class 各有自己的 heightForView，
// 不靠「类缺失」来凑部分安装 —— 装不上只会走各自的 skip 分支（见 test_skip_paths）。
static void setup_wallet_classes(void) {
    gWalletSection = BDPRMakeClass("BDPanPersonalWalletSection", Nil);
    CHECK(class_addMethod(gWalletSection, sel_registerName("heightForView"),
                          (IMP)PhWalletHeight, "d16@0:8"));
    gCenterWalletSection = BDPRMakeClass("BDPanPersonalCenterWalletSection", Nil);
    CHECK(class_addMethod(gCenterWalletSection, sel_registerName("heightForView"),
                          (IMP)PhCenterWalletHeight, "d16@0:8"));
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

    // 推广整排两条也在这里验「安装前」：spec 未装、getter 仍是原返回值、各被调一次。
    // 它们的安装发生在 test_install_and_gate 的 BDPRInstallData() 里，所以只能在这里看。
    SEL hsel = sel_registerName("heightForView");
    id walletBefore = [[gWalletSection alloc] init];
    id centerBefore = [[gCenterWalletSection alloc] init];
    CHECK(BDPRSpecWalletHeight.installed == NO);
    CHECK(BDPRSpecCenterWalletHeight.installed == NO);
    CHECK(BDPRSendInstanceDouble(walletBefore, hsel) == 80.0);
    CHECK(gWalletOrigCalls == 1);
    CHECK(BDPRSendInstanceDouble(centerBefore, hsel) == 120.0);
    CHECK(gCenterWalletOrigCalls == 1);

    // 旧三个 hook 的类不存在：BDFRInstallAll() 逐条 skip，且绝不碰 bannerSwitch 与 wallet 两条
    unsigned logsBefore = gLogLines;
    BDFRInstallAll();
    CHECK(gLogLines > logsBefore);                        // 至少有 skip 日志
    CHECK(BDPRSpecBannerSwitch.installed == NO);          // 它由 BDPRInstallData 单独装
    CHECK(gBannerOrigCalls == 2);                         // 安装过程不调用任何替换实现
    CHECK(BDPRSpecWalletHeight.installed == NO);
    CHECK(BDPRSpecCenterWalletHeight.installed == NO);
    CHECK(gWalletOrigCalls == 1);
    CHECK(gCenterWalletOrigCalls == 1);
}

static void test_install_and_gate(void) {
    SEL sel = sel_registerName("bannerSwitch");
    unsigned logsBefore = gLogLines;
    BDPRInstallData();
    CHECK(BDPRSpecBannerSwitch.installed == YES);
    CHECK(*BDPRSpecBannerSwitch.orig == (IMP)PhBannerSwitch);   // orig 存的是原实现
    CHECK(method_getImplementation(class_getClassMethod(gPersonalCfg, sel))
          == (IMP)BDPRBannerSwitch);
    // 一行 installed（banner）+ 本轮新增的两条 wallet installed = 3 行。
    // 本次只改了这条计数：BDPRInstallData 现在一次装三条 spec，断言语义（透传/抑制/幂等/自指）一字未动。
    CHECK(gLogLines == logsBefore + 3);

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

    // 5) 推广整排：签名不符（真注册 d32@0:8，spec 期望 d16@0:8）-> 不装
    Class wrongHeight = BDPRMakeClass("BDPRPhantomWalletWrongEnc", Nil);
    CHECK(class_addMethod(wrongHeight, sel_registerName("heightForView"),
                          (IMP)PhWalletHeight, "d32@0:8"));
    IMP origWalletEnc = NULL;
    BDFRSpec s5 = BDPRTestSpec("BDPRPhantomWalletWrongEnc", "heightForView", NO,
                               "d16@0:8", 2, (IMP)BDPRWalletHeight, &origWalletEnc,
                               "t-wallet-wrong-enc");
    CHECK(BDFRInstallSpec(&s5) == NO);
    CHECK(s5.installed == NO);
    CHECK(origWalletEnc == NULL);

    // 6) 参数个数不符：指向已注册的真 wallet class（编码 d16@0:8 本来就对），
    //    只把 argc 描述成 3 -> BDFRResolve 先在 argc 上 mismatch 就 skip，不写任何槽。
    //    不 class_addMethod 覆盖已有方法，也不重复验证 encoding。
    IMP origWalletArgc = NULL;
    BDFRSpec s6 = BDPRTestSpec("BDPanPersonalWalletSection", "heightForView", NO,
                               "d16@0:8", 3, (IMP)BDPRWalletHeight, &origWalletArgc,
                               "t-wallet-wrong-argc");
    CHECK(BDFRInstallSpec(&s6) == NO);
    CHECK(s6.installed == NO);
    CHECK(origWalletArgc == NULL);

    // 7) 推广整排：类缺失 -> 不装（真的两个 wallet class 在 main 里已建好，这里单测缺类分支）
    IMP origWalletMissing = NULL;
    BDFRSpec s7 = BDPRTestSpec("BDPRPhantomWalletMissingClass", "heightForView", NO,
                               "d16@0:8", 2, (IMP)BDPRWalletHeight, &origWalletMissing,
                               "t-wallet-missing-class");
    CHECK(BDFRInstallSpec(&s7) == NO);
    CHECK(s7.installed == NO);
    CHECK(origWalletMissing == NULL);
}

// 推广整排的机制：两个 class 各自的 -heightForView 被强制返回**该 class 自己的原生收起值**
// （新个人页 -6.0，旧个人中心页 -3.0），关闭时逐次精确透传原返回值。
// 注意：进入本用例时两条 spec 已由 test_install_and_gate 装好、首次 hit 也已消耗，
// 所以这里只从「开关生效 → 收起」开始，不装第二次、不重置 spec 或 hit token。
static void test_promo_row_collapse(void) {
    SEL sel = sel_registerName("heightForView");
    id wallet = [[gWalletSection alloc] init];
    id center = [[gCenterWalletSection alloc] init];

    CHECK(BDPRSpecWalletHeight.installed == YES);
    CHECK(BDPRSpecCenterWalletHeight.installed == YES);
    gEnabled = YES; gDumpOnly = NO; gRemovePersonalPromotions = YES;
    gWalletOrigResult = 80.0;        // 原实现的常态返回值（安装前也是这两个值）
    gCenterWalletOrigResult = 120.0;
    gWalletOrigCalls = 0;
    gCenterWalletOrigCalls = 0;

    // 1) 开关全开 -> 强制收起，原实现一次都不碰；这是两条 hit token 的首次真正收起，各记一行
    unsigned logsBefore = gLogLines;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == -6.0);
    CHECK(BDPRSendInstanceDouble(center, sel) == -3.0);
    CHECK(gWalletOrigCalls == 0);
    CHECK(gCenterWalletOrigCalls == 0);
    CHECK(gLogLines == logsBefore + 2);              // 每类一行；前面没有用例碰过这两个 getter
    for (int i = 0; i < 3; i++) {
        CHECK(BDPRSendInstanceDouble(wallet, sel) == -6.0);
        CHECK(BDPRSendInstanceDouble(center, sel) == -3.0);
    }
    CHECK(gLogLines == logsBefore + 2);

    // 2) 总开关关 -> 逐次透传原返回值，原实现各被调一次
    gEnabled = NO;
    gWalletOrigCalls = 0;
    gCenterWalletOrigCalls = 0;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 80.0);
    CHECK(BDPRSendInstanceDouble(center, sel) == 120.0);
    CHECK(gWalletOrigCalls == 1);
    CHECK(gCenterWalletOrigCalls == 1);
    gEnabled = YES;

    // 3) 诊断开启 -> 同样透传（诊断只 dump，不改行为）
    gDumpOnly = YES;
    gWalletOrigCalls = 0;
    gCenterWalletOrigCalls = 0;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 80.0);
    CHECK(BDPRSendInstanceDouble(center, sel) == 120.0);
    CHECK(gWalletOrigCalls == 1);
    CHECK(gCenterWalletOrigCalls == 1);
    gDumpOnly = NO;

    // 4) 独立开关关 -> 透传；顺带证明它与 banner / 其余开关互不影响
    gRemovePersonalPromotions = NO;
    gWalletOrigCalls = 0;
    gCenterWalletOrigCalls = 0;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 80.0);
    CHECK(BDPRSendInstanceDouble(center, sel) == 120.0);
    CHECK(gWalletOrigCalls == 1);
    CHECK(gCenterWalletOrigCalls == 1);
    gRemovePersonalBanner = NO;
    gRemoveRecommend = NO;
    gRemoveGameCenter = NO;
    gRemoveJobNovel = NO;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 80.0);
    CHECK(BDPRSendInstanceDouble(center, sel) == 120.0);
    gRemovePersonalBanner = YES;
    gRemoveRecommend = YES;
    gRemoveGameCenter = YES;
    gRemoveJobNovel = YES;
    gRemovePersonalPromotions = YES;

    // 5) 原值不是常量也照实透传（证明是透传而不是又拦一次）
    gWalletOrigResult = 96.5;
    gCenterWalletOrigResult = 54.25;
    gEnabled = NO;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 96.5);
    CHECK(BDPRSendInstanceDouble(center, sel) == 54.25);
    gEnabled = YES;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == -6.0);   // 开关回来照样收起
    CHECK(BDPRSendInstanceDouble(center, sel) == -3.0);
    gWalletOrigResult = 80.0;
    gCenterWalletOrigResult = 120.0;

    // 6) 幂等：orig 槽存的是原实现且不自指；重复安装不重装也不递归
    CHECK(*BDPRSpecWalletHeight.orig == (IMP)PhWalletHeight);
    CHECK(*BDPRSpecWalletHeight.orig != (IMP)BDPRWalletHeight);
    CHECK(*BDPRSpecCenterWalletHeight.orig == (IMP)PhCenterWalletHeight);
    CHECK(*BDPRSpecCenterWalletHeight.orig != (IMP)BDPRCenterWalletHeight);
    CHECK(BDFRResolve(&BDPRSpecWalletHeight) != NULL);
    CHECK(BDFRResolve(&BDPRSpecCenterWalletHeight) != NULL);
    CHECK(class_getMethodImplementation(gWalletSection, sel) == (IMP)BDPRWalletHeight);
    CHECK(class_getMethodImplementation(gCenterWalletSection, sel) == (IMP)BDPRCenterWalletHeight);
    BDPRInstallData();
    CHECK(BDPRSpecWalletHeight.installed == YES);
    CHECK(*BDPRSpecWalletHeight.orig == (IMP)PhWalletHeight);   // 没被写成替换实现
    gEnabled = NO;
    gWalletOrigCalls = 0;
    CHECK(BDPRSendInstanceDouble(wallet, sel) == 80.0);         // 透传只穿透一次原实现
    CHECK(gWalletOrigCalls == 1);
    gEnabled = YES;
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        setup_wallet_classes();      // 推广整排的两个假类（真实类名 + 真实 d16@0:8）
        test_before_install();
        test_install_and_gate();
        test_skip_paths();
        test_promo_row_collapse();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}