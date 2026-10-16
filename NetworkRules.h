// BDNadBlock — 网络拦截规则（Foundation only，纯匹配，无状态、无 SDK、无新库）
//
// 单独一个文件的原因：同一份实现被 Tweak.xm 与 tests/network_rules_test.mm include，
// 测试跑的是真实 matcher，不用在测试里抄一份算法。单 TU static，不开线程、不碰网络。
//
// 开关由调用方以同名静态函数提供（Tweak.xm 里定义，测试用内存假开关）：
//   BDBlockNetwork()       总门：总开关 && !dumpOnly && 网络拦截开关；不通过一律不拦
//   BDRemoveGameCenter()   我的页游戏中心（接口 + 资源路径），独立开关
//   BDRemoveSearchPromo()  搜索框底部推广词，独立于首页推荐
//   BDRemoveRecommend()    记忆中心推荐卡片
// 总门放在最前：总开关关或 dump-only 时，本 matcher 对所有 host / path 都返回 nil。
//
// 证据范围：所有规则都经 2026-10-15 Loon 抓包（632 条请求）逐条看响应体定性。
// 命中规则 / 安装 hook 不等于功能已移除；真机网络行为仍需实测。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释，吞掉后面的代码。

#ifndef BDNAD_NETWORK_RULES_H
#define BDNAD_NETWORK_RULES_H

#import <Foundation/Foundation.h>

#pragma mark - 规则表

// 整个 host 都是广告链路
static const char *BDHostRules[] = {
    // 趣盟广告 SDK
    "cpc-service-square.yunxish.com",
    "cpc-service-square.iggrowth.cn",
    "logrcv.yunxish.com",
    "show-api.yunxish.com",
    "usr-api.yunxish.com",
    "service.yunxish.com",
    "tracelog-debug.yunxish.com",
    // 百度自有：广告开关 / 点击归因 / 营销云
    "afdconf.baidu.com",
    "nsclick.baidu.com",
    "sofire.baidu.com",
    "huiduapi.nuomi.com",
    // 第三方联盟
    "ef-dongfeng.tanx.com",
    "tnc3-alisc1.zijieapi.com",
    "mssdk.volces.com",
    // 当贝 / 酷开 广告 SDK（logu.hpplay.cn:8856 的 host 相同，一条覆盖）
    "conf.hpplay.cn",
    "vfa.hpplay.cn",
    "ssdkauth.hpplay.cn",
    "logu.hpplay.cn",
};

// host + 路径前缀
typedef struct { const char *host; const char *path; const char *tag; } BDPathRule;
static const BDPathRule BDPathRules[] = {
    // 首页 banner 广告。响应实测：adList[0].title="双十一上淘宝"，
    // actionUrl=https://ulk.alimama.com/tb?...（淘宝联盟）
    {"pan.baidu.com", "/buy/ad/",          "ad-banner"},
    // 激励任务广告。响应实测：scene_list[].task_list[].complete_notice
    // ="恭喜获得1次音频倍速播放机会"
    {"pan.baidu.com", "/rest/2.0/pcs/adv", "ad-task"},
};

// 只看路径、不看 host：这批素材会走 P2P 加速镜像，
// host 每台设备都不一样（antpcdn.com:19001 / jomoxc.com:9082 / yingt.asia:9549），
// 拦 host 会连静态资源一起打死，所以只能按路径判。
static const char *BDAnyPathRules[] = {
    "/gamecenter/",    // ndstatic.cdn.bcebos.com 的 gameCenter 目录
    "_swan-game_",     // spcsz.cdn.bcebos.com 的 cmpkg 里的 swan 游戏包
    // 注意不要拦 cmpkg 整目录或 1_swan-core —— 那是小程序运行时
};

#pragma mark - 匹配

static NSString *BDMatchNetwork(NSString *host, NSString *path) {
    if (!host.length || !BDBlockNetwork()) return nil;
    host = host.lowercaseString;
    NSString *lp = path.lowercaseString ?: @"";

    for (unsigned i = 0; i < sizeof(BDHostRules)/sizeof(BDHostRules[0]); i++)
        if ([host isEqualToString:@(BDHostRules[i])]) return @"ad-host";

    for (unsigned i = 0; i < sizeof(BDPathRules)/sizeof(BDPathRules[0]); i++)
        if ([host isEqualToString:@(BDPathRules[i].host)] &&
            [lp hasPrefix:@(BDPathRules[i].path)])
            return @(BDPathRules[i].tag);

    if ([host isEqualToString:@"pan.baidu.com"] &&
        [lp hasPrefix:@"/act/v2/gamecenter"])
        return BDRemoveGameCenter() ? @"game-center-api" : nil;

    if (BDRemoveGameCenter())
        for (unsigned i = 0; i < sizeof(BDAnyPathRules)/sizeof(BDAnyPathRules[0]); i++)
            if ([lp containsString:@(BDAnyPathRules[i])]) return @"game-center-asset";

    // 搜索框底部推荐词。抓包实测只有 /recommend/searchbox/bottom 这一条返回 6 条 show_query，
    // 旧的 /recommend/ 泛前缀会把同一前缀下的其它接口一起拦掉，所以收到精确路径：
    // 只有 等值 或 末尾多一个 斜杠 两种写法命中，不含任何子路径。
    // （/recommend/searchbox/bottomFake 和 /recommend/searchbox/bottom/next 都不匹配。）
    // 独立开关：首页推荐（BDRemoveRecommend）不该把这条一起屏蔽，反之亦然。
    if (BDRemoveSearchPromo() && [host isEqualToString:@"pan.baidu.com"] &&
        ([lp isEqualToString:@"/recommend/searchbox/bottom"] ||
         [lp isEqualToString:@"/recommend/searchbox/bottom/"]))
        return @"search-promo-api";

    // 记忆中心推荐卡片
    if (BDRemoveRecommend() && [host isEqualToString:@"pan.baidu.com"] &&
        [lp hasPrefix:@"/aisearch/agent/memorycenter/getrecommendcards"])
        return @"recommend-api";

    return nil;
}

#endif
