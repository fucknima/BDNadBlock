// tests/transfer_promo_test.mm — TransferPromoRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（TransferPromoRemoval.h）与**真实** FeatureRemoval.h 安装器，
// 只有开关、日志和替身实现是假的：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemoveTransferYikePromo / BDRemoveTransferGamePromo / BDRemoveTransferCardPromo /
//     BDRemoveTransferDataPromo / BDRemoveTransferTrialPromo（两个产品 header 都按同名静态函数引用）
//   - main 里先调一次真实 BDFRInstallAll()（本 TU 没人引用会触发 unused-function；它的目标类在这里
//     全都不存在，只会逐条 skip，不碰本测试的类，也不影响任何断言）
//   - 六个动态 fake 类（真类名 + 真 selector + 真 encoding 自有方法）：前三个是 B16@0:8 bool，
//     第四个 `BDPanFreeWidgetManage -chechFreeUnicomWidget` 是 **Q16@0:8（无符号 64 位）**，
//     第五个 `BDPanTransWidgetController -showDataPkgWigdet` 是 B16@0:8 bool，
//     第六组是 `BDNCSpeedUpTrialManager -getSpeedUpTrialWidget`（@16@0:8 对象）加
//     `BDNCSpeedUpTrialView -isInUseView / -isProductGuideView`（B16@0:8，供只读依赖校验）；
//     原返回值/原对象与调用次数都可调，分类谓词还单独记账
//
// 只证明「原实现每次恰好被调一次 / 原值与原对象不被改写也不假 hit / 开关组合决定是否抑制 /
// 三条 bool + 数值 + 数据包 bool 那条互不影响 / 幂等不自指 / 签名或类不符就 skip /
// 数值那条只在原值恰好 3 且开关都开时改判 0ULL / 试用那条只在 exact view 类 + product 真 + inUse 假
// 且门全开、主线程时返回 nil（其余一律同一原对象，且门不满足/非主线程时不查 UI 分类）/
// 依赖校验失败只跳过试用那一条」。**不是真机测试**：页面留白、widget 展示时机、异步从 inUse 变
// guide 的那些展示，都要真机看，host 测试不承诺。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/transfer_promo_test tests/transfer_promo_test.mm
//   /tmp/transfer_promo_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gRemoveTransferYikePromo = YES;
static BOOL gRemoveTransferGamePromo = YES;
static BOOL gRemoveTransferCardPromo = YES;
static BOOL gRemoveTransferDataPromo = YES;
static BOOL gRemoveTransferTrialPromo = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) { (void)fmt; gLogLines++; }
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveTransferYikePromo(void) { return gRemoveTransferYikePromo; }
static BOOL BDRemoveTransferGamePromo(void) { return gRemoveTransferGamePromo; }
static BOOL BDRemoveTransferCardPromo(void) { return gRemoveTransferCardPromo; }
static BOOL BDRemoveTransferDataPromo(void) { return gRemoveTransferDataPromo; }
static BOOL BDRemoveTransferTrialPromo(void) { return gRemoveTransferTrialPromo; }

// 顺序即真实接线顺序：先 FeatureRemoval.h（安装器），再 TransferPromoRemoval.h。
#include "../FeatureRemoval.h"
#include "../TransferPromoRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class BDTPMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

static BDFRSpec BDTPTestSpec(const char *cls, const char *sel, const char *enc, unsigned argc,
                             IMP hook, IMP *orig, const char *name) {
    BDFRSpec s;
    s.cls = cls;
    s.sel = sel;
    s.isClassMethod = NO;
    s.enc = enc;
    s.argc = argc;
    s.hook = hook;
    s.orig = orig;
    s.name = name;
    s.installed = NO;
    return s;
}

// 取当前生效的 IMP 直接调用：B 编码的返回用内建 bool，并验证安装后运行时查到的就是替换实现。
static bool BDTPSendBool(id obj, SEL sel) {
    bool (*imp)(id, SEL) = (bool (*)(id, SEL))class_getMethodImplementation([obj class], sel);
    return imp(obj, sel);
}

// 数值那条：Q 是**无符号 64 位**，必须用 unsigned long long 接（不能用 NSInteger）。
// 用 object_getClass 取真实类（与 bool 矩阵同一个口径）。
static unsigned long long BDTPSendU64(id obj, SEL sel) {
    unsigned long long (*imp)(id, SEL) =
        (unsigned long long (*)(id, SEL))class_getMethodImplementation(object_getClass(obj), sel);
    return imp(obj, sel);
}

// 对象返回那条（@16@0:8）：按 +0 约定取回对象指针，只比较身份，不改变原对象。
static id BDTPSendObject(id obj, SEL sel) {
    id (*imp)(id, SEL) =
        (id (*)(id, SEL))class_getMethodImplementation(object_getClass(obj), sel);
    return imp(obj, sel);
}

#pragma mark - 三个替身实现

static BOOL gYikeTransOrig = YES;      // 原实现的返回值，可调
static unsigned gYikeTransCalls = 0;   // 原实现被调次数
static BOOL gYikeFileListOrig = YES;
static unsigned gYikeFileListCalls = 0;
static BOOL gGameOrig = YES;
static unsigned gGameCalls = 0;

// 三条替身都记下最后一次收到的 self/_cmd，供下面的真值表矩阵核对参数保真。
static id gLastOrigReceiver;
static SEL gLastOrigSEL;

static bool PhYikeTrans(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gYikeTransCalls++; return gYikeTransOrig ? true : false;
}
static bool PhYikeFileList(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gYikeFileListCalls++; return gYikeFileListOrig ? true : false;
}
static bool PhGame(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gGameCalls++; return gGameOrig ? true : false;
}

static SEL gYikeSel;
static Class gYikeTransCls, gYikeFileListCls, gGameCls;
static id gYikeTransInst, gYikeFileListInst, gGameInst;

// 数值那条（免流办卡）：原返回值可调，并同样捕获 self/_cmd 供保真核对。
static unsigned long long gCardOrig = 0ULL;
static unsigned gCardCalls = 0;
static SEL gCardSel;
static Class gCardCls;
static id gCardInst;

static unsigned long long PhFreeUnicomCheck(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gCardCalls++; return gCardOrig;
}

// 取值那条（加速试用 getSpeedUpTrialWidget）：@16@0:8 返回对象，可用开关控制返回什么，
// 并能分别统计「分类谓词」被问了几次（用来证明门控关闭/非主线程时不查 UI 分类）。
static id gTrialWidgetOrig = nil;
static unsigned gTrialWidgetCalls = 0;
static BOOL gInUse = NO;                     // -isInUseView 的返回值（可调）
static BOOL gProduct = NO;                   // -isProductGuideView 的返回值（可调）
static unsigned gInUseCalls = 0;
static unsigned gProductCalls = 0;
static SEL gTrialWidgetSel, gInUseSel, gProductSel;
static Class gTrialMgrCls, gTrialViewCls, gTrialViewSubCls;
static id gTrialMgrInst, gTrialViewInst, gTrialViewSubInst, gPlainObject;

static id PhTrialWidget(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gTrialWidgetCalls++; return gTrialWidgetOrig;
}
static bool PhInUseView(id self, SEL _cmd) {
    (void)self; (void)_cmd; gInUseCalls++; return gInUse ? true : false;
}
static bool PhProductGuideView(id self, SEL _cmd) {
    (void)self; (void)_cmd; gProductCalls++; return gProduct ? true : false;
}

// 数据包（流量包）引导那条：原返回值可调，同样捕获 self/_cmd。
static BOOL gDataPkgOrig = YES;
static unsigned gDataPkgCalls = 0;
static SEL gDataPkgSel;
static Class gDataPkgCls;
static id gDataPkgInst;

static bool PhDataPkgShow(id self, SEL _cmd) {
    gLastOrigReceiver = self; gLastOrigSEL = _cmd;
    gDataPkgCalls++; return gDataPkgOrig ? true : false;
}

static void setup_real_classes(void) {
    gYikeSel = sel_registerName("canShowYikeBanner");
    SEL gameSel = sel_registerName("canTransIdleGameWidgetShow");
    gCardSel = sel_registerName("chechFreeUnicomWidget");
    gDataPkgSel = sel_registerName("showDataPkgWigdet");
    gTrialWidgetSel = sel_registerName("getSpeedUpTrialWidget");
    gInUseSel = sel_registerName("isInUseView");
    gProductSel = sel_registerName("isProductGuideView");

    gYikeTransCls = BDTPMakeClass("BDPanTransViewController", Nil);
    CHECK(class_addMethod(gYikeTransCls, gYikeSel, (IMP)PhYikeTrans, "B16@0:8"));
    gYikeFileListCls = BDTPMakeClass("BDPanTransferFileTransListViewController", Nil);
    CHECK(class_addMethod(gYikeFileListCls, gYikeSel, (IMP)PhYikeFileList, "B16@0:8"));
    gGameCls = BDTPMakeClass("BDPanTransIdleGameManager", Nil);
    CHECK(class_addMethod(gGameCls, gameSel, (IMP)PhGame, "B16@0:8"));
    gCardCls = BDTPMakeClass("BDPanFreeWidgetManage", Nil);
    CHECK(class_addMethod(gCardCls, gCardSel, (IMP)PhFreeUnicomCheck, "Q16@0:8"));
    gDataPkgCls = BDTPMakeClass("BDPanTransWidgetController", Nil);
    CHECK(class_addMethod(gDataPkgCls, gDataPkgSel, (IMP)PhDataPkgShow, "B16@0:8"));
    // 第六条：view 类两个 B getter + manager 的对象 getter（都按真实签名/encoding 注册）
    gTrialViewCls = BDTPMakeClass("BDNCSpeedUpTrialView", Nil);
    CHECK(class_addMethod(gTrialViewCls, gInUseSel, (IMP)PhInUseView, "B16@0:8"));
    CHECK(class_addMethod(gTrialViewCls, gProductSel, (IMP)PhProductGuideView, "B16@0:8"));
    gTrialViewSubCls = BDTPMakeClass("BDTPPhantomTrialViewSub", gTrialViewCls);   // 未知子类
    CHECK(gTrialViewSubCls != Nil);
    gTrialMgrCls = BDTPMakeClass("BDNCSpeedUpTrialManager", Nil);
    CHECK(class_addMethod(gTrialMgrCls, gTrialWidgetSel, (IMP)PhTrialWidget, "@16@0:8"));

    gYikeTransInst = [[gYikeTransCls alloc] init];
    gYikeFileListInst = [[gYikeFileListCls alloc] init];
    gGameInst = [[gGameCls alloc] init];
    gCardInst = [[gCardCls alloc] init];
    gDataPkgInst = [[gDataPkgCls alloc] init];
    gTrialMgrInst = [[gTrialMgrCls alloc] init];
    gTrialViewInst = [[gTrialViewCls alloc] init];
    gTrialViewSubInst = [[gTrialViewSubCls alloc] init];
    gPlainObject = [[NSObject alloc] init];
    gTrialWidgetOrig = gTrialViewInst;      // 默认：返回真实的 view 实例
}

static void reset_all(void) {
    gEnabled = YES;
    gDumpOnly = NO;
    gRemoveTransferYikePromo = YES;
    gRemoveTransferGamePromo = YES;
    gRemoveTransferCardPromo = YES;
    gRemoveTransferDataPromo = YES;
    gRemoveTransferTrialPromo = YES;
    gYikeTransCalls = gYikeFileListCalls = gGameCalls = 0;
    gCardCalls = 0;
    gCardOrig = 0ULL;
    gDataPkgCalls = 0;
    gDataPkgOrig = YES;
    gTrialWidgetCalls = gInUseCalls = gProductCalls = 0;
    gInUse = NO;
    gProduct = NO;
    gTrialWidgetOrig = gTrialViewInst;
}

#pragma mark - 测试

static void test_before_install(void) {
    CHECK(objc_getClass("BDPanTransViewController") == NULL);
    setup_real_classes();
    CHECK(BDTPspecYikeTrans.installed == NO);
    CHECK(BDTPspecYikeFileList.installed == NO);
    CHECK(BDTPspecIdleGame.installed == NO);
    CHECK(BDTPspecFreeUnicom.installed == NO);
    CHECK(BDTPspecDataPkg.installed == NO);                       // 第五条
    CHECK(BDTPspecTrialWidget.installed == NO);                   // 第六条
    CHECK(BDTPspecTrialInUseView.installed == NO);                // 只读依赖永不 attach
    CHECK(BDTPspecTrialProductGuideView.installed == NO);

    reset_all();
    unsigned logsBefore = gLogLines;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);       // 安装前就是原返回值
    CHECK(gYikeTransCalls == 1);
    gYikeTransOrig = NO;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    CHECK(gYikeTransCalls == 2);
    gYikeTransOrig = YES;
    CHECK(gLogLines == logsBefore);                             // 安装前不会有任何 hit

    // 数值那条也一样：安装前直接落到原实现，原值原样
    gCardOrig = 3ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 3ULL);
    CHECK(gCardCalls == 1);
    gCardOrig = 0ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 0ULL);
    CHECK(gCardCalls == 2);
    CHECK(gLogLines == logsBefore);

    // 第五/第六条：安装前同样直落原实现，原值/原对象原样
    gDataPkgOrig = NO;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);
    CHECK(gDataPkgCalls == 1);
    gDataPkgOrig = YES;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == true);
    CHECK(gDataPkgCalls == 2);
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gTrialViewInst);
    CHECK(gTrialWidgetCalls == 1);
    CHECK(gInUseCalls == 0 && gProductCalls == 0);              // 安装前没人问分类
    CHECK(gLogLines == logsBefore);
}

// 安装一共 7 条（旧 4 + 数据包 + 试用取视图 + 两条只读依赖不打 installed 行）：
// 六条 target 各自一行 installed，依赖只校验不 attach、不记 installed。
#define BDTP_INSTALLED_LINES 6

static void test_install(void) {
    unsigned logsBefore = gLogLines;
    BDTPInstallAll();
    CHECK(BDTPspecYikeTrans.installed == YES);
    CHECK(BDTPspecYikeFileList.installed == YES);
    CHECK(BDTPspecIdleGame.installed == YES);
    CHECK(BDTPspecFreeUnicom.installed == YES);
    CHECK(BDTPspecDataPkg.installed == YES);                      // 第五条
    CHECK(BDTPspecTrialWidget.installed == YES);                  // 第六条（两个依赖都过）
    CHECK(BDTPspecTrialInUseView.installed == NO);                // 依赖永不 attach
    CHECK(BDTPspecTrialProductGuideView.installed == NO);
    CHECK(*BDTPspecYikeTrans.orig == (IMP)PhYikeTrans);
    CHECK(*BDTPspecYikeFileList.orig == (IMP)PhYikeFileList);
    CHECK(*BDTPspecIdleGame.orig == (IMP)PhGame);
    CHECK(*BDTPspecFreeUnicom.orig == (IMP)PhFreeUnicomCheck);
    CHECK(*BDTPspecDataPkg.orig == (IMP)PhDataPkgShow);
    CHECK(*BDTPspecTrialWidget.orig == (IMP)PhTrialWidget);
    CHECK(*BDTPspecYikeTrans.orig != (IMP)BDTPYikeTrans);
    CHECK(*BDTPspecIdleGame.orig != (IMP)BDTPIdleGame);
    CHECK(*BDTPspecFreeUnicom.orig != (IMP)BDTPFreeUnicomCheck);       // 不自指
    CHECK(*BDTPspecDataPkg.orig != (IMP)BDTPDataPkgShow);
    CHECK(*BDTPspecTrialWidget.orig != (IMP)BDTPTrialWidget);
    CHECK(class_getMethodImplementation(gYikeTransCls, gYikeSel) == (IMP)BDTPYikeTrans);
    CHECK(class_getMethodImplementation(gCardCls, gCardSel) == (IMP)BDTPFreeUnicomCheck);
    CHECK(class_getMethodImplementation(gDataPkgCls, gDataPkgSel) == (IMP)BDTPDataPkgShow);
    CHECK(class_getMethodImplementation(gTrialMgrCls, gTrialWidgetSel) == (IMP)BDTPTrialWidget);
    // 依赖方法本身没被换掉（view 类两个 getter 仍是替身）
    CHECK(class_getMethodImplementation(gTrialViewCls, gInUseSel) == (IMP)PhInUseView);
    CHECK(class_getMethodImplementation(gTrialViewCls, gProductSel) == (IMP)PhProductGuideView);
    // 安装成功后运行期会真正用到已校验的依赖
    CHECK(BDTPTrialViewClass == gTrialViewCls);
    CHECK(BDTPTrialInUseIMP == (IMP)PhInUseView);
    CHECK(BDTPTrialProductIMP == (IMP)PhProductGuideView);
    CHECK(BDTPTrialInUseSel == gInUseSel && BDTPTrialProductSel == gProductSel);
    CHECK(gLogLines == logsBefore + BDTP_INSTALLED_LINES);       // 六条各一行 installed
}

static void test_gate_semantics(void) {
    reset_all();
    unsigned logsBefore = gLogLines;

    // 1) 原 false -> 原样 false，绝不 hit，且原实现每次仍然只被调一次
    gYikeTransOrig = NO;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    CHECK(gYikeTransCalls == 1);
    CHECK(gLogLines == logsBefore);
    gYikeTransOrig = YES;

    // 2) 原 true + 开关全开 -> false，且第一次记一行 hit
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    CHECK(gYikeTransCalls == 2);                                // 每次调用都问了原实现一次
    CHECK(gLogLines == logsBefore + 1);
    for (int i = 0; i < 3; i++) {
        CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    }
    CHECK(gYikeTransCalls == 5);                                // 每次都恰好一次
    CHECK(gLogLines == logsBefore + 1);                         // dispatch_once 不再打

    // 3) 第二条 Yike 用同一个开关，行为一致，但 hit token 是各自的
    CHECK(BDTPSendBool(gYikeFileListInst, gYikeSel) == false);
    CHECK(gYikeFileListCalls == 1);
    CHECK(gLogLines == logsBefore + 2);

    // 4) 游戏那条用另一个开关；此时互不影响
    gRemoveTransferYikePromo = NO;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);      // 独立开关关：透传原 true
    CHECK(gYikeTransCalls == 6);
    CHECK(BDTPSendBool(gGameInst, sel_registerName("canTransIdleGameWidgetShow")) == false);
    CHECK(gGameCalls == 1);
    CHECK(gLogLines == logsBefore + 3);                         // 只有游戏那条首次 hit
    gRemoveTransferYikePromo = YES;

    // 5) 游戏开关关掉时，Yike 不受影响；游戏自身透传
    gRemoveTransferGamePromo = NO;
    CHECK(BDTPSendBool(gGameInst, sel_registerName("canTransIdleGameWidgetShow")) == true);
    CHECK(gGameCalls == 2);
    CHECK(BDTPSendBool(gYikeFileListInst, gYikeSel) == false);  // Yike 仍然抑制
    CHECK(gYikeFileListCalls == 2);
    CHECK(gLogLines == logsBefore + 3);                         // 没有新 hit
    gRemoveTransferGamePromo = YES;
}

static void test_global_and_dump_passthrough(void) {
    SEL gameSel = sel_registerName("canTransIdleGameWidgetShow");

    // 总开关关 -> 三条都精确透传
    reset_all();
    gEnabled = NO;
    gYikeFileListOrig = YES;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);
    CHECK(BDTPSendBool(gYikeFileListInst, gYikeSel) == true);
    CHECK(BDTPSendBool(gGameInst, gameSel) == true);
    CHECK(gYikeTransCalls == 1);
    CHECK(gYikeFileListCalls == 1);
    CHECK(gGameCalls == 1);
    gEnabled = YES;

    // 诊断开 -> 同样透传
    gDumpOnly = YES;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);
    CHECK(BDTPSendBool(gGameInst, gameSel) == true);
    CHECK(gYikeTransCalls == 2);
    CHECK(gGameCalls == 2);
    gDumpOnly = NO;

    // 原返回值不是常量也照实透传（证明是透传而不是又拦一次）
    gGameOrig = NO;
    CHECK(BDTPSendBool(gGameInst, gameSel) == false);
    CHECK(gGameCalls == 3);
    gGameOrig = YES;
}

static void test_reinstall_no_recursion(void) {
    SEL gameSel = sel_registerName("canTransIdleGameWidgetShow");
    unsigned logsBefore = gLogLines;
    BDTPInstallAll();
    CHECK(BDTPspecYikeTrans.installed == YES);
    CHECK(*BDTPspecYikeTrans.orig == (IMP)PhYikeTrans);          // 没被写成替换实现
    CHECK(*BDTPspecYikeFileList.orig == (IMP)PhYikeFileList);
    CHECK(*BDTPspecIdleGame.orig == (IMP)PhGame);
    CHECK(*BDTPspecFreeUnicom.orig == (IMP)PhFreeUnicomCheck);
    CHECK(*BDTPspecFreeUnicom.orig != (IMP)BDTPFreeUnicomCheck);
    CHECK(*BDTPspecDataPkg.orig == (IMP)PhDataPkgShow);          // 第五条也没被自指覆盖
    CHECK(*BDTPspecTrialWidget.orig == (IMP)PhTrialWidget);      // 第六条也没被自指覆盖
    CHECK(BDTPTrialInUseIMP == (IMP)PhInUseView);                // 依赖仍是原实现，不是替换实现
    CHECK(BDTPTrialProductIMP == (IMP)PhProductGuideView);
    CHECK(BDTPTrialInUseIMP != (IMP)BDTPTrialWidget);
    CHECK(class_getMethodImplementation(gCardCls, gCardSel) == (IMP)BDTPFreeUnicomCheck);
    CHECK(class_getMethodImplementation(gDataPkgCls, gDataPkgSel) == (IMP)BDTPDataPkgShow);
    CHECK(gLogLines == logsBefore + BDTP_INSTALLED_LINES);       // 六行 already installed

    reset_all();
    unsigned hitsBefore = gLogLines;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);       // 抑制照旧
    CHECK(gYikeTransCalls == 1);                                 // 没有自指递归
    CHECK(BDTPSendBool(gGameInst, gameSel) == false);
    CHECK(gGameCalls == 1);
    gCardOrig = 3ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 0ULL);             // 数值那条也真的还能调用、还真抑制
    CHECK(gCardCalls == 1);
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);     // 第五条照旧抑制
    CHECK(gDataPkgCalls == 1);
    gProduct = YES;                                              // 第六条：只有 product 才是 null
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == nil);
    CHECK(gTrialWidgetCalls == 1);
    CHECK(gLogLines == hitsBefore);                              // hit token 已消耗，不再打
    reset_all();
}

static void test_skip_paths(void) {
    // 1) 签名不符（真注册 B24@0:8，spec 期望 B16@0:8）-> 不装
    Class wrongEnc = BDTPMakeClass("BDTPPhantomWrongEnc", Nil);
    CHECK(class_addMethod(wrongEnc, gYikeSel, (IMP)PhYikeTrans, "B24@0:8"));
    IMP origEnc = NULL;
    BDFRSpec s1 = BDTPTestSpec("BDTPPhantomWrongEnc", "canShowYikeBanner", "B16@0:8", 2,
                               (IMP)BDTPYikeTrans, &origEnc, "t-wrong-enc");
    CHECK(BDFRInstallSpec(&s1) == NO);
    CHECK(s1.installed == NO);
    CHECK(origEnc == NULL);

    // 2) 参数个数不符（真值 2，spec 期望 3）-> 不装
    IMP origArgc = NULL;
    BDFRSpec s2 = BDTPTestSpec("BDTPPhantomWrongEnc", "canShowYikeBanner", "B24@0:8", 3,
                               (IMP)BDTPYikeTrans, &origArgc, "t-wrong-argc");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO);
    CHECK(origArgc == NULL);

    // 3) 只有继承实现（方法在父类上）-> 不装；父类的 Method 槽与子类解析结果都必须还是原父类实现
    Class base = BDTPMakeClass("BDTPPhantomBase", Nil);
    CHECK(class_addMethod(base, gYikeSel, (IMP)PhYikeTrans, "B16@0:8"));
    Class sub = BDTPMakeClass("BDTPPhantomSub", base);
    CHECK(sub != Nil);
    IMP origSub = NULL;
    BDFRSpec s3 = BDTPTestSpec("BDTPPhantomSub", "canShowYikeBanner", "B16@0:8", 2,
                               (IMP)BDTPYikeTrans, &origSub, "t-inherited-only");
    CHECK(BDFRInstallSpec(&s3) == NO);
    CHECK(s3.installed == NO);
    CHECK(origSub == NULL);                                 // 没把任何 IMP 存成「原实现」
    // 拒装之后：父类槽没被换，子类解析到的仍是父类那个原实现（不是本组件的替换实现）
    CHECK(class_getMethodImplementation(base, gYikeSel) == (IMP)PhYikeTrans);
    CHECK(class_getMethodImplementation(sub, gYikeSel) == (IMP)PhYikeTrans);
    CHECK(class_getMethodImplementation(sub, gYikeSel) != (IMP)BDTPYikeTrans);
    CHECK(class_getInstanceMethod(sub, gYikeSel) == class_getInstanceMethod(base, gYikeSel));
    // 运行时也确认走的是父类原实现：返回值照旧，调用次数只 +1
    gYikeTransOrig = YES;
    unsigned subCallsBefore = gYikeTransCalls;
    CHECK(BDTPSendBool([[sub alloc] init], gYikeSel) == true);
    CHECK(gYikeTransCalls == subCallsBefore + 1);

    // 4) 类缺失 -> 不装
    IMP origMissing = NULL;
    BDFRSpec s4 = BDTPTestSpec("BDTPPhantomMissingClass", "canTransIdleGameWidgetShow", "B16@0:8", 2,
                               (IMP)BDTPIdleGame, &origMissing, "t-missing-class");
    CHECK(BDFRInstallSpec(&s4) == NO);
    CHECK(s4.installed == NO);
    CHECK(origMissing == NULL);

    // 5) 已注册的真类：只把 game 那条的 selector 写错（方法不存在）-> 不装，且不碰已装好的 spec
    IMP origSel = NULL;
    BDFRSpec s5 = BDTPTestSpec("BDPanTransIdleGameManager", "canTransIdleGameWidgetShowNOT", "B16@0:8", 2,
                               (IMP)BDTPIdleGame, &origSel, "t-missing-sel");
    CHECK(BDFRInstallSpec(&s5) == NO);
    CHECK(s5.installed == NO);
    CHECK(origSel == NULL);
    CHECK(BDTPspecIdleGame.installed == YES);                    // 已装的那条没被 reset
    CHECK(*BDTPspecIdleGame.orig == (IMP)PhGame);

    // 6) 数值那条的三条不装路径（复用同一 phantom 模式，不另抄用例）
    //    6a) 真注册 Q16@0:8，spec 期望 Q24@0:8 -> 不装
    Class cardPhantom = BDTPMakeClass("BDTPPhantomCardEnc", Nil);
    CHECK(class_addMethod(cardPhantom, gCardSel, (IMP)PhFreeUnicomCheck, "Q16@0:8"));
    IMP origCardEnc = NULL;
    BDFRSpec c1 = BDTPTestSpec("BDTPPhantomCardEnc", "chechFreeUnicomWidget", "Q24@0:8", 2,
                               (IMP)BDTPFreeUnicomCheck, &origCardEnc, "t-card-wrong-enc");
    CHECK(BDFRInstallSpec(&c1) == NO);
    CHECK(c1.installed == NO && origCardEnc == NULL);

    //    6b) 参数个数不符（真值 2，spec 期望 3）-> 不装
    IMP origCardArgc = NULL;
    BDFRSpec c2 = BDTPTestSpec("BDTPPhantomCardEnc", "chechFreeUnicomWidget", "Q16@0:8", 3,
                               (IMP)BDTPFreeUnicomCheck, &origCardArgc, "t-card-wrong-argc");
    CHECK(BDFRInstallSpec(&c2) == NO);
    CHECK(c2.installed == NO && origCardArgc == NULL);

    //    6c) 只有父类实现 -> 不装，父类槽不动
    Class cardBase = BDTPMakeClass("BDTPPhantomCardBase", Nil);
    CHECK(class_addMethod(cardBase, gCardSel, (IMP)PhFreeUnicomCheck, "Q16@0:8"));
    Class cardSub = BDTPMakeClass("BDTPPhantomCardSub", cardBase);
    IMP origCardSub = NULL;
    BDFRSpec c3 = BDTPTestSpec("BDTPPhantomCardSub", "chechFreeUnicomWidget", "Q16@0:8", 2,
                               (IMP)BDTPFreeUnicomCheck, &origCardSub, "t-card-inherited-only");
    CHECK(BDFRInstallSpec(&c3) == NO);
    CHECK(c3.installed == NO && origCardSub == NULL);
    CHECK(class_getMethodImplementation(cardSub, gCardSel) == (IMP)PhFreeUnicomCheck);
    CHECK(class_getMethodImplementation(cardSub, gCardSel) != (IMP)BDTPFreeUnicomCheck);

    // 以上失败都不许动已装好的第四条真实 spec
    CHECK(BDTPspecFreeUnicom.installed == YES);
    CHECK(*BDTPspecFreeUnicom.orig == (IMP)PhFreeUnicomCheck);
}

#pragma mark - 真值表矩阵（3 条真实 spec × 真实 instance × 开关组合）

// 一条 spec 的运行期身份：目标类、selector、真实 instance，以及它自己的开关/原返回/计数槽。
typedef struct {
    const char *label;
    Class cls;
    SEL sel;
    id inst;
    BOOL *independentSwitch;   // 该条对应的独立开关（两条 Yike 共用同一个）
    BOOL *origSlot;
    unsigned *callSlot;
} BDTPMatrixCase;

// 用 runtime 查当前 IMP 直接调用：object_getClass 取真实类（-class 可能被覆盖）；
// B 编码的返回用内建 bool。
static bool BDTPCallGate(id obj, SEL sel) {
    Class realCls = object_getClass(obj);
    bool (*imp)(id, SEL) = (bool (*)(id, SEL))class_getMethodImplementation(realCls, sel);
    return imp(obj, sel);
}

// 约定的门控真值表（这是**规格**，不是产品实现的副本）：结果 true 仅当原实现为 true
// 且门控未生效（总开关开、非诊断、该条独立开关开全部满足）；原 false 一律 false。
static bool BDTPExpectedResult(bool original, BOOL enabled, BOOL dumpOnly, BOOL independent) {
    BOOL gate = enabled && !dumpOnly && independent;
    return original && !gate;
}

static void test_gate_matrix_all_specs(void) {
    BDTPMatrixCase cases[] = {
        {"transfer-yike-trans", gYikeTransCls, gYikeSel, gYikeTransInst,
         &gRemoveTransferYikePromo, &gYikeTransOrig, &gYikeTransCalls},
        {"transfer-yike-filelist", gYikeFileListCls, gYikeSel, gYikeFileListInst,
         &gRemoveTransferYikePromo, &gYikeFileListOrig, &gYikeFileListCalls},
        {"transfer-game", gGameCls, sel_registerName("canTransIdleGameWidgetShow"), gGameInst,
         &gRemoveTransferGamePromo, &gGameOrig, &gGameCalls},
    };
    const BOOL bools[2] = {YES, NO};
    const bool origs[2] = {true, false};
    const unsigned caseCount = (unsigned)(sizeof(cases) / sizeof(cases[0]));
    unsigned checked = 0;
    unsigned logsBefore = gLogLines;             // 三条 hit token 在前面已消耗：这里一行都不该再打

    for (unsigned r = 0; r < caseCount; r++) {
        BDTPMatrixCase c = cases[r];
        CHECK(c.cls != Nil && c.sel && c.inst);
        CHECK(object_getClass(c.inst) == c.cls);  // 真实 instance 的 isa 就是 spec 目标类

        for (unsigned o = 0; o < 2; o++)
        for (unsigned e = 0; e < 2; e++)
        for (unsigned d = 0; d < 2; d++)
        for (unsigned i = 0; i < 2; i++) {
            gEnabled = bools[e];
            gDumpOnly = bools[d];
            *c.independentSwitch = bools[i];
            *c.origSlot = origs[o];

            unsigned callsBefore = *c.callSlot;
            gLastOrigReceiver = nil;
            gLastOrigSEL = NULL;
            bool expected = BDTPExpectedResult(origs[o], bools[e], bools[d], bools[i]);
            bool got = BDTPCallGate(c.inst, c.sel);
            checked++;

            if (got != expected) {
                fprintf(stderr,
                        "FAIL %s:%d: matrix %s orig=%d enabled=%d dump=%d indep=%d -> %d (want %d)\n",
                        __FILE__, __LINE__, c.label, origs[o], bools[e], bools[d], bools[i],
                        got, expected);
                gFailures++;
            }
            CHECK(*c.callSlot == callsBefore + 1);   // 原实现每次恰好被调一次（无重复、无漏调）
            CHECK(gLastOrigReceiver == c.inst);      // 收到的就是同一个真实 instance
            CHECK(gLastOrigSEL == c.sel);            // SEL 原样透传
            CHECK(gLogLines == logsBefore);          // 重复/新组合都不再打 hit
        }
    }
    CHECK(checked == caseCount * 16);

    // 收尾：三条一起连续抑制多轮，日志仍然不增长，然后恢复全开状态给后面的用例。
    gEnabled = YES;
    gDumpOnly = NO;
    gRemoveTransferYikePromo = YES;
    gRemoveTransferGamePromo = YES;
    gYikeTransOrig = gYikeFileListOrig = gGameOrig = YES;
    unsigned quiet = gLogLines;
    for (int k = 0; k < 3; k++) {
        CHECK(BDTPCallGate(gYikeTransInst, gYikeSel) == false);
        CHECK(BDTPCallGate(gYikeFileListInst, gYikeSel) == false);
        CHECK(BDTPCallGate(gGameInst, cases[2].sel) == false);
    }
    CHECK(gLogLines == quiet);
    reset_all();
}

#pragma mark - 数值闸门（免流办卡）：原值 × 三个开关 的真值表

// 规格（不是产品实现的副本）：只有原值**恰好 == 3** 且门控生效（总开关开 + 非诊断 + Card 开关开）
// 才改判 0；其它任何值（含 0/1/2/4 与高位未知值）一律原样返回。
static unsigned long long BDTPExpectedCard(unsigned long long original,
                                           BOOL enabled, BOOL dumpOnly, BOOL independent) {
    BOOL gate = enabled && !dumpOnly && independent;
    return (original == 3ULL && gate) ? 0ULL : original;
}

static void test_card_numeric_gate(void) {
    // 原值集合刻意包含：原生已知的 0/1/2/3、未知的 4/7、最高位、全 1
    const unsigned long long originals[] = {
        0ULL, 1ULL, 2ULL, 3ULL, 4ULL, 7ULL,
        0x8000000000000000ULL,     // (1ULL << 63)
        0xFFFFFFFFFFFFFFFFULL,     // ULLONG_MAX
    };
    const unsigned count = (unsigned)(sizeof(originals) / sizeof(originals[0]));
    const BOOL bools[2] = {YES, NO};
    unsigned checked = 0;
    BOOL hitSeen = NO;                    // 对应产品里的 dispatch_once hit token

    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned i = 0; i < 2; i++)
    for (unsigned k = 0; k < count; k++) {
        gEnabled = bools[e];
        gDumpOnly = bools[d];
        gRemoveTransferCardPromo = bools[i];
        gCardOrig = originals[k];
        gLastOrigReceiver = nil;
        gLastOrigSEL = NULL;
        unsigned callsBefore = gCardCalls;
        unsigned linesBefore = gLogLines;

        unsigned long long want = BDTPExpectedCard(originals[k], bools[e], bools[d], bools[i]);
        unsigned long long got = BDTPSendU64(gCardInst, gCardSel);
        checked++;

        if (got != want) {
            fprintf(stderr,
                    "FAIL %s:%d: card orig=0x%llx enabled=%d dump=%d indep=%d -> 0x%llx (want 0x%llx)\n",
                    __FILE__, __LINE__, originals[k], bools[e], bools[d], bools[i], got, want);
            gFailures++;
        }
        CHECK(gCardCalls == callsBefore + 1);        // 原实现每次恰好一次（无重复、无漏调）
        CHECK(gLastOrigReceiver == gCardInst);       // 收到的就是同一个真实 instance
        CHECK(gLastOrigSEL == gCardSel);             // SEL 原样透传

        if (!hitSeen && originals[k] == 3ULL && bools[e] && !bools[d] && bools[i]) {
            CHECK(gLogLines == linesBefore + 1);     // 首次真正抑制：恰好一行
            hitSeen = YES;
        } else {
            CHECK(gLogLines == linesBefore);         // 其它任何组合都不假记 hit
        }
    }
    CHECK(checked == 8 * count);
    CHECK(hitSeen);                                  // 矩阵里确实发生过一次真正抑制

    // 之后继续「3 + 全开」也不再打日志（dispatch_once）
    gEnabled = YES; gDumpOnly = NO; gRemoveTransferCardPromo = YES; gCardOrig = 3ULL;
    unsigned quiet = gLogLines;
    for (int k = 0; k < 3; k++) CHECK(BDTPSendU64(gCardInst, gCardSel) == 0ULL);
    CHECK(gLogLines == quiet);
    CHECK(gCardCalls == 8 * count + 3);

    // 互不影响（此时四个 hit token 都已消耗，全程不该有新日志）
    unsigned noNewLogs = gLogLines;
    reset_all();                                     // Card 打开、计数归零、原值回到 0
    CHECK(gCardOrig == 0ULL);

    gRemoveTransferCardPromo = NO;                   // ① Card 关：数值那条精确透传 3
    gCardOrig = 3ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 3ULL);
    CHECK(gCardCalls == 1);
    gYikeTransOrig = YES;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);   // Yike 不受 Card 开关影响
    CHECK(gYikeTransCalls == 1);

    gRemoveTransferCardPromo = YES;                  // ② 两条 bool 关：Card 照旧抑制
    gRemoveTransferYikePromo = NO;
    gRemoveTransferGamePromo = NO;
    gCardOrig = 3ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 0ULL);
    CHECK(gCardCalls == 2);
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);    // 自己的开关关 -> 透传
    CHECK(gYikeTransCalls == 2);
    CHECK(BDTPSendBool(gGameInst, sel_registerName("canTransIdleGameWidgetShow")) == true);
    CHECK(gGameCalls == 1);
    gRemoveTransferYikePromo = YES;
    gRemoveTransferGamePromo = YES;

    CHECK(gLogLines == noNewLogs);                   // 上面全部不产生新 hit
    reset_all();
}

#pragma mark - 第五条（数据包/流量包引导）：原真假 × 三门 的真值表

// 规格（不是产品实现的副本）：结果 true 仅当原实现为 true 且门控未生效（总开关开、非诊断、
// DataPromo 开关开全部满足）；原 false 一律 false。
static bool BDTPExpectedDataPkg(bool original, BOOL enabled, BOOL dumpOnly, BOOL independent) {
    BOOL gate = enabled && !dumpOnly && independent;
    return original && !gate ? true : false;
}

static void test_data_pkg_gate(void) {
    // 先证明「没有真正抑制之前不会假 hit」：原 false 与各关门组合一行日志都不打。
    reset_all();
    unsigned logsBefore = gLogLines;
    gDataPkgOrig = NO;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);
    CHECK(gDataPkgCalls == 1);
    CHECK(gLogLines == logsBefore);
    gDataPkgOrig = YES;
    gEnabled = NO;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == true);       // 总开关关：原 true 透传
    gEnabled = YES;
    gDumpOnly = YES;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == true);       // 诊断：透传
    gDumpOnly = NO;
    gRemoveTransferDataPromo = NO;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == true);       // 独立开关关：透传
    CHECK(gDataPkgCalls == 4);
    CHECK(gLogLines == logsBefore);                               // 以上一行 hit 都没有

    // 首次真正抑制：恰好一行；重复不再打（dispatch_once）。
    gRemoveTransferDataPromo = YES;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);
    CHECK(gLogLines == logsBefore + 1);
    for (int i = 0; i < 3; i++) CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);
    CHECK(gLogLines == logsBefore + 1);
    CHECK(gDataPkgCalls == 8);

    // 原真假 × 三门 全 16 组：结果、原实现恰好一次、receiver/SEL 保真。
    const BOOL bools[2] = {YES, NO};
    const bool origs[2] = {true, false};
    unsigned checked = 0;
    unsigned quiet = gLogLines;
    for (unsigned o = 0; o < 2; o++)
    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned i = 0; i < 2; i++) {
        gEnabled = bools[e]; gDumpOnly = bools[d]; gRemoveTransferDataPromo = bools[i];
        gDataPkgOrig = origs[o];
        gLastOrigReceiver = nil; gLastOrigSEL = NULL;
        unsigned callsBefore = gDataPkgCalls;
        bool want = BDTPExpectedDataPkg(origs[o], bools[e], bools[d], bools[i]);
        bool got = BDTPSendBool(gDataPkgInst, gDataPkgSel);
        checked++;
        if (got != want) {
            fprintf(stderr, "FAIL %s:%d: dataPkg orig=%d enabled=%d dump=%d indep=%d -> %d (want %d)\n",
                    __FILE__, __LINE__, origs[o], bools[e], bools[d], bools[i], got, want);
            gFailures++;
        }
        CHECK(gDataPkgCalls == callsBefore + 1);
        CHECK(gLastOrigReceiver == gDataPkgInst);
        CHECK(gLastOrigSEL == gDataPkgSel);
    }
    CHECK(checked == 16);
    CHECK(gLogLines == quiet);                                    // token 已消耗，不再打

    // 不影响旧四条：把旧那几条开回全开，抑制行为与日志都不变（各 token 早已消耗）。
    gEnabled = YES; gDumpOnly = NO;
    gRemoveTransferYikePromo = YES; gYikeTransOrig = YES;
    unsigned oldQuiet = gLogLines;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    CHECK(BDTPSendBool(gYikeFileListInst, gYikeSel) == false);
    CHECK(BDTPSendBool(gGameInst, sel_registerName("canTransIdleGameWidgetShow")) == false);
    gCardOrig = 3ULL;
    CHECK(BDTPSendU64(gCardInst, gCardSel) == 0ULL);
    CHECK(gLogLines == oldQuiet);
    reset_all();
}

#pragma mark - 第六条（加速试用促销）：同一原对象透传 / 只在商品引导时 nil

static void test_trial_promo_identity_then_veto(void) {
    reset_all();
    unsigned logsBefore = gLogLines;
    CHECK([NSThread isMainThread]);

    // 1) 原实现已经 nil：同一（nil）值透传，不查分类、不记 hit
    gTrialWidgetOrig = nil;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == nil);
    CHECK(gTrialWidgetCalls == 1);
    CHECK(gInUseCalls == 0 && gProductCalls == 0);
    CHECK(gLogLines == logsBefore);

    // 2) 未知类型（NSObject）：同一个对象透传，不查分类
    gTrialWidgetOrig = gPlainObject;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gPlainObject);
    CHECK(gTrialWidgetCalls == 2);
    CHECK(gInUseCalls == 0 && gProductCalls == 0);
    CHECK(gLogLines == logsBefore);

    // 3) 已核 view 的未知子类：同样原对象透传，不查分类、不越过未知 override
    gTrialWidgetOrig = gTrialViewSubInst;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gTrialViewSubInst);
    CHECK(gTrialWidgetCalls == 3);
    CHECK(gInUseCalls == 0 && gProductCalls == 0);
    CHECK(gLogLines == logsBefore);

    // 4) 正常「进行中」：先问 isInUseView 得到真 → 立即透传（不再问 product）
    gTrialWidgetOrig = gTrialViewInst;
    gInUse = YES; gProduct = NO;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gTrialViewInst);
    CHECK(gInUseCalls == 1 && gProductCalls == 0);
    CHECK(gLogLines == logsBefore);

    // 5) 未知状态（inUse 假 + product 假）：两次分类都问过，仍原对象透传
    gInUse = NO; gProduct = NO;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gTrialViewInst);
    CHECK(gInUseCalls == 2 && gProductCalls == 1);
    CHECK(gLogLines == logsBefore);

    // 6) 不一致（inUse 真 + product 真）：进行中优先 → 原对象透传，不再问 product
    gInUse = YES; gProduct = YES;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == gTrialViewInst);
    CHECK(gInUseCalls == 3 && gProductCalls == 1);
    CHECK(gLogLines == logsBefore);

    // 7) 唯一会否决的情形：product 真 + inUse 假（exact class + 门全开 + 主线程）
    gInUse = NO; gProduct = YES;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == nil);
    CHECK(gInUseCalls == 4 && gProductCalls == 2);
    CHECK(gLogLines == logsBefore + 1);                            // 首次真正抑制：恰好一行
    for (int i = 0; i < 3; i++) CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == nil);
    CHECK(gLogLines == logsBefore + 1);                            // 不再打
    CHECK(gTrialWidgetCalls == 10);                                // 每次调用都恰好问原实现一次

    // 8) 门控关闭的三种情形：纯透传、**不调用分类**、不记 hit
    const BOOL bools[2] = {YES, NO};
    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned i = 0; i < 2; i++) {
        gEnabled = bools[e]; gDumpOnly = bools[d]; gRemoveTransferTrialPromo = bools[i];
        gInUse = NO; gProduct = YES;                              // 最“该被拦”的分类结果
        gLastOrigReceiver = nil; gLastOrigSEL = NULL;
        unsigned callsBefore = gTrialWidgetCalls;
        unsigned iuBefore = gInUseCalls, prBefore = gProductCalls;
        id want = (bools[e] && !bools[d] && bools[i]) ? nil : gTrialViewInst;
        id got = BDTPSendObject(gTrialMgrInst, gTrialWidgetSel);
        CHECK(got == want);
        CHECK(gTrialWidgetCalls == callsBefore + 1);
        CHECK(gLastOrigReceiver == gTrialMgrInst);
        CHECK(gLastOrigSEL == gTrialWidgetSel);
        if (bools[e] && !bools[d] && bools[i]) {
            // 门全开：会问分类（先 inUse 后 product）→ 该组合下返回 nil
            CHECK(got == nil);
            CHECK(gInUseCalls == iuBefore + 1 && gProductCalls == prBefore + 1);
        } else {
            // 任一开关关/诊断：完全不查 UI 分类
            CHECK(gInUseCalls == iuBefore && gProductCalls == prBefore);
        }
    }
    CHECK(gLogLines == logsBefore + 1);                            // 只有第 7 步那一行

    // 9) 非主线程：纯透传、不查分类、不记 hit（开关全开、分类结果也是“该拦”的组合）
    gEnabled = YES; gDumpOnly = NO; gRemoveTransferTrialPromo = YES;
    gInUse = NO; gProduct = YES;
    unsigned beforeInUse = gInUseCalls, beforeProduct = gProductCalls, beforeCalls = gTrialWidgetCalls;
    __block id bgResult = nil;
    // libdispatch 的 sync 可在调用线程内联执行；async + group 等待才能真正覆盖非主线程路径。
    dispatch_group_t work = dispatch_group_create();
    dispatch_group_async(work, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            CHECK(![NSThread isMainThread]);
            bgResult = BDTPSendObject(gTrialMgrInst, gTrialWidgetSel);
        }
    });
    CHECK(dispatch_group_wait(work, DISPATCH_TIME_FOREVER) == 0);
    CHECK(bgResult == gTrialViewInst);                             // 原对象透传
    CHECK(gTrialWidgetCalls == beforeCalls + 1);
    CHECK(gInUseCalls == beforeInUse && gProductCalls == beforeProduct);
    CHECK(gLogLines == logsBefore + 1);

    reset_all();
}

#pragma mark - 第六条：依赖校验失败只跳它自己（C2 与旧四条照装）

static void test_dep_fail_closed_c3_skips_c2_only(void) {
    // 真依赖已通过（test_install 里装好）；下面全部用独立 phantom，不改已注册类的 encoding。
    CHECK(BDTPspecTrialWidget.installed == YES);
    CHECK(BDTPspecDataPkg.installed == YES);
    CHECK(BDTPspecTrialInUseView.installed == NO);
    CHECK(BDTPspecTrialProductGuideView.installed == NO);

    const char *mgrs[] = {"BDTPPhantomTrialMgrEnc", "BDTPPhantomTrialMgrArgc",
                          "BDTPPhantomTrialMgrMissingDep", "BDTPPhantomTrialMgrInheritedDep"};
    Class mgr[4];
    SEL tw = sel_registerName("getSpeedUpTrialWidget");
    for (int i = 0; i < 4; i++) {
        mgr[i] = BDTPMakeClass(mgrs[i], Nil);
        CHECK(class_addMethod(mgr[i], tw, (IMP)PhTrialWidget, "@16@0:8"));
    }

    // 1) 依赖 encoding 不符（真注册 B16@0:8，spec 期望 B24@0:8）
    Class badEnc = BDTPMakeClass("BDTPPhantomTrialViewEnc", Nil);
    CHECK(class_addMethod(badEnc, gInUseSel, (IMP)PhInUseView, "B16@0:8"));
    CHECK(class_addMethod(badEnc, gProductSel, (IMP)PhProductGuideView, "B16@0:8"));
    // 2) 依赖 argc 不符（真值 2，spec 期望 3）
    Class badArgc = BDTPMakeClass("BDTPPhantomTrialViewArgc", Nil);
    CHECK(class_addMethod(badArgc, gInUseSel, (IMP)PhInUseView, "B16@0:8"));
    CHECK(class_addMethod(badArgc, gProductSel, (IMP)PhProductGuideView, "B16@0:8"));
    // 3) 依赖只在父类（子类没有自有实现）
    Class base = BDTPMakeClass("BDTPPhantomTrialViewBase", Nil);
    CHECK(class_addMethod(base, gInUseSel, (IMP)PhInUseView, "B16@0:8"));
    CHECK(class_addMethod(base, gProductSel, (IMP)PhProductGuideView, "B16@0:8"));
    Class sub = BDTPMakeClass("BDTPPhantomTrialViewSubOnly", base);
    CHECK(sub != Nil);

    struct { const char *view; const char *vEnc; unsigned vArgc;
             const char *mgr; const char *tEnc; unsigned tArgc; const char *name; } cases[] = {
        {"BDTPPhantomTrialViewEnc", "B24@0:8", 2, "BDTPPhantomTrialMgrEnc", "@16@0:8", 2, "dep-enc"},
        {"BDTPPhantomTrialViewArgc", "B16@0:8", 3, "BDTPPhantomTrialMgrArgc", "@16@0:8", 2, "dep-argc"},
        {"BDTPPhantomTrialViewMissing", "B16@0:8", 2, "BDTPPhantomTrialMgrMissingDep", "@16@0:8", 2, "dep-missing-class"},
        {"BDTPPhantomTrialViewSubOnly", "B16@0:8", 2, "BDTPPhantomTrialMgrInheritedDep", "@16@0:8", 2, "dep-inherited-only"},
    };
    unsigned logsBefore = gLogLines;
    for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        IMP o = NULL;
        BDFRSpec d1 = BDTPTestSpec(cases[k].view, "isInUseView", cases[k].vEnc, cases[k].vArgc, NULL, NULL, cases[k].name);
        BDFRSpec d2 = BDTPTestSpec(cases[k].view, "isProductGuideView", cases[k].vEnc, cases[k].vArgc, NULL, NULL, cases[k].name);
        BDFRSpec t = BDTPTestSpec(cases[k].mgr, "getSpeedUpTrialWidget", cases[k].tEnc, cases[k].tArgc,
                                  (IMP)BDTPTrialWidget, &o, cases[k].name);
        Class vc = Nil; IMP pi = NULL, pp = NULL; SEL ps = NULL, pps = NULL;
        CHECK(BDTPInstallTrialWith(&d1, &d2, &t, &vc, &pi, &ps, &pp, &pps) == NO);
        CHECK(t.installed == NO);
        CHECK(o == NULL);                       // 目标原 IMP 槽没被写
        CHECK(vc == Nil && pi == NULL && ps == NULL && pp == NULL && pps == NULL);  // 依赖全局也没被写
        // 每个失败用例恰好三行：两个依赖各一行 resolve skip + 安装器一行 skip
        CHECK(gLogLines == logsBefore + 3 * (k + 1));
        // 目标方法槽没被换：调用仍落到替身
        Class mc = objc_getClass(cases[k].mgr);
        CHECK(class_getMethodImplementation(mc, tw) == (IMP)PhTrialWidget);
    }
    // 父类依赖那条也确认：父类/子类槽都没被换
    CHECK(class_getMethodImplementation(sub, gInUseSel) == (IMP)PhInUseView);
    CHECK(class_getMethodImplementation(base, gProductSel) == (IMP)PhProductGuideView);

    // 真依赖与已装好的其它条不受影响
    CHECK(BDTPTrialViewClass == gTrialViewCls);
    CHECK(BDTPTrialInUseIMP == (IMP)PhInUseView);
    CHECK(BDTPspecTrialWidget.installed == YES);
    CHECK(BDTPspecDataPkg.installed == YES);
    CHECK(BDTPspecFreeUnicom.installed == YES);
    CHECK(*BDTPspecTrialWidget.orig == (IMP)PhTrialWidget);
    CHECK(*BDTPspecDataPkg.orig == (IMP)PhDataPkgShow);

    // 行为回归：C2 照旧抑制，C3 也只有 product 那条才 nil
    reset_all();
    unsigned quiet = gLogLines;
    CHECK(BDTPSendBool(gDataPkgInst, gDataPkgSel) == false);
    gInUse = NO; gProduct = YES;
    CHECK(BDTPSendObject(gTrialMgrInst, gTrialWidgetSel) == nil);
    CHECK(gLogLines == quiet);                  // 两个 token 早已消耗
    reset_all();
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        // 真实 FeatureRemoval.h 里的 BDFRInstallAll 在本 TU 没人调用会触发 unused-function。
        // 这里先调一次当机制 fixture：它的目标类（BHSettings / BDPanNewMSHContentViewController /
        // BDPanPersonalConfig / BDPanFeedHomeConfig / BDPanFHKingKongsModel）在本 TU 都不存在，
        // 只会逐条 skip，不碰传输那三个类，也不影响后面每个用例自己的 logsBefore。
        BDFRInstallAll();

        test_before_install();
        test_install();
        test_gate_semantics();
        test_gate_matrix_all_specs();      // 首次 hit 断言之后跑：token 已消耗，只验真值表与保真
        test_card_numeric_gate();          // 数值那条有自己的 hit token；上面那条 bool 矩阵不碰它
        test_data_pkg_gate();              // 第五条：原真假 × 三门 16 组（自己消耗 data-promo token）
        test_trial_promo_identity_then_veto();  // 第六条：透传/否决矩阵 + 分类调用记账（消耗 trial token）
        test_dep_fail_closed_c3_skips_c2_only(); // 第六条依赖不过只跳它自己，C2 与旧四条不受影响
        test_global_and_dump_passthrough();
        test_reinstall_no_recursion();
        test_skip_paths();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}
