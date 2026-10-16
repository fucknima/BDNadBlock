// BDNadBlock — 传输页三处推广：一刻相册推广行 + 传输列表空闲游戏引导 + 免流办卡 widget
//
// 契约（与 PersonalRemoval.h 同一约定）：先 include FeatureRemoval.h（复用 BDFRSpec /
// BDFRResolve / BDFRInstallSpec / BDFRSuppressed，不另抄安装器、不建默认值表）；调用方提供
// BDEnabled / BDDumpOnly / BDRemoveTransferYikePromo / BDRemoveTransferGamePromo /
// BDRemoveTransferCardPromo（Tweak.xm 读 Preferences 同名键，本文件不定义）；只用 Foundation，
// 不 import UIKit。四条各自独立安装与 skip、互不依赖，且每条**先且只先调用一次原实现**。
//
//   前三条：`B16@0:8` / argc 2 / bool。原 false 原样透传且不记 hit；只有原 true 且总开关开、
//   非诊断、该条独立开关开，才返回 false 并首次记一行 hit。两条 Yike 共用一个开关。
//   第四条：`Q16@0:8` / argc 2 / **无符号 64 位**（unsigned long long，不能用 NSInteger）。
//   只有原值**恰好 3** 且三开关都开才改判 **0ULL**；其它 0/1/2/4 与任意高位未知值**原样透传**。
//   0/1/2 的原有语义（不展示 / 已绑卡免流生效 / 需绑卡激活引导）与已激活免流状态一律保留。
//
// 范围与限制（只写结论）：
//   - **不宣称「底部必定为空」**：第四条的 gate 为 NO 后，原生 controller 会继续走**原生 fallback**
//     （数据包 / 备份 / 试用超额 / 各类提醒 widget），那些一路保留，不在本文件范围。
//   - **同款组件可能跨宿主页**：宿主 controller 除传输页外还被备份详情页引用，所以不声称只影响传输页；
//     本文件只按「类 + selector」精确安装，不做页面判定、不加页面上下文。
//   - **企业空间不覆盖**：企业侧有自己的同名实现，其 `getShowWidgetWithType:` 以 self 为 receiver；
//     本 spec 只替换非企业类的方法槽，不动企业自有实现。
//   - **实际效果（布局、展示时机、真机是否还出现办卡条）未真机验证**，不承诺任何页面效果。
//   - 不写 App 原生偏好（不碰“手动关闭”时间戳、不改 had* 标记）、不改下载/速度/暂停/并发、
//     不碰 window/timer/UIView/高度/inset。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_TRANSFER_PROMO_REMOVAL_H
#define BDNAD_TRANSFER_PROMO_REMOVAL_H

#import <Foundation/Foundation.h>

#pragma mark - 四条 gate

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

// 接线入口：Tweak.xm 在 FeatureRemoval.h 与 PersonalRemoval.h 之后 include 本文件，并在构造器里调一次。
// 校验不通过时只打一行 skip 日志，不装、不写任何 IMP 槽；先存原 IMP 再 method_setImplementation。
static void BDTPInstallAll(void) {
    BDFRInstallSpec(&BDTPspecYikeTrans);
    BDFRInstallSpec(&BDTPspecYikeFileList);
    BDFRInstallSpec(&BDTPspecIdleGame);
    BDFRInstallSpec(&BDTPspecFreeUnicom);
}

#endif
