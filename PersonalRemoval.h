// BDNadBlock — 「我的」活动轮播：+[BDPanPersonalConfig bannerSwitch] -> NO
//
// 必须在 FeatureRemoval.h **之后** include：复用同一套 BDFRSpec / BDFRResolve /
// BDFRInstallSpec / BDFRSuppressed 与同一组开关读取函数，不另抄安装器、不另建默认值表
// （BDNadPrefsActive 由 Tweak.xm 统一接线；BDRemovePersonalBanner 同理，由 Tweak.xm 提供）。
// 本文件只依赖 Foundation + 同一套 BDFR* 原语，后续 promo 可继续往这个 header 追加。
//
// 语义（与调用方议定，改这里等于改行为）：
//   - 只覆盖一个确定的方法：+[BDPanPersonalConfig bannerSwitch]（B16@0:8，类方法落在 metaclass）。
//     已从 -[BDPanPersonalViewController setupSections] 逐条反汇编确认：该开关为 false 时整个
//     BDPanPersonalBannerSection 不创建 —— 它就是「我的」活动轮播的 native gate。
//   - **调用方穷尽性未证明**：只保证「读这个开关的那条路径」不再建轮播 section；
//     不承诺覆盖 My 页全部入口，也不承诺零网络请求（轮播数据可能由别处预取）。
//   - 安装沿用既有规则：方法必须在该类自己的方法表里（继承来的不动）、完整 type encoding 与
//     argc 逐字节核对、不符就 skip 什么都不装；先存原 IMP 再 method_setImplementation，
//     绝不交换 IMP；透传时用匹配的 typed 指针与原 selector。
//   - 只读开关，不写 App 原生配置：绝不碰 BDPanPersonalConfig 及其它任何持久化键。
//   - 每次调用重新读 BDEnabled / BDDumpOnly / BDRemovePersonalBanner；
//     只有开关生效、该 getter 实际被强制返回 false 时才首次记一行 hit（installed 与 hit 是两条不同的日志）；
//     开关生效时不调原实现，所以不知道它原本是 true 还是 false，hit 也不证明该区块曾经可见。
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

// 接线入口：Tweak.xm 在 FeatureRemoval.h 之后 include 本文件，并在构造器里调一次。
// 校验不通过时只打一行 skip 日志，不装、不写任何 IMP 槽。
static void BDPRInstallData(void) {
    BDFRInstallSpec(&BDPRSpecBannerSwitch);
}

#endif