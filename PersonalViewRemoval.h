// BDNadBlock — 「我的」任务系统 / 金币卡（pointsCard）隐藏
//
// **前置契约（调用方必须先做，缺一编译不过）**：
//   1) #import <UIKit/UIKit.h>（本文件只用 UIView 的 hidden，不 import 它，由调用方先引入；
//      Tweak.xm 与 tests/ui_compile.mm 本来就 import 了 UIKit）
//   2) #include 本文件之前先 include FeatureRemoval.h（要复用它的 BDFRSpec / BDFRResolve /
//      BDFRCanAttach / BDFRAttach / BDFRSuppressed 与开关读取，不另抄安装器、不另建默认值表）
//   3) 提供 BDNadPrefsActive / BDEnabled / BDDumpOnly / BDRemoveTaskCard（由 Tweak.xm 提供；
//      和 BDRemovePersonalBanner / BDRemovePersonalPromotions 同一约定，本文件不定义）
// 顺序与 PersonalRemoval.h 完全一致：FeatureRemoval.h -> 本文件。
//
// 语义（与调用方议定，改这里等于改行为）：
//   - 目标只有两个：-[BDPanPersonalSpaceAndPointSection layoutViews] 与
//     -[BDPanPersonalSpaceSection layoutViews]（都是 v16@0:8、argc 2），各返回 void。
//     两个 class 各自独立校验、独立 skip，**不互相依赖、不共用原 IMP 槽**。
//   - 这两个 section 是同一件事的两套样式（isAdvanceProfilePageStyle 决定走哪套），
//     每套里 容量卡 spaceCard 与 任务卡 pointsCard 是兄弟视图；
//     任务卡 pointsCard 是该 section **自己的 getter**（@16@0:8，argc 2），只读校验、绝不 attach。
//   - 做法：先调原 layoutViews（它自己会在 iPhone 分支把 pointsCard setHidden:NO），
//     再在开关生效且在主线程时，把**这个 class 自己的 getter** 返回的、确实是 UIView 的对象
//     setHidden:YES。所以不依赖 didAppear，首帧不等它，原实现之后每次重排都会被覆盖回来。
//   - 保留原行为：容量卡 spaceCard 一点没碰，section 行高（80.0 / 96.0 两个常量）也没碰；
//     任务卡原来占的位置**允许留空**（这与 App 自己在 iPad 上的处理一致：那里也是把任务卡
//     宽度置 0，容量卡保持原宽）。不声称容量卡会撑满，不改约束、不改 frame、不改宽度。
//   - 不做：不调 al_isiPad、不全局 hook setHidden:、不装定时器/重试、不动 pointsCard 的 fetchPointsData、
//     不碰 BDPanPersonalCoinCenterCardView 之类卡片自身的实现。
//   - **未验证**：真机上隐藏后该 section 的 80.0 / 96.0 行高仍会留同样高度的空白；
//     以及异步刷新路径不会再把任务卡 setHidden:NO —— 后者用 xrefdb 核过：setHidden: 的
//     调用点在这两个 class 内只有 layoutViews（各 2 处），卡片自身 class 里的那些是它内部子视图。
//   - 不承诺零网络请求：任务卡数据照旧请求，只是这个视图不显示。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_PERSONAL_VIEW_REMOVAL_H
#define BDNAD_PERSONAL_VIEW_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 原 IMP / 依赖 / hit

// v16@0:8 与 id 返回（@16@0:8）分别用这两个函数指针类型，与手写 encoding 逐字对齐。
typedef void (*BDPVVoidIMP)(id, SEL);
typedef id (*BDPVObjectIMP)(id, SEL);

// 两个 class 各自一份：原 layoutViews IMP、依赖 getter 的 IMP 与 selector、hit token。
static IMP BDPVOrigLayoutAndPoint;          // -[BDPanPersonalSpaceAndPointSection layoutViews]
static IMP BDPVOrigLayoutSpace;             // -[BDPanPersonalSpaceSection layoutViews]
static IMP BDPVPointsCardImpAndPoint;       // -[BDPanPersonalSpaceAndPointSection pointsCard]
static IMP BDPVPointsCardImpSpace;          // -[BDPanPersonalSpaceSection pointsCard]
static SEL BDPVPointsCardSelAndPoint;
static SEL BDPVPointsCardSelSpace;
static dispatch_once_t BDPVHitAndPoint;
static dispatch_once_t BDPVHitSpace;

#pragma mark - 隐藏动作

// 只在「开关生效 + 主线程 + 拿到合法 UIView + 它当前可见」时才动手，并且只记一次 hit。
// 非主线程直接返回：那不是本组件该改的状态，也不借 BDFRSuppressed 借道输出 hit。
static void BDPVHidePointsCard(id host, IMP cardImp, SEL cardSel,
                               dispatch_once_t *hit, const char *name) {
    if (!cardImp || !cardSel) return;                 // 依赖没装成功时不该走到这里
    id card = ((BDPVObjectIMP)cardImp)(host, cardSel);   // 只问这个 class 自己的 getter
    if (![card isKindOfClass:[UIView class]]) return; // nil / 非视图 / 别的对象：一律不动
    UIView *view = (UIView *)card;
    if (view.hidden) return;                          // 已经是隐藏的：不重复写、不重复 hit
    view.hidden = YES;
    BDFRSuppressed(hit, name, YES);
}

static bool BDPVTaskCardGate(void) {
    return BDEnabled() && !BDDumpOnly() && BDRemoveTaskCard();
}

static void BDPVLayoutAndPoint(id self, SEL _cmd) {
    ((BDPVVoidIMP)BDPVOrigLayoutAndPoint)(self, _cmd);   // 先原实现
    if (!BDPVTaskCardGate() || ![NSThread isMainThread]) return;
    BDPVHidePointsCard(self, BDPVPointsCardImpAndPoint, BDPVPointsCardSelAndPoint,
                       &BDPVHitAndPoint, "personal-task-card");
}

static void BDPVLayoutSpace(id self, SEL _cmd) {
    ((BDPVVoidIMP)BDPVOrigLayoutSpace)(self, _cmd);      // 先原实现
    if (!BDPVTaskCardGate() || ![NSThread isMainThread]) return;
    BDPVHidePointsCard(self, BDPVPointsCardImpSpace, BDPVPointsCardSelSpace,
                       &BDPVHitSpace, "personal-task-card");
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
// 依赖：只走 BDFRResolve 校验（类 + 自有方法 + 完整 @16@0:8 + argc 2），永不 attach。
static BDFRSpec BDPVSpecPointsCardAndPoint = {
    "BDPanPersonalSpaceAndPointSection", "pointsCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-task-card-getter", NO,
};
static BDFRSpec BDPVSpecPointsCardSpace = {
    "BDPanPersonalSpaceSection", "pointsCard", NO, "@16@0:8", 2,
    NULL, NULL, "personal-task-card-getter", NO,
};

// 与 BDFRInstallKingKongsWith 同形：依赖与目标**都**校验过（依赖签名 + 目标 CanAttach），
// 全过了才写依赖全局、才 attach 目标；任一不过就整条跳过，两个 IMP 槽都不写。
static BOOL BDPVInstallTaskCardWith(BDFRSpec *dep, BDFRSpec *target,
                                     IMP *cardImp, SEL *cardSel) {
    Method md = BDFRResolve(dep);
    Method mt = BDFRResolve(target);
    if (!md || !mt || !BDFRCanAttach(target, mt)) {
        BDLog(@"[BDNadFeature] skip %s: 依赖 -[%s %s] 或目标自身校验不过，什么都不装",
              target->name, dep->cls, dep->sel);
        return NO;
    }
    *cardImp = method_getImplementation(md);
    *cardSel = sel_registerName(dep->sel);
    return BDFRAttach(target, mt);   // 仍是先存原 IMP 再 method_setImplementation，不交换
}

// 接线入口：Tweak.xm 在 FeatureRemoval.h 之后 include 本文件，并在构造器里调一次。
static void BDPVInstallAll(void) {
    BDPVInstallTaskCardWith(&BDPVSpecPointsCardAndPoint, &BDPVSpecLayoutAndPoint,
                            &BDPVPointsCardImpAndPoint, &BDPVPointsCardSelAndPoint);
    BDPVInstallTaskCardWith(&BDPVSpecPointsCardSpace, &BDPVSpecLayoutSpace,
                            &BDPVPointsCardImpSpace, &BDPVPointsCardSelSpace);
}

#endif