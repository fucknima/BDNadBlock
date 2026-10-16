// BDNadBlock — 传输页两处推广：一刻相册推广行 + 传输列表空闲游戏引导
//
// 前置契约（与 PersonalRemoval.h 同一约定）：先 include FeatureRemoval.h（复用 BDFRSpec /
// BDFRResolve / BDFRInstallSpec / BDFRSuppressed，不另抄安装器、不建默认值表）；调用方提供
// BDEnabled / BDDumpOnly / BDRemoveTransferYikePromo / BDRemoveTransferGamePromo（Tweak.xm 读
// Preferences 同名键，本文件不定义）；本文件只用 Foundation，不 import UIKit。
//
// 语义（与调用方议定，改这里等于改行为）：三条都是 `B16@0:8`、argc 2 的类自有实例 gate getter，
// 各自独立安装与 skip、互不依赖。每条**先且只先调用一次原实现**并取回原 bool（原实现里的
// 策略/状态/埋点照旧发生）：原返回 false 时原样返回 false 且不记 hit（那不是我们抑制的）；
// 只有「原 true 且总开关开、非诊断、该条独立开关开」才返回 false 并首次记一行 hit。
// 两条 Yike 共用同一个开关，游戏那条用另一个开关。
//
// 已证明与未验证（只写静态分析范围，具体地址与跳转表不复述）：
//   已证明：主传输页 `BDPanTransViewController` 那条 gate 为 NO 时走原生行高入口的共同返回
//   （行高 0、无空行），与「用户手动关闭」同一布局；产品不为此改任何高度/section。
//   未验证：第二条 Yike `BDPanTransferFileTransListViewController` 的运行期展示路径没有静态证据，
//   保留它只为「原方法先调一次 + 精确透传」的安全语义，不声称会收起任何行。
//   游戏那条的原生消费点本身就有「gate NO → 直接返回、不存 block、不建 widget」的分支，
//   所以这里只改判 bool。**真机布局与展示效果未验证**，本文件不承诺任何页面效果。
//   不写 App 原生偏好（不碰“手动关闭”时间戳）、不改下载/速度/暂停/并发、不改 -transIdleGameEnable。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_TRANSFER_PROMO_REMOVAL_H
#define BDNAD_TRANSFER_PROMO_REMOVAL_H

#import <Foundation/Foundation.h>

#pragma mark - 三条 gate

// B 编码的返回用内建 bool（与手写 encoding 逐字对齐），复用 FeatureRemoval.h 的 BDFRBoolIMP。
static IMP BDTPOrigYikeTrans;        // -[BDPanTransViewController canShowYikeBanner]
static IMP BDTPOrigYikeFileList;     // -[BDPanTransferFileTransListViewController canShowYikeBanner]
static IMP BDTPOrigIdleGame;         // -[BDPanTransIdleGameManager canTransIdleGameWidgetShow]

static dispatch_once_t BDTPHitYikeTrans;
static dispatch_once_t BDTPHitYikeFileList;
static dispatch_once_t BDTPHitIdleGame;

// 三条统一形态：先调一次原实现拿原值；原 false 原样透传（不 hit）；
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

// 接线入口：Tweak.xm 在 FeatureRemoval.h 与 PersonalRemoval.h 之后 include 本文件，并在构造器里调一次。
// 校验不通过时只打一行 skip 日志，不装、不写任何 IMP 槽；先存原 IMP 再 method_setImplementation。
static void BDTPInstallAll(void) {
    BDFRInstallSpec(&BDTPspecYikeTrans);
    BDFRInstallSpec(&BDTPspecYikeFileList);
    BDFRInstallSpec(&BDTPspecIdleGame);
}

#endif