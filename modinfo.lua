local L = locale ~= "zh" and locale ~= "zhr" -- true 英文  false 中文
local Loc = function(eng, chi) return L and eng or chi end


version = '1.3.8'
local log = {
    "v1.3.7 更新：减少了网络带宽的占用和服务器的性能消耗。",
    "v1.3.8 更新：通过引入缓存来解决服务器卡顿问题。",
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
    }
}

bugtracker_config = {
    email = "zao44457660@hotmail.com",
    upload_client_log = true,
    upload_server_log = true
}
