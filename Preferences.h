// BDNadBlock — 净化设置的唯一规格表 + 读写原语（Foundation only，无自定义配置类）
//
// 本文件是**唯一**的默认值来源：规格表 BDNadPrefsSpecs[i].defaultValue。
// 别在别处再抄一份默认值（SettingsMenu.h 从表里取标题与分组）。
//
// 语义（与调用方议定，改这里等于改行为）：
//   - 未知 key：读取 fail-closed 返回 NO，写入拒绝；不反射调用任意 selector；
//   - 已知 key 但存了不合适的类型（数组/字典/Data 等容器，或日期等非 bool 的 plist 值）：
//     退回规格默认，不崩；
//   - 旧版用户值可能是 NSString（"0"/"1"/"true"），boolValue 一律接受；
//   - 只读写 NSUserDefaults：仅写本组件固定键，不修改账号、缓存或原生偏好；
//     不 synchronize、不碰 plist 文件、不删 unknown 键；
//   - 进程启动快照只建一次（dispatch_once），运行期 active 读取一律走快照：
//     设置里改值只影响“下次冷启动”，不改当前进程，不热改、不重启 App。
//
// 被 Tweak.xm（经 SettingsMenu.h）与 tests/preferences_test.mm 以单一 TU 形式 include。
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_PREFERENCES_H
#define BDNAD_PREFERENCES_H

#import <Foundation/Foundation.h>

#pragma mark - 规格表

typedef NS_ENUM(NSInteger, BDNadPrefsGroup) {
    BDNadPrefsGroupMaster = 0,   // 总开关
    BDNadPrefsGroupHome,         // 首页
    BDNadPrefsGroupPersonal,     // 我的
    BDNadPrefsGroupAds,          // 广告
    BDNadPrefsGroupDiagnostics,  // 诊断
};

// key = 固定存储键；title = 菜单中文标题（开关 ON 代表“去除/拦截”）。
typedef struct {
    const char *key;
    const char *title;
    BOOL defaultValue;
    BDNadPrefsGroup group;
} BDNadPrefsSpec;

static const BDNadPrefsSpec BDNadPrefsSpecs[] = {
    // 总开关
    {"BDNadBlockEnabled",          "启用网盘净化",           YES, BDNadPrefsGroupMaster},
    // 首页
    {"BDRemoveRecommend",          "隐藏推荐/创意区域",      YES, BDNadPrefsGroupHome},
    {"BDRemoveAITab",              "隐藏底部库库AI",         YES, BDNadPrefsGroupHome},
    {"BDRemoveJobNovel",           "隐藏求职/小说入口",      YES, BDNadPrefsGroupHome},
    {"BDRemoveSearchPromo",        "隐藏搜索推广词",         YES, BDNadPrefsGroupHome},
    {"BDRemoveSearchAI",           "隐藏搜索框AI按钮",       YES, BDNadPrefsGroupHome},
    // 实验项：默认关闭，独立 key
    {"BDExperimentHideHomeBanner", "隐藏顶部横幅容器·实验",   NO,  BDNadPrefsGroupHome},
    // 我的
    {"BDRemoveGameCenter",         "隐藏游戏中心",           YES, BDNadPrefsGroupPersonal},
    {"BDRemovePersonalPromotions", "隐藏推广入口整排",       YES, BDNadPrefsGroupPersonal},
    {"BDRemovePersonalBanner",     "隐藏活动轮播",           YES, BDNadPrefsGroupPersonal},
    {"BDRemoveTaskCard",           "隐藏任务系统卡片",       YES, BDNadPrefsGroupPersonal},
    {"BDRemovePersonalSpaceCard",  "隐藏容量管理卡片",       YES, BDNadPrefsGroupPersonal},
    {"BDRemoveRenewButton",        "隐藏续费按钮",           NO,  BDNadPrefsGroupPersonal},
    // 广告
    {"BDNadBlockNetwork",          "广告网络拦截·旧规则",    YES, BDNadPrefsGroupAds},
    {"BDNadBlockAdMethods",        "广告展示拦截·实验",      YES, BDNadPrefsGroupAds},
    // 传输页推广（一刻相册是行内推广、小游戏是引导，不都在页面底部）
    {"BDRemoveTransferYikePromo",  "隐藏传输页一刻相册",     YES, BDNadPrefsGroupAds},
    {"BDRemoveTransferGamePromo",  "隐藏下载小游戏引导",     YES, BDNadPrefsGroupAds},
    {"BDRemoveTransferCardPromo",  "隐藏免流办卡推广",       YES, BDNadPrefsGroupAds},
    // 传输/下载页底部 widget 的另外两条：数据包(流量包)付费引导、加速试用商品引导
    {"BDRemoveTransferDataPromo",  "隐藏流量包付费引导",     YES, BDNadPrefsGroupAds},
    {"BDRemoveTransferTrialPromo", "隐藏加速试用促销",       YES, BDNadPrefsGroupAds},
    // 诊断
    {"BDNadBlockDumpOnly",         "仅诊断，不执行净化",     NO,  BDNadPrefsGroupDiagnostics},
};

static const NSUInteger BDNadPrefsSpecCount = sizeof(BDNadPrefsSpecs) / sizeof(BDNadPrefsSpecs[0]);

#pragma mark - 规格查询

// 已知 key 才返回规格；未知返回 NULL（调用方据此 fail-closed，不做任何反射）。
static inline const BDNadPrefsSpec *BDNadPrefsSpecForKey(NSString *key) {
    if (!key) return NULL;
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++)
        if ([key isEqualToString:@(BDNadPrefsSpecs[i].key)]) return &BDNadPrefsSpecs[i];
    return NULL;
}

static inline NSString *BDNadPrefsGroupTitle(BDNadPrefsGroup group) {
    switch (group) {
        case BDNadPrefsGroupMaster:      return @"总开关";
        case BDNadPrefsGroupHome:        return @"首页";
        case BDNadPrefsGroupPersonal:    return @"我的";
        case BDNadPrefsGroupAds:         return @"广告";
        case BDNadPrefsGroupDiagnostics: return @"诊断";
    }
    return @"";
}

#pragma mark - 期望值读 / 写（defaults 可注入，测试用 isolated suite）

// 期望（已保存）值：未知 key -> NO；类型不合适（容器/日期等）-> 规格默认；nil defaults -> 规格默认。
static inline BOOL BDNadPrefsDesired(NSUserDefaults *defaults, NSString *key) {
    const BDNadPrefsSpec *spec = BDNadPrefsSpecForKey(key);
    if (!spec) return NO;
    id v = defaults ? [defaults objectForKey:key] : nil;
    if (!v) return spec->defaultValue;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue];   // 旧版可能存字符串
    return spec->defaultValue;                                      // 数组/字典/Data/日期等
}

// 只允许写 known key（返回 NO = 拒绝，不落任何值）。不 synchronize。
// defaults 必须显式传入（菜单传 standardUserDefaults）：避免误写到别的域。
static inline BOOL BDNadPrefsSetDesired(NSUserDefaults *defaults, NSString *key, BOOL value) {
    if (!defaults || !BDNadPrefsSpecForKey(key)) return NO;
    [defaults setBool:value forKey:key];
    return YES;
}

#pragma mark - 启动快照

// 纯函数：按规格表顺序读一遍，返回 immutable 快照。测试里可多次调用以模拟“下一次冷启动”的读取。
static inline NSDictionary<NSString *, NSNumber *> *BDNadPrefsSnapshot(NSUserDefaults *defaults) {
    NSMutableDictionary<NSString *, NSNumber *> *d = [NSMutableDictionary dictionaryWithCapacity:BDNadPrefsSpecCount];
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
        NSString *k = @(BDNadPrefsSpecs[i].key);
        d[k] = @(BDNadPrefsDesired(defaults, k));
    }
    return [d copy];
}

// 进程级启动快照：只建一次；之后 active 读取永远走它，菜单改值不改当前进程。
static inline NSDictionary<NSString *, NSNumber *> *BDNadPrefsGlobalSnapshot(void) {
    static NSDictionary<NSString *, NSNumber *> *snapshot = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        snapshot = BDNadPrefsSnapshot([NSUserDefaults standardUserDefaults]);
    });
    return snapshot;
}

// 启动时调一次，把快照建在页面组装之前（也可不调，第一次 active 读取会惰性建）。
static inline void BDNadPrefsInit(void) { (void)BDNadPrefsGlobalSnapshot(); }

// 当前进程生效值（快照）。未知 key -> NO。
static inline BOOL BDNadPrefsActive(NSString *key) {
    if (!BDNadPrefsSpecForKey(key)) return NO;
    NSNumber *n = BDNadPrefsGlobalSnapshot()[key];
    return n ? n.boolValue : NO;
}

// 菜单用：是否有改动要等下个冷启动才生效（saved != active）。
static inline BOOL BDNadPrefsHasPendingChanges(void) {
    NSUserDefaults *live = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, NSNumber *> *snap = BDNadPrefsGlobalSnapshot();
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
        NSString *k = @(BDNadPrefsSpecs[i].key);
        if (BDNadPrefsDesired(live, k) != snap[k].boolValue) return YES;
    }
    return NO;
}

#endif
