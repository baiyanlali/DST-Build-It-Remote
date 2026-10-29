local _G = GLOBAL
local TheSim = _G.TheSim
local TheNet = _G.TheNet

local tonumber = _G.tonumber
local tostring = _G.tostring
local pairs = _G.pairs
local ipairs = _G.ipairs
local type = _G.type
local math = _G.math
local table = _G.table
local GetTime = _G.GetTime

local MAX_SEARCH_RANGE = GetModConfigData("MAX_RANGE") or 5
local REFRESH_TIME = GetModConfigData("REFRESH_TIME") or 5
local KEEP_ONE = GetModConfigData("KEEP_ONE")

local IsServer = TheNet:GetIsServer()
local IsDedicated = TheNet:IsDedicated()
local IsClient = TheNet:GetIsClient()

local Highlight = _G.require 'components/highlight'
local __Highlight_ApplyColour = Highlight.ApplyColour
local __Highlight_UnHighlight = Highlight.UnHighlight

local DEBUG_MODE = false

local function debug_print(msg)
    if DEBUG_MODE then
        print("[BuildItRemote] \n" .. msg .. "\n END")
    end
end

local c = { r = .5, g = 0, b = 0 }

-- highlit 用纯数组，方便整表替换
local highlit = {}

local FIND_MUST_TAGS = { "_container" }
local FIND_CANT_TAGS = { "NOBLOCK", "player", "FX" }

local EMPTY_TABLE = {}

-- may cause bug by item.replica is nil. It happens when item is given by some NPC? I don't know really. But it may work now.
local function Count(item)
    if not item then
        return 0
    end
    if item.components and item.components.stackable then
        return item.components.stackable:StackSize() or 1
    elseif item.replica and item.replica.stackable then
        return item.replica.stackable:StackSize() or 1
    else
        return 1
    end
end

--[[
    These two functions are from mod Find It.
    Please check it out and subscribe it if you like!
]]
local function custom_ApplyColour(self, ...)
    local r, g, b = (self.base_add_colour_red or 0), (self.base_add_colour_green or 0), (self.base_add_colour_blue or 0)

    self.base_add_colour_red, self.base_add_colour_green, self.base_add_colour_blue = r + c.r, g + c.g, b + c.b

    local result = __Highlight_ApplyColour(self, ...)

    self.base_add_colour_red, self.base_add_colour_green, self.base_add_colour_blue = r, g, b

    return result
end

local function custom_UnHighlight(self, ...)
    local flashing = self.flashing
    self.flashing = true
    local result = __Highlight_UnHighlight(self, ...)
    self.flashing = flashing

    if not self.flashing then
        local r, g, b = (self.highlight_add_colour_red or 0), (self.highlight_add_colour_green or 0),
            (self.highlight_add_colour_blue or 0)

        self.highlight_add_colour_red, self.highlight_add_colour_green, self.highlight_add_colour_blue = 0, 0, 0

        self:ApplyColour()

        self.highlight_add_colour_red, self.highlight_add_colour_green, self.highlight_add_colour_blue = r, g, b
    end

    return result
end

-----------------------------------------------------------------
-- 周围容器的查询与缓存
--
-- cache 采用弱键表，玩家实体销毁后自动回收，不再需要一个全局
-- DoPeriodicTask 去清空整表（那会让所有玩家在同一帧集体 cache miss）。
-- 每个玩家两级缓存：
--   entry.chests  : 容器实体列表，TTL = REFRESH_TIME
--   entry.counts  : prefab -> 总数 的聚合字典，TTL = 一个 tick
-- counts 是关键性能优化：合成菜单刷新时会对上千个配方逐个材料调 Has，
-- 原实现每次都要 遍历箱子 x 遍历槽位，这里降为每 tick 全扫一次、之后 O(1)。
-----------------------------------------------------------------

-- 注意：DST 的 mod 沙箱（CreateEnvironment）不提供 setmetatable 等标准库全局函数，
-- 必须经由 GLOBAL（真实全局表）访问，否则加载时直接报 "attempt to call global 'setmetatable' (a nil value)"
local cache = _G.setmetatable({}, { __mode = "k" })

local function InvalidateCounts(inst)
    local entry = inst ~= nil and cache[inst] or nil
    if entry ~= nil then
        entry.counts = nil
        entry.counts_t = nil
    end
end

local function GetSurroundingContainers(inst)
    if inst == nil or inst.Transform == nil or not inst:IsValid() then
        return EMPTY_TABLE
    end

    local now = GetTime()
    local entry = cache[inst]
    local x, y, z = inst.Transform:GetWorldPosition()

    -- 移动后不能沿用原位置的箱子列表，尤其不能缓存“附近没有箱子”。
    if entry ~= nil and entry.chests ~= nil and now - entry.chests_t < REFRESH_TIME
        and entry.x == x and entry.z == z then
        return entry.chests
    end

    local ents = TheSim:FindEntities(x, y, z, MAX_SEARCH_RANGE, FIND_MUST_TAGS, FIND_CANT_TAGS)

    local chests = {}
    local n = 0
    for i = 1, #ents do
        local v = ents[i]
        -- 口袋维度容器（shadow_container 等）不支持作为材料源：它固定停在 (0,0,0)，
        -- 打开暗影切斯特时若被当成附近箱子，会直接消耗全队共享的暗影存储。
        if v:IsValid() and v.entity:IsVisible() and not v:HasTag("pocketdimension_container")
            and v.replica ~= nil and v.replica.container ~= nil then
            n = n + 1
            chests[n] = v
        end
    end

    if entry == nil then
        entry = {}
        cache[inst] = entry
    end
    entry.chests = chests
    entry.chests_t = now
    entry.x, entry.z = x, z
    entry.counts = nil
    entry.counts_t = nil

    return chests
end

-- 缓存里的箱子可能在 TTL 内被烧掉 / 锤掉 / 卸载。
-- 不做校验就会把已销毁实体上的残留物品当成有效材料（"幽灵材料"），
-- 这是 "有概率不消耗原材料" 的主要来源之一。
local function IsChestUsable(chest)
    return chest ~= nil
        and chest:IsValid()
        and chest.entity:IsVisible()
        and chest.components ~= nil
end

-- 服务端：取出真正可用于合成的 container / inventory 组件
local function GetChestContainer(chest)
    if not IsChestUsable(chest) then
        return nil
    end
    local container = chest.components.container or chest.components.inventory
    if container == nil then
        return nil
    end
    if container.excludefromcrafting or container.readonlycontainer then
        return nil
    end
    return container
end

-- 客户端：取出 container_replica
local function GetChestContainerReplica(chest)
    if chest == nil or not chest:IsValid() or not chest.entity:IsVisible() or chest.replica == nil then
        return nil
    end
    local container = chest.replica.container
    if container == nil then
        return nil
    end
    if container.IsReadOnlyContainer ~= nil and container:IsReadOnlyContainer() then
        return nil
    end
    return container
end

-- 制作栏关闭时固定栏也需要更新。只在附近材料总量变化时发送原生事件，
-- 让“降低客户端卡顿”等 UI 优化模组继续自行决定重算哪些配方。
local function RefreshNearbyCrafting(player)
    if player ~= _G.ThePlayer or not player:IsValid() or player.HUD == nil then
        return
    end

    local counts = {}
    local chests = GetSurroundingContainers(player)
    for i = 1, #chests do
        local chest = chests[i]
        local container = GetChestContainer(chest)
        if container ~= nil then
            for _, item in pairs(container.slots or container.itemslots or EMPTY_TABLE) do
                if item ~= nil and item.prefab ~= nil and item:IsValid() and not item:HasTag("nocrafting") then
                    counts[item.prefab] = (counts[item.prefab] or 0) + Count(item)
                end
            end
        elseif GetChestContainerReplica(chest) ~= nil then
            for prefab, n in pairs(chest.buffered_items or EMPTY_TABLE) do
                counts[prefab] = (counts[prefab] or 0) + n
            end
        end
    end

    local entry = cache[player]
    if entry == nil then
        return
    end
    local previous = entry.refresh_counts or EMPTY_TABLE
    local changed = false
    for prefab, n in pairs(counts) do
        if previous[prefab] ~= n then changed = true; break end
    end
    if not changed then
        for prefab, n in pairs(previous) do
            if counts[prefab] ~= n then changed = true; break end
        end
    end
    entry.refresh_counts = counts
    if changed then
        InvalidateCounts(player)
        player:PushEvent("refreshcrafting")
    end
end

local function QueueNearbyCraftingRefresh(chest)
    local player = _G.ThePlayer
    if player == nil or not player:IsValid() or player.Transform == nil then
        return
    end
    -- 口袋维度容器（shadow_container）的客户端副本没有 Transform，不能假设容器实体一定有世界坐标。
    if chest == nil or not chest:IsValid() or chest.Transform == nil then
        return
    end
    local x, _, z = player.Transform:GetWorldPosition()
    local cx, _, cz = chest.Transform:GetWorldPosition()
    if (cx - x)^2 + (cz - z)^2 > MAX_SEARCH_RANGE^2 then
        return
    end
    -- 新加载的箱子可能尚未在列表中；同帧内的后续材料查询也必须读到新数据。
    local entry = cache[player]
    if entry ~= nil then
        entry.chests = nil
        InvalidateCounts(player)
    end
    if player._birt_refresh_task == nil then
        player._birt_refresh_task = player:DoTaskInTime(0, function(inst)
            inst._birt_refresh_task = nil
            RefreshNearbyCrafting(inst)
        end)
    end
end

-- 遍历周围箱子时统一的跳过规则：
-- 已被自己打开的容器 / 自己的背包(overflow) 由原生逻辑负责统计，
-- 这里必须跳过，否则会重复计数。
local function ShouldSkipChest(chest, opencontainers, overflow_inst)
    if opencontainers ~= nil and opencontainers[chest] then
        return true
    end
    if overflow_inst ~= nil and chest == overflow_inst then
        return true
    end
    return false
end

-- 聚合 prefab -> 数量，按 tick 缓存
local function GetSurroundingCounts(inventory)
    local inst = inventory.inst
    local chests = GetSurroundingContainers(inst)
    local entry = cache[inst]
    if entry == nil then
        return EMPTY_TABLE
    end

    local now = GetTime()
    if entry.counts ~= nil and entry.counts_t == now then
        return entry.counts
    end

    local counts = {}
    local overflow = inventory:GetOverflowContainer()
    local overflow_inst = overflow ~= nil and overflow.inst or nil
    -- 服务端 Inventory 用 opencontainers 字段；客户端 Inventory_Replica 只有 GetOpenContainers()。
    -- 两端的 Has 都靠这里跳过「打开着的容器」，因为它们已由原版统计，不能再算一遍。
    local opencontainers = inventory.opencontainers
    if opencontainers == nil and inventory.GetOpenContainers ~= nil then
        opencontainers = inventory:GetOpenContainers()
    end

    for i = 1, #chests do
        local chest = chests[i]
        if not ShouldSkipChest(chest, opencontainers, overflow_inst) then
            local container = GetChestContainer(chest)
            if container ~= nil and container ~= overflow then
                local slots = container.slots or container.itemslots
                if slots ~= nil then
                    for _, v in pairs(slots) do
                        -- v:IsValid() 过滤已销毁的物品，避免幽灵材料
                        if v ~= nil and v.prefab ~= nil and v:IsValid() and not v:HasTag("nocrafting") then
                            counts[v.prefab] = (counts[v.prefab] or 0) + Count(v)
                        end
                    end
                end
            elseif GetChestContainerReplica(chest) ~= nil then
                -- 客户端：未打开的箱子读服务端广播的快照
                for prefab, n in pairs(chest.buffered_items or EMPTY_TABLE) do
                    counts[prefab] = (counts[prefab] or 0) + n
                end
            end
        end
    end

    entry.counts = counts
    entry.counts_t = now
    return counts
end

local function HighlightContainer(v)
    if not v or not v.components then
        return
    end
    if not v.components.highlight then
        v:AddComponent('highlight')
    end
    if v.components.highlight then
        highlit[#highlit + 1] = v
        v.components.highlight.ApplyColour = custom_ApplyColour
        v.components.highlight.UnHighlight = custom_UnHighlight
        v.components.highlight:Highlight(0, 0, 0)
    end
end

local function unlightall()
    if #highlit == 0 then
        return
    end

    local to_process = highlit
    highlit = {}

    for i = 1, #to_process do
        local v = to_process[i]
        if v and v:IsValid() and v.components and v.components.highlight then
            if v.components.highlight.ApplyColour == custom_ApplyColour then
                v.components.highlight.ApplyColour = nil
            end

            if v.components.highlight.UnHighlight == custom_UnHighlight then
                v.components.highlight.UnHighlight = nil
            end

            v.components.highlight:UnHighlight()
        end
    end
end

-----------------------------------------------------------------
-- REMAKE SOME FUNCTIONS IN INGREDIENT
-----------------------------------------------------------------
do

    AddComponentPostInit("inventory", function(self)

        -----------------------------------------------------------
        -- Has
        -- 仅在 checkallcontainers == true（合成语境）时扩展。
        -- 原实现无条件扩展，导致 Wortox 灵魂、绳桥、雕刻南瓜、猪人代币
        -- 等只传两个参数的 Has 检查也算上了箱子里的东西 —— 但这些系统
        -- 的扣除逻辑并不认箱子，于是出现 "检查通过、效果生效、材料不扣"。
        -----------------------------------------------------------
        local oldHas = self.Has

        self.Has = function(self, item, amount, checkallcontainers)
            local has_enough, num_found = oldHas(self, item, amount, checkallcontainers)

            -- 不能因为「手上 + 已打开容器已够」就提前返回：那样 num_found 只含打开容器，
            -- 制作栏显示的数量会被打开容器“覆盖”（附近箱子里的不计入）。
            -- GetSurroundingCounts 按 tick 缓存，这里只是 O(1) 查表，不会变慢。
            if not checkallcontainers then
                return has_enough, num_found
            end

            local counts = GetSurroundingCounts(self)
            num_found = num_found + (counts[item] or 0)

            return num_found >= amount, num_found
        end

        -----------------------------------------------------------
        -- RemoveItem
        -- 原实现用 `oldRemoveItem(...) ~= nil` 判断"是否已成功移除"，
        -- 但原生 Inventory:RemoveItem 在找不到物品时会 `return item`
        -- （container.lua / inventory.lua 尾部），永远不返回 nil，
        -- 所以后面遍历箱子的整段代码是死代码，从未执行过。
        -- 这里改为先按 inventoryitem.owner 定位物品真正所在的容器，
        -- 再交给对应容器的 RemoveItem 去扣。
        -----------------------------------------------------------
        local oldRemoveItem = self.RemoveItem

        self.RemoveItem = function(self, item, wholestack, checkallcontainers, keepoverstacked)
            if item == nil then
                return
            end

            local invitem = item.components ~= nil and item.components.inventoryitem or nil
            local owner = invitem ~= nil and invitem.owner or nil

            -- 物品就在自己身上（背包 / 装备栏 / 鼠标 / 地上）→ 走原生逻辑
            if owner == nil or owner == self.inst then
                return oldRemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)
            end

            -- 自己的背包（overflow）或自己已打开的容器 → 原生逻辑已覆盖
            local overflow = self:GetOverflowContainer()
            if overflow ~= nil and overflow.inst == owner then
                return oldRemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)
            end
            if self.opencontainers ~= nil and self.opencontainers[owner] then
                return oldRemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)
            end

            -- 物品在周围的箱子里 → 从真正持有它的容器扣
            local chests = GetSurroundingContainers(self.inst)
            for i = 1, #chests do
                if chests[i] == owner then
                    local container = GetChestContainer(owner)
                    if container ~= nil
                        and container.GetItemSlot ~= nil
                        and container:GetItemSlot(item) ~= nil
                    then
                        local removed = container:RemoveItem(item, wholestack, nil, keepoverstacked)
                        InvalidateCounts(self.inst)
                        if removed ~= nil then
                            debug_print("RemoveItem from chest " .. tostring(owner.prefab) ..
                                ": " .. tostring(item.prefab))
                            return removed
                        end
                    end
                    break
                end
            end

            return oldRemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)
        end

        -----------------------------------------------------------
        -- GetCraftingIngredient
        -- 修正三点：
        --   1. 不覆盖已有条目（原来的 crafting_items[k] = v 会把原生
        --      算好的数量顶掉，同时 total_num_found 重复累加 → 取料不齐）
        --   2. 过滤 v <= 0 与已销毁实体
        --   3. 跳过 overflow / 已打开容器时口径与 Has 保持一致
        -----------------------------------------------------------
        local oldGetCraftingIngredient = self.GetCraftingIngredient

        self.GetCraftingIngredient = function(self, item, amount)
            local crafting_items = oldGetCraftingIngredient(self, item, amount) or {}

            local total_num_found = 0
            for k, v in pairs(crafting_items) do
                total_num_found = total_num_found + v
            end

            if total_num_found >= amount then
                return crafting_items
            end

            local chests = GetSurroundingContainers(self.inst)
            local overflow = self:GetOverflowContainer()
            local overflow_inst = overflow ~= nil and overflow.inst or nil
            local opencontainers = self.opencontainers

            for i = 1, #chests do
                local chest = chests[i]
                if not ShouldSkipChest(chest, opencontainers, overflow_inst) then
                    local container = GetChestContainer(chest)
                    if container ~= nil
                        and container ~= overflow
                        and container.GetCraftingIngredient ~= nil
                    then
                        local found = container:GetCraftingIngredient(item, amount - total_num_found, true)
                        if found ~= nil then
                            for k, v in pairs(found) do
                                if v > 0 and crafting_items[k] == nil and k:IsValid() then
                                    crafting_items[k] = v
                                    total_num_found = total_num_found + v
                                end
                            end
                        end

                        if total_num_found >= amount then
                            break
                        end
                    end
                end
            end

            -- 即将扣料，聚合缓存必然过期
            InvalidateCounts(self.inst)

            return crafting_items
        end

    end)

    AddClassPostConstruct("components/inventory_replica", function(self)

        local oldHas = self.Has

        self.Has = function(self, prefab, amount, checkallcontainers)
            local has_enough, num_found = oldHas(self, prefab, amount, checkallcontainers)

            -- 主机 / 服务端上，replica 会直接转发给权威的 inventory 组件，
            -- 那边已经算过箱子了。这里再算一遍就是双重计数（原实现的 bug）。
            if self.inst.components.inventory ~= nil then
                return has_enough, num_found
            end

            -- 不能因为 oldHas 已够就提前返回：那会让 num_found 只含打开容器，
            -- 制作栏显示的数量被打开容器“覆盖”，附近箱子的不计入。
            -- 这里复用按 tick 聚合缓存，避免每次调用都逐箱子遍历。
            if not checkallcontainers then
                return has_enough, num_found
            end

            local counts = GetSurroundingCounts(self)
            num_found = num_found + (counts[prefab] or 0)

            return num_found >= amount, num_found
        end

    end)

end

-----------------------------------------------------------------
-- DO HIGHLIGHT
-----------------------------------------------------------------
do
    local PinSlot = require "widgets/redux/craftingmenu_pinslot"
    require "recipe"
    local AllRecipes = _G.AllRecipes
    local ori_on_gain_focus = PinSlot.OnGainFocus
    local ori_on_lose_focus = PinSlot.OnLoseFocus

    local function HighlightForIngredients(ingredients, chests)
        for k, v in pairs(ingredients) do
            local type = v.type
            for i = 1, #chests do
                local chest = chests[i]
                local container = GetChestContainerReplica(chest)
                if container ~= nil and container:Has(type, 1) then
                    HighlightContainer(chest)
                end
            end
        end
    end

    function PinSlot:OnGainFocus()
        unlightall()

        local recipe_name = self.recipe_name

        if AllRecipes then
            local chests = GetSurroundingContainers(self.owner)
            local recipe = AllRecipes[recipe_name]

            if recipe and recipe.ingredients then
                HighlightForIngredients(recipe.ingredients, chests)
            end
        end

        return ori_on_gain_focus(self)
    end

    function PinSlot:OnLoseFocus()
        unlightall()
        return ori_on_lose_focus(self)
    end

    local ori_on_crafting_menu_close = PinSlot.OnCraftingMenuClose
    function PinSlot:OnCraftingMenuClose()
        unlightall()
        ori_on_crafting_menu_close(self)
    end

    local TabGroup = require "widgets/tabgroup"

    local ori_deselect_all = TabGroup.DeselectAll

    -- unlight when deselect all
    function TabGroup:DeselectAll(...)
        ori_deselect_all(self, ...)
        unlightall()
    end

end

-----------------------------------------------------------------
---DST Network Related The Most Difficult Part
-----------------------------------------------------------------

-- 把容器内容压成 "prefab count prefab count ..." 广播给客户端，
-- 让客户端在没打开箱子的情况下也能预测"材料够不够"。
--
-- 注意：这里刻意不再展开 unwrappable（礼物包裹）内部的物品。
-- 服务端的 Container:Has / GetCraftingIngredient 完全看不到包裹内的东西，
-- 原实现把它们算进客户端的可用材料，直接造成 客户端说够 / 服务端拿不到 的不一致。
local function BuildContainerString(container)
    local counts = {}
    for _, v in pairs(container.slots) do
        if v ~= nil and v.prefab ~= nil and v:IsValid() and not v:HasTag("nocrafting") then
            local prefab = tostring(v.prefab)
            counts[prefab] = (counts[prefab] or 0) + Count(v)
        end
    end

    -- net_string 是变长字符串。旧版自行限制 240 字节会直接丢弃后续材料。
    -- 排序保证同一份物品统计总是生成相同快照，避免 pairs 顺序引起重复同步。
    local keys = {}
    for prefab in pairs(counts) do
        keys[#keys + 1] = prefab
    end
    table.sort(keys)
    local parts = {}
    for i, prefab in ipairs(keys) do
        parts[i] = prefab .. " " .. counts[prefab]
    end

    return table.concat(parts, " ")
end

-- called by server
local function DoUpdateContainer(inst)
    inst._birt_task = nil

    if not inst:IsValid() or inst._item_str == nil then
        return
    end

    local container = inst.components ~= nil and inst.components.container or nil
    local result = ""

    if container ~= nil and not container.excludefromcrafting and not container.readonlycontainer
        and container.slots ~= nil and not container:IsEmpty() then
        result = BuildContainerString(container)
    end

    -- 内容没变就不发，省掉绝大部分网络同步
    if inst._birt_last ~= result then
        inst._birt_last = result
        inst._item_str:set(result)
        QueueNearbyCraftingRefresh(inst)
        debug_print("UpdateContainerAll: " .. result)
    end
end

-- itemget / itemlose / stacksizechange 会密集触发（搬箱子、合成扣料每扣 1 个都触发一次）。
-- 原实现每次都全量重建字符串并 net_string:set()，是卡顿的主要来源之一。
-- 这里合并到同一帧末尾只做一次。
local function UpdateContainerAll(inst)
    if inst == nil or not inst:IsValid() or inst._item_str == nil then
        return
    end
    if inst._birt_task ~= nil then
        return
    end
    inst._birt_task = inst:DoTaskInTime(0, DoUpdateContainer)
end

-- called by client
local function OnContainerDirty(inst)
    local str = inst._item_str:value()

    local buffered = {}
    for k, v in _G.string.gmatch(str, "(%S+) (%d+)") do
        buffered[k] = (buffered[k] or 0) + (tonumber(v) or 0)
    end
    inst.buffered_items = buffered
    QueueNearbyCraftingRefresh(inst)
end

AddClassPostConstruct("components/container_replica", function(self)
    if not self or not self.inst then
        return
    end

    local inst = self.inst

    -- 口袋维度容器（暗影切斯特 / 魔术箱 / 魔术帽共享的 shadow_container）不支持量子建造：
    -- 它没有世界坐标（客户端连 Transform 都没有），也不是普通箱子。整段跳过，
    -- 既不挂网络串也不覆盖 Has，避免崩溃和读到共享的暗影存储。
    if inst:HasTag("pocketdimension_container") then
        return
    end

    -- netvar 必须在服务端和客户端上以完全一致的方式声明，不能条件性创建
    if _G.net_string then
        inst._item_str = _G.net_string(inst.GUID, "builditremote_item_str", "on_container_dirty")
    end

    inst.buffered_items = {}

    if IsClient then
        if inst._item_str then
            inst:ListenForEvent("on_container_dirty", OnContainerDirty)
        end

        local ori_has = self.Has
        if ori_has then
            self.Has = function(self_ref, prefab, amount, iscrafting)
                -- 有权威数据（主机）或箱子已打开（有 classified）时，
                -- 一律用原生逻辑，不要用广播来的近似值
                if self_ref.inst.components.container ~= nil
                    or (self_ref.classified ~= nil and self_ref.opener ~= nil)
                then
                    return ori_has(self_ref, prefab, amount, iscrafting)
                end

                local buffered = self_ref.inst.buffered_items
                if buffered == nil then
                    return amount <= 0, 0
                end

                local num_found = buffered[prefab] or 0
                debug_print("From buffered has " .. tostring(prefab) .. " " .. num_found .. "/" .. tostring(amount))

                return num_found >= amount, num_found
            end
        end
    end

    if (IsServer or IsDedicated) and inst._item_str then
        inst:ListenForEvent("onclose", UpdateContainerAll)
        inst:ListenForEvent("itemget", UpdateContainerAll)
        inst:ListenForEvent("itemlose", UpdateContainerAll)
        inst:ListenForEvent("stacksizechange", UpdateContainerAll)

        inst:DoTaskInTime(0, function(inst_param)
            if inst_param and inst_param:IsValid() then
                UpdateContainerAll(inst_param)
            end
        end)
    end
end)

-----------------------------------------------------------------
-- 轮询只比较附近材料快照，补足移动 / 箱子销毁等没有网络 dirty 的变化。
-- 主机和远程客户端都运行；不因菜单关闭而停用，也不无条件重算全部配方。
-----------------------------------------------------------------
AddPlayerPostInit(function(inst)
    if IsDedicated or inst.__birt_refresh then
        return
    end
    inst.__birt_refresh = true

    inst:DoPeriodicTask(math.min(1, REFRESH_TIME), RefreshNearbyCrafting)
end)
