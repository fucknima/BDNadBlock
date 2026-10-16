// BDNadBlock — 「去续费」按钮可隐藏（默认保留，独立开关）
//
// 包含顺序（与 FeatureRemoval.h 相同的两条硬依赖）：
//   1) 调用方必须**先** import UIKit —— 本文件只 import Foundation/objc/runtime，
//      下面用到的 UIButton / -isHidden / -setHidden: 由调用方的 UIKit 声明提供。
//      Tweak.xm 与 ui_compile 的编译单元都已经 import 了 UIKit。
//   2) 必须**在 FeatureRemoval.h 之后** include：复用同一套 BDFRSpec / BDFRResolve /
//      BDFRInstallSpec / BDFRSuppressed 与同一组开关读取，不另抄安装器、不建默认值表。
//      BDRemoveRenewButton() 也由 Tweak.xm 统一提供：它读的是 BDNadPrefsActive 的**进程启动快照**
//      （对应 NSUserDefaults 里既有的键，产品默认 NO），不是每次调用重读 defaults。
//
// 三个 hook（都是**实例方法**、都在各自类自己的方法表里、`@16@0:8`、argc 2）：
//   -[BDPanPersonNewVipCardHeaderView vipButton]      0x106e599ac
//   -[BDPanPersonVipHeaderView vipButton]             0x106e63cdc
//   -[BDPanPersonAdvanceVIPHeaderView vipButton]      0x106dee1a8
// 三张卡由 +[BDPanPersonalConfig isSVipCardRedesignEnable] / isAdvanceProfilePageStyle 互斥选出，
// 线上只会命中其中一张；但三条**各自独立安装**，某一类缺失不阻断另外两条。
//
// 语义（与调用方议定，改这里等于改行为）：
//   - getter 原 IMP 先且只调用一次；返回值原样返回（**同一个对象**，不新建按钮、
//     不写 title/model、不调用任何其它私有 getter）。
//   - 只有同时满足：总开关开 + 非诊断 + 独立开关开 + **主线程** + 返回值确实是 UIButton，
//     才把该 button 置 hidden。nil 或非 UIButton 一律原样透传：类型判定本身要发一次
//     -isKindOfClass:，但**不向非按钮发送 UIKit 可见性消息**（不 setHidden:/setAlpha:）。
//   - 已经 hidden 的不再重复处理；只有 visible -> hidden 这第一次才记 hit 日志。
//   - 非主线程：只调原 IMP 后原样返回，不动 UI、不记 hit。本文件不做 dispatch、不加延时、
//     不加锁、不重试（线程决策留给调用方）。
//   - 一律不动 tapView / topTapView / 父卡 / 约束 / 整体会员入口：卡片整体点击行为保持原样。
//   - 只读开关：不写任何 App 原生配置、不改持久化。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_RENEW_BUTTON_REMOVAL_H
#define BDNAD_RENEW_BUTTON_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - getter 转发用的 typed 指针

// @16@0:8 返回对象指针。与 FeatureRemoval.h 的 BDFRKongArrayIMP 同一处理：
// IMP -> (返回对象) 的 typed cast 在 ObjC++ 里是合法的。
typedef id (*BDRBIdIMP)(id, SEL);

#pragma mark - 三条 spec 的原 IMP 槽与 hit token

static IMP BDFROrigRenewButtonNew;   // -[BDPanPersonNewVipCardHeaderView vipButton]
static IMP BDFROrigRenewButtonVip;   // -[BDPanPersonVipHeaderView vipButton]
static IMP BDFROrigRenewButtonAdv;   // -[BDPanPersonAdvanceVIPHeaderView vipButton]

static dispatch_once_t BDRBHitRenewButtonNew;
static dispatch_once_t BDRBHitRenewButtonVip;
static dispatch_once_t BDRBHitRenewButtonAdv;

#pragma mark - 隐藏逻辑（三处共用）

// 只在开关已判定为「要隐藏」且处于主线程时调用。
// 返回值不是 UIButton 或已经是 hidden 时一律不动，也不记 hit。
static inline id BDRBApplyHide(id result, dispatch_once_t *hit, const char *name) {
    if (!result || ![result isKindOfClass:[UIButton class]]) return result;   // 非按钮：不做任何可见性操作
    UIButton *button = (UIButton *)result;                                   // 之后的可见性消息只发给按钮
    if ([button isHidden]) return result;                                    // 已隐藏：不重复处理、不重复 hit
    [button setHidden:YES];
    BDFRSuppressed(hit, name, YES);                                          // visible -> hidden 才首次 hit
    return result;
}

// 开关 + 线程的总闸；不满足就只把原对象带回去。
static inline BOOL BDRBShouldHide(void) {
    return BDEnabled() && !BDDumpOnly() && BDRemoveRenewButton();
}

#pragma mark - 三个替换实现

static id BDRBRenewButtonNew(id self, SEL _cmd) {
    id result = ((BDRBIdIMP)BDFROrigRenewButtonNew)(self, _cmd);   // 原实现只调一次
    if (!BDRBShouldHide() || ![NSThread isMainThread]) return result;   // 非主线程：不动 UI、不记 hit
    return BDRBApplyHide(result, &BDRBHitRenewButtonNew, "renew-button-new");
}

static id BDRBRenewButtonVip(id self, SEL _cmd) {
    id result = ((BDRBIdIMP)BDFROrigRenewButtonVip)(self, _cmd);
    if (!BDRBShouldHide() || ![NSThread isMainThread]) return result;
    return BDRBApplyHide(result, &BDRBHitRenewButtonVip, "renew-button-vip");
}

static id BDRBRenewButtonAdv(id self, SEL _cmd) {
    id result = ((BDRBIdIMP)BDFROrigRenewButtonAdv)(self, _cmd);
    if (!BDRBShouldHide() || ![NSThread isMainThread]) return result;
    return BDRBApplyHide(result, &BDRBHitRenewButtonAdv, "renew-button-adv");
}

#pragma mark - spec 与安装入口

static BDFRSpec BDFRSpecRenewButtonNew = {
    "BDPanPersonNewVipCardHeaderView", "vipButton", NO, "@16@0:8", 2,
    (IMP)BDRBRenewButtonNew, &BDFROrigRenewButtonNew, "renew-button-new", NO,
};
static BDFRSpec BDFRSpecRenewButtonVip = {
    "BDPanPersonVipHeaderView", "vipButton", NO, "@16@0:8", 2,
    (IMP)BDRBRenewButtonVip, &BDFROrigRenewButtonVip, "renew-button-vip", NO,
};
static BDFRSpec BDFRSpecRenewButtonAdv = {
    "BDPanPersonAdvanceVIPHeaderView", "vipButton", NO, "@16@0:8", 2,
    (IMP)BDRBRenewButtonAdv, &BDFROrigRenewButtonAdv, "renew-button-adv", NO,
};

// 接线入口：三条独立安装；某条校验不过只 skip 自己，不影响另外两条。
static void BDRBInstallAll(void) {
    BDFRInstallSpec(&BDFRSpecRenewButtonNew);
    BDFRInstallSpec(&BDFRSpecRenewButtonVip);
    BDFRInstallSpec(&BDFRSpecRenewButtonAdv);
}

#endif