-- Reading a quick full scan without asking the same thing on every row.
--
-- On a big auction house (about 245,000 rows, 7,000 items) the snapshot came
-- in seconds and the read took minutes. Every row of an item with no
-- commodity status on record walked every bag slot looking for it, and the
-- miss was kept only ten seconds, so a long read walked the same items again
-- and again. Whose listing a row is, and the stack size of an item the client
-- has not cached, were also worked out again on every row.
--
-- Now the bags are walked once into an index, and each of those answers is
-- worked out once per item (or seller) per scan. The answers must not change.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "GetTime", "time", "C_Timer", "C_Item", "C_AuctionHouse",
    "C_Container", "ItemLocation", "UnitName", "GetRealmName" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

local function Blank()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end

-- A clock that moves with every row read: 160 rows take 8 seconds, so the
-- old ten second memo of a miss never runs out and is not what saves time.
local clock = 1000
CreateFrame = function() return Blank() end
GetTime = function() return clock end
time = function() return 100000 end
C_Timer = {
    After = noop,
    NewTimer = function() return { Cancel = noop } end,
    NewTicker = function() return { Cancel = noop } end,
}
UnitName = function() return "Me" end
GetRealmName = function() return "TestRealm" end

local HERB, ORE, UNCACHED = 765, 2770, 4444
local OTHERS = {}
for i = 1, 10 do OTHERS[i] = 5000 + i end

-- Five bags of twenty slots. The player holds herbs and ore, nothing else.
local BAGS, SLOTS = 5, 20
local bags = {}
for bag = 0, BAGS - 1 do bags[bag] = {} end
bags[0][3] = HERB
bags[2][7] = ORE

local slotReads = 0
C_Container = {
    GetContainerNumSlots = function() return SLOTS end,
    GetContainerItemInfo = function(bag, slot)
        slotReads = slotReads + 1
        local id = bags[bag] and bags[bag][slot]
        return id and { itemID = id, stackCount = 1 } or nil
    end,
}

ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        return { bag = bag, slot = slot, IsValid = function() return true end }
    end,
}

-- Herbs are commodities, ore is not, as the game says for a held item.
local status = { [HERB] = 2, [ORE] = 1 }

local stackSizes = { [HERB] = 20, [ORE] = 20 }
for _, id in ipairs(OTHERS) do stackSizes[id] = 20 end
local infoAsks = {}
C_Item = {
    GetItemInfo = function(itemID)
        infoAsks[itemID] = (infoAsks[itemID] or 0) + 1
        local stack = stackSizes[itemID]
        if not stack then return nil end
        return "item", "link", 1, 1, 1, "Trade Goods", "Herb", stack
    end,
}

-- The snapshot's rows: how many, the buyout of the whole row, the item, the
-- seller.
local rows = {}
C_AuctionHouse = {
    GetReplicateItemInfo = function(index)
        clock = clock + 0.05
        local row = rows[index + 1]
        if not row then return nil end
        if row.before then row.before() end
        return "x", 0, row[1], 1, true, 1, "", 0, 0, row[2], 0, false, nil,
            row[4], row[4] .. "-TestRealm", 0, row[3], true
    end,
    GetItemCommodityStatus = function(location)
        local id = bags[location.bag] and bags[location.bag][location.slot]
        return id and status[id] or 0
    end,
}

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop

local priceTable = {}
ns.db = { commodity = {} }
ns.Config = {
    Get = function() return nil end,
    GetRealmKey = function() return "TestRealm-Alliance" end,
    GetPriceTable = function() return priceTable end,
}
ns.Inventory = {
    GetCarriedBags = function()
        local list = {}
        for bag = 0, BAGS - 1 do list[#list + 1] = bag end
        return list
    end,
}

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Scanner.lua"))("Blackthornes_TS", ns)

local Prices, Scanner = ns.Prices, ns.Scanner

-- Run the worker straight through.
ns.Util.NewWorker = function(opts)
    return { Start = function(_, items)
        for _, item in ipairs(items) do opts.onItem(item) end
        if opts.onDone then opts.onDone() end
    end }
end

local ownAsks = 0
local IsOwnAuction = Scanner.IsOwnAuction
Scanner.IsOwnAuction = function(...)
    ownAsks = ownAsks + 1
    return IsOwnAuction(...)
end

local function QuickScan(snapshot)
    rows = snapshot
    Scanner.isScanning = true
    Scanner.scanStartedWall = time()
    Scanner:ReadReplicateResults(#rows)
end

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
        print(("  ok    %s"):format(label))
    else
        failed = failed + 1
        print(("  FAIL  %s"):format(label))
    end
end

-- Ten rows for each of ten items nobody holds, spread out as the snapshot
-- spreads them, then herbs and ore, then an item the client has not cached.
-- Two sellers, one of them the player.
local snapshot = {}
for round = 1, 10 do
    for _, id in ipairs(OTHERS) do
        snapshot[#snapshot + 1] = { 5, 500 + round, id, round % 2 == 0 and "Rival" or "Other" }
    end
end
for _ = 1, 5 do
    snapshot[#snapshot + 1] = { 40, 4000, HERB, "Rival" }   -- 1s each, a commodity
    snapshot[#snapshot + 1] = { 5, 1000, ORE, "Rival" }     -- 2s each, a stack of 5
    snapshot[#snapshot + 1] = { 3, 300, UNCACHED, "Rival" }
end
snapshot[#snapshot + 1] = { 1, 150, ORE, "Me" }

print("")
print("one read of the snapshot")

QuickScan(snapshot)

local slotCount = BAGS * SLOTS
check(("the bags are walked once (%d slot reads for %d slots)"):format(slotReads, slotCount),
    slotReads <= slotCount + 10)
check(("whose listing a row is, asked once a seller (%d asks)"):format(ownAsks), ownAsks <= 3)
check(("an item the client has not cached is asked about once (%d asks)"):format(infoAsks[UNCACHED] or 0),
    (infoAsks[UNCACHED] or 0) <= 1)

print("")
print("the prices are the same as before")

do
    local herb, ore = Prices:Get(HERB), Prices:Get(ORE)
    check("herbs held in the bags are known to be a commodity", Scanner:GetCommodityStatus(HERB) == true)
    check("ore held in the bags is known to be an item auction", Scanner:GetCommodityStatus(ORE) == false)
    check("herbs read at 1s each", herb ~= nil and herb.min == 100)
    check("ore reads at 2s each", ore ~= nil and ore.rivalMin == 200)
    check("the player's own ore listing is theirs", ore ~= nil and ore.ownMin == 150)
    check("an uncached item still gets a price per one", Prices:Get(UNCACHED) ~= nil
        and Prices:Get(UNCACHED).min == 100)
    local other = Prices:Get(OTHERS[1])
    check("an item nobody holds is priced from its cheapest row", other ~= nil and other.min == 100)
end

print("")
print("bags that moved without telling us")

do
    -- Outside a scan nothing is kept: a herb put in the bags is found at
    -- once, before any bag event.
    local PUT = 785
    status[PUT] = 2
    Scanner:GetCommodityStatus(PUT)            -- not held yet
    Scanner:ForgetNotHeld()
    bags[1][1] = PUT
    check("a herb just put in the bags is found", Scanner:GetCommodityStatus(PUT) == true)

    -- During a read, a stack moves to another bag after the index was made.
    local MOVED = 2447
    status[MOVED] = 2
    bags[3][4] = MOVED
    QuickScan({
        { 5, 500, OTHERS[1] + 100, "Rival" },  -- makes the index, MOVED in bag 3
        { 5, 500, OTHERS[2] + 100, "Rival", before = function()
            bags[3][4] = nil
            bags[4][9] = MOVED                 -- moved, no event
        end },
        { 40, 4000, MOVED, "Rival" },
    })
    check("a stack moved during the read is still found",
        Scanner:GetCommodityStatus(MOVED) == true)
    check("and read as a commodity", Prices:Get(MOVED) ~= nil and Prices:Get(MOVED).min == 100)
end

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d check(s) failed"):format(failed)) end
