local _G = GLOBAL
local TheSim = _G.TheSim
local TheNet = _G.TheNet

local tonumber = GLOBAL.tonumber

local MAX_SEARCH_RANGE = GetModConfigData("MAX_RANGE")
local REFRESH_TIME = GetModConfigData("REFRESH_TIME")
local KEEP_ONE = GetModConfigData("KEEP_ONE")
-- local MAX_SEARCH_RANGE = 10

local IsServer = TheNet:GetIsServer()
local IsDedicated = TheNet:IsDedicated()
local IsClient = TheNet:GetIsClient()


local Highlight = _G.require 'components/highlight'
local __Highlight_ApplyColour = Highlight.ApplyColour
local __Highlight_UnHighlight = Highlight.UnHighlight

local DEBUG_MODE = false

local function debug_print(msg)
    if DEBUG_MODE then
        print("[BuildItRemote] \n"..msg.."\n END")
    end
end

local c = {
    r = .5,
    g = 0,
    b = 0
}
local highlit = {}

-- may cause bug by item.replica is nil. It happens when item is given by some NPC? I don't know really. But it may work now.
local function Count(item)
    if not item then
        return 0
    end
    if item.replica and item.replica.stackable then
        return item.replica.stackable:StackSize() or 1
    elseif item.components and item.components.stackable then
        return item.components.stackable:StackSize() or 1
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

local cache_chests = {}

AddSimPostInit(function()
    GLOBAL.TheWorld:DoPeriodicTask(REFRESH_TIME, function()
        cache_chests = {}
        -- print("clear cache!")
    end)
end)

local loCount = 0

local function GetSurroundingContainers(inst)
    if cache_chests[inst] then
        return cache_chests[inst]
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local ent = TheSim:FindEntities(x, y, z, MAX_SEARCH_RANGE, "_container", {'NOBLOCK', 'player', 'FX'})

    local chests = {}
    for i, v in ipairs(ent) do
        if v:IsValid() and v.entity:IsVisible() and v.replica.container then
            table.insert(chests, v)
        end
    end
    cache_chests[inst] = chests
    -- 调试信息，发布版本可以注释掉
        -- print("Found "..#chests.." chests " .. loCount)
    loCount = loCount + 1
    -- loCount = loCount % 300
    return chests
end

function HasInContainers(inst, item, amount)
    if not inst or not item then
        return false, 0
    end

    local chests = GetSurroundingContainers(inst)
    local num_found = 0
    for i, v in ipairs(chests) do
        -- item is ingredient.type(string)
        if v and v.replica and v.replica.container then
            local enough, num = v.replica.container:Has(item, amount, true)
            num_found = num_found + (num or 0)
        end
    end
    -- 移除或减少print以提高性能
    -- print("Item "..tostring(item)..",  found in "..#chests.." chests: "..num_found.."/"..amount)
    return num_found >= amount, num_found
end

local function HighlightContainer(v)
    if not v or not v.components then
        return
    end
    if not v.components.highlight then
        v:AddComponent('highlight')
    end
    if v.components.highlight then
        table.insert(highlit, v)
        v.components.highlight.ApplyColour = custom_ApplyColour
        v.components.highlight.UnHighlight = custom_UnHighlight
        v.components.highlight:Highlight(0, 0, 0)
    end
end

local function unlightall()
    if not highlit then
        return
    end
    -- 创建一个临时表来存储所有需要处理的对象，避免在循环中修改表
    local to_process = {}
    for k, v in pairs(highlit) do
        table.insert(to_process, v)
    end
    -- 清空原始表以便重新填充
    highlit = {}
    
    -- 处理所有对象
    for _, v in ipairs(to_process) do
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

        -- TheWorld.DebugMessage("add post init inventory")

        local oldHas = self.Has

        self.Has = function(self, item, amount, checkallcontainers)

            local iscrafting = checkallcontainers
            local has_enough, num_found = oldHas(self, item, amount, checkallcontainers)

            
            if has_enough then
                return true, num_found
            end

            local chests = GetSurroundingContainers(self.inst)
            local overflow = self:GetOverflowContainer()
            local opencontainers = self.opencontainers

            for i, chest in pairs(chests) do

                if opencontainers  and opencontainers[chest] then
                    -- 如果箱子已经被打开，则不做检测
                else
                    local container = chest and chest.components and chest.components.container or chest.components.inventory
                    if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
                        local container_enough, container_found = container:Has(item, amount, iscrafting)
                        num_found = num_found + container_found
                    end
                end
                
            end

            return num_found >= amount, num_found
        end

        local oldRemoveItem = self.RemoveItem

        self.RemoveItem = function(self, item, wholestack, checkallcontainers, keepoverstacked)

            if item == nil then
                return
            end

            -- print(">the removing item: a table "..tostring(item.prefab).." Whole stack "..tostring(wholestack))
            local return_item = oldRemoveItem(self, item, wholestack, checkallcontainers, keepoverstacked)

            -- This happens when get an item from a stackable item, in other conditions the item value will not change
            if return_item ~= item then
                return return_item
            end

            local chests = GetSurroundingContainers(self.inst)
            local overflow = self:GetOverflowContainer()
            local opencontainers = self.opencontainers

            for i, chest in pairs(chests) do

                if opencontainers  and opencontainers[chest] then
                    -- 如果箱子已经被打开，则不做检测
                else
                    local container = chest and chest.components and chest.components.container or chest.components.inventory
                    if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
                        local container_item = container:RemoveItem(item, wholestack, nil, keepoverstacked)
                        if container_item then
                            return container_item
                        end
                    end
                end

                
            end


            return item

        end

        local oldGetCraftingIngredient = self.GetCraftingIngredient

        self.GetCraftingIngredient = function (self, item, amount)
            -- dict[item_inst, number]
            local crafting_items = oldGetCraftingIngredient(self, item, amount)

            local total_num_found = 0
            for k, v in pairs(crafting_items) do
                total_num_found = total_num_found + v
            end

            if total_num_found >= amount then
                return crafting_items
            end

            local chests = GetSurroundingContainers(self.inst)
            local overflow = self:GetOverflowContainer()
            local opencontainers = self.opencontainers

            for i, chest in pairs(chests) do

                if opencontainers  and opencontainers[chest] then
                    -- 如果箱子已经被打开，则不做检测
                else
                    local container = chest and chest.components and chest.components.container or chest.components.inventory
                    if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
                        if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
                            for k, v in pairs(container:GetCraftingIngredient(item, amount - total_num_found, true)) do
                                crafting_items[k] = v
                                total_num_found = total_num_found + v
                            end
                        end

                        if total_num_found >= amount then
                            return crafting_items
                        end
                    end
                end
                
            end
        end

    end)

    AddClassPostConstruct("components/inventory_replica", function(self)
        
        local oldHas = self.Has
        
        self.Has = function (self, prefab, amount, checkallcontainers)
            local has_enough, num_found = oldHas(self, prefab, amount, checkallcontainers)

            debug_print("Inventory Has: for " .. tostring(prefab) .. " #" .. tostring(amount))

            if has_enough then
                debug_print("Inventory Has: already enough in other way " .. tostring(prefab) .. " #" .. tostring(amount))
                return true, num_found
            end

            local chests = GetSurroundingContainers(self.inst)
            local overflow = self:GetOverflowContainer()
            local opencontainers = self.opencontainers

            debug_print("Inventory Has: Now search for chests " .. tostring(prefab) .. " #" .. tostring(amount))
                

            for i, chest in pairs(chests) do

                if opencontainers  and opencontainers[chest] then
                    -- 如果箱子已经被打开，则不做检测
                else
                    local container = chest and chest.replica and chest.replica.container
                    if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
                        local container_enough, container_found = container:Has(prefab, amount, true)
                        num_found = num_found + (tonumber(container_found) or 0)
                        debug_print("Search for " .. tostring(prefab) .." in chest ".. container.type .. ". And get " .. tostring(container_found))
                    end
                end
                
            end
            -- 移除或减少print以提高性能
            debug_print("Inventory Has: Item "..tostring(prefab)..",  found in "..#chests.." chests: "..num_found.."/"..amount)
            return num_found >= amount, num_found
        end

    end)

end

-----------------------------------------------------------------
-- DO HIGHLIGHT
-----------------------------------------------------------------
do
    local PinSlot = require "widgets/redux/craftingmenu_pinslot"
    local CraftingMenuHUD = require "widgets/redux/craftingmenu_hud"
    require "recipe"
    local AllRecipes = _G.AllRecipes
    local ori_on_gain_focus = PinSlot.OnGainFocus
    local ori_on_lose_focus = PinSlot.OnLoseFocus

    local function HighlightForIngredients(ingredients, chests)
        for k, v in pairs(ingredients) do
            local type = v.type
            for i, chest in pairs(chests) do
                if chest and chest.replica.container then
                    if chest.replica.container:Has(type, 1) then
                        HighlightContainer(chest)
                    end
                end
            end
        end
    end

    function PinSlot:OnGainFocus()
        -- print("unlight from ongain focus")
        unlightall()

        local recipe_name = self.recipe_name

        if AllRecipes then
            local chests = GetSurroundingContainers(self.owner)
            local recipe = AllRecipes[recipe_name]

            if recipe and recipe.ingredients then
                HighlightForIngredients(recipe.ingredients, chests)
            end
        else
            -- print "No recipes found"
        end

        return ori_on_gain_focus(self)
    end

    function PinSlot:OnLoseFocus()
        -- print("unlight from onlose focus")
        unlightall()
        return ori_on_lose_focus(self)
    end

    local CraftingMenuDetails = require "widgets/redux/craftingmenu_details"

    -- local ori_populate_recipe_detail_panel = CraftingMenuDetails.PopulateRecipeDetailPanel

    -- function CraftingMenuDetails:PopulateRecipeDetailPanel(data, skin_name)
    --     print("unlight from PopulateRecipeDetailPanel")
    --     unlightall()
    --     -- the argument recipe is actually data {recipe, meta}

    --     if data then
    --         local ingredients = data.recipe.ingredients

    --         local owner = self.owner
    --         if owner and owner.HUD:IsCraftingOpen() then
    --             local chests = GetSurroundingContainers(owner)
    --             HighlightForIngredients(ingredients, chests)
    --         end
    --     end

    --     return ori_populate_recipe_detail_panel(self, data, skin_name)
    -- end

    local ori_on_crafting_menu_close = PinSlot.OnCraftingMenuClose
    function PinSlot:OnCraftingMenuClose()
        -- print("unlight from OnCraftingMenuClose")
        unlightall()
        ori_on_crafting_menu_close(self)
    end

    local TabGroup = require "widgets/tabgroup"

    local ori_deselect_all = TabGroup.DeselectAll

    -- unlight when deselect all
    function TabGroup:DeselectAll(...)
        ori_deselect_all(self, ...)
        -- print("unlight from DeselectAll")
        unlightall()
    end

end

-----------------------------------------------------------------
---DST Network Related The Most Difficult Part
-----------------------------------------------------------------

local ContainerReplica = require "components/container_replica"
local ThePlayer = _G.ThePlayer
local number = 0



-- -- called by server

-- ---update sigle data

local function UpdateContainerAll(inst)
        if not inst or not inst.components then
            return
        end
        local container = inst.components.container
        if not container or not container.slots then
            if inst._item_str then
                inst._item_str:set("")
            end
            return
        end
        
        if container:IsEmpty() then
            if inst._item_str then
                inst._item_str:set("")
            end
            return
        end

        local items = {}

        for k, v in pairs(container.slots) do
            if v and v.prefab then
                local prefab_str = tostring(v.prefab)
                local count = Count(v)
                if items[prefab_str] then
                    items[prefab_str] = items[prefab_str] + count
                else
                    items[prefab_str] = count
                end
                
                -- 处理可包装物品
                if v.components and v.components.unwrappable and v.components.unwrappable.itemdata then
                    local itemdata = v.components.unwrappable.itemdata
                    if itemdata and type(itemdata) == "table" then
                        for _, wrapped_item in pairs(itemdata) do
                            if wrapped_item and wrapped_item.prefab then
                                local wrapped_prefab = tostring(wrapped_item.prefab)
                                local wrapped_count = Count(wrapped_item)
                                if items[wrapped_prefab] then
                                    items[wrapped_prefab] = items[wrapped_prefab] + wrapped_count
                                else
                                    items[wrapped_prefab] = wrapped_count
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- 构建结果字符串
        local result = ""
        for k, v in pairs(items) do
            result = result .. " " .. k .. " " .. v
        end

        debug_print("UpdateContainerAll, result of chest: \n"..result)
        if inst._item_str then
            inst._item_str:set(result)
        end
    end

-- called by client
local function OnContainerDirty(inst)

    local str = inst._item_str:value()

    -- print("On Dirty "..str)
    -- clear buffer item
    inst.buffered_items = {}

    -- match a string like 
    --[[
        meatballs 5 seeds 6 log 7
    --]]
    for k, v in string.gmatch(str, "(%S+) (%d+)") do
        local num = tonumber(v) or 0
        if inst.buffered_items[k] then
            inst.buffered_items[k] = (tonumber(inst.buffered_items[k]) or 0) + num
        else
            inst.buffered_items[k] = num
        end
    end
end

AddClassPostConstruct("components/container_replica", function(self)
    if not self or not self.inst then
        return
    end
    
    local inst = self.inst
    
    -- 安全地创建网络变量
    if _G.net_string then
        inst._item_str = _G.net_string(inst.GUID, "builditremote_item_str", "on_container_dirty")
    end
    
    inst.buffered_items = {}
    
    if IsClient then
        -- 安全地添加事件监听
        if inst._item_str then
            inst:ListenForEvent("on_container_dirty", OnContainerDirty)
        end
        
        -- 安全地覆盖Has函数
        local ori_has = self.Has
        if ori_has then
            self.Has = function(self_ref, prefab, amount)
                if not self_ref or not self_ref.inst.buffered_items then
                    return false, 0
                end

                local prefab_str = tostring(prefab)
                
                local num_found = 0
                for k, v in pairs(self_ref.inst.buffered_items) do
                    -- both k and v are string i guess
                    debug_print("Check " .. k .. "(#" .. tostring(v)  .. ")==" .. prefab_str)
                    if k == prefab then
                        num_found = num_found + (tonumber(v) or 0)
                    end
                end
                debug_print("From buffered has "..prefab_str.." "..num_found.."/"..amount)
                
                return num_found >= amount, num_found
            end
        end
    end

    if (IsServer or IsDedicated) and inst._item_str then
        -- 安全地添加事件监听
        inst:ListenForEvent("onclose", UpdateContainerAll)
        inst:ListenForEvent("itemget", UpdateContainerAll)
        inst:ListenForEvent("itemlose", UpdateContainerAll)
        inst:ListenForEvent("stacksizechange", UpdateContainerAll)
        
        -- 安全地调度初始更新
        inst:DoTaskInTime(0, function(inst_param)
            if inst_param and inst_param:IsValid() then
                UpdateContainerAll(inst_param)
            end
        end)
    end

    -- print("Construct container replica end")
end)


AddPlayerPostInit(function(inst)
    -- sadly, in server there is no "ThePlayer"
    -- Actually this should only make the current player work instead all of them, 
    -- but actually no other will respond to this event I guess. So will it work fine?

    -- just refresh once
    -- 确保只在客户端执行周期性任务
    if IsClient and inst == ThePlayer and number == 0 then
        -- 增加检查以确保inst有效
        inst:DoPeriodicTask(1.0, function(player_inst)
            if player_inst and player_inst:IsValid() then
                player_inst:PushEvent("refreshcrafting")
            end
        end)
        
        number = number + 1
    end
end)

