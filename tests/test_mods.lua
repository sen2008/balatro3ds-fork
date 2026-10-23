local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

bootstrap.load()
local Json = require("json")
local ModLoader = require("mod_loader")

--------------------------------------------------------------------------------
-- Fixtures
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

--- Write a mod folder: a Steamodded manifest plus its main file.
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
    -- Each card is its own image; registration checks the file is there, so write one for
    -- every `sprite = "..."` the main file names. The stub's newImage accepts any bytes.
    for file in main:gmatch('sprite%s*=%s*"([^"]+)"') do
        love.filesystem.write(base .. "/assets/1x/" .. file, "png")
    end
end

local EXAMPLE = [[
SMODS.Joker {
    key = "plus_four",
    loc_txt = { name = "Plus Four", text = { "{C:mult}+#1#{} Mult" } },
    config = { extra = { mult = 4 } },
    rarity = 1, cost = 2, sprite = "plus_four.png", negative_sprite = "plus_four_negative.png",
    blueprint_compat = true,
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.extra.mult } } end,
    calculate = function(self, card, context)
        if context.joker_main then return { mult = card.ability.extra.mult } end
    end,
}

SMODS.Joker {
    key = "sevens",
    loc_txt = { name = "Sevens", text = { "Played {C:attention}7s{} give {C:chips}+#1#{} Chips" } },
    config = { extra = { chips = 30 } },
    rarity = 2, cost = 5, sprite = "sevens.png",
    calculate = function(self, card, context)
        if context.individual and context.cardarea == G.play and context.other_card:get_id() == 7 then
            return { chips = card.ability.extra.chips }
        end
    end,
}

SMODS.Joker {
    key = "runner",
    loc_txt = { name = "Runner", text = { "{C:inactive}(Currently {C:chips}+#1#{C:inactive} Chips)" } },
    config = { extra = { chips = 0, gain = 15 } },
    rarity = 1, cost = 5, sprite = "runner.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.extra.chips } } end,
    calculate = function(self, card, context)
        if context.before and next(context.poker_hands["Straight"]) and not context.blueprint then
            card.ability.extra.chips = card.ability.extra.chips + card.ability.extra.gain
            return { message = "Upgrade!" }
        end
        if context.joker_main and card.ability.extra.chips > 0 then
            return { chips = card.ability.extra.chips }
        end
    end,
}

SMODS.Joker {
    key = "golden",
    loc_txt = { name = "Golden", text = { "Earn {C:money}$#1#{}" } },
    config = { extra = { money = 4 } },
    rarity = 1, cost = 6, sprite = "golden.png",
    calc_dollar_bonus = function(self, card) return card.ability.extra.money end,
}

SMODS.Joker {
    key = "buskin",
    loc_txt = { name = "Buskin", text = { "Retrigger face cards" } },
    rarity = 2, cost = 6, sprite = "buskin.png",
    calculate = function(self, card, context)
        if context.repetition and context.cardarea == G.play and context.other_card:is_face() then
            return { repetitions = 1 }
        end
    end,
}

SMODS.Joker {
    key = "broken",
    loc_txt = { name = "Broken", text = { "Throws" } },
    rarity = 1, cost = 1, sprite = "broken.png",
    calculate = function(self, card, context)
        if context.joker_main then error("boom") end
    end,
}
]]

local function install_example()
    wipe_mods()
    write_mod("Example", {
        id = "ExampleMod", name = "Example", prefix = "ex", main_file = "main.lua",
        version = "1.2.0", author = { "Someone" },
    }, EXAMPLE)
    ModLoader.load_all()
    local game = bootstrap.new_game(4401)
    G = game
    G.play = G.play or SMODS.PLAY
    -- Popups land on the top screen's UI, which `love.load` builds and the tests do not.
    _G.Top = _G.Top or { addPopup = function() end }
    return game
end

local function add(game, id)
    game.jokers = {}
    T.assert_true(game:add_joker_by_def(id), id .. " should be addable")
    return game.jokers[#game.jokers]
end

local function scored(joker, extra)
    local ctx = { event = "on_hand_scored", event_name = "on_hand_scored", chips = 10, mult = 2 }
    for k, v in pairs(extra or {}) do ctx[k] = v end
    if joker:matches_trigger(ctx.event_name, ctx) then joker:apply_effect(ctx) end
    return ctx
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

suite.test("json decodes a Steamodded manifest", function()
    local m = Json.decode('\239\187\191{ "id": "VSMODS", "author": ["a", "b\\u00e9"], "n": -1.5e1, "x": null, "ok": true }')
    T.assert_eq(m.id, "VSMODS")
    T.assert_eq(m.author[2], "b\195\169")
    T.assert_eq(m.n, -15)
    T.assert_eq(m.x, nil)
    T.assert_true(m.ok)
    T.assert_false(pcall(Json.decode, '{ "id": }'), "bad JSON raises")
end)

suite.test("a mod's Jokers register as ordinary Jokers", function()
    local game = install_example()
    local mod = ModLoader.by_id.ExampleMod
    T.assert_eq(mod.status, "loaded")
    T.assert_eq(#mod.registered.jokers, 6)
    local def = JOKER_DEFS.j_ex_plus_four
    T.assert_true(def ~= nil, "id is j_<prefix>_<key>")
    T.assert_eq(def.name, "Plus Four")
    T.assert_eq(def.rarity, 1)
    T.assert_true(def.order > 150, "mod Jokers sort after the vanilla ones")
    T.assert_true(game:joker_allowed_in_random_pool("j_ex_plus_four"), "rollable in the shop")
    local found = false
    for _, entry in ipairs(require("collection_catalog").get_entries("jokers")) do
        if entry.id == "j_ex_plus_four" then found = true end
    end
    T.assert_true(found, "listed in the collection")
    wipe_mods()
end)

suite.test("a mod that fails is rolled back and the others still load", function()
    wipe_mods()
    write_mod("Good", { id = "Good", prefix = "good", main_file = "main.lua", version = "1" }, [[
        SMODS.Joker { key = "fine", rarity = 1, sprite = "a.png" }
    ]])
    write_mod("Bad", { id = "Bad", prefix = "bad", main_file = "main.lua", version = "1" }, [[
        SMODS.Joker { key = "first", rarity = 1, sprite = "a.png" }
        SMODS.Joker { key = "second", rarity = 9, sprite = "a.png" }
    ]])
    write_mod("NoManifest", {}, "")
    love.filesystem.remove(ModLoader.DIR .. "/NoManifest/NoManifest.json")
    write_mod("Needy", { id = "Needy", prefix = "needy", main_file = "main.lua", version = "1",
        dependencies = { "Steamodded (>=1.0.0)", "Missing (>=2)" } }, "")
    ModLoader.load_all()

    T.assert_eq(ModLoader.by_id.Good.status, "loaded")
    T.assert_true(JOKER_DEFS.j_good_fine ~= nil)
    local bad = ModLoader.by_id.Bad
    T.assert_eq(bad.status, "error")
    T.assert_true(tostring(bad.error):find("rarity", 1, true) ~= nil, tostring(bad.error))
    T.assert_eq(JOKER_DEFS.j_bad_first, nil, "the half-loaded Joker is gone with its mod")
    T.assert_eq(SMODS.Sprites["mod:bad:a.png"], nil, "and its images")
    local needy = ModLoader.by_id.Needy
    T.assert_eq(needy.status, "error")
    T.assert_true(needy.error:find("Missing", 1, true) ~= nil, needy.error)
    local no_manifest
    for _, m in ipairs(ModLoader.mods) do if m.folder == "NoManifest" then no_manifest = m end end
    T.assert_eq(no_manifest.status, "error")
    T.assert_true(love.filesystem.read(ModLoader.LOG_PATH):find("[ERROR] Bad", 1, true) ~= nil,
        "the log names the failure for a modder on hardware")
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

suite.test("joker_main returns are scored like a vanilla Joker", function()
    local game = install_example()
    local j = add(game, "j_ex_plus_four")
    local ctx = scored(j)
    T.assert_eq(ctx.mult, 6)
    T.assert_true(ctx._joker_effect_applied, "counts as a trigger for the scoring pace")
    wipe_mods()
end)

suite.test("individual contexts see the scored card", function()
    local game = install_example()
    local j = add(game, "j_ex_sevens")
    local seven = Card(0, 0, 1, 1, { rank = 7, suit = "Hearts" })
    local eight = Card(0, 0, 1, 1, { rank = 8, suit = "Hearts" })
    local function play(node)
        local ctx = { event = "card_played", event_name = "card_played", chips = 0, mult = 1,
            rank = node.card_data.rank, suit = node.card_data.suit, card_node = node }
        if j:matches_trigger("card_played", ctx) then j:apply_effect(ctx) end
        return ctx.chips
    end
    T.assert_eq(play(seven), 30)
    T.assert_eq(play(eight), 0)
    wipe_mods()
end)

suite.test("each copy scales its own ability", function()
    local game = install_example()
    game.jokers = {}
    game:add_joker_by_def("j_ex_runner")
    game:add_joker_by_def("j_ex_runner")
    local a, b = game.jokers[1], game.jokers[2]
    local before = { event = "on_hand_played", event_name = "on_hand_played",
        hand_type = "Straight", contains_hand_types = { Straight = true } }
    a:apply_effect(before)
    T.assert_eq(a.ability.extra.chips, 15)
    T.assert_eq(b.ability.extra.chips, 0, "the second copy did not scale")
    T.assert_eq(JOKER_DEFS.j_ex_runner.config.extra.chips, 0, "the definition is untouched")
    T.assert_eq(scored(a).chips, 25)
    wipe_mods()
end)

suite.test("retriggers, round-end money and runtime errors", function()
    local game = install_example()
    local busk = add(game, "j_ex_buskin")
    local king = Card(0, 0, 1, 1, { rank = 13, suit = "Spades" })
    T.assert_eq(busk:query_retrigger({ card_node = king, held = false }), 1)
    T.assert_eq(busk:query_retrigger({ card_node = Card(0, 0, 1, 1, { rank = 5, suit = "Spades" }), held = false }), 0)

    local golden = add(game, "j_ex_golden")
    local paid = {}
    local ctx = { event = "on_round_end", event_name = "on_round_end",
        add_round_win_payout = function(label, n) paid[#paid + 1] = { label, n } end }
    golden:apply_effect(ctx)
    T.assert_eq(paid[1][1], "Golden")
    T.assert_eq(paid[1][2], 4)

    local broken = add(game, "j_ex_broken")
    local out = scored(broken)
    T.assert_eq(out.mult, 2, "a throwing Joker is skipped, not fatal")
    local errs = ModLoader.by_id.ExampleMod.runtime_errors
    T.assert_true(#errs >= 1 and errs[1]:find("boom", 1, true) ~= nil)
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

suite.test("tooltips fill loc_vars and colour Steamodded markup", function()
    local game = install_example()
    local j = add(game, "j_ex_plus_four")
    local lines = j:get_tooltip_body_lines()
    T.assert_eq(lines[1].kind, "rarity_badge")
    local segs = lines[2].segments
    T.assert_eq(segs[1].text, "+4")
    T.assert_eq(segs[1].color_key, "MULT")
    T.assert_eq(segs[2].text, " Mult")
    T.assert_eq(segs[2].color_key, nil, "{} resets the colour")
    wipe_mods()
end)

suite.test("a negative mod Joker draws its negative art, if it has some", function()
    local game = install_example()
    game.jokers = {}
    T.assert_true(game:add_joker_by_def("j_ex_plus_four", { edition = "negative" }))
    T.assert_eq(game.jokers[1].front_sprite_key, "mod:ex:plus_four_negative.png")
    T.assert_eq(Joker.front_sprite_key_for(JOKER_DEFS.j_ex_plus_four, { edition = "negative" }),
        "mod:ex:plus_four_negative.png", "warming names the same sprite")
    T.assert_true(game:add_joker_by_def("j_ex_sevens", { edition = "negative" }))
    T.assert_eq(game.jokers[2].front_sprite_key, "mod:ex:sevens.png", "no negative art: the plain image")
    wipe_mods()
end)

suite.test("a mod Joker's image loads and frees like a vanilla sprite", function()
    local game = install_example()
    local j = add(game, "j_ex_sevens")
    T.assert_eq(j.front_sprite_key, "mod:ex:sevens.png")
    local entry = game.JOKER_SPRITES["mod:ex:sevens.png"]
    T.assert_eq(entry.path, ModLoader.DIR .. "/Example/assets/1x/sevens.png")
    T.assert_true(entry.image ~= nil)
    j:draw()
    game:remove_owned_joker_at(1, true)
    T.assert_eq(entry.image, nil, "the last owner going frees it, as for vanilla art")
    wipe_mods()
end)

suite.test("atlases, missing images and stray atlas/pos are load errors that say why", function()
    wipe_mods()
    write_mod("A", { id = "A", prefix = "a", main_file = "main.lua", version = "1" },
        'SMODS.Atlas { key = "x", path = "x.png", px = 71, py = 95 }')
    write_mod("B", { id = "B", prefix = "b", main_file = "main.lua", version = "1" },
        'SMODS.Joker { key = "j", rarity = 1, atlas = "x", pos = { x = 0, y = 0 } }')
    write_mod("C", { id = "C", prefix = "c", main_file = "main.lua", version = "1" },
        'SMODS.Joker { key = "j", rarity = 1, sprite = "here.png" }')
    love.filesystem.remove(ModLoader.DIR .. "/C/assets/1x/here.png")
    write_mod("D", { id = "D", prefix = "d", main_file = "main.lua", version = "1" },
        'SMODS.Joker { key = "j", rarity = 1, sprite = "only_t3x.png" }')
    love.filesystem.remove(ModLoader.DIR .. "/D/assets/1x/only_t3x.png")
    love.filesystem.write(ModLoader.DIR .. "/D/assets/1x/only_t3x.t3x", "t3x")
    ModLoader.load_all()
    T.assert_true(ModLoader.by_id.A.error:find("sprite = ", 1, true) ~= nil, ModLoader.by_id.A.error)
    T.assert_true(ModLoader.by_id.B.error:find("atlas/pos", 1, true) ~= nil, ModLoader.by_id.B.error)
    T.assert_true(ModLoader.by_id.C.error:find("here.t3x", 1, true) ~= nil, ModLoader.by_id.C.error)
    T.assert_eq(ModLoader.by_id.D.status, "loaded", "a .t3x alone is enough: that is what the 3DS loads")
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Saves
--------------------------------------------------------------------------------

suite.test("a run records its mods and refuses to continue on a different set", function()
    local game = install_example()
    game.jokers = {}
    game:add_joker_by_def("j_ex_runner")
    game.jokers[1].ability.extra.chips = 45
    local snap = game:build_run_snapshot()
    T.assert_eq(snap.mods[1].id, "ExampleMod")
    T.assert_eq(snap.mods[1].version, "1.2.0")
    T.assert_eq(snap.jokers[1].ability.extra.chips, 45)
    T.assert_true(game:check_saved_run_mods(snap), "same mods: continue")

    T.assert_true(game:load_run_snapshot(snap))
    T.assert_eq(game.jokers[1].ability.extra.chips, 45, "a mod Joker's state survives the save")

    -- Mod removed: the run is held, not loaded or discarded.
    wipe_mods()
    T.assert_false(game:check_saved_run_mods(snap))
    T.assert_eq(game._menu_sub_state, "mods")
    T.assert_eq(game._mods_continue_block.missing[1].id, "ExampleMod")

    -- Version changed.
    write_mod("Example", { id = "ExampleMod", prefix = "ex", main_file = "main.lua", version = "2.0.0" }, EXAMPLE)
    ModLoader.load_all()
    T.assert_false(game:check_saved_run_mods(snap))
    T.assert_eq(game._mods_continue_block.changed[1].installed, "2.0.0")

    -- A vanilla save with a mod now installed.
    T.assert_false(game:check_saved_run_mods({ seed = "X" }))
    T.assert_eq(game._mods_continue_block.extra[1].id, "ExampleMod")
    local lines = ModLoader.describe_mismatch(game._mods_continue_block)
    T.assert_true(lines[1]:find("Turn off ExampleMod", 1, true) ~= nil, lines[1])
    wipe_mods()
end)

suite.test("a mod Joker's tooltip leads with its rarity, like a vanilla one", function()
    local game = install_example()
    local sevens = add(game, "j_ex_sevens")
    local lines = sevens:get_tooltip_body_lines()
    T.assert_eq(lines[1].kind, "rarity_badge")
    T.assert_eq(lines[1].rarity, 2)
    T.assert_eq(lines[1].text, "Uncommon")
    T.assert_eq(#sevens:get_tooltip_body_lines(), #lines, "the badge is added once, not per call")

    I18N.set_language("zh_CN")
    T.assert_eq(sevens:get_tooltip_body_lines()[1].text, I18N.t("rarity.uncommon"))
    I18N.set_language("en")
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Turning mods off and on
--------------------------------------------------------------------------------

local SIMPLE_JOKER = [[
SMODS.Joker { key = "j", loc_txt = { name = "J", text = { "x" } }, rarity = 1, cost = 1, sprite = "j.png" }
]]

suite.test("a mod turned off does not load, stays off across boots, and comes back on", function()
    wipe_mods()
    write_mod("Base", { id = "Base", prefix = "base", main_file = "main.lua", version = "1" }, SIMPLE_JOKER)
    write_mod("Addon", { id = "Addon", prefix = "add", main_file = "main.lua", version = "1",
        dependencies = { "Base (>=1)" } }, SIMPLE_JOKER)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Base.status, "loaded")
    T.assert_true(JOKER_DEFS.j_base_j ~= nil)

    ModLoader.set_enabled("Base", false)
    T.assert_eq(ModLoader.by_id.Base.status, "disabled")
    T.assert_eq(JOKER_DEFS.j_base_j, nil, "a mod turned off takes its Jokers with it")
    T.assert_eq(ModLoader.by_id.Addon.status, "error")
    T.assert_true(ModLoader.by_id.Addon.error:find("turned off", 1, true) ~= nil, ModLoader.by_id.Addon.error)
    T.assert_eq(#ModLoader.fingerprint(), 0, "neither is part of a run now")
    T.assert_true(love.filesystem.read(ModLoader.DISABLED_PATH):find("Base", 1, true) ~= nil)

    -- A reboot reads the choice back.
    ModLoader.disabled = {}
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Base.status, "disabled")
    -- The prefix is free while it is off: only what registers under it reserves it.
    write_mod("Other", { id = "Other", prefix = "base", main_file = "main.lua", version = "1" }, "")
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Other.status, "loaded", tostring(ModLoader.by_id.Other.error))
    love.filesystem.remove(ModLoader.DIR .. "/Other/Other.json")

    ModLoader.set_enabled("Base", true)
    T.assert_eq(ModLoader.by_id.Base.status, "loaded")
    T.assert_eq(ModLoader.by_id.Addon.status, "loaded", tostring(ModLoader.by_id.Addon.error))
    T.assert_true(JOKER_DEFS.j_base_j ~= nil)
    T.assert_eq(love.filesystem.getInfo(ModLoader.DISABLED_PATH, "file"), nil, "nothing off, no file")
    wipe_mods()
end)

suite.test("a mod with a load error can be turned off, and its error goes with it", function()
    wipe_mods()
    write_mod("Bad", { id = "Bad", prefix = "bad", main_file = "main.lua", version = "1" }, "error('nope')")
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Bad.status, "error")
    ModLoader.set_enabled("Bad", false)
    T.assert_eq(ModLoader.by_id.Bad.status, "disabled")
    T.assert_eq(ModLoader.by_id.Bad.error, nil)
    wipe_mods()
end)

suite.test("the Mods page switches mods, and re-checks a held saved run as it does", function()
    local game = install_example()
    local snap = game:build_run_snapshot()
    local ModsUI = require("mods_ui")

    -- Turned off on the Mods page, the saved run asks for it back by name.
    ModsUI.open(game)
    ModsUI.draw(game)
    T.assert_eq(ModsUI.switchable()[1].id, "ExampleMod")
    ModsUI.handle_button(game, "a")
    T.assert_eq(ModLoader.by_id.ExampleMod.status, "disabled", "A flips the focused mod")
    T.assert_eq(game._menu_sub_state, "mods", "and does not leave the page")

    T.assert_false(game:check_saved_run_mods(snap))
    local lines = ModLoader.describe_mismatch(game._mods_continue_block)
    T.assert_true(lines[1]:find("Turn on ExampleMod", 1, true) ~= nil, lines[1])

    -- Tapping the mod's row turns it back on, and the page says the run can go on.
    ModsUI.draw(game)
    local rect = game._mods_switch_rects[1]
    T.assert_true(rect ~= nil, "the mod's row is a switch")
    ModsUI.handle_touch(game, rect.x + 4, rect.y + 2)
    T.assert_eq(ModLoader.by_id.ExampleMod.status, "loaded")
    T.assert_eq(game._mods_continue_block, nil)
    local text = {}
    for _, l in ipairs(ModsUI.lines(game)) do text[#text + 1] = l[1] end
    T.assert_true(table.concat(text, "\n"):find("match the saved run", 1, true) ~= nil)
    T.assert_true(game:check_saved_run_mods(snap))

    ModsUI.handle_button(game, "b")
    T.assert_eq(game._menu_sub_state, "main")
    wipe_mods()
end)

suite.test("the example mod in dev/example_mods loads and scores", function()
    wipe_mods()
    local root = (os.getenv("BALATRO_ROOT") or ".") .. "/dev/example_mods/ExampleJokers/"
    for _, name in ipairs({ "ExampleJokers.json", "ExampleJokers.lua" }) do
        local f = assert(io.open(root .. name, "rb"))
        love.filesystem.createDirectory(ModLoader.DIR .. "/ExampleJokers")
        local text = f:read("*a")
        f:close()
        love.filesystem.write(ModLoader.DIR .. "/ExampleJokers/" .. name, text)
        -- Every image the mod names has to be in the repo, as the .png and the .t3x it ships.
        for file in text:gmatch('sprite%s*=%s*"([^"]+)"') do
            for _, real in ipairs({ file, (file:gsub("%.png$", ".t3x")) }) do
                local img = io.open(root .. "assets/1x/" .. real, "rb")
                T.assert_true(img ~= nil, "example mod ships assets/1x/" .. real)
                if img then img:close() end
            end
            love.filesystem.write(ModLoader.DIR .. "/ExampleJokers/assets/1x/" .. file, "png")
        end
    end
    ModLoader.load_all()
    local mod = ModLoader.by_id.ExampleJokers
    T.assert_eq(mod.status, "loaded", tostring(mod.error))
    T.assert_eq(#mod.registered.jokers, 3)
    T.assert_eq(#mod.registered.consumables, 2)
    T.assert_eq(#mod.registered.vouchers, 2)
    T.assert_eq(#mod.registered.deck_skins, 1)
    T.assert_eq(require("card_art").find("Spades", "exj_royal_court").name, "Royal Court")
    T.assert_eq(VOUCHER_DEFS.v_exj_biggest_hand.depends_on, "v_exj_bigger_hand")
    T.assert_eq(JOKER_DEFS.j_exj_grower.negative_pos.index, "mod:exj:grower_negative.png")
    local game = bootstrap.new_game(4403)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    local grower = add(game, "j_exj_grower")
    grower:apply_effect({ event = "on_hand_played", event_name = "on_hand_played",
        hand_type = "Flush", contains_hand_types = { Flush = true } })
    T.assert_eq(grower.ability.extra.money, 1)
    T.assert_eq(#mod.runtime_errors, 0)
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Consumables and Vouchers
--------------------------------------------------------------------------------

local CV_MOD = [[
SMODS.Consumable {
    set = "Tarot", key = "gilded",
    loc_txt = { name = "Gilded", text = { "Enhances {C:attention}#1#{} cards to Gold" } },
    config = { max_highlighted = 2, mod_conv = "m_gold" },
    sprite = "gilded.png", negative_sprite = "gilded_negative.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.max_highlighted } } end,
}
SMODS.Consumable {
    set = "Planet", key = "pluto2",
    loc_txt = { name = "Pluto 2", text = { "Levels High Card, +$1" } },
    config = { hand_type = "High Card" },
    sprite = "pluto2.png",
    use = function(self, card) ease_dollars(1) end,
}
SMODS.Consumable {
    set = "Spectral", key = "windfall", cost = 5,
    loc_txt = { name = "Windfall", text = { "Gain {C:money}$#1#{}" } },
    config = { extra = { dollars = 7 } },
    sprite = "windfall.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.extra.dollars } } end,
    can_use = function(self, card) return G.money < 100 end,
    use = function(self, card) ease_dollars(card.ability.extra.dollars) end,
}
SMODS.Voucher {
    key = "bigger_hand",
    loc_txt = { name = "Bigger Hand", text = { "{C:attention}+#1#{} hand size" } },
    config = { h_size = 1 },
    sprite = "bigger_hand.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.h_size } } end,
}
SMODS.Voucher {
    key = "even_bigger",
    loc_txt = { name = "Even Bigger", text = { "+1 hand size, +1 discard" } },
    config = { h_size = 1, d_size = 1 },
    sprite = "even_bigger.png", requires = { "bigger_hand" }, cost = 12,
    redeem = function(self, card) ease_dollars(3) end,
}
SMODS.Joker {
    key = "slotter", loc_txt = { name = "Slotter", text = { "+1 Joker slot" } },
    config = { joker_slots = 1, consumable_slots = 1 },
    rarity = 2, sprite = "slotter.png",
}
]]

local function install_cv()
    wipe_mods()
    write_mod("CV", { id = "CV", prefix = "cv", main_file = "main.lua", version = "1" }, CV_MOD)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.CV.status, "loaded", tostring(ModLoader.by_id.CV.error))
    local game = bootstrap.new_game(4410)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    return game
end

suite.test("mod consumables register into the pools as their set", function()
    local game = install_cv()
    local gilded = CONSUMABLE_DEFS.c_cv_gilded
    T.assert_eq(gilded.kind, "tarot")
    T.assert_eq(gilded.select.max, 2)
    T.assert_eq(CONSUMABLE_DEFS.c_cv_pluto2.hand, "High Card")
    T.assert_eq(CONSUMABLE_DEFS.c_cv_windfall.kind, "spectral")
    local function in_pool(kind, id)
        for _, x in ipairs(game:_consumable_pool_ids(kind, true)) do if x == id then return true end end
        return false
    end
    T.assert_true(in_pool("tarot", "c_cv_gilded"))
    T.assert_true(in_pool("spectral", "c_cv_windfall"))
    T.assert_eq(game:shop_price_for_consumable_offer(CONSUMABLE_DEFS.c_cv_windfall), 5, "its own cost")
    for _, v in pairs(gilded) do T.assert_true(type(v) ~= "function", "defs stay saveable data") end
    wipe_mods()
end)

suite.test("mod consumables are rolled by the real shop and pack code", function()
    -- The pools above are not what the shop and packs draw from: they index a fixed
    -- reference order (`REFERENCE_CONSUMABLE_POOL_ORDERS`), which mod cards have to join.
    local game = install_cv()
    game.consumables, game.jokers = {}, {}
    local seen = {}
    for ante = 1, 300 do
        game.ante = ante
        game.shop_offers = {}
        for _, kind in ipairs({ "tarot", "planet", "spectral" }) do
            local offer = game:_roll_shop_queue_consumable_offer(kind)
            if offer and offer.id then seen["shop:" .. offer.id] = true end
        end
        for _, pack in ipairs({ "arcana", "celestial", "spectral" }) do
            for _, ch in ipairs(game:_booster_build_choices({ pack = pack, card_count = 5 })) do
                local id = (ch.consumable_def and ch.consumable_def.id) or ch.id
                if id then seen["pack:" .. id] = true end
            end
        end
        local made = game:random_consumable_id_of_kind("tarot", nil, "test")
        if made then seen["make:" .. made] = true end
    end
    T.assert_true(seen["shop:c_cv_gilded"], "Tarot in the shop")
    T.assert_true(seen["shop:c_cv_pluto2"], "Planet in the shop")
    T.assert_true(seen["shop:c_cv_windfall"], "Spectral in the shop")
    T.assert_true(seen["pack:c_cv_gilded"], "Tarot in an Arcana pack")
    T.assert_true(seen["pack:c_cv_pluto2"], "Planet in a Celestial pack")
    T.assert_true(seen["pack:c_cv_windfall"], "Spectral in a Spectral pack")
    T.assert_true(seen["make:c_cv_gilded"], "created by The Emperor and friends")
    wipe_mods()
end)

suite.test("with no mods the consumable rolls are the reference ones", function()
    wipe_mods()
    local game = bootstrap.new_game(4412)
    G = game
    game.consumables, game.shop_offers = {}, {}
    game.ante = 3
    local offer = game:_roll_shop_queue_consumable_offer("tarot")
    T.assert_true(offer.id:match("^tarot_") ~= nil, offer.id)
end)

suite.test("a data-only Tarot enhances the selected cards", function()
    local game = install_cv()
    game.STATE = game.STATES.SELECTING_HAND
    local a = Card(0, 0, 1, 1, { rank = 5, suit = "Hearts" })
    local b = Card(0, 0, 1, 1, { rank = 9, suit = "Clubs" })
    local selected = { a, b }
    game.hand = {
        ordered_selected_nodes = function() return selected end,
        clear_selection = function() end, layout = function() end,
        is_scoring_active = function() return false end,
    }
    game.consumables, game.consumable_nodes = {}, {}
    T.assert_true(game:add_consumable("c_cv_gilded"))
    T.assert_true(game:consumable_use_enabled(1), "two selected: usable")
    selected = { a, b, Card(0, 0, 1, 1, { rank = 2, suit = "Clubs" }) }
    T.assert_false(game:consumable_use_enabled(1), "three selected: over max_highlighted")
    selected = { a, b }
    T.assert_true(game:use_consumable(1))
    T.assert_eq(a.card_data.enhancement, "gold")
    T.assert_eq(b.card_data.enhancement, "gold")
    T.assert_eq(game.last_consumable_use_id, "c_cv_gilded", "The Fool can copy it")
    wipe_mods()
end)

suite.test("a mod Planet levels its hand, then runs its use", function()
    local game = install_cv()
    local idx
    for i, name in ipairs(game.handlist) do if name == "High Card" then idx = i end end
    local before = game.hand_stats[idx].level
    game:apply_consumable_effect(copy_table(CONSUMABLE_DEFS.c_cv_pluto2))
    T.assert_eq(game.hand_stats[idx].level, before + 1)
    T.assert_eq(game.money, 11)
    wipe_mods()
end)

suite.test("can_use and use drive a coded Spectral, with per-copy ability saved", function()
    local game = install_cv()
    game.STATE = game.STATES.SHOP
    game.consumables, game.consumable_nodes = {}, {}
    T.assert_true(game:add_consumable("c_cv_windfall"))
    game.consumables[1].ability.extra.dollars = 9
    local snap = game:build_run_snapshot()
    T.assert_eq(snap.consumables[1].ability.extra.dollars, 9)
    game.money = 150
    T.assert_false(game:consumable_use_enabled(1), "can_use says no")
    game.money = 10
    T.assert_true(game:use_consumable(1))
    T.assert_eq(game.money, 19)
    wipe_mods()
end)

suite.test("mod consumable art and tooltips", function()
    local game = install_cv()
    local plain = Consumable(0, 0, copy_table(CONSUMABLE_DEFS.c_cv_gilded))
    T.assert_eq(plain.index, "mod:cv:gilded.png")
    T.assert_eq(plain.atlas.path, ModLoader.DIR .. "/CV/assets/1x/gilded.png")
    T.assert_true(plain.quad ~= nil, "drawn like a vanilla consumable sprite")
    local neg = copy_table(CONSUMABLE_DEFS.c_cv_gilded)
    neg.edition = "negative"
    T.assert_eq(Consumable(0, 0, neg).index, "mod:cv:gilded_negative.png", "negative art")
    plain:draw()
    local lines = plain:get_tooltip_body_lines()
    T.assert_eq(lines[1].segments[2].text, "2")
    T.assert_eq(lines[1].segments[2].color_key, "IMPORTANT")
    plain:draw_tooltip(0, 0)
    game:remove(plain)
    wipe_mods()
end)

suite.test("mod vouchers: tiers, the shop roll, redeem and declared modifiers", function()
    local game = install_cv()
    game.vouchers = {}
    local function candidate(id)
        for _, x in ipairs(game:_shop_voucher_candidate_ids({})) do if x == id then return true end end
        return false
    end
    T.assert_true(candidate("v_cv_bigger_hand"))
    T.assert_false(candidate("v_cv_even_bigger"), "needs Bigger Hand first")
    T.assert_eq(VOUCHER_DEFS.v_cv_bigger_hand.description, "+1 hand size")

    local hand_before = game:get_effective_hand_size_limit()
    local discards_before = game:get_effective_discards_per_round()
    game.vouchers[#game.vouchers + 1] = "v_cv_bigger_hand"
    game:apply_voucher_effect("v_cv_bigger_hand")
    T.assert_eq(game:get_effective_hand_size_limit(), hand_before + 1)
    T.assert_true(candidate("v_cv_even_bigger"))
    game.money = 0
    game.vouchers[#game.vouchers + 1] = "v_cv_even_bigger"
    game:apply_voucher_effect("v_cv_even_bigger")
    T.assert_eq(game.money, 3, "redeem ran")
    T.assert_eq(game:get_effective_hand_size_limit(), hand_before + 2)
    T.assert_eq(game:get_effective_discards_per_round(), discards_before + 1)

    -- The roll can land on a mod voucher; with no mods the pool is the reference one.
    local seen = false
    game.vouchers = {}
    for ante = 1, 200 do
        game.ante = ante
        local offer = game:_roll_one_shop_voucher_offer()
        if offer and offer.id == "v_cv_bigger_hand" then seen = true break end
    end
    T.assert_true(seen, "mod vouchers appear in the shop")

    local image, quad = game:voucher_sprite(VOUCHER_DEFS.v_cv_bigger_hand)
    T.assert_true(image ~= nil and quad ~= nil)
    wipe_mods()
end)

suite.test("a mod Joker's declared slots apply while it is held", function()
    local game = install_cv()
    game.jokers = {}
    local jokers_before = game:joker_base_capacity()
    local cons_before = game:get_effective_consumable_capacity()
    T.assert_true(game:add_joker_by_def("j_cv_slotter"))
    T.assert_eq(game:joker_base_capacity(), jokers_before + 1)
    T.assert_eq(game:get_effective_consumable_capacity(), cons_before + 1)
    game:remove_owned_joker_at(1, true)
    T.assert_eq(game:joker_base_capacity(), jokers_before)
    wipe_mods()
end)

suite.test("a failed mod takes its consumables and vouchers with it", function()
    wipe_mods()
    write_mod("CV", { id = "CV", prefix = "cv", main_file = "main.lua", version = "1" },
        CV_MOD .. "\nerror('late failure')")
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.CV.status, "error")
    T.assert_eq(CONSUMABLE_DEFS.c_cv_gilded, nil)
    T.assert_eq(VOUCHER_DEFS.v_cv_bigger_hand, nil)
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Deck skins
--------------------------------------------------------------------------------

local SKIN_MOD = [[
SMODS.DeckSkin {
    key = "royal", suit = "Spades",
    loc_txt = { name = "Royal Court" },
    sprite = "royal_spades.png", hc_sprite = "royal_spades_hc.png",
}
SMODS.DeckSkin {
    key = "plain", suit = "hearts", loc_txt = "Plain Hearts",
    sprite = "plain_hearts.png",
}
]]

local function install_skins()
    wipe_mods()
    write_mod("Skins", { id = "Skins", prefix = "sk", main_file = "main.lua", version = "1" }, SKIN_MOD)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Skins.status, "loaded", tostring(ModLoader.by_id.Skins.error))
    local game = bootstrap.new_game(4420)
    G = game
    return game
end

suite.test("a mod deck skin joins its suit's Card Art carousel and draws on live cards", function()
    local CardArt = require("card_art")
    local game = install_skins()
    local carousel = CardArt.carousel("Spades")
    T.assert_eq(carousel[#carousel].id, "sk_royal", "after the built-in sets")
    T.assert_eq(carousel[#carousel].name, "Royal Court")
    T.assert_eq(CardArt.carousel("Hearts")[#CardArt.carousel("Hearts")].name, "Plain Hearts", "loc_txt as a string")

    local atlas = game.ASSET_ATLAS[CardArt.atlas_name("Spades", "sk_royal", false)]
    T.assert_eq(atlas.path, ModLoader.DIR .. "/Skins/assets/1x/royal_spades.png")
    T.assert_eq(game.ASSET_ATLAS[CardArt.atlas_name("Spades", "sk_royal", true)].path,
        ModLoader.DIR .. "/Skins/assets/1x/royal_spades_hc.png", "its own high-contrast strip")
    T.assert_eq(game.ASSET_ATLAS[CardArt.atlas_name("Hearts", "sk_plain", true)].path,
        ModLoader.DIR .. "/Skins/assets/1x/plain_hearts.png", "no hc_sprite: the normal strip")

    game.SETTINGS.CARD_ART = CardArt.default_settings()
    local king = Card(0, 0, 1, 1, { rank = 13, suit = "Spades" })
    T.assert_true(game:set_card_art("Spades", "sk_royal", false))
    T.assert_eq(king.rank_atlas_name, "collab_spades_sk_royal_1")
    T.assert_eq(king.rank_index, 13 - 2 + 39)
    local snap = game:snapshot_settings()
    T.assert_eq(snap.CARD_ART.Spades.collab, "sk_royal", "the choice saves")

    -- The panel previews it like any other set.
    game:open_card_art_panel()
    game:art_select_suit(4)
    game._art_pick = #CardArt.carousel("Spades")
    T.assert_eq(game:art_preview_sprite(2), "collab_spades_sk_royal_1")

    -- Mod removed: the saved choice falls back to the deck's own art instead of breaking.
    wipe_mods()
    T.assert_eq(CardArt.find("Spades", "sk_royal"), nil, "rolled back with its mod")
    T.assert_eq(game:normalize_settings(snap).CARD_ART.Spades.collab, nil)
end)

suite.test("deck skins reject what this port cannot draw, saying why", function()
    wipe_mods()
    write_mod("A", { id = "A", prefix = "a", main_file = "main.lua", version = "1" },
        'SMODS.DeckSkin { key = "x", suit = "Spades", lc_atlas = "x" }')
    write_mod("B", { id = "B", prefix = "b", main_file = "main.lua", version = "1" },
        'SMODS.DeckSkin { key = "x", suit = "Spades", ranks = { "Jack", "Queen", "King", "Ace" }, sprite = "x.png" }')
    write_mod("C", { id = "C", prefix = "c", main_file = "main.lua", version = "1" },
        'SMODS.DeckSkin { key = "x", suit = "Stars", sprite = "x.png" }')
    write_mod("D", { id = "D", prefix = "d", main_file = "main.lua", version = "1" },
        'SMODS.DeckSkin { key = "x", suit = "Spades", sprite = "x.png" }\nerror("late")')
    ModLoader.load_all()
    T.assert_true(ModLoader.by_id.A.error:find("216x95", 1, true) ~= nil, ModLoader.by_id.A.error)
    T.assert_true(ModLoader.by_id.B.error:find("Ace", 1, true) ~= nil, ModLoader.by_id.B.error)
    T.assert_true(ModLoader.by_id.C.error:find("suit must be", 1, true) ~= nil, ModLoader.by_id.C.error)
    T.assert_eq(require("card_art").find("Spades", "d_x"), nil, "a failed mod's skin goes with it")
    wipe_mods()
end)

suite.test("the Mods page draws loaded and failed mods", function()
    wipe_mods()
    write_mod("Bad", { id = "Bad", prefix = "bad", main_file = "main.lua", version = "1" }, "error('nope')")
    ModLoader.load_all()
    local game = bootstrap.new_game(4402)
    G = game
    local ModsUI = require("mods_ui")
    ModsUI.open(game)
    local text = {}
    for _, l in ipairs(ModsUI.lines(game)) do text[#text + 1] = l[1] end
    T.assert_true(table.concat(text, "\n"):find("Not loaded", 1, true) ~= nil)
    ModsUI.draw(game)
    ModsUI.handle_button(game, "dpdown")
    wipe_mods()
end)

suite.test("mod loc_txt can carry one table per language", function()
    wipe_mods()
    write_mod("Loc", { id = "Loc", prefix = "loc", main_file = "main.lua", version = "1" }, [==[
SMODS.Joker {
    key = "plus",
    loc_txt = {
        ["en-us"] = { name = "Plus", text = { "{C:mult}+#1#{} Mult" } },
        zh_CN = { name = "加号", text = { "{C:mult}+#1#{}倍率" } },
    },
    config = { extra = { mult = 4 } }, rarity = 1, cost = 2, sprite = "plus.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.extra.mult } } end,
}
SMODS.Voucher {
    key = "big",
    loc_txt = { ["en-us"] = { name = "Big", text = { "+#1# hand size" } }, zh_CN = { name = "大", text = { "手牌上限+#1#" } } },
    config = { extra = 1 }, cost = 10, sprite = "big.png",
    loc_vars = function(self, info_queue, card) return { vars = { card.ability.extra } } end,
}
]==])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Loc.status, "loaded", tostring(ModLoader.by_id.Loc.error))
    T.assert_eq(JOKER_DEFS.j_loc_plus.name, "Plus", "the English name is the definition's")
    T.assert_eq(VOUCHER_DEFS.v_loc_big.description, "+1 hand size")

    local function flat(v, out)
        out = out or {}
        if type(v) == "string" then out[#out + 1] = v
        elseif type(v) == "table" then for _, x in pairs(v) do flat(x, out) end end
        return out
    end
    local card = { ability = { extra = { mult = 4 } } }
    T.assert_true(table.concat(flat(SMODS.tooltip_lines("j_loc_plus", card))):find("Mult", 1, true) ~= nil)

    I18N.set_language("zh_CN")
    T.assert_eq(I18N.content_name("joker", "j_loc_plus", "Plus"), "加号")
    T.assert_eq(I18N.content_name("voucher", "v_loc_big", "Big"), "大")
    T.assert_eq(I18N.t("voucher.v_loc_big.description"), "手牌上限+1")
    T.assert_true(table.concat(flat(SMODS.tooltip_lines("j_loc_plus", card))):find("倍率", 1, true) ~= nil,
        "the tooltip follows the live language")

    wipe_mods()
    T.assert_false(I18N.has("joker.j_loc_plus.name"), "unloading a mod takes its strings with it")
    I18N.set_language("en")
end)

suite.test("context.probability_success repeats a chance roll that hit", function()
    wipe_mods()
    write_mod("Dice", { id = "Dice", name = "Dice", prefix = "dice", main_file = "main.lua" }, [[
SMODS.Joker {
    key = "nat20", rarity = 3, cost = 6, sprite = "nat20.png", blueprint_compat = true,
    calculate = function(self, card, context)
        if context.probability_success then return { repetitions = 1 } end
    end,
}
]])
    ModLoader.load_all()
    local game = bootstrap.new_game(4402)
    G = game
    _G.Top = _G.Top or { addPopup = function() end }
    local real_do_random = game.do_random
    game.do_random = function() return true end

    game.jokers = {}
    T.assert_eq(game:chance_triggers(1, 5, 1, "t"), 1, "a hit with no help fires once")
    T.assert_true(game:add_joker_by_def("j_seltzer"))
    T.assert_eq(game:chance_triggers(1, 5, 1, "t"), 1, "card retriggers do not repeat rolls")
    T.assert_true(game:add_joker_by_def("j_dice_nat20"))
    T.assert_eq(game:chance_triggers(1, 5, 1, "t"), 2, "the mod Joker fires it again")
    -- Blueprint copies the Joker to its right: Blueprint, then Natural 20.
    game.jokers = {}
    T.assert_true(game:add_joker_by_def("j_blueprint"))
    T.assert_true(game:add_joker_by_def("j_dice_nat20"))
    T.assert_eq(game:chance_triggers(1, 5, 1, "t"), 3, "Blueprint copies it")

    local lucky = Card(0, 0, 1, 1, { rank = 5, suit = "Spades", enhancement = "lucky" })
    local money = game.money
    local ctx = { chips = 0, mult = 1 }
    lucky:do_enhancement(ctx)
    T.assert_eq(ctx.mult, 61, "+20 Mult three times")
    T.assert_eq(game.money - money, 60, "+$20 three times")

    game.do_random = function() return false end
    T.assert_eq(game:chance_triggers(1, 5, 1, "t"), 0, "a miss never fires")
    game.do_random = real_do_random
    wipe_mods()
end)

--- A mod whose Jokers each exercise one of the hooks below. `seen` records every context flag
--- the recorder is asked with, so a test can check an engine path raised it.
local HOOKS = [[
SEEN = {}
_MOD.seen = SEEN
SMODS.Joker {
    key = "plus", rarity = 1, sprite = "j.png", blueprint_compat = true,
    calculate = function(self, card, context)
        if context.joker_main then
            if context.retrigger_joker then SEEN.retrigger_pass = (SEEN.retrigger_pass or 0) + 1 end
            return { mult = 4 }
        end
    end,
}
SMODS.Joker {
    key = "again", rarity = 1, sprite = "j.png", blueprint_compat = true,
    calculate = function(self, card, context)
        if context.retrigger_joker_check and context.other_card ~= card then
            return { repetitions = 1 }
        end
    end,
}
SMODS.Joker {
    key = "echo", rarity = 1, sprite = "j.png",
    calculate = function(self, card, context)
        if context.post_trigger and context.other_card ~= card then return { chips = 1 } end
    end,
}
SMODS.Joker {
    key = "loaded", rarity = 1, sprite = "j.png",
    calculate = function(self, card, context)
        if context.mod_probability then return { numerator = context.numerator * 2 } end
        if context.pseudorandom_result then
            SEEN.results = (SEEN.results or 0) + 1
            SEEN.last_result = context.result
        end
    end,
}
SMODS.Joker {
    key = "sure", rarity = 1, sprite = "j.png",
    calculate = function(self, card, context)
        if context.fix_probability then return { numerator = context.denominator } end
        if context.probability_success then return { repetitions = 2 } end
    end,
}
SMODS.Joker {
    key = "recorder", rarity = 1, sprite = "j.png",
    in_pool = function(self, args) return false end,
    set_ability = function(self, card, initial) card.ability.stamp = initial end,
    calculate = function(self, card, context)
        for _, flag in ipairs({ "card_added", "tag_added", "ante_change", "ending_shop",
            "starting_shop", "skip_blind", "blind_defeated", "hand_drawn", "final_scoring_step" }) do
            if context[flag] then SEEN[flag] = context[flag] end
        end
        if context.card_added then SEEN.added_card = context.card end
        if context.final_scoring_step then return { xmult = 2 } end
    end,
}
]]

local function install_hooks()
    wipe_mods()
    write_mod("Hooks", { id = "Hooks", name = "Hooks", prefix = "hk", main_file = "main.lua" }, HOOKS)
    ModLoader.load_all()
    local game = bootstrap.new_game(4403)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    return game
end

--- The mod's `SEEN` table. Mod globals live in the mod's own environment, so the mod hands
--- it over through `_MOD`.
local function seen()
    return ModLoader.by_id.Hooks.seen
end

local function hold(game, ids)
    game.jokers = {}
    for _, id in ipairs(ids) do T.assert_true(game:add_joker_by_def(id), id .. " should be addable") end
end

local function hand_scored()
    return { event = "on_hand_scored", event_name = "on_hand_scored", chips = 10, mult = 2 }
end

suite.test("retrigger_joker_check repeats another Joker's effect", function()
    local game = install_hooks()
    hold(game, { "j_hk_plus", "j_hk_again" })
    local ctx = hand_scored()
    game:emit_joker_event("on_hand_scored", ctx)
    T.assert_eq(ctx.mult, 10, "+4 Mult, then +4 again")
    T.assert_eq(seen().retrigger_pass, 1, "the repeat sees context.retrigger_joker")

    -- The staggered queue the scoring sequence uses gives the repeat its own beat.
    ctx = hand_scored()
    game:begin_joker_emit("on_hand_scored", ctx)
    local guard = 0
    while game:joker_emit_busy() and guard < 50 do
        game:_update_joker_emit_queue(1)
        guard = guard + 1
    end
    T.assert_eq(ctx.mult, 10, "the queued path repeats it too")

    -- A vanilla Joker can be retriggered as well.
    hold(game, { "j_joker", "j_hk_again" })
    ctx = hand_scored()
    game:emit_joker_event("on_hand_scored", ctx)
    T.assert_eq(ctx.mult, 10, "Joker's +4 Mult twice")
    wipe_mods()
end)

suite.test("post_trigger lets a Joker react to another's trigger", function()
    local game = install_hooks()
    hold(game, { "j_hk_plus", "j_hk_echo" })
    local ctx = hand_scored()
    game:emit_joker_event("on_hand_scored", ctx)
    T.assert_eq(ctx.mult, 6, "+4 Mult from plus")
    T.assert_eq(ctx.chips, 11, "+1 chip from echo reacting to it")
    wipe_mods()
end)

suite.test("mod_probability and fix_probability reshape every roll", function()
    local game = install_hooks()
    hold(game, { "j_hk_loaded" })
    local num, den = SMODS.get_probability_vars(nil, 1, 4)
    T.assert_eq(num, 2, "loaded doubles the numerator")
    T.assert_eq(den, 4)

    hold(game, { "j_hk_sure" })
    local hits = 0
    for i = 1, 20 do
        if game:do_random(1, 4, 1, "fixed" .. i) then hits = hits + 1 end
    end
    T.assert_eq(hits, 20, "fix_probability made the game's own roll certain")
    local hit, times = SMODS.pseudorandom_probability(nil, "modroll", 1, 1000)
    T.assert_true(hit, "and a mod's roll")
    T.assert_eq(times, 3, "probability_success adds two more passes to a mod roll")

    hold(game, { "j_hk_loaded" })
    seen().results = 0
    game:do_random(1, 4, 1, "heard")
    SMODS.pseudorandom_probability(nil, "heard2", 1, 4)
    T.assert_eq(seen().results, 2, "pseudorandom_result hears both kinds of roll")
    wipe_mods()
end)

suite.test("in_pool and set_ability", function()
    local game = install_hooks()
    T.assert_false(game:joker_allowed_in_random_pool("j_hk_recorder"), "in_pool false keeps it out")
    T.assert_true(game:joker_allowed_in_random_pool("j_hk_plus"), "others still roll")
    hold(game, { "j_hk_recorder" })
    T.assert_eq(game.jokers[1].ability.stamp, true, "set_ability ran on creation")
    wipe_mods()
end)

suite.test("lifecycle contexts fire from the game's own paths", function()
    local game = install_hooks()
    hold(game, { "j_hk_recorder" })
    T.assert_true(game:add_joker_by_def("j_joker"))
    T.assert_eq(seen().added_card, game.jokers[2], "card_added hands over the new Joker")
    game:emit_joker_event("on_ante_change", { ante_change = -1 })
    T.assert_eq(seen().ante_change, -1, "ante_change carries the change")
    game:emit_joker_event("on_shop_exit", {})
    T.assert_true(seen().ending_shop, "ending_shop")
    game:emit_joker_event("on_hand_drawn", { drawn_cards = { Card(0, 0, 1, 1, { rank = 5, suit = "Spades" }) } })
    T.assert_eq(#seen().hand_drawn, 1, "hand_drawn lists the cards drawn")
    game:addTag("investment")
    T.assert_true(seen().tag_added ~= nil, "tag_added from addTag")
    game:roll_skips()
    game:skip_blind(1)
    T.assert_true(seen().skip_blind, "skip_blind from skip_blind")
    wipe_mods()
end)

suite.test("final_scoring_step changes the score before it lands", function()
    local game = install_hooks()
    hold(game, { "j_hk_recorder" })
    game.selectedHandChips, game.selectedHandMult = 10, 2
    local hand = setmetatable({
        _play_sequence = { phase = "finalize", finalize_step = 2, timer = 0, cards = {} },
    }, { __index = Hand })
    local seq = hand._play_sequence
    for _ = 1, 20 do
        if seq.final_score then break end
        hand:_update_play_sequence(0.5)
        game:_update_joker_emit_queue(1)
    end
    T.assert_eq(seq.final_score, 40, "10 chips x (2 Mult x2)")
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Creating and destroying cards (Tier 1)
--------------------------------------------------------------------------------

local TIER1 = [[
SEEN = {}
_MOD.seen = SEEN
SMODS.Joker {
    key = "maker", rarity = 1, sprite = "a.png",
    loc_txt = { name = "Maker", text = { "x" } },
    remove_from_deck = function(self, card) SEEN.removed = (SEEN.removed or 0) + 1 end,
    calculate = function(self, card, context)
        if context.setting_blind then
            SMODS.add_card { set = "Joker", key = "j_joker" }
            return { message = "Made!" }
        end
    end,
}
SMODS.Joker {
    key = "looper", rarity = 1, sprite = "a.png",
    loc_txt = { name = "Looper", text = { "x" } },
    calculate = function(self, card, context)
        if context.joker_main then
            if context.retrigger_joker then SEEN.passes = (SEEN.passes or 0) + 1 end
            return { mult = 3, repetitions = 1 }
        end
    end,
}
SMODS.Joker {
    key = "booster", rarity = 1, sprite = "a.png",
    loc_txt = { name = "Booster", text = { "x" } },
    calculate = function(self, card, context)
        if context.joker_main then
            for _, j in ipairs(G.jokers) do
                if j.def and j.def.id == "j_t1_looper" and j ~= card then
                    return { retrigger_joker = j, repetitions = 1 }
                end
            end
        end
    end,
}
]]

local function install_tier1()
    wipe_mods()
    write_mod("Tier1", { id = "Tier1", prefix = "t1", main_file = "main.lua", version = "1" }, TIER1)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Tier1.status, "loaded", tostring(ModLoader.by_id.Tier1.error))
    local game = bootstrap.new_game(4430)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.jokers = {}
    return game
end

local function t1_seen()
    return ModLoader.by_id.Tier1.seen
end

suite.test("SMODS.add_card creates Jokers and consumables, respecting capacity", function()
    local game = install_tier1()
    local j = SMODS.add_card { set = "Joker", key = "j_t1_maker" }
    T.assert_true(j ~= nil, "the created Joker is returned")
    T.assert_eq(j.def.id, "j_t1_maker")
    T.assert_eq(#game.jokers, 1)
    local v = SMODS.create_card { set = "Joker", key = "j_joker" }
    T.assert_eq(v.def.id, "j_joker", "create_card is the same call")
    T.assert_eq(#game.jokers, 2)
    T.assert_eq(SMODS.add_card { set = "Joker", key = "j_nope" }, nil, "unknown id: nothing created")
    T.assert_eq(#game.jokers, 2)

    game.consumables, game.consumable_nodes = {}, {}
    local c = SMODS.add_card { set = "Tarot", key = "tarot_fool" }
    T.assert_true(c ~= nil)
    T.assert_eq(game.consumables[1].id, "tarot_fool")
    local cap = game:get_effective_consumable_capacity()
    local guard = 0
    while SMODS.add_card { set = "Consumable", key = "tarot_magician" } and guard < 20 do guard = guard + 1 end
    T.assert_eq(#game.consumables, cap, "fills to the consumable slots and no further")
    T.assert_eq(SMODS.add_card { set = "Tarot", key = "tarot_fool" }, nil, "full: refused")

    local jcap = game:joker_base_capacity()
    guard = 0
    while SMODS.add_card { set = "Joker", key = "j_joker" } and guard < 20 do guard = guard + 1 end
    T.assert_eq(#game.jokers, jcap, "fills to the Joker slots and no further")
    wipe_mods()
end)

suite.test("a mod can create a Joker from inside calculate", function()
    local game = install_tier1()
    T.assert_true(game:add_joker_by_def("j_t1_maker"))
    game.jokers[1]:apply_effect({ event = "on_blind_selected", event_name = "on_blind_selected" })
    T.assert_eq(#game.jokers, 2)
    T.assert_eq(game.jokers[2].def.id, "j_joker")
    wipe_mods()
end)

suite.test("SMODS.destroy_joker removes a held Joker and runs remove_from_deck", function()
    local game = install_tier1()
    local j = SMODS.add_card { set = "Joker", key = "j_t1_maker" }
    T.assert_true(SMODS.destroy_joker(j))
    T.assert_eq(#game.jokers, 0)
    T.assert_eq(t1_seen().removed, 1, "remove_from_deck ran: SMODS.on_joker_removed fired")
    T.assert_false(SMODS.destroy_joker(j), "already gone")
    wipe_mods()
end)

suite.test("SMODS.add_card creates playing cards in hand and deck; destroy_card removes them", function()
    local game = install_tier1()
    game.hand = Hand(game)   -- a headless game has no hand or deck until a run starts them
    game.deck = Deck(game)
    local node = SMODS.add_card { set = "Playing", rank = "Ace", suit = "Spades" }
    T.assert_true(node ~= nil, "the new hand card's node is returned")
    T.assert_eq(node.card_data.rank, 14)
    T.assert_eq(node.base.id, 14, "the view contexts see is refreshed")
    T.assert_eq(#game.hand.cards, 1)
    T.assert_eq(#game.hand.card_nodes, 1)

    local in_deck = #game.deck.cards
    local cd = SMODS.add_card { set = "Playing", rank = 7, suit = "Hearts", area = "deck", enhancement = "m_gold" }
    T.assert_true(cd ~= nil)
    T.assert_eq(cd.rank, 7)
    T.assert_eq(cd.enhancement, "gold", "Steamodded enhancement keys translate")
    T.assert_eq(#game.deck.cards, in_deck + 1)

    T.assert_true(SMODS.destroy_card(node))
    T.assert_eq(#game.hand.cards, 0, "destroyed from the hand")
    T.assert_eq(#game.hand.card_nodes, 0)
    T.assert_eq(#game.deck.discard_pile, 0, "and it never reached the discard pile")
    T.assert_true(SMODS.destroy_card(cd))
    T.assert_eq(#game.deck.cards, in_deck)
    T.assert_false(SMODS.destroy_card(cd), "already gone")
    T.assert_eq(SMODS.add_card { set = "Playing", rank = "Joker", suit = "Spades" }, nil, "no such rank")
    wipe_mods()
end)

suite.test("retrigger fields in a calculate return run the effect again", function()
    local game = install_tier1()
    T.assert_true(game:add_joker_by_def("j_t1_looper"))
    local ctx = { event = "on_hand_scored", event_name = "on_hand_scored", chips = 10, mult = 2 }
    game:emit_joker_event("on_hand_scored", ctx)
    T.assert_eq(ctx.mult, 8, "+3 Mult, then +3 again from its own repetitions return")
    T.assert_eq(t1_seen().passes, 1, "the pass sees context.retrigger_joker and does not loop")

    T.assert_true(game:add_joker_by_def("j_t1_booster"))
    t1_seen().passes = 0
    ctx = { event = "on_hand_scored", event_name = "on_hand_scored", chips = 10, mult = 2 }
    game:emit_joker_event("on_hand_scored", ctx)
    T.assert_eq(ctx.mult, 11, "booster's retrigger_joker return runs the looper once more")
    T.assert_eq(t1_seen().passes, 2, "one self pass and one booster pass")
    wipe_mods()
end)

--------------------------------------------------------------------------------
-- Rarities, suits and poker hands (Tier 2)
--------------------------------------------------------------------------------

local TIER2 = [[
SMODS.Rarity {
    key = "mythic", weight = 0,
    loc_txt = { name = "Mythic" },
    badge_colour = "#B26CBB",
}
SMODS.Rarity {
    key = "cursed", weight = 50,
    loc_txt = { name = "Cursed" },
    badge_colour = { 0.5, 0.1, 0.9 },
}
SMODS.Suit {
    key = "Stars",
    loc_txt = { name = "Stars" },
    ui_colour = "#FFAA00",
}
SMODS.PokerHand {
    key = "Spectrum",
    loc_txt = { name = "Spectrum", text = { "Five cards, all different suits" } },
    chips = 30, mult = 4, l_chips = 30, l_mult = 3,
    evaluate = function(self, hand)
        local seen, wilds = {}, 0
        for _, card in ipairs(hand) do
            local data = card.card_data or {}
            if data.enhancement == "wild" then
                wilds = wilds + 1
            else
                local suit = card.base and card.base.suit or data.suit
                if suit == nil or seen[suit] then return nil end
                seen[suit] = true
            end
        end
        local distinct = wilds
        for _ in pairs(seen) do distinct = distinct + 1 end
        if distinct >= 5 then return hand end
        return nil
    end,
}
SMODS.Consumable {
    set = "Planet", key = "nebula",
    loc_txt = { name = "Nebula", text = { "Levels Spectrum" } },
    config = { hand_type = "Spectrum" },
    sprite = "a.png",
}
SMODS.Joker {
    key = "myth", rarity = "mythic", cost = 9, sprite = "a.png",
    loc_txt = { name = "Myth", text = { "x" } },
    calculate = function(self, card, context)
        if context.joker_main then return { mult = 5 } end
    end,
}
SMODS.Joker {
    key = "cursed_one", rarity = "t2_cursed", cost = 4, sprite = "a.png",
    loc_txt = { name = "Cursed One", text = { "x" } },
}
SMODS.Joker {
    key = "star_gazer", rarity = 2, cost = 6, sprite = "a.png",
    loc_txt = { name = "Star Gazer", text = { "x" } },
    calculate = function(self, card, context)
        if context.joker_main and next(context.poker_hands["Spectrum"]) then
            return { mult = 8 }
        end
    end,
}
]]

local function install_tier2()
    wipe_mods()
    write_mod("Tier2", { id = "Tier2", prefix = "t2", main_file = "main.lua", version = "1" }, TIER2)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Tier2.status, "loaded", tostring(ModLoader.by_id.Tier2.error))
    local game = bootstrap.new_game(4431)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.jokers = {}
    return game
end

--- Classify a play the way `test_hand_eval` does: plain nodes, every one selected.
local function classify(game, specs)
    local h = Hand(game)
    h.card_nodes, h.selected = {}, {}
    for _, spec in ipairs(specs) do
        local nd = { card_data = { rank = spec[1], suit = spec[2], enhancement = spec[3] }, face_up = true }
        h.card_nodes[#h.card_nodes + 1] = nd
        h.selected[#h.selected + 1] = nd
    end
    h:calculate_play()
    return G.handlist and G.handlist[G.selectedHand], h
end

local function colour_eq(a, b)
    return type(a) == "table" and math.abs((a[1] or -1) - b[1]) < 0.01
        and math.abs((a[2] or -1) - b[2]) < 0.01 and math.abs((a[3] or -1) - b[3]) < 0.01
end

suite.test("custom rarities: registration, pool rolls, shop weight and the badge", function()
    local game = install_tier2()
    local mythic = SMODS.Rarities["t2_mythic"]
    local cursed = SMODS.Rarities["t2_cursed"]
    T.assert_true(mythic ~= nil and cursed ~= nil)
    T.assert_true(mythic.index >= 5 and cursed.index >= 5 and mythic.index ~= cursed.index,
        "custom rarities take numbers after Legendary")
    T.assert_eq(JOKER_DEFS.j_t2_myth.rarity, mythic.index, "declared by key from its own mod")
    T.assert_eq(JOKER_DEFS.j_t2_cursed_one.rarity, cursed.index, "declared by full id")

    T.assert_eq(game:random_joker_def_id_by_rarity(mythic.index, "t2pool", true), "j_t2_myth",
        "rolls by rarity find it")

    -- The shop roll: Cursed (weight 50 of 150) turns up, Mythic (weight 0) never does.
    game.shop_offers, game.ante = {}, 1
    local seen_cursed, seen_myth = false, false
    for i = 1, 200 do
        local id = game:_pick_joker_id_shop_rarity_distribution(
            function(lo, hi) return math.random(lo, hi) end, "t" .. i)
        if id == "j_t2_cursed_one" then seen_cursed = true end
        if id == "j_t2_myth" then seen_myth = true end
    end
    T.assert_true(seen_cursed, "a weighted custom rarity reaches the shop")
    T.assert_false(seen_myth, "weight 0 stays out of the shop roll")

    local j = add(game, "j_t2_myth")
    local lines = j:get_tooltip_body_lines()
    T.assert_eq(lines[1].kind, "rarity_badge")
    T.assert_eq(lines[1].text, "Mythic")
    T.assert_eq(lines[1].rarity, mythic.index)
    local seg = j:resolve_tooltip_line_segments(lines[1])[1]
    T.assert_true(colour_eq(seg.rarity_colour, { 0xB2 / 255, 0x6C / 255, 0xBB / 255 }),
        "the badge carries the rarity's own colour")
    T.assert_true(colour_eq(game.C.RARITY[mythic.index], { 0xB2 / 255, 0x6C / 255, 0xBB / 255 }),
        "and the palette has it for anything else that badges by number")
    wipe_mods()
    T.assert_eq(next(SMODS.Rarities), nil, "rollback takes the rarities with the mod")
end)

suite.test("an unknown rarity name is a load error that says so", function()
    wipe_mods()
    write_mod("Bad", { id = "BadR", prefix = "br", main_file = "main.lua", version = "1" }, [[
        SMODS.Joker { key = "j", rarity = "sparkly", sprite = "a.png" }
    ]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.BadR.status, "error")
    T.assert_true(tostring(ModLoader.by_id.BadR.error):find("unknown rarity", 1, true) ~= nil,
        tostring(ModLoader.by_id.BadR.error))
    wipe_mods()
end)

suite.test("custom suits: is_suit, creation, colours and flush", function()
    local game = install_tier2()
    T.assert_true(SMODS.Suits["Stars"] ~= nil)
    T.assert_true(colour_eq(game.C.SUITS["Stars"], { 1, 0xAA / 255, 0 }), "ui_colour installed")

    local star = Card(0, 0, 1, 1, { rank = 7, suit = "Stars" })
    T.assert_true(star:is_suit("Stars"))
    T.assert_false(star:is_suit("Hearts"))
    local wild_star = Card(0, 0, 1, 1, { rank = 7, suit = "Stars", enhancement = "wild" })
    T.assert_true(wild_star:is_suit("Hearts"), "a Wild card is every suit, custom included")

    game.hand = Hand(game)
    game.deck = Deck(game)
    local node = SMODS.add_card { set = "Playing", rank = 5, suit = "Stars" }
    T.assert_true(node ~= nil, "a playing card of a custom suit can be created")
    T.assert_eq(node.card_data.suit, "Stars")

    local name = classify(game, {
        { 2, "Stars" }, { 5, "Stars" }, { 9, "Stars" }, { 11, "Stars" }, { 13, "Stars" },
    })
    T.assert_eq(name, "Flush", "five of a custom suit flush like any suit")
    wipe_mods()
    T.assert_eq(SMODS.Suits["Stars"], nil, "rollback takes the suit with the mod")
end)

suite.test("custom poker hands: Spectrum over a custom suit, contained types, Planets", function()
    local game = install_tier2()
    T.assert_eq(#game.handlist, 13, "the hand joins the list")
    local pos = {}
    for i, name in ipairs(game.handlist) do pos[name] = i end
    T.assert_true(pos["Spectrum"] == 13 and pos["High Card"] == 12,
        "appended after High Card: the engine names plays by list position, "
        .. "so the vanilla twelve keep their places")
    local stats = game.hand_stats[pos["Spectrum"]]
    T.assert_eq(stats.base_chips, 30)
    T.assert_eq(stats.base_mult, 4)

    local play = {
        { 2, "Hearts" }, { 5, "Clubs" }, { 9, "Diamonds" }, { 13, "Spades" }, { 7, "Stars" },
    }
    local name, h = classify(game, play)
    T.assert_eq(name, "Spectrum", "five cards, all different suits")
    T.assert_eq(G.selectedHandChips, 30)
    T.assert_eq(G.selectedHandMult, 4)
    for _, nd in ipairs(h.card_nodes) do
        T.assert_true(nd.counts_for_play_score, "every Spectrum card scores")
    end

    local nodes = {}
    for _, spec in ipairs(play) do
        nodes[#nodes + 1] = { card_data = { rank = spec[1], suit = spec[2] }, face_up = true }
    end
    T.assert_true(h:build_contained_hand_types(nodes)["Spectrum"] == true,
        "contained types name it, so context.poker_hands sees it")

    local plain = classify(game, {
        { 2, "Hearts" }, { 5, "Clubs" }, { 9, "Diamonds" }, { 13, "Spades" }, { 7, "Hearts" },
    })
    T.assert_eq(plain, "High Card", "a duplicated suit is no Spectrum")
    T.assert_eq(classify(game, {
        { 2, "Stars" }, { 5, "Stars" }, { 9, "Stars" }, { 11, "Stars" }, { 13, "Stars" },
    }), "Flush", "a Flush still outranks it")

    -- A Joker keyed on the hand through context.poker_hands.
    local gazer = add(game, "j_t2_star_gazer")
    local ctx = { event = "on_hand_scored", event_name = "on_hand_scored", chips = 30, mult = 4,
        hand_type = "Spectrum", contains_hand_types = { Spectrum = true } }
    gazer:apply_effect(ctx)
    T.assert_eq(ctx.mult, 12, "+8 Mult when the played hand is Spectrum")
    ctx = { event = "on_hand_scored", event_name = "on_hand_scored", chips = 35, mult = 4,
        hand_type = "Flush", contains_hand_types = { Flush = true } }
    gazer:apply_effect(ctx)
    T.assert_eq(ctx.mult, 4, "and not for a Flush")

    -- A Planet levels it by name, and the level shows in the next play's numbers.
    game:apply_consumable_effect(copy_table(CONSUMABLE_DEFS.c_t2_nebula))
    T.assert_eq(game.hand_stats[pos["Spectrum"]].level, 2)
    classify(game, play)
    T.assert_eq(G.selectedHandChips, 60)
    T.assert_eq(G.selectedHandMult, 7)
    wipe_mods()
end)

suite.test("with no mods registered, hands and suits stay vanilla", function()
    wipe_mods()
    local game = bootstrap.new_game(4432)
    G = game
    T.assert_eq(#game.handlist, 12)
    T.assert_eq(game.handlist[1], "Flush Five")
    T.assert_eq(game.handlist[12], "High Card")
    T.assert_eq(game.C.SUITS["Stars"], nil)
    T.assert_eq(#SMODS.PokerHands, 0)
end)

--------------------------------------------------------------------------------
-- Suit pool gates: random playing-card fronts (the exotic-suits hook)
--------------------------------------------------------------------------------

local SUITGATE = [[
SMODS.Suit {
    key = "Stars",
    loc_txt = { name = "Stars" },
    ui_colour = "#FFAA00",
    in_pool = function(self, game) return _G.T2_SUIT_OPEN == true end,
}
SMODS.Suit {
    key = "Moons",
    loc_txt = { name = "Moons" },
    ui_colour = "#AAAAFF",
}
]]

suite.test("suit in_pool gates the random playing-card fronts", function()
    wipe_mods()
    write_mod("SuitGate", { id = "SuitGate", prefix = "sg", main_file = "main.lua", version = "1" }, SUITGATE)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.SuitGate.status, "loaded", tostring(ModLoader.by_id.SuitGate.error))
    local game = bootstrap.new_game(5150)
    G = game

    -- Gate shut: only the ungated suit (Moons) deals fronts, 13 of them.
    _G.T2_SUIT_OPEN = false
    local fronts = SMODS.extra_playing_card_fronts(game)
    T.assert_eq(#fronts, 13, "one ungated suit contributes 13 fronts")
    for _, f in ipairs(fronts) do T.assert_eq(f.suit, "Moons") end

    -- Gate open: both suits, sorted by name ahead of registration order.
    _G.T2_SUIT_OPEN = true
    fronts = SMODS.extra_playing_card_fronts(game)
    T.assert_eq(#fronts, 26, "two open suits contribute 26 fronts")
    T.assert_eq(fronts[1].suit, "Moons")
    T.assert_eq(fronts[14].suit, "Stars")
    T.assert_eq(fronts[14].rank, 2)
    T.assert_eq(fronts[26].rank, 14)

    -- The roll itself reaches the gated suit while the gate is open...
    local saw = {}
    for _ = 1, 400 do
        local f = game:_random_reference_playing_card_front("fronttest")
        saw[f.suit] = true
    end
    T.assert_true(saw["Stars"] and saw["Moons"] and saw["Hearts"],
        "random fronts include gated, ungated and vanilla suits")

    -- ...and never deals it once the gate shuts.
    _G.T2_SUIT_OPEN = false
    saw = {}
    for _ = 1, 400 do
        local f = game:_random_reference_playing_card_front("fronttest")
        saw[f.suit] = true
    end
    T.assert_true(saw["Stars"] == nil and saw["Moons"] and saw["Hearts"],
        "a shut gate keeps its suit out of random fronts")
    _G.T2_SUIT_OPEN = nil
    wipe_mods()

    -- No suits registered at all: no extras, and the roll is vanilla's 52.
    local plain = bootstrap.new_game(5151)
    G = plain
    T.assert_eq(#SMODS.extra_playing_card_fronts(plain), 0)
    for _ = 1, 200 do
        local f = plain:_random_reference_playing_card_front("fronttest")
        T.assert_true(f.suit == "Hearts" or f.suit == "Diamonds"
            or f.suit == "Clubs" or f.suit == "Spades", "vanilla fronts only")
    end
end)

--------------------------------------------------------------------------------
-- Custom consumable types (SMODS.ConsumableType)
--------------------------------------------------------------------------------

local CTYPES = [[
SMODS.ConsumableType {
    key = "Minor",
    loc_txt = { name = "Minor Arcana" },
    shop_rate = 6,
}
SMODS.Consumable {
    set = "Minor", key = "coin",
    loc_txt = { name = "Coin", text = { "Gain {C:money}$#1#{}" } },
    config = { extra = { dollars = 5 } },
    cost = 3, sprite = "coin.png",
    can_use = function(self, card) return G.money < 100 end,
    use = function(self, card) ease_dollars(card.ability.extra.dollars) end,
}
SMODS.Consumable {
    set = "minor", key = "mark",
    loc_txt = { name = "Mark", text = { "Enhances {C:attention}1{} card", "into a {C:mult}Mult Card{}" } },
    config = { max_highlighted = 1, mod_conv = "m_mult" },
    sprite = "mark.png",
}
SMODS.Consumable {
    set = "ct_Minor", key = "sigil",
    loc_txt = { name = "Sigil", text = { "Gain {C:money}$2{}" } },
    sprite = "sigil.png",
    use = function(self, card) ease_dollars(2) end,
}
]]

local function install_ct()
    wipe_mods()
    write_mod("CTypes", { id = "CTypes", prefix = "ct", main_file = "main.lua", version = "1" }, CTYPES)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.CTypes.status, "loaded", tostring(ModLoader.by_id.CTypes.error))
    local game = bootstrap.new_game(4460)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    return game
end

suite.test("custom consumable types: registration, pool, add_card and the shop roll", function()
    local game = install_ct()
    local entry = SMODS.ConsumableTypes["ct_Minor"]
    T.assert_true(entry ~= nil, "the type registers under its full id")
    T.assert_eq(entry.kind, "Minor")
    T.assert_eq(entry.shop_rate, 6)
    T.assert_eq(CONSUMABLE_DEFS.c_ct_coin.kind, "Minor", "declared by bare key")
    T.assert_eq(CONSUMABLE_DEFS.c_ct_mark.kind, "Minor", "declared lowercase")
    T.assert_eq(CONSUMABLE_DEFS.c_ct_sigil.kind, "Minor", "declared by full id")
    T.assert_true(game:is_consumable_kind("Minor"))
    T.assert_true(SMODS.is_consumable_kind("Minor"))

    -- The pool is the kind's own cards.
    local pool = game:_consumable_pool_ids("Minor", true)
    T.assert_eq(#pool, 3)
    local rolled = game:random_consumable_id_of_kind("Minor", nil, "ct")
    T.assert_true(rolled == "c_ct_coin" or rolled == "c_ct_mark" or rolled == "c_ct_sigil",
        "kind rolls draw from the kind's pool")

    -- SMODS.add_card resolves the custom kind by name.
    game.consumables, game.consumable_nodes = {}, {}
    local made = SMODS.add_card { set = "Minor", key = "c_ct_coin" }
    T.assert_true(made ~= nil and made.id == "c_ct_coin" and made.kind == "Minor",
        "add_card with the custom set name")
    local made2 = SMODS.add_card { set = "Consumable", key = "c_ct_sigil" }
    T.assert_true(made2 ~= nil and made2.kind == "Minor", "the generic set name still works")

    -- The shop roll: weights are joker 20, tarot 4, planet 4, spectral 0 (standard
    -- deck), Minor 6 -- so Minor should land near 6/34 of the offers, alongside the
    -- vanilla kinds.
    game.consumables, game.shop_offers = {}, {}
    local counts, total = {}, 0
    for ante = 1, 800 do
        game.ante = ante
        local offer = game:_generate_next_shop_queue_offer()
        if offer then
            counts[offer.kind] = (counts[offer.kind] or 0) + 1
            total = total + 1
        end
    end
    T.assert_true(total > 700, "the shop generated its offers")
    local share = (counts["Minor"] or 0) / total
    T.assert_true(share > 0.08 and share < 0.28,
        ("Minor shop share %.3f, expected near %.3f"):format(share, 6 / 34))
    T.assert_true((counts.tarot or 0) > 0 and (counts.planet or 0) > 0 and (counts.joker or 0) > 0,
        "the vanilla kinds still roll")

    -- Unloading the mod restores the vanilla kinds.
    wipe_mods()
    T.assert_eq(next(SMODS.ConsumableTypes), nil, "types unregister on rollback")
    T.assert_eq(next(SMODS.ConsumableKinds), nil)
    T.assert_eq(CONSUMABLE_DEFS.c_ct_coin, nil)
    local plain = bootstrap.new_game(4461)
    G = plain
    T.assert_false(plain:is_consumable_kind("Minor"))
    T.assert_eq(SMODS.shop_consumable_kinds(), nil, "no custom kinds in the shop roll")
end)

suite.test("custom consumable types: use and can_use run through the real flow", function()
    local game = install_ct()
    game.STATE = game.STATES.SHOP
    game.consumables, game.consumable_nodes = {}, {}
    T.assert_true(game:add_consumable("c_ct_coin"))
    game.money = 150
    T.assert_false(game:consumable_use_enabled(1), "can_use blocks at $100+")
    game.money = 10
    T.assert_true(game:consumable_use_enabled(1))
    T.assert_true(game:use_consumable(1))
    T.assert_eq(game.money, 15, "the custom kind's use ran")
    T.assert_eq(#game.consumables, 0, "and the card is spent")

    -- A targeted card of the kind follows the tarot selection rules.
    game.STATE = game.STATES.SELECTING_HAND
    local a = Card(0, 0, 1, 1, { rank = 7, suit = "Hearts" })
    local selected = { a }
    game.hand = {
        ordered_selected_nodes = function() return selected end,
        clear_selection = function() end, layout = function() end,
        is_scoring_active = function() return false end,
    }
    T.assert_true(game:add_consumable("c_ct_mark"))
    selected = {}
    T.assert_false(game:consumable_use_enabled(1), "nothing selected: not usable")
    selected = { a }
    T.assert_true(game:consumable_use_enabled(1), "one selected: usable")
    T.assert_true(game:use_consumable(1))
    T.assert_eq(a.card_data.enhancement, "mult", "mod_conv applies to the selection")
    wipe_mods()
end)

suite.test("custom consumable types: shop offers buy and buy-and-use", function()
    local game = install_ct()
    game.STATE = game.STATES.SHOP
    game.money = 10
    game.consumables, game.consumable_nodes = {}, {}
    game.shop_offers = { { kind = "Minor", id = "c_ct_coin", price = 3 } }
    T.assert_eq(game:shop_price_for_consumable_offer(CONSUMABLE_DEFS.c_ct_coin), 3,
        "the kind prices from the def's cost")
    T.assert_eq(game:get_shop_offer_price(game.shop_offers[1]), 3)
    T.assert_true(game:can_buy_shop_offer(1))
    T.assert_true(game:buy_shop_joker(1), "buying the custom offer works")
    T.assert_eq(#game.consumables, 1)
    T.assert_eq(game.consumables[1].kind, "Minor")
    T.assert_eq(game.money, 7, "price paid")

    game.shop_offers = { { kind = "Minor", id = "c_ct_coin", price = 3 } }
    T.assert_true(game:shop_offer_consumable_use_enabled(game.shop_offers[1]), "buy-and-use is offered")
    T.assert_true(game:buy_and_use_shop_consumable(1), "buy-and-use works")
    T.assert_eq(#game.consumables, 1, "the bought copy was used, not held")
    T.assert_eq(game.money, 9, "paid $3, and the card's use paid $5")
    wipe_mods()
end)

suite.test("a consumable in an unregistered set is a load error naming the set", function()
    wipe_mods()
    write_mod("NoType", { id = "NoType", prefix = "nt", main_file = "main.lua", version = "1" }, [[
SMODS.Consumable {
    set = "Minor", key = "orphan",
    loc_txt = { name = "Orphan" },
    sprite = "orphan.png",
}
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.NoType.status, "error")
    T.assert_true(tostring(ModLoader.by_id.NoType.error):find("Minor", 1, true) ~= nil,
        "the error names the set: " .. tostring(ModLoader.by_id.NoType.error))
    T.assert_true(tostring(ModLoader.by_id.NoType.error):find("unknown set", 1, true) ~= nil,
        tostring(ModLoader.by_id.NoType.error))
    T.assert_eq(CONSUMABLE_DEFS.c_nt_orphan, nil, "nothing registered")
    wipe_mods()
end)

suite.test("with no custom types, consumable kinds and a tarot use stay vanilla", function()
    wipe_mods()
    local game = bootstrap.new_game(4462)
    G = game
    T.assert_eq(SMODS.shop_consumable_kinds(), nil)
    T.assert_true(game:is_consumable_kind("tarot") and game:is_consumable_kind("planet")
        and game:is_consumable_kind("spectral"))
    T.assert_false(game:is_consumable_kind("Minor"))
    T.assert_eq(game:random_consumable_id_of_kind("Minor", nil, "van"), nil,
        "an unregistered kind has no pool")

    game.consumables, game.shop_offers = {}, {}
    local allowed = { joker = true, tarot = true, planet = true, spectral = true, playing_card = true }
    for ante = 1, 200 do
        game.ante = ante
        local offer = game:_generate_next_shop_queue_offer()
        T.assert_true(offer == nil or allowed[offer.kind] == true,
            "only vanilla kinds roll: " .. tostring(offer and offer.kind))
    end

    game.STATE = game.STATES.SHOP
    game.consumables, game.consumable_nodes = {}, {}
    game.money = 10
    T.assert_true(game:add_consumable("tarot_hermit"))
    T.assert_true(game:use_consumable(1))
    T.assert_eq(game.money, 20, "The Hermit still doubles the money (capped at $20)")
end)

--------------------------------------------------------------------------------
-- Custom consumable types in booster packs + collection (Tier 3c)
--------------------------------------------------------------------------------

local PTYPES = [[
SMODS.ConsumableType {
    key = "Minor",
    loc_txt = { name = "Minor Arcana" },
    shop_rate = 0,
    packs = { arcana = 96, celestial = 96, spectral = 96 },
}
SMODS.Consumable {
    set = "Minor", key = "coin",
    loc_txt = { name = "Coin", text = { "Gain {C:money}$#1#{}" } },
    config = { extra = { dollars = 5 } },
    cost = 3, sprite = "coin.png",
    use = function(self, card) ease_dollars(card.ability.extra.dollars) end,
}
SMODS.Consumable {
    set = "Minor", key = "sigil",
    loc_txt = { name = "Sigil", text = { "Gain {C:money}$#1#{}" } },
    config = { extra = { dollars = 2 } },
    sprite = "sigil.png",
    use = function(self, card) ease_dollars(card.ability.extra.dollars) end,
}
]]

local function install_pk()
    wipe_mods()
    write_mod("PackTypes", { id = "PackTypes", prefix = "pk", main_file = "main.lua", version = "1" }, PTYPES)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.PackTypes.status, "loaded", tostring(ModLoader.by_id.PackTypes.error))
    local game = bootstrap.new_game(4465)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    return game
end

suite.test("custom consumable types: packs opt-in deals the kind, and a dealt card picks and uses", function()
    local game = install_pk()
    local entry = SMODS.ConsumableTypes["pk_Minor"]
    T.assert_eq(entry.packs.arcana, 96, "the type records its pack rates")
    local subs = SMODS.pack_substitutions("arcana")
    T.assert_true(subs ~= nil and #subs == 1 and subs[1].kind == "Minor" and subs[1].rate == 96,
        "the pack substitution list carries the kind and its rate")
    T.assert_eq(SMODS.pack_substitutions("buffoon"), nil, "no kind opts into Buffoon packs")

    -- Every opted-in pack kind deals both Minor cards (rate 96 against the pack
    -- kind's 4, and the two-card pool is then culled for the rest of the pack).
    game.consumables, game.jokers = {}, {}
    for _, pack in ipairs({ "arcana", "celestial", "spectral" }) do
        for round = 1, 10 do
            game.ante = round
            local seen = {}
            local choices = game:_booster_build_choices({ pack = pack, card_count = 5, picks_granted = 2 })
            T.assert_eq(#choices, 5, pack .. " still deals a full pack")
            for _, ch in ipairs(choices) do
                if ch.consumable_def then seen[ch.consumable_def.id] = true end
            end
            T.assert_true(seen["c_pk_coin"] and seen["c_pk_sigil"],
                pack .. " pack deals both Minor cards (round " .. round .. ")")
        end
    end

    -- Open a real Arcana pack and use a dealt Minor card straight out of it: its
    -- `use` reads `card.ability`, which the pack's def copy now carries.
    game.STATE = game.STATES.SHOP
    game.money = 10
    game:begin_booster_session({ kind = "booster", pack = "arcana", size = "mega",
        card_count = 5, picks_granted = 2, booster_sprite_index = 0 })
    local sess = game.booster_session
    T.assert_true(sess ~= nil, "the pack session opens")
    local idx, want
    for i, ch in ipairs(sess.choices) do
        if ch.consumable_def and ch.consumable_def.id == "c_pk_coin" then idx, want = i, 5 end
        if ch.consumable_def and ch.consumable_def.id == "c_pk_sigil" and not idx then idx, want = i, 2 end
    end
    T.assert_true(idx ~= nil, "a Minor card is among the choices")
    T.assert_true(game.booster_session.choices[idx].consumable_def.ability ~= nil,
        "the dealt def copy carries its ability")
    T.assert_true(game:_booster_choice_is_custom_consumable(sess.choices[idx]))
    T.assert_true(game:pick_booster_choice(idx), "the custom-kind choice picks")
    T.assert_eq(game.money, 10 + want, "and its use fires from the pack")
    T.assert_true(sess.choices[idx].taken)
    game:end_booster_session()
    wipe_mods()
end)

suite.test("custom consumable types: no packs opt-in, no pack appearances; bad packs are load errors", function()
    wipe_mods()
    write_mod("NoPacks", { id = "NoPacks", prefix = "np", main_file = "main.lua", version = "1" }, [[
SMODS.ConsumableType {
    key = "Minor",
    loc_txt = { name = "Minor Arcana" },
    shop_rate = 0,
}
SMODS.Consumable {
    set = "Minor", key = "coin",
    loc_txt = { name = "Coin", text = { "Gain $5" } },
    config = { extra = { dollars = 5 } },
    sprite = "coin.png",
    use = function(self, card) ease_dollars(5) end,
}
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.NoPacks.status, "loaded", tostring(ModLoader.by_id.NoPacks.error))
    T.assert_eq(SMODS.pack_substitutions("arcana"), nil, "a type without packs opts into nothing")
    local game = bootstrap.new_game(4466)
    G = game
    game.consumables, game.jokers = {}, {}
    for round = 1, 30 do
        game.ante = round
        for _, ch in ipairs(game:_booster_build_choices({ pack = "arcana", card_count = 5 })) do
            T.assert_true(ch.consumable_def == nil or ch.consumable_def.id ~= "c_np_coin",
                "the kind never appears without opting in")
        end
    end
    wipe_mods()

    write_mod("BadPacks", { id = "BadPacks", prefix = "bp", main_file = "main.lua", version = "1" }, [[
SMODS.ConsumableType {
    key = "Minor",
    loc_txt = { name = "Minor Arcana" },
    packs = { buffoon = 2 },
}
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.BadPacks.status, "error")
    T.assert_true(tostring(ModLoader.by_id.BadPacks.error):find("buffoon", 1, true) ~= nil,
        "the error names the bad pack: " .. tostring(ModLoader.by_id.BadPacks.error))
    wipe_mods()
end)

suite.test("a mod Tarot used straight out of a pack reads its card.ability", function()
    wipe_mods()
    write_mod("PackBug", { id = "PackBug", prefix = "pb", main_file = "main.lua", version = "1" }, [[
SMODS.Consumable {
    set = "Tarot", key = "purse",
    loc_txt = { name = "The Purse", text = { "Gain {C:money}$#1#{}" } },
    config = { extra = { dollars = 7 } },
    sprite = "purse.png",
    use = function(self, card) ease_dollars(card.ability.extra.dollars) end,
}
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.PackBug.status, "loaded", tostring(ModLoader.by_id.PackBug.error))
    local game = bootstrap.new_game(4467)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.consumables, game.jokers = {}, {}
    game.money = 10
    local dealt
    for round = 1, 200 do
        game.ante = round
        local choices = game:_booster_build_choices({ pack = "arcana", card_count = 5, picks_granted = 1 })
        for i, ch in ipairs(choices) do
            if ch.consumable_def and ch.consumable_def.id == "c_pb_purse" then
                dealt = { choices = choices, idx = i }
                break
            end
        end
        if dealt then break end
    end
    T.assert_true(dealt ~= nil, "the Purse is dealt by an Arcana pack")
    T.assert_true(dealt.choices[dealt.idx].consumable_def.ability ~= nil,
        "the pack's def copy materialises ability (the pack-path bug)")
    game.booster_session = { choices = dealt.choices, picks_remaining = 1,
        hand_for_tarot = false, choice_nodes = {} }
    T.assert_true(game:pick_booster_choice(dealt.idx), "the dealt Tarot picks")
    T.assert_eq(game.money, 17, "its use read card.ability and paid out")
    wipe_mods()
end)

-- The seeded pack contents of a vanilla install, captured from the build
-- before custom-kind pack support: any change to the vanilla draw sequence
-- (extra RNG draws, reordered pools) breaks this line by line.
local BASELINE_PACK_SEQ = {
    "arcana:tarot_death,tarot_empress,tarot_chariot,tarot_star,tarot_lovers",
    "celestial:planet_mars,planet_uranus,planet_neptune,planet_earth,planet_jupiter",
    "spectral:spectral_ouija,spectral_sigil,spectral_deja_vu,spectral_wraith,spectral_ectoplasm",
    "buffoon:j_drunkard,j_scary_face,j_mad,j_smiley_face,j_8_ball",
    "standard:P14/Diamonds/wild/-,P6/Hearts/wild/-,P10/Clubs/-/-,P8/Hearts/-/-,P8/Hearts/mult/-",
    "arcana:tarot_hanged_man,tarot_empress,tarot_moon,tarot_magician,tarot_death",
    "celestial:planet_neptune,planet_pluto,planet_earth,planet_jupiter,planet_saturn",
    "spectral:spectral_hex,spectral_deja_vu,spectral_familiar,spectral_aura,spectral_medium",
    "buffoon:j_baron,j_gros_michel,j_zany,j_walkie_talkie,j_mad",
    "standard:P7/Clubs/-/-,P12/Clubs/glass/-,P14/Hearts/-/-,P11/Clubs/wild/-,P14/Diamonds/gold/-",
    "arcana:tarot_justice,tarot_strength,tarot_star,tarot_judgement,tarot_sun",
    "celestial:planet_venus,planet_pluto,planet_mercury,planet_earth,planet_mars",
    "spectral:spectral_hex,spectral_sigil,spectral_grim,spectral_medium,spectral_ankh",
    "buffoon:j_joker,j_spare_trousers,j_raised_fist,j_dna,j_gluttenous_joker",
    "standard:P9/Spades/-/-,P8/Clubs/-/-,P9/Hearts/-/-,P2/Spades/stone/-,P3/Hearts/-/-",
    "arcana:tarot_devil,tarot_fool,tarot_sun,tarot_judgement,tarot_hierophant",
    "celestial:planet_mercury,planet_earth,planet_saturn,planet_mars,planet_venus",
    "spectral:spectral_immolate,spectral_ouija,spectral_grim,spectral_incantation,spectral_familiar",
    "buffoon:j_todo_list,j_mail,j_reserved_parking,j_castle,j_trading_card",
    "standard:P14/Hearts/-/-,P13/Hearts/stone/-,P14/Diamonds/-/-,P9/Diamonds/bonus/-,P9/Clubs/-/-",
    "arcana:tarot_emperor,tarot_magician,tarot_world,tarot_strength,tarot_devil",
    "celestial:planet_mercury,planet_saturn,planet_jupiter,planet_uranus,planet_earth",
    "spectral:spectral_ouija,spectral_trance,spectral_ectoplasm,spectral_talisman,spectral_hex",
    "buffoon:j_fibonacci,j_crazy,j_castle,j_odd_todd,j_egg",
    "standard:P2/Spades/wild/-,P6/Diamonds/-/-,P11/Hearts/-/-,P13/Hearts/gold/-,P12/Hearts/mult/-",
    "arcana:tarot_judgement,tarot_devil,tarot_chariot,tarot_strength,tarot_high_priestess",
    "celestial:planet_jupiter,planet_mars,planet_neptune,planet_venus,planet_mercury",
    "spectral:spectral_ectoplasm,spectral_trance,spectral_aura,spectral_familiar,spectral_immolate",
    "buffoon:j_vagabond,j_burglar,j_walkie_talkie,j_todo_list,j_campfire",
    "standard:P13/Clubs/-/-,P9/Hearts/-/-,P2/Hearts/-/-,P11/Clubs/bonus/-,P13/Hearts/-/-",
}

local function pack_sequence(game)
    local packs = { "arcana", "celestial", "spectral", "buffoon", "standard" }
    local out = {}
    for round = 1, 6 do
        game.ante = round
        for _, pack in ipairs(packs) do
            local ids = {}
            for _, ch in ipairs(game:_booster_build_choices({ pack = pack, card_count = 5, picks_granted = 2 })) do
                if ch.consumable_def then
                    ids[#ids + 1] = ch.consumable_def.id
                elseif ch.joker_id then
                    ids[#ids + 1] = ch.joker_id
                else
                    local d = ch.playing_data
                    ids[#ids + 1] = "P" .. tostring(d.rank) .. "/" .. tostring(d.suit)
                        .. "/" .. tostring(d.enhancement or "-") .. "/" .. tostring(d.edition or "-")
                end
            end
            out[#out + 1] = pack .. ":" .. table.concat(ids, ",")
        end
    end
    return out
end

suite.test("booster pack contents are the seeded vanilla sequence, before and after a pack-type rollback", function()
    wipe_mods()
    local game = bootstrap.new_game(9101)
    G = game
    game.consumables, game.jokers = {}, {}
    local seq = pack_sequence(game)
    T.assert_eq(#seq, #BASELINE_PACK_SEQ)
    for i, line in ipairs(BASELINE_PACK_SEQ) do
        T.assert_eq(seq[i], line, "sequence line " .. i)
    end

    -- Registering an opted-in type and rolling it back restores the sequence.
    local game2 = install_pk()
    T.assert_true(SMODS.pack_substitutions("arcana") ~= nil, "the type is live for this part")
    wipe_mods()
    T.assert_eq(SMODS.pack_substitutions("arcana"), nil, "rollback removes the opt-in")
    local game3 = bootstrap.new_game(9101)
    G = game3
    game3.consumables, game3.jokers = {}, {}
    local seq3 = pack_sequence(game3)
    for i, line in ipairs(BASELINE_PACK_SEQ) do
        T.assert_eq(seq3[i], line, "post-rollback sequence line " .. i)
    end
end)

suite.test("custom consumable kinds get their own collection category", function()
    local game = install_pk()
    local Catalog = require("collection_catalog")
    Catalog.invalidate_cache()
    local def = Catalog.get_category_def("consumable_kind_Minor")
    T.assert_true(def ~= nil, "the kind has a category def")
    T.assert_eq(def.label, "Minor Arcana", "labelled with the type's name")
    T.assert_eq(def.group, "consumables")
    local entries = Catalog.get_entries("consumable_kind_Minor")
    T.assert_eq(#entries, 2, "both Minor cards are listed")
    for _, e in ipairs(entries) do
        T.assert_eq(e.category, "consumable_kind_Minor")
        T.assert_eq(e.node_kind, "consumable")
    end
    local prog = Catalog.get_progress(game, "consumable_kind_Minor")
    T.assert_eq(prog.total, 2)
    T.assert_eq(#Catalog.get_entries("tarots"), 22, "vanilla categories untouched")
    T.assert_eq(#Catalog.get_entries("planets"), 12)
    T.assert_eq(#Catalog.get_entries("spectrals"), 18)
    T.assert_eq(#Catalog.categories(), #Catalog.CATEGORIES + 1, "one category is added")

    wipe_mods()
    Catalog.invalidate_cache()
    T.assert_eq(Catalog.get_category_def("consumable_kind_Minor"), nil, "the category goes with the mod")
    T.assert_eq(#Catalog.get_entries("consumable_kind_Minor"), 0)
    T.assert_eq(#Catalog.categories(), #Catalog.CATEGORIES, "and the category list is vanilla again")
end)

--------------------------------------------------------------------------------
-- Custom centers: enhancements, seals and editions (SMODS.Enhancement / Seal / Edition)
--------------------------------------------------------------------------------

local CENTERS = [[
SMODS.Enhancement {
    key = "copper",
    loc_txt = { name = "Copper", text = { "{C:chips}+#1#{} Chips", "{C:mult}+#2#{} Mult when played" } },
    config = { chips = 25, h_chips = 10, h_dollars = 2 },
    loc_vars = function(self, info_queue, card) return { vars = { self.config.chips, 3 } } end,
    calculate = function(self, card, context)
        if context.card_played then return { mult = 3 } end
    end,
}
SMODS.Seal {
    key = "lime",
    loc_txt = { name = "Lime Seal", text = { "Earn {C:money}$2{} when played", "Retrigger this card" } },
    config = { retrigger = 1 },
    calculate = function(self, card, context)
        if context.repetition then return { repetitions = 1 } end
        if context.card_played then return { dollars = 2 } end
        if context.on_discard then _G.T3_DISCARDS = (_G.T3_DISCARDS or 0) + 1 end
    end,
}
SMODS.Edition {
    key = "fluoro",
    loc_txt = { name = "Fluorescent", text = { "{C:chips}+40{} Chips, {C:mult}+6{} Mult,", "{X:mult,C:white}X2{} Mult" } },
    config = { chips = 40, mult = 6, x_mult = 2 },
}
SMODS.Edition {
    key = "roomy",
    loc_txt = { name = "Roomy", text = { "{C:attention}+1{} Joker slot" } },
    config = { joker_slots = 1 },
    weight = 0,
}
SMODS.Consumable {
    set = "tarot", key = "brand",
    loc_txt = { name = "The Brand", text = { "Enhances {C:attention}1{} selected card", "into a {C:chips}Copper{} card" } },
    config = { max_highlighted = 1, mod_conv = "m_copper" },
    sprite = "brand.png",
}
]]

local function install_t3(seed)
    wipe_mods()
    write_mod("Centers", { id = "Centers", prefix = "t3", main_file = "main.lua", version = "1" }, CENTERS)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Centers.status, "loaded", tostring(ModLoader.by_id.Centers.error))
    local game = bootstrap.new_game(seed or 4470)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    return game
end

local function hand_node(game, rank, suit, fields)
    local hand = Hand(game)
    game.hand = hand
    local data = { rank = rank, suit = suit }
    for k, v in pairs(fields or {}) do data[k] = v end
    hand:add_card(data)
    return hand.card_nodes[#hand.card_nodes]
end

suite.test("custom centers: registration, resolvers and rollback", function()
    local game = install_t3()
    T.assert_true(SMODS.EnhancementByValue.copper ~= nil, "the enhancement registers by value")
    T.assert_eq(SMODS.Enhancements["t3_copper"].value, "copper")
    T.assert_eq(SMODS.Enhancements["t3_copper"].mod.id, "Centers")
    T.assert_true(SMODS.SealByValue.lime ~= nil and SMODS.EditionByValue.fluoro ~= nil)
    T.assert_eq(SMODS.EditionByValue.roomy.weight, 0, "weight 0 keeps an edition out of the polls")

    T.assert_eq(SMODS.enhancement_name("copper"), "copper")
    T.assert_eq(SMODS.enhancement_name("m_copper"), "copper", "Steamodded-style key resolves")
    T.assert_eq(SMODS.enhancement_name("m_t3_copper"), "copper", "and by full id")
    T.assert_eq(SMODS.enhancement_name("m_bonus"), "bonus", "vanilla m_ keys still resolve")
    T.assert_eq(SMODS.enhancement_name("bogus"), nil)
    T.assert_eq(SMODS.seal_name("Lime"), "lime", "seal names are case-insensitive")
    T.assert_eq(SMODS.seal_name("gold"), "gold")
    T.assert_eq(SMODS.edition_value("fluoro"), "fluoro")
    T.assert_eq(SMODS.edition_value("e_fluoro"), "fluoro")
    T.assert_eq(SMODS.edition_value("Holographic"), "holo", "vanilla spellings still resolve")
    T.assert_eq(SMODS.edition_value("bogus"), nil)
    T.assert_eq(Joker.normalize_edition("fluoro"), "fluoro", "a registered edition survives normalization")
    T.assert_eq(Joker.normalize_edition("e_roomy"), "roomy")

    -- The tooltip reads the registered name and loc text.
    local name, lines = SMODS.center_tooltip("enhancement", "copper")
    T.assert_eq(name, "Copper")
    T.assert_true(lines[1] ~= nil and lines[1]:find("25", 1, true) ~= nil,
        "loc_vars fill the tooltip line: " .. tostring(lines[1]))
    local vname = SMODS.center_tooltip("seal", "gold")
    T.assert_eq(vname, nil, "vanilla centers are not the registry's business")

    wipe_mods()
    T.assert_eq(next(SMODS.Enhancements), nil, "enhancements unregister on rollback")
    T.assert_eq(next(SMODS.EnhancementByValue), nil)
    T.assert_eq(next(SMODS.Seals), nil)
    T.assert_eq(next(SMODS.SealByValue), nil)
    T.assert_eq(next(SMODS.Editions), nil)
    T.assert_eq(next(SMODS.EditionByValue), nil)
    T.assert_eq(SMODS.enhancement_name("copper"), nil, "the resolver forgets with the registry")
    T.assert_eq(Joker.normalize_edition("fluoro"), "base", "and normalization falls back to base")
end)

suite.test("custom centers: add_card creates them and scoring lands", function()
    local game = install_t3()
    game.hand = Hand(game)   -- a headless game has no hand until a run starts one

    -- A playing card carrying all three, created the mod way.
    local view = SMODS.add_card { set = "Playing", rank = 9, suit = "Hearts",
        enhancement = "copper", seal = "Lime", edition = "fluoro" }
    T.assert_true(view ~= nil, "add_card accepts the registered centers")
    local node = game.hand.card_nodes[#game.hand.card_nodes]
    T.assert_eq(node.card_data.enhancement, "copper")
    T.assert_eq(node.card_data.seal, "lime", "the seal stores its canonical value")
    T.assert_eq(node.card_data.modifier.edition, "fluoro")

    -- The enhancement's config lands when the card scores, and its calculate
    -- return lands on top.
    local ctx = { chips = 0, mult = 1 }
    T.assert_true(node:emit_hand_event("card_played", ctx), "the enhancement fires")
    T.assert_eq(ctx.chips, 25, "config chips")
    T.assert_eq(ctx.mult, 4, "calculate's +3 Mult on the base 1")

    -- Held in hand, the h_ config lands instead.
    local held = { chips = 0, mult = 1 }
    T.assert_true(node:emit_hand_event("held_in_hand", held))
    T.assert_eq(held.chips, 10, "h_chips while held")

    -- At round end the held dollars land, and the seal's played dollars did too.
    local money = game.money
    T.assert_true(node:emit_hand_event("on_round_end", { chips = 0, mult = 1 }))
    T.assert_eq(game.money, money + 2, "h_dollars at round end")
    local played = { chips = 0, mult = 1 }
    node:emit_hand_event("card_played", played)
    T.assert_eq(game.money, money + 4, "the seal's calculate paid its $2 as well")

    -- The seal hears the discard moment.
    _G.T3_DISCARDS = 0
    node:emit_hand_event("on_discard", { discard_reason = "discard" })
    T.assert_eq(_G.T3_DISCARDS, 1, "the seal's calculate saw the discard")
    _G.T3_DISCARDS = nil

    -- The seal's retriggers: config's one plus calculate's one.
    local out = game:collect_retrigger_sources(false, { card_node = node }, {})
    T.assert_eq(#out, 2, "config retrigger + calculate repetitions")

    -- The edition on a playing card contributes its numbers.
    local cb, mb, xb = game.hand:get_playing_card_edition_bonus(node.card_data)
    T.assert_eq(cb, 40); T.assert_eq(mb, 6); T.assert_eq(xb, 2)
    local c2, m2 = game.hand:apply_playing_card_edition(10, 2, node.card_data)
    T.assert_eq(c2, 50); T.assert_eq(m2, 16)

    -- The same edition on a Joker: flat numbers before its effect, x_mult after.
    local joker = add(game, "j_joker")
    joker.edition = "fluoro"
    local jctx = { chips = 0, mult = 1 }
    joker:apply_edition_on_hand_scored(jctx, false)
    T.assert_eq(jctx.chips, 40, "edition chips before the Joker's effect")
    T.assert_eq(jctx.mult, 7, "edition mult before")
    joker:apply_edition_on_hand_scored(jctx, true)
    T.assert_eq(jctx.mult, 14, "edition x_mult after")

    -- An edition created through add_card keeps its name on the Joker.
    local made = SMODS.add_card { set = "Joker", key = "j_joker", edition = "e_fluoro" }
    T.assert_true(made ~= nil)
    T.assert_eq(Joker.normalize_edition(made.edition), "fluoro")

    -- A slots edition widens the Joker area while held.
    local plain = add(game, "j_joker")
    game:refresh_joker_capacity_from_negatives()
    local base_cap = game.joker_capacity
    plain.edition = "roomy"
    game:refresh_joker_capacity_from_negatives()
    T.assert_eq(game.joker_capacity, base_cap + 1, "joker_slots from the edition's config")
    plain.edition = "base"
    game:refresh_joker_capacity_from_negatives()
    T.assert_eq(game.joker_capacity, base_cap, "and gives it back")
    wipe_mods()
end)

suite.test("custom centers: polls reach them, and unloaded polls stay vanilla", function()
    local game = install_t3(4471)
    game.ante = 1
    local enh_seen, seal_seen, ed_seen = {}, {}, {}
    for _ = 1, 800 do
        local d = game:_roll_playing_card_data(true, "sta", true)
        if d.enhancement then enh_seen[d.enhancement] = true end
        if d.seal then seal_seen[d.seal] = true end
        if d.modifier then ed_seen[d.modifier.edition] = true end
    end
    T.assert_true(enh_seen.copper, "the enhancement polls in Standard-pack rolls")
    T.assert_true(enh_seen.bonus and enh_seen.stone, "and the vanilla ones still do")
    T.assert_true(seal_seen.lime, "the seal polls")
    T.assert_true(seal_seen.red or seal_seen.blue or seal_seen.gold or seal_seen.purple,
        "and vanilla seals still do")
    T.assert_true(ed_seen.fluoro, "the edition polls in Standard-pack rolls")
    T.assert_true(ed_seen.roomy == nil, "a weight-0 edition never polls")

    local shop_seen = {}
    for _ = 1, 3000 do shop_seen[game:roll_joker_offer_edition("sho")] = true end
    T.assert_true(shop_seen.fluoro, "the edition polls in the shop ladder")
    T.assert_true(shop_seen.base and shop_seen.foil, "and the ladder's vanilla answers stand")

    local guar_seen = {}
    for _ = 1, 1200 do guar_seen[game:poll_guaranteed_edition("t3g")] = true end
    T.assert_true(guar_seen.fluoro, "the edition polls in guaranteed rolls")
    T.assert_true(guar_seen.foil and guar_seen.holo and guar_seen.polychrome,
        "and the guaranteed vanilla three stand")

    -- The seeded invariance: the same seed, no mod, the exact same sequence --
    -- before the mod ever loads, and again after it is rolled back.
    local function sequence(g)
        g.ante = 1
        local parts = {}
        for _ = 1, 150 do
            local d = g:_roll_playing_card_data(true, "sta", true)
            parts[#parts + 1] = table.concat({ tostring(d.enhancement), tostring(d.seal),
                tostring(d.modifier and d.modifier.edition) }, "/")
            parts[#parts + 1] = g:roll_joker_offer_edition("sho")
            parts[#parts + 1] = g:poll_guaranteed_edition("t3inv")
        end
        return table.concat(parts, ",")
    end
    wipe_mods()
    local plain1 = bootstrap.new_game(4472)
    G = plain1
    local before = sequence(plain1)
    local loaded = install_t3(4472)
    T.assert_true(sequence(loaded) ~= before, "registered centers change the polls")
    wipe_mods()
    local plain2 = bootstrap.new_game(4472)
    G = plain2
    T.assert_eq(sequence(plain2), before, "rollback restores the vanilla poll sequence exactly")
end)

suite.test("custom centers: mod_conv converts to a registered enhancement", function()
    local game = install_t3()
    game.STATE = game.STATES.SELECTING_HAND
    local a = Card(0, 0, 1, 1, { rank = 7, suit = "Hearts" })
    local selected = { a }
    game.hand = {
        ordered_selected_nodes = function() return selected end,
        clear_selection = function() end, layout = function() end,
        is_scoring_active = function() return false end,
    }
    game.consumables, game.consumable_nodes = {}, {}
    T.assert_true(game:add_consumable("c_t3_brand"))
    T.assert_true(game:consumable_use_enabled(1))
    T.assert_true(game:use_consumable(1))
    T.assert_eq(a.card_data.enhancement, "copper", "mod_conv = 'm_copper' converts to the registered enhancement")
    wipe_mods()
end)

suite.test("custom centers: unknown names are errors naming them", function()
    local game = install_t3()
    local ok, err = pcall(SMODS.add_card, { set = "Playing", rank = 7, suit = "Hearts", enhancement = "bogus" })
    T.assert_false(ok, "an unregistered enhancement is an error")
    T.assert_true(tostring(err):find("bogus", 1, true) ~= nil
        and tostring(err):find("enhancement", 1, true) ~= nil, tostring(err))
    ok, err = pcall(SMODS.add_card, { set = "Playing", rank = 7, suit = "Hearts", seal = "bogus" })
    T.assert_false(ok)
    T.assert_true(tostring(err):find("bogus", 1, true) ~= nil
        and tostring(err):find("seal", 1, true) ~= nil, tostring(err))
    ok, err = pcall(SMODS.add_card, { set = "Playing", rank = 7, suit = "Hearts", edition = "bogus" })
    T.assert_false(ok)
    T.assert_true(tostring(err):find("bogus", 1, true) ~= nil
        and tostring(err):find("edition", 1, true) ~= nil, tostring(err))
    ok, err = pcall(SMODS.add_card, { set = "Joker", key = "j_joker", edition = "bogus" })
    T.assert_false(ok, "an unregistered edition on a Joker is an error")
    T.assert_true(tostring(err):find("bogus", 1, true) ~= nil, tostring(err))
    wipe_mods()

    -- A consumable converting to an unregistered enhancement fails its load.
    wipe_mods()
    write_mod("BadConv", { id = "BadConv", prefix = "bc", main_file = "main.lua", version = "1" }, [[
SMODS.Consumable {
    set = "tarot", key = "bad",
    loc_txt = { name = "Bad" },
    config = { mod_conv = "m_bogus" },
    sprite = "bad.png",
}
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.BadConv.status, "error")
    T.assert_true(tostring(ModLoader.by_id.BadConv.error):find("m_bogus", 1, true) ~= nil,
        "the load error names the conversion: " .. tostring(ModLoader.by_id.BadConv.error))
    wipe_mods()

    -- A key that reuses a vanilla center's name is refused at registration.
    write_mod("Clash", { id = "Clash", prefix = "cl", main_file = "main.lua", version = "1" }, [[
SMODS.Enhancement { key = "bonus", loc_txt = { name = "Bonus II" } }
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Clash.status, "error")
    T.assert_true(tostring(ModLoader.by_id.Clash.error):find("bonus", 1, true) ~= nil,
        tostring(ModLoader.by_id.Clash.error))
    T.assert_eq(SMODS.EnhancementByValue.bonus, nil, "the vanilla name was not claimed")
    wipe_mods()
end)

suite.test("custom centers: an orphaned save value loads and scores nothing", function()
    wipe_mods()
    local game = bootstrap.new_game(4473)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    -- A card restored from a save whose mod is gone: the strings ride along in
    -- card_data, and every read of them must degrade, never crash.
    local node = hand_node(game, 7, "Hearts", { enhancement = "copper", seal = "lime" })
    node.card_data.modifier = { edition = "fluoro" }
    local ctx = { chips = 0, mult = 1 }
    T.assert_false(node:emit_hand_event("card_played", ctx), "no enhancement fires")
    T.assert_eq(ctx.chips, 0); T.assert_eq(ctx.mult, 1)
    T.assert_false(node:emit_hand_event("held_in_hand", { chips = 0, mult = 1 }))
    T.assert_false(node:emit_hand_event("on_round_end", { chips = 0, mult = 1 }))
    T.assert_false(node:emit_hand_event("on_discard", { discard_reason = "discard" }))
    T.assert_eq(game.money, 10, "no seal paid out")
    local out = game:collect_retrigger_sources(false, { card_node = node }, {})
    T.assert_eq(#out, 0, "no seal retriggers")
    local cb, mb, xb = game.hand:get_playing_card_edition_bonus(node.card_data)
    T.assert_eq(cb, 0); T.assert_eq(mb, 0); T.assert_eq(xb, 1)
    T.assert_eq(Joker.normalize_edition("fluoro"), "base", "a Joker's orphaned edition normalizes away")
end)

--------------------------------------------------------------------------------
-- Custom tags (SMODS.Tag)
--------------------------------------------------------------------------------

local TAGS = [[
SMODS.Tag {
    key = "windfall",
    loc_txt = { name = "Windfall Tag", text = { "Gain {C:money}$#1#{}" } },
    config = { type = "immediate", dollars = 7 },
    loc_vars = function(self, info_queue, tag) return { vars = { self.config.dollars } } end,
    apply = function(self, tag, context)
        G.money = G.money + tag.ability.dollars
        return true
    end,
}
SMODS.Tag {
    key = "stash",
    loc_txt = { name = "Stash Tag", text = { "Create a {C:tarot}Fool{}" } },
    config = { type = "new_blind_choice" },
    apply = function(self, tag, context)
        return SMODS.add_card { set = "Tarot", key = "tarot_fool" } ~= nil
    end,
}
SMODS.Tag {
    key = "kickback",
    loc_txt = { name = "Kickback Tag", text = { "Gain {C:money}$3{}" } },
    config = { type = "shop_start" },
    apply = function(self, tag, context)
        G.money = G.money + 3
        return true
    end,
}
SMODS.Tag {
    key = "tithe",
    loc_txt = { name = "Tithe Tag", text = { "Earn {C:money}$5{}" } },
    config = { type = "eval" },
    apply = function(self, tag, context)
        if context.add_round_win_payout then
            context.add_round_win_payout("Tithe Tag", 5)
            return true
        end
    end,
}
SMODS.Tag {
    key = "dud",
    loc_txt = { name = "Dud Tag", text = { "Does nothing, stays held" } },
    config = { type = "immediate" },
    apply = function(self, tag, context) return false end,
}
SMODS.Tag {
    key = "ghost",
    loc_txt = { name = "Ghost Tag", text = { "Never polled" } },
    config = { type = "immediate" },
    weight = 0,
    apply = function(self, tag, context) return true end,
}
]]

local function install_tags(seed)
    wipe_mods()
    write_mod("Tags", { id = "Tags", prefix = "tg", main_file = "main.lua", version = "1" }, TAGS)
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.Tags.status, "loaded", tostring(ModLoader.by_id.Tags.error))
    local game = bootstrap.new_game(seed or 4480)
    G = game
    G.play = G.play or SMODS.PLAY
    _G.Top = _G.Top or { addPopup = function() end }
    game.money = 10
    return game
end

suite.test("custom tags: registration, addTag by key and full id, immediate use", function()
    local game = install_tags()
    local entry = SMODS.Tags["tg_windfall"]
    T.assert_true(entry ~= nil, "the tag registers under its full id")
    T.assert_eq(entry.type, "windfall")
    T.assert_eq(entry.moment, "immediate")
    T.assert_eq(entry.weight, 1, "default weight is vanilla's 1")
    T.assert_eq(SMODS.TagByType["windfall"], entry)
    T.assert_true(SMODS.tag_entry_for("tg_windfall") == entry, "resolved by full id")
    T.assert_true(SMODS.tag_entry_for("Windfall") == entry, "resolved by key, any case")

    -- A held tag carries its def's config as its ability.
    game:addTag("dud")
    T.assert_eq(#game.tags, 1, "an apply that returns false stays held")
    T.assert_eq(game.tags[1].type, "dud")
    game:removeTag(1)

    -- Immediate tags fire as they are gained and are not stored.
    game:addTag("windfall")
    T.assert_eq(game.money, 17, "the immediate apply paid out")
    T.assert_eq(#game.tags, 0, "a fired tag is consumed, not held")
    T.assert_eq(game:hasTag("windfall"), -1)
    game:addTag("tg_windfall")
    T.assert_eq(game.money, 24, "the full id names the same tag")

    -- Tooltips come from the registration.
    local name, lines = SMODS.tag_tooltip("windfall")
    T.assert_eq(name, "Windfall Tag")
    T.assert_eq(#lines, 1)
    T.assert_true(lines[1]:find("$7", 1, true) ~= nil, "loc_vars fill the text: " .. lines[1])
    local tip = game:get_skip_tag_tooltip(entry.skip_id, nil)
    T.assert_eq(tip.name, "Windfall Tag")
    T.assert_eq(tip.type, "windfall")
    T.assert_true(tip.description:find("$7", 1, true) ~= nil, tip.description)
    wipe_mods()
end)

suite.test("custom tags: blind-choice tags wait for their moment, then fire", function()
    local game = install_tags()
    game.consumables, game.consumable_nodes = {}, {}
    game:addTag("stash")
    T.assert_eq(#game.tags, 1, "a blind-choice tag does not fire as it is gained")
    T.assert_eq(#game.consumables, 0)
    T.assert_true(game:apply_new_blind_choice_tags(), "it fires at blind select")
    T.assert_eq(#game.tags, 0, "and is consumed")
    T.assert_eq(#game.consumables, 1, "its apply created the Fool")
    T.assert_eq(game.consumables[1].id, "tarot_fool")
    wipe_mods()
end)

suite.test("custom tags: shop_start and eval moments dispatch and consume", function()
    local game = install_tags()
    game:addTag("kickback")
    game:addTag("tithe")
    T.assert_eq(#game.tags, 2, "neither fires as it is gained")
    T.assert_eq(SMODS.tag_moment(game, "shop_start"), 1, "the shop_start tag fires")
    T.assert_eq(game.money, 13)
    T.assert_eq(#game.tags, 1, "and is consumed; the eval tag still waits")
    local paid = {}
    local ctx = { add_round_win_payout = function(name, n) paid[#paid + 1] = n end }
    T.assert_eq(SMODS.tag_moment(game, "eval", ctx), 1, "the eval tag fires")
    T.assert_eq(paid[1], 5, "through the payout context the engine hands it")
    T.assert_eq(#game.tags, 0)
    wipe_mods()
end)

suite.test("custom tags: the skip poll deals them at weight, and never weight 0", function()
    local game = install_tags(5190)
    local saw, slots = {}, 0
    for ante = 1, 300 do
        game.ante = ante
        game:roll_skips()
        for slot = 1, 2 do
            local type_name = game:tag_type_for_id(game.skips[slot])
            if type_name then saw[type_name] = true end
            slots = slots + 1
        end
    end
    T.assert_eq(slots, 600)
    T.assert_true(saw["windfall"], "the weight-1 tag is dealt by the poll")
    T.assert_true(saw["ghost"] == nil, "a weight-0 tag is never dealt")
    wipe_mods()
end)

suite.test("custom tags: seeded vanilla skip sequence is untouched by registration", function()
    local function sequence(seed)
        local game = bootstrap.new_game(seed)
        G = game
        local ids = {}
        for ante = 1, 40 do
            game.ante = ante
            game:roll_skips()
            ids[#ids + 1] = game.skips[1]
            ids[#ids + 1] = game.skips[2]
        end
        return ids
    end
    wipe_mods()
    local vanilla = sequence(5191)
    install_tags(5191)
    local with_mod = sequence(5191)
    for i = 1, #vanilla do
        T.assert_true(with_mod[i] == vanilla[i] or (with_mod[i] or 0) >= 100,
            "slot " .. i .. ": the vanilla pick stands or a custom tag replaces it")
    end
    wipe_mods()
    local after = sequence(5191)
    for i = 1, #vanilla do
        T.assert_eq(after[i], vanilla[i], "rollback restores the exact sequence")
    end
end)

suite.test("custom tags: unknown names and bad registrations are errors naming them", function()
    local game = install_tags()
    local ok, err = pcall(function() game:addTag("nope") end)
    T.assert_false(ok, "an unknown tag name is an error")
    T.assert_true(tostring(err):find("nope", 1, true) ~= nil, tostring(err))
    T.assert_true(tostring(err):find("unknown tag", 1, true) ~= nil, tostring(err))
    T.assert_true(pcall(function() game:addTag("handy") end), "vanilla names still work")
    wipe_mods()

    write_mod("VanillaTag", { id = "VanillaTag", prefix = "vt", main_file = "main.lua", version = "1" }, [[
SMODS.Tag { key = "double", loc_txt = { name = "Double Ganger" } }
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.VanillaTag.status, "error")
    T.assert_true(tostring(ModLoader.by_id.VanillaTag.error):find("vanilla", 1, true) ~= nil,
        tostring(ModLoader.by_id.VanillaTag.error))
    wipe_mods()

    write_mod("BadMoment", { id = "BadMoment", prefix = "bm", main_file = "main.lua", version = "1" }, [[
SMODS.Tag { key = "shopkeep", loc_txt = { name = "Shopkeep" }, config = { type = "store_joker_create" } }
]])
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.BadMoment.status, "error")
    T.assert_true(tostring(ModLoader.by_id.BadMoment.error):find("store_joker_create", 1, true) ~= nil,
        "the error names the moment: " .. tostring(ModLoader.by_id.BadMoment.error))
    wipe_mods()
end)

suite.test("custom tags: saves round-trip, and an orphaned held tag is a no-op", function()
    local game = install_tags()
    game:addTag("stash")
    local snap = game:build_run_snapshot()
    T.assert_eq(snap.tags[1], "stash", "the held tag serializes as its type string")

    local restored = bootstrap.new_game(4481)
    G = restored
    T.assert_true(restored:load_run_snapshot(snap))
    T.assert_eq(#restored.tags, 1, "the tag is held again after a load")
    T.assert_eq(restored.tags[1].type, "stash")

    -- The mod goes away: registries empty, and the held orphan neither
    -- fires nor crashes at any dispatch.
    wipe_mods()
    T.assert_eq(next(SMODS.Tags), nil, "tags unregister on rollback")
    T.assert_eq(next(SMODS.TagByType), nil)
    T.assert_false(restored:apply_new_blind_choice_tags(), "an orphan does not fire")
    local orphan = restored.tags[1]
    T.assert_true(orphan ~= nil, "the orphan itself stays held and harmless")
    T.assert_false(orphan:Use("new_blind_choice"), "its Use is a no-op")

    -- A fresh load of the same snapshot skips the orphan silently.
    local fresh = bootstrap.new_game(4482)
    G = fresh
    T.assert_true(fresh:load_run_snapshot(snap))
    T.assert_eq(#fresh.tags, 0, "the orphaned type is skipped on restore")
    wipe_mods()
end)

return suite
