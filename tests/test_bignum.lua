--- Tier 3e Phase 0/3 unit tests for `big.lua`: representation, arithmetic,
--- comparisons, formatting, and the Totals save encoding. The scoring-pipeline
--- behaviour lives in tests/test_bignum_equivalence.lua.

local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")
local Big = require("big")
local Totals = Big.Totals

local suite = T.suite()

bootstrap.load()

local function assert_big_near(v, expected, tol, msg)
    T.assert_true(Big.is_big(v), (msg or "value") .. ": expected a Big, got " .. tostring(v))
    local got = Big.log10_of(v)
    T.assert_near(got, math.log(expected) / math.log(10), tol or 1e-9, msg)
end

suite.test("construction normalises into [1,10) mantissa", function()
    local a = Big.from(12345)
    T.assert_eq(a.m, 1.2345)
    T.assert_eq(a.e, 4)
    local b = Big.from(0.05)
    T.assert_eq(b.m, 5)
    T.assert_eq(b.e, -2)
    local c = Big.from(5, 400)
    T.assert_eq(c.m, 5)
    T.assert_eq(c.e, 400)
    local z = Big.from(0)
    T.assert_eq(z.m, 0)
    T.assert_eq(z.e, 0)
    -- A power of ten exactly: log10 imprecision must not leave m at 9.999...
    local p = Big.from(1e20)
    T.assert_eq(p.m, 1)
    T.assert_eq(p.e, 20)
end)

suite.test("add and mul match doubles in the overlap range", function()
    local rng = math.random
    math.randomseed(20261023)
    for _ = 1, 200 do
        local a = rng() * 1e6 - 5e5
        local b = rng() * 1e6 - 5e5
        local s = Big.to_number(Big.add(Big.from(a), b))
        T.assert_near(s, a + b, math.max(1e-6, math.abs(a + b) * 1e-12), "add overlap")
        local p = Big.to_number(Big.mul(Big.from(a), b))
        local want = a * b
        T.assert_near(p, want, math.max(1e-6, math.abs(want) * 1e-12), "mul overlap")
    end
end)

suite.test("addition absorbs a far-smaller operand, like doubles do", function()
    local big = Big.from(1, 500)
    local s = Big.add(big, 100)
    T.assert_eq(s.m, 1)
    T.assert_eq(s.e, 500)
    -- ...but a comparable operand still lands.
    local t = Big.add(big, Big.from(5, 499))
    T.assert_eq(t.m, 1.5)
    T.assert_eq(t.e, 500)
end)

suite.test("subtraction across the boundary, including exact cancellation", function()
    local d = Big.sub(Big.from(1, 100), Big.from(1, 100))
    T.assert_eq(d.m, 0)
    local e = Big.sub(Big.from(2, 10), Big.from(5, 9))
    assert_big_near(e, 1.5e10, 1e-9, "sub")
    local n = Big.to_number(Big.sub(5, Big.from(9)))
    T.assert_eq(n, -4)
end)

suite.test("pow: plain exponents on Big bases, NaN passthrough", function()
    local r = Big.pow(Big.from(2, 100), 3) -- (2e100)^3 = 8e300, within log-space tolerance
    assert_big_near(r, 8e300, 1e-9, "pow")
    T.assert_eq(r.e, 300)
    local root = Big.pow(Big.from(9), 0.5)
    T.assert_eq(Big.to_number(root), 3)
    local nan = Big.pow(-2, 0.5)
    T.assert_true(nan ~= nan, "negative base to a fractional power is NaN")
    local neg = Big.pow(Big.from(-2), 3)
    T.assert_near(Big.to_number(neg), -8, 1e-9)
end)

suite.test("pow_promote only promotes on real overflow", function()
    local small = Big.pow_promote(4, 3)
    T.assert_eq(small, 64)
    T.assert_false(Big.is_big(small))
    local huge = Big.pow_promote(1e200, 2)
    T.assert_true(Big.is_big(huge))
    T.assert_eq(huge.m, 1)
    T.assert_eq(huge.e, 400)
    local nan = Big.pow_promote(-2, 0.5)
    T.assert_true(nan ~= nan, "NaN stays NaN so callers keep the base")
    local mul = Big.mul_promote(3, 4)
    T.assert_eq(mul, 12)
    local mulbig = Big.mul_promote(1e200, 1e200)
    T.assert_true(Big.is_big(mulbig))
    T.assert_eq(mulbig.e, 400)
end)

suite.test("Totals.cmp orders mixed plain and Big values", function()
    T.assert_eq(Totals.cmp(Big.from(1, 400), 1e308), 1)
    T.assert_eq(Totals.cmp(1e308, Big.from(1, 400)), -1)
    T.assert_eq(Totals.cmp(Big.from(1e20), 1e20), 0, "a Big from a double equals the double")
    T.assert_eq(Totals.cmp(Big.from(5, 3), 4999), 1)
    T.assert_eq(Totals.cmp(Big.from(5, 3), 5000), 0)
    T.assert_eq(Totals.cmp(Big.from(5, 3), 5001), -1)
    T.assert_eq(Totals.cmp(-5, Big.from(1, 400)), -1)
    T.assert_eq(Totals.cmp(Big.from(-2, 10), Big.from(-1, 10)), -1, "negative order flips")
    T.assert_eq(Totals.cmp(nil, 0), 0, "nil reads as zero")
    T.assert_eq(Totals.cmp(Big.from(0), 0), 0)
end)

suite.test("metamethods: Big arithmetic and Big<->Big comparison", function()
    local a = Big.from(3, 10)
    local s = a + 5 -- absorbed
    T.assert_true(Big.is_big(s))
    T.assert_eq(s.e, 10)
    local p = 2 * a
    T.assert_eq(p.m, 6)
    local q = a * a
    assert_big_near(q, 9e20, 1e-9, "square")
    T.assert_true(Big.from(1, 5) < Big.from(2, 5))
    T.assert_true(Big.from(1, 5) == Big.from(10, 4))
    T.assert_true(Big.from(1, 5) <= Big.from(1, 5))
    local half = Big.half_sum(Big.from(1, 10), Big.from(1, 10))
    assert_big_near(half, 1e10, 1e-9, "half_sum")
    local avg = Big.half_sum(10, 20)
    T.assert_eq(avg, 15, "plain half_sum stays plain")
end)

suite.test("Totals.floor / min_plain / max_plain", function()
    T.assert_eq(Totals.floor(Big.from(1.5, 20)), Big.from(1.5, 20), "large Big is its own floor")
    T.assert_eq(Totals.floor(Big.from(15.7)), 15, "small fractional Big floors through its double")
    T.assert_eq(Totals.floor(42.9), 42)
    T.assert_eq(Totals.min_plain(Big.from(1, 400), 250), 250, "dollar cap beats a positive Big")
    T.assert_eq(Totals.min_plain(Big.from(3), 250).m, 3, "a small Big under the cap survives")
    T.assert_eq(Totals.max_plain(Big.from(1, 400), 0).e, 400)
    T.assert_eq(Totals.max_plain(5, 9), 9)
end)

suite.test("format: mantissa with three decimals, raw exponent", function()
    T.assert_eq(Big.format(Big.from(1.234, 456)), "1.234e456")
    T.assert_eq(Big.format(Big.from(9.9999, 10)), "1.000e11", "a mantissa rounding to 10 renormalises")
    T.assert_eq(Big.format(Big.from(-2.5, 30)), "-2.500e30")
    T.assert_eq(Big.format(Big.from(0)), "0")
    T.assert_eq(tostring(Big.from(1, 1000000)), "1.000e1000000", "huge exponents print raw")
end)

suite.test("encode/revive round-trips Big and leaves plain values alone", function()
    local b = Big.from(1.2345, 678)
    local enc = Totals.encode(b)
    T.assert_eq(type(enc), "table")
    local back = Totals.revive(enc)
    T.assert_true(Big.is_big(back))
    T.assert_eq(back.m, b.m)
    T.assert_eq(back.e, b.e)
    -- Plain values pass through both ways (byte-identical snapshots, design §4.5).
    T.assert_eq(Totals.encode(42), 42)
    T.assert_eq(Totals.revive(42), 42)
    T.assert_eq(Totals.revive(nil, 0), 0)
    T.assert_eq(Totals.revive("junk", 7), 7)
    -- The structural form: a live Big serialised inside a bigger table loses its
    -- metatable but keeps its fields, and revive rebuilds it.
    local structural = { __big = true, m = 2.5, e = 33 }
    local r2 = Totals.revive(structural)
    T.assert_true(Big.is_big(r2))
    T.assert_eq(r2.m, 2.5)
    T.assert_eq(r2.e, 33)
end)

suite.test("to_number is explicitly lossy past the double range", function()
    T.assert_eq(Big.to_number(Big.from(1, 400)), math.huge)
    T.assert_eq(Big.to_number(Big.from(-1, 400)), -math.huge)
    T.assert_eq(Big.to_number(Big.from(5, 3)), 5000)
    T.assert_eq(Big.to_number(7), 7)
end)

suite.test("NumberFormat: Big branch, demote-small, and plain regression", function()
    local NumberFormat = require("number_format")
    T.assert_eq(NumberFormat.format(Big.from(1.234, 456)), "1.234e456")
    T.assert_eq(NumberFormat.format(Big.from(5, 25)), "5.000e25",
        "past the switch point a Big uses the scientific shape")
    T.assert_eq(NumberFormat.format(Big.from(1234567)), "1,234,567",
        "a small Big demotes and groups like its double")
    T.assert_eq(NumberFormat.format(Big.from(0)), "0")
    T.assert_eq(NumberFormat.format(Big.from(-2.5, 30)), "-2.500e30")
    -- Plain values format exactly as before.
    T.assert_eq(NumberFormat.format(6247326), "6,247,326")
    T.assert_eq(NumberFormat.format(1.5e11), "1.500e11")
    T.assert_eq(NumberFormat.format(42), "42")
end)

--------------------------------------------------------------------------------
-- Saves (Phase 5): tagged encoding, revive, plain snapshots unchanged.
--------------------------------------------------------------------------------

suite.test("a Big run snapshot round-trips through the real save file", function()
    local game = bootstrap.new_game(9501)
    game.jokers = {}
    game.round_score = Big.from(1.5, 500)
    game.last_hand_score = Big.from(2.5, 400)
    game.selectedHandChips = Big.from(3, 350)
    game.selectedHandMult = Big.from(4, 320)
    game.run_best_hand_score = Big.from(1.5, 500)
    local built = game:build_run_snapshot()
    -- The fields carry the tagged encoding, never a raw Big (R5).
    T.assert_eq(type(built.round_score), "table")
    T.assert_eq(type(built.round_score.__big), "string")
    local ok, err = game:write_run_snapshot(built)
    T.assert_true(ok, "write failed: " .. tostring(err))
    local raw = love.filesystem.read(game:run_save_path())
    T.assert_true(raw:find("__big", 1, true) ~= nil, "the save file carries the tag")
    local decoded = game:read_run_snapshot()
    T.assert_not_nil(decoded)
    local back = Totals.revive(decoded.round_score)
    T.assert_true(Big.is_big(back))
    T.assert_eq(back.m, 1.5)
    T.assert_eq(back.e, 500)
    local back_chips = Totals.revive(decoded.selectedHandChips)
    T.assert_true(Big.is_big(back_chips))
    T.assert_eq(back_chips.e, 350)
    -- And a full load revives live Bigs onto the game. (The selected totals are
    -- recomputed from hand stats during the resume's re-deal, as for any save:
    -- a run cannot be saved mid-scoring, so they are never load-bearing.)
    local game2 = bootstrap.new_game(9502)
    T.assert_true(game2:load_run_snapshot(decoded))
    T.assert_true(Big.is_big(game2.round_score))
    T.assert_eq(game2.round_score.e, 500)
    T.assert_true(Big.is_big(game2.run_best_hand_score))
    T.assert_true(Big.is_big(game2.last_hand_score))
end)

suite.test("a plain run's snapshot fields stay plain numbers", function()
    local game = bootstrap.new_game(9503)
    game.jokers = {}
    game.round_score = 12345
    game.last_hand_score = 678
    game.selectedHandChips = 55
    game.selectedHandMult = 6
    game.run_best_hand_score = 999
    local built = game:build_run_snapshot()
    T.assert_eq(built.round_score, 12345)
    T.assert_eq(built.last_hand_score, 678)
    T.assert_eq(built.selectedHandChips, 55)
    T.assert_eq(built.selectedHandMult, 6)
    T.assert_eq(built.run_best_hand_score, 999)
    local ok = game:write_run_snapshot(built)
    T.assert_true(ok)
    local raw = love.filesystem.read(game:run_save_path())
    T.assert_true(raw:find("__big", 1, true) == nil, "no tag leaks into a plain save")
end)

suite.test("career best: a Big best survives settings normalisation", function()
    local game = bootstrap.new_game(9504)
    -- The structural form (a live Big serialised inside SETTINGS) ...
    local out = game:normalize_career_stats({
        c_best_hand_chips = { __big = true, m = 1.5, e = 500 },
    })
    T.assert_true(Big.is_big(out.c_best_hand_chips))
    T.assert_eq(out.c_best_hand_chips.e, 500)
    -- ... and plain stats keep the old floor-and-positive rule.
    local out2 = game:normalize_career_stats({ c_most_money = 300.7, c_furthest_ante = 0 })
    T.assert_eq(out2.c_most_money, 300)
    T.assert_eq(out2.c_furthest_ante, 0)
    -- Recording a Big best, then a smaller plain one, keeps the Big.
    game:record_career_best("c_best_hand_chips", Big.from(9, 400))
    T.assert_true(Big.is_big(game.career_stats.c_best_hand_chips))
    game:record_career_best("c_best_hand_chips", 12345)
    T.assert_true(Big.is_big(game.career_stats.c_best_hand_chips), "a plain score cannot demote the record")
end)

suite.test("the Observatory voucher multiplies a Big mult instead of resetting it", function()
    local game = bootstrap.new_game(9505)
    game.vouchers = { "v_observatory" }
    local planet_id
    for id, def in pairs(CONSUMABLE_DEFS) do
        if type(def) == "table" and def.kind == "planet" and def.hand == "Pair" then planet_id = id break end
    end
    T.assert_not_nil(planet_id)
    game.consumables = { { id = planet_id } }
    local ctx = { hand_type = "Pair", chips = 10, mult = Big.from(2, 400) }
    game:_apply_observatory_voucher_to_hand_scored_ctx(ctx)
    T.assert_true(Big.is_big(ctx.mult), "the total stayed Big through the voucher")
    T.assert_near(Big.log10_of(ctx.mult), 400 + math.log(3) / math.log(10), 1e-9, "x1.5 applied")
    -- Plain path unchanged.
    local plain = { hand_type = "Pair", chips = 10, mult = 4 }
    game:_apply_observatory_voucher_to_hand_scored_ctx(plain)
    T.assert_eq(plain.mult, 6)
end)

suite.test("blind targets: the endless formula is unchanged while finite, Big past it (2b)", function()
    local game = bootstrap.new_game(9506)
    -- The pre-change formula, verbatim, as the plain-range oracle.
    local function oracle(ante)
        local last_base = 50000
        local overflow = math.max(0, ante - 8)
        local raw = last_base * (1.6 + (0.75 * overflow) ^ (1 + (0.2 * overflow))) ^ (overflow)
        if raw ~= raw or raw == math.huge then return nil end
        local magnitude = math.floor(math.log(raw) / math.log(10))
        return math.floor(raw / (10 ^ (magnitude - 1))) * (10 ^ (magnitude - 1))
    end
    for _, ante in ipairs({ 9, 10, 11, 12, 15, 20, 30, 35 }) do
        local want = oracle(ante)
        T.assert_not_nil(want, "oracle finite at ante " .. ante)
        T.assert_eq(game:get_base_requirement_for_ante(ante), want, "ante " .. ante)
        T.assert_false(Big.is_big(game:get_base_requirement_for_ante(ante)))
    end
    T.assert_true(Big.is_big(game:get_base_requirement_for_ante(39)),
        "the formula's own overflow point promotes (pre-change this was inf)")
    -- Past the double range the requirement is a Big capped to two sig figs.
    local req = game:get_base_requirement_for_ante(100)
    T.assert_true(Big.is_big(req), "ante 100 requirement is Big")
    local digits = req.m * 10
    T.assert_near(digits, math.floor(digits + 1e-9), 1e-6, "two significant figures")
    -- Independent magnitude check via Big pow: 50000 x (1.6 + 69^19.4)^92.
    local inner = Big.add(Big.pow(Big.from(69), 19.4), 1.6)
    local raw = Big.mul(Big.from(50000), Big.pow(inner, 92))
    T.assert_near(Big.log10_of(req), Big.log10_of(raw), 0.02, "log-space magnitude")
    T.assert_true(Big.cmp(req, raw) <= 0, "the cap rounds down")
    -- The blind target built on it is Big too, and a Big score beats it.
    local target = game:get_blind_target(1, 100)
    T.assert_true(Big.is_big(target))
    T.assert_eq(Big.cmp(Big.from(1, 4000), target), 1)
    -- Snapshot carries the target tagged, and it revives.
    game.current_blind_target = target
    local built = game:build_run_snapshot()
    T.assert_eq(type(built.current_blind_target), "table")
    local revived = Totals.revive(built.current_blind_target)
    T.assert_true(Big.is_big(revived))
    T.assert_eq(revived.e, req.e)
end)

return suite
