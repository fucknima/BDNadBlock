// tests/ui_compile.mm — 用 iOS SDK 对 UIKit 组件做编译（语法/签名）检查，**不运行**
//
// 这不是 UI 运行测试：只 -fsyntax-only，不建 app、不启模拟器、不进 Xcode 工程、
// 不发消息、不读 NSUserDefaults（下面那些开关壳只是「能被编译」的代码，检查阶段不执行）。
// 目的：让这几个 UIKit header 真过一遍 iOS SDK + -Wall -Wextra -Werror（不靠 -Wno），
// 并且让它们里面所有 static 函数都被真正引用到 —— 没人调就会报 unused-function，
// 那正是接线缺失或漏改的信号。
//
// 覆盖的 header（都是产品代码本身，不复制、不改写）：
//   SettingsMenu.h / FeatureRemoval.h / SearchDataRemoval.h / SearchViewRemoval.h / MenuEntry.h
//
// 编译运行（CI 的 macOS runner，无需 IPA；工具链取当前选中的 Xcode）：
//   sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
//   xcrun --sdk iphoneos clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -target arm64-apple-ios15.0 -isysroot "$sdk" -I . -x objective-c++ -fsyntax-only tests/ui_compile.mm

#import <UIKit/UIKit.h>
#import "Preferences.h"

#pragma mark - 只为编译存在的最小壳（不新增默认值表、不做任何 I/O）

// 日志壳：只吞掉格式串，不解析路径、不写文件、不打 syslog。
static void BDLog(NSString *fmt, ...) { (void)fmt; }

// 菜单入口会把它转成 NSURL 传进去：给一个非空路径字符串就够，
// 这里只是拼字符串，不 touch 任何目录、不建文件。
static NSString *BDResolveLogPath(void) { return @"compile-check/BDNadBlock-dump.txt"; }

// 开关壳：直接复用 Preferences.h 的启动快照读原语，**不**另建一份默认值表
// （默认值的唯一来源是 Preferences.h 的规格表）。运行期语义与 Tweak.xm 相同。
static BOOL BDEnabled(void)           { return BDNadPrefsActive(@"BDNadBlockEnabled"); }
static BOOL BDDumpOnly(void)          { return BDNadPrefsActive(@"BDNadBlockDumpOnly"); }
static BOOL BDRemoveRecommend(void)   { return BDNadPrefsActive(@"BDRemoveRecommend"); }
static BOOL BDRemoveGameCenter(void)  { return BDNadPrefsActive(@"BDRemoveGameCenter"); }
static BOOL BDRemoveJobNovel(void)    { return BDNadPrefsActive(@"BDRemoveJobNovel"); }
static BOOL BDRemoveSearchPromo(void) { return BDNadPrefsActive(@"BDRemoveSearchPromo"); }
static BOOL BDRemoveSearchAI(void)    { return BDNadPrefsActive(@"BDRemoveSearchAI"); }
static BOOL BDRemoveAITab(void)       { return BDNadPrefsActive(@"BDRemoveAITab"); }
static BOOL BDRemovePersonalBanner(void) { return BDNadPrefsActive(@"BDRemovePersonalBanner"); }
static BOOL BDRemoveRenewButton(void)   { return BDNadPrefsActive(@"BDRemoveRenewButton"); }
static BOOL BDRemovePersonalPromotions(void) { return BDNadPrefsActive(@"BDRemovePersonalPromotions"); }
static BOOL BDRemoveTaskCard(void)      { return BDNadPrefsActive(@"BDRemoveTaskCard"); }

#pragma mark - 产品 header（顺序就是它们之间的单向依赖，别调换）

// SettingsMenu.h   提供 BDPresentPurificationSettings（MenuEntry 的依赖）
// FeatureRemoval.h 提供 BDFRSpec / BDFRResolve / BDFRInstallSpec（下面几个组件的安装器）
// TabRemoval.h     底部 AI tab 过滤（复用安装器）
// PersonalRemoval.h「我的」活动轮播 + 推广整排（复用安装器）
// PersonalViewRemoval.h「我的」任务卡 / 金币卡（布局 post-hook + 只读 getter 依赖）
// RenewButtonRemoval.h「去续费」按钮可隐藏（不 import UIKit，用本文件顶部的真实 UIKit 声明）
// SearchDataRemoval.h / SearchViewRemoval.h 搜索框数据层与 UI 层（必须在 FeatureRemoval.h 之后）
// MenuEntry.h      设置页入口按钮（需要菜单入口 + 安装器）
#include "SettingsMenu.h"
#include "FeatureRemoval.h"
#include "TabRemoval.h"
#include "PersonalRemoval.h"
#include "PersonalViewRemoval.h"
#include "RenewButtonRemoval.h"
#include "SearchDataRemoval.h"
#include "SearchViewRemoval.h"
#include "MenuEntry.h"

#pragma mark - 编译检查入口

// 非 static 的全局函数（只为了被链接期引用，不运行、不注册）：把每个组件的对外入口
// 各调一次，让五个 header 里全部 static 函数/安装器都被引用到。
void BDNadUICompileCheck(UIViewController *host, NSURL *logURL) {
    BDFRInstallAll();                        // 首页推荐/游戏中心/金刚区求职小说
    BDPRInstallData();                       // 「我的」活动轮播 + 推广整排
    BDPVInstallAll();                        // 「我的」任务卡两条 -layoutViews
    BDRBInstallAll();                        // 「去续费」按钮三条 vipButton
    BDTRInstallAll();                        // 底部「库库AI」tab 过滤 + 索引换算
    BDSRInstallData();                       // 搜索框轮播词数据层
    BDSRInstallView();                       // 搜索框 UI 层三条 post-hook（整组校验）
    BDMEInstallAll();                        // 设置页导航条「网盘净化」入口
    BDPresentPurificationSettings(host, logURL);   // 菜单入口的真实签名
}