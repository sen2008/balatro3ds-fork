--- Hot-load sprite recovery: a hot-loaded pack's centres register and resolve
--- their sprites exactly like a boot-loaded pack's (pinned behaviour), and a
--- mod sprite whose texture build fails transiently at node construction --
--- the console failure behind the blank Fridge Magnet Lucas hit after
--- hot-loading Cryptid mid-session -- must not stay blank for the node's
--- whole life. `Joker:draw` retries the resolve, throttled, for mod sprites
--- only; vanilla keys keep the exact pre-fix behaviour (no draw-time loads).
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

bootstrap.load()
local ModLoader = require("mod_loader")

--------------------------------------------------------------------------------
-- Fixtures (same shape as tests/test_mod_hotload.lua)
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
    if fs.getInfo(ModLoader.BUNDLED_DIR) then rm(ModLoader.BUNDLED_DIR) end
    ModLoader.reset()
end

local function write_bundled_mod(folder, manifest, main)
    local base = ModLoader.BUNDLED_DIR .. "/" .. folder
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

local function write_enabled(ids)
    love.filesystem.createDirectory(ModLoader.DIR)
    love.filesystem.write(ModLoader.ENABLED_PATH, table.concat(ids, "\n") .. "\n")
end

local function one_joker(key)
    return ("SMODS.Joker { key = %q, loc_txt = { name = %q, text = { \"x\" } }, rarity = 1, cost = 1, sprite = %q }\n")
        :format(key, key, key .. ".png")
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

suite.test("hot-load: a bundled pack switched on mid-session resolves sprites like the boot pack", function()
    wipe_mods()
    write_bundled_mod("HeatA", { id = "HeatA", prefix = "hta", main_file = "main.lua", version = "1" },
        one_joker("one"))
    write_bundled_mod("HeatB", { id = "HeatB", prefix = "htb", main_file = "main.lua", version = "1" },
        one_joker("first") .. one_joker("second"))
    write_enabled({ "HeatA" }) -- HeatB off at boot: the hot-load case.
    ModLoader.load_all()
    T.assert_eq(ModLoader.by_id.HeatA.status, "loaded")
    T.assert_eq(ModLoader.by_id.HeatB.status, "disabled")

    local game = bootstrap.new_game(8801)
    G = game
    game.jokers = {}
    T.assert_true(game:add_joker_by_def("j_hta_one"))
    local boot_node = game.jokers[#game.jokers]
    T.assert_true(boot_node.front_sprite ~= nil and boot_node.front_sprite.image ~= nil,
        "boot-loaded pack's sprite materialises")

    T.assert_true(ModLoader.set_enabled("HeatB", true))
    T.assert_eq(ModLoader.by_id.HeatB.status, "loaded", tostring(ModLoader.by_id.HeatB.error))
    T.assert_true(game:add_joker_by_def("j_htb_first"))
    local hot_node = game.jokers[#game.jokers]
    T.assert_eq(hot_node.front_sprite_key, "mod:htb:first.png")
    T.assert_true(hot_node.front_sprite ~= nil and hot_node.front_sprite.image ~= nil,
        "hot-loaded pack's sprite materialises the same way")
    T.assert_eq(game.JOKER_SPRITES["mod:htb:first.png"].load_error, nil)
    -- The boot pack's sprite is undisturbed by the hot-load.
    T.assert_true(boot_node.front_sprite.image ~= nil, "boot sprite still resolved after hot-load")
    wipe_mods()
end)

suite.test("a mod sprite that fails to build at construction recovers on draw; vanilla does not retry", function()
    wipe_mods()
    write_bundled_mod("HeatB", { id = "HeatB", prefix = "htb", main_file = "main.lua", version = "1" },
        one_joker("first") .. one_joker("second"))
    ModLoader.load_all() -- off at boot
    local game = bootstrap.new_game(8802)
    G = game
    game.jokers = {}
    T.assert_true(ModLoader.set_enabled("HeatB", true))
    T.assert_eq(ModLoader.by_id.HeatB.status, "loaded", tostring(ModLoader.by_id.HeatB.error))

    local key2 = "mod:htb:second.png"
    local path2 = SMODS.sprite_path(key2)
    T.assert_true(path2 ~= nil, "second sprite registered by the hot-load")

    -- A vanilla node prepared the same way, for the gate check below.
    T.assert_true(game:add_joker_by_def("j_joker"))
    local vanilla_node = game.jokers[#game.jokers]
    local vkey = vanilla_node.front_sprite_key
    T.assert_true(vkey ~= nil and SMODS.sprite_path(vkey) == nil,
        "vanilla front key is not a mod sprite: " .. tostring(vkey))
    local vpath = game.JOKER_SPRITES[vkey].path

    -- Simulate the transient console failure: newImage throws for the two
    -- paths while the flag is set, then builds again once it clears.
    local failing = {}
    local attempts = {}
    local real_new_image = love.graphics.newImage
    love.graphics.newImage = function(path, ...)
        attempts[path] = (attempts[path] or 0) + 1
        if failing[path] then error("simulated transient texture failure") end
        return real_new_image(path, ...)
    end

    local obs = {}
    failing[path2] = true
    local ok_add = game:add_joker_by_def("j_htb_second")
    local node2 = game.jokers[#game.jokers]
    -- On screen, as a booster choice or an owned joker is when drawn; a node
    -- still in its arrive state is not drawn at all.
    node2.states.visible = true
    vanilla_node.states.visible = true
    obs.added = ok_add
    obs.blank_at_construct = node2.front_sprite == nil or node2.front_sprite.image == nil
    obs.load_error_at_construct = game.JOKER_SPRITES[key2].load_error ~= nil

    -- Recovery: the failure clears, time passes, the node draws.
    failing[path2] = nil
    love._test.advance(1)
    node2:draw()
    obs.recovered_on_draw = node2.front_sprite ~= nil and node2.front_sprite.image ~= nil
    obs.load_error_cleared = game.JOKER_SPRITES[key2].load_error == nil

    -- Throttle: blank it again under failure; an immediate draw must not
    -- retry, a draw after the interval must.
    failing[path2] = true
    game:unload_joker_sprite(key2)
    node2:refresh_quads()
    obs.blanked_again = node2.front_sprite == nil or node2.front_sprite.image == nil
    local before = attempts[path2]
    node2:draw()
    obs.throttled_no_attempt = attempts[path2] == before
    love._test.advance(0.6)
    node2:draw()
    obs.retry_after_interval = attempts[path2] > before
    obs.still_blank_under_failure = node2.front_sprite == nil or node2.front_sprite.image == nil
    failing[path2] = nil
    love._test.advance(0.6)
    node2:draw()
    obs.recovered_again = node2.front_sprite ~= nil and node2.front_sprite.image ~= nil

    -- Vanilla gate: freed and failed once, then loads would succeed -- but a
    -- vanilla node must not load at draw time at all (pre-fix behaviour).
    failing[vpath] = true
    game:unload_joker_sprite(vkey)
    vanilla_node:refresh_quads()
    obs.vanilla_blanked = vanilla_node.front_sprite == nil or vanilla_node.front_sprite.image == nil
    failing[vpath] = nil
    local vbefore = attempts[vpath]
    love._test.advance(1)
    vanilla_node:draw()
    obs.vanilla_no_draw_attempt = attempts[vpath] == vbefore
    obs.vanilla_still_blank = vanilla_node.front_sprite == nil or vanilla_node.front_sprite.image == nil
    vanilla_node:refresh_quads() -- an explicit refresh still resolves it
    obs.vanilla_refresh_recovers = vanilla_node.front_sprite ~= nil
        and vanilla_node.front_sprite.image ~= nil

    love.graphics.newImage = real_new_image

    T.assert_true(obs.added, "second joker added")
    T.assert_true(obs.blank_at_construct, "failed build leaves the node blank (the reported symptom)")
    T.assert_true(obs.load_error_at_construct, "the failure is recorded on the sprite entry")
    T.assert_true(obs.recovered_on_draw, "the node recovers once the sprite can build and it draws")
    T.assert_true(obs.load_error_cleared, "recovery clears the recorded error")
    T.assert_true(obs.blanked_again, "setup: node blanked again under failure")
    T.assert_true(obs.throttled_no_attempt, "draws inside the throttle window do not retry the build")
    T.assert_true(obs.retry_after_interval, "a draw after the throttle interval retries")
    T.assert_true(obs.still_blank_under_failure, "a failed retry leaves the node blank, not broken")
    T.assert_true(obs.recovered_again, "and it recovers when the failure clears")
    T.assert_true(obs.vanilla_blanked, "setup: vanilla node blanked by the same failure")
    T.assert_true(obs.vanilla_no_draw_attempt, "vanilla nodes never load at draw time (gate holds)")
    T.assert_true(obs.vanilla_still_blank, "vanilla behaviour is unchanged by the fix")
    T.assert_true(obs.vanilla_refresh_recovers, "an explicit refresh still resolves a vanilla sprite")
    wipe_mods()
end)

return suite
