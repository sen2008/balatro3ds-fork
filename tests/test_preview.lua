--- Balatro Preview (Top-10 Wave 2): the snapshot-sandboxed score preview.
---
--- The claims under test are the feature's whole contract: (1) the preview equals
--- the score the real play produces afterwards -- including Lucky/Glass rolls,
--- because the snapshot rewinds the RNG streams the simulation consumed; (2) the
--- simulation leaves the run and the profile exactly as it found them; (3) the
--- result is cached by selection signature; (4) the guards refuse cleanly.
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

bootstrap.load()

local function hand_of(g, cards)
    local want = #cards
    local hand = Hand(g)
    g.hand = hand
    g.deck = Deck()
    g.deck.cards = cards
    hand:fill_from_deck()
    for _ = 1, 200 do
        hand:update(0.1)
        if #hand.card_nodes >= want then break end
    end
    return hand
end

local function scenario(seed, cards, jokers, opts)
    opts = opts or {}
    _G.Top = { addPopup = function() end }
    local g = bootstrap.new_game(seed)
    g.STATE = g.STATES.SELECTING_HAND
    g.hands, g.discards = 4, 3
    if opts.money then g.money = opts.money end
    if opts.deck_special then g._deck_special = opts.deck_special end
    if opts.challenge then g.challenge_modifiers = opts.challenge end
    for _, j in ipairs(jokers or {}) do
        if type(j) == "table" then
            T.assert_true(g:add_joker_by_def(j.id, { edition = j.edition }) and true or false, j.id)
        else
            T.assert_true(g:add_joker_by_def(j) and true or false, j)
        end
    end
    local hand = hand_of(g, cards)
    g.SETTINGS.PREVIEW_SCORE = true
    return g, hand
end

local function C(rank, suit, extra)
    local c = { rank = rank, suit = suit }
    if extra then for k, v in pairs(extra) do c[k] = v end end
    return c
end

local function select_specs(hand, specs)
    for _, s in ipairs(specs) do
        local found = false
        for _, node in ipairs(hand.card_nodes) do
            local d = node.card_data or {}
            local rank_ok = s[1] == nil or d.rank == s[1]
            local suit_ok = s[2] == nil or d.suit == s[2]
            local enh_ok = s[3] == nil or d.enhancement == s[3]
            if rank_ok and suit_ok and enh_ok and not node.selected then
                hand:toggle_selection(node)
                found = true
                break
            end
        end
        T.assert_true(found, "dealt card present: " .. tostring(s[1]) .. " of " .. tostring(s[2]))
    end
end

local function play_for_real(g, hand)
    hand:play_selected()
    T.assert_true(hand._play_sequence ~= nil, "the real play sequence started")
    for _ = 1, 20000 do
        hand:update(1 / 60)
        g:update(1 / 60)
        if not hand._play_sequence then break end
    end
    T.assert_true(hand._play_sequence == nil, "the real play sequence finished")
    return g.last_hand_score
end

--- Preview, assert it, then play for real and assert the same number lands.
local function preview_then_play(seed, cards, jokers, specs, opts)
    local g, hand = scenario(seed, cards, jokers, opts)
    select_specs(hand, specs)
    local preview = g:score_preview()
    T.assert_not_nil(preview, "preview produced a value")
    T.assert_nil(g._preview_error, "no sim error: " .. tostring(g._preview_error))
    local actual = play_for_real(g, hand)
    T.assert_eq(actual, preview, "the real play lands exactly on the preview")
    return g, hand, preview
end

suite.test("preview equals the real score: plain hand with a Mult Joker", function()
    local _, _, preview = preview_then_play(9201, {
        C(14, "Spades"), C(5, "Hearts"), C(9, "Clubs"), C(3, "Diamonds"), C(7, "Spades"),
        C(2, "Hearts"), C(11, "Clubs"), C(4, "Diamonds"),
    }, { "j_joker" }, { { 14, "Spades" } })
    T.assert_eq(preview, 80, "matches the equivalence battery's golden")
end)

suite.test("preview equals the real score: Lucky and Glass rolls included", function()
    local _, _, preview = preview_then_play(9203, {
        C(10, "Hearts", { enhancement = "bonus" }),
        C(11, "Hearts", { enhancement = "mult" }),
        C(12, "Hearts", { enhancement = "glass" }),
        C(13, "Hearts", { enhancement = "lucky" }),
        C(2, "Hearts", { enhancement = "stone" }),
        C(4, "Clubs"), C(6, "Diamonds"), C(8, "Spades"),
    }, { "j_joker", "j_lusty_joker" }, {
        { 10, "Hearts" }, { 11, "Hearts" }, { 12, "Hearts" }, { 13, "Hearts" }, { nil, nil, "stone" } })
    T.assert_eq(preview, 1820, "matches the equivalence battery's golden")
end)

suite.test("preview equals the real score: X-mult chain", function()
    local _, _, preview = preview_then_play(9204, {
        C(12, "Spades"), C(12, "Hearts"), C(4, "Clubs"), C(4, "Diamonds"), C(14, "Spades"),
        C(3, "Hearts"), C(6, "Clubs"), C(9, "Diamonds"),
    }, { "j_cavendish", "j_duo", "j_trio", "j_blackboard" }, {
        { 12, "Spades" }, { 12, "Hearts" }, { 4, "Clubs" }, { 4, "Diamonds" }, { 14, "Spades" } })
    T.assert_eq(preview, 576, "matches the equivalence battery's golden")
end)

suite.test("the simulation leaves run, RNG and profile untouched", function()
    local g, hand = scenario(9210, {
        C(10, "Hearts", { enhancement = "bonus" }),
        C(12, "Hearts", { enhancement = "glass" }),
        C(13, "Hearts", { enhancement = "lucky" }),
        C(9, "Clubs"), C(9, "Diamonds"), C(4, "Clubs"), C(6, "Diamonds"), C(8, "Spades"),
    }, { "j_joker", "j_lusty_joker" }, { money = 25 })
    select_specs(hand, { { 9, "Clubs" }, { 9, "Diamonds" } })

    local run_before = g:build_run_snapshot()
    local career_before = g.career_stats or {}
    local discovered_before = g.Discovered or {}
    local money_before, sel_before = g.money, #hand.selected
    local glass_before = 0
    for _, n in ipairs(hand.card_nodes) do
        if (n.card_data or {}).enhancement == "glass" then glass_before = glass_before + 1 end
    end

    local preview = g:score_preview()
    T.assert_not_nil(preview)
    T.assert_nil(g._preview_error, "no sim error: " .. tostring(g._preview_error))

    T.assert_deep_eq(g:build_run_snapshot(), run_before,
        "run snapshot identical after the sim (RNG streams included)")
    T.assert_deep_eq(g.career_stats or {}, career_before, "no career stats earned")
    T.assert_deep_eq(g.Discovered or {}, discovered_before, "nothing discovered")
    T.assert_eq(g.money, money_before, "money unmoved")
    T.assert_eq(#hand.selected, sel_before, "selection restored")
    local glass_after = 0
    for _, n in ipairs(hand.card_nodes) do
        if (n.card_data or {}).enhancement == "glass" then glass_after = glass_after + 1 end
    end
    T.assert_eq(glass_after, glass_before, "a Glass card the sim may have broken is whole again")
    T.assert_true(not g._simulating, "sim flag cleared")
    T.assert_nil(g.chip_total_display, "no phantom landed total left for the readout")
end)

suite.test("the preview is cached by selection signature", function()
    local g, hand = scenario(9211, {
        C(14, "Spades"), C(5, "Hearts"), C(9, "Clubs"), C(3, "Diamonds"), C(7, "Spades"),
        C(2, "Hearts"), C(11, "Clubs"), C(4, "Diamonds"),
    }, { "j_joker" })
    select_specs(hand, { { 14, "Spades" } })
    local sims = 0
    local real_sim = g.simulate_selected_play
    g.simulate_selected_play = function(self, ...)
        sims = sims + 1
        return real_sim(self, ...)
    end
    local first = g:score_preview()
    local second = g:score_preview()
    T.assert_eq(second, first, "same selection, same preview")
    T.assert_eq(sims, 1, "one simulation for two reads")
    select_specs(hand, { { 5, "Hearts" } })
    local third = g:score_preview()
    T.assert_eq(sims, 2, "a changed selection re-simulates")
    T.assert_not_nil(third)
end)

suite.test("preview guards: off, nothing selected, hidden hand", function()
    local g, hand = scenario(9212, {
        C(14, "Spades"), C(5, "Hearts"), C(9, "Clubs"), C(3, "Diamonds"), C(7, "Spades"),
        C(2, "Hearts"), C(11, "Clubs"), C(4, "Diamonds"),
    }, { "j_joker" })
    T.assert_nil(g:score_preview(), "nothing selected, no preview")
    select_specs(hand, { { 14, "Spades" } })
    g.SETTINGS.PREVIEW_SCORE = false
    T.assert_nil(g:score_preview(), "toggle off, no preview")
    g.SETTINGS.PREVIEW_SCORE = true
    T.assert_not_nil(g:score_preview(), "toggle on, preview back")
    g.selectedHandHidden = true
    T.assert_nil(g:score_preview(), "a hidden hand keeps its score hidden")
    g.selectedHandHidden = false
end)

return suite
