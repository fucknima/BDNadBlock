// BDNadBlock — 传输/下载页底部推广的六条 gate
//
// 契约（与 PersonalRemoval.h 同一约定）：先 include FeatureRemoval.h（复用 BDFRSpec /
// BDFRResolve / BDFRCanAttach / BDFRAttach / BDFRSuppressed，不另抄安装器、不建默认值表）；
// 调用方提供 BDEnabled / BDDumpOnly / BDRemoveTransferYikePromo / BDRemoveTransferGamePromo /
// BDRemoveTransferCardPromo / BDRemoveTransferDataPromo / BDRemoveTransferTrialPromo
// （Tweak.xm 读 Preferences 同名键，本文件不定义）；只用 Foundation，不 import UIKit。
// 六条各自独立安装与 skip（第六条带两个只读依赖，依赖不过只跳它自己，其余五条与旧行为不变），
// 且每条**先且只先调用一次原实现**。
//
//   前三条：`B16@0:8` / argc 2 / bool。原 false 原样透传且不记 hit；只有原 true 且总开关开、
//   非诊断、该条独立开关开，才返回 false 并首次记一行 hit。两条 Yike 共用一个开关。
//   第四条：`Q16@0:8` / argc 2 / **无符号 64 位**（unsigned long long，不能用 NSInteger）。
//   只有原值**恰好 3** 且三开关都开才改判 **0ULL**；其它 0/1/2/4 与任意高位未知值**原样透传**。
//   0/1/2 的原有语义（不展示 / 已绑卡免流生效 / 需绑卡激活引导）与已激活免流状态一律保留。
//   第五条（数据包＝流量包付费引导）：`BDPanTransWidgetController -showDataPkgWigdet`，
//   `B16@0:8` / argc 2 / 自有方法。先调原实现一次，保留原策略调用、不假定下游无副作用；
//   原 false 原样返回且不 hit，只有原 true 且三开关都开才返回 false。
//   之后走**原生** false 链（haveAvailableFlowData → 试用 widget 或什么都不展示），
//   保留全部查询/缓存/通知/任务/速度/并发，不补任何 completion。
//   第六条（加速试用商品引导）：`BDNCSpeedUpTrialManager -getSpeedUpTrialWidget`，
//   `@16@0:8` / argc 2 / 自有方法；加两个**只读依赖**（同一个 view 类自己的方法）：
//   `BDNCSpeedUpTrialView -isInUseView` 与 `-isProductGuideView`，均 `B16@0:8` / argc 2。
//   依赖任一不通过就只跳过这一条；通过时保存 viewClass + 两个 SEL/IMP 供运行期只读调用，
//   依赖方法本身**永不 attach**、不写它们的原 IMP。运行期：先调原实现拿对象；nil / 开关不满足 /
//   非主线程 / 不是已核 view 类（子类或未知类型）→ **同一个原对象**原样返回；是已核类时先问
//   isInUseView（true 立刻透传，保障“试用进行中 / 已激活”），再问 isProductGuideView，
//   只有 `product 真 && inUse 假` 才返回 nil 并首次记一行 hit。不改 visible/notifyView/setWidget、
//   不调用 dismiss、不补回调、不 copy 原对象、不用字符串或私有 ivar 或坐标判断。
//
// 范围与限制（只写结论）：
//   - 第五条**不宣称**“底部必定为空”或“只影响传输页”：宿主 controller 是共享类（传输页 /
//     备份详情页 / 传输模块注册，文件列表页的同形路径未逐帧证明），动态调用范围不穷尽。
//   - 第六条只按“被取时”的原状态决策：**不保证**所有异步展示都藏住（后来从 inUse 异步变成
//     product guide 的那一次可能漏过），本组件不加定时器 / 布局 hook / 重试去补。
//   - 企业侧 probation manager 与普通侧共用同一个 BDNCSpeedUpTrialManager，所以同 exact view 的
//     促销展示会一起受影响；不宣称“企业全不覆盖”，也不为企业路径另加判定。
//   - 实际效果（布局、展示时机、真机是否还出现）未真机验证，不承诺任何页面效果。
//   - 不写 App 原生偏好（不碰“手动关闭”时间戳、不改 had* 标记）、不改下载/速度/暂停/并发、
//     不碰 window/timer/UIView/高度/inset、不调用 dismiss、不补回调。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_TRANSFER_PROMO_REMOVAL_H
#define BDNAD_TRANSFER_PROMO_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 前四条 gate

// 前三条：B 编码的返回用内建 bool（与手写 encoding 逐字对齐），复用 FeatureRemoval.h 的 BDFRBoolIMP。
// 第四条：Q 是**无符号 64 位**，必须用 unsigned long long 接，不能用 NSInteger（有符号）。
typedef unsigned long long (*BDTPU64IMP)(id, SEL);

static IMP BDTPOrigYikeTrans;        // -[BDPanTransViewController canShowYikeBanner]
static IMP BDTPOrigYikeFileList;     // -[BDPanTransferFileTransListViewController canShowYikeBanner]
static IMP BDTPOrigIdleGame;         // -[BDPanTransIdleGameManager canTransIdleGameWidgetShow]
static IMP BDTPOrigFreeUnicomCheck;  // -[BDPanFreeWidgetManage chechFreeUnicomWidget]

static dispatch_once_t BDTPHitYikeTrans;
static dispatch_once_t BDTPHitYikeFileList;
static dispatch_once_t BDTPHitIdleGame;
static dispatch_once_t BDTPHitFreeUnicom;

// 前三条统一形态：先调一次原实现拿原值；原 false 原样透传（不 hit）；
// 原 true 且三个开关都开才改判 false 并首次记一行 hit。
static bool BDTPYikeTrans(id self, SEL _cmd) {
    bool original = ((BDFRBoolIMP)BDTPOrigYikeTrans)(self, _cmd);   // 只调一次：保原状态/策略/埋点
    if (!original) return false;                                    // 本来就是 false：不 hit
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferYikePromo())) return true;
    BDFRSuppressed(&BDTPHitYikeTrans, "transfer-yike-trans", YES);
    return false;
}

static bool BDTPYikeFileList(id self, SEL _cmd) {
    bool original = ((BDFRBoolIMP)BDTPOrigYikeFileList)(self, _cmd);
    if (!original) return false;
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferYikePromo())) return true;
    BDFRSuppressed(&BDTPHitYikeFileList, "transfer-yike-filelist", YES);
    return false;
}

static bool BDTPIdleGame(id self, SEL _cmd) {
    bool original = ((BDFRBoolIMP)BDTPOrigIdleGame)(self, _cmd);
    if (!original) return false;
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferGamePromo())) return true;
    BDFRSuppressed(&BDTPHitIdleGame, "transfer-game", YES);
    return false;
}

// 第四条：数值闸门。原实现**先且只调一次**并取回原值（不因「本地看该方法体都是 getter」就假定
// 递归下全只读 —— 策略/状态仍按原样跑）；只有原值**恰好 3**（该模块自己的「引导买卡」枚举）
// 且三个开关都开时，才改判 0（原生「没有可展示的 widget」值）并首次记一行 hit。
// 其它 0/1/2/4 与任何高位未知值一律原样 return，不裁剪、不归一化。
static unsigned long long BDTPFreeUnicomCheck(id self, SEL _cmd) {
    unsigned long long original = ((BDTPU64IMP)BDTPOrigFreeUnicomCheck)(self, _cmd);
    if (original != 3ULL) return original;
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferCardPromo())) return original;
    BDFRSuppressed(&BDTPHitFreeUnicom, "transfer-card-promo", YES);
    return 0ULL;
}

#pragma mark - 第五条：数据包（流量包）付费引导

static IMP BDTPOrigDataPkgShow;      // -[BDPanTransWidgetController showDataPkgWigdet]
static dispatch_once_t BDTPHitDataPkg;

// 先且只调一次原实现（保它下游的查询/计数等副作用）；原 false 原样透传且不 hit。
static bool BDTPDataPkgShow(id self, SEL _cmd) {
    bool original = ((BDFRBoolIMP)BDTPOrigDataPkgShow)(self, _cmd);
    if (!original) return false;
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferDataPromo())) return true;
    BDFRSuppressed(&BDTPHitDataPkg, "transfer-data-promo", YES);
    return false;
}

#pragma mark - 第六条：加速试用商品引导（带两个只读依赖）

// `@16@0:8` 返回 id；getSpeedUpTrialWidget 不属于 ARC 的 retained-return 方法族，按 +0 透传。
typedef id (*BDTPObjectIMP)(id, SEL);

static IMP BDTPOrigTrialWidget;      // -[BDNCSpeedUpTrialManager getSpeedUpTrialWidget]
static dispatch_once_t BDTPHitTrial;

// 只读依赖：安装校验通过后才写入；依赖方法永不 attach，也不写它们的原 IMP。
static Class BDTPTrialViewClass;     // BDNCSpeedUpTrialView（exact class 判定用）
static IMP BDTPTrialInUseIMP;        // -[BDNCSpeedUpTrialView isInUseView]
static SEL BDTPTrialInUseSel;
static IMP BDTPTrialProductIMP;      // -[BDNCSpeedUpTrialView isProductGuideView]
static SEL BDTPTrialProductSel;

// 分类调用只发生在：开关生效 + 主线程 + 拿到对象 + 对象正是已核 view 类。
// 顺序固定先 isInUseView（进行中优先，true 立即透传）再 isProductGuideView。
static id BDTPTrialWidget(id self, SEL _cmd) {
    id v = ((BDTPObjectIMP)BDTPOrigTrialWidget)(self, _cmd);   // 只调一次
    if (!v) return v;                                          // 原生 nil：本就已经“不需要展示”
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveTransferTrialPromo())) return v;
    if (![NSThread isMainThread]) return v;                    // 非主线程：不查 UI 分类
    if (object_getClass(v) != BDTPTrialViewClass) return v;    // 子类/未知类型：原对象透传
    if (((BDFRBoolIMP)BDTPTrialInUseIMP)(v, BDTPTrialInUseSel)) return v;       // 进行中：保障
    if (!((BDFRBoolIMP)BDTPTrialProductIMP)(v, BDTPTrialProductSel)) return v;  // 非商品引导：透传
    BDFRSuppressed(&BDTPHitTrial, "transfer-trial-promo", YES);
    return nil;                                               // 只否决“商品引导”这一次取视图
}

#pragma mark - spec 表（每类独立校验、独立 skip、各自独立原 IMP 槽）

// 两条 Yike 共用同一开关，但**不是一对**：任一类签名不符只 skip 那一条，另一条照装。
static BDFRSpec BDTPspecYikeTrans = {
    "BDPanTransViewController", "canShowYikeBanner", NO, "B16@0:8", 2,
    (IMP)BDTPYikeTrans, &BDTPOrigYikeTrans, "transfer-yike-trans", NO,
};
static BDFRSpec BDTPspecYikeFileList = {
    "BDPanTransferFileTransListViewController", "canShowYikeBanner", NO, "B16@0:8", 2,
    (IMP)BDTPYikeFileList, &BDTPOrigYikeFileList, "transfer-yike-filelist", NO,
};
static BDFRSpec BDTPspecIdleGame = {
    "BDPanTransIdleGameManager", "canTransIdleGameWidgetShow", NO, "B16@0:8", 2,
    (IMP)BDTPIdleGame, &BDTPOrigIdleGame, "transfer-game", NO,
};
// 免流办卡 widget：Q = 无符号 64 位。类名与 selector 均为该模块自有方法。
static BDFRSpec BDTPspecFreeUnicom = {
    "BDPanFreeWidgetManage", "chechFreeUnicomWidget", NO, "Q16@0:8", 2,
    (IMP)BDTPFreeUnicomCheck, &BDTPOrigFreeUnicomCheck, "transfer-card-promo", NO,
};
// 数据包（流量包）付费引导：B 编码 bool，自有方法。
static BDFRSpec BDTPspecDataPkg = {
    "BDPanTransWidgetController", "showDataPkgWigdet", NO, "B16@0:8", 2,
    (IMP)BDTPDataPkgShow, &BDTPOrigDataPkgShow, "transfer-data-promo", NO,
};
// 加速试用取视图：对象返回，自有方法。
static BDFRSpec BDTPspecTrialWidget = {
    "BDNCSpeedUpTrialManager", "getSpeedUpTrialWidget", NO, "@16@0:8", 2,
    (IMP)BDTPTrialWidget, &BDTPOrigTrialWidget, "transfer-trial-promo", NO,
};
// 两个只读依赖：只走 BDFRResolve 校验（类 + 自有方法 + 完整 encoding + argc），永不 attach。
static BDFRSpec BDTPspecTrialInUseView = {
    "BDNCSpeedUpTrialView", "isInUseView", NO, "B16@0:8", 2,
    NULL, NULL, "transfer-trial-promo-inuse", NO,
};
static BDFRSpec BDTPspecTrialProductGuideView = {
    "BDNCSpeedUpTrialView", "isProductGuideView", NO, "B16@0:8", 2,
    NULL, NULL, "transfer-trial-promo-product", NO,
};

// 与 BDPVInstallTaskCardWith / BDFRInstallKingKongsWith 同形：目标与两个依赖**都**校验过
// （依赖自有方法 + 完整 encoding/argc + 目标 CanAttach + 依赖类存在），全过了才写依赖全局、
// 才 attach 目标；任一不过就只跳过这一条，两个 IMP 槽与依赖全局都不写。
static BOOL BDTPInstallTrialWith(BDFRSpec *depInUse, BDFRSpec *depProduct, BDFRSpec *target,
                                 Class *viewCls, IMP *inUseImp, SEL *inUseSel,
                                 IMP *productImp, SEL *productSel) {
    Method mdInUse = BDFRResolve(depInUse);
    Method mdProduct = BDFRResolve(depProduct);
    Method mt = BDFRResolve(target);
    Class cls = objc_getClass(depInUse->cls);
    if (!mdInUse || !mdProduct || !mt || !cls || !BDFRCanAttach(target, mt)) {
        BDLog(@"[BDNadFeature] skip %s: 依赖 %s/%s 或目标自身校验不过，什么都不装",
              target->name, depInUse->cls, depProduct->cls);
        return NO;
    }
    *viewCls = cls;
    *inUseImp = method_getImplementation(mdInUse);
    *inUseSel = sel_registerName(depInUse->sel);
    *productImp = method_getImplementation(mdProduct);
    *productSel = sel_registerName(depProduct->sel);
    return BDFRAttach(target, mt);   // 先存原 IMP 再 method_setImplementation，不交换
}

static BOOL BDTPInstallTrialPromo(void) {
    return BDTPInstallTrialWith(&BDTPspecTrialInUseView, &BDTPspecTrialProductGuideView,
                                &BDTPspecTrialWidget,
                                &BDTPTrialViewClass, &BDTPTrialInUseIMP, &BDTPTrialInUseSel,
                                &BDTPTrialProductIMP, &BDTPTrialProductSel);
}

// 接线入口：Tweak.xm 在 FeatureRemoval.h 与 PersonalRemoval.h 之后 include 本文件，并在构造器里调一次。
// 校验不通过时只打一行 skip 日志，不装、不写任何 IMP 槽；第六条依赖不过只跳它自己。
static void BDTPInstallAll(void) {
    BDFRInstallSpec(&BDTPspecYikeTrans);
    BDFRInstallSpec(&BDTPspecYikeFileList);
    BDFRInstallSpec(&BDTPspecIdleGame);
    BDFRInstallSpec(&BDTPspecFreeUnicom);
    BDFRInstallSpec(&BDTPspecDataPkg);   // 第五条：数据包（流量包）付费引导
    BDTPInstallTrialPromo();             // 第六条：加速试用商品引导（带两个只读依赖）
}

#endif
