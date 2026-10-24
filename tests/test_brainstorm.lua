--- Brainstorm (Top-10 Wave 2): named snapshot slots, same-seed restart, fast reroll.
---
--- Slots are the run snapshot machinery with a parameterized path; the tests lean on
--- the same in-memory filesystem as test_save_load.lua. Restart and reroll tests use
--- two identically-seeded games so equivalence is asserted, not assumed.
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

bootstrap.load()
local ScreenWipe = require("screen_wipe")

local function offer_signature(game)
    local parts = {}
    for _, o in ipairs(game.shop_offers or {}) do
        parts[#parts + 1] = tostring(o.kind) .. ":" .. tostring(o.id)
    end
    return table.concat(parts, ",")
end

local function deck_signature(game)
    local parts = {}
    for i, c in ipairs(game.deck.cards or {}) do
        parts[i] = tostring(c.rank) .. tostring(c.suit):sub(1, 1)
    end
    return table.concat(parts, ",")
end

suite.test("a slot round-trips a mid-run state and leaves other slots empty", function()
    local g = bootstrap.new_game(8101)
    g._pending_run_seed = "SLOTSMOKE"
    g:start_run_from_main_menu()
    T.assert_eq(g.STAGE, g.STAGES.RUN, "run is live")
    T.assert_true(g:add_joker_by_def("j_joker"))
    g.money = 42
    g.ante = 3

    local ok, err = g:save_run_slot(1)
    T.assert_true(ok, "slot save failed: " .. tostring(err))
    local info = g:run_slot_info(1)
    T.assert_not_nil(info, "slot 1 has a summary")
    T.assert_eq(info.money, 42)
    T.assert_eq(info.ante, 3)
    T.assert_nil(g:run_slot_info(2), "slot 2 untouched")

    -- Trash the live run, then restore.
    g.money = 7
    g.ante = 1
    g:remove_owned_joker_at(1, true)
    T.assert_eq(#g.jokers, 0)
    local lok, lerr = g:load_run_slot(1)
    T.assert_true(lok, "slot load failed: " .. tostring(lerr))
    T.assert_eq(g.money, 42, "money restored")
    T.assert_eq(g.ante, 3, "ante restored")
    T.assert_eq(#g.jokers, 1, "joker restored")
    T.assert_eq(g.jokers[1].def.id, "j_joker")
end)

suite.test("slot save and load refuse while a hand is scoring", function()
    local g = bootstrap.new_game(8102)
    g._pending_run_seed = "SLOTGATE"
    g:start_run_from_main_menu()
    T.assert_true((g:save_run_slot(1)))
    g.is_hand_scoring_active = function() return true end
    local ok, err = g:save_run_slot(2)
    T.assert_eq(ok, false, "save blocked")
    T.assert_eq(err, "scoring")
    local lok, lerr = g:load_run_slot(1)
    T.assert_eq(lok, false, "load blocked")
    T.assert_eq(lerr, "scoring")
    T.assert_nil(g:run_slot_info(2), "nothing was written")
end)

suite.test("restart with the same seed reproduces the fresh run's opening", function()
    local seed = "BRNSTRM1"
    local fresh = bootstrap.new_game(8103)
    fresh._pending_run_seed = seed
    fresh:start_run_from_main_menu()
    local want_deck = deck_signature(fresh)
    local want_boss = fresh.current_boss_blind_id
    local want_offer = fresh:_generate_next_shop_queue_offer()
    want_offer = want_offer and want_offer.id

    local g = bootstrap.new_game(8104)
    g._pending_run_seed = seed
    g:start_run_from_main_menu()
    g.money = 99 -- spend the run somewhere else entirely
    g.ante = 4
    T.assert_true(g:restart_run_with_same_seed(), "restart accepted")
    -- The restart rides the screen wipe; step it through like a frame loop would.
    for _ = 1, 60 do
        if not ScreenWipe.active(g) then break end
        g:update(1 / 60, 1 / 60)
    end
    T.assert_true(not ScreenWipe.active(g), "wipe finished")
    T.assert_eq(g.SEED, seed, "same seed identity")
    T.assert_true(g.seeded == true, "a restarted run counts as seeded")
    T.assert_eq(g.ante, 1, "back to ante 1")
    T.assert_eq(deck_signature(g), want_deck, "same shuffled deck")
    T.assert_eq(g.current_boss_blind_id, want_boss, "same boss")
    local offer = g:_generate_next_shop_queue_offer()
    T.assert_eq(offer and offer.id, want_offer, "same first shop offer")
end)

suite.test("fast rerolls land exactly where manual rerolls land", function()
    local function shop_game(seed)
        local g = bootstrap.new_game(seed)
        g.STATE = g.STATES.SHOP
        g.money = 500
        g.shop_reroll_count = 0
        g:roll_shop_offers()
        return g
    end
    local a = shop_game(8105)
    local b = shop_game(8105)
    T.assert_eq(offer_signature(a), offer_signature(b), "same opening shelf")
    for _ = 1, 5 do T.assert_true(a:reroll_shop_offers()) end
    for _ = 1, 5 do T.assert_true(b:reroll_shop_offers({ fast = true })) end
    T.assert_eq(offer_signature(b), offer_signature(a), "same shelf after five rerolls")
    T.assert_eq(b.money, a.money, "same money spent")
    T.assert_eq(b.shop_reroll_count, a.shop_reroll_count, "same reroll count")

    -- The fast path tolerates the entry slide the manual path refuses.
    b._shop_slide = {}
    T.assert_eq(b:reroll_shop_offers(), false, "manual reroll refuses mid-slide")
    T.assert_true(b:reroll_shop_offers({ fast = true }), "fast reroll rides through")
    b._shop_slide = nil
end)

suite.test("holding reroll repeats on the fast path and stops when broke", function()
    local g = bootstrap.new_game(8106)
    g.STATE = g.STATES.SHOP
    g.money = 60
    g.shop_reroll_count = 0
    g:roll_shop_offers()
    g._shop_reroll_held = function() return true end

    for _ = 1, 3 do g:update_shop_reroll_hold(0.1) end
    T.assert_eq(g.shop_reroll_count, 0, "no repeats inside the hold delay")
    for _ = 1, 20 do g:update_shop_reroll_hold(0.1) end
    T.assert_true(g.shop_reroll_count >= 3, "repeats fired while held")
    local spent_at = g.money

    -- Broke: repeats stop and stay stopped until the button is released.
    g.money = 0
    for _ = 1, 10 do g:update_shop_reroll_hold(0.1) end
    local count_broke = g.shop_reroll_count
    g.money = 60
    for _ = 1, 10 do g:update_shop_reroll_hold(0.1) end
    T.assert_eq(g.shop_reroll_count, count_broke, "no resume until release")
    T.assert_true(spent_at < 60, "money was spent by the repeats")

    g._shop_reroll_held = function() return false end
    g:update_shop_reroll_hold(0.1)
    g._shop_reroll_held = function() return true end
    for _ = 1, 10 do g:update_shop_reroll_hold(0.1) end
    T.assert_true(g.shop_reroll_count > count_broke, "a fresh hold rerolls again")
end)

suite.test("the pause menu reaches the save-states page and its actions", function()
    local g = bootstrap.new_game(8107)
    g._pending_run_seed = "SLOTMENU"
    g:start_run_from_main_menu()
    g.STATE = g.STATES.PAUSED
    g._pause_show_settings = false
    g:draw_bottom_pause()
    T.assert_not_nil(g._pause_slots_rect, "main page has the Save States button")

    local function focus_index_of(kind, index)
        for i, t in ipairs(g:build_pause_focus_targets()) do
            if t.kind == kind and (index == nil or t.index == index) then return i end
        end
        return nil
    end
    g._pause_focus_index = focus_index_of("slots_open")
    T.assert_true(g:activate_pause_focus(), "Save States opens")
    T.assert_eq(g._pause_settings_tab, "slots")
    g:draw_bottom_pause()
    T.assert_not_nil(g._pause_slot_save_rects[1], "slot rows drawn")

    g.money = 33
    g._pause_focus_index = focus_index_of("slot_save", 1)
    T.assert_true(g:activate_pause_focus(), "slot save activates")
    T.assert_not_nil(g:run_slot_info(1), "slot written from the menu")
    T.assert_eq(g:run_slot_info(1).money, 33)

    g:draw_bottom_pause()
    T.assert_not_nil(focus_index_of("slot_load", 1), "a filled slot offers a load target")
end)

return suite
