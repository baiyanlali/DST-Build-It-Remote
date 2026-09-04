-----------------------------------------------------------------
-- 客户端路径测试（IsClient = true）
-- 验证：
--   1. net_string 广播的内容能被正确解析
--   2. 已打开的箱子不会被重复计数（原实现读 self.opencontainers 恒为 nil）
--   3. 主机（有权威 components）时不会二次叠加
-- 用法: runner.py client.lua <modmain路径>
-----------------------------------------------------------------

local MODMAIN = arg and arg[1] or "modmain.lua"

local clock = 0
function GetTime() return clock end

local guid = 0
local all_ents = {}
local PENDING = {}

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
function Entity:ListenForEvent(ev, fn) self.ev[ev] = self.ev[ev] or {}; table.insert(self.ev[ev], fn) end
function Entity:PushEvent(ev, d) for _, f in ipairs(self.ev[ev] or {}) do f(self, d) end end
function Entity:DoTaskInTime(_, fn) table.insert(PENDING, function() fn(self) end); return { Cancel = function() end } end
function Entity:DoPeriodicTask() return { Cancel = function() end } end

local function flush() local t = PENDING; PENDING = {}; for _, f in ipairs(t) do f() end end

local POST = {}
local CONFIG = { MAX_RANGE = 30, REFRESH_TIME = 5, KEEP_ONE = false }
function GetModConfigData(k) return CONFIG[k] end
function AddComponentPostInit() end
function AddClassPostConstruct(n, fn) POST[n] = POST[n] or {}; table.insert(POST[n], fn) end
function AddPlayerPostInit() end
function AddSimPostInit(fn) table.insert(PENDING, fn) end

local STUBS = {
    ["components/highlight"] = { ApplyColour = function() end, UnHighlight = function() end },
    ["widgets/redux/craftingmenu_pinslot"] = { OnGainFocus = function() end,
        OnLoseFocus = function() end, OnCraftingMenuClose = function() end },
    ["widgets/tabgroup"] = { DeselectAll = function() end },
}
local _require = function(n) return STUBS[n] or {} end
require = _require

-- 有状态的 net_string mock（记录 set 次数与最终值）
local NETSTATS = { sets = 0 }
local function make_net_string(g, name, ev)
    local v = ""
    local holder
    holder = {
        set = function(_, s) NETSTATS.sets = NETSTATS.sets + 1; v = s; holder.__onset(s) end,
        value = function() return v end,
        __onset = function() end,
        __event = ev,
    }
    return holder
end

GLOBAL = {
    tonumber = tonumber, tostring = tostring, type = type, pairs = pairs, ipairs = ipairs,
    math = math, table = table, string = string, GetTime = GetTime, require = _require,
    AllRecipes = {}, ThePlayer = nil,
    net_string = make_net_string,
    TheSim = { FindEntities = function(_, x, y, z, r)
        local out = {}
        for _, e in ipairs(all_ents) do if e.valid and e.tags["_container"] then out[#out + 1] = e end end
        return out
    end },
    TheNet = { GetIsServer = function() return false end, IsDedicated = function() return false end,
        GetIsClient = function() return true end },
    TheWorld = NewEntity("world"),
}
GLOBAL.GLOBAL = GLOBAL
TheSim = GLOBAL.TheSim

assert(loadfile(MODMAIN))()
flush()

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  [PASS] " .. name)
    else fail = fail + 1; print("  [FAIL] " .. name .. "   " .. tostring(detail or "")) end
end

-- 构造一个"客户端视角"的箱子 replica
local function MakeChestReplica(items, opened)
    local e = NewEntity("treasurechest")
    e:AddTag("_container")
    local rep = {
        inst = e,
        classified = opened and {
            Has = function(_, p, a) local n = items[p] or 0; return n >= a, n end,
        } or nil,
        opener = opened and NewEntity("wilson") or nil,
        -- 原版 Container_Replica:Has
        Has = function(self, p, a, c)
            if self.inst.components.container ~= nil then
                return self.inst.components.container:Has(p, a, c)
            elseif self.classified ~= nil and self.opener ~= nil then
                return self.classified:Has(p, a, c)
            else
                return a <= 0, 0
            end
        end,
        IsReadOnlyContainer = function() return false end,
    }
    e.replica.container = rep
    for _, fn in ipairs(POST["components/container_replica"] or {}) do fn(rep) end
    -- 模拟服务端把内容广播过来
    local parts = {}
    for k, v in pairs(items) do parts[#parts + 1] = k .. " " .. v end
    if e._item_str then
        e._item_str.set(nil, table.concat(parts, " "))
        e:PushEvent("on_container_dirty")
    end
    return e, rep
end

-- 客户端 inventory_replica
local function MakePlayerReplica(open_chests)
    local e = NewEntity("wilson")
    e:AddTag("player")
    local rep = {
        inst = e,
        Has = function(self, p, a, c)
            -- 客户端原版：classified 会把"已打开的容器"算进去
            local n = 0
            for chest in pairs(open_chests or {}) do
                local crep = chest.replica.container
                if crep.classified then
                    local _, f = crep.classified:Has(p, a, c)
                    n = n + f
                end
            end
            return n >= a, n
        end,
        GetOverflowContainer = function() return nil end,
        GetOpenContainers = function() return open_chests or {} end,
    }
    e.replica.inventory = rep
    for _, fn in ipairs(POST["components/inventory_replica"] or {}) do fn(rep) end
    return e, rep
end

print("=== " .. MODMAIN .. " (client) ===")

-- C1：未打开的箱子，靠 net_string 广播的数据判断
do
    local chest = MakeChestReplica({ log = 12, rocks = 5 }, false)
    local crep = chest.replica.container
    local has, n = crep:Has("log", 4, true)
    check("C1 未打开箱子能读到广播数量", has and n == 12, "has=" .. tostring(has) .. " n=" .. tostring(n))
    local has2, n2 = crep:Has("boards", 1, true)
    check("C1 不存在的材料返回 0", (not has2) and n2 == 0, "n=" .. tostring(n2))
end

-- C2：已打开的箱子不应被重复计数
--     构造成"原版统计不足、必须继续遍历箱子"的情形，才会走到出 bug 的分支
do
    all_ents = {}
    clock = clock + 100
    local opened = MakeChestReplica({ twigs = 6 }, true)   -- 已打开：原版 classified 已统计
    local closed = MakeChestReplica({ twigs = 4 }, false)  -- 未打开：只能靠广播
    local open = { [opened] = true }
    local player, prep = MakePlayerReplica(open)
    local has, n = prep:Has("twigs", 10, true)
    check("C2 已打开箱子不重复计数", n == 10,
        "n=" .. tostring(n) .. "（期望 10 = 6 已开 + 4 未开；重复计数会是 16）")
    check("C2 判定结果正确", has == true, "has=" .. tostring(has))
end

print(string.format("\n结果: %d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
