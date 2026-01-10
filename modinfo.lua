local L = locale ~= "zh" and locale ~= "zhr" -- true 英文  false 中文
local Loc = function(eng, chi) return L and eng or chi end


version = '1.3.11'
local log = {
    Loc("v1.3.7 Update: Reduce network bandwidth consumption and server performance consumption.","v1.3.7 更新：减少了网络带宽的占用和服务器的性能消耗。"),
    Loc("v1.3.8 Update: Solve server lag problem by introducing cache.","v1.3.8 更新：通过引入缓存来解决服务器卡顿问题。"),
    Loc("v1.3.8 Update: Optimize performance by introducing cache refresh time.","v1.3.8 更新：通过引入缓存刷新时间来优化性能。"),
    Loc("v1.3.9 Update: Fix some bugs.","v1.3.9 更新：修复了一些bug。"),
    Loc("v1.3.10 Update: Optimize performance, reduce the possibility of crash caused by nil value.","v1.3.10 更新：优化了性能，减少了可能因为空值导致的闪退。"),
    Loc("v1.3.11 Update: Fix nil value crash.","v1.3.11 更新：修复空值造成的崩溃问题。"),
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
    -- {
    --     name ="KEEP_ONE",
    --     label = Loc("Keep One Material","保留一个材料"),
    --     options = {
    --         { description = Loc("No","否"), data = false },
    --         { description = Loc("Yes","是"), data = true },
    --     },
    --     default = false
    -- },
}

bugtracker_config = {
    email = "zao44457660@hotmail.com",
    upload_client_log = true,
    upload_server_log = true
}
