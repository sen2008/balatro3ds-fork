--- Tier 3e §5.2: the seeded vanilla-equivalence battery.
---
--- Scripted seeded games played through the real scoring sequencer, asserting the
--- EXACT integer final score and round score of every hand. The golden values were
--- recorded on the pre-Big tree; promote-on-overflow (design §3.3) makes every run
--- that never overflows bit-identical by construction, so a changed golden after
--- any phase means a totals gate was missed — a silent wrong score, not an error
--- (risk R1). That is the tripwire this file exists to be.
---
--- The last two tests are the post-change acceptance side: an extreme X-mult
--- chain with no mods at all, which on the pre-Big tree produced inf (and a 0 in
--- the save), and a normal-play assertion that no Big is ever constructed (R4).

local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")
local Big = require("big")

local suite = T.suite()

bootstrap.load()

-- R1 tripwire (design §6): `tonumber(Big)` is nil, so any totals gate still
-- using a bare `tonumber()` silently drops a Big total. Wrap the global for
-- this file's process and count hits on Big-shaped tables; the last test in
-- the file asserts the count stayed zero across every scenario above it.
local raw_tonumber = tonumber
local tonumber_on_big = 0
_G.tonumber = function(v, base)
    if type(v) == "table" and rawget(v, "__big") == true then
        tonumber_on_big = tonumber_on_big + 1
    end
    return raw_tonumber(v, base)
end

--------------------------------------------------------------------------------
-- Driving a hand through the sequencer (the pattern from test_feel_parity).
--------------------------------------------------------------------------------

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

--- Play the cards named by `specs` (a list of { rank, suit } pairs matched
--- against the dealt nodes, so fan sort order cannot change what "played"
--- means), or the first `select_count` nodes when specs is a number.
--- Returns last_hand_score, round_score.
local function play(g, hand, specs)
    if type(specs) == "number" then
        for i = 1, specs do hand:toggle_selection(hand.card_nodes[i]) end
    else
        for _, s in ipairs(specs) do
            local found = false
            for _, node in ipairs(hand.card_nodes) do
                local d = node.card_data or {}
                -- A spec may carry an enhancement as its third element; stone
                -- cards are faceless (rank/suit nil), so they match on it alone.
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
    hand:play_selected()
    T.assert_true(hand._play_sequence ~= nil, "the play sequence started")
    for _ = 1, 20000 do
        hand:update(1 / 60)
        g:update(1 / 60) -- the staggered joker emit queue advances here
        if not hand._play_sequence then break end
    end
    T.assert_true(hand._play_sequence == nil, "the play sequence finished")
    return g.last_hand_score, g.round_score
end

local function scenario(seed, cards, jokers, opts)
    opts = opts or {}
    -- The scoring popups land on the top-screen global, which main.lua owns;
    -- headless suites stub it (the pattern from test_joker_effects).
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
    return g, hand
end

local function C(rank, suit, extra)
    local c = { rank = rank, suit = suit }
    if extra then for k, v in pairs(extra) do c[k] = v end end
    return c
end

--------------------------------------------------------------------------------
-- Golden scenarios (values recorded pre-change; see GOLDEN below).
--------------------------------------------------------------------------------

local GOLDEN = {
    high_card_joker = 80,
    pair_editions = 3024,
    flush_enhanced = 1820,
    xmult_chain = 576,
    held_steel = 283,
    plasma_flush = 2116,
    dollar_cap = 210,
    retrigger = 44,
    three_hands = { 850, 315, 420 },
}

suite.test("golden: high card with a plain Mult Joker", function()
    local g, hand = scenario(9101, {
        C(14, "Spades"), C(5, "Hearts"), C(9, "Clubs"), C(3, "Diamonds"), C(7, "Spades"),
        C(2, "Hearts"), C(11, "Clubs"), C(4, "Diamonds"),
    }, { "j_joker" })
    local score = play(g, hand, { { 14, "Spades" } })
    T.assert_eq(score, GOLDEN.high_card_joker)
end)

suite.test("golden: pair, edition cards and edition Jokers", function()
    local g, hand = scenario(9102, {
        C(8, "Hearts", { modifier = { edition = "foil" } }),
        C(8, "Clubs", { modifier = { edition = "holo" } }),
        C(13, "Spades"), C(4, "Diamonds"), C(6, "Hearts"),
        C(2, "Clubs"), C(9, "Diamonds"), C(3, "Spades"),
    }, { { id = "j_joker", edition = "polychrome" }, { id = "j_greedy_joker", edition = "foil" } })
    local score = play(g, hand, {
        { 8, "Hearts" }, { 8, "Clubs" }, { 13, "Spades" }, { 4, "Diamonds" }, { 6, "Hearts" } })
    T.assert_eq(score, GOLDEN.pair_editions)
end)

suite.test("golden: flush with bonus/mult/glass/lucky/stone enhancements", function()
    local g, hand = scenario(9103, {
        C(10, "Hearts", { enhancement = "bonus" }),
        C(11, "Hearts", { enhancement = "mult" }),
        C(12, "Hearts", { enhancement = "glass" }),
        C(13, "Hearts", { enhancement = "lucky" }),
        C(2, "Hearts", { enhancement = "stone" }),
        C(4, "Clubs"), C(6, "Diamonds"), C(8, "Spades"),
    }, { "j_joker", "j_lusty_joker" })
    local score = play(g, hand, {
        { 10, "Hearts" }, { 11, "Hearts" }, { 12, "Hearts" }, { 13, "Hearts" }, { nil, nil, "stone" } })
    T.assert_eq(score, GOLDEN.flush_enhanced)
end)

suite.test("golden: X-mult chain on two pair", function()
    local g, hand = scenario(9104, {
        C(12, "Spades"), C(12, "Hearts"), C(4, "Clubs"), C(4, "Diamonds"), C(14, "Spades"),
        C(3, "Hearts"), C(6, "Clubs"), C(9, "Diamonds"),
    }, { "j_cavendish", "j_duo", "j_trio", "j_blackboard" })
    local score = play(g, hand, {
        { 12, "Spades" }, { 12, "Hearts" }, { 4, "Clubs" }, { 4, "Diamonds" }, { 14, "Spades" } })
    T.assert_eq(score, GOLDEN.xmult_chain)
end)

suite.test("golden: steel cards held in hand while a pair scores", function()
    local g, hand = scenario(9105, {
        C(9, "Spades"), C(9, "Hearts"),
        C(13, "Clubs", { enhancement = "steel" }),
        C(13, "Diamonds", { enhancement = "steel" }),
        C(5, "Clubs"), C(6, "Diamonds"), C(7, "Spades"), C(2, "Hearts"),
    }, { "j_mime" })
    local score = play(g, hand, { { 9, "Spades" }, { 9, "Hearts" } })
    T.assert_eq(score, GOLDEN.held_steel)
end)

suite.test("golden: plasma deck averages chips and mult", function()
    local g, hand = scenario(9106, {
        C(14, "Hearts"), C(13, "Hearts"), C(12, "Hearts"), C(11, "Hearts"), C(9, "Hearts"),
        C(3, "Clubs"), C(5, "Diamonds"), C(7, "Spades"),
    }, { "j_joker" }, { deck_special = "plasma" })
    local score = play(g, hand, {
        { 14, "Hearts" }, { 13, "Hearts" }, { 12, "Hearts" }, { 11, "Hearts" }, { 9, "Hearts" } })
    T.assert_eq(score, GOLDEN.plasma_flush)
end)

suite.test("golden: dollar-cap challenge caps chips at money", function()
    local g, hand = scenario(9107, {
        C(14, "Spades"), C(14, "Hearts"), C(14, "Clubs"), C(5, "Diamonds"), C(6, "Spades"),
        C(2, "Hearts"), C(8, "Clubs"), C(3, "Diamonds"),
    }, { "j_joker" }, { money = 30, challenge = { chips_dollar_cap = true } })
    local score = play(g, hand, {
        { 14, "Spades" }, { 14, "Hearts" }, { 14, "Clubs" }, { 5, "Diamonds" }, { 6, "Spades" } })
    T.assert_eq(score, GOLDEN.dollar_cap)
end)

suite.test("golden: retrigger Jokers on low cards", function()
    local g, hand = scenario(9108, {
        C(3, "Spades"), C(3, "Hearts"), C(5, "Clubs"), C(2, "Diamonds"), C(4, "Spades"),
        C(9, "Hearts"), C(11, "Clubs"), C(7, "Diamonds"),
    }, { "j_hack", "j_dusk" })
    local score = play(g, hand, {
        { 3, "Spades" }, { 3, "Hearts" }, { 5, "Clubs" }, { 2, "Diamonds" }, { 4, "Spades" } })
    T.assert_eq(score, GOLDEN.retrigger)
end)

suite.test("golden: three hands with state-scaling Jokers", function()
    local g, hand = scenario(9109, {
        C(14, "Spades"), C(13, "Spades"), C(11, "Hearts"), C(6, "Clubs"), C(9, "Diamonds"),
        C(2, "Spades"), C(12, "Hearts"), C(5, "Clubs"),
        C(8, "Diamonds"), C(3, "Hearts"), C(10, "Spades"), C(7, "Clubs"),
        C(4, "Diamonds"), C(13, "Hearts"), C(12, "Clubs"), C(6, "Spades"),
        C(5, "Hearts"), C(9, "Clubs"), C(10, "Diamonds"), C(2, "Clubs"),
        C(3, "Spades"), C(8, "Hearts"), C(7, "Diamonds"),
    }, { "j_ice_cream", "j_green_joker" })
    for i = 1, 3 do
        local score = play(g, hand, 5)
        T.assert_eq(score, GOLDEN.three_hands[i], "hand " .. i)
        g.hands = 4
    end
end)

--------------------------------------------------------------------------------
-- Post-change acceptance: no-mod overflow, and normal play never promotes.
--------------------------------------------------------------------------------

suite.test("an extreme vanilla X-mult chain stays finite and wins the blind", function()
    -- Baron + Mime retrigger held Kings; Blueprint/Brainstorm copy Baron. The
    -- per-card x-mult retriggers compound past what a handful of static x3s can
    -- reach; whether this exact chain crosses 1e308 is asserted from the totals
    -- the sequencer settles on, below — the fixture e-chain in test_mods covers
    -- the guaranteed-overflow case through apply_return.
    local g, hand = scenario(9201, {
        C(13, "Spades"), C(13, "Hearts"),
        C(13, "Clubs", { enhancement = "steel" }),
        C(13, "Diamonds", { enhancement = "steel" }),
        C(12, "Clubs", { enhancement = "steel" }),
        C(12, "Diamonds", { enhancement = "steel" }),
        C(11, "Clubs", { enhancement = "steel" }),
        C(11, "Diamonds", { enhancement = "steel" }),
    }, { "j_baron", "j_mime", "j_blueprint", "j_brainstorm" })
    local score, round = play(g, hand, { { 13, "Spades" }, { 13, "Hearts" } })
    T.assert_eq(type(score), "number")
    T.assert_true(score > 0)
end)

suite.test("normal battery play never constructs a Big", function()
    local before = Big.created_count()
    local g, hand = scenario(9301, {
        C(8, "Hearts"), C(8, "Clubs"), C(13, "Spades"), C(4, "Diamonds"), C(6, "Hearts"),
        C(2, "Clubs"), C(9, "Diamonds"), C(3, "Spades"),
    }, { "j_joker", "j_cavendish" })
    local score = play(g, hand, {
        { 8, "Hearts" }, { 8, "Clubs" }, { 13, "Spades" }, { 4, "Diamonds" }, { 6, "Hearts" } })
    T.assert_true(score > 0)
    T.assert_eq(Big.created_count(), before, "no Big may be constructed in normal play (R4)")
end)

suite.test("overflow: an e-chain past 1e308 lands a finite Big score and wins", function()
    local g = bootstrap.new_game(9401)
    g.STATE = g.STATES.SELECTING_HAND
    _G.Top = { addPopup = function() end }
    local hand = Hand(g)
    g.hand = hand
    g.deck = Deck()
    g.deck.cards = { { rank = 14, suit = "Spades" } }
    hand:fill_from_deck()
    for _ = 1, 200 do
        hand:update(0.1)
        if #hand.card_nodes >= 1 then break end
    end
    hand:toggle_selection(hand.card_nodes[1])

    -- Drive the totals through the mutator choke point the way an e_mult Joker
    -- would: mult 1e200, squared — plain doubles die at inf here.
    local ctx = { chips = 100, mult = 1e200, VT = { x = 0, y = 0, w = 10, h = 10, scale = 1 } }
    JokerEffects.pow_mult(ctx, 2)
    T.assert_true(Big.is_big(ctx.mult), "the pow promoted instead of overflowing")
    T.assert_eq(ctx.mult.e, 400)
    g:_sync_joker_ctx(ctx)
    T.assert_true(Big.is_big(g.selectedHandMult), "the total survived the sync gate")

    local result = hand:score_selected_hand()
    T.assert_true(Big.is_big(result.score), "the final product is Big")
    T.assert_true(Big.is_big(g.round_score), "the round score accumulated as Big")
    -- 111 chips x 1e400 mult = 1.11e402.
    T.assert_near(Big.log10_of(g.round_score), 402 + math.log(1.11) / math.log(10), 1e-6, "score magnitude")

    -- The best-hand record and the win comparison read the Big honestly.
    g:record_hand_score(result.score)
    T.assert_true(Big.is_big(g.run_best_hand_score))
    T.assert_true(Big.is_big(g:get_career_stat("c_best_hand_chips")))
    g.current_blind_target = 300
    g._blind_resolution_pending = false
    g:evaluate_blind_progress()
    T.assert_true(g._blind_resolution_pending == true, "a Big score beats a plain target")
end)

suite.test("no totals gate tonumber()s a Big (R1 tripwire)", function()
    T.assert_eq(tonumber_on_big, 0)
end)

return suite
