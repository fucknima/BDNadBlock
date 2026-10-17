// BDNadBlock — 「我的」任务系统卡（pointsCard）与容量管理卡（spaceCard）隐藏 + 行高折叠
//
// **前置契约（调用方必须先做，缺一编译不过）**：
//   1) #import <UIKit/UIKit.h>（本文件只用 UIView 的 hidden，不 import 它，由调用方先引入；
//      Tweak.xm 与 tests/ui_compile.mm 本来就 import 了 UIKit）
//   2) #include 本文件之前先 include FeatureRemoval.h（要复用它的 BDFRSpec / BDFRResolve /
//      BDFRCanAttach / BDFRAttach / BDFRSuppressed 与开关读取，不另抄安装器、不另建默认值表）
//   3) 提供 BDNadPrefsActive / BDEnabled / BDDumpOnly / BDRemoveTaskCard /
//      BDRemovePersonalSpaceCard（由 Tweak.xm 提供；和 BDRemovePersonalBanner /
//      BDRemovePersonalPromotions 同一约定，本文件不定义）
// 顺序与 PersonalRemoval.h 完全一致：FeatureRemoval.h -> 本文件。
//
// 语义（与调用方议定，改这里等于改行为）：
//   - 目标：两个 section 各自的 -layoutViews（v16@0:8、argc 2），以及**条件安装**的
//     -heightForView（d16@0:8、argc 2）。两个 class 各自独立校验、独立 skip，互不依赖。
//   - 依赖（只读校验、永不 attach）：每个 class **自己的** -pointsCard 与 -spaceCard（均 @16@0:8）。
//     pointsCard 用来隐藏任务卡（BDRemoveTaskCard），spaceCard 用来隐藏容量卡
//     （BDRemovePersonalSpaceCard）。两条依赖互相独立：任一条缺失/签名不符，只关掉它那一条。
//   - 做法：先调原 layoutViews（它自己会在 iPhone 分支把 pointsCard setHidden:NO），
//     再在开关生效且在主线程时，把对应 getter 返回的、确实是 UIView 的对象 setHidden:YES。
//     不依赖 didAppear，原实现之后每次重排都会被我们重新覆盖。spaceCard 原生 layoutViews 不碰，
//     本轮所查原生布局不重置它的 hidden；其它异步路径未穷尽。
//   - 行高：只有「该 style 的 layout 已装 + 两个 getter 依赖都通过 + 任务与容量两个开关都生效 +
//     主线程」时才把 heightForView 的返回值从**恰好 80.0 / 84.0**（该 style 自己的常量）改成 0.0。
//     宿主 -[BDPanPersonalViewController tableView:heightForRowAtIndexPath:] 会再 +6.0，
//     预期只剩6pt段间距，不留整卡高度的大空白。0.0 是本组件选择的非负高度，
//     不是这个 class 原生的收起分支；未知负值 / NaN / 其它高度一律精确透传，原实现每次先且只调一次。
//   - 只藏一张卡（或门控未生效 / 非主线程 / 依赖不足）时行高原值透传 —— 不把仍可见的兄弟卡压没。
//   - 不改约束、不改 frame、不改宽度、不动父布局；容量卡原来占的位置允许留空（与任务卡一致）。
//     正常 SVIP 权益 header、容量/配额/购买/账号数据一概不碰；不写缓存、不写 App 原生配置。
//   - 不做：不调 al_isiPad、不全局 hook setHidden:、不装定时器/重试、不动 getter 背后的网络/数据。
//   - **未验证**：真机上 6pt 段间距的实际观感；只藏一张时的留白宽度；以及异步刷新路径是否还会
//     再次把卡显示出来（本组件在每次 layout 后覆盖，但这不等于所有异步路径都已遍历）。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_PERSONAL_VIEW_REMOVAL_H
#define BDNAD_PERSONAL_VIEW_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 原 IMP / 依赖 / hit

// v16@0:8、id 返回（@16@0:8）、double 返回（d16@0:8）各用一个函数指针类型，与手写 encoding 逐字对齐。
typedef void (*BDPVVoidIMP)(id, SEL);
typedef id (*BDPVObjectIMP)(id, SEL);
typedef double (*BDPVHeightIMP)(id, SEL);

// 两个 class 各自一份：原 layoutViews / heightForView IMP、两个依赖 getter 的 IMP 与 selector、
// 各自的 hit token（任务卡、容量卡、行高折叠分别独立）。
static IMP BDPVOrigLayoutAndPoint;          // -[BDPanPersonalSpaceAndPointSection layoutViews]
static IMP BDPVOrigLayoutSpace;             // -[BDPanPersonalSpaceSection layoutViews]
static IMP BDPVPointsCardImpAndPoint;       // -[BDPanPersonalSpaceAndPointSection pointsCard]
static IMP BDPVPointsCardImpSpace;          // -[BDPanPersonalSpaceSection pointsCard]
static IMP BDPVSpaceCardImpAndPoint;        // 同名 spaceCard（容量卡）
static IMP BDPVSpaceCardImpSpace;
static SEL BDPVPointsCardSelAndPoint;
static SEL BDPVPointsCardSelSpace;
static SEL BDPVSpaceCardSelAndPoint;
static SEL BDPVSpaceCardSelSpace;
static IMP BDPVOrigHeightAndPoint;          // -[BDPanPersonalSpaceAndPointSection heightForView]
static IMP BDPVOrigHeightSpace;
static BOOL BDPVHeightReadyAndPoint;        // 该 style 的行高 gate 是否装上（安装期判定）
static BOOL BDPVHeightReadySpace;
static dispatch_once_t BDPVHitAndPoint;
static dispatch_once_t BDPVHitSpace;
static dispatch_once_t BDPVSpaceHitAndPoint;
static dispatch_once_t BDPVSpaceHitSpace;
static dispatch_once_t BDPVRowHitAndPoint;
static dispatch_once_t BDPVRowHitSpace;

#pragma mark - 隐藏动作

// 只在「开关生效 + 主线程 + 拿到合法 UIView + 它当前可见」时才动手，并且只记一次 hit。
// 非主线程直接返回：那不是本组件该改的状态，也不借 BDFRSuppressed 借道输出 hit。
// cardImp/cardSel 为 NULL（该依赖校验没过）时什么都不做 —— 单条依赖失败不影响另一条。
static void BDPVHideCard(id host, IMP cardImp, SEL cardSel,
                         dispatch_once_t *hit, const char *name) {
    if (!cardImp || !cardSel) return;                 // 依赖没装成功时不该走到这里
    id card = ((BDPVObjectIMP)cardImp)(host, cardSel);   // 只问这个 class 自己的 getter
    if (![card isKindOfClass:[UIView class]]) return; // nil / 非视图 / 别的对象：一律不动
    UIView *view = (UIView *)card;
    if (view.hidden) return;                          // 已经是隐藏的：不重复写、不重复 hit
    view.hidden = YES;
    BDFRSuppressed(hit, name, YES);
}

static bool BDPVTaskGate(void) {
    return BDEnabled() && !BDDumpOnly() && BDRemoveTaskCard();
}

static bool BDPVSpaceGate(void) {
    return BDEnabled() && !BDDumpOnly() && BDRemovePersonalSpaceCard();
}

// 两个 style 同一个形状：先原 layoutViews，再按各自开关隐藏各自的卡。
// 任务卡与容量卡互不依赖：任一 getter 依赖没装上，只影响它那一条。
static void BDPVLayoutAndPoint(id self, SEL _cmd) {
    ((BDPVVoidIMP)BDPVOrigLayoutAndPoint)(self, _cmd);   // 先原实现
    if (![NSThread isMainThread]) return;
    if (BDPVTaskGate())
        BDPVHideCard(self, BDPVPointsCardImpAndPoint, BDPVPointsCardSelAndPoint,
                     &BDPVHitAndPoint, "personal-task-card");
    if (BDPVSpaceGate())
        BDPVHideCard(self, BDPVSpaceCardImpAndPoint, BDPVSpaceCardSelAndPoint,
                     &BDPVSpaceHitAndPoint, "personal-space-card");
}

static void BDPVLayoutSpace(id self, SEL _cmd) {
    ((BDPVVoidIMP)BDPVOrigLayoutSpace)(self, _cmd);      // 先原实现
    if (![NSThread isMainThread]) return;
    if (BDPVTaskGate())
        BDPVHideCard(self, BDPVPointsCardImpSpace, BDPVPointsCardSelSpace,
                     &BDPVHitSpace, "personal-task-card");
    if (BDPVSpaceGate())
        BDPVHideCard(self, BDPVSpaceCardImpSpace, BDPVSpaceCardSelSpace,
                     &BDPVSpaceHitSpace, "personal-space-card");
}

#pragma mark - 行高 gate（两卡都收起时给 0.0，宿主 +6 => 正常段间距）

// 保守方案：两张卡都由本组件隐藏时返回 0.0（不是 -6），宿主 pending +6 后得到正常 6pt 段间距，
// 不留整卡高度的大空白。0.0 不是这个 class 原生的收起分支，实际布局仍须真机验证。
// 只在安装期就确认「layout 已装 + 两个 getter 依赖都可用」的 style 上生效（BDPVHeightReady*），
// 避免在某个开关关闭或依赖不符时压掉兄弟卡；只改已知原值 80.0 / 84.0，
// 未知负值 / NaN / 将来别的高度一律精确透传。
static double BDPVHeightAndPoint(id self, SEL _cmd) {
    double original = ((BDPVHeightIMP)BDPVOrigHeightAndPoint)(self, _cmd);   // 先且只一次
    if (!BDPVHeightReadyAndPoint) return original;
    if (!(BDPVTaskGate() && BDPVSpaceGate()) || ![NSThread isMainThread]) return original;
    if (original == 0.0) return original;          // 本来就没有行高：不假记 hit
    if (original != 80.0) return original;         // 只认这个 style 自己的常量
    BDFRSuppressed(&BDPVRowHitAndPoint, "personal-space-row", YES);
    return 0.0;
}

static double BDPVHeightSpace(id self, SEL _cmd) {
    double original = ((BDPVHeightIMP)BDPVOrigHeightSpace)(self, _cmd);
    if (!BDPVHeightReadySpace) return original;
    if (!(BDPVTaskGate() && BDPVSpaceGate()) || ![NSThread isMainThread]) return original;
    if (original == 0.0) return original;
    if (original != 84.0) return original;         // legacy 样式的常量
    BDFRSuppressed(&BDPVRowHitSpace, "personal-space-row", YES);
    return 0.0;
}

#pragma mark - spec 表

static BDFRSpec BDPVSpecLayoutAndPoint = {
    "BDPanPersonalSpaceAndPointSection", "layoutViews", NO, "v16@0:8", 2,
    (IMP)BDPVLayoutAndPoint, &BDPVOrigLayoutAndPoint, "personal-task-card", NO,
};
static BDFRSpec BDPVSpecLayoutSpace = {
    "BDPanPersonalSpaceSection", "layoutViews", NO, "v16@0:8", 2,
    (IMP)BDPVLayoutSpace, &BDPVOrigLayoutSpace, "personal-task-card", NO,
};
static BDFRSpec BDPVSpecHeightAndPoint = {
    "BDPanPersonalSpaceAndPointSection", "heightForView", NO, "d16@0:8", 2,
    (IMP)BDPVHeightAndPoint, &BDPVOrigHeightAndPoint, "personal-space-row", NO,
};
static BDFRSpec BDPVSpecHeightSpace = {
    "BDPanPersonalSpaceSection", "heightForView", NO, "d16@0:8", 2,
    (IMP)BDPVHeightSpace, &BDPVOrigHeightSpace, "personal-space-row", NO,
};
// 依赖：只走 BDFRResolve 校验（类 + 自有方法 + 完整 encoding + argc），永不 attach。
static BDFRSpec BDPVSpecPointsCardAndPoint = {
    "BDPanPersonalSpaceAndPointSection", "pointsCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-task-card-getter", NO,
};
static BDFRSpec BDPVSpecPointsCardSpace = {
    "BDPanPersonalSpaceSection", "pointsCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-task-card-getter", NO,
};
static BDFRSpec BDPVSpecSpaceCardAndPoint = {
    "BDPanPersonalSpaceAndPointSection", "spaceCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-space-card-getter", NO,
};
static BDFRSpec BDPVSpecSpaceCardSpace = {
    "BDPanPersonalSpaceSection", "spaceCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-space-card-getter", NO,
};

// 每个 style 一次预检安装（非原子事务）：先装 layoutViews，再条件安装 heightForView。
// 依赖 pointsCard / spaceCard 各自独立：任一条缺失只关掉它对应的 hide，不影响另一条；
// 两个依赖都不可用就整条跳过（装了也没有可隐藏的对象）。
// height gate 只在 目标通过 + layout 成功 attach + **两个依赖都可用** 时才装，
// 是否折叠仍由两个运行期开关决定，不以签名匹配代替真实可见性验证。
static BOOL BDPVInstallSectionWith(BDFRSpec *depPoints, BDFRSpec *depSpace,
                                   BDFRSpec *layoutTarget, BDFRSpec *heightTarget,
                                   IMP *pointsImp, SEL *pointsSel,
                                   IMP *spaceImp, SEL *spaceSel,
                                   BOOL *heightReady) {
    *heightReady = NO;   // 除非下面真的 attach 了 height，否则一律不算就绪
    Method mPoints = BDFRResolve(depPoints);
    Method mSpace = BDFRResolve(depSpace);
    Method mLayout = BDFRResolve(layoutTarget);
    if (!mLayout || !BDFRCanAttach(layoutTarget, mLayout)) {
        BDLog(@"[BDNadFeature] skip %s: layoutViews 目标校验不过，什么都不装", layoutTarget->name);
        return NO;
    }
    if (!mPoints && !mSpace) {
        BDLog(@"[BDNadFeature] skip %s: pointsCard / spaceCard 两个依赖都不可用",
              layoutTarget->name);
        return NO;
    }
    // 校验全过之后才写依赖全局，避免留下半套状态
    if (mPoints) { *pointsImp = method_getImplementation(mPoints); *pointsSel = sel_registerName(depPoints->sel); }
    if (mSpace) { *spaceImp = method_getImplementation(mSpace); *spaceSel = sel_registerName(depSpace->sel); }
    if (!BDFRAttach(layoutTarget, mLayout)) return NO;

    if (mPoints && mSpace) {
        Method mHeight = BDFRResolve(heightTarget);
        if (mHeight && BDFRCanAttach(heightTarget, mHeight)) {
            *heightReady = BDFRAttach(heightTarget, mHeight);
        } else {
            BDLog(@"[BDNadFeature] skip %s: heightForView 校验不过，行高保持原值",
                  heightTarget->name);
        }
    }
    return YES;
}

// 接线入口：Tweak.xm 在 FeatureRemoval.h 之后 include 本文件，并在构造器里调一次。
static void BDPVInstallAll(void) {
    BDPVInstallSectionWith(&BDPVSpecPointsCardAndPoint, &BDPVSpecSpaceCardAndPoint,
                           &BDPVSpecLayoutAndPoint, &BDPVSpecHeightAndPoint,
                           &BDPVPointsCardImpAndPoint, &BDPVPointsCardSelAndPoint,
                           &BDPVSpaceCardImpAndPoint, &BDPVSpaceCardSelAndPoint,
                           &BDPVHeightReadyAndPoint);
    BDPVInstallSectionWith(&BDPVSpecPointsCardSpace, &BDPVSpecSpaceCardSpace,
                           &BDPVSpecLayoutSpace, &BDPVSpecHeightSpace,
                           &BDPVPointsCardImpSpace, &BDPVPointsCardSelSpace,
                           &BDPVSpaceCardImpSpace, &BDPVSpaceCardSelSpace,
                           &BDPVHeightReadySpace);
}

#endif
