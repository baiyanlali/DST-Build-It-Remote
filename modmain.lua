local _G = GLOBAL
local TheSim = _G.TheSim
local TheNet = _G.TheNet

local MAX_SEARCH_RANGE = GetModConfigData("MAX_RANGE")
-- local MAX_SEARCH_RANGE = 10

local IsServer = TheNet:GetIsServer()
local IsDedicated = TheNet:IsDedicated()
local IsClient = TheNet:GetIsClient()

local Inventory = _G.require "components/inventory"
local InventoryReplica = _G.require "components/inventory_replica"

local Highlight = _G.require 'components/highlight'
local __Highlight_ApplyColour = Highlight.ApplyColour
local __Highlight_UnHighlight = Highlight.UnHighlight

local c = {
    r = .5,
    g = 0,
    b = 0
}
local highlit = {}

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
    GLOBAL.TheWorld:DoPeriodicTask(0.5, function()
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
    -- print("Found "..#chests.." chests " .. loCount)
    loCount = loCount + 1
    loCount = loCount % 300
    return chests
end

function HasInContainers(inst, item, amount)

    local chests = GetSurroundingContainers(inst)
    local num_found = 0
    for i, v in ipairs(chests) do
        -- item is ingredient.type(string)
        local enough, num = v.replica.container:Has(item, amount, true)
        num_found = num_found + num

    end
    -- print("Item "..tostring(item)..",  found."..num_found.."/"..amount)
    return num_found >= amount, num_found

end

local function HighlightContainer(v)
    if not v.components.highlight then
        v:AddComponent('highlight')
    end
    table.insert(highlit, v)
    v.components.highlight.ApplyColour = custom_ApplyColour
    v.components.highlight.UnHighlight = custom_UnHighlight
    v.components.highlight:Highlight(0, 0, 0)
end

local function unlightall()
    for k, v in pairs(highlit) do
        if v and v.components and v.components.highlight then
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

    local ori_has = Inventory.Has
    local ori_has_replica = InventoryReplica.Has
    local ori_get_crafting_ingredient = Inventory.GetCraftingIngredient
    local ori_get_crafting_ingredient_replica = InventoryReplica.GetCraftingIngredient
    local ori_remove_item = Inventory.RemoveItem

    function Inventory:RemoveItem(item, wholestack, checkallcontainers)

        -- print(">the removing item: a table "..tostring(item.prefab).." Whole stack "..tostring(wholestack))
        local return_item = ori_remove_item(self, item, wholestack, false)

        -- This happens when get an item from a stackable item, in other conditions the item value will not change
        if return_item ~= item then
            return return_item
        end

        local chests = GetSurroundingContainers(self.inst)
        local overflow = self:GetOverflowContainer()

        local prevslot = item.components.inventoryitem and item.components.inventoryitem:GetSlotNum() or nil
        if not wholestack and item.components.stackable ~= nil and item.components.stackable:IsStack() then
            -- the logic just like origin remove item, here we do nothing
        else
            -- We will check if the remove param whole stack is true, then we will try to use lose item
            for i, chest in pairs(chests) do
                local container = chest and chest.components and chest.components.container
                if chest ~= overflow then
                    for k, v in pairs(container.slots) do
                        if v == item then
                            container.slots[k] = nil
                            container.inst:PushEvent("itemlose", {
                                slot = k,
                                prev_item = item
                            })
                            item.components.inventoryitem:OnRemoved()
                            item.prevslot = prevslot
                            item.prevcontainer = container
                            return item
                        end
                    end
                end
            end

        end

        return item

    end
    function Inventory:Has(item, amount, checkallcontainers, fromReplica)
        -- if the inventory is called by replica, then it should not recalculate the resource again
        if fromReplica then
            return ori_has(self, item, amount, false)
        else
            local _, num = ori_has(self, item, amount, false)
            local left = amount - num
            local enough, num_container = HasInContainers(self.inst, item, left)
            return enough, num_container + num
        end
    end

    function InventoryReplica:Has(item, amount, checkallcontainers)
        local enough, num
        if self.inst.components.inventory ~= nil then
            enough, num = self.inst.components.inventory:Has(item, amount, false, true)
        elseif self.classified ~= nil then
            enough, num = self.classified:Has(item, amount, false)
        else
            enough, num = amount <= 0, 0
        end
        -- local _, num = ori_has_replica(self, item, amount, false, true)

        local left = amount - num
        local enough, num_container = HasInContainers(self.inst, item, left)

        return enough, num_container + num
    end

    -- can only call from server
    function Inventory:GetCraftingIngredient(item, amount)
        -- print ("Call get crafting ingredient "..amount.." "..item)
        local ingredients = ori_get_crafting_ingredient(self, item, amount)

        local total_num_found = 0
        for k, v in pairs(ingredients) do
            total_num_found = total_num_found + v
        end

        if total_num_found >= amount then
            -- print("Backpack is enough")
            return ingredients
        end

        local chests = GetSurroundingContainers(self.inst)
        local overflow = self:GetOverflowContainer()
        for i, chest_inst in pairs(chests) do
            local chest = chest_inst.components.container
            -- print("Chest "..tostring(chest))
            if chest and chest ~= overflow and not chest.excludefromcrafting then
                for k, v in pairs(chest:GetCraftingIngredient(item, amount - total_num_found, true)) do
                    ingredients[k] = v
                    total_num_found = total_num_found + v
                    if total_num_found >= amount then
                        return ingredients
                    end
                end
            end
        end

        return ingredients

    end
    local BuilderReplica = _G.require "components/builder_replica"
    local Builder = _G.require "components/builder"

    local ori_get_ingredients = Builder.GetIngredients
    function Builder:GetIngredients(recname)
        -- print('Custom Builder:GetIngredients: ' .. recname)
        return ori_get_ingredients(self, recname)
    end

    -- local make_recipe = Builder.MakeRecipe
    -- function Builder:MakeRecipe(recipe, pt, rot, skin, onsuccess)
    --     local result = make_recipe(self,recipe,pt,rot,skin,onsuccess)
    --     -- print("Result is "..tostring(result))
    -- end

    -- local do_build = Builder.DoBuild
    -- local buffer_build = Builder.BufferBuild

    -- function Builder:BufferBuild(recname)
    --     local recipe = _G.GetValidRecipe(recname)
    --     print("Buffer build for "..recname .. ' '..'Has Ingredients '..tostring(self:HasIngredients(recipe)))
    --     buffer_build(self,recname)
    --     print("success "..tostring(success).." fault "..tostring(fault))
    -- end

    local InventoryItemReplica = _G.require "components/inventoryitem_replica"
    local ori_set_pickup_pos = InventoryItemReplica.SetPickupPos
    function InventoryItemReplica:SetPickupPos(pos)
        if not self.classified then
            return
        end
        return ori_set_pickup_pos(self, pos)
        -- if pos ~= nil then
        --     self.classified.src_pos.isvalid:set(true)
        --     self.classified.src_pos.x:set(pos.x)
        --     self.classified.src_pos.z:set(pos.z)
        -- else
        --     self.classified.src_pos.isvalid:set(false)
        -- end
    end

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
            print "No recipes found"
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
        print("unlight from DeselectAll")
        unlightall()
    end

end
-----------------------------------------------------------------
---DST Network Related The Most Difficult Part
-----------------------------------------------------------------
local ContainerReplica = require "components/container_replica"
local ThePlayer = _G.ThePlayer

-- may cause bug by item.replica is nil. It happens when item is given by some NPC? I don't know really. But it may work now.
local function Count(item)
    if item.replica and item.replica.stackable then
        return item.replica.stackable ~= nil and item.replica.stackable:StackSize() or 1
    elseif item.components and item.components.stackable then
        return item.components.stackable ~= nil and item.components.stackable:StackSize() or 1
    else
        return 0
    end
end

-- called by server

---update sigle data
local function ItemGet(inst, data)
    local container = inst.components.container
    if container and data then
        if container:IsEmpty() then
            inst._item_str:set("")
            return
        end

        local item = 0

        item = Count(data.item)

        for k, v in pairs(container.slots) do
            if v.prefab == data.item.prefab then
                item = item + Count(v)
            end
        end
        local result = tostring(data.item.prefab) .. " " .. item
        -- for k,v in pairs(items)do
        --     result = result.." "..k.." "..v
        -- end
        inst._item_str:set(result)

        -- print("Send msg "..result)
    end
end

local function ItemLose(inst, data)
    local container = inst.components.container
    if container and data then
        if container:IsEmpty() then
            inst._item_str:set("")
            return
        end

        local item = 0

        -- item = Count(data.prev_item)

        for k, v in pairs(container.slots) do
            if v.prefab == data.prev_item.prefab then
                item = item + Count(v)
            end
        end
        local result = tostring(data.prev_item.prefab) .. " " .. item
        -- for k,v in pairs(items)do
        --     result = result.." "..k.." "..v
        -- end
        inst._item_str:set(result)

        -- print("Send msg "..result)
    end
end

local function UpdateContainerAll(inst)
    local container = inst.components.container
    if container then
        if container:IsEmpty() then
            inst._item_str:set("")
            return
        end

        local items = {}

        for k, v in pairs(container.slots) do
            if items[tostring(v.prefab)] then
                items[tostring(v.prefab)] = items[tostring(v.prefab)] + Count(v)
            else
                items[tostring(v.prefab)] = Count(v)
            end
            if v.components and v.components.unwrappable and v.components.unwrappable.itemdata then
                local itemdata = v.components.unwrappable.itemdata
                for k, v in pairs(itemdata) do
                    if items[tostring(v.prefab)] then
                        items[tostring(v.prefab)] = items[tostring(v.prefab)] + (Count(v) or 0)
                    else
                        items[tostring(v.prefab)] = Count(v)
                    end
                end
            end
        end
        local result = ""
        for k, v in pairs(items) do
            result = result .. " " .. k .. " " .. v
        end
        inst._item_str:set(result)

        -- print("Send msg "..result)
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
    for k, v in string.gmatch(str, "(%a+) (%d+)") do
        if inst.buffered_items[k] then
            inst.buffered_items[k] = inst.buffered_items[k] + v
        else
            inst.buffered_items[k] = v
        end
    end
end

AddClassPostConstruct("components/container_replica", function(self)
    local inst = self.inst
    inst._item_str = _G.net_string(inst.GUID, "builditremote_item_str", "on_container_dirty")
    inst.buffered_items = {}
    if IsClient then
        inst:ListenForEvent("on_container_dirty", OnContainerDirty)
        local ori_has = self.Has
        self.Has = function(self, prefab, amount)
            if inst.buffered_items then
                local num_found = 0
                for k, v in pairs(inst.buffered_items) do
                    -- both k and v are string i guess
                    if k == prefab then
                        num_found = num_found + v
                    end
                end
                -- print("From buffered "..#inst.buffered_items.." has "..prefab.." "..num_found.."/"..amount)
                return num_found >= amount, num_found
            else
                return ori_has(inst, prefab, amount)
            end
        end
    end

    if IsServer then
        inst:ListenForEvent("onclose", UpdateContainerAll)
        inst:ListenForEvent("itemget", ItemGet)
        inst:ListenForEvent("itemlose", ItemLose)
        inst:ListenForEvent("stacksizechange", UpdateContainerAll)
        inst:DoTaskInTime(0, function(inst)
            UpdateContainerAll(inst)
        end)
    end

    -- print("Construct container replica end")
end)

local number = 0

AddPlayerPostInit(function(inst)
    -- sadly, in server there is no "ThePlayer"
    -- Actually this should only make the current player work instead all of them, 
    -- but actually no other will respond to this event I guess. So will it work fine?

    -- just refresh once
    if number == 0 then
        inst:DoPeriodicTask(.7, function()
            -- print("refreshcrafting ing...")
            inst:PushEvent("refreshcrafting")
        end)

        number = number + 1
    end

end)

-- AddSimPostInit(function(inst)
--     inst:DoPeriodicTask(.9, function()
--         cache_chests = {}
--     end)
-- end)

-- TheWorld:DoPeriodicTask(.9, function()
--     cache_chests = {}
-- end)
