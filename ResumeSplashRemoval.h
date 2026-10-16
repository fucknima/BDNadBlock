// BDNadBlock — 开屏展示判定闸门：冷启动(0) + 热启动(2/3)
//
// 症状：热启动空白开屏，以及用户反馈 13.35.5 冷启动时全屏开屏再次出现。
// 静态已核 BDNCUIAdvertisesManage 的冷/热启动路径都经过此判定；设备的具体展示链尚未取证。
// 让原生自己判定为「不展示」，于是它走自带的收尾路径，不进入建窗/竞价任务。
// **不是**隐藏窗口、不是定时关闭、不是延后。
//
// 静态证据（13.32.2 与 13.35.5 两版都核过同一条判定）：predicate 返回 0 时，原生自己会
// 标记「已决定不展示」（iPhone 另标记非开屏窗口）并返回 NO；冷启动上游自行通知并继续启动，
// 这条收尾是原生自带的，不是本组件补的 callback。海外动态 provider 是否使用此判定未证；
// **本文件不硬编码任何地址**。
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
//
// 语义（改这里等于改行为）：
//   - 原 IMP **先且只调一次**：它消费 _hasEnteredForeground、跑原策略检查与埋点，
//     这一步不能省（省了会改变原生状态）。返回值先拿到手。
//   - 原结果是 false 就**原样返回 false**，不记 hit（本来就不展示，不是我们拦下的）。
//   - 原结果是 true 时，只有同时满足：
//       总开关开 + 非诊断 + 广告方法开关开 + launchType 恰好是 0 / 2 / 3，
//     才把结果改成 false，并只在这第一次记一次 hit 日志。
//   - launchType 其它值（1 / 负数 / 未知正值）一律精确透传原 bool：不做区间猜测。
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

// 冷启动(0)与热启动(2/3)都可能被否决；其余类型、开关关闭、原结果 false 一律精确透传。
static bool BDRSNeedShowSplash(id self, SEL _cmd, NSInteger launchType, id launchUrl, id launchOptions) {
    // 原实现先且只调一次：状态消费 / 策略检查 / 埋点全部照旧，参数原样传。
    bool original = ((BDRSNeedShowIMP)BDFROrigResumeSplashGate)(self, _cmd, launchType, launchUrl, launchOptions);
    if (!original) return false;                       // 原生本来就不展示：原值返回，不假记 hit

    if (!(BDEnabled() && !BDDumpOnly() && BDAdMethodsEnabled())) return true;
    if (launchType != 0 && launchType != 2 && launchType != 3) return true;   // 1/负值/未知正值不动

    // token 名沿用 "resume-splash-gate"：现在也覆盖冷启动 0，但不改名，避免破坏既有日志排查习惯。
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
