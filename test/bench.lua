-----------------------------------------------------------------
-- 性能对照：模拟一次合成菜单刷新（refreshcrafting）
-- 菜单会对全部配方逐个材料调 inventory:Has(type, amt, true)
-- 用法: 同 harness，由 run.py 注入 arg[1] = modmain 路径
-----------------------------------------------------------------

local MODMAIN = arg and arg[1] or "modmain.lua"

-- 复用 harness 的 mock（只到"加载 mod"为止），这里重新写一份精简版
local clock = 0
function GetTime() return clock end

local guid = 0
local all_ents = {}

local Entity = {}
Entity.__index = Entity
local function NewEntity(prefab)
    guid = guid + 1
    local e = setmetatable({ GUID = guid, prefab = prefab, components = {}, replica = {},
        tags = {}, valid = true, x = 0, y = 0, z = 0, ev = {} }, Entity)
    e.entity = { IsVisible = function() return true end }
    e.Transform = { GetWorldPosition = function() return e.x, e.y, e.z end }
    all_ents[#all_ents + 1] = e
    return e
end
function Entity:IsValid() return self.valid end
function Entity:HasTag(t) return self.tags[t] == true end
function Entity:AddTag(t) self.tags[t] = true end
function Entity:AddChild() end
function Entity:RemoveChild() end
function Entity:RemoveFromScene() end
function Entity:ReturnToScene() end
function Entity:ListenForEvent() end
function Entity:PushEvent() end
function Entity:DoTaskInTime() return { Cancel = function() end } end
function Entity:DoPeriodicTask() return { Cancel = function() end } end

local Stackable = { }
Stackable.__index = Stackable
function Stackable:StackSize() return self.stacksize end

local Container = {}
Container.__index = Container
function Container:Has(item, amount, iscrafting)
    local n = 0
    for _, v in pairs(self.slots) do
        if v ~= nil and v.prefab == item then n = n + v.components.stackable:StackSize() end
    end
    return n >= amount, n
end
function Container:GetCraftingIngredient() return {} end
function Container:GetItemSlot() return nil end
function Container:IsEmpty() return next(self.slots) == nil end

local Inventory = {}
Inventory.__index = Inventory
function Inventory:GetOverflowContainer() return nil end
function Inventory:Has(item, amount) return false, 0 end
function Inventory:RemoveItem(item) return item end
function Inventory:GetCraftingIngredient() return {} end

local INV_POSTINITS = {}
local CONFIG = { MAX_RANGE = 30, REFRESH_TIME = 5, KEEP_ONE = false }
function GetModConfigData(k) return CONFIG[k] end
function AddComponentPostInit(n, fn) if n == "inventory" then INV_POSTINITS[#INV_POSTINITS + 1] = fn end end
function AddClassPostConstruct() end
function AddPlayerPostInit() end
function AddSimPostInit(fn) SIMPOST = fn end

local STUBS = {
    ["components/highlight"] = { ApplyColour = function() end, UnHighlight = function() end },
    ["widgets/redux/craftingmenu_pinslot"] = { OnGainFocus = function() end,
        OnLoseFocus = function() end, OnCraftingMenuClose = function() end },
    ["widgets/tabgroup"] = { DeselectAll = function() end },
}
local _require = function(n) return STUBS[n] or {} end
require = _require

GLOBAL = {
    tonumber = tonumber, tostring = tostring, type = type, pairs = pairs, ipairs = ipairs,
    math = math, table = table, string = string, GetTime = GetTime, require = _require,
    AllRecipes = {}, ThePlayer = nil,
    net_string = function() return { set = function() end, value = function() return "" end } end,
    TheSim = { FindEntities = function(_, x, y, z, r)
        local out = {}
        for _, e in ipairs(all_ents) do
            if e.valid and e.tags["_container"] then out[#out + 1] = e end
        end
        return out
    end },
    TheNet = { GetIsServer = function() return true end, IsDedicated = function() return true end,
        GetIsClient = function() return false end },
    TheWorld = NewEntity("world"),
}
GLOBAL.GLOBAL = GLOBAL
TheSim = GLOBAL.TheSim

assert(loadfile(MODMAIN))()
if SIMPOST then SIMPOST() end

-- 造场景：20 个箱子，每个 15 槽装不同材料
local PREFABS = { "log", "rocks", "cutstone", "boards", "twigs", "cutgrass", "flint",
    "goldnugget", "nitre", "gears", "silk", "pigskin", "rope", "papyrus", "nightmarefuel" }

local player = NewEntity("wilson")
player:AddTag("player")
player.components.inventory = setmetatable({ inst = player, itemslots = {}, equipslots = {},
    maxslots = 15, opencontainers = {}, activeitem = nil }, Inventory)
for _, fn in ipairs(INV_POSTINITS) do fn(player.components.inventory) end

for _ = 1, 20 do
    local chest = NewEntity("treasurechest")
    chest:AddTag("_container")
    local slots = {}
    for i = 1, 15 do
        local it = NewEntity(PREFABS[i])
        it.components.stackable = setmetatable({ stacksize = 40 }, Stackable)
        slots[i] = it
    end
    chest.components.container = setmetatable({ inst = chest, slots = slots, numslots = 15 }, Container)
    chest.replica.container = chest.components.container
end

-- 一次菜单刷新 = 1000 配方 x 3 材料 = 3000 次 Has 查询（同一帧内）
local RECIPES, ING = 1000, 3
local queries = {}
for r = 1, RECIPES do
    for i = 1, ING do
        queries[#queries + 1] = PREFABS[((r + i) % #PREFABS) + 1]
    end
end

local inv = player.components.inventory
local t0 = os.clock()
local FRAMES = 20
for f = 1, FRAMES do
    clock = clock + 1 / 30 -- 新的一帧
    for _, p in ipairs(queries) do inv:Has(p, 4, true) end
end
local dt = os.clock() - t0

print(string.format("%-22s  %d 帧 x %d 次 Has  ->  总 %.3fs, 单帧 %.2f ms",
    MODMAIN, FRAMES, #queries, dt, dt / FRAMES * 1000))
