-- 回归测试：加载真实 modmain，通过服务端事件、网络快照和客户端 HUD 验证。
-- python test/runner.py sync_refresh.lua modmain.lua [降低客户端卡顿/modmain.lua]
local target = arg[1]
local function loadenv(path, env)
    if setfenv then
        local fn = assert(loadfile(path))
        setfenv(fn, env)
        return fn()
    end
    return assert(loadfile(path, "t", env))()
end

local function Runtime(server)
    local r = {time=0, entities={}, tasks={}, periodic={}, hooks={}, players={}, sets=0, scans=0}
    local g = {}
    for k,v in pairs(_G) do g[k]=v end
    local env = {GLOBAL=g}
    -- DST mod 环境只显式提供所需 API，不能依赖普通 Lua 全局泄漏。
    env.env = env
    env.GetModConfigData = function(k) return ({MAX_RANGE=5, REFRESH_TIME=5})[k] end
    env.AddComponentPostInit = function() end
    env.AddClassPostConstruct = function(name, fn) r.hooks[name] = fn end
    env.AddPlayerPostInit = function(fn) r.players[#r.players+1] = fn end
    env.AddPrefabPostInit = function() end
    local stubs = {
        ["components/highlight"]={ApplyColour=function() end, UnHighlight=function() end},
        ["widgets/redux/craftingmenu_pinslot"]={OnGainFocus=function() end, OnLoseFocus=function() end, OnCraftingMenuClose=function() end},
        ["widgets/tabgroup"]={DeselectAll=function() end},
    }
    g.require = function(name) return stubs[name] or {} end
    env.require = g.require
    env.print = print
    g.GetTime = function() return r.time end
    g.TheNet = {GetIsServer=function() return server end, IsDedicated=function() return false end, GetIsClient=function() return not server end}
    g.TheSim = {FindEntities=function(_, x, y, z, radius)
        r.scans = r.scans + 1
        local found = {}
        for _, e in ipairs(r.entities) do
            if e.valid and e.replica.container and (e.x-x)^2+(e.z-z)^2 <= radius^2 then found[#found+1]=e end
        end
        return found
    end}
    g.net_string = function(guid, name, event)
        local net = {data="", event=event}
        function net:set(value) self.data=value; r.sets=r.sets+1 end
        function net:value() return self.data end
        r.entities[guid].nets[name] = net
        return net
    end
    function r:entity(x)
        local e = {GUID=#self.entities+1, x=x or 0, z=0, valid=true, components={}, replica={}, events={}, nets={}}
        self.entities[e.GUID]=e
        e.Transform={GetWorldPosition=function() return e.x,0,e.z end}
        e.entity={IsVisible=function() return e.valid end}
        function e:IsValid() return self.valid end
        function e:HasTag() return false end
        function e:ListenForEvent(name,fn) self.events[name]=self.events[name] or {}; table.insert(self.events[name],fn) end
        function e:PushEvent(name,data) for _,fn in ipairs(self.events[name] or {}) do fn(self,data) end end
        function e:DoTaskInTime(delay,fn)
            local task={time=r.time+delay, fn=function() if self.valid then fn(self) end end}
            function task:Cancel() self.cancelled=true end
            table.insert(r.tasks,task)
            return task
        end
        function e:DoPeriodicTask(interval,fn)
            table.insert(r.periodic,{interval=interval,at=r.time+interval,fn=function() if self.valid then fn(self) end end})
            return {Cancel=function() end}
        end
        return e
    end
    function r:flush()
        for _=1,10 do
            local pending=self.tasks; self.tasks={}
            local ran=false
            for _,task in ipairs(pending) do
                if not task.cancelled then
                    if task.time<=self.time then task.fn(); ran=true else table.insert(self.tasks,task) end
                end
            end
            if not ran then break end
        end
    end
    function r:advance(dt)
        self.time=self.time+dt
        for _,task in ipairs(self.periodic) do
            if task.at<=self.time then task.at=self.time+task.interval; task.fn() end
        end
        self:flush()
    end
    function r:chest(items,x,opts)
        local e=self:entity(x)
        local c={inst=e, slots={}, IsEmpty=function(self) return next(self.slots)==nil end}
        for prefab,count in pairs(items or {}) do
            local item={prefab=prefab, components={stackable={StackSize=function() return count end}}, IsValid=function() return true end, HasTag=function() return false end}
            c.slots[#c.slots+1]=item
        end
        if opts and opts.tags then
            e.HasTag=function(_,tag) return opts.tags[tag]==true end
        end
        if opts and opts.notransform then
            e.Transform=nil
        end
        if server then e.components.container=c end
        local rep={inst=e, Has=function() return false,0 end, IsReadOnlyContainer=function() return false end}
        e.replica.container=rep
        self.hooks["components/container_replica"](rep)
        return e,c
    end
    function r:deliver(source,dest)
        local events={}
        for name,net in pairs(source.nets) do
            assert(dest.nets[name], "server/client netvar mismatch")
            dest.nets[name].data=net.data
            events[net.event]=true
        end
        for event in pairs(events) do dest:PushEvent(event) end
    end
    function r:broadcast(chest,items)
        local parts={}
        for prefab,n in pairs(items) do parts[#parts+1]=prefab.." "..n end
        chest._item_str.data=table.concat(parts," ")
        chest:PushEvent("on_container_dirty")
    end
    function r:player()
        local e=self:entity()
        local rep={inst=e, GetOverflowContainer=function() end, GetOpenContainers=function() return {} end, Has=function() return false,0 end}
        e.replica.inventory=rep
        self.hooks["components/inventory_replica"](rep)
        e.HUD={IsCraftingOpen=function() return false end}
        e.refreshes=0
        e:ListenForEvent("refreshcrafting",function() e.refreshes=e.refreshes+1 end)
        g.ThePlayer=e
        for _,fn in ipairs(self.players) do fn(e) end
        return e,rep
    end
    r.g=g; r.env=env
    loadenv(target,env)
    return r
end

local pass,fail=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then pass=pass+1; print("[PASS] "..name)
    else fail=fail+1; print("[FAIL] "..name..": "..tostring(err)) end
end
local function eq(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end

test("large inventory roundtrip, shrink and empty",function()
    local s,c=Runtime(true),Runtime(false)
    local items={}
    for i=1,80 do items["long_mod_material_prefab_"..i]=i end
    local source,container=s:chest(items)
    local dest=c:chest({})
    s:flush(); c:deliver(source,dest)
    for prefab,n in pairs(items) do local has,count=dest.replica.container:Has(prefab,n,true); eq(count,n); eq(has,true) end
    container.slots={container.slots[1]}
    source:PushEvent("itemlose"); s:flush(); c:deliver(source,dest)
    local kinds=0; for _ in pairs(dest.buffered_items) do kinds=kinds+1 end; eq(kinds,1)
    container.slots={}; source:PushEvent("itemlose"); s:flush(); c:deliver(source,dest)
    eq(next(dest.buffered_items),nil)
end)

test("server batches changes and skips unchanged snapshots",function()
    local r=Runtime(true); local chest,container=r:chest({log=10,rocks=20})
    r:flush(); local before=r.sets
    for _=1,20 do chest:PushEvent("itemget") end
    r:flush(); eq(r.sets,before)
    container.slots={}; for _=1,20 do chest:PushEvent("itemlose") end
    r:flush(); eq(r.sets,before+1)
end)

test("dirty data refreshes closed menu once and invalidates empty chest cache",function()
    local r=Runtime(false); local p,inv=r:player()
    eq(inv:Has("log",4,true),false)
    local a=r:chest({}); local b=r:chest({})
    r:broadcast(a,{log=2}); r:broadcast(b,{log=3}); r:flush()
    eq(inv:Has("log",4,true),true); eq(p.refreshes,1)
    r:advance(6); eq(p.refreshes,1)
    r:broadcast(a,{log=2}); r:flush(); eq(p.refreshes,1)
    r:broadcast(a,{}); r:broadcast(b,{}); r:flush()
    eq(inv:Has("log",1,true),false); eq(p.refreshes,2)
end)

test("far chest updates do not refresh recipes",function()
    local r=Runtime(false); local p=r:player(); local chest=r:chest({},100)
    r:broadcast(chest,{log=10}); r:flush(); r:advance(6); eq(p.refreshes,0)
end)

test("movement invalidates cached range for immediate ingredient queries",function()
    local r=Runtime(false); local p,inv=r:player(); local chest=r:chest({},10)
    r:broadcast(chest,{log=10}); r:flush()
    eq(inv:Has("log",4,true),false)
    p.x=10; eq(inv:Has("log",4,true),true)
    p.x=0; eq(inv:Has("log",4,true),false)
end)

test("closed-menu polling detects approach, departure and destroyed chest without idle spam",function()
    local r=Runtime(false); local p=r:player(); local chest=r:chest({},10)
    r:broadcast(chest,{log=10}); r:flush(); r:advance(6); eq(p.refreshes,0)
    p.x=10; r:advance(1); eq(p.refreshes,1)
    r:advance(6); eq(p.refreshes,1)
    p.x=0; r:advance(1); eq(p.refreshes,2)
    p.x=10; r:advance(1); eq(p.refreshes,3)
    chest.valid=false; r:advance(1); eq(p.refreshes,4)
end)

test("listen-server host also refreshes closed-menu crafting",function()
    local r=Runtime(true); local p=r:player(); r:chest({log=10}); r:flush(); r:advance(1)
    eq(p.refreshes,1); r:advance(6); eq(p.refreshes,1)
end)

test("late HUD initialization retains pending material changes",function()
    local r=Runtime(false); local p=r:player(); p.HUD=nil
    local chest=r:chest({}); r:broadcast(chest,{log=10}); r:flush(); eq(p.refreshes,0)
    p.HUD={IsCraftingOpen=function() return false end}
    r:advance(1); eq(p.refreshes,1)
    -- 打开的菜单也不应该因为轮询而重复全量刷新。
    p.HUD.IsCraftingOpen=function() return true end
    r:advance(6); eq(p.refreshes,1)
end)

test("excluded and nocrafting items are not broadcast as usable materials",function()
    local s,c=Runtime(true),Runtime(false)
    local source,container=s:chest({log=10})
    local dest=c:chest({})
    container.slots[1].HasTag=function(_,tag) return tag=="nocrafting" end
    s:flush(); c:deliver(source,dest); eq(dest.replica.container:Has("log",1,true),false)
    container.slots[1].HasTag=function() return false end
    source:PushEvent("stacksizechange"); s:flush(); c:deliver(source,dest)
    eq(dest.replica.container:Has("log",10,true),true)
    container.excludefromcrafting=true
    source:PushEvent("onclose"); s:flush(); c:deliver(source,dest)
    eq(dest.replica.container:Has("log",1,true),false)
    container.excludefromcrafting=false; container.readonlycontainer=true
    source:PushEvent("itemget"); s:flush(); c:deliver(source,dest)
    eq(dest.replica.container:Has("log",1,true),false)
end)

test("stack changes roundtrip and refresh without opening the chest",function()
    local s,c=Runtime(true),Runtime(false)
    local p,inv=c:player(); local source,container=s:chest({log=10}); local dest=c:chest({})
    s:flush(); c:deliver(source,dest); c:flush(); eq(p.refreshes,1)
    container.slots[1].components.stackable.StackSize=function() return 3 end
    source:PushEvent("stacksizechange"); s:flush(); c:deliver(source,dest); c:flush()
    local has,n=inv:Has("log",4,true); eq(has,false); eq(n,3); eq(p.refreshes,2)
end)

test("shadow pocket container without Transform neither crashes nor refreshes",function()
    local s,c=Runtime(true),Runtime(false)
    s:player()                        -- 服务端也必须有 ThePlayer，崩溃正好发生在这里
    local p,inv=c:player()
    local source,container=s:chest({log=10}); local dest=c:chest({})
    -- 暗影切斯特 / 魔术箱共用口袋维度容器：不在世界里，没有 Transform
    source.Transform=nil; dest.Transform=nil
    s:flush()                         -- DoUpdateContainer -> QueueNearbyCraftingRefresh
    c:deliver(source,dest); c:flush() -- on_container_dirty -> QueueNearbyCraftingRefresh
    local has,n=inv:Has("log",10,true)
    eq(has,true); eq(n,10)            -- 广播内容照常可用
    eq(p.refreshes,0)                 -- 它不是附近的材料源，不应触发刷新
end)

test("pocket dimension container is fully excluded from the mod",function()
    local s,c=Runtime(true),Runtime(false)
    s:player()
    local p,inv=c:player()
    local opts={tags={pocketdimension_container=true}}
    local source=s:chest({log=10},0,opts)
    local dest=c:chest({},0,{tags={pocketdimension_container=true},notransform=true})
    s:flush()
    eq(next(source.nets),nil)          -- 服务端不挂 mod 网络串
    c:deliver(source,dest); c:flush()  -- 也不应因缺少 Transform 崩溃
    eq(next(dest.nets),nil)
    eq(dest.buffered_items,nil)        -- 未被 mod 初始化
end)

-- 可选：运行用户提供的真实优化模组，不复制或改写第三方实现。
if arg[2] then
    test("actual lag mod: pinned recipes update with menu closed and full rebuild stays deferred",function()
        local r=Runtime(false); local p,inv=r:player()
        local rec={name="boards"}; r.g.AllRecipes={boards=rec}
        r.g.IsRecipeValid=function() return true end
        r.g.TheCraftingMenuProfile={GetPinnedRecipes=function() return {{recipe_name="boards"}} end}
        p.replica.builder={IsFreeBuildMode=function() return false end,CanLearn=function() return true end,
            KnowsRecipe=function() return true end,IsBuildBuffered=function() return false end,
            HasIngredients=function() return inv:Has("log",4,true) end}
        local hooks={}
        local env={GLOBAL=r.g,AddClassPostConstruct=function(name,fn) hooks[name]=fn end,AddPrefabPostInit=function() end}
        env.env=env; loadenv(arg[2],env)
        local pinbar={owner=p,RefreshPinnedRecipes=function() end,Refresh=function() end}
        hooks["widgets/redux/craftingmenu_pinbar"](pinbar); pinbar:RefreshPinnedRecipes()
        local full=0
        local hud={is_open=false, valid_recipes={},pinbar=pinbar,craftingmenu={Refresh=function() end},
            IsCraftingOpen=function(self) return self.is_open end,Open=function(self) self.is_open=true end,
            RefreshCraftingHelpText=function() end,
            RebuildRecipes=function(self) full=full+1; self.valid_recipes.boards={meta={can_build=inv:Has("log",4,true)}} end}
        hooks["widgets/redux/craftingmenu_hud"](hud)
        p:ListenForEvent("refreshcrafting",function() hud.needtoupdate=true end)
        hud.needtoupdate=true; hud:OnUpdate()
        local chest=r:chest({}); r:broadcast(chest,{log=10}); r:flush(); hud:OnUpdate()
        eq(hud.valid_recipes.boards.meta.can_build,true); eq(full,1)
        hud:Open(); eq(full,2)
    end)
else
    print("[SKIP] actual lag mod integration (pass its modmain.lua as an extra argument)")
end
print(string.format("sync/refresh: %d passed, %d failed",pass,fail))
os.exit(fail==0 and 0 or 1)
