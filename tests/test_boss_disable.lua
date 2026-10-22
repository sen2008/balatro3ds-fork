--- Disabling a boss (Luchador sold mid-round, Chicot owned at the start) undoes what it did, as
--- the reference's `Blind:disable` does; Crimson Heart's debuff belongs to a Joker, not a slot;
--- and Amber Acorn's face-down row survives a save and resume.
local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")

local suite = T.suite()

--- A game sitting in boss blind `boss_id` with `jokers` owned, set up the way
--- `_commit_selected_blind` leaves it.
local function boss_game(seed, boss_id, jokers, ante)
    local g = bootstrap.new_game(seed)
    g.STATE = g.STATES.SELECTING_HAND
    g.ante = ante or 2
    g.current_blind_index = 3
    g.current_boss_blind_id = boss_id
    for _, id in ipairs(jokers or {}) do
        T.assert_true(g:add_joker_by_def(id), "add " .. id)
    end
    g.hand = Hand(g)
    g.hands = g:get_effective_hands_per_round()
    g.discards = g:get_effective_discards_per_round()
    g.current_blind_target = g:get_blind_target(3, g.ante)
    g:boss_reset_for_new_blind()
    return g
end

local function sell(g, id)
    for i, j in ipairs(g.jokers) do
        if j.def.id == id then
            T.assert_true(g:sell_owned_joker(i), "sold " .. id)
            return
        end
    end
    error("no " .. id .. " to sell")
end

-- Luchador -------------------------------------------------------------------------------

suite.test("selling Luchador against The Wall halves the target", function()
    local g = boss_game(8101, "bl_wall", { "j_luchador" })
    local full = g.current_blind_target
    sell(g, "j_luchador")
    T.assert_eq(g.current_blind_target, math.floor(full / 2), "back to an ordinary boss size")
end)

suite.test("selling Luchador against Violet Vessel cuts the target to a third", function()
    local g = boss_game(8102, "bl_final_vessel", { "j_luchador" }, 8)
    local full = g.current_blind_target
    sell(g, "j_luchador")
    T.assert_eq(g.current_blind_target, math.floor(full / 3), "a third")
end)

suite.test("selling Luchador against The Needle gives the hands back", function()
    local g = boss_game(8103, "bl_needle", { "j_luchador" })
    T.assert_eq(g.hands, 1, "The Needle leaves one hand")
    sell(g, "j_luchador")
    T.assert_eq(g.hands, 4, "all four hands back")
end)

suite.test("selling Luchador against The Water gives the discards back", function()
    local g = boss_game(8104, "bl_water", { "j_luchador" })
    T.assert_eq(g.discards, 0, "The Water takes them all")
    sell(g, "j_luchador")
    T.assert_eq(g.discards, 3, "all three discards back")
end)

suite.test("selling Luchador turns face-down cards back over", function()
    for _, boss in ipairs({ "bl_house", "bl_wheel", "bl_fish", "bl_mark" }) do
        local g = boss_game(8105, boss, { "j_luchador" })
        g.hand:create_card({ rank = 12, suit = "Hearts" })
        g.hand:create_card({ rank = 5, suit = "Clubs" })
        g.hand.card_nodes[1]:set_face_up(false)
        sell(g, "j_luchador")
        for _, node in ipairs(g.hand.card_nodes) do
            T.assert_true(node.face_up ~= false, boss .. ": every card is face up")
        end
        T.assert_nil(g:get_active_boss_blind_id(), boss .. " is disabled")
    end
end)

-- Chicot ---------------------------------------------------------------------------------

suite.test("Chicot shrinks The Wall as the blind starts and stays sold-proof", function()
    local g = boss_game(8106, "bl_wall", { "j_chicot" })
    T.assert_eq(g.current_blind_target, math.floor(g:get_blind_target(3, g.ante) / 2), "halved")
    sell(g, "j_chicot")
    T.assert_nil(g:get_active_boss_blind_id(), "selling Chicot does not switch the boss back on")
end)

-- Crimson Heart --------------------------------------------------------------------------

suite.test("Crimson Heart's debuff follows its Joker when the row is reordered", function()
    local g = boss_game(8107, "bl_final_heart", { "j_joker", "j_greedy_joker", "j_lusty_joker" }, 8)
    g:boss_on_hand_refilled(true, nil)
    g._frame_id = 1
    local blocked = g:boss_crimson_disabled_joker_node()
    T.assert_not_nil(blocked, "a Joker is debuffed")

    -- Move the debuffed Joker to the other end of the row.
    for i, j in ipairs(g.jokers) do
        if j == blocked then table.remove(g.jokers, i) break end
    end
    if blocked == g.jokers[1] then
        table.insert(g.jokers, blocked)
    else
        table.insert(g.jokers, 1, blocked)
    end
    g:_apply_joker_layout()
    for _, j in ipairs(g.jokers) do
        if j.T and j.VT then j.VT.x = j.T.x end
    end
    g._frame_id = 2
    T.assert_eq(g:boss_crimson_disabled_joker_node(), blocked, "the same Joker is still debuffed")
end)

suite.test("Crimson Heart's debuffed Joker survives a save and resume", function()
    local g = boss_game(8108, "bl_final_heart", { "j_joker", "j_greedy_joker", "j_lusty_joker" }, 8)
    g:boss_on_hand_refilled(true, nil)
    g._frame_id = 1
    local blocked_id = g:boss_crimson_disabled_joker_node().def.id

    local resumed = bootstrap.new_game(8109)
    T.assert_true(resumed:load_run_snapshot(g:build_run_snapshot()))
    resumed.STATE = resumed.STATES.SELECTING_HAND
    resumed._frame_id = 1
    local node = resumed:boss_crimson_disabled_joker_node()
    T.assert_not_nil(node, "still debuffing a Joker")
    T.assert_eq(node.def.id, blocked_id, "the same one")
end)

-- Amber Acorn ----------------------------------------------------------------------------

suite.test("Amber Acorn's face-down Jokers stay face down across a save and resume", function()
    local g = boss_game(8110, "bl_final_acorn", { "j_joker", "j_greedy_joker" }, 8)
    for _, j in ipairs(g.jokers) do T.assert_true(j.face_up == false, "flipped by the boss") end

    local resumed = bootstrap.new_game(8111)
    T.assert_true(resumed:load_run_snapshot(g:build_run_snapshot()))
    T.assert_eq(#resumed.jokers, 2, "both Jokers restored")
    for _, j in ipairs(resumed.jokers) do
        T.assert_true(j.face_up == false, j.def.id .. " is still face down")
    end
end)

return suite
