// BDNadBlock — BDNC 冷/热启动开屏闸门 + App Open 冷/热策略
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
// 三条 hook（都是**自有实例方法**，各自在目标类自己的方法表里）：
//   -[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]
//     encoding "B40@0:8q16@24@32"  argc 5  （self + _cmd + q + @ + @）
//   -[BDPanAdvertisementStrategy isEnableShowAdForAppColdOpenWithLaunchoptions:] B24@0:8@16 argc 3
//   -[BDPanAdvertisementStrategy isEnableShowAdForAppHotOpenWithFrom:] B24@0:8q16 argc 3
// 后两条是 App Open 冷/热策略：两版各查到一个启动广告入口的直接调用点，动态/跨镜像调用未穷尽。
// 它们返回 false 时原生自己走「不展示」收尾（不建 callback、不碰 handler、不触发调用方 present/dismiss
// block），与「服务端把该类别关掉」是同一条既有路径。所以只在策略判定层把 true 改 false，
// 不动展示层、不补回调。热那条只纳入 from ∈ {1,2,3,4}（-keyForAppHotOpenWithFrom: 的字面量表
// 两版一致：1/2=icon、3=web、4=push）；0 / 负值 / 未知值一律精确透传，不把「非零」当热启动。
//
// BDNC 闸门语义（改这里等于改行为）：
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
//   - App Open 那两条同规则：原 IMP 先且只调一次 → 原 false 透传不记 hit → 三开关全开才把 true 改 false；
//     枚举各自独立（开屏 = launchType 0/2/3，App Open 冷 = 无枚举，App Open 热 = from 1/2/3/4），不混用。
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

#pragma mark - App Open 冷/热策略闸门（两条）

// 返回 bool（encoding 的 B），实参：冷 = id（launch options 字典，可为 nil）/ 热 = NSInteger（from）。
// 同样不用 objc_msgSend 转发，只直调安装期保存下来的原 IMP；实参原值传递，不复制、不造默认对象。
typedef bool (*BDAOIdGateIMP)(id, SEL, id);        // 冷
typedef bool (*BDAOQGateIMP)(id, SEL, NSInteger);  // 热

static IMP BDFROrigAppColdOpenGate;      // -[BDPanAdvertisementStrategy isEnableShowAdForAppColdOpenWithLaunchoptions:]
static IMP BDFROrigAppHotOpenGate;       // -[BDPanAdvertisementStrategy isEnableShowAdForAppHotOpenWithFrom:]
static dispatch_once_t BDRSHitAppColdOpenGate;
static dispatch_once_t BDRSHitAppHotOpenGate;

// 冷：原 true 且三开关全开才改成 false；其余一律原值透传。
static bool BDRSAppColdOpenGate(id self, SEL _cmd, id launchOptions) {
    // 原实现先且只调一次：AMIS 配置读取等副作用照旧，launchOptions（含 nil）identity 保真。
    bool original = ((BDAOIdGateIMP)BDFROrigAppColdOpenGate)(self, _cmd, launchOptions);
    if (!original) return false;                       // 原生本来就不展示：原值返回，不假记 hit
    if (!(BDEnabled() && !BDDumpOnly() && BDAdMethodsEnabled())) return true;
    BDFRSuppressed(&BDRSHitAppColdOpenGate, "app-open-cold-gate", YES);   // 只在真正否决时首次记一行
    return false;
}

// 热：只有已证枚举 from ∈ {1,2,3,4} 才纳入否决；0 / 负值 / 其它未知值（含 NSIntegerMax）不猜。
static bool BDRSAppHotOpenGate(id self, SEL _cmd, NSInteger from) {
    bool original = ((BDAOQGateIMP)BDFROrigAppHotOpenGate)(self, _cmd, from);
    if (!original) return false;
    if (!(BDEnabled() && !BDDumpOnly() && BDAdMethodsEnabled())) return true;
    if (from < 1 || from > 4) return true;             // 未来新增的未知 from 精确透传原 bool
    BDFRSuppressed(&BDRSHitAppHotOpenGate, "app-open-hot-gate", YES);
    return false;
}

#pragma mark - spec 与安装入口

static BDFRSpec BDFRSpecResumeSplashGate = {
    "BDNCUIAdvertisesManage", "needToShowSplashWithLaunchType:launchUrl:launchOptions:",
    NO, "B40@0:8q16@24@32", 5,
    (IMP)BDRSNeedShowSplash, &BDFROrigResumeSplashGate, "resume-splash-gate", NO,
};

// App Open 冷/热各一条：独立校验、独立 orig 槽、独立 token，互不影响，也不改上面那条。
static BDFRSpec BDFRSpecAppColdOpenGate = {
    "BDPanAdvertisementStrategy", "isEnableShowAdForAppColdOpenWithLaunchoptions:",
    NO, "B24@0:8@16", 3,
    (IMP)BDRSAppColdOpenGate, &BDFROrigAppColdOpenGate, "app-open-cold-gate", NO,
};
static BDFRSpec BDFRSpecAppHotOpenGate = {
    "BDPanAdvertisementStrategy", "isEnableShowAdForAppHotOpenWithFrom:",
    NO, "B24@0:8q16", 3,
    (IMP)BDRSAppHotOpenGate, &BDFROrigAppHotOpenGate, "app-open-hot-gate", NO,
};

// 接线入口：三条各自独立校验（校验不过只 skip 自己，不牵连别条）。
static void BDRSInstallAll(void) {
    BDFRInstallSpec(&BDFRSpecResumeSplashGate);
    BDFRInstallSpec(&BDFRSpecAppColdOpenGate);
    BDFRInstallSpec(&BDFRSpecAppHotOpenGate);
}

#endif
