--- Big numbers for the scoring pipeline (Tier 3e; design in
--- `~/workspace/balatro3ds-fork-push/DESIGN-tier3e-bignums.md`).
---
--- A Big is a table `{ __big = true, m = <mantissa in [1,10) or 0>, e = <exponent> }`
--- worth `m * 10^e`, with `e` itself a plain double — so values up to 10^(1.8e308)
--- are representable, which is unbounded for scoring purposes. One exponent level
--- only: PC Talisman's Omeganum tetration is deliberately not ported (design §3.2);
--- no traced effect can reach a value whose exponent needs an exponent.
---
--- Totals stay plain Lua numbers until an operation would overflow the double
--- range; only then do they promote to Big, and they never demote mid-run except
--- at explicit boundaries (display via `Big.format`, `Totals.floor`, saves via
--- `Totals.encode`/`revive`). Below overflow every operation is the vanilla double
--- operation bit-for-bit, which is what makes vanilla equivalence provable.
---
--- Lua 5.1 facts this module is shaped by:
--- * `tonumber(Big)` is nil and cannot be overridden — every totals gate must go
---   through `Totals.read` instead of a bare `tonumber()` (design §1.2, risk R1).
--- * Mixed Big<->number comparisons do NOT consult metamethods in 5.1 —
---   `Big >= number` raises. Every comparison site uses `Totals.cmp` (design §4.2).
--- * Mixed Big<->number *arithmetic* does consult the table's metamethods, so a
---   mod doing `context.port.chips + 50` gets a correct Big result for free.

local Big = {}

local LOG10 = math.log(10)

local is_big

local function raw_big(m, e)
    local v = { __big = true, m = m, e = e }
    setmetatable(v, Big._mt)
    Big._created = Big._created + 1
    return v
end

--- Split a finite non-zero double into the (mantissa, exponent) pair `from` stores.
--- Shared by construction and comparison, so a double and a Big built from the same
--- double always produce identical pairs.
local function split_number(x)
    local e = math.floor(math.log(math.abs(x)) / LOG10)
    local m = x / (10 ^ e)
    -- log10 is not exact at powers of ten; one renormalisation step always suffices.
    local am = math.abs(m)
    if am >= 10 then
        m = m / 10
        e = e + 1
    elseif am < 1 then
        m = m * 10
        e = e - 1
    end
    return m, e
end

local function normalize(m, e)
    if m == 0 then return 0, 0 end
    if m ~= m then return 0, 0 end
    local shift = math.floor(math.log(math.abs(m)) / LOG10)
    if shift ~= 0 then
        m = m / (10 ^ shift)
        e = e + shift
    end
    local am = math.abs(m)
    if am >= 10 then
        m = m / 10
        e = e + 1
    elseif am < 1 and am > 0 then
        m = m * 10
        e = e - 1
    end
    return m, e
end

--- Construct a Big from a mantissa and an optional base-10 exponent.
--- `Big.from(1e100)` is the common case (a plain double re-expressed);
--- `Big.from(5, 400)` is 5e400. Non-finite input collapses to the signed
--- `e = math.huge` sentinel rather than poisoning arithmetic with NaN fields.
function Big.from(m, e)
    m = tonumber(m) or 0
    e = tonumber(e) or 0
    if m ~= m then return raw_big(0, 0) end
    if m == math.huge then return raw_big(1, math.huge) end
    if m == -math.huge then return raw_big(-1, math.huge) end
    if e == math.huge or e == -math.huge then return raw_big(m < 0 and -1 or 1, e) end
    if m == 0 then return raw_big(0, 0) end
    if e ~= 0 then
        -- Fold the caller's exponent in through the mantissa's own split so the
        -- result is normalised in one pass.
        local mm, ee = split_number(m)
        return raw_big(mm, ee + e)
    end
    local mm, ee = split_number(m)
    return raw_big(mm, ee)
end

--- Construct a Big directly from a log10 value (and sign), for the pow paths
--- where the log is what was actually computed.
function Big.from_log10(l, sign)
    sign = (sign and sign < 0) and -1 or 1
    if l ~= l then return raw_big(0, 0) end
    if l == math.huge then return raw_big(sign, math.huge) end
    if l == -math.huge then return raw_big(0, 0) end
    local e = math.floor(l)
    local m = 10 ^ (l - e)
    if m >= 10 then
        m = m / 10
        e = e + 1
    end
    return raw_big(sign * m, e)
end

function Big.is_big(v)
    return type(v) == "table" and v.__big == true
end
is_big = Big.is_big

--- log10 of the value's magnitude, as a double. For a Big with a huge exponent
--- this is itself huge but finite for every value promotion can produce.
local function log10_of(v)
    if is_big(v) then
        if v.m == 0 then return -math.huge end
        return v.e + math.log(math.abs(v.m)) / LOG10
    end
    local n = tonumber(v) or 0
    if n == 0 then return -math.huge end
    return math.log(math.abs(n)) / LOG10
end
Big.log10_of = log10_of

--- The (mantissa, exponent) pair for a number|Big, or nil for anything else.
local function pair_of(v)
    if is_big(v) then return v.m, v.e end
    if type(v) == "number" then
        if v ~= v then return nil end
        if v == math.huge then return 1, math.huge end
        if v == -math.huge then return -1, math.huge end
        if v == 0 then return 0, 0 end
        return split_number(v)
    end
    return nil
end

--- Three-way compare of two number|Big values (nil reads as 0, the totals
--- convention). Returns -1, 0 or 1. This is the ONLY safe comparison across
--- the plain/Big boundary in Lua 5.1 (design §4.2).
local function cmp(a, b)
    if rawequal(a, b) then return 0 end
    local ma, ea = pair_of(a)
    local mb, eb = pair_of(b)
    if ma == nil then ma, ea = 0, 0 end
    if mb == nil then mb, eb = 0, 0 end
    local sa = (ma > 0 and 1) or (ma < 0 and -1) or 0
    local sb = (mb > 0 and 1) or (mb < 0 and -1) or 0
    if sa ~= sb then return sa < sb and -1 or 1 end
    if sa == 0 then return 0 end
    if ea ~= eb then
        local less = ea < eb
        if sa < 0 then less = not less end
        return less and -1 or 1
    end
    if ma == mb then return 0 end
    local less = math.abs(ma) < math.abs(mb)
    if sa < 0 then less = not less end
    return less and -1 or 1
end
Big.cmp = cmp

function Big.eq(a, b) return cmp(a, b) == 0 end

--- Demote to a plain double, explicitly lossy: past the double range the result
--- is ±inf, exactly what the value would have been without Big (design §3.4).
function Big.to_number(v)
    if type(v) == "number" then return v end
    if not is_big(v) then return nil end
    if v.m == 0 then return 0 end
    if v.e == math.huge then return v.m < 0 and -math.huge or math.huge end
    if v.e > 308 then return v.m < 0 and -math.huge or math.huge end
    if v.e < -310 then return 0 end
    return v.m * (10 ^ v.e)
end

local function add_pairs(ma, ea, mb, eb)
    if ma == 0 then return mb, eb end
    if mb == 0 then return ma, ea end
    -- Align on the larger exponent. When the gap passes ~17 the smaller term is
    -- below the larger's double precision and the scaling underflows it to 0 —
    -- absorption, the same rounding the doubles themselves would have done.
    if ea >= eb then
        return normalize(ma + mb * (10 ^ (eb - ea)), ea)
    end
    return normalize(mb + ma * (10 ^ (ea - eb)), eb)
end

--- Add two number|Big values; the result is a Big if either side is one.
function Big.add(a, b)
    local ma, ea = pair_of(a)
    local mb, eb = pair_of(b)
    if ma == nil then ma, ea = 0, 0 end
    if mb == nil then mb, eb = 0, 0 end
    local m, e = add_pairs(ma, ea, mb, eb)
    return raw_big(m, e)
end

function Big.sub(a, b)
    local mb, eb = pair_of(b)
    if mb == nil then mb, eb = 0, 0 end
    local ma, ea = pair_of(a)
    if ma == nil then ma, ea = 0, 0 end
    local m, e = add_pairs(ma, ea, -mb, eb)
    return raw_big(m, e)
end

function Big.mul(a, b)
    local ma, ea = pair_of(a)
    local mb, eb = pair_of(b)
    if ma == nil or mb == nil then return raw_big(0, 0) end
    if ma == 0 or mb == 0 then return raw_big(0, 0) end
    local m, e = normalize(ma * mb, ea + eb)
    return raw_big(m, e)
end

--- `base ^ p` where base is number|Big and p is a plain number. A negative base
--- to a fractional power is NaN, returned as a plain NaN so the caller's
--- existing `r ~= r` guard keeps the base, exactly as with doubles.
function Big.pow(base, p)
    p = tonumber(p) or 1
    local mb, eb = pair_of(base)
    if mb == nil then return 0 / 0 end
    if mb == 0 then
        if p > 0 then return raw_big(0, 0) end
        if p == 0 then return Big.from(1) end
        return raw_big(1, math.huge)
    end
    if p == 0 then return Big.from(1) end
    if p == 1 then
        if is_big(base) then return base end
        return Big.from(base)
    end
    if mb < 0 and p ~= math.floor(p) then return 0 / 0 end
    local sign = 1
    if mb < 0 and (math.abs(p) % 2) == 1 then sign = -1 end
    local l = p * (eb + math.log(math.abs(mb)) / LOG10)
    return Big.from_log10(l, sign)
end

--- Multiply two plain doubles, promoting to Big only when the finite product
--- overflowed (design §3.3). Returns a number when nothing overflowed, so
--- callers can use it as a drop-in for `a * b` on score-bearing values.
function Big.mul_promote(a, b)
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    local r = a * b
    if r == math.huge or r == -math.huge then
        if a ~= 0 and b ~= 0 and a == a and b == b
            and a ~= math.huge and a ~= -math.huge and b ~= math.huge and b ~= -math.huge then
            local sign = ((a < 0) ~= (b < 0)) and -1 or 1
            return Big.from_log10(log10_of(a) + log10_of(b), sign)
        end
    end
    return r
end

--- Raise a plain double to a plain power, promoting on overflow (design §3.3).
--- NaN results pass through as NaN, preserving the vanilla keep-the-base rule.
function Big.pow_promote(base, p)
    base = tonumber(base) or 0
    p = tonumber(p) or 1
    local r = base ^ p
    if (r == math.huge or r == -math.huge) and base == base and p == p
        and base ~= math.huge and base ~= -math.huge then
        -- inf from a finite base: |base| > 1 with p > 0, or 0 < |base| < 1 with
        -- p < 0 (the negative-base fractional case is NaN above, never inf).
        local sign = 1
        if r == -math.huge then sign = -1 end
        return Big.from_log10(p * log10_of(base), sign)
    end
    return r
end

--- Add two plain doubles, promoting to Big only when the finite sum overflowed
--- (the round-score accumulation case, design §4.2). Below overflow the result
--- is the vanilla double sum, bit-for-bit.
function Big.add_promote(a, b)
    a = tonumber(a) or 0
    b = tonumber(b) or 0
    local r = a + b
    if (r == math.huge or r == -math.huge) and a == a and b == b
        and a ~= math.huge and a ~= -math.huge and b ~= math.huge and b ~= -math.huge then
        return Big.add(a, b)
    end
    return r
end

--- Arithmetic for totals code whose values may be number|Big: the plain path is
--- taken (and stays bit-identical) unless a Big is involved or the plain
--- operation overflows. These are the drop-in replacements for raw `+`/`*`/`^`
--- on score-bearing values.
function Big.add_values(a, b)
    if is_big(a) or is_big(b) then return Big.add(a, b) end
    return Big.add_promote(a, b)
end

function Big.mul_values(a, b)
    if is_big(a) or is_big(b) then return Big.mul(a, b) end
    return Big.mul_promote(a, b)
end

function Big.div_values(a, b)
    if is_big(a) or is_big(b) then return Big.mul(a, Big.pow(b, -1)) end
    return (tonumber(a) or 0) / (tonumber(b) or 1)
end

function Big.pow_values(base, p)
    if is_big(base) then return Big.pow(base, p) end
    return Big.pow_promote(base, p)
end

--- (a + b) / 2 for the Plasma deck average, computed without leaving log space
--- for the addends (design §4.4).
function Big.half_sum(a, b)
    local s
    if is_big(a) or is_big(b) then
        s = Big.add(a, b)
    else
        s = (tonumber(a) or 0) + (tonumber(b) or 0)
        if s == math.huge or s == -math.huge then
            local sign = s < 0 and -1 or 1
            s = Big.from_log10(log10_of(Big.add(a, b)), sign)
        end
    end
    if is_big(s) then
        local m, e = normalize(s.m / 2, s.e)
        return raw_big(m, e)
    end
    return s / 2
end

--- The display shape (design §4.3): mantissa with three decimals + "e" + the raw
--- exponent integer, mirroring `NumberFormat`'s existing scientific branch.
function Big.format(v)
    if not is_big(v) then return tostring(v) end
    if v.m == 0 then return "0" end
    local sign = ""
    local m = v.m
    if m < 0 then
        sign = "-"
        m = -m
    end
    if v.e == math.huge then return sign .. "inf" end
    local e = v.e
    local mantissa = string.format("%.3f", m)
    if mantissa == "10.000" then
        mantissa = "1.000"
        e = e + 1
    end
    local es
    if e == math.floor(e) and math.abs(e) < 1e15 then
        es = string.format("%.0f", e)
    else
        es = tostring(e)
    end
    return sign .. mantissa .. "e" .. es
end

--------------------------------------------------------------------------------
-- Totals: the accessors every totals gate uses instead of bare `tonumber()`.
--------------------------------------------------------------------------------

local Totals = {}
Big.Totals = Totals

--- A totals read: returns `v` when it is a number or a Big, else the fallback.
function Totals.read(v, fallback)
    if type(v) == "number" or is_big(v) then return v end
    return fallback
end

--- For genuine plain-number consumers (counts, indices): a Big reads as the
--- signed infinity, so a caller's existing "astronomically large" handling —
--- usually none, just `or fallback` paths that never expected a table — behaves
--- honestly (design §3.4). Never use this on a totals write-back.
function Totals.plain(v)
    if type(v) == "number" then return v end
    if is_big(v) then
        if v.m > 0 then return math.huge end
        if v.m < 0 then return -math.huge end
        return 0
    end
    return nil
end

Totals.cmp = cmp

function Totals.eq(a, b) return cmp(a, b) == 0 end

--- math.floor for number|Big. Scores are integral by construction once floored
--- at the boundary, so a Big with a large exponent is its own floor; a small
--- fractional Big demotes through the double it equals (design §4.2).
function Totals.floor(v)
    if is_big(v) then
        if v.m == 0 then return 0 end
        if v.e >= 17 then return v end
        return math.floor(Big.to_number(v))
    end
    return math.floor(tonumber(v) or 0)
end

--- math.max(v, plain) across the boundary.
function Totals.max_plain(v, plain)
    plain = tonumber(plain) or 0
    if is_big(v) then
        return cmp(v, plain) >= 0 and v or plain
    end
    return math.max(tonumber(v) or 0, plain)
end

--- math.min(v, plain) across the boundary. A positive Big is past any plain
--- money a dollar cap could name, so the cap wins — the design's rule (§4.4).
function Totals.min_plain(v, plain)
    plain = tonumber(plain) or 0
    if is_big(v) then
        return cmp(v, plain) <= 0 and v or plain
    end
    return math.min(tonumber(v) or 0, plain)
end

--- The save encoding (design §4.5): a one-key table whose string payload
--- round-trips through the save serializer untouched and cannot collide with
--- real data, since the fields it sits in are scalars. Plain values encode
--- as themselves, so a normal run's snapshot stays byte-identical.
function Totals.encode(v)
    if is_big(v) then
        return { __big = string.format("%.17g:%.17g", v.m, v.e) }
    end
    return v
end

--- Undo `Totals.encode` (and the structural form a live Big takes when it is
--- serialised inside a bigger table, e.g. career stats). Returns the fallback
--- for anything that is not a number, a Big, or an encoded table.
function Totals.revive(v, fallback)
    if type(v) == "number" or is_big(v) then return v end
    if type(v) == "table" then
        if type(v.__big) == "string" then
            local ms, es = v.__big:match("^([^:]+):(.+)$")
            local m, e = tonumber(ms), tonumber(es)
            if m and e then
                local r = raw_big(0, 0)
                r.m, r.e = normalize(m, e)
                return r
            end
        elseif v.__big == true and type(v.m) == "number" and type(v.e) == "number" then
            local r = raw_big(0, 0)
            r.m, r.e = normalize(v.m, v.e)
            return r
        end
    end
    return fallback
end

--- How many Big values have been constructed. The equivalence battery reads
--- this to prove normal play never promotes (design risk R4).
Big._created = 0
function Big.created_count() return Big._created end

--------------------------------------------------------------------------------
-- Metamethods: Big<->Big and mixed arithmetic. Comparisons are Big<->Big only;
-- Lua 5.1 never fires them across types, which is what `Totals.cmp` is for.
--------------------------------------------------------------------------------

Big._mt = {
    __add = function(a, b) return Big.add(a, b) end,
    __sub = function(a, b) return Big.sub(a, b) end,
    __mul = function(a, b) return Big.mul(a, b) end,
    __div = function(a, b)
        local mb, eb = pair_of(b)
        if mb == nil or mb == 0 then return raw_big(0, 0) end
        -- Division by a plain-or-Big divisor is multiplication by its reciprocal
        -- in log space; scoring only ever divides by small constants.
        local inv = Big.pow(b, -1)
        return Big.mul(a, inv)
    end,
    __pow = function(a, b) return Big.pow(a, tonumber(b) or 1) end,
    __unm = function(a) return raw_big(-a.m, a.e) end,
    __eq = function(a, b) return cmp(a, b) == 0 end,
    __lt = function(a, b) return cmp(a, b) < 0 end,
    __le = function(a, b) return cmp(a, b) <= 0 end,
    __tostring = function(a) return Big.format(a) end,
}

return Big
