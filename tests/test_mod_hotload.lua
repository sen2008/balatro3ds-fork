--- In-game mod loading: a mod turned off at boot loads into the running session when it
--- is switched on (`ModLoader.set_enabled` -> `ModLoader.load_mod`), dependencies first,
--- with the boot pass's rollback and error reporting; switching off never unloads, and
--- inside a run the switch only queues the choice for the next boot.
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

bootstrap.load()
local ModLoader = require("mod_loader")
local CollectionCatalog = require("collection_catalog")

--------------------------------------------------------------------------------
-- Fixtures (the same shape as tests/test_mods.lua: mods are files in the stub fs)
--------------------------------------------------------------------------------

local function wipe_mods()
    local fs = love.filesystem
    local function rm(path)
        for _, item in ipairs(fs.getDirectoryItems(path)) do
            local child = path .. "/" .. item
            if fs.getInfo(child, "file") then fs.remove(child) else rm(child); fs.remove(child) end
        end
    end
    if fs.getInfo(ModLoader.DIR) then rm(ModLoader.DIR) end
    ModLoader.reset()
end

local function write_mod(folder, manifest, main)
    local base = ModLoader.DIR .. "/" .. folder
    love.filesystem.createDirectory(base)
    local parts = {}
    for k, v in pairs(manifest) do
        local value
        if type(v) == "table" then
            local items = {}
            for _, x in ipairs(v) do items[#items + 1] = ("%q"):format(x) end
            value = "[" .. table.concat(items, ", ") .. "]"
        else
            value = ("%q"):format(tostring(v))
        end
        parts[#parts + 1] = ("%q: %s"):format(k, value)
    end
    love.filesystem.write(base .. "/" .. folder .. ".json", "{" .. table.concat(parts, ",\n") .. "}")
    love.filesystem.write(base .. "/" .. (manifest.main_file or "main.lua"), main)
    for file in main:gmatch('sprite%s*=%s*"([^"]+)"') do
        love.filesystem.write(base .. "/assets/1x/" .. file, "png")
    end
end

local function write_disabled(ids)
    love.filesystem.createDirectory(ModLoader.DIR)
    love.filesystem.write(ModLoader.DISABLED_PATH, table.concat(ids, "\n") .. "\n")
end

local function one_joker(key, sprite)
    return ("SMODS.Joker { key = %q, loc_txt = { name = %q, text = { \"x\" } }, rarity = 1, cost = 1, sprite = %q }\n")
        :format(key, key, sprite or (key .. ".png"))
end

local function collection_has_joker(id)
    for _, entry in ipairs(CollectionCatalog.build_joker_entries()) do
        if entry.id == id then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

suite.test("hot-load: a mod off at boot loads when switched on, registered and reachable", function()
    wipe_mods()
    write_mod("Hot", { id = "HotMod", prefix = "hot", main_file = "main.lua", version = "1" }, [[
SMODS.Joker {
    key = "alpha",
    loc_txt = { name = "Alpha", text = { "+4 Mult" } },
    config = { extra = { mult = 4 } },
    rarity = 1, cost = 2, sprite = "alpha.png", negative_sprite = "alpha_negative.png",
    calculate = function(self, card, context)
        if context.joker_main then return { mult = card.ability.extra.mult } end
    end,
}
]])
    write_disabled({ "HotMod" })
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.HotMod.status, "disabled")
    T.assert_eq(JOKER_DEFS.j_hot_alpha, nil, "not registered while off")
    T.assert_eq(SMODS.Sprites["mod:hot:alpha.png"], nil, "no sprite while off")

    local game = bootstrap.new_game(7701)
    G = game
    T.assert_false(collection_has_joker("j_hot_alpha"), "not in the collection while off")

    T.assert_true(ModLoader.set_enabled("HotMod", true))
    local mod = ModLoader.by_id.HotMod
    T.assert_eq(mod.status, "loaded", tostring(mod.error))
    T.assert_true(JOKER_DEFS.j_hot_alpha ~= nil, "registered by the switch, no reboot")
    T.assert_eq(JOKER_DEFS.j_hot_alpha.mod_id, "HotMod")
    -- Sprites ride the same registration: the plain image and the negative variant.
    T.assert_true(SMODS.Sprites["mod:hot:alpha.png"] ~= nil, "sprite registered")
    T.assert_true(SMODS.Sprites["mod:hot:alpha_negative.png"] ~= nil, "negative sprite registered")
    T.assert_true(SMODS.image("mod:hot:alpha.png") ~= nil, "sprite loads through SMODS.image")
    -- Pool-visible: the shop pools iterate JOKER_DEFS, and the collection lists it too.
    T.assert_true(collection_has_joker("j_hot_alpha"), "in the collection after the switch")
    T.assert_true(love.filesystem.read(ModLoader.LOG_PATH):find("[OK] HotMod", 1, true) ~= nil,
        "the log is rewritten with the new state")
    wipe_mods()
end)

suite.test("hot-load: a failing mod rolls back and leaves the loaded set untouched", function()
    wipe_mods()
    write_mod("Good", { id = "GoodMod", prefix = "good", main_file = "main.lua", version = "1" },
        one_joker("g1"))
    write_mod("Broken", { id = "BrokenMod", prefix = "brk", main_file = "main.lua", version = "1" }, [[
SMODS.Joker { key = "half", loc_txt = { name = "Half", text = { "x" } }, rarity = 1, cost = 1, sprite = "half.png" }
error("boom")
]])
    write_disabled({ "BrokenMod" })
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.GoodMod.status, "loaded")
    T.assert_eq(ModLoader.by_id.BrokenMod.status, "disabled")

    T.assert_true(ModLoader.set_enabled("BrokenMod", true))
    local broken = ModLoader.by_id.BrokenMod
    T.assert_eq(broken.status, "error", "the failure is reported on the mod, like a boot failure")
    T.assert_true(broken.error:find("boom", 1, true) ~= nil, tostring(broken.error))
    T.assert_eq(JOKER_DEFS.j_brk_half, nil, "what it registered before throwing is rolled back")
    T.assert_eq(SMODS.Sprites["mod:brk:half.png"], nil, "its sprite goes with it")
    T.assert_eq(ModLoader.by_id.GoodMod.status, "loaded", "the loaded set is undisturbed")
    T.assert_true(JOKER_DEFS.j_good_g1 ~= nil)
    T.assert_eq(#ModLoader.fingerprint(), 1)
    T.assert_eq(ModLoader.fingerprint()[1].id, "GoodMod")
    T.assert_true(love.filesystem.read(ModLoader.LOG_PATH):find("[ERROR] BrokenMod", 1, true) ~= nil)
    wipe_mods()
end)

suite.test("hot-load: dependencies load first in order; a turned-off dependency refuses", function()
    wipe_mods()
    -- A <- B <- C by dependency; C is broken, so the whole chain fails at boot.
    write_mod("ChainC", { id = "ChainC", prefix = "cc", main_file = "main.lua", version = "1" },
        'error("chain c is broken")')
    write_mod("ChainB", { id = "ChainB", prefix = "cb", main_file = "main.lua", version = "1",
        dependencies = { "ChainC (>=1)" } }, one_joker("j"))
    write_mod("ChainA", { id = "ChainA", prefix = "ca", main_file = "main.lua", version = "1",
        dependencies = { "ChainB (>=1)" } }, one_joker("j"))
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.ChainC.status, "error")
    T.assert_eq(ModLoader.by_id.ChainB.status, "error")
    T.assert_true(ModLoader.by_id.ChainA.error:find("failed to load", 1, true) ~= nil,
        tostring(ModLoader.by_id.ChainA.error))

    -- Fix C on the card and switch A on: C and B load on the way, in dependency order.
    write_mod("ChainC", { id = "ChainC", prefix = "cc", main_file = "main.lua", version = "1" },
        one_joker("j"))
    T.assert_true(ModLoader.set_enabled("ChainA", true))
    T.assert_eq(ModLoader.by_id.ChainC.status, "loaded", tostring(ModLoader.by_id.ChainC.error))
    T.assert_eq(ModLoader.by_id.ChainB.status, "loaded", tostring(ModLoader.by_id.ChainB.error))
    T.assert_eq(ModLoader.by_id.ChainA.status, "loaded", tostring(ModLoader.by_id.ChainA.error))
    T.assert_true(JOKER_DEFS.j_cc_j.order < JOKER_DEFS.j_cb_j.order
        and JOKER_DEFS.j_cb_j.order < JOKER_DEFS.j_ca_j.order,
        "dependencies registered before their dependants")

    -- A dependency the player turned off refuses the load, with the boot pass's words.
    wipe_mods()
    write_mod("OffDep", { id = "OffDep", prefix = "od", main_file = "main.lua", version = "1" },
        one_joker("j"))
    write_mod("Needy", { id = "Needy", prefix = "nd", main_file = "main.lua", version = "1",
        dependencies = { "OffDep (>=1)" } }, one_joker("j"))
    write_disabled({ "OffDep" })
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Needy.status, "error")
    T.assert_true(ModLoader.set_enabled("Needy", true))
    T.assert_eq(ModLoader.by_id.Needy.status, "error", "still refused while the dependency is off")
    T.assert_true(ModLoader.by_id.Needy.error:find("turned off", 1, true) ~= nil,
        tostring(ModLoader.by_id.Needy.error))
    T.assert_eq(JOKER_DEFS.j_nd_j, nil)
    -- Turning the dependency on heals the dependant without touching it.
    T.assert_true(ModLoader.set_enabled("OffDep", true))
    T.assert_eq(ModLoader.by_id.Needy.status, "loaded", tostring(ModLoader.by_id.Needy.error))
    T.assert_true(JOKER_DEFS.j_nd_j ~= nil)
    wipe_mods()
end)

suite.test("hot-load: inside a run the switch only queues; off never unloads", function()
    wipe_mods()
    write_mod("Fenced", { id = "Fenced", prefix = "fen", main_file = "main.lua", version = "1" },
        one_joker("j"))
    write_disabled({ "Fenced" })
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Fenced.status, "disabled")

    local game = bootstrap.new_game(7702)
    G = game
    game.STAGE = game.STAGES.RUN
    T.assert_false(ModLoader.hot_load_allowed(), "no hot-load while a run is in memory")
    T.assert_true(ModLoader.set_enabled("Fenced", true))
    T.assert_eq(ModLoader.by_id.Fenced.status, "pending", "queued, not loaded")
    T.assert_eq(JOKER_DEFS.j_fen_j, nil, "nothing registers mid-run")
    T.assert_eq(ModLoader.disabled.Fenced, nil, "but the choice is recorded")

    -- Back at the menu the queued choice is still just a queue: the next boot loads it.
    game.STAGE = game.STAGES.MAIN_MENU
    T.assert_true(ModLoader.hot_load_allowed())
    T.assert_eq(ModLoader.by_id.Fenced.status, "pending")
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Fenced.status, "loaded", "the queued mod loads at the next boot")
    T.assert_true(JOKER_DEFS.j_fen_j ~= nil)

    -- Off is a recording, not an unload: content stays until the next boot, and turning
    -- it back on does not run the main file a second time.
    wipe_mods()
    write_mod("Sticky", { id = "Sticky", prefix = "stk", main_file = "main.lua", version = "1" }, [[
_MOD._runs = (_MOD._runs or 0) + 1
SMODS.Joker { key = "j", loc_txt = { name = "J", text = { "x" } }, rarity = 1, cost = 1, sprite = "j.png" }
]])
    ModLoader.load_all()
    local sticky = ModLoader.by_id.Sticky
    T.assert_eq(sticky.status, "loaded")
    T.assert_eq(sticky._runs, 1)
    T.assert_true(ModLoader.set_enabled("Sticky", false))
    T.assert_eq(sticky.status, "disabled")
    T.assert_true(JOKER_DEFS.j_stk_j ~= nil, "still in the session until the next boot")
    T.assert_true(ModLoader.set_enabled("Sticky", true))
    T.assert_eq(sticky.status, "loaded")
    T.assert_eq(sticky._runs, 1, "re-enabling a live mod does not re-run it")
    wipe_mods()
end)

suite.test("hot-load: a poker hand joins the live game's handlist through the refresh", function()
    wipe_mods()
    write_mod("Handsy", { id = "Handsy", prefix = "hnd", main_file = "main.lua", version = "1" }, [[
SMODS.PokerHand {
    key = "Hot Flush",
    loc_txt = { name = "Hot Flush", text = { "A test hand" } },
    chips = 30, mult = 4, l_chips = 30, l_mult = 3,
    evaluate = function(self, hand) return {} end,
}
]])
    write_disabled({ "Handsy" })
    ModLoader.load_all()

    local game = bootstrap.new_game(7703)
    G = game
    local function has_hand(g)
        for _, name in ipairs(g.handlist) do if name == "Hot Flush" then return true end end
        return false
    end
    T.assert_false(has_hand(game), "the hand is not in the game while the mod is off")

    T.assert_true(ModLoader.set_enabled("Handsy", true))
    T.assert_eq(ModLoader.by_id.Handsy.status, "loaded", tostring(ModLoader.by_id.Handsy.error))
    T.assert_true(has_hand(game), "the live game gains the hand without being rebuilt")
    T.assert_eq(#game.handlist, #game.hand_stats, "hand stats stay aligned with the list")
    T.assert_true(has_hand(bootstrap.new_game(7704)), "and a game built afterwards has it too")
    wipe_mods()
end)

return suite
