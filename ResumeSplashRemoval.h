// BDNadBlock — 热启动空白开屏：只否决「展示判定」这一步，不碰窗口/生命周期
//
// 症状：从后台放一段时间回前台，广告素材已经没有了，但**空白开屏仍然出现几秒才消失**。
// 本文件只处理这一条：让原生自己在「该不该展示」那一步判定为「不展示」，
// 于是原生走它自带的收尾路径，不进入建窗/竞价任务。**不是**隐藏窗口、不是定时关闭、不是延后。
//
// 包含顺序（与 RenewButtonRemoval.h 相同的两条硬依赖）：
//   1) **必须在本文件之前先 include FeatureRemoval.h**：复用同一套
//      BDFRSpec / BDFRResolve / BDFRCanAttach / BDFRAttach / BDFRInstallSpec / BDFRSuppressed，
//      不另抄安装器、不建第二套默认值表。
//   2) 本文件只 import Foundation / objc/runtime，不 import UIKit（这里不碰任何 UI 类）。
//
// 唯一一条 hook（**自有实例方法**，在 BDNCUIAdvertisesManage 自己的方法表里）：
//   -[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]
//     encoding "B40@0:8q16@24@32"  argc 5  （self + _cmd + q + @ + @）
//     VM 0x107711cc4 仅作证据，代码里不硬编码地址。
//
// 原生顺序（已核对 13.32.2 ASM，见 research-resume-splash/trigger/uiman.asm）：
//   热启动通知 -> [BDNCUIAdvertisesManage applicationWillEnterForeground]
//     -> fetchSplashInfoAfterDelay -> dispatch_after(300ms) -> 一系列 shield 判定
//     -> showWithLaunchOptions:launchUrl:launchType:      （全区间无 alloc、无窗口，只做登录/
//        服务端开关/频次/updateShieldTimeCache，然后委派）
//       -> iPhone/iPadSplashWithLaunchOptions:launchUrl:launchType:
//         -> ***本 hook 所在的那个判定***      0x1077117d8
//            - 返回 0（不展示）：调用方自己 setIsNotSplashWindow:YES、
//              reportMonitorLogWithop:'has_ad_hot_start_not_reached' source:'splash'、
//              setDecidedNotShow:YES，然后 return NO —— **不到建窗**
//            - 返回非 0：才 dynamicAdvertiseTaskWithLaunchType:
//              -> setupSplashAdvertiseWindowWithLaunchType: -> alloc BDNCSplashAdvertiseWindow
//   也就是说：本 hook 就在**建窗之前**那一步，原生假分支自己会收尾，我们不需要补任何状态。
//
// 语义（改这里等于改行为）：
//   - 原 IMP **先且只调一次**，返回值先拿到手：保留原方法对 _hasEnteredForeground 的一次性消费、
//     原策略检查（isFirstLauchDay / needShieldSplashAdForFirstLaunch /
//     isDSPOrActivityLinkLaunchWithUrl / needShieldSplashAdForThirdLaunch 等）与全部埋点。
//   - 原结果是 false 就**原样返回 false**，不记 hit（本来就不展示，不是我们拦下的）。
//   - 原结果是 true 时，只有同时满足：
//       总开关开 + 非诊断 + 广告方法开关开 + launchType 恰好是 2 或 3，
//     才把结果改成 false，并只在这第一次记一次 hit 日志。
//   - launchType 其它值（0 / 1 / 负数 / 未知正值）一律精确透传原 bool：冷启动走的就是 0，
//     不受影响；不做区间猜测、不把未知值当热启动。
//   - 三个参数（launchType / launchUrl / launchOptions）**原样传**，nil 不造默认对象。
//   - 不读也不写任何 ivar（尤其不碰 _hasEnteredForeground / _decidedNotShow /
//     _enterbackgroundTime / _splashWindow / _dspTimer），不补 notification、不改时长、
//     不建窗不关窗、不加定时器/重试/锁/返回值 fallback。
//   - 只读开关：不写 App 原生配置、不改持久化、不新增设置键。
//
// 依赖但不在本文件定义（由调用方提供，命名与其它组件一致）：
//   BDLog / BDEnabled / BDDumpOnly / BDAdMethodsEnabled（读既有 Prefs 键 BDNadBlockAdMethods 的
//   进程启动快照，不新增键、不在本合同抄默认值）。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_RESUME_SPLASH_REMOVAL_H
#define BDNAD_RESUME_SPLASH_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 原实现转发用的 typed 指针

// 返回 bool（encoding 的 B），参数依次 NSInteger(q) / id(@) / id(@)。
// 不用 objc_msgSend 转发，只直调安装期保存下来的原 IMP。
typedef bool (*BDRSNeedShowIMP)(id, SEL, NSInteger, id, id);

#pragma mark - 原 IMP 槽与 hit token

static IMP BDFROrigResumeSplashGate;      // -[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]
static dispatch_once_t BDRSHitResumeSplashGate;

#pragma mark - 替换实现

// 热启动（launchType 2/3）才可能被否决；其余类型、开关关闭、原结果 false 一律精确透传。
static bool BDRSNeedShowSplash(id self, SEL _cmd, NSInteger launchType, id launchUrl, id launchOptions) {
    // 原实现先且只调一次：状态消费 / 策略检查 / 埋点全部照旧，参数原样传。
    bool original = ((BDRSNeedShowIMP)BDFROrigResumeSplashGate)(self, _cmd, launchType, launchUrl, launchOptions);
    if (!original) return false;                       // 原生本来就不展示：原值返回，不假记 hit

    if (!(BDEnabled() && !BDDumpOnly() && BDAdMethodsEnabled())) return true;
    if (launchType != 2 && launchType != 3) return true;   // 0 = 冷启动；1/负值/未知正值不动

    BDFRSuppressed(&BDRSHitResumeSplashGate, "resume-splash-gate", YES);   // 只在真正否决时首次记一行
    return false;
}

#pragma mark - spec 与安装入口

static BDFRSpec BDFRSpecResumeSplashGate = {
    "BDNCUIAdvertisesManage", "needToShowSplashWithLaunchType:launchUrl:launchOptions:",
    NO, "B40@0:8q16@24@32", 5,
    (IMP)BDRSNeedShowSplash, &BDFROrigResumeSplashGate, "resume-splash-gate", NO,
};

// 接线入口：单条安装。校验不过只 skip，不写 IMP、不动别的组件。
static void BDRSInstallAll(void) {
    BDFRInstallSpec(&BDFRSpecResumeSplashGate);
}

#endif