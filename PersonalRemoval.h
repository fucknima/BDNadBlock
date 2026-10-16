// BDNadBlock — 「我的」页两处：活动轮播 + 推广入口整排
//
// 必须在 FeatureRemoval.h **之后** include：复用同一套 BDFRSpec / BDFRResolve /
// BDFRInstallSpec / BDFRSuppressed 与同一组开关读取函数，不另抄安装器、不另建默认值表
// （BDNadPrefsActive 由 Tweak.xm 统一接线；BDRemovePersonalBanner 与
// BDRemovePersonalPromotions 同理，都由 Tweak.xm 提供）。
// 本文件只依赖 Foundation + 同一套 BDFR* 原语。
//
// 语义（与调用方议定，改这里等于改行为）：
//   轮播：只覆盖 +[BDPanPersonalConfig bannerSwitch]（B16@0:8，类方法落在 metaclass）。
//     已从 -[BDPanPersonalViewController setupSections] 逐条反汇编确认：该开关为 false 时整个
//     BDPanPersonalBannerSection 不创建 —— 它就是「我的」活动轮播的 native gate。
//   推广整排：覆盖两个 class 各自的 -heightForView（d16@0:8，argc 2），各返回**该 class 自己
//     在原生代码里用的收起值**（见下面两个常量旁的注释）。不碰 -fetchSectionData、不清数组、
//     不拦 BDPanActivityManage、不写任何缓存或 App 原生配置键。
//   - **调用方穷尽性未证明**：只保证「读这些开关/这些高度的那条路径」不再显示，
//     不承诺覆盖 My 页全部入口，也不承诺零网络请求（推广整排的数据请求照旧发生，
//     只是不显示；轮播数据也可能由别处预取）。
//   - 安装沿用既有规则：方法必须在该类自己的方法表里（继承来的不动）、完整 type encoding 与
//     argc 逐字节核对、不符就 skip 什么都不装；先存原 IMP 再 method_setImplementation，
//     绝不交换 IMP；透传时用匹配的 typed 指针与原 selector。
//   - 每次调用重新读 BDEnabled / BDDumpOnly / BDRemovePersonalBanner / BDRemovePersonalPromotions；
//     只有开关生效、该方法实际被强制返回收起值时才首次记一行 hit（installed 与 hit 是两条不同的
//     日志）；开关生效时不调原实现，所以不知道它原本返回多少，hit 也不证明该区块曾经可见。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_PERSONAL_REMOVAL_H
#define BDNAD_PERSONAL_REMOVAL_H

#import <Foundation/Foundation.h>

#pragma mark - 我的活动轮播（bannerSwitch）

// B 编码的返回与 BOOL 未必等价（见 FeatureRemoval.h 同处说明），所以用内建 bool；
// BDFRBoolIMP 就是 bool (*)(id, SEL)，直接复用，不另起一个 typedef。
static IMP BDPROrigBannerSwitch;      // +[BDPanPersonalConfig bannerSwitch]
static dispatch_once_t BDPRHitBannerSwitch;

static bool BDPRBannerSwitch(id self, SEL _cmd) {
    if (BDFRSuppressed(&BDPRHitBannerSwitch, "personal-banner",
                       BDEnabled() && !BDDumpOnly() && BDRemovePersonalBanner()))
        return false;                                   // 整个 banner section 不再建
    return ((BDFRBoolIMP)BDPROrigBannerSwitch)(self, _cmd);   // 精确透传原返回值
}

// 类方法（isClassMethod = YES，装在 metaclass 槽）、B16@0:8、argc 2（self + _cmd）。
static BDFRSpec BDPRSpecBannerSwitch = {
    "BDPanPersonalConfig", "bannerSwitch", YES, "B16@0:8", 2,
    (IMP)BDPRBannerSwitch, &BDPROrigBannerSwitch, "personal-banner", NO,
};

#pragma mark - 我的推广入口整排（-heightForView -> 各 class 自己的原生收起值）

// d16@0:8 的返回与函数指针都用 double：与手写 encoding 逐字对齐，不复用别处的 typedef。
typedef double (*BDFRHeightIMP)(id, SEL);

static IMP BDPROrigWalletHeight;        // -[BDPanPersonalWalletSection heightForView]
static IMP BDPROrigCenterWalletHeight;  // -[BDPanPersonalCenterWalletSection heightForView]
static dispatch_once_t BDPRHitWalletHeight;
static dispatch_once_t BDPRHitCenterWalletHeight;

static double BDPRWalletHeight(id self, SEL _cmd) {
    if (BDFRSuppressed(&BDPRHitWalletHeight, "personal-promo-row",
                       BDEnabled() && !BDDumpOnly() && BDRemovePersonalPromotions()))
        return -6.0;   // 新个人页：-[BDPanPersonalViewController tableView:heightForRowAtIndexPath:]
                       // 对 heightForView 的结果固定 +6.0，原生收起值就是 -6.0（同一节里
                       // 该方法在 _dataArray 为空时也正是返回 -6.0）
    return ((BDFRHeightIMP)BDPROrigWalletHeight)(self, _cmd);
}

static double BDPRCenterWalletHeight(id self, SEL _cmd) {
    if (BDFRSuppressed(&BDPRHitCenterWalletHeight, "personal-promo-row-center",
                       BDEnabled() && !BDDumpOnly() && BDRemovePersonalPromotions()))
        return -3.0;   // 旧个人中心页：-[BDPanPersonalCenterViewController tableView:heightForRowAtIndexPath:]
                       // 加的是 bottomEdgeSection:（该 section 没实现 bottomEdgeForView 时返回 3.0），
                       // 而这个 class 自己的原生收起值是 -3.0（dataList 为空时）。这里必须用 -3.0：
                       // 用 -6.0 会算出行高 -3，交给 UITableView 一个负行高。
    return ((BDFRHeightIMP)BDPROrigCenterWalletHeight)(self, _cmd);
}

// 两个 class 各自独立校验、独立 skip、互相不依赖（也不共用原 IMP 槽）。
static BDFRSpec BDPRSpecWalletHeight = {
    "BDPanPersonalWalletSection", "heightForView", NO, "d16@0:8", 2,
    (IMP)BDPRWalletHeight, &BDPROrigWalletHeight, "personal-promo-row", NO,
};
static BDFRSpec BDPRSpecCenterWalletHeight = {
    "BDPanPersonalCenterWalletSection", "heightForView", NO, "d16@0:8", 2,
    (IMP)BDPRCenterWalletHeight, &BDPROrigCenterWalletHeight, "personal-promo-row-center", NO,
};

// 接线入口：Tweak.xm 在 FeatureRemoval.h 之后 include 本文件，并在构造器里调一次。
// 校验不通过时只打一行 skip 日志，不装、不写任何 IMP 槽。
static void BDPRInstallData(void) {
    BDFRInstallSpec(&BDPRSpecBannerSwitch);
    BDFRInstallSpec(&BDPRSpecWalletHeight);
    BDFRInstallSpec(&BDPRSpecCenterWalletHeight);
}

#endif