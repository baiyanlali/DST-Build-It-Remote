-----------------------------------------------------------------
-- DST "量子建造" mod 逻辑测试台
-- 用最小但忠于原版语义的 mock 复现 Builder / Inventory / Container
-- 然后加载 modmain.lua，断言"材料是否被精确扣除"。
--
-- 用法: lua test/harness.lua <modmain路径>
-----------------------------------------------------------------

local MODMAIN = arg and arg[1] or "modmain.lua"

-----------------------------------------------------------------
-- 引擎侧 mock
-----------------------------------------------------------------
local clock = 0
function GetTime() return clock end
local function tick(dt) clock = clock + (dt or 1 / 30) end

local guid = 0
local all_ents = {}

local Entity = {}
Entity.__index = Entity

local function NewEntity(prefab)
    guid = guid + 1
    local e = setmetatable({
        GUID = guid,
        prefab = prefab,
        components = {},
        replica = {},
        tags = {},
        valid = true,
        x = 0, y = 0, z = 0,
        children = {},
        event_listeners = {},
    }, Entity)
    e.entity = { IsVisible = function() return true end }
    e.Transform = {
        GetWorldPosition = function() return e.x, e.y, e.z end,
        SetPosition = function(_, x, y, z) e.x, e.y, e.z = x or 0, y or 0, z or 0 end,
    }
    all_ents[#all_ents + 1] = e
    return e
end

function Entity:IsValid() return self.valid end
function Entity:HasTag(t) return self.tags[t] == true end
function Entity:AddTag(t) self.tags[t] = true end
function Entity:GetPosition() return { x = self.x, y = self.y, z = self.z } end
function Entity:AddChild(c) self.children[c] = true end
function Entity:RemoveChild(c) self.children[c] = nil end
function Entity:RemoveFromScene() self.in_scene = false end
function Entity:ReturnToScene() self.in_scene = true end
function Entity:ListenForEvent(ev, fn)
    self.event_listeners[ev] = self.event_listeners[ev] or {}
    table.insert(self.event_listeners[ev], fn)
end
function Entity:PushEvent(ev, data)
    for _, fn in ipairs(self.event_listeners[ev] or {}) do fn(self, data) end
end
function Entity:DoTaskInTime(_, fn) table.insert(PENDING_TASKS, function() fn(self) end); return { Cancel = function() end } end
function Entity:DoPeriodicTask(_, fn) return { Cancel = function() end } end
function Entity:AddComponent(name) self.components[name] = { inst = self } end

-- 原版 InventoryItem:OnRemoveEntity 会把物品从其所在容器里摘掉
function Entity:Remove()
    local invitem = self.components.inventoryitem
    if invitem and invitem.owner then
        local owner = invitem.owner
        if owner.components.inventory then
            owner.components.inventory:RemoveItem(self, true)
        elseif owner.components.container then
            owner.components.container:RemoveItem(self, true)
        end
    end
    self.valid = false
end

PENDING_TASKS = {}
local function flush_tasks()
    local t = PENDING_TASKS
    PENDING_TASKS = {}
    for _, fn in ipairs(t) do fn() end
end

-----------------------------------------------------------------
-- Stackable
-----------------------------------------------------------------
local Stackable = {}
Stackable.__index = Stackable

local function SpawnPrefab(prefab)
    local e = NewEntity(prefab)
    -- 测试里所有 spawn 出来的都当作可堆叠 1 个
    e.components.stackable = setmetatable({ inst = e, stacksize = 1, maxsize = 40 }, Stackable)
    e.components.inventoryitem = { inst = e, owner = nil }
    setmetatable(e.components.inventoryitem, { __index = INVENTORYITEM_MT })
    return e
end

function Stackable:StackSize() return self.stacksize end
function Stackable:IsStack() return self.stacksize > 1 end
function Stackable:SetStackSize(n)
    self.stacksize = n
    self.inst:PushEvent("stacksizechange", { stacksize = n })
end
function Stackable:IsOverStacked() return false end
function Stackable:Get(num)
    local n = num or 1
    if self.stacksize > n then
        local inst = SpawnPrefab(self.inst.prefab)
        self:SetStackSize(self.stacksize - n)
        inst.components.stackable:SetStackSize(n)
        return inst
    else
        local invitem = self.inst.components.inventoryitem
        if invitem and invitem.owner then
            local owner = invitem.owner
            if owner.components.container then
                owner.components.container:__detach(self.inst)
            elseif owner.components.inventory then
                owner.components.inventory:__detach(self.inst)
            end
        end
        return self.inst
    end
end

-----------------------------------------------------------------
-- InventoryItem
-----------------------------------------------------------------
INVENTORYITEM_MT = {}
INVENTORYITEM_MT.OnRemoved = function(self)
    if self.owner then self.owner:RemoveChild(self.inst) end
    self.owner = nil
    self.inst:ReturnToScene()
end
INVENTORYITEM_MT.GetSlotNum = function(self) return self.slot end
INVENTORYITEM_MT.SetOwner = function(self, o) self.owner = o end
INVENTORYITEM_MT.GetMoisture = function() return 0 end
INVENTORYITEM_MT.__index = INVENTORYITEM_MT

local function MakeItem(prefab, stacksize, stackable)
    local e = NewEntity(prefab)
    if stackable ~= false then
        e.components.stackable = setmetatable(
            { inst = e, stacksize = stacksize or 1, maxsize = 40 }, Stackable)
    end
    e.components.inventoryitem = setmetatable({ inst = e, owner = nil }, INVENTORYITEM_MT)
    return e
end

-----------------------------------------------------------------
-- Container（照抄 components/container.lua 的相关语义）
-----------------------------------------------------------------
local Container = {}
Container.__index = Container

local function crafting_priority_fn(a, b)
    if a.stacksize == b.stacksize then return a.slot < b.slot end
    return a.stacksize < b.stacksize
end

function Container:GiveItem(item, slot)
    slot = slot or (function()
        for i = 1, self.numslots do if self.slots[i] == nil then return i end end
    end)()
    self.slots[slot] = item
    item.components.inventoryitem:SetOwner(self.inst)
    self.inst:AddChild(item)
    item:RemoveFromScene()
end

function Container:__detach(item)
    for k, v in pairs(self.slots) do
        if v == item then self.slots[k] = nil end
    end
end

function Container:IsEmpty()
    for _ in pairs(self.slots) do return false end
    return true
end

function Container:GetItemSlot(item)
    for k, v in pairs(self.slots) do if v == item then return k end end
end

function Container:Has(item, amount, iscrafting)
    local num_found = 0
    for _, v in pairs(self.slots) do
        if v ~= nil and v.prefab == item and not (iscrafting and v:HasTag("nocrafting")) then
            num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)
        end
    end
    return num_found >= amount, num_found
end

function Container:GetCraftingIngredient(item, amount, reverse)
    local items = {}
    for i = 1, self.numslots do
        local v = self.slots[i]
        if v ~= nil and v.prefab == item and not v:HasTag("nocrafting") then
            table.insert(items, {
                item = v,
                stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,
                slot = reverse and (self.numslots - (i - 1)) or i,
            })
        end
    end
    table.sort(items, crafting_priority_fn)
    local crafting_items, total = {}, 0
    for _, v in ipairs(items) do
        local sz = math.min(v.stacksize, amount - total)
        crafting_items[v.item] = sz
        total = total + sz
        if total >= amount then break end
    end
    return crafting_items
end

function Container:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)
    if self.readonlycontainer then return nil end
    local stackable = item.components.stackable
    if stackable and stackable:IsStack() then
        local num = (not wholestack and 1) or nil
        if num then
            local dec = stackable:Get(num)
            dec.components.inventoryitem:OnRemoved()
            return dec
        end
    end
    self.slots[slot] = nil
    self.inst:PushEvent("itemlose", { slot = slot, prev_item = item })
    item.components.inventoryitem:OnRemoved()
    return item
end

function Container:RemoveItem(item, wholestack, _cac_, keepoverstacked)
    if item then
        local slot = self:GetItemSlot(item)
        if slot then return self:RemoveItem_Internal(item, slot, wholestack, keepoverstacked) end
        return item
    end
end

local function MakeChest(prefab, numslots)
    local e = NewEntity(prefab or "treasurechest")
    e:AddTag("_container")
    e.components.container = setmetatable(
        { inst = e, slots = {}, numslots = numslots or 9 }, Container)
    e.replica.container = { inst = e, Has = function(self, p, a, c) return e.components.container:Has(p, a, c) end }
    return e
end

-----------------------------------------------------------------
-- Inventory（照抄 components/inventory.lua 的相关语义）
-----------------------------------------------------------------
local Inventory = {}
Inventory.__index = Inventory

function Inventory:__detach(item)
    for k, v in pairs(self.itemslots) do if v == item then self.itemslots[k] = nil end end
    if self.activeitem == item then self.activeitem = nil end
end

function Inventory:GiveItem(item, slot)
    slot = slot or (function()
        for i = 1, self.maxslots do if self.itemslots[i] == nil then return i end end
    end)()
    self.itemslots[slot] = item
    item.components.inventoryitem:SetOwner(self.inst)
    self.inst:AddChild(item)
    item:RemoveFromScene()
end

function Inventory:GetOverflowContainer() return self.overflow end

function Inventory:Has(item, amount, checkallcontainers)
    local iscrafting = checkallcontainers
    local num_found = 0
    for _, v in pairs(self.itemslots) do
        if v and v.prefab == item and not (iscrafting and v:HasTag("nocrafting")) then
            num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)
        end
    end
    if self.activeitem and self.activeitem.prefab == item then
        num_found = num_found + (self.activeitem.components.stackable
            and self.activeitem.components.stackable:StackSize() or 1)
    end
    local overflow = self:GetOverflowContainer()
    if overflow then
        local _, f = overflow:Has(item, amount, iscrafting)
        num_found = num_found + f
    end
    if checkallcontainers then
        for cinst in pairs(self.opencontainers) do
            local container = cinst.components.container or cinst.components.inventory
            if container and container ~= overflow
                and not container.excludefromcrafting and not container.readonlycontainer then
                local _, f = container:Has(item, amount, iscrafting)
                num_found = num_found + f
            end
        end
    end
    return num_found >= amount, num_found
end

function Inventory:RemoveItem(item, wholestack, checkallcontainers, keepoverstacked)
    if item == nil then return end
    if not wholestack and item.components.stackable ~= nil and item.components.stackable:IsStack() then
        local dec = item.components.stackable:Get()
        dec.components.inventoryitem:OnRemoved()
        return dec
    end
    for k, v in pairs(self.itemslots) do
        if v == item then
            self.itemslots[k] = nil
            self.inst:PushEvent("itemlose", { slot = k, prev_item = item })
            item.components.inventoryitem:OnRemoved()
            return item
        end
    end
    if item == self.activeitem then
        self.activeitem = nil
        item.components.inventoryitem:OnRemoved()
        return item
    end
    local overflow = self:GetOverflowContainer()
    local oi = overflow and overflow:RemoveItem(item, wholestack, nil, keepoverstacked)
    if oi then return oi end
    if checkallcontainers then
        for cinst in pairs(self.opencontainers) do
            local container = cinst.components.container or cinst.components.inventory
            if container and container ~= overflow
                and not container.excludefromcrafting and not container.readonlycontainer then
                local ci = container:RemoveItem(item, wholestack, nil, keepoverstacked)
                if ci then return ci end
            end
        end
    end
    return item -- ★ 原版就是这样：找不到也返回 item，永不返回 nil
end

function Inventory:GetCraftingIngredient(item, amount)
    local overflow = self:GetOverflowContainer()
    local crafting_items, total = {}, 0
    for cinst in pairs(self.opencontainers) do
        local container = cinst.components.container or cinst.components.inventory
        if container and container ~= overflow
            and not container.excludefromcrafting and not container.readonlycontainer then
            for k, v in pairs(container:GetCraftingIngredient(item, amount - total, true)) do
                crafting_items[k] = v
                total = total + v
            end
        end
        if total >= amount then return crafting_items end
    end
    local items = {}
    for i = 1, self.maxslots do
        local v = self.itemslots[i]
        if v ~= nil and v.prefab == item and not v:HasTag("nocrafting") then
            table.insert(items, {
                item = v,
                stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,
                slot = i,
            })
        end
    end
    table.sort(items, crafting_priority_fn)
    for _, v in ipairs(items) do
        local sz = math.min(v.stacksize, amount - total)
        crafting_items[v.item] = sz
        total = total + sz
        if total >= amount then return crafting_items end
    end
    if overflow then
        for k, v in pairs(overflow:GetCraftingIngredient(item, amount - total)) do
            crafting_items[k] = v
            total = total + v
        end
        if total >= amount then return crafting_items end
    end
    if self.activeitem and self.activeitem.prefab == item then
        crafting_items[self.activeitem] = math.min(
            self.activeitem.components.stackable and self.activeitem.components.stackable:StackSize() or 1,
            amount - total)
    end
    return crafting_items
end

local INVENTORY_POSTINITS = {}

local function MakePlayer()
    local e = NewEntity("wilson")
    e:AddTag("player")
    e.components.inventory = setmetatable({
        inst = e, itemslots = {}, equipslots = {}, maxslots = 15,
        opencontainers = {}, activeitem = nil,
    }, Inventory)
    for _, fn in ipairs(INVENTORY_POSTINITS) do fn(e.components.inventory) end
    e.replica.inventory = {}
    return e
end

-----------------------------------------------------------------
-- Builder（照抄 components/builder.lua 的相关部分）
-----------------------------------------------------------------
local function Builder_GetIngredients(player, recipe)
    local ingredients = {}
    for _, v in pairs(recipe.ingredients) do
        if v.amount > 0 then
            ingredients[v.type] = player.components.inventory:GetCraftingIngredient(v.type, v.amount)
        end
    end
    return ingredients
end

local function Builder_RemoveIngredients(player, ingredients)
    for _, ents in pairs(ingredients) do
        for k, v in pairs(ents) do
            for _ = 1, v do
                local item = player.components.inventory:RemoveItem(k, false, true)
                assert(item ~= nil, "RemoveItem 返回了 nil —— 原版 Builder 会在这里崩")
                item:Remove()
            end
        end
    end
end

local function Builder_HasIngredients(player, recipe)
    for _, v in ipairs(recipe.ingredients) do
        if not player.components.inventory:Has(v.type, v.amount, true) then return false end
    end
    return true
end

-----------------------------------------------------------------
-- mod API mock
-----------------------------------------------------------------
local CONFIG = { MAX_RANGE = 10, REFRESH_TIME = 5, KEEP_ONE = false }
function GetModConfigData(k) return CONFIG[k] end

local CLASS_POSTCONSTRUCTS = {}
function AddComponentPostInit(name, fn)
    if name == "inventory" then table.insert(INVENTORY_POSTINITS, fn) end
end

function AddClassPostConstruct(name, fn)
    CLASS_POSTCONSTRUCTS[name] = CLASS_POSTCONSTRUCTS[name] or {}
    table.insert(CLASS_POSTCONSTRUCTS[name], fn)
end

function AddPlayerPostInit(fn) end

function AddSimPostInit(fn) table.insert(PENDING_TASKS, fn) end

local WIDGET_STUBS = {
    ["components/highlight"] = { ApplyColour = function() end, UnHighlight = function() end },
    ["widgets/redux/craftingmenu_pinslot"] = {
        OnGainFocus = function() end, OnLoseFocus = function() end, OnCraftingMenuClose = function() end,
    },
    ["widgets/redux/craftingmenu_hud"] = {},
    ["widgets/redux/craftingmenu_details"] = {},
    ["widgets/tabgroup"] = { DeselectAll = function() end },
    ["components/container_replica"] = {},
    ["recipe"] = {},
}

local _require = function(n) return WIDGET_STUBS[n] or {} end
require = _require

GLOBAL = {
    tonumber = tonumber, tostring = tostring, type = type,
    pairs = pairs, ipairs = ipairs, math = math, table = table, string = string,
    GetTime = GetTime,
    require = _require,
    AllRecipes = {},
    ThePlayer = nil,
    net_string = function() return { set = function() end, value = function() return "" end } end,
    TheSim = {
        FindEntities = function(_, x, y, z, r, must, cant)
            local out = {}
            for _, e in ipairs(all_ents) do
                if e.valid and e.tags["_container"] then
                    local dx, dz = e.x - x, e.z - z
                    if dx * dx + dz * dz <= r * r then table.insert(out, e) end
                end
            end
            return out
        end,
    },
    TheNet = {
        GetIsServer = function() return true end,
        IsDedicated = function() return true end,
        GetIsClient = function() return false end,
    },
    TheWorld = NewEntity("world"),
}
GLOBAL.GLOBAL = GLOBAL
TheSim = GLOBAL.TheSim

-----------------------------------------------------------------
-- 加载 mod
-----------------------------------------------------------------
local chunk = assert(loadfile(MODMAIN))
chunk()
flush_tasks()

-----------------------------------------------------------------
-- 测试
-----------------------------------------------------------------
local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        print(string.format("  [PASS] %s", name))
    else
        fail = fail + 1
        print(string.format("  [FAIL] %s   %s", name, detail or ""))
    end
end

local function chest_count(chest, prefab)
    local _, n = chest.components.container:Has(prefab, 0, true)
    return n
end

local function inv_count(player, prefab)
    local n = 0
    for _, v in pairs(player.components.inventory.itemslots) do
        if v and v.prefab == prefab then
            n = n + (v.components.stackable and v.components.stackable:StackSize() or 1)
        end
    end
    return n
end

local function reset()
    all_ents = {}
    clock = clock + 100 -- 让缓存过期
end

local function craft(player, recipe)
    if not Builder_HasIngredients(player, recipe) then return false, "HasIngredients=false" end
    local mats = Builder_GetIngredients(player, recipe)
    Builder_RemoveIngredients(player, mats)
    return true
end

print("=== " .. MODMAIN .. " ===")

-- 场景 1：背包 2 + 箱子 10，需要 6
do
    reset()
    local p = MakePlayer()
    p.components.inventory:GiveItem(MakeItem("log", 2))
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("log", 10))
    local ok, why = craft(p, { ingredients = { { type = "log", amount = 6 } } })
    check("S1 合成成功", ok, tostring(why))
    check("S1 背包 log 归零", inv_count(p, "log") == 0, "剩 " .. inv_count(p, "log"))
    check("S1 箱子 log 10->6", chest_count(chest, "log") == 6, "剩 " .. chest_count(chest, "log"))
end

-- 场景 2：箱子里只有 1 个，需要 1（槽位必须清空）
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("goldnugget", 1))
    local ok, why = craft(p, { ingredients = { { type = "goldnugget", amount = 1 } } })
    check("S2 合成成功", ok, tostring(why))
    check("S2 箱子清空", chest_count(chest, "goldnugget") == 0, "剩 " .. chest_count(chest, "goldnugget"))
end

-- 场景 3：两个箱子 4 + 6，需要 10
do
    reset()
    local p = MakePlayer()
    local c1, c2 = MakeChest(), MakeChest()
    c1.components.container:GiveItem(MakeItem("cutstone", 4))
    c2.components.container:GiveItem(MakeItem("cutstone", 6))
    local ok, why = craft(p, { ingredients = { { type = "cutstone", amount = 10 } } })
    check("S3 合成成功", ok, tostring(why))
    check("S3 箱子1 清空", chest_count(c1, "cutstone") == 0, "剩 " .. chest_count(c1, "cutstone"))
    check("S3 箱子2 清空", chest_count(c2, "cutstone") == 0, "剩 " .. chest_count(c2, "cutstone"))
end

-- 场景 4：不可堆叠物品（龙鳞之类），箱子里 1 个，需要 1
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("dragon_scales", 1, false))
    local ok, why = craft(p, { ingredients = { { type = "dragon_scales", amount = 1 } } })
    check("S4 合成成功", ok, tostring(why))
    check("S4 箱子清空", chest_count(chest, "dragon_scales") == 0, "剩 " .. chest_count(chest, "dragon_scales"))
end

-- 场景 5：非合成语境的 Has（只传 2 个参数）不应算箱子
--         对应 Wortox 灵魂 / 绳桥 / 雕南瓜 那类"检查通过但不扣材料"的 bug
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("wortox_soul", 20))
    local has2, n2 = p.components.inventory:Has("wortox_soul", 1)
    check("S5 非合成 Has 不算箱子", (not has2) and n2 == 0, "has=" .. tostring(has2) .. " n=" .. tostring(n2))
    local has3 = p.components.inventory:Has("wortox_soul", 1, true)
    check("S5 合成语境 Has 仍算箱子", has3 == true, "has=" .. tostring(has3))
end

-- 场景 6：箱子在缓存 TTL 内被销毁 —— 不应再把它的物品算成材料（幽灵材料）
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("boards", 20))
    -- 先建立缓存
    p.components.inventory:Has("boards", 1, true)
    -- 箱子被烧掉，但缓存还在（TTL 5s，只推进 1 帧）
    chest.valid = false
    tick()
    local has, n = p.components.inventory:Has("boards", 4, true)
    check("S6 幽灵箱子不计入材料", (not has) and n == 0,
        "has=" .. tostring(has) .. " n=" .. tostring(n))
end

-- 场景 7：口径一致性 —— Has 说够，GetCraftingIngredient 必须能取齐
do
    reset()
    local p = MakePlayer()
    p.components.inventory:GiveItem(MakeItem("twigs", 1))
    local c1, c2, c3 = MakeChest(), MakeChest(), MakeChest()
    c1.components.container:GiveItem(MakeItem("twigs", 3))
    c2.components.container:GiveItem(MakeItem("twigs", 2))
    c3.components.container:GiveItem(MakeItem("twigs", 5))
    local need = 9
    local has, n = p.components.inventory:Has("twigs", need, true)
    local mats = p.components.inventory:GetCraftingIngredient("twigs", need)
    local got = 0
    for _, v in pairs(mats) do got = got + v end
    check("S7 Has 报够", has, "n=" .. tostring(n))
    check("S7 取料与 Has 口径一致", got == need, "取到 " .. got .. "/" .. need)
end

-- 场景 8：合成后总量守恒（不多扣也不少扣）
do
    reset()
    local p = MakePlayer()
    p.components.inventory:GiveItem(MakeItem("rocks", 5))
    local c1, c2 = MakeChest(), MakeChest()
    c1.components.container:GiveItem(MakeItem("rocks", 7))
    c2.components.container:GiveItem(MakeItem("rocks", 8))
    local before = inv_count(p, "rocks") + chest_count(c1, "rocks") + chest_count(c2, "rocks")
    local ok = craft(p, { ingredients = { { type = "rocks", amount = 12 } } })
    local after = inv_count(p, "rocks") + chest_count(c1, "rocks") + chest_count(c2, "rocks")
    check("S8 合成成功", ok)
    check("S8 恰好扣 12（守恒）", before - after == 12,
        string.format("before=%d after=%d delta=%d", before, after, before - after))
end

-- 场景 9：端到端复现玩家反馈的"生成物品但不消耗原材料"
--         原版里有一批系统（Wortox 灵魂跳跃、绳桥铺设、雕刻南瓜、猪人代币…）
--         用 Has(prefab, n) 两参数做门槛检查，扣除却只走自己身上的物品。
--         mod 无条件扩展 Has 后：检查通过 -> 效果生效 -> 材料一个没扣。
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("wortox_soul", 20))

    -- 模拟原版 ConsumeByName 风格的扣除：只在自己身上找
    local function consume_from_self(player, prefab, amount)
        local removed = 0
        for _, v in pairs(player.components.inventory.itemslots) do
            if v and v.prefab == prefab then
                local st = v.components.stackable
                local take = math.min(st and st:StackSize() or 1, amount - removed)
                if st then st:SetStackSize(st:StackSize() - take) end
                removed = removed + take
                if removed >= amount then break end
            end
        end
        return removed
    end

    local need = 4
    local gate = p.components.inventory:Has("wortox_soul", need) -- 2 参数
    local consumed = gate and consume_from_self(p, "wortox_soul", need) or 0
    check("S9 门槛检查不应被箱子污染", not gate,
        string.format("gate=%s 实际扣除=%d/%d（技能生效但材料未扣）", tostring(gate), consumed, need))
end

-- 场景 10：幽灵箱子（缓存 TTL 内被销毁）不能用来白嫖合成
do
    reset()
    local p = MakePlayer()
    local chest = MakeChest()
    chest.components.container:GiveItem(MakeItem("boards", 20))
    p.components.inventory:Has("boards", 1, true) -- 建缓存
    chest.valid = false
    tick()
    local allowed = Builder_HasIngredients(p, { ingredients = { { type = "boards", amount = 4 } } })
    check("S10 幽灵箱子不能白嫖合成", not allowed, "allowed=" .. tostring(allowed))
end

print(string.format("\n结果: %d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
