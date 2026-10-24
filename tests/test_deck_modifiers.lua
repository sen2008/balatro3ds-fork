--- A deck's modifiers belong to the run it started. Starting the next run on another deck, or
--- loading a save made on one, must not inherit whatever the previous deck switched on.

local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

---@return table snapshot of every lasting deck modifier on `game`
local function modifiers(game)
    return {
        hands = game:get_effective_hands_per_round(),
        discards = game:get_effective_discards_per_round(),
        hand_size = game:get_effective_hand_size_limit(),
        jokers = game:joker_base_capacity(),
        consumables = game:get_effective_consumable_capacity(),
        no_interest = game._deck_no_interest == true,
        hand_bonus = tonumber(game.extra_hand_bonus) or 0,
        discard_bonus = tonumber(game.extra_discard_bonus) or 0,
        spectral_rate = tonumber(game.deck_spectral_rate) or 0,
        special = game._deck_special or "none",
    }
end

local function assert_same(actual, expected, label)
    for k, v in pairs(expected) do
        T.assert_eq(actual[k], v, label .. " " .. k)
    end
end

suite.test("every deck leaves the next run's deck as if it were the first", function()
    local fresh = bootstrap.new_game(11)
    fresh:apply_deck_config("b_red")
    local red = modifiers(fresh)

    for _, def in ipairs(DECK_DEFS) do
        local game = bootstrap.new_game(12)
        game:apply_deck_config(def.id)
        -- The run start clears vouchers before applying the next deck; start vouchers are not
        -- what this checks.
        game.vouchers = {}
        game:apply_deck_config("b_red")
        assert_same(modifiers(game), red, "red after " .. def.id)
    end
end)

suite.test("loading a save restores that run's deck modifiers", function()
    local game = bootstrap.new_game(13)
    game:apply_deck_config("b_green")
    local green = modifiers(game)

    game:apply_deck_config("b_painted")
    game:restore_run_deck_stake_from_snapshot({ selected_deck_id = "b_green" })
    assert_same(modifiers(game), green, "green restored over painted")
end)

--------------------------------------------------------------------------------
-- CardSleeves (Wave 2): a sleeve deck merges over the primary.
--------------------------------------------------------------------------------

---@return table snapshot of the raw lasting modifier fields on `game`
local function raw_fields(game)
    return {
        hands = tonumber(game.deck_hands) or 0,
        discards = tonumber(game.deck_discards) or 0,
        hand_bonus = tonumber(game.extra_hand_bonus) or 0,
        discard_bonus = tonumber(game.extra_discard_bonus) or 0,
        hand_size = tonumber(game.deck_hand_size) or 0,
        consumables = tonumber(game.deck_consumable_slots) or 0,
        jokers = tonumber(game.deck_joker_slots) or 0,
        spectral = tonumber(game.deck_spectral_rate) or 0,
        no_interest = game._deck_no_interest == true,
        special = game._deck_special,
        special_sleeve = game._deck_special_sleeve,
    }
end

local function cfg_of(id) return DECK_DEFS_BY_ID[id].config or {} end

--- The merge rules applied to the catalog by hand: numerics add, the flag ORs,
--- specials take their own slots and collapse when identical.
local function expected_merge(primary_id, sleeve_id)
    local a, b = cfg_of(primary_id), sleeve_id and cfg_of(sleeve_id) or {}
    local pa = DECK_DEFS_BY_ID[primary_id].special
    local pb = sleeve_id and DECK_DEFS_BY_ID[sleeve_id].special or nil
    return {
        hands = (tonumber(a.hands) or 0) + (tonumber(b.hands) or 0),
        discards = (tonumber(a.discards) or 0) + (tonumber(b.discards) or 0),
        hand_bonus = (tonumber(a.extra_hand_bonus) or 0) + (tonumber(b.extra_hand_bonus) or 0),
        discard_bonus = (tonumber(a.extra_discard_bonus) or 0) + (tonumber(b.extra_discard_bonus) or 0),
        hand_size = (tonumber(a.hand_size) or 0) + (tonumber(b.hand_size) or 0),
        consumables = (tonumber(a.consumable_slots) or 0) + (tonumber(b.consumable_slots) or 0),
        jokers = (tonumber(a.joker_slots) or 0) + (tonumber(b.joker_slots) or 0),
        spectral = (tonumber(a.spectral_rate) or 0) + (tonumber(b.spectral_rate) or 0),
        no_interest = a.no_interest == true or b.no_interest == true,
        special = pa,
        special_sleeve = (pb and pb ~= pa) and pb or nil,
    }
end

suite.test("every deck pair merges by the sleeve rules (16x16)", function()
    local game = bootstrap.new_game(21)
    for _, primary in ipairs(DECK_DEFS) do
        for _, sleeve in ipairs(DECK_DEFS) do
            game:apply_deck_config(primary.id, sleeve.id)
            local sleeve_arg = sleeve.id
            if sleeve_arg == primary.id then sleeve_arg = nil end -- the pair collapses
            local want = expected_merge(primary.id, sleeve_arg)
            local got = raw_fields(game)
            for k, v in pairs(want) do
                T.assert_eq(got[k], v, primary.id .. " + " .. sleeve.id .. " " .. k)
            end
            T.assert_eq(game.selected_deck_id, primary.id, "the primary owns the run")
            if sleeve.id ~= primary.id then
                T.assert_eq(game.selected_sleeve_id, sleeve.id, "the sleeve is tracked")
            else
                T.assert_nil(game.selected_sleeve_id, "a deck cannot sleeve itself")
            end
        end
    end
end)

suite.test("no sleeve is the old behavior, field for field", function()
    local game = bootstrap.new_game(22)
    for _, def in ipairs(DECK_DEFS) do
        game:apply_deck_config(def.id)
        local want = expected_merge(def.id, nil)
        local got = raw_fields(game)
        for k, v in pairs(want) do
            T.assert_eq(got[k], v, def.id .. " unsleeved " .. k)
        end
        T.assert_nil(game.selected_sleeve_id)
    end
end)

suite.test("the content transform comes from the primary, else the sleeve", function()
    local function fired_transform(primary_id, sleeve_id)
        local game = bootstrap.new_game(23)
        local fired = {}
        game._apply_erratic_deck = function() fired[#fired + 1] = "erratic" end
        game._apply_no_face_cards = function() fired[#fired + 1] = "no_face" end
        game._apply_suit_filter = function() fired[#fired + 1] = "suit_filter" end
        game._apply_suit_split = function() fired[#fired + 1] = "suit_split" end
        game:apply_deck_config(primary_id, sleeve_id)
        return fired[1], #fired
    end
    local kind, n = fired_transform("b_abandoned", "b_checkered")
    T.assert_eq(kind, "no_face", "the primary's rewrite wins over the sleeve's")
    T.assert_eq(n, 1, "exactly one rewrite runs")
    kind, n = fired_transform("b_checkered", "b_abandoned")
    T.assert_eq(kind, "suit_split", "and the other way round")
    T.assert_eq(n, 1)
    kind, n = fired_transform("b_red", "b_checkered")
    T.assert_eq(kind, "suit_split", "a transformless primary borrows the sleeve's")
    T.assert_eq(n, 1)
    kind, n = fired_transform("b_erratic", "b_plasma")
    T.assert_eq(kind, "erratic", "erratic is a rewrite as well as a special")
    T.assert_eq(n, 1)
    kind, n = fired_transform("b_red", "b_blue")
    T.assert_nil(kind, "no rewrite in the pair, none runs")
    T.assert_eq(n, 0)
end)

suite.test("sleeve transforms really rewrite the deck", function()
    local function standard_deck()
        local cards = {}
        for _, suit in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
            for rank = 2, 14 do cards[#cards + 1] = { rank = rank, suit = suit } end
        end
        return { cards = cards }
    end
    local game = bootstrap.new_game(24)
    game.deck = standard_deck()
    game:apply_deck_config("b_red", "b_checkered")
    T.assert_eq(#game.deck.cards, 52, "the split rebuilds a full deck")
    for _, c in ipairs(game.deck.cards) do
        T.assert_true(c.suit == "Spades" or c.suit == "Hearts", "only the split's suits remain")
    end
    game.deck = standard_deck()
    game:apply_deck_config("b_abandoned", "b_checkered")
    T.assert_eq(#game.deck.cards, 40, "the primary's no-face rewrite wins and removes the faces")
    for _, c in ipairs(game.deck.cards) do
        T.assert_true(c.rank < 11 or c.rank == 14, "no face cards survive (Aces are not faces)")
    end
end)

suite.test("start content comes from both decks", function()
    local game = bootstrap.new_game(25)
    game.money = 4
    game:apply_deck_config("b_yellow", "b_magic")
    T.assert_eq(game.money, 14, "the primary's dollars land")
    T.assert_true(game:has_voucher("v_crystal_ball"), "the sleeve's voucher lands")
    local fools = 0
    for _, c in ipairs(game.consumables or {}) do
        if c.id == "tarot_fool" then fools = fools + 1 end
    end
    T.assert_eq(fools, 2, "and the sleeve's two Fools")
    local game2 = bootstrap.new_game(26)
    game2.money = 4
    game2:apply_deck_config("b_magic", "b_yellow")
    T.assert_eq(game2.money, 14, "the sleeve's dollars land the other way round")
    T.assert_true(game2:has_voucher("v_crystal_ball"), "the primary's voucher lands")
end)

suite.test("specials coexist in two slots and collapse when identical", function()
    local game = bootstrap.new_game(27)
    game:apply_deck_config("b_plasma", "b_anaglyph")
    T.assert_true(game:deck_special_active("plasma"))
    T.assert_true(game:deck_special_active("anaglyph"))
    T.assert_false(game:deck_special_active("erratic"))
    game:apply_deck_config("b_plasma", "b_plasma")
    T.assert_eq(game._deck_special, "plasma")
    T.assert_nil(game._deck_special_sleeve, "Plasma + Plasma is one Plasma")
    T.assert_nil(game.selected_sleeve_id, "and no sleeve at all")
end)

suite.test("a sleeved snapshot restores the merged modifiers", function()
    local game = bootstrap.new_game(28)
    game:apply_deck_config("b_painted", "b_ghost")
    local merged = raw_fields(game)
    game:restore_run_deck_stake_from_snapshot({
        selected_deck_id = "b_black", selected_sleeve_id = "b_green",
    })
    local want = expected_merge("b_black", "b_green")
    local got = raw_fields(game)
    for k, v in pairs(want) do T.assert_eq(got[k], v, "restored " .. k) end
    T.assert_eq(game.selected_sleeve_id, "b_green")
    -- A pre-sleeve snapshot restores unsleeved.
    game:restore_run_deck_stake_from_snapshot({ selected_deck_id = "b_painted" })
    T.assert_nil(game.selected_sleeve_id, "old saves have no sleeve")
    local plain = raw_fields(game)
    T.assert_eq(plain.hand_size, merged.hand_size, "painted alone is what the old save meant")
end)

return suite
