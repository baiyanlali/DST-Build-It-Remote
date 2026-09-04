local L = locale ~= "zh" and locale ~= "zhr" -- true 英文  false 中文
local Loc = function(eng, chi) return L and eng or chi end


version = '1.3.17'
local log = {
    Loc("v1.3.7 Update: Reduce network bandwidth consumption and server performance consumption.","v1.3.7 更新：减少了网络带宽的占用和服务器的性能消耗。"),
    Loc("v1.3.8 Update: Solve server lag problem by introducing cache.","v1.3.8 更新：通过引入缓存来解决服务器卡顿问题。"),
    Loc("v1.3.8 Update: Optimize performance by introducing cache refresh time.","v1.3.8 更新：通过引入缓存刷新时间来优化性能。"),
    Loc("v1.3.9 Update: Fix some bugs.","v1.3.9 更新：修复了一些bug。"),
    Loc("v1.3.10 Update: Optimize performance, reduce the possibility of crash caused by nil value.","v1.3.10 更新：优化了性能，减少了可能因为空值导致的闪退。"),
    Loc("v1.3.11 Update: Add option to keep one material (not available now).","v1.3.11 更新：增加材料保留一个的选项（暂不可用）。"),
    Loc("v1.3.12 Update:  Rewrite logic codes.","v1.3.12 更新：重写部分代码，希望运行能更稳定。"),
    Loc("v1.3.13 Update:  Fix bug that some ingredients can not be found.","v1.3.13 更新：修复部分物体查找不到的 bug。"),
    Loc("v1.3.14 Update:  Fix prefab nil issue","v1.3.14 更新：修复 prefab 为空的 issue。"),
    Loc("v1.3.15 Update:  Fix container type nil issue","v1.3.15 更新：修复 container type 为空的 issue。"),
    Loc("v1.3.16 Update:  Fix container ingredient won't be consumed issue","v1.3.16 更新：修复 container ingredient 无法被消耗的 issue。"),
    Loc("v1.3.17 Update:  Fixed the bug where items could be crafted without consuming materials, and greatly reduced lag.",
        "v1.3.17 更新：修复了造物时有概率不消耗材料的 bug，并大幅优化了卡顿。"),
    Loc("        - Ingredient lookup no longer leaks into non-crafting checks (Wortox souls, rope bridges, pumpkin carving...), which was letting those abilities trigger for free.",
        "        - 材料查找不再污染非合成类的检查（沃拓克斯灵魂、绳桥、雕刻南瓜等），此前这些功能会出现\"生效但不扣材料\"。"),
    Loc("        - Destroyed/burnt chests are no longer counted as valid material sources within the cache window.",
        "        - 箱子被烧毁或拆除后，不会再在缓存有效期内被当成有效的材料来源（幽灵材料）。"),
    Loc("        - Ingredient removal now goes through the container that actually holds the item.",
        "        - 扣除材料时改为定位物品真正所在的容器再扣，不再依赖失效的判断分支。"),
    Loc("        - Fixed double-counting of already-opened chests in the crafting UI.",
        "        - 修复已打开的箱子在合成界面被重复计数的问题。"),
    Loc("        - Crafting menu ingredient queries are now cached per tick (~50x faster).",
        "        - 合成菜单的材料查询改为按帧聚合缓存（实测快约 50 倍）。"),
    Loc("        - Container sync is now coalesced per frame and skipped when unchanged; string length is capped to avoid truncation.",
        "        - 容器同步改为每帧合并、内容未变则不发送，并限制长度避免网络字符串被截断。"),
}

local function updateLog()
    local updatedLog = ""

    for i = #log, 1, -1 do
        updatedLog = updatedLog .. "\n" .. log[i]
    end
    return updatedLog
end

description = Loc(
    'We can build an item using nearby chests, instead of grabbing items in chest to bag and use it. Version '..version..".",
[[你是否有过要建造一些物品，但是原料在箱子里懒得拿出来，或是背包太满腾不出空间放原料的伤心经历？
这是量子造物mod！它可以自动探查并使用你周围箱子里面的原料来建造物品。终于不用背一堆木头了~
版本:]]..version.."\n"..updateLog())
author = Loc('Baiyan','白炎拉力')
name = Loc('Build It From Chest', '量子建造')

api_version = 10

dst_compatible = true

all_clients_require_mod = true

icon_atlas = "builditremote.xml"
icon = "builditremote.tex"


configuration_options = {
    {
        name ="MAX_RANGE",
        label = Loc("Maximum Search Range","最大探查范围"),
        options = {
            { description = "5", data = 5 },
            { description = "10", data = 10 },
            { description = "30", data = 30 },
            { description = "50", data = 50 },
        },
        default = 5
    },
    {
        name ="REFRESH_TIME",
        label = Loc("Refresh Time","刷新时间"),
        options = {
            { description = "0.5", data = 0.5 },
            { description = "1", data = 1 },
            { description = "3", data = 3 },
            { description = "5", data = 5 },
        },
        default = 5
    },
    {
        name ="KEEP_ONE",
        label = Loc("Keep One Material (not available)","保留一个材料(暂不可用)"),
        options = {
            { description = Loc("No","否"), data = false },
            { description = Loc("Yes","是"), data = true },
        },
        default = false
    },
}

bugtracker_config = {
    email = "zao44457660@hotmail.com",
    upload_client_log = true,
    upload_server_log = true
}
