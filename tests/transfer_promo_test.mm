// tests/transfer_promo_test.mm — TransferPromoRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（TransferPromoRemoval.h）与**真实** FeatureRemoval.h 安装器，
// 只有开关、日志和替身实现是假的：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemoveTransferYikePromo / BDRemoveTransferGamePromo（两个产品 header 都按同名静态函数引用）
//   - main 里先调一次真实 BDFRInstallAll()（本 TU 没人引用会触发 unused-function；它的目标类在这里
//     全都不存在，只会逐条 skip，不碰本测试的三个类，也不影响任何断言）
//   - 三个动态 fake 类（真类名 + 真 selector + 真 B16@0:8 自有方法），原返回值与调用次数可调
//
// 只证明「原实现每次恰好被调一次 / 原 false 不被改写也不 hit / 开关组合决定是否抑制 /
// 两条 Yike 与游戏互不影响 / 幂等不自指 / 签名或类不符就 skip」。**不是真机测试**：
// 传输页那行到底会不会留空行、游戏引导的展示时机，都要真机看，host 测试不承诺。
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
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) { (void)fmt; gLogLines++; }
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveTransferYikePromo(void) { return gRemoveTransferYikePromo; }
static BOOL BDRemoveTransferGamePromo(void) { return gRemoveTransferGamePromo; }

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

static void setup_real_classes(void) {
    gYikeSel = sel_registerName("canShowYikeBanner");
    SEL gameSel = sel_registerName("canTransIdleGameWidgetShow");

    gYikeTransCls = BDTPMakeClass("BDPanTransViewController", Nil);
    CHECK(class_addMethod(gYikeTransCls, gYikeSel, (IMP)PhYikeTrans, "B16@0:8"));
    gYikeFileListCls = BDTPMakeClass("BDPanTransferFileTransListViewController", Nil);
    CHECK(class_addMethod(gYikeFileListCls, gYikeSel, (IMP)PhYikeFileList, "B16@0:8"));
    gGameCls = BDTPMakeClass("BDPanTransIdleGameManager", Nil);
    CHECK(class_addMethod(gGameCls, gameSel, (IMP)PhGame, "B16@0:8"));

    gYikeTransInst = [[gYikeTransCls alloc] init];
    gYikeFileListInst = [[gYikeFileListCls alloc] init];
    gGameInst = [[gGameCls alloc] init];
}

static void reset_all(void) {
    gEnabled = YES;
    gDumpOnly = NO;
    gRemoveTransferYikePromo = YES;
    gRemoveTransferGamePromo = YES;
    gYikeTransCalls = gYikeFileListCalls = gGameCalls = 0;
}

#pragma mark - 测试

static void test_before_install(void) {
    CHECK(objc_getClass("BDPanTransViewController") == NULL);
    setup_real_classes();
    CHECK(BDTPspecYikeTrans.installed == NO);
    CHECK(BDTPspecYikeFileList.installed == NO);
    CHECK(BDTPspecIdleGame.installed == NO);

    reset_all();
    unsigned logsBefore = gLogLines;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == true);       // 安装前就是原返回值
    CHECK(gYikeTransCalls == 1);
    gYikeTransOrig = NO;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);
    CHECK(gYikeTransCalls == 2);
    gYikeTransOrig = YES;
    CHECK(gLogLines == logsBefore);                             // 安装前不会有任何 hit
}

static void test_install(void) {
    unsigned logsBefore = gLogLines;
    BDTPInstallAll();
    CHECK(BDTPspecYikeTrans.installed == YES);
    CHECK(BDTPspecYikeFileList.installed == YES);
    CHECK(BDTPspecIdleGame.installed == YES);
    CHECK(*BDTPspecYikeTrans.orig == (IMP)PhYikeTrans);
    CHECK(*BDTPspecYikeFileList.orig == (IMP)PhYikeFileList);
    CHECK(*BDTPspecIdleGame.orig == (IMP)PhGame);
    CHECK(*BDTPspecYikeTrans.orig != (IMP)BDTPYikeTrans);
    CHECK(*BDTPspecIdleGame.orig != (IMP)BDTPIdleGame);
    CHECK(class_getMethodImplementation(gYikeTransCls, gYikeSel) == (IMP)BDTPYikeTrans);
    CHECK(gLogLines == logsBefore + 3);                         // 三条各一行 installed
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
    CHECK(gLogLines == logsBefore + 3);                          // 三行 already installed

    reset_all();
    unsigned hitsBefore = gLogLines;
    CHECK(BDTPSendBool(gYikeTransInst, gYikeSel) == false);       // 抑制照旧
    CHECK(gYikeTransCalls == 1);                                 // 没有自指递归
    CHECK(BDTPSendBool(gGameInst, gameSel) == false);
    CHECK(gGameCalls == 1);
    CHECK(gLogLines == hitsBefore);                              // hit token 已消耗，不再打
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
    return original && !gate ? true : false;
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
        test_global_and_dump_passthrough();
        test_reinstall_no_recursion();
        test_skip_paths();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}