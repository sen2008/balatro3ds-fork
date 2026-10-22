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

return suite
