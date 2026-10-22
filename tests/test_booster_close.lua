--- Closing a booster pack. The last pick used to end the session on the same frame it fired, so
--- anything it started -- Immolate taking five cards apart, a conversion ripple, the used card
--- flying out -- was cut off, and the preview hand vanished instead of un-dealing.
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

local function arcana_offer()
    return {
        kind = "booster",
        pack = "arcana",
        size = "normal",
        card_count = 2,
        picks_granted = 1,
    }
end

--- A game sitting in an opened Arcana pack with a preview hand dealt.
local function open_pack(seed)
    local game = bootstrap.new_game(seed)
    game.STATE = game.STATES.SHOP
    game:begin_booster_session(arcana_offer())
    -- Skip the wrapper animation; this file is about what happens on the way out.
    for _ = 1, 200 do
        if game.booster_session.opening_phase == "ready" then break end
        game:_update_booster_opening(0.5)
    end
    return game
end

suite.test("the pack holds open while the last pick's effects play out", function()
    local game = open_pack(6001)
    local sess = game.booster_session
    sess.picks_remaining = 0
    game:begin_booster_close()
    T.assert_true(game._booster_closing ~= nil, "the close is pending")

    -- Something is still coming apart, so the hold does not expire.
    game._dissolving_nodes = { {} }
    game:_update_booster_close(2.0)
    T.assert_eq(game.booster_session, sess, "the pack is still open while cards dissolve")

    game._dissolving_nodes = nil
    game:_update_booster_close(0.1)
    T.assert_nil(game.booster_session, "and closes once the board is quiet")
end)

suite.test("the pack always holds a beat, even with nothing animating", function()
    local game = open_pack(6002)
    local sess = game.booster_session
    sess.picks_remaining = 0
    game:begin_booster_close()

    game:_update_booster_close(0.1)
    T.assert_eq(game.booster_session, sess, "a pick does not read as the pack blinking shut")
    game:_update_booster_close(1.0)
    T.assert_nil(game.booster_session, "the beat passes and it closes")
end)

suite.test("a stuck animation cannot strand the player in a spent pack", function()
    local game = open_pack(6003)
    game.booster_session.picks_remaining = 0
    game:begin_booster_close()
    game._dissolving_nodes = { {} } -- never finishes

    game:_update_booster_close(10)
    T.assert_nil(game.booster_session, "the hold has a ceiling")
end)

suite.test("the pack hand un-deals to the deck instead of vanishing", function()
    local game = open_pack(6004)
    game.booster_session.hand_for_tarot = true
    game.deck = game.deck or Deck(game)
    local hand = Hand(game)
    game.hand = hand
    hand:add_card({ rank = 10, suit = "Spades" })
    hand:add_card({ rank = 4, suit = "Hearts" })
    local nodes = { hand.card_nodes[1], hand.card_nodes[2] }
    local deck_before = #game.deck.cards

    game:end_booster_session()

    T.assert_eq(#game.pending_discard, 2, "both cards are in flight")
    for i, entry in ipairs(game.pending_discard) do
        T.assert_true(entry.target ~= nil, "flight " .. i .. " targets the deck origin")
    end
    T.assert_eq(#hand.card_nodes, 0, "the hand is empty")
    T.assert_eq(#game.deck.cards, deck_before + 2, "and both cards went back to the deck")
    for _, node in ipairs(nodes) do
        T.assert_false(node.selected, "a returning card is not still selected")
    end
end)

suite.test("skipping a pack, by B or the Skip button, feeds Red Card", function()
    local game = open_pack(6005)
    T.assert_true(game:add_joker_by_def("j_red_card"))
    local red = game.jokers[#game.jokers]
    game:skip_booster_pack()
    T.assert_nil(game.booster_session, "the pack is closed")
    T.assert_eq(tonumber(red.stored_mult) or 0, 3, "Red Card gains +3 Mult")
end)

suite.test("cutting a finished pack's close short is not a skip", function()
    local game = open_pack(6006)
    T.assert_true(game:add_joker_by_def("j_red_card"))
    local red = game.jokers[#game.jokers]
    game.booster_session.picks_remaining = 0
    game:begin_booster_close()
    game:skip_booster_pack()
    T.assert_eq(tonumber(red.stored_mult) or 0, 0, "nothing was skipped")
end)

--- Shop focus targets laid out like the shelf: the two controls on the left, then a pack.
local function stub_shop_targets(game)
    local pack = { shop_booster_slot = 1 }
    game.build_shop_focus_targets = function()
        return {
            { kind = "control", action = "continue", key = "continue", rect = { x = 8, y = 49, w = 74, h = 45 } },
            { kind = "control", action = "reroll", key = "reroll", rect = { x = 8, y = 98, w = 74, h = 45 } },
            { kind = "booster", slot = 1, node = pack, rect = { x = 200, y = 150, w = 50, h = 60 } },
        }
    end
end

suite.test("closing a shop pack puts the cursor on the nearest shelf item, not Next Round", function()
    local game = bootstrap.new_game(6007)
    game.input_mode = "gamepad"
    game.STATE = game.STATES.SHOP
    stub_shop_targets(game)
    -- The bought pack sat just left of the one that is still on the shelf.
    game:begin_booster_session(arcana_offer(), { x = 140, y = 150, w = 50, h = 60 })
    -- Leftovers from inside the pack that used to stay lit alongside Next Round.
    game.active_tooltip_joker = {}
    game.active_tooltip_consumable_index = 1
    game:skip_booster_pack()

    T.assert_eq(game.STATE, game.STATES.SHOP, "back in the shop")
    T.assert_eq(game._shop_focus_index, 3, "the remaining pack is focused")
    T.assert_eq(game.active_shop_booster_slot, 1, "and it is the one highlighted")
    T.assert_nil(game.active_tooltip_joker, "nothing from the pack stays highlighted")
    T.assert_nil(game.active_tooltip_consumable_index, "nothing from the pack stays highlighted")
end)

return suite
