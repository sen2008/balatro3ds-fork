--- Burglar adds its +3 Hands when the Blind is selected, not to the per-round count: it lands
--- after The Needle has cut the round to one hand, and every Blueprint or Brainstorm copying
--- it adds its own +3 (`reference/Balatro/card.lua`, Burglar's `setting_blind`).
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

--- A game with `jokers` owned, left as `_commit_selected_blind` leaves it for blind `idx`.
local function start_blind(jokers, boss_id)
    local g = bootstrap.new_game(5150)
    for _, id in ipairs(jokers) do
        T.assert_true(g:add_joker_by_def(id), "add " .. id)
    end
    if boss_id then
        g.ante = 2
        g.current_blind_index = 3
        g.current_boss_blind_id = boss_id
    else
        g.current_blind_index = 1
    end
    g.hands = g:get_effective_hands_per_round()
    g.discards = g:get_effective_discards_per_round()
    g.blind_hand_play_counts = {}
    g.round_hands_played = 0
    g:boss_reset_for_new_blind()
    g:prepare_hand_for_new_blind()
    return g
end

suite.test("Burglar gives +3 Hands and takes every discard", function()
    local g = start_blind({ "j_burglar" })
    T.assert_eq(g.hands, 7, "4 base hands + 3")
    T.assert_eq(g.discards, 0, "no discards")
end)

suite.test("Burglar adds its hands after The Needle", function()
    local g = start_blind({ "j_burglar" }, "bl_needle")
    T.assert_eq(g.hands, 4, "The Needle's 1 hand + 3")
end)

suite.test("each Blueprint or Brainstorm copying Burglar adds another +3", function()
    -- Blueprint copies the Joker to its right; Brainstorm copies the leftmost.
    local g = start_blind({ "j_burglar", "j_brainstorm", "j_blueprint", "j_burglar" })
    T.assert_eq(g.hands, 4 + 3 * 4, "two Burglars, one Brainstorm and one Blueprint")
end)

suite.test("the first hand still counts as first when Burglar or The Needle moved the total", function()
    local g = start_blind({ "j_burglar" }, "bl_needle")
    T.assert_eq(g:get_round_hands_played(), 0, "no hand played yet")
end)

return suite
