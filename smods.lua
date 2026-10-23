--- The mod API: a Steamodded-shaped surface over this port's own systems.
---
--- Mods are written the way Steamodded mods are -- `SMODS.Joker { key, loc_txt, config, rarity,
--- cost, loc_vars, calculate }` and friends -- so the examples at
--- https://github.com/Steamodded/examples port with little change. What sits underneath is not
--- Steamodded: there is no Lovely, no `G.GAME`, no event manager and no shaders. A mod Joker is
--- registered into `JOKER_DEFS` and `JokerEffects` exactly like a vanilla one, and `calculate`
--- is driven from the port's own joker events (`EVENT_CONTEXT` below), so pools, the shop, the
--- collection, Blueprint, retriggers and saving all treat it as a Joker like any other.
---
--- Textures: one image per card, the way the port stores its own Jokers and consumables, not
--- Steamodded's atlases. A card names its file (`sprite = "plus_four.png"`) under the mod's
--- `assets/1x/`, and the 3DS runtime loads the `.t3x` beside it whenever it is asked for a
--- `.png` (LovePotion's `translatePath`). Converting is the modder's job
--- (`tex3ds -f rgba plus_four.png -o plus_four.t3x`), never the game's. One file per card is what
--- lets a mod sprite be loaded when a card appears and freed when the last one goes, exactly as a
--- vanilla sprite is, instead of a whole sheet staying resident.
---
--- Editions stay the port's own: a mod Joker in foil, holo or polychrome is drawn with the same
--- additive texture passes as a vanilla one (`Fx.draw_edition_image`), since the PICA200 has no
--- fragment shaders to run a mod's. Negative needs its own image (`negative_sprite`).

SMODS = SMODS or {}

local CardArt = require("card_art")
--- Scoring totals may be Big past the double range (Tier 3e).
local Big = require("big")
local Totals = Big.Totals

--- Every mod image, by sprite key (`mod:<prefix>:<file>`): `{ path, mod }`.
SMODS.Sprites = SMODS.Sprites or {}
--- Every mod card's definition table (the one the mod passed in), by id.
SMODS.Centers = SMODS.Centers or {}
--- The mod whose main file is running. Only set while a mod loads, which is the only time
--- `SMODS.Joker` and the other registration calls may be made.
SMODS.current_mod = nil

--- Stands in for Steamodded's `G.play` card area, so `context.cardarea == G.play` reads true
--- for a scored card. `main.lua` points `G.play` at it.
SMODS.PLAY = SMODS.PLAY or { _smods_area = "play" }

--- Mod Jokers sort after every vanilla one in the collection.
local next_order = 1000

local RARITY = { common = 1, uncommon = 2, rare = 3, legendary = 4 }

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, vv in pairs(v) do out[k] = deep_copy(vv) end
    return out
end
SMODS.deep_copy = deep_copy

local function need_mod(what)
    local mod = SMODS.current_mod
    if not mod then
        error(what .. " can only be called from a mod's main file while it loads", 3)
    end
    return mod
end

local function check(cond, msg)
    if not cond then error(msg, 3) end
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

--- Record a runtime error against a mod. A mod that throws inside `calculate` must not take the
--- run down with it: the call is skipped, the error is kept for the Mods screen and the log, and
--- only the first few are kept so a Joker failing every frame cannot grow the list forever.
function SMODS.report_runtime_error(mod, err)
    if type(mod) ~= "table" then return end
    mod.runtime_errors = mod.runtime_errors or {}
    if #mod.runtime_errors < 5 then
        mod.runtime_errors[#mod.runtime_errors + 1] = tostring(err)
        if SMODS.on_runtime_error then SMODS.on_runtime_error(mod, err) end
    end
end

--- Call into mod code, catching anything it throws.
function SMODS.call(mod, fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    SMODS.report_runtime_error(mod, a)
    return nil
end

--------------------------------------------------------------------------------
-- Sprites
--------------------------------------------------------------------------------

--- The atlas name a mod card's `pos` carries. Its `index` is then a sprite key rather than a
--- cell, so the port's existing sprite plumbing (`Joker.sprite_key_from_pos`, the collection,
--- sprite warming) resolves a mod card without knowing anything about mods.
SMODS.MOD_ATLAS = "@mod"

--- Register one of a mod's images and return its sprite key. The file has to exist -- as the
--- `.png` it is named by, or as the `.t3x` the 3DS loads in its place -- so a typo is a load error
--- naming the file, not an invisible card.
local function register_sprite(mod, file, what, key, field)
    if type(file) ~= "string" or not file:match("%S") then
        error(("%s '%s' needs %s = \"Name.png\" (an image in assets/1x)"):format(what, key, field), 0)
    end
    if file:find("..", 1, true) or file:sub(1, 1) == "/" then
        error(("%s '%s': %s must be a file inside assets/1x"):format(what, key, field), 0)
    end
    local path = mod.path .. "/assets/1x/" .. file
    local f = love and love.filesystem
    if f and f.getInfo then
        local t3x = path:gsub("%.[^./]+$", "") .. ".t3x"
        if not (f.getInfo(path, "file") or f.getInfo(t3x, "file")) then
            error(("%s '%s': %s '%s' not found in assets/1x (the 3DS loads %s)"):format(
                what, key, field, file, t3x:match("[^/]+$")), 0)
        end
    end
    local sprite_key = "mod:" .. mod.prefix .. ":" .. file
    if not SMODS.Sprites[sprite_key] then
        SMODS.Sprites[sprite_key] = { path = path, mod = mod }
        mod.registered.sprites[#mod.registered.sprites + 1] = sprite_key
    end
    return sprite_key
end

--- The file behind a sprite key, or nil when the key is not a mod's.
function SMODS.sprite_path(sprite_key)
    local sprite = SMODS.Sprites[sprite_key]
    return sprite and sprite.path or nil
end

--- The sprite key a `pos` names, or nil for a vanilla atlas position.
function SMODS.sprite_key(atlas_name, index)
    if atlas_name == SMODS.MOD_ATLAS and type(index) == "string" then return index end
    return nil
end

--- A mod image kept by this module, for the places that have no sprite cache of their own
--- (voucher art). Loaded on first use; a file that will not load is reported once.
function SMODS.image(sprite_key)
    local sprite = SMODS.Sprites[sprite_key]
    if not sprite then return nil end
    if sprite.image or sprite.load_error then return sprite.image end
    if not (love and love.graphics and love.graphics.newImage) then return nil end
    local ok, img = pcall(love.graphics.newImage, sprite.path)
    if ok and img then
        sprite.image = img
    else
        sprite.load_error = tostring(img)
        SMODS.report_runtime_error(sprite.mod, ("image %s failed to load: %s"):format(sprite.path, sprite.load_error))
    end
    return sprite.image
end

--- Steamodded's atlases are not how this port stores art: every card is its own image.
function SMODS.Atlas()
    error("SMODS.Atlas isn't supported on 3DS: give each card its own image with "
        .. "sprite = \"Name.png\" (see MODDING.md)", 2)
end

local function no_atlas(t, what)
    if t.atlas ~= nil or t.pos ~= nil then
        error(("%s '%s': atlas/pos aren't supported on 3DS; give it its own image with "
            .. "sprite = \"Name.png\""):format(what, tostring(t.key)), 0)
    end
end

--------------------------------------------------------------------------------
-- Card helpers mods call on playing cards
--------------------------------------------------------------------------------

--- Steamodded reads playing cards through methods and a `base` table. These answer from the
--- port's `card_data`, and `refresh_card_view` keeps `base` / `debuff` current for each context.
local function install_card_methods()
    if not Card or Card._smods_methods then return end
    Card._smods_methods = true
    function Card:get_id()
        local data = self.card_data or {}
        return tonumber(data.rank) or 0
    end
    function Card:is_face()
        local r = self:get_id()
        return (r >= 11 and r <= 13) or (G and G.hasJoker and G:hasJoker("j_pareidolia")) == true
    end
    function Card:is_suit(suit)
        local data = self.card_data or {}
        if data.enhancement == "stone" then return false end
        if data.enhancement == "wild" then return true end
        return JokerEffects.is_suit(data.suit, suit)
    end
end
SMODS.install_card_methods = install_card_methods

local function refresh_card_view(node)
    if type(node) ~= "table" then return node end
    local data = node.card_data or {}
    node.base = node.base or {}
    node.base.suit = data.suit
    node.base.id = tonumber(data.rank)
    node.base.nominal = tonumber(data.chips) or node.base.nominal
    node.debuff = node.debuffed == true or node.debuffed_for_scoring == true
    return node
end

local function card_views(list)
    local out = {}
    for i, node in ipairs(type(list) == "table" and list or {}) do out[i] = refresh_card_view(node) end
    return out
end

--------------------------------------------------------------------------------
-- Calculate: port events -> Steamodded contexts
--------------------------------------------------------------------------------

--- Which Steamodded context flag each of the port's joker events raises. `card_played` and
--- `card_held` are both `context.individual`, told apart by `cardarea` as in Steamodded.
local EVENT_CONTEXT = {
    on_hand_played = "before",
    card_played = "individual_play",
    card_held = "individual_hand",
    on_hand_scored = "joker_main",
    on_hand_after = "after",
    on_round_end = "end_of_round",
    on_discard = "discard",
    on_pre_discard = "pre_discard",
    on_blind_selected = "setting_blind",
    on_round_begin = "first_hand_drawn",
    on_joker_sold = "selling_card",
    on_shop_reroll = "reroll_shop",
    on_booster_open = "open_booster",
    on_booster_skip = "skipping_booster",
    on_consumable_used = "using_consumeable",
    on_shop_buy = "buying_card",
    on_destroy = "remove_playing_cards",
    on_cards_added_to_deck = "playing_card_added",
    on_shop_enter = "starting_shop",
    on_shop_exit = "ending_shop",
    on_blind_skipped = "skip_blind",
    on_blind_defeated = "blind_defeated",
    on_ante_change = "ante_change",
    on_hand_drawn = "hand_drawn",
    on_joker_added = "card_added",
    on_tag_added = "tag_added",
    on_hand_final = "final_scoring_step",
    on_joker_type_destroyed = "joker_type_destroyed",
    on_money_altered = "money_altered",
    on_card_debuffed = "debuff_card",
    on_press_play = "press_play",
    on_blind_disabled = "blind_disabled",
    on_setting_ability = "setting_ability",
    on_hand_level_up = "level_up_hand",
    on_game_over = "game_over",
    on_money_gain = "money_transform",
}
SMODS.EVENT_CONTEXT = EVENT_CONTEXT

--- `next(context.poker_hands["Straight"])` is how Steamodded asks whether a hand contains a
--- type. Contained types map to a non-empty list; anything else reads as an empty one.
local EMPTY = {}
local poker_hands_meta = { __index = function() return EMPTY end }
local function poker_hands_for(ctx)
    local out = setmetatable({}, poker_hands_meta)
    if type(ctx.contains_hand_types) == "table" then
        for name, yes in pairs(ctx.contains_hand_types) do
            if yes then out[name] = { true } end
        end
    end
    if type(ctx.hand_type) == "string" then out[ctx.hand_type] = { true } end
    return out
end

--- The Steamodded context for one port event. `context.port` is the raw event table, for mods
--- that want something the translation does not carry.
function SMODS.build_context(event_name, ctx, joker)
    ctx = type(ctx) == "table" and ctx or {}
    local kind = EVENT_CONTEXT[event_name]
    local c = {
        event = event_name,
        port = ctx,
        blueprint = ctx.blueprint,
        blueprint_card = ctx.blueprint_card,
        main_eval = true,
        game_over = false,
    }
    if kind == "individual_play" then
        c.individual = true
        c.cardarea = (G and G.play) or SMODS.PLAY
        c.other_card = refresh_card_view(ctx.card_node)
    elseif kind == "individual_hand" then
        c.individual = true
        c.cardarea = G and G.hand
        c.other_card = refresh_card_view(ctx.card_node)
    elseif kind then
        c[kind] = true
        c.cardarea = G and G.jokers
    end
    if kind == "discard" then c.other_card = refresh_card_view(ctx.card_node) end
    if kind == "selling_card" then
        c.card = ctx.joker or ctx.consumable
        c.selling_self = ctx.joker ~= nil and ctx.joker == joker
    end
    -- The destroyed Joker itself, the way `selling_card` hands over the sold one: mods
    -- compare `context.card` against their own card to tell their own end from another's.
    if kind == "joker_type_destroyed" then c.card = ctx.joker end
    if kind == "money_altered" then
        c.amount = tonumber(ctx.amount) or 0
        c.from_shop = ctx.from_shop == true
    end
    if kind == "debuff_card" then
        c.card = refresh_card_view(ctx.card_node)
        c.permanent = ctx.permanent == true
    end
    if kind == "blind_disabled" then c.blind = ctx.blind end
    if kind == "setting_ability" then
        c.other_card = refresh_card_view(ctx.card_node)
        c.old = ctx.old
        c.unchanged = ctx.unchanged == true
    end
    if kind == "end_of_round" and ctx.game_over ~= nil then c.game_over = ctx.game_over == true end
    -- The game-over evaluation is Steamodded's end-of-round pass with the flag set:
    -- `game_over` arrives as the kind itself, and `saved = true` in a return is what
    -- `SMODS.game_over_saved` reads (the apply path never sees this event).
    if kind == "game_over" then c.end_of_round = true end
    -- A hand levelled, from any source: the flag carries the hand's NAME, Steamodded's
    -- shape (`context.level_up_hand == "Pair"`), with the new level and the delta.
    if kind == "level_up_hand" then
        c.level_up_hand = ctx.hand_name
        c.level = tonumber(ctx.level)
        c.amount = tonumber(ctx.amount)
    end
    -- A money gain about to land, offered to held Jokers for transformation:
    -- `amount` is the current (possibly already transformed) gain.
    if kind == "money_transform" then
        c.amount = tonumber(ctx.amount) or 0
        c.from_shop = ctx.from_shop == true
    end
    -- Contexts whose flag carries a value rather than `true`.
    if kind == "hand_drawn" then c.hand_drawn = card_views(ctx.drawn_cards) end
    if kind == "card_added" then c.card = ctx.joker end
    if kind == "tag_added" then c.tag_added = ctx.tag end
    if kind == "ante_change" then
        c.ante_change = tonumber(ctx.ante_change) or 0
        c.ante_end = ctx.ante_end == true
    end
    -- Set while a `retrigger_joker_check` pass is repeating this Joker's effect.
    c.retrigger_joker = ctx.retrigger_joker
    c.scoring_name = ctx.hand_type
    c.poker_hands = poker_hands_for(ctx)
    c.scoring_hand = card_views(ctx.cards)
    c.full_hand = card_views(ctx.full_hand or ctx.played_cards)
    return c
end

local function first_number(t, ...)
    for i = 1, select("#", ...) do
        local v = tonumber(t[select(i, ...)])
        if v then return v end
    end
    return nil
end

--- Like `first_number`, but a Big value counts as present and passes through
--- untouched (Tier 3e): the score fields of a return may carry one, and
--- `tonumber(Big)` is nil, so the number-only reader would silently drop it.
local function first_value(t, ...)
    for i = 1, select("#", ...) do
        local raw = t[select(i, ...)]
        if type(raw) == "number" or Big.is_big(raw) then return raw end
        local v = tonumber(raw)
        if v then return v end
    end
    return nil
end

--- `level_up` in a return: level the hand being scored, Steamodded semantics. The stored
--- level rises through the game's own upgrade path (`Game:upgrade_hand_level_at_index`, what
--- a Planet walks); when the levelled hand is the one on the table, the running totals also
--- gain the level's delta, so contributions Jokers already made are kept rather than
--- overwritten by the new base. Outside a scoring context the level still rises and no
--- totals move. Returns whether a level was gained.
local function apply_return_level_up(ctx, value)
    local n = value == true and 1 or math.floor(tonumber(value) or 0)
    if n <= 0 or type(ctx) ~= "table" or not (G and G.upgrade_hand_level_at_index) then return false end
    local idx = tonumber(ctx.hand_index)
    if not idx and type(ctx.hand_type) == "string" and type(G.handlist) == "table" then
        for i, name in ipairs(G.handlist) do
            if name == ctx.hand_type then idx = i break end
        end
    end
    idx = idx or tonumber(G.selectedHand)
    if not idx then return false end
    local current = tonumber(G.selectedHand) == idx and ctx.chips ~= nil and ctx.mult ~= nil
    local before_chips = current and Totals.read(G.selectedHandChips, 0) or 0
    local before_mult = current and Totals.read(G.selectedHandMult, 1) or 1
    local leveled = false
    for _ = 1, n do
        if G:upgrade_hand_level_at_index(idx) then leveled = true end
    end
    if not leveled then return false end
    JokerEffects.mark_effect_applied(ctx)
    if current then
        local after_chips = Totals.read(G.selectedHandChips, 0)
        local after_mult = Totals.read(G.selectedHandMult, 1)
        local d_chips = (Big.is_big(after_chips) or Big.is_big(before_chips))
            and Big.sub(after_chips, before_chips) or (after_chips - before_chips)
        local d_mult = (Big.is_big(after_mult) or Big.is_big(before_mult))
            and Big.sub(after_mult, before_mult) or (after_mult - before_mult)
        ctx.chips = Big.add_values(Totals.read(ctx.chips, 0), d_chips)
        ctx.mult = Big.add_values(Totals.read(ctx.mult, 0), d_mult)
    end
    return true
end
SMODS.apply_return_level_up = apply_return_level_up

--- Apply what `calculate` returned, through the same helpers vanilla Jokers use: the popup, the
--- sound and the trigger bookkeeping that paces scoring all come for free. The total fields
--- land in Steamodded's order: chips, mult, x_mult, e_mult, e_chips, x_chips, swap, balance,
--- level_up, dollars.
--- Big values for mods (Tier 3e; see MODDING.md "Big numbers"). Totals promote
--- on their own when an effect overflows the double range; these exist so a mod
--- can construct, test, convert and print a Big it holds itself.
SMODS.big = function(m, e) return Big.from(m, e) end
SMODS.big_pow = function(base, exponent) return Big.pow_values(base, exponent) end
SMODS.is_big = function(v) return Big.is_big(v) end
--- The value as a plain double — explicitly lossy: past the double range this
--- is ±inf, the value the run would have had without Big.
SMODS.big_to_number = function(v) return Big.to_number(v) end
SMODS.big_format = function(v)
    if Big.is_big(v) then return Big.format(v) end
    return tostring(v)
end
--- Three-way compare across the plain/Big boundary (-1/0/1). Lua 5.1 never
--- fires comparison metamethods between a table and a number, so a mod
--- comparing `context.port.chips` against a plain threshold needs this.
SMODS.big_cmp = function(a, b) return Totals.cmp(a, b) end

function SMODS.apply_return(joker, ctx, ret, kind)
    if type(ret) ~= "table" then return end
    local chips = first_value(ret, "chips", "chip_mod", "h_chips")
    local mult = first_value(ret, "mult", "mult_mod", "h_mult")
    local xmult = first_value(ret, "xmult", "x_mult", "Xmult", "Xmult_mod", "x_mult_mod")
    local emult = first_value(ret, "emult", "e_mult", "Emult")
    local echips = first_value(ret, "echips", "e_chips", "Echips")
    local xchips = first_value(ret, "xchips", "x_chips", "Xchips")
    local xlogchips = first_value(ret, "xlog_chips", "xlogchips", "Xlog_chips")
    local dollars = first_number(ret, "dollars", "p_dollars")
    if chips and Totals.cmp(chips, 0) ~= 0 then JokerEffects.add_chips(ctx, chips) end
    if mult and Totals.cmp(mult, 0) ~= 0 then JokerEffects.add_mult(ctx, mult) end
    if xmult and Totals.cmp(xmult, 1) ~= 0 then JokerEffects.mul_mult(ctx, xmult) end
    if emult and Totals.cmp(emult, 1) ~= 0 then JokerEffects.pow_mult(ctx, emult) end
    if echips and Totals.cmp(echips, 1) ~= 0 then JokerEffects.pow_chips(ctx, echips) end
    if xchips and Totals.cmp(xchips, 1) ~= 0 then JokerEffects.mul_chips(ctx, xchips) end
    if xlogchips then JokerEffects.log_chips(ctx, xlogchips) end
    if ret.swap then JokerEffects.swap_totals(ctx) end
    if ret.balance then JokerEffects.balance_totals(ctx, type(ret.balance) == "number" and ret.balance or nil) end
    if ret.level_up then apply_return_level_up(ctx, ret.level_up) end
    if dollars and dollars ~= 0 then
        if kind == "end_of_round" then
            JokerEffects.add_round_win_money(ctx, joker, dollars)
        else
            JokerEffects.add_money(ctx, dollars)
        end
    end
    -- A bare message ("Upgraded!", "Safe!") still counts as the Joker doing something.
    -- swap / balance / level_up land no numeric popup of their own, so a message returned
    -- alongside them still shows; the fields above each raise one and keep the old rule.
    if ret.message and not (chips or mult or xmult or emult or echips or xchips or xlogchips or dollars) then
        if Popup and Top and ctx.VT then
            local p = Popup()
            p:spawn(tostring(ret.message), "Nope",
                ctx.VT.x + ctx.VT.w * 0.5 * (ctx.VT.scale or 1),
                ctx.VT.y + ctx.VT.h * 0.5 * (ctx.VT.scale or 1))
            Top:addPopup(p)
        end
        JokerEffects.mark_effect_applied(ctx)
    end
    if type(ret.extra) == "table" then SMODS.apply_return(joker, ctx, ret.extra, kind) end
end

--- Retrigger fields in a `calculate` return: `repetitions = n` repeats this Joker, and
--- `retrigger_joker = <a held Joker>` (or `true`, meaning this Joker) repeats that one.
--- Steamodded honours both from any effect context; `apply_return` used to drop them. The
--- extra passes run through the game's own retrigger path (`Game:_apply_joker_retrigger`),
--- so they are announced with "Again!" and hear `post_trigger` like the passes
--- `retrigger_joker_check` grants -- except they run on the spot, inside this Joker's own
--- beat, rather than being queued for a beat of their own. Two bounds keep a bad return
--- from hanging the run: a pass already running as a retrigger never retriggers (the same
--- rule the game applies to `retrigger_joker_check`), and one return buys at most
--- MAX_RETURN_RETRIGGERS extra passes.
local MAX_RETURN_RETRIGGERS = 100
local function retrigger_return_passes(joker, ctx, ret)
    if type(ret) ~= "table" or ctx.retrigger_joker then return end
    local target = ret.retrigger_joker
    if target == true then target = joker end
    local reps = math.max(0, math.floor(tonumber(ret.repetitions) or 0))
    if target ~= nil and reps == 0 then reps = 1 end
    if reps == 0 then return end
    if type(target) ~= "table" then
        target = joker
    elseif target ~= joker then
        local held = false
        for _, j in ipairs(G and type(G.jokers) == "table" and G.jokers or EMPTY) do
            if j == target then held = true break end
        end
        if not held then return end
    end
    if not (G and G._apply_joker_retrigger) then return end
    for _ = 1, math.min(reps, MAX_RETURN_RETRIGGERS) do
        G:_apply_joker_retrigger(target, joker, ctx)
    end
end

--- The `JokerEffects` implementation for one mod Joker.
local function build_effect(center, def)
    local mod = center.mod
    local impl = {}

    function impl.matches_trigger(_, event_name)
        if not EVENT_CONTEXT[event_name] then return false end
        if type(center.calculate) == "function" then return true end
        return event_name == "on_round_end" and type(center.calc_dollar_bonus) == "function"
    end

    function impl.apply_effect(joker, ctx)
        local event_name = ctx.event_name or ctx.event
        local kind = EVENT_CONTEXT[event_name]
        if not kind then return end
        if type(center.calculate) == "function" then
            local ret = SMODS.call(mod, center.calculate, center, joker,
                SMODS.build_context(event_name, ctx, joker))
            SMODS.apply_return(joker, ctx, ret, kind)
            retrigger_return_passes(joker, ctx, ret)
        end
        -- Steamodded pays this at cash-out; the port's cash-out is the round-end payout table.
        if kind == "end_of_round" and not ctx.blueprint and type(center.calc_dollar_bonus) == "function" then
            local bonus = tonumber(SMODS.call(mod, center.calc_dollar_bonus, center, joker))
            if bonus and bonus > 0 then JokerEffects.add_round_win_money(ctx, joker, bonus) end
        end
    end

    --- Money transformation (Bunco's Fiendish seat): asked with
    --- `context.money_transform` and the gain in `context.amount`; an `amount`
    --- field in the return replaces the gain. Anything else leaves it alone.
    function impl.transform_money(joker, amount, raw)
        if type(center.calculate) ~= "function" then return nil end
        raw = type(raw) == "table" and raw or {}
        raw.amount = amount
        local ret = SMODS.call(mod, center.calculate, center, joker,
            SMODS.build_context("on_money_gain", raw, joker))
        if type(ret) == "table" and tonumber(ret.amount) then
            return math.floor(tonumber(ret.amount))
        end
        return nil
    end

    --- The game-over question: asked with `context.game_over` (and `end_of_round`)
    --- when a lost blind would end the run; `saved = true` in the return (or in a
    --- nested `extra`) rescues it. The Joker's own consequences are its own
    --- business -- Mr. Bones spends itself in the engine, a mod spends itself
    --- through the ordinary destroy/sell contexts.
    function impl.game_over_save(joker, raw)
        if type(center.calculate) ~= "function" then return false end
        local ret = SMODS.call(mod, center.calculate, center, joker,
            SMODS.build_context("on_game_over", raw or {}, joker))
        local function has_saved(r)
            if type(r) ~= "table" then return false end
            if r.saved == true then return true end
            return has_saved(r.extra)
        end
        return has_saved(ret)
    end

    --- Retriggers: Steamodded asks with `context.repetition` and reads `repetitions` back.
    function impl.query_retrigger(joker, rctx)
        if type(center.calculate) ~= "function" or type(rctx) ~= "table" then return 0 end
        local c = {
            repetition = true,
            cardarea = rctx.held and (G and G.hand) or ((G and G.play) or SMODS.PLAY),
            other_card = refresh_card_view(rctx.card_node or rctx.retrigger_card),
            blueprint = rctx.blueprint,
            blueprint_card = rctx.blueprint_card,
            port = rctx,
        }
        local ret = SMODS.call(mod, center.calculate, center, joker, c)
        return type(ret) == "table" and math.max(0, math.floor(tonumber(ret.repetitions) or 0)) or 0
    end

    --- A port extension: a chance roll just succeeded (`Game:chance_triggers`). Asked with
    --- `context.probability_success`, it reads `repetitions` back like `context.repetition`.
    function impl.query_probability_retrigger(joker, pctx)
        if type(center.calculate) ~= "function" or type(pctx) ~= "table" then return 0 end
        local c = {
            probability_success = true,
            identifier = pctx.key,
            numerator = pctx.numerator,
            denominator = pctx.denominator,
            cardarea = G and G.jokers,
            blueprint = pctx.blueprint,
            blueprint_card = pctx.blueprint_card,
            port = pctx,
        }
        local ret = SMODS.call(mod, center.calculate, center, joker, c)
        return type(ret) == "table" and math.max(0, math.floor(tonumber(ret.repetitions) or 0)) or 0
    end

    return impl
end

--------------------------------------------------------------------------------
-- Contexts asked outside an event: retriggers, post_trigger, probability
--------------------------------------------------------------------------------

--- Whether any held Joker is a mod's. Every helper below is a no-op without one, which keeps
--- them free in a vanilla run (they sit on paths that run per trigger and per roll).
local function holding_mod_joker()
    for _, j in ipairs(G and type(G.jokers) == "table" and G.jokers or EMPTY) do
        if j and j.def and j.def.smods then return true end
    end
    return false
end

--- Ask each held Joker that runs mod code one context, left to right. Blueprint and Brainstorm
--- answer for the Joker they copy, with `context.blueprint` set, as in Steamodded. `make()`
--- builds a fresh context per Joker, since a mod may write to it; `each(joker, ret)` gets every
--- table returned, `joker` being the one in the slot.
function SMODS.ask_jokers(make, each)
    if not (G and G._collect_jokers_in_slot_order) or not holding_mod_joker() then return end
    for _, j in ipairs(G:_collect_jokers_in_slot_order()) do
        local id = j.def and j.def.id
        local source = j
        if id == "j_blueprint" or id == "j_brainstorm" then source = JokerEffects.resolve_copy_target(j) end
        local center = type(source) == "table" and source.def and source.def.smods
        if center and type(center.calculate) == "function" then
            local c = make()
            c.cardarea = c.cardarea or (G and G.jokers)
            if source ~= j then
                c.blueprint = true
                c.blueprint_card = j
            end
            local ret = SMODS.call(center.mod, center.calculate, center, source, c)
            if type(ret) == "table" then each(j, ret) end
        end
    end
end

--- A floating message over a Joker, as a bare `message` return raises.
function SMODS.joker_message(joker, text)
    local vt = joker and joker.VT
    if not (vt and text and Popup and Top) then return end
    local p = Popup()
    p:spawn(tostring(text), "Nope", vt.x + vt.w * 0.5 * (vt.scale or 1), vt.y + vt.h * 0.5 * (vt.scale or 1))
    Top:addPopup(p)
end

--- `context.retrigger_joker_check`: `joker` just triggered on the event in `ctx`. Returns one
--- entry per extra pass, naming the Joker that asked for it. `context.other_card` is the Joker
--- that triggered and `context.other_context` the context it triggered in.
function SMODS.joker_retriggers(joker, ctx)
    local out = {}
    if not holding_mod_joker() then return out end
    local other = SMODS.build_context(ctx.event_name, ctx, joker)
    SMODS.ask_jokers(function()
        return { retrigger_joker_check = true, other_card = joker, other_context = other }
    end, function(j, ret)
        for _ = 1, math.max(0, math.floor(tonumber(ret.repetitions) or 0)) do out[#out + 1] = j end
    end)
    return out
end

--- `context.post_trigger`: `joker` just triggered. What each Joker returns is applied as if it
--- had triggered on the same event, its popup over itself.
function SMODS.post_trigger(joker, ctx)
    if not holding_mod_joker() then return end
    local other = SMODS.build_context(ctx.event_name, ctx, joker)
    local kind = EVENT_CONTEXT[ctx.event_name]
    SMODS.ask_jokers(function()
        return { post_trigger = true, other_card = joker, other_context = other }
    end, function(j, ret)
        local vt = ctx.VT
        ctx.VT = j.VT
        SMODS.apply_return(j, ctx, ret, kind)
        ctx.VT = vt
    end)
end

--- Steamodded's `mod_probability` pass, then its `fix_probability` pass, over one roll's odds.
--- Each Joker sees the odds as the ones before it left them and may return new
--- `numerator` / `denominator`. `identifier` names the roll (the vanilla RNG key for the
--- game's own rolls); `trigger_obj` is the mod's, nil for the game's.
function SMODS.modify_probability(trigger_obj, identifier, numerator, denominator)
    if not holding_mod_joker() then return numerator, denominator end
    for _, flag in ipairs({ "mod_probability", "fix_probability" }) do
        SMODS.ask_jokers(function()
            return { [flag] = true, trigger_obj = trigger_obj, identifier = identifier,
                numerator = numerator, denominator = denominator }
        end, function(_, ret)
            numerator = tonumber(ret.numerator) or numerator
            denominator = tonumber(ret.denominator) or denominator
        end)
    end
    return numerator, denominator
end

--- `context.pseudorandom_result`: a roll has landed (`result` is whether it hit). A returned
--- `message` floats over the Joker.
function SMODS.probability_result(trigger_obj, identifier, result, numerator, denominator)
    if not holding_mod_joker() then return end
    SMODS.ask_jokers(function()
        return { pseudorandom_result = true, result = result, trigger_obj = trigger_obj,
            identifier = identifier, numerator = numerator, denominator = denominator }
    end, function(j, ret)
        if ret.message then SMODS.joker_message(j, ret.message) end
    end)
end

--------------------------------------------------------------------------------
-- Tooltips: loc_txt + loc_vars, with Steamodded's {C:...} markup
--------------------------------------------------------------------------------

--- Steamodded colour names onto the tooltip palette (`TooltipDraw.tooltip_color_by_key`).
local COLOUR_KEYS = {
    mult = "MULT", red = "RED", chips = "CHIPS", blue = "CHIPS", green = "CHANCE",
    attention = "IMPORTANT", orange = "IMPORTANT", money = "MONEY", gold = "MONEY",
    yellow = "MONEY", purple = "PURPLE", tarot = "PURPLE", dark_edition = "PURPLE",
    legendary = "PURPLE", planet = "CHIPS", spectral = "CHIPS", edition = "PURPLE",
}

--- `{C:mult}`, `{X:mult,C:white}`, `{C:inactive}` ... `{}` -> colour for the text that follows.
local function colour_for_modifiers(spec)
    local c, x
    for part in tostring(spec):gmatch("[^,]+") do
        local k, v = part:match("^%s*(%a+)%s*:%s*([%w_]+)%s*$")
        if k == "C" then c = v elseif k == "X" then x = v end
    end
    if c and c ~= "white" and COLOUR_KEYS[c] then return COLOUR_KEYS[c] end
    if x and COLOUR_KEYS[x] then return COLOUR_KEYS[x] end
    return nil
end

--- Steamodded's language codes are the game's, except English.
local STEAMODDED_CODE = { en = "en-us" }

--- `loc_txt` for one language. A mod may write `loc_txt = { name, text }` (one language), or one
--- table per language as Steamodded allows: `loc_txt = { ["en-us"] = {...}, zh_CN = {...} }`.
local function loc_for(loc, language)
    if type(loc) ~= "table" then return nil end
    if loc.name ~= nil or loc.text ~= nil then return loc end
    return loc[STEAMODDED_CODE[language] or language] or loc[language] or loc["en-us"] or loc.default
end
SMODS.loc_for = loc_for

--- The languages a per-language `loc_txt` names, other than English.
local function other_languages(loc)
    local out = {}
    if type(loc) ~= "table" or loc.name ~= nil or loc.text ~= nil then return out end
    for code, entry in pairs(loc) do
        if type(entry) == "table" and code ~= "en-us" and code ~= "en" and code ~= "default" then
            out[#out + 1] = code
        end
    end
    return out
end

--- One tooltip line from one `loc_txt.text` entry: `#n#` filled from `vars`, then split into
--- coloured segments.
function SMODS.format_line(text, vars)
    text = tostring(text or ""):gsub("#(%d+)#", function(n)
        local v = vars and vars[tonumber(n)]
        if v == nil then return "#" .. n .. "#" end
        return tostring(v)
    end)
    local segments, colour, pos = {}, nil, 1
    while pos <= #text do
        local s, e, spec = text:find("{([^}]*)}", pos)
        local chunk = text:sub(pos, (s or #text + 1) - 1)
        if chunk ~= "" then segments[#segments + 1] = { text = chunk, color_key = colour } end
        if not s then break end
        colour = colour_for_modifiers(spec)
        pos = e + 1
    end
    if #segments == 0 then segments[1] = { text = " " } end
    return { segments = segments }
end

local function tooltip_lines_for(center)
    return function(joker)
        local loc = loc_for(center.loc_txt, I18N and I18N.get_language() or "en") or {}
        local text = loc.text
        if type(text) == "string" then text = { text } end
        if type(text) ~= "table" then return nil end
        local vars = {}
        if type(center.loc_vars) == "function" then
            local ret = SMODS.call(center.mod, center.loc_vars, center, {}, joker)
            if type(ret) == "table" and type(ret.vars) == "table" then vars = ret.vars end
        end
        local lines = {}
        for _, line in ipairs(text) do lines[#lines + 1] = SMODS.format_line(line, vars) end
        return lines
    end
end

--------------------------------------------------------------------------------
-- Rarities, suits and poker hands (Tier 2)
--------------------------------------------------------------------------------

--- Things mods register once and the game then treats as its own. All three live in
--- registries on SMODS (not in the game's tables) because mods load before the game
--- exists: `Game:set_globals` calls `SMODS.install_into_game` as it builds the tables
--- they extend (`G.C`, `handlist`, `hand_stats`), and a game built with nothing
--- registered is the vanilla game, untouched.

--- Custom rarities by full id (`<prefix>_<key>`) and by the numeric rarity their
--- Jokers carry. Vanilla keeps 1-4; customs take 5, 6, ... in registration order
--- (a rolled-back rarity's number is not reused, so a stale def can never silently
--- change rarity while its mod is off).
SMODS.Rarities = SMODS.Rarities or {}
SMODS.RarityByIndex = SMODS.RarityByIndex or {}
local next_rarity_index = 5

--- Custom suits by canonical name (the string a card's `card_data.suit` carries).
SMODS.Suits = SMODS.Suits or {}

--- Custom poker hands, strongest first, and by hand name (the `handlist` entry).
SMODS.PokerHands = SMODS.PokerHands or {}
SMODS.PokerHandByName = SMODS.PokerHandByName or {}

--- Where each vanilla hand sits on the strength scale `SMODS.PokerHand`'s `order`
--- speaks: Flush Five strongest, High Card weakest. A custom hand's `order` is
--- compared against these, both for its `handlist` place and for whether it takes
--- a play from the vanilla hand the cards made.
local VANILLA_HAND_ORDER = {
    ["Flush Five"] = 120, ["Flush House"] = 110, ["Five of a Kind"] = 100,
    ["Straight Flush"] = 90, ["Four of a Kind"] = 80, ["Full House"] = 70,
    ["Flush"] = 60, ["Straight"] = 50, ["Three of a Kind"] = 40,
    ["Two Pair"] = 30, ["Pair"] = 20, ["High Card"] = 10,
}

--- The strength of one hand name: a registered custom hand's `order`, else vanilla's.
function SMODS.hand_order(name)
    local center = SMODS.PokerHandByName[name]
    if center then return center.order end
    return VANILLA_HAND_ORDER[name] or 0
end

--- A colour the way mods write it -- `"#FE5F55"`, `"FE5F55"` or `{ r, g, b, a? }` in
--- 0..1 -- as the `{ r, g, b, a }` table the game's palettes carry.
local function parse_colour(value, what, key, field)
    if value == nil then return nil end
    if type(value) == "string" then
        local hex = value:gsub("^#", "")
        check(#hex == 6 and hex:match("^%x+$") ~= nil,
            ("%s '%s': %s must be a hex colour like \"#FE5F55\""):format(what, key, field))
        return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255, 1 }
    end
    if type(value) == "table" then
        local r, g, b = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
        check(r ~= nil and g ~= nil and b ~= nil,
            ("%s '%s': %s must be a hex string or { r, g, b }"):format(what, key, field))
        return { r, g, b, tonumber(value[4]) or 1 }
    end
    error(("%s '%s': %s must be a hex string or { r, g, b }"):format(what, key, field), 0)
end

--- Register the display name of a suit or poker hand with I18N, for English and for
--- every other language the `loc_txt` carries, the way card names are registered.
--- The strings are recorded on the mod, so rollback takes them away again.
local function register_name_strings(mod, kind, internal, loc)
    if not (I18N and I18N.add_strings) or type(loc) ~= "table" then return end
    local function add(code, name)
        if type(name) ~= "string" then return end
        local strings = { [kind .. "." .. internal:lower():gsub("[^%w]+", "_")] = name }
        local keys = {}
        for k in pairs(strings) do keys[#keys + 1] = k end
        I18N.add_strings(code, strings)
        mod.registered.strings[#mod.registered.strings + 1] = { language = code, keys = keys }
    end
    local english = loc_for(loc, "en")
    if english then add("en-us", english.name) end
    for _, code in ipairs(other_languages(loc)) do
        local entry = loc[code]
        if type(entry) == "table" then add(code, entry.name) end
    end
end

--- `SMODS.Rarity { key, loc_txt, badge_colour, weight }`: a rarity of this mod's own.
--- A Joker declares it by name -- `rarity = "<prefix>_<key>"`, or just `"<key>"` from
--- the same mod (or the table `SMODS.Rarity` returned). It gets the next numeric
--- rarity after Legendary, so every place that compares rarities numerically (random
--- rolls by rarity, the collection) treats it as a rarity like any other.
---
--- `badge_colour` is the colour of the rarity badge on the Joker's tooltip; without
--- one the badge wears the last vanilla colour. `weight` is how much of the shop the
--- rarity takes, in the units of the vanilla roll (Common 70, Uncommon 25, Rare 5
--- out of 100): the default 3 makes it about as present as a second Rare. Weight 0
--- keeps it out of the shop roll entirely (its Jokers can still be created directly).
--- Legendary stays out of the shop, as vanilla has it; a custom rarity is in the
--- roll whenever it has Jokers and a positive weight.
function SMODS.Rarity(t)
    local mod = need_mod("SMODS.Rarity")
    check(type(t) == "table", "SMODS.Rarity expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.Rarity needs a 'key' of letters, digits and underscores")
    local id = mod.prefix .. "_" .. t.key
    check(SMODS.Rarities[id] == nil, "Rarity '" .. t.key .. "' is defined twice (id " .. id .. ")")
    local weight = t.weight == nil and 3 or tonumber(t.weight)
    check(weight ~= nil and weight >= 0, "Rarity '" .. t.key .. "': weight must be a number >= 0")
    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = id, key = t.key, mod = mod,
        name = tostring(loc.name or t.name or t.key),
        colour = parse_colour(t.badge_colour or t.colour, "Rarity", t.key, "badge_colour"),
        weight = weight,
        index = next_rarity_index,
    }
    next_rarity_index = next_rarity_index + 1
    SMODS.Rarities[id] = entry
    SMODS.RarityByIndex[entry.index] = entry
    mod.registered.rarities = mod.registered.rarities or {}
    mod.registered.rarities[#mod.registered.rarities + 1] = id
    t.mod = mod
    t.original_key = t.key
    t.key = id
    t.index = entry.index
    return t
end

--- What a Joker's `rarity` field means: 1-4, a vanilla name, or a custom rarity
--- (its full id, its key from the same mod, or the registered table). Anything else
--- is a load error naming the field.
local function resolve_rarity(mod, key, value)
    if value == nil then return 1 end
    if type(value) == "number" then
        check(value >= 1 and value <= 4 and value % 1 == 0, "Joker '" .. key
            .. "': rarity must be 1-4 or the key of a rarity registered with SMODS.Rarity")
        return value
    end
    if type(value) == "string" then
        local vanilla = RARITY[value:lower()]
        if vanilla then return vanilla end
        local entry = SMODS.Rarities[value] or SMODS.Rarities[mod.prefix .. "_" .. value]
        if entry then return entry.index end
        error(("Joker '%s': unknown rarity '%s' (register it with SMODS.Rarity first, "
            .. "or use 1-4 / Common / Uncommon / Rare / Legendary)"):format(key, value), 0)
    end
    if type(value) == "table" and SMODS.Rarities[tostring(value.key or "")] then
        return SMODS.Rarities[value.key].index
    end
    error(("Joker '%s': rarity must be 1-4, a vanilla rarity name, or a rarity "
        .. "registered with SMODS.Rarity"):format(key), 0)
end

--- The tooltip badge line for a Joker whose rarity is a mod's, or nil. The badge
--- carries the rarity's own colour, which the tooltip draws ahead of the palette.
function SMODS.rarity_badge(def)
    local entry = def and SMODS.RarityByIndex[tonumber(def.rarity) or 0]
    if not entry then return nil end
    return { kind = "rarity_badge", text = entry.name, rarity = entry.index, colour = entry.colour }
end

local function rarity_has_jokers(index)
    for _, def in pairs(JOKER_DEFS) do
        if type(def) == "table" and tonumber(def.rarity) == index then return true end
    end
    return false
end

--- The shop's rarity roll, extended: with no custom rarities (or none with Jokers
--- and a weight) the vanilla target stands and no extra random is drawn. Otherwise
--- one more roll on its own stream stretches the vanilla 70/25/5 over
--- 100 + (custom weights), so a custom rarity takes its declared share and the
--- vanilla rarities keep their proportions between themselves.
function SMODS.shop_rarity_target(game, ante, append, vanilla_target)
    local customs = {}
    for _, entry in pairs(SMODS.Rarities) do
        if entry.weight > 0 and rarity_has_jokers(entry.index) then customs[#customs + 1] = entry end
    end
    if #customs == 0 then return vanilla_target end
    table.sort(customs, function(a, b) return a.index < b.index end)
    local total = 100
    for _, entry in ipairs(customs) do total = total + entry.weight end
    local x = game:random("rarity_custom" .. tostring(ante) .. (append or "sho")) * total
    if x < 100 then return vanilla_target end
    x = x - 100
    for _, entry in ipairs(customs) do
        x = x - entry.weight
        if x < 0 then return entry.index end
    end
    return vanilla_target
end

--- `SMODS.Suit { key, loc_txt, ui_colour, card_key, in_pool }`: a suit of this
--- mod's own. `key` is the suit itself: the string a card carries in
--- `card_data.suit` (one capitalised word, `"Stars"`), so
--- `Card:is_suit("Stars")`, flush counting and every suit check in the game see
--- it with no further work -- suit checks in this port compare names, and flush
--- detection counts cards per suit name. Cards of the suit are made with
--- `SMODS.add_card { set = "Playing", suit = "Stars" }` or by a consumable's
--- `suit_conv`; the standard deck stays the four vanilla suits.
---
--- The optional `in_pool(self, game)` gates the suit's one other way into play:
--- random playing-card fronts. While the gate passes, one front per rank in
--- the suit joins the pool `Game:_random_reference_playing_card_front` draws
--- from (Standard packs and shop playing cards), so gated suits stay out of
--- random creation until the mod opens the gate -- Bunco's exotic suits open
--- theirs the first time a Spectrum-family hand is scored. A suit with no
--- `in_pool` is always in the pool. The standard deck is never touched.
---
--- There is no art sheet for a mod suit: its cards draw on the Hearts row of the
--- deck sheets (the game's own fallback for a suit it has no row for), in the
--- suit's `ui_colour` wherever a suit is named in colour (tooltips). `card_key`
--- is accepted for Steamodded compatibility and stored; nothing here keys cards
--- by it.
function SMODS.Suit(t)
    local mod = need_mod("SMODS.Suit")
    check(type(t) == "table", "SMODS.Suit expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w]+$"),
        "SMODS.Suit needs a 'key' of letters, digits and underscores (the suit's name)")
    check(t.in_pool == nil or type(t.in_pool) == "function",
        "Suit '" .. t.key .. "': in_pool must be a function")
    local name = t.key:sub(1, 1):upper() .. t.key:sub(2)
    check(CardArt.suit_key(name) == nil, "Suit '" .. t.key .. "' is one of the four vanilla suits")
    check(SMODS.Suits[name] == nil, "Suit '" .. t.key .. "' is defined twice")
    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = mod.prefix .. "_" .. t.key, key = name, mod = mod,
        name = tostring(loc.name or t.name or name),
        colour = parse_colour(t.ui_colour or t.colour, "Suit", t.key, "ui_colour"),
        card_key = t.card_key,
        in_pool = t.in_pool,
    }
    SMODS.Suits[name] = entry
    mod.registered.suits = mod.registered.suits or {}
    mod.registered.suits[#mod.registered.suits + 1] = name
    register_name_strings(mod, "suit", name, t.loc_txt)
    t.mod = mod
    t.original_key = t.key
    t.key = entry.id
    return t
end

--- The extra fronts `Game:_random_reference_playing_card_front` deals from:
--- one per rank (2..Ace) for every registered suit whose `in_pool` gate passes
--- (a suit with no gate is always in). Sorted by suit name, so the pool's shape
--- depends only on which gates are open, never on registration or table order.
--- Empty when no suit is registered or every gate is shut -- the caller then
--- draws from exactly the vanilla 52, spending the same single random draw.
function SMODS.extra_playing_card_fronts(game)
    local names = {}
    for name, entry in pairs(SMODS.Suits) do
        if type(entry.in_pool) ~= "function" then
            names[#names + 1] = name
        elseif SMODS.call(entry.mod, entry.in_pool, entry, game) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local fronts = {}
    for _, name in ipairs(names) do
        for rank = 2, 14 do fronts[#fronts + 1] = { rank = rank, suit = name } end
    end
    return fronts
end

--- The canonical name of a suit a mod names (a vanilla suit or a registered one),
--- or nil. Case is forgiving the way the game's own suit reads are.
function SMODS.suit_name(suit)
    if type(suit) ~= "string" then return nil end
    local vanilla = CardArt.suit_key(suit)
    if vanilla then return vanilla end
    if SMODS.Suits[suit] then return suit end
    local c = suit:sub(1, 1):upper() .. suit:sub(2):lower()
    if SMODS.Suits[c] then return c end
    return nil
end

--- `SMODS.PokerHand { key, loc_txt, chips, mult, l_chips, l_mult, evaluate, order }`:
--- a poker hand of this mod's own. `key` is the hand's name -- the `handlist` entry,
--- what `context.scoring_name` reads and what a Planet levels by
--- (`config.hand_type = "Spectrum"`). The hand joins every game's `handlist`
--- (appended after High Card; see `SMODS.install_into_game` for why) with a
--- `hand_stats` entry of `chips`/`mult` at level 1 and `l_chips`/`l_mult` per
--- level, so Planets, the Run Info screen and hand levels treat it as a hand
--- like any other. `order` is its strength for contests: which of several
--- matching hands wins, and whether it takes a play from the vanilla hand the
--- cards made (the default 55 sits between Flush and Straight, where Bunco
--- puts Spectrum).
---
--- `evaluate(self, hand)` is asked about a play only when the hand outranks the
--- vanilla hand the cards made; it returns the scoring cards (a list of the hand's
--- own card views), `true` for all of them, or nil/empty for no match. The same
--- answer feeds `context.poker_hands`: a play whose cards satisfy `evaluate`
--- contains the hand, whatever it finally scores as.
function SMODS.PokerHand(t)
    local mod = need_mod("SMODS.PokerHand")
    check(type(t) == "table", "SMODS.PokerHand expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w ]+$") and t.key:match("%S"),
        "SMODS.PokerHand needs a 'key' naming the hand (letters, digits, underscores, spaces)")
    local name = t.key
    check(VANILLA_HAND_ORDER[name] == nil, "PokerHand '" .. name .. "' is a vanilla hand")
    check(SMODS.PokerHandByName[name] == nil, "PokerHand '" .. name .. "' is defined twice")
    check(type(t.evaluate) == "function", "PokerHand '" .. name .. "': evaluate must be a function")
    local loc = loc_for(t.loc_txt, "en") or {}
    local center = {
        key = name, mod = mod,
        name = tostring(loc.name or t.name or name),
        order = tonumber(t.order) or 55,
        chips = tonumber(t.chips) or 0,
        mult = tonumber(t.mult) or 0,
        l_chips = tonumber(t.l_chips) or 0,
        l_mult = tonumber(t.l_mult) or 0,
        evaluate = t.evaluate,
        visible = t.visible ~= false,
    }
    local pos = #SMODS.PokerHands + 1
    for i, other in ipairs(SMODS.PokerHands) do
        if other.order < center.order then pos = i break end
    end
    table.insert(SMODS.PokerHands, pos, center)
    SMODS.PokerHandByName[name] = center
    mod.registered.poker_hands = mod.registered.poker_hands or {}
    mod.registered.poker_hands[#mod.registered.poker_hands + 1] = name
    register_name_strings(mod, "hand", name, t.loc_txt)
    t.mod = mod
    return t
end

--- Whether `evaluate`'s answer means the hand matches, as the list of scoring
--- nodes it names (only nodes that are part of the play), or nil.
local function poker_hand_match(center, ordered)
    local ret = SMODS.call(center.mod, center.evaluate, center, card_views(ordered))
    if ret == true then return ordered end
    if type(ret) ~= "table" or #ret == 0 then return nil end
    local in_play = {}
    for _, node in ipairs(ordered) do in_play[node] = true end
    local nodes = {}
    for _, node in ipairs(ret) do
        if in_play[node] then nodes[#nodes + 1] = node end
    end
    if #nodes == 0 then return nil end
    return nodes
end

--- The custom hand that takes this play, if any: the strongest registered hand
--- that outranks the vanilla result and whose `evaluate` matches. Returns its
--- `handlist` index and the cards that score. Called from `Hand:calculate_play`
--- once the vanilla hand is known; with nothing registered it returns at once.
function SMODS.evaluate_poker_hands(ordered, vanilla_index)
    if #SMODS.PokerHands == 0 then return nil end
    local handlist = G and G.handlist
    if type(handlist) ~= "table" then return nil end
    local vanilla_order = SMODS.hand_order(handlist[vanilla_index or 0])
    for _, center in ipairs(SMODS.PokerHands) do
        if center.order > vanilla_order then
            for i, name in ipairs(handlist) do
                if name == center.key then
                    local nodes = poker_hand_match(center, ordered)
                    if nodes then return i, nodes end
                    break
                end
            end
        end
    end
    return nil
end

--- Registered hands a set of cards contains, for `context.poker_hands`: every
--- hand whose `evaluate` matches the cards, whatever the play scores as.
function SMODS.contained_poker_hands(nodes, contained)
    if #SMODS.PokerHands == 0 then return end
    for _, center in ipairs(SMODS.PokerHands) do
        if poker_hand_match(center, nodes) then contained[center.key] = true end
    end
end

--- Put everything registered into one game as `Game:set_globals` builds it: suit
--- and rarity colours into the palettes, and poker hands into `handlist` /
--- `hand_stats`. Idempotent -- a hand already listed is left where it is, so
--- re-running globals never duplicates one.
---
--- Hands APPEND after High Card rather than taking the place their `order` earns:
--- the engine names a play by its hand's position in this list (the evaluation
--- chain's indices are the vanilla twelve, hardcoded), so a hand inserted in the
--- middle would rename every vanilla hand below it. `order` still decides every
--- contest -- which custom hand wins, and whether one takes a play from the
--- vanilla hand -- it just does not order this list.
function SMODS.install_into_game(game)
    if type(game) ~= "table" then return end
    if type(game.C) == "table" then
        if type(game.C.SUITS) == "table" then
            for name, entry in pairs(SMODS.Suits) do
                if entry.colour then
                    game.C.SUITS[name] = entry.colour
                    if type(game.C.SO_1) == "table" then game.C.SO_1[name] = entry.colour end
                    if type(game.C.SO_2) == "table" then game.C.SO_2[name] = entry.colour end
                end
            end
        end
        if type(game.C.RARITY) == "table" then
            for index, entry in pairs(SMODS.RarityByIndex) do
                if entry.colour and game.C.RARITY[index] == nil then
                    game.C.RARITY[index] = entry.colour
                end
            end
        end
    end
    if type(game.handlist) == "table" and type(game.hand_stats) == "table" then
        for _, center in ipairs(SMODS.PokerHands) do
            local present = false
            for _, name in ipairs(game.handlist) do
                if name == center.key then present = true break end
            end
            if not present then
                game.handlist[#game.handlist + 1] = center.key
                game.hand_stats[#game.hand_stats + 1] = {
                    level = 1, base_chips = center.chips, base_mult = center.mult,
                    chips_per_level = center.l_chips, mult_per_level = center.l_mult,
                }
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Jokers
--------------------------------------------------------------------------------

--- `SMODS.Joker { key, loc_txt, config, rarity, cost, sprite, soul_sprite, negative_sprite,
--- loc_vars, calculate, in_pool, set_ability,
--- calc_dollar_bonus, add_to_deck, remove_from_deck, blueprint_compat, eternal_compat,
--- perishable_compat, unlocked, discovered }`. The Joker's id is `j_<prefix>_<key>`.
function SMODS.Joker(t)
    local mod = need_mod("SMODS.Joker")
    check(type(t) == "table", "SMODS.Joker expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.Joker needs a 'key' of letters, digits and underscores")
    local id = "j_" .. mod.prefix .. "_" .. t.key
    check(JOKER_DEFS[id] == nil, "Joker '" .. t.key .. "' is defined twice (id " .. id .. ")")

    local rarity = resolve_rarity(mod, t.key, t.rarity)
    local cost = tonumber(t.cost or 3)
    check(cost and cost >= 0, "Joker '" .. t.key .. "': cost must be a number")

    no_atlas(t, "Joker")
    for name, fn in pairs({ calculate = t.calculate, loc_vars = t.loc_vars,
        calc_dollar_bonus = t.calc_dollar_bonus, add_to_deck = t.add_to_deck,
        remove_from_deck = t.remove_from_deck, in_pool = t.in_pool, set_ability = t.set_ability }) do
        check(fn == nil or type(fn) == "function", "Joker '" .. t.key .. "': " .. name .. " must be a function")
    end

    -- The art: the card, the floating layer Legendaries have, and the Negative version. The PC
    -- game recolours a Negative card in a shader; the PICA200 cannot, so vanilla ships a separate
    -- negative image per Joker and a mod does the same. Without one, the plain art is used.
    local sprite = register_sprite(mod, t.sprite, "Joker", t.key, "sprite")
    local soul = t.soul_sprite ~= nil and register_sprite(mod, t.soul_sprite, "Joker", t.key, "soul_sprite") or nil
    local negative = t.negative_sprite ~= nil
        and register_sprite(mod, t.negative_sprite, "Joker", t.key, "negative_sprite") or nil

    local loc = loc_for(t.loc_txt, "en") or {}
    next_order = next_order + 1
    local def = {
        id = id,
        name = tostring(loc.name or t.name or t.key),
        order = next_order,
        unlocked = t.unlocked ~= false,
        discovered = t.discovered == true,
        -- Steamodded's defaults: nothing copies a mod Joker unless it says it can be copied.
        blueprint_compat = t.blueprint_compat == true,
        perishable_compat = t.perishable_compat ~= false,
        eternal_compat = t.eternal_compat ~= false,
        rarity = rarity,
        cost = cost,
        sell_cost = math.max(1, math.floor(cost / 2)),
        config = deep_copy(type(t.config) == "table" and t.config or {}),
        pos = { atlas = SMODS.MOD_ATLAS, index = sprite },
        sub_pos = soul and { atlas = SMODS.MOD_ATLAS, index = soul } or nil,
        negative_pos = negative and { atlas = SMODS.MOD_ATLAS, index = negative } or nil,
        mod_id = mod.id,
        smods = t,
    }
    t.mod = mod
    t.original_key = t.key
    t.key = id
    def.mod_tooltip = tooltip_lines_for(t)

    JOKER_DEFS[id] = def
    SMODS.Centers[id] = t
    SMODS.register_translations(mod, "joker", id, t)
    JokerEffects.register(id, build_effect(t, def))
    mod.registered.jokers[#mod.registered.jokers + 1] = id
    return t
end

--------------------------------------------------------------------------------
-- Shared registration pieces (Jokers, Consumables, Vouchers)
--------------------------------------------------------------------------------

--- A card's image, and its negative image when it ships one.
local function card_sprites(mod, t, what)
    no_atlas(t, what)
    local sprite = register_sprite(mod, t.sprite, what, t.key, "sprite")
    local negative = t.negative_sprite ~= nil
        and register_sprite(mod, t.negative_sprite, what, t.key, "negative_sprite") or nil
    return sprite, negative
end

local function check_functions(t, what, names)
    for _, name in ipairs(names) do
        check(t[name] == nil or type(t[name]) == "function", what .. " '" .. t.key .. "': "
            .. name .. " must be a function")
    end
end

--- `loc_txt.text` as plain lines with `#n#` filled in and the markup dropped, for the places
--- that show a single plain string (the shop's voucher callout, the collection).
local function plain_text(center, card, language)
    local loc = loc_for(center.loc_txt, language or "en") or {}
    local text = loc.text
    if type(text) == "string" then text = { text } end
    if type(text) ~= "table" then return "" end
    local vars = {}
    if type(center.loc_vars) == "function" then
        local ret = SMODS.call(center.mod, center.loc_vars, center, {}, card)
        if type(ret) == "table" and type(ret.vars) == "table" then vars = ret.vars end
    end
    local lines = {}
    for _, line in ipairs(text) do
        local segs = SMODS.format_line(line, vars).segments
        local parts = {}
        for _, s in ipairs(segs) do parts[#parts + 1] = s.text end
        lines[#lines + 1] = table.concat(parts)
    end
    return table.concat(lines, "\n")
end
SMODS.plain_text = plain_text

--- A mod's own translations: each language in a per-language `loc_txt` gets the card's name
--- (and, for vouchers, whose description is shown as one plain string, the description) in the
--- game's string tables, so the collection, the shop and the toasts find it like any other.
--- Tooltip text is read from `loc_txt` in the live language when drawn (`tooltip_lines_for`).
function SMODS.register_translations(mod, kind, id, center, voucher_config)
    if not (I18N and I18N.add_strings) then return end
    for _, code in ipairs(other_languages(center.loc_txt)) do
        local entry = center.loc_txt[code]
        local strings, keys = {}, {}
        if entry.name ~= nil then
            strings[kind .. "." .. id .. ".name"] = tostring(entry.name)
        end
        if voucher_config then
            strings[kind .. "." .. id .. ".description"] = plain_text(center, { ability = deep_copy(voucher_config) }, code)
        end
        for key in pairs(strings) do keys[#keys + 1] = key end
        I18N.add_strings(code, strings)
        mod.registered.strings[#mod.registered.strings + 1] = { language = code, keys = keys }
    end
end

--- The tooltip lines for any mod centre, given the object standing in for `card`.
function SMODS.tooltip_lines(id, card)
    local center = SMODS.Centers[id]
    if not center then return nil end
    return tooltip_lines_for(center)(card)
end

--- Steamodded reads the player's selected cards as `G.hand.highlighted`. The port keeps the
--- selection on the Hand; this mirrors it there before a mod looks.
local function sync_highlighted(game)
    local hand = game and game.hand
    if not hand then return {} end
    local list = hand.ordered_selected_nodes and hand:ordered_selected_nodes() or {}
    hand.highlighted = card_views(list)
    return hand.highlighted
end
SMODS.sync_highlighted = sync_highlighted

--------------------------------------------------------------------------------
-- Enhancements, seals and editions (Tier 3a)
--------------------------------------------------------------------------------

--- The third family of registries: the centers a playing card itself carries.
--- Vanilla's are hardcoded in the engine -- enhancement effects in
--- `Card:do_enhancement` behind per-name branches in `Card:emit_hand_event`,
--- seals in `Card:do_seal` plus the Red Seal's line in
--- `Game:collect_retrigger_sources`, edition bonuses in
--- `Hand:get_playing_card_edition_bonus` and `Joker:apply_edition_on_hand_scored`,
--- and every random poll (spectral creation, Standard packs, the shop's edition
--- ladder, guaranteed-edition rolls) spelling its own list of names. The
--- registries below are what those places consult once their vanilla names miss,
--- so with nothing registered every one of them takes exactly the path it took
--- before -- same lists, same draws, same numbers.
---
--- A center's **value** is the string cards carry (`card_data.enhancement`,
--- `card_data.seal`, a Joker's `edition`, a playing card's `modifier.edition`):
--- the registration key lowercased, because the engine compares those strings
--- against lowercase literals everywhere (`"steel"`, `"blue"`, `"foil"`). Values
--- are global, like consumable kinds: no two mods may register the same one, and
--- none may reuse a vanilla name. A save stores the value as the plain string,
--- exactly like a vanilla one; a save loaded without the mod keeps the string and
--- every engine read of it falls back to no effect (unknown enhancements score
--- nothing, unknown editions normalize away on Jokers and score nothing on
--- cards), so an orphaned center never crashes a load.

SMODS.Enhancements = SMODS.Enhancements or {}
SMODS.EnhancementByValue = SMODS.EnhancementByValue or {}
SMODS.Seals = SMODS.Seals or {}
SMODS.SealByValue = SMODS.SealByValue or {}
SMODS.Editions = SMODS.Editions or {}
SMODS.EditionByValue = SMODS.EditionByValue or {}
local next_center_order = 1

local VANILLA_ENHANCEMENTS = { bonus = true, mult = true, wild = true, glass = true,
    steel = true, stone = true, gold = true, lucky = true }
local VANILLA_SEALS = { gold = true, red = true, blue = true, purple = true }
local VANILLA_EDITIONS = { foil = true, holo = true, polychrome = true, negative = true, base = true }

--- Steamodded's enhancement keys onto the port's.
local ENHANCEMENT = {
    m_bonus = "bonus", m_mult = "mult", m_wild = "wild", m_glass = "glass",
    m_steel = "steel", m_stone = "stone", m_gold = "gold", m_lucky = "lucky",
}

--- A center's display name in the string tables, in the `content_name` shape
--- (`enhancement.copper.name`), for English and every language its `loc_txt`
--- carries. Recorded on the mod, so rollback takes the strings away again.
local function register_center_strings(mod, kind, value, loc)
    if not (I18N and I18N.add_strings) or type(loc) ~= "table" then return end
    local function add(code, name)
        if type(name) ~= "string" then return end
        local key = kind .. "." .. value .. ".name"
        I18N.add_strings(code, { [key] = name })
        mod.registered.strings[#mod.registered.strings + 1] = { language = code, keys = { key } }
    end
    local english = loc_for(loc, "en")
    if english then add("en-us", english.name) end
    for _, code in ipairs(other_languages(loc)) do
        local entry = loc[code]
        if type(entry) == "table" then add(code, entry.name) end
    end
end

--- Shared registrar shape for the three centers: validate the key, claim its
--- value globally, and file the entry in both registries.
local function register_center(what, t, vanilla, by_id, by_value)
    local mod = need_mod("SMODS." .. what)
    check(type(t) == "table", "SMODS." .. what .. " expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS." .. what .. " needs a 'key' of letters, digits and underscores")
    check(t.calculate == nil or type(t.calculate) == "function",
        what .. " '" .. t.key .. "': calculate must be a function")
    check(t.loc_vars == nil or type(t.loc_vars) == "function",
        what .. " '" .. t.key .. "': loc_vars must be a function")
    local value = t.key:lower()
    check(vanilla[value] == nil, what .. " '" .. t.key .. "' is a vanilla " .. what:lower())
    local clash = by_value[value]
    check(clash == nil, what .. " '" .. t.key .. "': the " .. what:lower() .. " '" .. value
        .. "' is already registered by " .. (clash and clash.mod.id or "?"))
    local id = mod.prefix .. "_" .. t.key
    check(by_id[id] == nil, what .. " '" .. t.key .. "' is defined twice (id " .. id .. ")")
    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = id, key = t.key, value = value, mod = mod,
        name = tostring(loc.name or t.name or t.key),
        config = deep_copy(type(t.config) == "table" and t.config or {}),
        calculate = t.calculate, loc_vars = t.loc_vars, loc_txt = t.loc_txt,
        order = next_center_order,
    }
    next_center_order = next_center_order + 1
    by_id[id] = entry
    by_value[value] = entry
    local bucket = what:lower() .. "s"
    mod.registered[bucket] = mod.registered[bucket] or {}
    mod.registered[bucket][#mod.registered[bucket] + 1] = id
    register_center_strings(mod, what:lower(), value, t.loc_txt)
    t.mod = mod
    t.original_key = t.key
    t.key = id
    t.value = value
    return entry
end

--- `SMODS.Enhancement { key, loc_txt, config, calculate, weight }`: an
--- enhancement of this mod's own. Its value (the key, lowercased) is a valid
--- `enhancement` everywhere a vanilla one is: `SMODS.add_card`, a consumable's
--- `mod_conv` (by value, or Steamodded-style as `m_<key>` / `m_<full id>`), and
--- the random-enhancement polls (spectral creation and enhanced Standard-pack /
--- shop cards), where it takes `weight` slots among the vanilla names
--- (default 1, the vanilla-like share; 0 keeps it out of the polls).
---
--- `config` is data the engine applies itself, mirroring the vanilla centers:
--- `chips` / `mult` / `x_mult` when the card scores (Bonus / Mult / Glass),
--- `h_chips` / `h_mult` / `h_x_mult` while it is held in hand (Steel), and
--- `h_dollars` at round end while held (Gold). (`bonus` / `h_bonus` are read
--- as spellings of `chips` / `h_chips`.) Anything richer is
--- `calculate(self, card, context)`, fired at the same three moments
--- (`context.card_played` / `context.held_in_hand` / `context.on_round_end`,
--- with `context.other_card` the card): its return's `chips` / `mult` /
--- `x_mult` land on the running totals and `dollars` in the player's money.
--- Art is the optional `sprite = "Name.png"` (a card-sized image in
--- assets/1x): a card carrying the enhancement draws it as its face, the
--- rank and suit still overlaid. Without one the card draws the plain card
--- face, the same fallback as a mod suit's Hearts row.
function SMODS.Enhancement(t)
    local entry = register_center("Enhancement", t, VANILLA_ENHANCEMENTS,
        SMODS.Enhancements, SMODS.EnhancementByValue)
    local weight = t.weight == nil and 1 or math.floor(tonumber(t.weight) or -1)
    check(weight >= 0, "Enhancement '" .. t.original_key .. "': weight must be a whole number >= 0")
    entry.weight = weight
    if t.sprite ~= nil then
        entry.sprite = register_sprite(entry.mod, t.sprite, "Enhancement", t.original_key, "sprite")
    end
    return t
end

--- `SMODS.Seal { key, loc_txt, config, calculate, weight }`: a seal of this
--- mod's own, valid everywhere a vanilla one is (`SMODS.add_card`, creation)
--- and in the Standard-pack seal poll, where it takes `weight` slots among
--- the four vanilla seals (default 1; 0 keeps it out).
---
--- A seal's behavior is its `calculate(self, card, context)`, fired at the
--- moments the engine raises for cards -- `context.card_played` (Gold Seal's
--- moment), `context.held_in_hand`, `context.on_round_end` (Blue Seal's),
--- `context.on_discard` (Purple Seal's, with `context.discard_reason`) -- its
--- return's `dollars` land in the player's money and `chips` / `mult` /
--- `x_mult` on the running totals, as for enhancements. Retriggers (Red
--- Seal's trick) come from `config.retrigger` / `config.retrigger_held`
--- counts, or from `calculate` returning `repetitions` when asked with
--- `context.repetition`. Art is the optional `sprite = "Name.png"`: a
--- full-card image (transparent but for the stamp) drawn as the seal
--- overlay. Without one the card draws without a seal stamp, like a card
--- whose seal the atlas has no cell for.
function SMODS.Seal(t)
    local entry = register_center("Seal", t, VANILLA_SEALS, SMODS.Seals, SMODS.SealByValue)
    local weight = t.weight == nil and 1 or math.floor(tonumber(t.weight) or -1)
    check(weight >= 0, "Seal '" .. t.original_key .. "': weight must be a whole number >= 0")
    entry.weight = weight
    if t.sprite ~= nil then
        entry.sprite = register_sprite(entry.mod, t.sprite, "Seal", t.original_key, "sprite")
    end
    return t
end

--- `SMODS.Edition { key, loc_txt, config, weight }`: an edition of this mod's
--- own, valid for Jokers and playing cards everywhere a vanilla one is
--- (creation, `SMODS.add_card { edition = ... }`) and in the random edition
--- polls at its `weight` -- in the shop ladder's units, percent of the roll
--- (vanilla: Foil 4, Holo 2, Polychrome 0.6 at base rates; default 2). In
--- guaranteed-edition rolls (Aura, Wheel of Fortune) it shares the Foil band
--- by weight, Foil itself counting 50.
---
--- `config` is what the edition contributes, mirroring the vanilla three:
--- `chips` / `mult` / `x_mult`. On a playing card all three land in its
--- scoring step; on a Joker the flat `chips` / `mult` land before its effect
--- and `x_mult` after it, the slots Foil / Holo and Polychrome sit in.
--- `config.joker_slots` grants that many extra Joker slots while a Joker
--- carrying the edition is held -- Negative's trick, as data. `cost` is the
--- extra dollars a Joker carrying the edition costs (and so half again on
--- its sell value), applied where the vanilla editions' own deltas are --
--- the spawned Joker's price and the shop's offer price; default 0, and it
--- may be negative. A mod edition has no shader pass and no reveal sting;
--- its treatment is the optional `sprite = "Name.png"`, a full-card overlay
--- image drawn over the face (a Joker's front, a playing card's face).
--- Without one its cards draw plain.
function SMODS.Edition(t)
    local entry = register_center("Edition", t, VANILLA_EDITIONS,
        SMODS.Editions, SMODS.EditionByValue)
    local weight = t.weight == nil and 2 or tonumber(t.weight)
    check(weight ~= nil and weight >= 0, "Edition '" .. t.original_key .. "': weight must be a number >= 0")
    entry.weight = weight
    local cost = t.cost == nil and 0 or tonumber(t.cost)
    check(cost ~= nil, "Edition '" .. t.original_key .. "': cost must be a number")
    entry.cost = math.floor(cost)
    if t.sprite ~= nil then
        entry.sprite = register_sprite(entry.mod, t.sprite, "Edition", t.original_key, "sprite")
    end
    return t
end

--- What an enhancement name means, as the canonical value a card carries: a
--- vanilla port name, a Steamodded `m_` key (vanilla or a mod's own, by bare
--- key or full id), or a registered value in any case. Nil for anything else.
local function enhancement_name(name)
    if type(name) ~= "string" or name == "" then return nil end
    if ENHANCEMENT[name] then return ENHANCEMENT[name] end
    if VANILLA_ENHANCEMENTS[name] then return name end
    local lower = name:lower()
    if SMODS.EnhancementByValue[lower] then return lower end
    if lower:sub(1, 2) == "m_" then
        local rest = lower:sub(3)
        if SMODS.EnhancementByValue[rest] then return rest end
        local entry = SMODS.Enhancements[rest]
        if entry then return entry.value end
    end
    return nil
end
SMODS.enhancement_name = enhancement_name

--- What a seal name means, as its canonical value: a vanilla seal or a
--- registered one, in any case. Nil for anything else.
local function seal_name(name)
    if type(name) ~= "string" or name == "" then return nil end
    local lower = name:lower()
    if VANILLA_SEALS[lower] or SMODS.SealByValue[lower] then return lower end
    return nil
end
SMODS.seal_name = seal_name

--- What an edition name means, as its canonical value: a vanilla edition
--- (any of its spellings), or a registered one by key or `e_<key>`. Nil for
--- anything else.
local function edition_value(name)
    if type(name) == "table" then name = name.key or name.name end
    if type(name) ~= "string" or name == "" then return nil end
    local lower = name:lower()
    if VANILLA_EDITIONS[lower] then return lower end
    if lower == "holographic" or lower == "e_holo" then return "holo" end
    if lower:sub(1, 2) == "e_" then
        local rest = lower:sub(3)
        if VANILLA_EDITIONS[rest] then return rest end
        if SMODS.EditionByValue[rest] then return rest end
    end
    if SMODS.EditionByValue[lower] then return lower end
    return nil
end
SMODS.edition_value = edition_value

--- The extra dollars a registered edition adds to a Joker's price -- its
--- registration's `cost`, which `Joker.edition_price_deltas` applies at the
--- same sites as the vanilla deltas (a spawned Joker's cost, and so its sell
--- value, and the shop's offer price). Nil for a vanilla edition or an
--- unknown name: those are not the registry's business.
function SMODS.edition_cost(name)
    local value = edition_value(name)
    local entry = value and SMODS.EditionByValue[value]
    return entry and entry.cost or nil
end

--- The standalone image a registered center draws with -- its registration's
--- `sprite`, in this port's one-image-per-card terms -- by kind
--- ("enhancement" / "seal" / "edition") and the value a card carries. Nil
--- when the center is vanilla, unregistered, or registered without art:
--- those draw the plain fallbacks.
function SMODS.center_sprite(kind, value)
    if type(value) ~= "string" or value == "" then return nil end
    if kind == "enhancement" then value = enhancement_name(value) or value
    elseif kind == "seal" then value = seal_name(value) or value
    elseif kind == "edition" then value = edition_value(value) or value end
    local by_value = kind == "enhancement" and SMODS.EnhancementByValue
        or kind == "seal" and SMODS.SealByValue
        or kind == "edition" and SMODS.EditionByValue
    local entry = by_value and by_value[value:lower()]
    return entry and entry.sprite or nil
end

--- Apply one center `calculate` return to a card event: the scoring fields
--- onto the running totals the event carries, in the same order
--- `SMODS.apply_return` lands them, `dollars` into the player's money.
--- Returns whether anything landed, so the caller can count the card as
--- triggered (its juice, its retrigger eligibility).
local function apply_center_return(ctx, ret)
    if type(ret) ~= "table" then return false end
    local fired = ret.message ~= nil
    local chips = first_value(ret, "chips", "chip_mod") or 0
    local mult = first_value(ret, "mult", "mult_mod") or 0
    local xmult = first_value(ret, "x_mult", "xmult", "Xmult") or 1
    local emult = first_value(ret, "emult", "e_mult", "Emult")
    local echips = first_value(ret, "echips", "e_chips", "Echips")
    local xchips = first_value(ret, "xchips", "x_chips", "Xchips")
    local xlogchips = first_value(ret, "xlog_chips", "xlogchips", "Xlog_chips")
    local dollars = tonumber(ret.dollars) or tonumber(ret.p_dollars) or 0
    if Totals.cmp(chips, 0) ~= 0 then ctx.chips = Big.add_values(Totals.read(ctx.chips, 0), chips) fired = true end
    if Totals.cmp(mult, 0) ~= 0 then ctx.mult = Big.add_values(Totals.read(ctx.mult, 1), mult) fired = true end
    if Totals.cmp(xmult, 1) ~= 0 then ctx.mult = Big.mul_values(Totals.read(ctx.mult, 1), xmult) fired = true end
    if emult and Totals.cmp(emult, 1) ~= 0 then
        local base = Totals.read(ctx.mult, 1)
        local r = Big.pow_values(base, tonumber(emult) or 1)
        if r == r then ctx.mult = r fired = true end
    end
    if echips and Totals.cmp(echips, 1) ~= 0 then
        local base = Totals.read(ctx.chips, 0)
        local r = Big.pow_values(base, tonumber(echips) or 1)
        if r == r then ctx.chips = r fired = true end
    end
    if xchips and Totals.cmp(xchips, 1) ~= 0 then ctx.chips = Big.mul_values(Totals.read(ctx.chips, 0), xchips) fired = true end
    if xlogchips then
        local base = tonumber(xlogchips) or 0
        local cur = Totals.read(ctx.chips, 0)
        if base > 0 and base ~= 1 and Totals.cmp(cur, 1) > 0 then
            local log = Big.log10_of(cur) / (math.log(base) / math.log(10))
            if log >= 1 then ctx.chips = Big.mul_values(cur, log) fired = true end
        end
    end
    if ret.swap then
        local c, m = Totals.read(ctx.chips, 0), Totals.read(ctx.mult, 1)
        if not Totals.eq(c, m) then ctx.chips, ctx.mult = m, c fired = true end
    end
    if ret.balance then
        local c, m = Totals.read(ctx.chips, 0), Totals.read(ctx.mult, 1)
        local best = Totals.cmp(c, m) >= 0 and c or m
        local f = tonumber(ret.balance)
        if f and f > 0 and f < 1 then
            local function toward(v)
                if Totals.eq(v, best) then return v end
                if Big.is_big(v) or Big.is_big(best) then
                    return Big.add_values(v, Big.mul_values(Big.add_values(best, Big.mul_values(v, -1)), f))
                end
                return v + (best - v) * f
            end
            local nc, nm = toward(c), toward(m)
            if not Totals.eq(nc, c) or not Totals.eq(nm, m) then ctx.chips, ctx.mult = nc, nm fired = true end
        elseif not Totals.eq(c, best) or not Totals.eq(m, best) then ctx.chips, ctx.mult = best, best fired = true end
    end
    if ret.level_up and apply_return_level_up(ctx, ret.level_up) then fired = true end
    if dollars ~= 0 and G then
        if dollars > 0 and SMODS.transform_money_gain then
            dollars = SMODS.transform_money_gain(G, dollars)
        end
        G.money = (tonumber(G.money) or 0) + dollars
        if G._emit_money_altered then G:_emit_money_altered(dollars) end
        fired = true
    end
    return fired
end

--- The moments a card center fires at, as the context a `calculate` sees:
--- the event's own flag, the card as `other_card`, the raw event as `port`.
local function center_context(node, event_name, ctx)
    return {
        individual = true,
        event = event_name,
        [event_name] = true,
        cardarea = event_name == "card_played" and ((G and G.play) or SMODS.PLAY) or (G and G.hand),
        other_card = refresh_card_view(node),
        discard_reason = ctx.discard_reason,
        port = ctx,
    }
end

--- A registered enhancement's and seal's turn at one of the card moments
--- `Card:emit_hand_event` dispatches (`card.lua` calls this after its vanilla
--- branches; a card carries at most one of each, and the vanilla and custom
--- names never overlap, so the two halves cannot both fire). The
--- enhancement's `config` numbers land first, then either center's
--- `calculate` return. Returns whether anything fired.
function SMODS.card_center_event(node, event_name, ctx)
    if type(node) ~= "table" or type(ctx) ~= "table" then return false end
    local data = node.card_data or {}
    local fired = false

    local enh = node.enhancement or data.enhancement
    local eentry = enh and SMODS.EnhancementByValue[enh]
    if eentry then
        local cfg = eentry.config
        if event_name == "card_played" then
            local chips = tonumber(cfg.chips) or tonumber(cfg.bonus) or 0
            local mult = tonumber(cfg.mult) or 0
            local xmult = tonumber(cfg.x_mult) or 1
            if chips ~= 0 then ctx.chips = Big.add_values(Totals.read(ctx.chips, 0), chips) fired = true end
            if mult ~= 0 then ctx.mult = Big.add_values(Totals.read(ctx.mult, 1), mult) fired = true end
            if xmult ~= 1 then ctx.mult = Big.mul_values(Totals.read(ctx.mult, 1), xmult) fired = true end
        elseif event_name == "held_in_hand" then
            local chips = tonumber(cfg.h_chips) or tonumber(cfg.h_bonus) or 0
            local mult = tonumber(cfg.h_mult) or 0
            local xmult = tonumber(cfg.h_x_mult) or 1
            if chips ~= 0 then ctx.chips = Big.add_values(Totals.read(ctx.chips, 0), chips) fired = true end
            if mult ~= 0 then ctx.mult = Big.add_values(Totals.read(ctx.mult, 1), mult) fired = true end
            if xmult ~= 1 then ctx.mult = Big.mul_values(Totals.read(ctx.mult, 1), xmult) fired = true end
        elseif event_name == "on_round_end" then
            local dollars = tonumber(cfg.h_dollars) or tonumber(cfg.dollars) or 0
            if dollars ~= 0 and G then
                G.money = (tonumber(G.money) or 0) + dollars
                if G._emit_money_altered then G:_emit_money_altered(dollars) end
                fired = true
            end
        end
        if type(eentry.calculate) == "function" and event_name ~= "on_discard" then
            local ret = SMODS.call(eentry.mod, eentry.calculate, eentry,
                refresh_card_view(node), center_context(node, event_name, ctx))
            if apply_center_return(ctx, ret) then fired = true end
        end
    end

    local seal = node.seal or data.seal
    local sentry = seal and SMODS.SealByValue[seal]
    if sentry and type(sentry.calculate) == "function" then
        local ret = SMODS.call(sentry.mod, sentry.calculate, sentry,
            refresh_card_view(node), center_context(node, event_name, ctx))
        if apply_center_return(ctx, ret) then fired = true end
    end
    return fired
end

--- How many retrigger passes a card's registered seal grants, from
--- `config.retrigger` / `config.retrigger_held` and from `calculate` asked
--- with `context.repetition`. Called from `Game:collect_retrigger_sources`,
--- where the Red Seal's own pass comes from.
function SMODS.seal_retrigger_count(node, held)
    if type(node) ~= "table" then return 0 end
    local data = node.card_data or {}
    local seal = node.seal or data.seal
    local entry = seal and SMODS.SealByValue[seal]
    if not entry then return 0 end
    local n = tonumber(entry.config[held and "retrigger_held" or "retrigger"]) or 0
    if type(entry.calculate) == "function" then
        local c = {
            repetition = true,
            held = held == true,
            cardarea = held and (G and G.hand) or ((G and G.play) or SMODS.PLAY),
            other_card = refresh_card_view(node),
            port = {},
        }
        local ret = SMODS.call(entry.mod, entry.calculate, entry, refresh_card_view(node), c)
        if type(ret) == "table" then
            n = n + math.max(0, math.floor(tonumber(ret.repetitions) or 0))
        end
    end
    return math.max(0, math.floor(n))
end

--- A registered edition's scoring numbers for a playing card
--- (`Hand:get_playing_card_edition_bonus` asks here once the vanilla three
--- miss): chips, mult, x_mult, exactly the vanilla return's shape.
function SMODS.playing_card_edition_bonus(edition)
    local entry = edition and SMODS.EditionByValue[edition]
    if not entry then return 0, 0, 1 end
    local cfg = entry.config
    return tonumber(cfg.chips) or tonumber(cfg.bonus) or 0,
        tonumber(cfg.mult) or 0, tonumber(cfg.x_mult) or 1
end

--- A registered edition's turn in a Joker's scoring, in the slots the vanilla
--- editions sit in (`Joker:apply_edition_on_hand_scored` calls here for a
--- non-vanilla edition): flat `chips` / `mult` before the Joker's effect,
--- `x_mult` after it.
function SMODS.apply_custom_edition_on_hand_scored(joker, ctx, after_effect)
    if type(ctx) ~= "table" then return end
    local ed = Joker and Joker.normalize_edition and Joker.normalize_edition(joker.edition)
    local entry = ed and SMODS.EditionByValue[ed]
    if not entry then return end
    local cfg = entry.config
    local applied = false
    if after_effect then
        local xmult = tonumber(cfg.x_mult) or 1
        if xmult ~= 1 then
            ctx.mult = Big.mul_values(Totals.read(ctx.mult, 0), xmult)
            applied = true
        end
    else
        local chips = tonumber(cfg.chips) or tonumber(cfg.bonus) or 0
        local mult = tonumber(cfg.mult) or 0
        if chips ~= 0 then ctx.chips = Big.add_values(Totals.read(ctx.chips, 0), chips) applied = true end
        if mult ~= 0 then ctx.mult = Big.add_values(Totals.read(ctx.mult, 0), mult) applied = true end
    end
    if applied then
        if Sfx and Sfx.play then Sfx.play("foil2", 1, 0.3) end
        if joker.juice_up then joker:juice_up(0.6, 0.1) end
    end
end

--- Extra Joker slots a held Joker's registered edition grants
--- (`config.joker_slots`, Negative's trick as data). Counted by
--- `Game:refresh_joker_capacity_from_negatives` beside the Negatives.
function SMODS.edition_extra_slots(joker)
    local ed = Joker and Joker.normalize_edition and Joker.normalize_edition(joker and joker.edition)
    local entry = ed and SMODS.EditionByValue[ed]
    if not entry then return 0 end
    return math.max(0, math.floor(tonumber(entry.config.joker_slots) or 0))
end

local function sorted_centers(by_value)
    local out = {}
    for _, entry in pairs(by_value) do out[#out + 1] = entry end
    table.sort(out, function(a, b) return a.order < b.order end)
    return out
end

--- A random-enhancement poll's list, extended: with no custom enhancement
--- polling, the caller's own list comes back untouched (same table, same
--- length, same draw). Otherwise each custom takes its `weight` in slots
--- after the vanilla names, in registration order.
function SMODS.enhancement_poll_list(base)
    local customs = {}
    for _, entry in ipairs(sorted_centers(SMODS.EnhancementByValue)) do
        if entry.weight > 0 then customs[#customs + 1] = entry end
    end
    if #customs == 0 then return base end
    local out = {}
    for _, v in ipairs(base) do out[#out + 1] = v end
    for _, entry in ipairs(customs) do
        for _ = 1, entry.weight do out[#out + 1] = entry.value end
    end
    return out
end

--- The Standard-pack seal poll's type list when custom seals poll: the
--- vanilla four in the order the vanilla thresholds lay them (purple, gold,
--- blue, red, bottom band first) with each custom's `weight` in slots after,
--- in registration order. Nil when no custom seal polls, so the caller keeps
--- its threshold chain -- and its exact seeded answers.
function SMODS.seal_poll_list()
    local customs = {}
    for _, entry in ipairs(sorted_centers(SMODS.SealByValue)) do
        if entry.weight > 0 then customs[#customs + 1] = entry end
    end
    if #customs == 0 then return nil end
    local out = { "purple", "gold", "blue", "red" }
    for _, entry in ipairs(customs) do
        for _ = 1, entry.weight do out[#out + 1] = entry.value end
    end
    return out
end

--- A custom edition's slice of an edition ladder (`Game:roll_joker_offer_edition`,
--- the Standard-pack roll): `floor` is the top of the band still unclaimed
--- below the vanilla rungs, as a fraction of the roll; each custom takes
--- `weight * mult / 100` of the roll from there down, in registration order.
--- Returns the edition a roll in its slice names, or nil -- and nil whenever
--- no custom edition polls, so the vanilla ladder stands untouched.
function SMODS.shop_edition_pick(roll, floor, mult)
    local picked = nil
    for _, entry in ipairs(sorted_centers(SMODS.EditionByValue)) do
        if entry.weight > 0 then
            local band = entry.weight * (mult or 1) / 100
            if roll > floor - band then picked = entry.value break end
            floor = floor - band
        end
    end
    return picked
end

--- The bottom band of a guaranteed-edition roll (Aura, Wheel of Fortune,
--- Illusion), shared out: Foil counts 50, each custom edition its `weight`,
--- and the band's 50% is divided in those proportions, Foil's slice on top,
--- then the customs' in registration order. Returns "foil" or a custom
--- value; nil when no custom edition polls, so the caller keeps its
--- vanilla answer.
function SMODS.guaranteed_edition_pick(roll)
    local customs = {}
    local total = 50
    for _, entry in ipairs(sorted_centers(SMODS.EditionByValue)) do
        if entry.weight > 0 then
            customs[#customs + 1] = entry
            total = total + entry.weight
        end
    end
    if #customs == 0 then return nil end
    local edge = 0.5
    local foil_share = 0.5 * 50 / total
    if roll > edge - foil_share then return "foil" end
    edge = edge - foil_share
    for _, entry in ipairs(customs) do
        local share = 0.5 * entry.weight / total
        if roll > edge - share then return entry.value end
        edge = edge - share
    end
    return "foil"
end

--- A registered center's tooltip: its display name and its `loc_txt` lines
--- as plain text (`#n#` filled from `loc_vars`), for the playing-card
--- tooltip, whose vanilla name/line tables only know the vanilla centers.
--- Returns nil name and no lines for anything unregistered.
function SMODS.center_tooltip(kind, value)
    local entry = kind == "enhancement" and SMODS.EnhancementByValue[value]
        or kind == "seal" and SMODS.SealByValue[value]
        or kind == "edition" and SMODS.EditionByValue[value]
    if not entry then return nil, {} end
    local loc = loc_for(entry.loc_txt, I18N and I18N.get_language() or "en") or {}
    local text = loc.text
    if type(text) == "string" then text = { text } end
    if type(text) ~= "table" then return entry.name, {} end
    local vars = {}
    if type(entry.loc_vars) == "function" then
        local ret = SMODS.call(entry.mod, entry.loc_vars, entry, {}, { ability = entry.config })
        if type(ret) == "table" and type(ret.vars) == "table" then vars = ret.vars end
    end
    local lines = {}
    for _, line in ipairs(text) do
        local segs = SMODS.format_line(line, vars).segments
        local parts = {}
        for _, s in ipairs(segs) do parts[#parts + 1] = s.text end
        lines[#lines + 1] = table.concat(parts)
    end
    return entry.name, lines
end

--------------------------------------------------------------------------------
-- Consumables
--------------------------------------------------------------------------------

local CONSUMABLE_SET = { tarot = "tarot", planet = "planet", spectral = "spectral" }

--- Custom consumable types by full id (`<prefix>_<key>`) and by the kind string their
--- cards carry (`def.kind`, the bare key as the mod wrote it, e.g. "Minor"). Kinds are
--- global, the way Steamodded's sets are: two mods cannot register the same kind, and
--- a kind may not reuse a vanilla set's name.
SMODS.ConsumableTypes = SMODS.ConsumableTypes or {}
SMODS.ConsumableKinds = SMODS.ConsumableKinds or {}
local next_consumable_type_order = 1

--- `SMODS.ConsumableType { key, loc_txt, shop_rate, packs }`: a consumable set of
--- this mod's own. A consumable then declares it with `set = "<key>"` (or the
--- type's full id) in `SMODS.Consumable`, and its cards are held, pooled, sold
--- and used exactly like the vanilla sets' -- but as their own kind wherever the
--- game asks which set a card belongs to. Planet hand-levelling and the
--- Tarot/Spectral-only effects stay with their own kinds; a custom kind's cards
--- do what their own `use` says.
---
--- `shop_rate` is the kind's weight in the shop's consumable roll, in the units of
--- the vanilla weights (Tarot and Planet are 4 each before their merchant vouchers
--- raise them): the default 4 makes the kind as present as a vanilla one. The kind
--- joins the roll only while it has cards and a positive rate; rate 0 keeps it out
--- of the shop (its cards can still be created directly).
---
--- `packs` opts the kind into booster packs: a table mapping a pack kind --
--- "arcana", "celestial" or "spectral" -- to a rate in the same units (the pack's
--- own kind weighs 4). Each consumable slot of an opted-in pack first rolls its
--- vanilla kind, then a weighted draw can hand the slot to an opted-in kind with
--- cards available instead. A kind with no `packs` (or a rate of 0 for a pack)
--- never appears in that pack, and packs spend no extra draws while no kind is
--- opted in, so vanilla pack contents are unchanged.
function SMODS.ConsumableType(t)
    local mod = need_mod("SMODS.ConsumableType")
    check(type(t) == "table", "SMODS.ConsumableType expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$") ~= nil,
        "SMODS.ConsumableType needs a 'key' of letters, digits and underscores")
    check(CONSUMABLE_SET[t.key:lower()] == nil,
        "ConsumableType '" .. t.key .. "' reuses one of the three vanilla sets")
    local id = mod.prefix .. "_" .. t.key
    check(SMODS.ConsumableTypes[id] == nil,
        "ConsumableType '" .. t.key .. "' is defined twice (id " .. id .. ")")
    for _, entry in pairs(SMODS.ConsumableKinds) do
        check(entry.kind:lower() ~= t.key:lower(),
            "ConsumableType '" .. t.key .. "': the set '" .. entry.kind
            .. "' is already registered by " .. entry.mod.id)
    end
    local rate = t.shop_rate == nil and 4 or tonumber(t.shop_rate)
    check(rate ~= nil and rate >= 0,
        "ConsumableType '" .. t.key .. "': shop_rate must be a number >= 0")
    local packs = nil
    if t.packs ~= nil then
        check(type(t.packs) == "table",
            "ConsumableType '" .. t.key .. "': packs must be a table mapping pack kinds to rates")
        packs = {}
        for pack, pack_rate in pairs(t.packs) do
            check(pack == "arcana" or pack == "celestial" or pack == "spectral",
                "ConsumableType '" .. t.key .. "': packs names unknown pack '" .. tostring(pack)
                .. "' (packs hold consumables only in \"arcana\", \"celestial\" and \"spectral\")")
            local r = tonumber(pack_rate)
            check(r ~= nil and r >= 0,
                "ConsumableType '" .. t.key .. "': packs." .. pack .. " must be a number >= 0")
            if r > 0 then packs[pack] = r end
        end
        if next(packs) == nil then packs = nil end
    end
    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = id, key = t.key, kind = t.key, mod = mod,
        name = tostring(loc.name or t.name or t.key),
        shop_rate = rate,
        packs = packs,
        order = next_consumable_type_order,
    }
    next_consumable_type_order = next_consumable_type_order + 1
    SMODS.ConsumableTypes[id] = entry
    SMODS.ConsumableKinds[entry.kind] = entry
    mod.registered.consumable_types = mod.registered.consumable_types or {}
    mod.registered.consumable_types[#mod.registered.consumable_types + 1] = id
    t.mod = mod
    t.original_key = t.key
    t.key = id
    return t
end

--- Whether `kind` names a consumable set: a vanilla one, or a kind a mod registered
--- with `SMODS.ConsumableType`.
function SMODS.is_consumable_kind(kind)
    if type(kind) ~= "string" then return false end
    if CONSUMABLE_SET[kind:lower()] then return true end
    return SMODS.ConsumableKinds[kind] ~= nil
end

--- The registered type a set name means, or nil: the bare kind ("Minor"), a full type
--- id ("ct_Minor"), or -- from the registering mod -- its own bare key. Apart from
--- the exact full id, matching is case-insensitive, the way the vanilla set names are
--- read.
local function consumable_type_for_set(set, mod)
    if type(set) ~= "string" or set == "" then return nil end
    local entry = SMODS.ConsumableTypes[set]
    if entry then return entry end
    if mod then
        entry = SMODS.ConsumableTypes[mod.prefix .. "_" .. set]
        if entry then return entry end
    end
    local lower = set:lower()
    for _, e in pairs(SMODS.ConsumableKinds) do
        if e.kind:lower() == lower then return e end
    end
    return nil
end

--- What `set` means in `SMODS.Consumable` / `SMODS.add_card`: the kind string the
--- card carries, or nil when the name is none of the vanilla sets and no registered
--- type.
local function resolve_consumable_kind(set, mod)
    local vanilla = CONSUMABLE_SET[tostring(set or ""):lower()]
    if vanilla then return vanilla end
    local entry = consumable_type_for_set(set, mod)
    return entry and entry.kind or nil
end

--- Custom kinds that belong in the shop roll right now: a positive `shop_rate` and
--- at least one def of the kind, in registration order. Nil when there are none, so
--- the shop's vanilla roll is untouched.
function SMODS.shop_consumable_kinds()
    local out = {}
    for _, entry in pairs(SMODS.ConsumableKinds) do
        if entry.shop_rate > 0 then
            for _, def in pairs(CONSUMABLE_DEFS or {}) do
                if type(def) == "table" and def.kind == entry.kind then
                    out[#out + 1] = entry
                    break
                end
            end
        end
    end
    if #out == 0 then return nil end
    table.sort(out, function(a, b) return a.order < b.order end)
    return out
end

--- Custom kinds that opted into the booster pack kind `pack` (see the `packs`
--- field of `SMODS.ConsumableType`): those with a positive rate for the pack and
--- at least one def of the kind, in registration order, as `{ kind, rate }`.
--- Nil when there are none, so pack building is untouched.
function SMODS.pack_substitutions(pack)
    local out = {}
    for _, entry in pairs(SMODS.ConsumableKinds) do
        local rate = entry.packs and entry.packs[pack] or 0
        if rate > 0 then
            for _, def in pairs(CONSUMABLE_DEFS or {}) do
                if type(def) == "table" and def.kind == entry.kind then
                    out[#out + 1] = { kind = entry.kind, rate = rate, order = entry.order }
                    break
                end
            end
        end
    end
    if #out == 0 then return nil end
    table.sort(out, function(a, b) return a.order < b.order end)
    return out
end

local consumable_order = 1000

--- `SMODS.Consumable { set, key, loc_txt, config, cost, sprite,
--- negative_sprite, loc_vars, can_use, use }`. The id is `c_<prefix>_<key>`.
--- `set` is "Tarot", "Planet" or "Spectral", or a type this mod registered with
--- `SMODS.ConsumableType` (its bare key or its full id).
---
--- Like Steamodded, a consumable that only declares data needs no code:
---   * `config.max_highlighted` (and `min_highlighted`) is how many cards it targets;
---   * `config.mod_conv = "m_gold"` enhances them, `config.suit_conv = "Hearts"` changes suit;
---   * a Planet with `config.hand_type = "Flush"` levels that hand.
--- `use` runs instead of (or, for a Planet, after) the built-in part.
function SMODS.Consumable(t)
    local mod = need_mod("SMODS.Consumable")
    check(type(t) == "table", "SMODS.Consumable expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.Consumable needs a 'key' of letters, digits and underscores")
    local kind = resolve_consumable_kind(t.set, mod)
    check(kind ~= nil, "Consumable '" .. t.key .. "': unknown set '" .. tostring(t.set)
        .. "' (register it with SMODS.ConsumableType first, or use \"Tarot\", \"Planet\" or \"Spectral\")")
    local id = "c_" .. mod.prefix .. "_" .. t.key
    check(CONSUMABLE_DEFS[id] == nil, "Consumable '" .. t.key .. "' is defined twice (id " .. id .. ")")
    check_functions(t, "Consumable", { "loc_vars", "can_use", "use" })
    local sprite, negative = card_sprites(mod, t, "Consumable")
    local config = type(t.config) == "table" and t.config or {}

    local select
    local max_h, min_h = tonumber(config.max_highlighted), tonumber(config.min_highlighted)
    if max_h then select = { min = math.max(1, min_h or 1), max = max_h } end
    if config.mod_conv ~= nil then
        check(enhancement_name(config.mod_conv) ~= nil, "Consumable '" .. t.key .. "': unknown mod_conv '"
            .. tostring(config.mod_conv) .. "'")
    end
    if kind == "planet" and config.hand_type ~= nil then
        check(type(config.hand_type) == "string", "Consumable '" .. t.key .. "': hand_type must be a string")
    end

    -- `target_joker = true` (on the definition, or in `config`): using this
    -- consumable means choosing one held Joker for it to act on. See
    -- `SMODS.joker_target_for` for how the chosen Joker is resolved.
    local target_joker = t.target_joker == true or config.target_joker == true
    t.target_joker = target_joker or nil

    local loc = loc_for(t.loc_txt, "en") or {}
    consumable_order = consumable_order + 1
    -- Data only: an owned consumable is a copy of this table and is saved with the run, so
    -- nothing here may be a function. The code is found again through `SMODS.Centers[id]`.
    CONSUMABLE_DEFS[id] = {
        id = id,
        kind = kind,
        name = tostring(loc.name or t.name or t.key),
        index = consumable_order,          -- collection order; the art is `mod_sprite`
        select = select,
        target_joker = target_joker or nil,
        hand = kind == "planet" and config.hand_type or nil,
        cost = tonumber(t.cost),
        config = deep_copy(config),
        mod_id = mod.id,
        mod_sprite = sprite,
        mod_negative_sprite = negative,
    }
    t.mod = mod
    t.original_key = t.key
    t.key = id
    t.consumable_kind = kind
    SMODS.Centers[id] = t
    SMODS.register_translations(mod, "consumable", id, t)
    mod.registered.consumables[#mod.registered.consumables + 1] = id
    return t
end

--- The Joker a Joker-targeting consumable will act on, resolved in order:
--- an explicit target (the argument, or one the use path attached to the
--- consumable copy), the Joker under the gamepad focus while the focus layer
--- is the Joker row, and the Joker whose tooltip is open. Anything that is
--- not a currently held Joker does not count. Also mirrors the choice onto
--- `game.jokers.highlighted`, the field Steamodded mods read, and returns it.
function SMODS.joker_target_for(game, c, explicit)
    local function held(j)
        if type(j) ~= "table" then return nil end
        for _, held_j in ipairs(type(game.jokers) == "table" and game.jokers or EMPTY) do
            if held_j == j then return j end
        end
        return nil
    end
    local target = held(explicit) or held(c and c._smods_joker_target)
    if not target and game.get_gamepad_focus_layer
        and game:get_gamepad_focus_layer() == "jokers" then
        target = held(game.jokers and game.jokers[tonumber(game._joker_focus_index) or 1])
    end
    if not target then target = held(game.active_tooltip_joker) end
    if type(game.jokers) == "table" then
        game.jokers.highlighted = target and { target } or nil
    end
    return target
end

--- Whether a mod consumable can be used now. The port has already checked that the game is in
--- a state where consumables can be used at all. A Joker-targeting consumable's
--- `can_use(self, card, target)` receives the resolved target (possibly nil);
--- with no `can_use` of its own it needs a valid target to be usable at all.
function SMODS.consumable_can_use(game, c, target)
    local center = SMODS.Centers[c and c.id]
    if not center then return nil end
    if type(c.select) == "table" then
        if not game:hand_ready_for_tarot_selection() then return false end
        if not game:tarot_selection_requirement_met(c) then return false end
    end
    if center.target_joker then target = SMODS.joker_target_for(game, c, target) end
    if type(center.can_use) == "function" then
        sync_highlighted(game)
        return SMODS.call(center.mod, center.can_use, center, c, target) == true
    end
    if center.target_joker then return target ~= nil end
    return true
end

--- Use a mod consumable. Returns true when it is fully handled, false to let the port's own
--- Planet path level the hand first (the mod's `use`, if any, then runs from there).
--- A Joker-targeting consumable's `use(self, card, area, copier, target)`
--- receives the resolved target as its last argument.
function SMODS.use_consumable(game, c, target)
    local center = SMODS.Centers[c and c.id]
    if not center then return false end
    local config = c.ability or c.config or {}
    local hand = game.hand
    local highlighted = sync_highlighted(game)

    if center.consumable_kind == "planet" and c.hand and not c._smods_planet_done then
        return false
    end
    if center.target_joker then target = SMODS.joker_target_for(game, c, target) end

    local conv = config.mod_conv and enhancement_name(config.mod_conv) or nil
    if conv then
        game:convert_enhancement_ripple(highlighted, conv,
            tonumber(config.max_highlighted) or #highlighted)
    elseif type(config.suit_conv) == "string" then
        game:convert_suit_ripple(highlighted, config.suit_conv)
    end
    if type(center.use) == "function" then
        SMODS.call(center.mod, center.use, center, c, hand, nil, target)
    end
    c._smods_joker_target = nil

    game:record_consumable_use_id(c.id)
    if hand and hand.clear_selection then hand:clear_selection() end
    game.active_tooltip_card = nil
    if hand and hand.layout then hand:layout(false) end
    if Sfx and Sfx.play and center.consumable_kind ~= "planet" then Sfx.play("tarot1") end
    return true
end

--- After the port has levelled a mod Planet's hand, run the mod's own `use` if it has one.
function SMODS.after_planet(game, c)
    local center = SMODS.Centers[c and c.id]
    if center and type(center.use) == "function" then
        c._smods_planet_done = true
        local target = center.target_joker and SMODS.joker_target_for(game, c) or nil
        SMODS.call(center.mod, center.use, center, c, game.hand, nil, target)
        c._smods_planet_done = nil
        c._smods_joker_target = nil
    end
end

--------------------------------------------------------------------------------
-- Vouchers
--------------------------------------------------------------------------------

--- Steamodded's ids for the vanilla vouchers, where they differ from the port's.
local VOUCHER_ALIAS = { v_overstock_norm = "v_overstock", v_reroll_surplus = "v_reroll" }

local voucher_order = 1000

--- `SMODS.Voucher { key, loc_txt, config, cost, sprite, requires, loc_vars, redeem }`.
--- The id is `v_<prefix>_<key>`. `requires` lists vouchers that must be owned first -- vanilla
--- ids, full mod ids, or this mod's own keys. `redeem(self, card)` runs once, when it is bought.
function SMODS.Voucher(t)
    local mod = need_mod("SMODS.Voucher")
    check(type(t) == "table", "SMODS.Voucher expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.Voucher needs a 'key' of letters, digits and underscores")
    local id = "v_" .. mod.prefix .. "_" .. t.key
    check(VOUCHER_DEFS[id] == nil, "Voucher '" .. t.key .. "' is defined twice (id " .. id .. ")")
    check_functions(t, "Voucher", { "loc_vars", "redeem" })
    local sprite = card_sprites(mod, t, "Voucher")

    local requires = {}
    local req = t.requires
    if type(req) == "string" then req = { req } end
    for _, r in ipairs(type(req) == "table" and req or {}) do
        r = VOUCHER_ALIAS[r] or r
        local full = VOUCHER_DEFS[r] and r or ("v_" .. mod.prefix .. "_" .. tostring(r))
        check(VOUCHER_DEFS[full] ~= nil, "Voucher '" .. t.key .. "' requires unknown voucher '"
            .. tostring(r) .. "' (define it first)")
        requires[#requires + 1] = full
    end

    local loc = loc_for(t.loc_txt, "en") or {}
    voucher_order = voucher_order + 1
    t.mod = mod
    t.original_key = t.key
    t.key = id
    local config = deep_copy(type(t.config) == "table" and t.config or {})
    VOUCHER_DEFS[id] = {
        id = id,
        name = tostring(loc.name or t.name or t.key),
        description = plain_text(t, { ability = deep_copy(config) }),
        tier = #requires > 0 and 2 or 1,
        depends_on = requires[1],
        requires_all = #requires > 0 and requires or nil,
        price = tonumber(t.cost) or 10,
        order = voucher_order,
        config = config,
        mod_id = mod.id,
        mod_sprite = sprite,
    }
    SMODS.Centers[id] = t
    SMODS.register_translations(mod, "voucher", id, t, config)
    mod.registered.vouchers[#mod.registered.vouchers + 1] = id
    return t
end

--- Run a mod voucher's `redeem` once, when it is gained.
function SMODS.redeem_voucher(id)
    local center = SMODS.Centers[id]
    local def = VOUCHER_DEFS and VOUCHER_DEFS[id]
    if not center or not def then return false end
    if type(center.redeem) == "function" then
        SMODS.call(center.mod, center.redeem, center, { ability = deep_copy(def.config or {}) })
    end
    return true
end

--------------------------------------------------------------------------------
-- Deck skins: face-card sets for Options > Art
--------------------------------------------------------------------------------

local FACE_RANKS = { Jack = true, Queen = true, King = true }

--- `SMODS.DeckSkin { key, suit, loc_txt, sprite, hc_sprite }`: a set of Jack, Queen and King
--- art for one suit, offered in the Card Art carousel beside the built-in collab sets.
---
--- Same format as those sets (`card_art.lua`): `sprite` is one strip of three 72x95 cells, J, Q
--- and K left to right (216x95), drawn over the card front exactly like the deck's own faces.
--- `hc_sprite` is the high-contrast strip, used when the player ticks High Contrast for the
--- suit; without one, the normal strip is used at either contrast.
---
--- Steamodded's deck skins name atlases (`lc_atlas`, `hc_atlas`) and can cover any ranks; here
--- every skin is the three face cards, as the built-in sets are.
function SMODS.DeckSkin(t)
    local mod = need_mod("SMODS.DeckSkin")
    check(type(t) == "table", "SMODS.DeckSkin expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.DeckSkin needs a 'key' of letters, digits and underscores")
    local suit = CardArt.suit_key(t.suit)
    check(suit ~= nil, "DeckSkin '" .. t.key .. "': suit must be \"Hearts\", \"Clubs\", \"Diamonds\" or \"Spades\"")
    if t.lc_atlas ~= nil or t.hc_atlas ~= nil or t.atlas ~= nil then
        error(("DeckSkin '%s': atlases aren't supported on 3DS; give it sprite = \"Name.png\", one "
            .. "216x95 strip of J, Q and K (and hc_sprite for high contrast)"):format(t.key), 0)
    end
    if t.ranks ~= nil then
        check(type(t.ranks) == "table", "DeckSkin '" .. t.key .. "': ranks must be a list")
        local n = 0
        for _, rank in ipairs(t.ranks) do
            check(FACE_RANKS[rank], "DeckSkin '" .. t.key .. "': only Jack, Queen and King can be "
                .. "replaced, not '" .. tostring(rank) .. "'")
            n = n + 1
        end
        check(n == 3, "DeckSkin '" .. t.key .. "': ranks must be Jack, Queen and King, all three")
    end
    local lc = register_sprite(mod, t.sprite, "DeckSkin", t.key, "sprite")
    local hc = t.hc_sprite ~= nil and register_sprite(mod, t.hc_sprite, "DeckSkin", t.key, "hc_sprite") or lc

    local loc = t.loc_txt
    local name = type(loc) == "string" and loc
        or type(loc) == "table" and (loc.name or loc["en-us"]) or t.name or t.key
    local id = mod.prefix .. "_" .. t.key
    check(CardArt.find(suit, id) == nil, "DeckSkin '" .. t.key .. "' is defined twice")
    CardArt.register(suit, {
        id = id,
        name = tostring(name),
        path_1 = SMODS.sprite_path(lc),
        path_2 = SMODS.sprite_path(hc),
        mod_id = mod.id,
    })
    mod.registered.deck_skins[#mod.registered.deck_skins + 1] = { suit = suit, id = id }
    return t
end

--------------------------------------------------------------------------------
-- Declarative modifiers
--------------------------------------------------------------------------------

--- The run-wide numbers a mod Joker or Voucher may change just by declaring them in `config`,
--- as vanilla Jokers like Juggler (`h_size`) and Drunkard (`d_size`) do. The port recomputes
--- each of these from what is owned whenever it is asked, so a modifier needs no bookkeeping:
--- it applies while the Joker is held or the Voucher redeemed, and saves with them.
SMODS.MODIFIERS = { h_size = true, d_size = true, hands = true, joker_slots = true, consumable_slots = true }

--- Sum one modifier over owned mod Jokers (their `card.ability`) and redeemed mod Vouchers.
function SMODS.modifier_total(game, key)
    if not next(SMODS.Centers) then return 0 end
    local total = 0
    for _, j in ipairs(game.jokers or {}) do
        if j and j.def and j.def.smods and type(j.ability) == "table" then
            total = total + (tonumber(j.ability[key]) or 0)
        end
    end
    for _, vid in ipairs(type(game.vouchers) == "table" and game.vouchers or {}) do
        local def = SMODS.Centers[vid] and VOUCHER_DEFS[vid]
        if def and type(def.config) == "table" then
            total = total + (tonumber(def.config[key]) or 0)
        end
    end
    return total
end

--- Per-copy state. Steamodded's `card.ability` is the Joker's own copy of its `config`, so two
--- copies of a scaling Joker scale apart; the port's `effect_config` is the shared def table,
--- so mod Jokers get a real copy here (`Joker:init`).
function SMODS.init_ability(joker)
    local def = joker and joker.def
    if type(def) ~= "table" or not def.smods then return end
    joker.ability = deep_copy(def.config or {})
    joker.ability.name = def.name
    local center = def.smods
    if type(center.set_ability) == "function" then
        SMODS.call(center.mod, center.set_ability, center, joker, true)
    end
end

--- `in_pool(self, args)`: false keeps the Joker out of the shop and every random roll.
function SMODS.in_pool(center)
    if type(center) ~= "table" or type(center.in_pool) ~= "function" then return true end
    local ok = SMODS.call(center.mod, center.in_pool, center, {})
    return ok ~= false
end

--- Called by the game when a mod Joker joins or leaves the player's Jokers. Not called while a
--- save is restored: the restored run already carries whatever these changed.
function SMODS.on_joker_added(joker)
    local center = joker and joker.def and joker.def.smods
    if center and center.add_to_deck then SMODS.call(center.mod, center.add_to_deck, center, joker, false) end
end

function SMODS.on_joker_removed(joker)
    local center = joker and joker.def and joker.def.smods
    if center and center.remove_from_deck then SMODS.call(center.mod, center.remove_from_deck, center, joker, false) end
end

--------------------------------------------------------------------------------
-- Creating and destroying cards
--------------------------------------------------------------------------------

--- Steamodded mods create cards mid-run (`SMODS.add_card`, its alias `SMODS.create_card`)
--- and destroy them. The port already creates and destroys for its own effects -- shop
--- purchases, Ankh's clone, Incantation's generated cards -- so these route to those same
--- functions and a created card is a card like any other: it is discovered, saved, scored
--- and its art freed the same way. Capacity is the game's own, checked the same way the
--- game checks it: no room means the call returns nil and nothing is created.

--- Rank names a mod may pass for a playing card, onto the game's rank numbers
--- (`Card:get_id`: Jack 11, Queen 12, King 13, Ace 14). Numbers and numeric strings
--- ("7", "10") are taken as those numbers directly.
local RANK_BY_NAME = { Ace = 14, King = 13, Queen = 12, Jack = 11, A = 14, K = 13, Q = 12, J = 11, T = 10 }
--- A center name the card asks for that nothing registered is an error naming
--- it, where an unknown rank or suit only makes the ask refuse: a typo'd
--- enhancement that quietly vanished would cost a mod its whole effect with
--- nothing to show for it.
local function center_or_error(resolve, value, what, how)
    local resolved = resolve(value)
    if not resolved then
        error(("SMODS.add_card: unknown %s '%s' (use %s)"):format(what, tostring(value), how), 3)
    end
    return resolved
end

--- The `card_data` for one playing card `SMODS.add_card` was asked for, built the way the
--- game builds its own (`{ rank, suit, enhancement, seal }`), or nil when the ask is one
--- the game has no card for. Also accepts the rank/suit on a `card` sub-table, as
--- Steamodded's `create_card` takes them.
local function playing_card_data(t)
    local src = type(t.card) == "table" and t.card or t
    local rank = src.rank
    if type(rank) == "string" then rank = RANK_BY_NAME[rank] or tonumber(rank) end
    rank = tonumber(rank)
    if not rank or rank % 1 ~= 0 or rank < 2 or rank > 14 then return nil end
    local suit = SMODS.suit_name(src.suit)
    if not suit then return nil end
    local data = { rank = rank, suit = suit, enhancement = nil, seal = nil }
    local enhancement = src.enhancement or t.enhancement
    if enhancement ~= nil then
        data.enhancement = center_or_error(enhancement_name, enhancement, "enhancement",
            "a vanilla enhancement, a Steamodded m_ key, or one registered with SMODS.Enhancement")
    end
    local seal = src.seal or t.seal
    if seal ~= nil then
        data.seal = center_or_error(seal_name, seal, "seal",
            "a vanilla seal or one registered with SMODS.Seal")
    end
    local edition = src.edition or t.edition
    if edition ~= nil then
        data.modifier = { edition = center_or_error(edition_value, edition, "edition",
            "foil, holo, polychrome, negative, or one registered with SMODS.Edition") }
    end
    return data
end

local function edition_param(t)
    local edition = t.edition
    if type(edition) == "table" then edition = edition.key or edition.name end
    return edition
end

--- Create a card and give it to the player. One call, by `t.set`:
---   * `"Joker"`: `t.key` is a Joker def id (`"j_joker"`, `"j_<prefix>_<key>"`). Returns
---     the new Joker, or nil when the Joker slots are full or the id is unknown. A mod
---     Joker created this way hears its `add_to_deck`, like a bought one.
---   * `"Tarot"` / `"Planet"` / `"Spectral"` / `"Consumable"`, or a kind registered
---     with `SMODS.ConsumableType`: `t.key` is a consumable
---     def id. Returns the new consumable, or nil when the consumable slots are full
---     (checked with `Game:can_add_consumable`, the shop's own check) or the id is unknown.
---   * `"Playing"`: `t.rank` / `t.suit` name the card (see `playing_card_data`), with
---     optional `enhancement`, `seal` and `edition` -- vanilla names, a Steamodded
---     `m_` key for an enhancement, or a value registered with `SMODS.Enhancement` /
---     `SMODS.Seal` / `SMODS.Edition`. An unregistered center name is an error naming
---     it, unlike an unknown rank or suit. It joins the hand (nil when the hand is full, unless
---     `t.bypass_limit`), or the deck when `t.area` is `"deck"` (or `G.deck`). A hand
---     card returns its node, refreshed as contexts hand cards over; a deck card returns
---     the `card_data` now in the deck.
--- `t.edition` also applies to Jokers and consumables (`"foil"`, `"negative"`, ...).
function SMODS.add_card(t)
    if type(t) ~= "table" or not G then return nil end
    local set = tostring(t.set or "")
    if set == "Joker" then
        if type(t.key) ~= "string" or not (JOKER_DEFS and JOKER_DEFS[t.key]) then return nil end
        local params = {}
        local edition = edition_param(t)
        if edition ~= nil then
            params.edition = center_or_error(edition_value, edition, "edition",
                "foil, holo, polychrome, negative, or one registered with SMODS.Edition")
        end
        if type(t.create_params) == "table" then
            for k, v in pairs(t.create_params) do params[k] = v end
        end
        if not G:add_joker_by_def(t.key, params) then return nil end
        return G.jokers[#G.jokers]
    end
    -- A consumable set by any of its names: the vanilla three, "Consumable" (the def
    -- decides), or a kind registered with `SMODS.ConsumableType`.
    if set == "Consumable" or resolve_consumable_kind(set, nil) ~= nil then
        if type(t.key) ~= "string" or not (CONSUMABLE_DEFS and CONSUMABLE_DEFS[t.key]) then return nil end
        local params = {}
        local edition = edition_param(t)
        if edition ~= nil then
            params.edition = center_or_error(edition_value, edition, "edition",
                "foil, holo, polychrome, negative, or one registered with SMODS.Edition")
        end
        if not G:can_add_consumable(params) then return nil end
        if not G:add_consumable(t.key, params) then return nil end
        return G.consumables[#G.consumables]
    end
    if set == "Playing" then
        local data = playing_card_data(t)
        if not data then return nil end
        if t.area == "deck" or (G.deck and t.area == G.deck) then
            if not G._deck_inject_playing_card or not G:_deck_inject_playing_card(data) then return nil end
            return G.deck.cards[#G.deck.cards]
        end
        local hand = G.hand
        if not hand or not hand.add_card then return nil end
        local node = hand:add_card(data, t.bypass_limit == true)
        if not node then return nil end
        if G.notify_cards_added_to_deck then G:notify_cards_added_to_deck(1) end
        return refresh_card_view(node)
    end
    return nil
end
SMODS.create_card = SMODS.add_card

--- Destroy a held Joker: gone for good, through the game's own removal, so a mod Joker's
--- `remove_from_deck` runs and its art frees exactly as when the game removes one.
--- Unlike selling or the game's own removal, this forces past the eternal sticker --
--- a mod destroying a Joker means it. Returns true when the Joker was held and removed.
function SMODS.destroy_joker(joker)
    if not (G and type(G.jokers) == "table" and G.remove_owned_joker_at) then return false end
    for i, j in ipairs(G.jokers) do
        if j == joker then return G:remove_owned_joker_at(i, true) ~= nil end
    end
    return false
end

--- Destroy a playing card: it leaves the game entirely, never reaching the discard pile,
--- the way Immolate's victims do. `card` may be a hand card's node (what contexts hand
--- over), its `card_data`, or a `card_data` sitting in the deck or the discard pile.
--- Returns true when a card was destroyed.
function SMODS.destroy_card(card)
    if type(card) ~= "table" or not G then return false end
    local data = card.card_data or card
    local hand = G.hand
    if hand and hand.destroy_card_node then
        if card.card_data and hand:destroy_card_node(card) then return true end
        for _, node in ipairs(type(hand.card_nodes) == "table" and hand.card_nodes or EMPTY) do
            if node.card_data == data then return hand:destroy_card_node(node) end
        end
    end
    local deck = G.deck
    for _, list in ipairs({ deck and deck.cards, deck and deck.discard_pile }) do
        if type(list) == "table" then
            for i, c in ipairs(list) do
                if c == data or (data.uid ~= nil and c.uid == data.uid) then
                    -- No node exists for a card sitting in the deck; the veto pass
                    -- still runs, against a scratch view over the card's data.
                    if SMODS.card_destroy_vetoed({ card_data = c }) then return false end
                    table.remove(list, i)
                    return true
                end
            end
        end
    end
    return false
end

--- Steamodded's `destroying_card` pass, asked before a playing card is destroyed:
--- every mod Joker sees the card in `context.destroying_card` and may answer
--- `{ remove = false }` to keep it alive. Any other return (or none) lets the
--- destruction proceed. `Hand:destroy_card_at_index` asks this for cards in hand
--- or in play; `SMODS.destroy_card` asks it for cards in the deck or discard
--- pile. With no mod Joker held this is a no-op, so vanilla destruction is
--- untouched. Returns true when some Joker vetoed the destruction.
function SMODS.card_destroy_vetoed(node)
    if not holding_mod_joker() or type(node) ~= "table" then return false end
    local view = refresh_card_view(node)
    if not view then return false end
    local vetoed = false
    SMODS.ask_jokers(function()
        return { destroying_card = view }
    end, function(_, ret)
        if ret.remove == false then vetoed = true end
    end)
    return vetoed
end

--- Debuff or un-debuff a playing card, through the game's canonical setter
--- (`Game:set_card_debuff`, the persistent `perma_debuff` channel), so the
--- `debuff_card` context fires exactly as for an effect that calls it. `card`
--- is a card node or view, as contexts hand over; a bare `card_data` table has
--- no node to show the other Jokers, so its flag is set with no context.
--- Returns true when the card's state was set.
function SMODS.set_debuff(card, debuffed)
    if type(card) ~= "table" then return false end
    if card.card_data then
        if G and G.set_card_debuff then return G:set_card_debuff(card, debuffed, "smods") end
        card.card_data.perma_debuff = debuffed and true or nil
        return true
    end
    card.perma_debuff = debuffed and true or nil
    return true
end

--------------------------------------------------------------------------------
-- Randomness and text helpers mods expect
--------------------------------------------------------------------------------

--- How many times Oops! All 6s doubles probabilities.
local function oops_factor()
    local n = (G and G.count_jokers_with_id and G:count_jokers_with_id("j_oops")) or 0
    return 2 ^ n
end

--- `numerator in denominator` chance on the run's seeded stream: doubled by each Oops! All 6s,
--- then reshaped by mod Jokers' `mod_probability` / `fix_probability` unless `no_mod` is set.
--- Every Joker hears the outcome (`pseudorandom_result`). Returns whether it hit and, as a port
--- extension, how many times the effect should fire: 1, plus a pass for each
--- `context.probability_success` repetition (`local hit, times = SMODS.pseudorandom_probability(...)`).
function SMODS.pseudorandom_probability(trigger_obj, seed, numerator, denominator, identifier, no_mod)
    seed = tostring(seed or "smods")
    identifier = identifier or seed
    local num, den = tonumber(numerator) or 1, math.max(1, tonumber(denominator) or 1)
    if not no_mod then
        num, den = SMODS.modify_probability(trigger_obj, identifier, num * oops_factor(), den)
    end
    local hit
    if den == math.floor(den) then
        hit = (G and G.random and G:random(seed, 1, den) or math.random(1, den)) <= num
    else
        hit = (G and G.random and G:random(seed) or math.random()) * den < num
    end
    SMODS.probability_result(trigger_obj, identifier, hit, num, den)
    if not hit then return false, 0 end
    return true, 1 + (G and G.probability_retriggers and G:probability_retriggers(identifier, num, den) or 0)
end

--- The numbers a "#1# in #2#" tooltip should show: the same odds a roll would use.
function SMODS.get_probability_vars(trigger_obj, numerator, denominator, identifier, _, no_mod)
    local num, den = tonumber(numerator) or 1, tonumber(denominator) or 1
    if no_mod then return num, den end
    return SMODS.modify_probability(trigger_obj, identifier, num * oops_factor(), den)
end

--- `pseudorandom(seed)` in 0..1, or an integer in `min..max`, on the run's seeded stream.
function SMODS.pseudorandom(seed, min, max)
    seed = tostring(seed or "smods")
    if min and max then
        return G and G.random and G:random(seed, min, max) or math.random(min, max)
    end
    local n = G and G.random and G:random(seed, 1, 1000000) or math.random(1, 1000000)
    return (n - 1) / 999999
end

--- `pseudorandom_element(list, seed)`.
function SMODS.pseudorandom_element(list, seed)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[SMODS.pseudorandom(seed, 1, #list)]
end

--------------------------------------------------------------------------------
-- Wave-1 small systems: money transformation, the game-over question, polls,
-- permanent card fields
--------------------------------------------------------------------------------

--- Offer a money gain to every held mod Joker, in slot order, before it lands.
--- Each Joker whose `calculate` answers `context.money_transform` with an
--- `amount` field replaces the running gain for the next. Only the Joker's OWN
--- impl is asked: Bunco's PC wrapper keys off the held Joker itself, so a
--- Blueprint copying a transformer does not transform. Boss-debuffed Jokers
--- are skipped. Returns the final gain. Depth-capped and snapshot-safe, like
--- the `money_altered` notification it precedes.
function SMODS.transform_money_gain(game, amount, opts)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or type(game) ~= "table" then return amount end
    if game._restoring_run_snapshot then return amount end
    if type(game.jokers) ~= "table" or #game.jokers == 0 then return amount end
    local depth = game._money_transform_depth or 0
    if depth >= 4 then return amount end
    game._money_transform_depth = depth + 1
    local ok, result = pcall(function()
        for _, j in ipairs(game.jokers) do
            local impl = j and j.effect_impl
            if impl and type(impl.transform_money) == "function"
                and not (game.boss_is_joker_debuffed and game:boss_is_joker_debuffed(j)) then
                local new = impl.transform_money(j, amount,
                    { from_shop = opts and opts.from_shop or nil })
                if tonumber(new) then amount = math.floor(tonumber(new)) end
                if amount <= 0 then break end
            end
        end
        return amount
    end)
    game._money_transform_depth = depth
    if ok and tonumber(result) then return math.floor(tonumber(result)) end
    return amount
end

--- Ask the held Jokers, in slot order, whether any of them saves a run that is
--- about to end (`context.game_over`, `saved = true` in the return). A Blueprint
--- or Brainstorm is resolved to the Joker it copies, Steamodded-fashion, and
--- the COPY's slot is what counts. Returns the slot index (into `game.jokers`)
--- of the first saver, or nil. Mr. Bones is the engine's own business; the
--- caller compares indices so the earlier slot wins, as one evaluation would.
function SMODS.game_over_saved(game)
    if type(game) ~= "table" or type(game.jokers) ~= "table" then return nil end
    if game._restoring_run_snapshot then return nil end
    local raw = {
        round_score = Totals.read(game.round_score, 0),
        blind_target = Totals.read(game.current_blind_target, 0),
    }
    for i, j in ipairs(game.jokers) do
        local eff, is_copy = j, false
        if j and j.def and (j.def.id == "j_blueprint" or j.def.id == "j_brainstorm")
            and JokerEffects and JokerEffects.resolve_copy_target then
            local r = JokerEffects.resolve_copy_target(j)
            if type(r) == "table" and r ~= j then eff, is_copy = r, true end
        end
        local impl = eff and eff.effect_impl
        if impl and type(impl.game_over_save) == "function"
            and not (game.boss_is_joker_debuffed and game:boss_is_joker_debuffed(eff)) then
            raw.blueprint = is_copy or nil
            raw.blueprint_card = is_copy and j or nil
            if impl.game_over_save(eff, raw) then return i end
        end
    end
    return nil
end

--- The enhancement/seal polls mods call when they need a random center
--- (`SMODS.poll_enhancement({guaranteed = true})` is MoreFluff's shape). The
--- pool is the vanilla values plus every registered center, weighted by the
--- registration's `config.weight` (default 1; `config.no_poll` or a weight of
--- 0 stays out), drawn on the run's seeded stream. The fork's poll always
--- deals a real center -- there is no "no enhancement" outcome to gate --
--- so `guaranteed` is accepted for source compatibility and `options.key`,
--- when it names a center, returns that center (the draw is still spent).
--- Returns the fork VALUE ("lucky", "red"), not a PC center key.
local function poll_center(options, vanilla, by_value, stream)
    options = type(options) == "table" and options or {}
    local key = options.key
    if key ~= nil then
        SMODS.pseudorandom(stream)
        if by_value[key] then return key end
        for _, v in ipairs(vanilla) do if v == key then return key end end
        for _, entry in pairs(by_value) do
            if entry.key == key and entry.value ~= nil then return entry.value end
        end
        return key
    end
    local pool, total = {}, 0
    for _, v in ipairs(vanilla) do pool[#pool + 1] = { value = v, weight = 1 } total = total + 1 end
    for value, entry in pairs(by_value) do
        local cfg = type(entry.config) == "table" and entry.config or {}
        local w = tonumber(cfg.weight) or tonumber(entry.weight) or 1
        if cfg.no_poll ~= true and entry.no_poll ~= true and w > 0 then
            pool[#pool + 1] = { value = value, weight = w }
            total = total + w
        end
    end
    if #pool == 0 then return nil end
    local roll = SMODS.pseudorandom(stream) * total
    for _, item in ipairs(pool) do
        roll = roll - item.weight
        if roll < 0 then return item.value end
    end
    return pool[#pool].value
end

local VANILLA_ENHANCEMENT_POLL = { "bonus", "mult", "wild", "glass", "steel", "stone", "gold", "lucky" }
local VANILLA_SEAL_POLL = { "gold", "red", "blue", "purple" }

function SMODS.poll_enhancement(options)
    options = type(options) == "table" and options or {}
    local suffix = options.key_append or options.type_key or ""
    return poll_center(options, VANILLA_ENHANCEMENT_POLL, SMODS.EnhancementByValue or {},
        "poll_enhancement" .. tostring(suffix))
end

function SMODS.poll_seal(options)
    options = type(options) == "table" and options or {}
    local suffix = options.key_append or options.type_key or ""
    return poll_center(options, VANILLA_SEAL_POLL, SMODS.SealByValue or {},
        "poll_seal" .. tostring(suffix))
end

--- Permanent per-card fields (Steamodded's `perma_*`): plain numbers stored on
--- the card's data, beside `perma_debuff`, so they persist with the deck and
--- survive saves. Readers: `perma_bonus` (+Chips) and `perma_mult` (+Mult)
--- land with the card's own contribution; `perma_x_chips` / `perma_x_mult`
--- multiply the running totals at the card's step, after its edition;
--- `perma_repetitions` adds trigger passes played and held; `perma_p_dollars`
--- pays at round end while held, retriggered like a Gold card. Effects set
--- them through here (or by writing `card.card_data` directly); a nil value
--- clears the field.
SMODS.PERMA_FIELDS = {
    perma_bonus = true, perma_mult = true, perma_x_chips = true,
    perma_x_mult = true, perma_p_dollars = true, perma_repetitions = true,
}

function SMODS.set_perma(card, field, value)
    if type(card) ~= "table" or not SMODS.PERMA_FIELDS[field] then return false end
    local data = type(card.card_data) == "table" and card.card_data or card
    if type(data) ~= "table" then return false end
    if value == nil then data[field] = nil else data[field] = tonumber(value) end
    return true
end

function SMODS.get_perma(card, field)
    if type(card) ~= "table" then return nil end
    local data = type(card.card_data) == "table" and card.card_data or card
    return tonumber(data[field])
end

--- The handful of vanilla localisation keys mods reach for in messages.
local LOCALIZE = {
    k_upgrade_ex = "Upgrade!", k_duplicated_ex = "Duplicated!", k_reset = "Reset",
    k_safe_ex = "Safe!", k_extinct_ex = "Extinct!", k_eaten_ex = "Eaten!",
    k_again_ex = "Again!", k_nope_ex = "Nope!", k_saved_ex = "Saved!",
    a_chips = "+#1#", a_mult = "+#1# Mult", a_xmult = "X#1# Mult", a_dollars = "$#1#",
}

--- A vanilla key in the live language: `smods.<key>` when the game has it, else the English.
local function localized(key)
    local english = LOCALIZE[key]
    if english == nil then return nil end
    return I18N and I18N.text("smods." .. key, nil, english) or english
end

function SMODS.localize(args, _)
    if type(args) == "table" then
        local text = localized(args.key) or tostring(args.key)
        return (text:gsub("#(%d+)#", function(n)
            local v = args.vars and args.vars[tonumber(n)]
            return v ~= nil and tostring(v) or ""
        end))
    end
    return localized(args) or tostring(args)
end

--- The globals a mod's main file sees beyond the game's own: Steamodded's free functions.
function SMODS.mod_environment(mod)
    local env = {
        SMODS = SMODS,
        localize = SMODS.localize,
        pseudorandom = SMODS.pseudorandom,
        pseudoseed = function(s) return tostring(s) end,
        pseudorandom_element = SMODS.pseudorandom_element,
        -- Vanilla's money change, which Steamodded mods call directly. Routes
        -- through the game's own choke point so `money_altered` fires for it.
        ease_dollars = function(n)
            if G and G.ease_dollars then G:ease_dollars(n) end
        end,
    }
    env._MOD = mod
    return setmetatable(env, { __index = _G })
end

--------------------------------------------------------------------------------
-- Tags (SMODS.Tag)
--------------------------------------------------------------------------------

--- Custom tags by full id (`<prefix>_<key>`), by the type string a held tag
--- carries (`tag.type`, the bare key as the mod wrote it), and by the numeric
--- id the skip poll stores. Types are global, the way consumable kinds are:
--- two mods cannot register the same type, and a type may not reuse a vanilla
--- tag's name. A held tag serializes as its type string, exactly like a
--- vanilla one; a save loaded without the mod keeps the string and every
--- dispatch for it finds no entry and does nothing, so an orphaned tag never
--- crashes a load (the run's mod check refuses a changed mod set anyway).
SMODS.Tags = SMODS.Tags or {}
SMODS.TagByType = SMODS.TagByType or {}
SMODS.TagBySkipId = SMODS.TagBySkipId or {}
local next_tag_order = 1
local next_tag_skip_id = 100

--- The type strings `Tag()` and `Game:addTag` know in vanilla: the tray types
--- plus the `P_TAGS` key spellings (`d_six`, `top_up`, `skip`) that name the
--- same three tags in the catalog.
local VANILLA_TAG_TYPES = { uncommon = true, rare = true, negative = true, foil = true,
    holo = true, polychrome = true, investment = true, voucher = true, boss = true,
    standard = true, charm = true, meteor = true, buffoon = true, handy = true,
    garbage = true, ethereal = true, coupon = true, double = true, juggle = true,
    d6 = true, topup = true, speed = true, orbital = true, economy = true,
    d_six = true, top_up = true, skip = true }

--- The moments the engine actually applies tags at, and so the only ones a
--- registered tag may declare (as its `config.type`, Steamodded-style):
--- `immediate` fires in `Game:addTag` as the tag is gained; `new_blind_choice`
--- at blind-select, one tag per screen; `shop_start` and `shop_final_pass`
--- bracket the shop roll in `Game:enter_shop_after_blind`;
--- `round_start_bonus` as a blind starts (Juggle Tag's seat); `eval` in the
--- Boss payout (Investment Tag's seat); `store_joker_create` as a shop
--- Joker offer is rolled (the draft offer is `context.card`, and an `apply`
--- may rewrite its `id` / `edition` before the offer is priced and built --
--- the Uncommon / Rare Tags' seat in the reference); `store_joker_modify`
--- as a rolled offer is shelved, and again when a shelved offer is rebuilt
--- (the edition tags' seat), with the finished offer as `context.card`.
--- The vanilla `voucher_add` / `tag_add` types still cannot be registered:
--- nothing in this engine runs a tag's own effect when a voucher is
--- redeemed or a tag is gained (a gain raises the `tag_added` Joker
--- context, not a tag moment).
local TAG_MOMENTS = { immediate = true, new_blind_choice = true, shop_start = true,
    shop_final_pass = true, round_start_bonus = true, eval = true,
    store_joker_create = true, store_joker_modify = true }

function SMODS.is_vanilla_tag_type(name)
    return type(name) == "string" and VANILLA_TAG_TYPES[name:lower()] == true
end

--- The registered tag a name means, or nil: the full id ("tg_windfall"), the
--- bare type ("windfall"), in any case.
function SMODS.tag_entry_for(name)
    if type(name) ~= "string" or name == "" then return nil end
    local entry = SMODS.Tags[name] or SMODS.TagByType[name]
    if entry then return entry end
    local lower = name:lower()
    for _, e in pairs(SMODS.TagByType) do
        if e.type:lower() == lower then return e end
    end
    return nil
end

--- `SMODS.Tag { key, loc_txt, config, apply, weight, min_ante, in_pool }`: a
--- tag of this mod's own. It is gained exactly like a vanilla one --
--- `G:addTag("<key>")` or `G:addTag("<full id>")`, the skip poll, Double Tag
--- copies -- and the engine calls `apply(self, tag, context)` at the tag's
--- moment (`config.type`, default `"immediate"`; `context.type` names the
--- moment, `context.tag` is the held tag, whose `ability` is a copy of
--- `config`). Returning true consumes the tag, the way vanilla one-shot tags
--- are consumed; returning false (or having no `apply`) leaves it held.
---
--- `weight` is the tag's share of the skip poll, where every vanilla tag
--- weighs 1: the default 1 makes it as likely as any vanilla tag, 0 keeps it
--- out of the poll (it can still be created directly). `min_ante` gates the
--- poll like a vanilla tag's. `in_pool(self, game)` may veto the poll.
--- Art is the optional `sprite = "Name.png"`, drawn in the tag's box;
--- without one a mod tag draws as a plain outline. Either way it is listed
--- in the collection's Tags category.
function SMODS.Tag(t)
    local mod = need_mod("SMODS.Tag")
    check(type(t) == "table", "SMODS.Tag expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$") ~= nil,
        "SMODS.Tag needs a 'key' of letters, digits and underscores")
    check(VANILLA_TAG_TYPES[t.key:lower()] == nil,
        "Tag '" .. t.key .. "' reuses a vanilla tag type")
    check(t.apply == nil or type(t.apply) == "function",
        "Tag '" .. t.key .. "': apply must be a function")
    check(t.in_pool == nil or type(t.in_pool) == "function",
        "Tag '" .. t.key .. "': in_pool must be a function")
    check(t.loc_vars == nil or type(t.loc_vars) == "function",
        "Tag '" .. t.key .. "': loc_vars must be a function")
    check(t.config == nil or type(t.config) == "table",
        "Tag '" .. t.key .. "': config must be a table")
    local id = mod.prefix .. "_" .. t.key
    check(SMODS.Tags[id] == nil,
        "Tag '" .. t.key .. "' is defined twice (id " .. id .. ")")
    for _, entry in pairs(SMODS.TagByType) do
        check(entry.type:lower() ~= t.key:lower(),
            "Tag '" .. t.key .. "': the type '" .. entry.type
            .. "' is already registered by " .. entry.mod.id)
    end
    local moment = (type(t.config) == "table" and t.config.type) or "immediate"
    check(TAG_MOMENTS[moment] == true,
        "Tag '" .. t.key .. "': moment '" .. tostring(moment)
        .. "' is not one the engine raises for mod tags (immediate, "
        .. "new_blind_choice, shop_start, shop_final_pass, round_start_bonus, eval, "
        .. "store_joker_create, store_joker_modify)")
    local weight = t.weight == nil and 1 or tonumber(t.weight)
    check(weight ~= nil and weight >= 0,
        "Tag '" .. t.key .. "': weight must be a number >= 0")
    local min_ante = t.min_ante == nil and nil or tonumber(t.min_ante)
    check(t.min_ante == nil or min_ante ~= nil,
        "Tag '" .. t.key .. "': min_ante must be a number")
    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = id, key = t.key, type = t.key, mod = mod,
        name = tostring(loc.name or t.name or t.key),
        config = deep_copy(type(t.config) == "table" and t.config or {}),
        apply = t.apply, loc_vars = t.loc_vars, loc_txt = t.loc_txt,
        moment = moment, weight = weight, min_ante = min_ante,
        in_pool = t.in_pool,
        order = next_tag_order, skip_id = next_tag_skip_id,
    }
    if t.sprite ~= nil then
        entry.sprite = register_sprite(mod, t.sprite, "Tag", t.key, "sprite")
    end
    next_tag_order = next_tag_order + 1
    next_tag_skip_id = next_tag_skip_id + 1
    SMODS.Tags[id] = entry
    SMODS.TagByType[entry.type] = entry
    SMODS.TagBySkipId[entry.skip_id] = entry
    mod.registered.tags = mod.registered.tags or {}
    mod.registered.tags[#mod.registered.tags + 1] = id
    register_center_strings(mod, "tag", entry.type, t.loc_txt)
    t.mod = mod
    t.original_key = t.key
    t.key = id
    return t
end

--- Run one registered tag's `apply` for a moment. `extra` fields (the eval
--- payout context, say) are merged into the context the apply sees.
--- Returns whether the tag fired (and so should be consumed).
function SMODS.tag_fire(entry, tag, moment, extra)
    if type(entry.apply) ~= "function" then return false end
    local ctx = {}
    if type(extra) == "table" then for k, v in pairs(extra) do ctx[k] = v end end
    ctx.type = moment
    ctx.tag = tag
    ctx.game = G
    local ret = SMODS.call(entry.mod, entry.apply, entry, tag, ctx)
    return ret and true or false
end

--- `Tag:apply`'s dispatch for a held tag: returns (handled, fired). A type
--- with no entry is not handled, and the vanilla chain runs untouched. A
--- registered tag called at any moment but its own is handled and does not
--- fire -- the pack tags' wait, applied to every moment.
function SMODS.tag_apply(tag, context)
    local entry = tag and SMODS.TagByType[tag.type]
    if not entry then return false end
    local moment = type(context) == "string" and context or "immediate"
    if entry.moment ~= moment then return true, false end
    return true, SMODS.tag_fire(entry, tag, moment, nil)
end

--- Whether a held tag of this type waits for the blind-select screen.
function SMODS.tag_is_blind_choice(type_name)
    local entry = SMODS.TagByType[type_name]
    return entry ~= nil and entry.moment == "new_blind_choice"
end

--- Fire every held registered tag whose moment this is, consuming the ones
--- that fire -- the shape of the vanilla scans (Juggle at blind start, D6 in
--- the shop, Investment in the Boss payout). Returns how many fired.
function SMODS.tag_moment(game, moment, extra)
    if next(SMODS.TagByType) == nil then return 0 end
    if type(game) ~= "table" or type(game.tags) ~= "table" then return 0 end
    local fired = 0
    for i = #game.tags, 1, -1 do
        local tag = game.tags[i]
        local entry = tag and SMODS.TagByType[tag.type]
        if entry and entry.moment == moment
            and SMODS.tag_fire(entry, tag, moment, extra) then
            game:removeTag(i)
            fired = fired + 1
        end
    end
    return fired
end

--- The skip poll's custom half: with probability weight/(vanilla + weight)
--- the slot's vanilla pick is replaced by a registered tag, chosen by
--- weight. Drawn on its own stream ("SMODS_tag_poll<ante>_<slot>"), so the
--- vanilla "Tag<ante>" sequence -- and every candidate it picks -- is
--- exactly what it would be with no tags registered. Returns the winning
--- tag's skip id, or nil when the vanilla pick stands (or none is pooled).
function SMODS.tag_poll_candidate(game, ante, slot, vanilla_available)
    local customs, total_custom = {}, 0
    for _, entry in pairs(SMODS.TagByType) do
        if entry.weight > 0 and (entry.min_ante == nil or ante >= entry.min_ante)
            and (entry.in_pool == nil
                or SMODS.call(entry.mod, entry.in_pool, entry, game)) then
            customs[#customs + 1] = entry
            total_custom = total_custom + entry.weight
        end
    end
    if #customs == 0 then return nil end
    table.sort(customs, function(a, b) return a.order < b.order end)
    local vanilla = tonumber(vanilla_available) or 0
    local roll = game:random("SMODS_tag_poll" .. tostring(ante) .. "_" .. tostring(slot),
        1, 100000) / 100000 * (vanilla + total_custom)
    if roll <= vanilla then return nil end
    local edge = vanilla
    for _, entry in ipairs(customs) do
        edge = edge + entry.weight
        if roll <= edge then return entry.skip_id end
    end
    return customs[#customs].skip_id
end

--- The type string a skip-poll id means, for `Game:tag_type_for_id`.
function SMODS.tag_type_for_skip_id(id)
    local entry = SMODS.TagBySkipId[tonumber(id) or -1]
    return entry and entry.type or nil
end

--- A registered tag's tooltip: its display name and its `loc_txt` lines as
--- plain text (`#n#` filled from `loc_vars`), for the skip-tag tooltip,
--- whose vanilla tables only know the vanilla tags. Returns nil name and
--- no lines for anything unregistered.
function SMODS.tag_tooltip(type_name)
    local entry = SMODS.TagByType[type_name]
    if not entry then return nil, {} end
    local loc = loc_for(entry.loc_txt, I18N and I18N.get_language() or "en") or {}
    local text = loc.text
    if type(text) == "string" then text = { text } end
    if type(text) ~= "table" then return entry.name, {} end
    local vars = {}
    if type(entry.loc_vars) == "function" then
        local ret = SMODS.call(entry.mod, entry.loc_vars, entry, {}, { ability = entry.config })
        if type(ret) == "table" and type(ret.vars) == "table" then vars = ret.vars end
    end
    local lines = {}
    for _, line in ipairs(text) do
        local segs = SMODS.format_line(line, vars).segments
        local parts = {}
        for _, s in ipairs(segs) do parts[#parts + 1] = s.text end
        lines[#lines + 1] = table.concat(parts)
    end
    return entry.name, lines
end

--------------------------------------------------------------------------------
-- Booster packs (SMODS.Booster)
--------------------------------------------------------------------------------

--- Custom pack kinds by full id (`<prefix>_<key>`) and by the pack string a
--- shop offer carries (the bare key, lowercased -- the same slot the vanilla
--- names "arcana" / "celestial" / "spectral" / "standard" / "buffoon" fill).
--- Pack names are global: two mods cannot register the same one, and none
--- may reuse a vanilla name.
SMODS.Boosters = SMODS.Boosters or {}
SMODS.BoosterByPack = SMODS.BoosterByPack or {}
local next_booster_order = 1

local VANILLA_PACK_NAMES = { arcana = true, celestial = true, spectral = true,
    standard = true, buffoon = true }

--- `SMODS.Booster { key, loc_txt, pool, card_count, picks, cost, weight, sprite, colour }`:
--- a booster pack kind of this mod's own. It joins the shop's booster roll
--- at its `weight`, in the profile pool's units (a vanilla normal pack
--- weighs 100, a Mega 25): the draw is the pool's single draw, extended --
--- with nothing registered the pool and the seeded sequence are exactly
--- vanilla's. `cost` is the pack's shop price before inflation and
--- discounts (vanilla packs price 4 / 6 / 8 by size). A registered pack has
--- one size of its own: `card_count` cards (default 3), `picks` of them
--- chosen (default 1).
---
--- `pool` names where its cards come from, mirroring a vanilla kind's
--- choice builder: `{ consumable = "<kind>" }` deals that consumable kind
--- (a vanilla one, or a kind registered with `SMODS.ConsumableType`) through
--- the pack flow, Soul / Black Hole polls included for the kinds that have
--- them; `{ jokers = true }` deals unique Jokers like a Buffoon pack;
--- `{ playing = true }` deals playing cards like a Standard pack.
---
--- `sprite = "Name.png"` is the wrapper art, drawn on the shop shelf and
--- as the pack flies open; without one the pack draws the plain booster
--- fallback panel. `colour = { r, g, b }` tints its opening burst.
function SMODS.Booster(t)
    local mod = need_mod("SMODS.Booster")
    check(type(t) == "table", "SMODS.Booster expects a table")
    check(type(t.key) == "string" and t.key:match("^[%w_]+$"),
        "SMODS.Booster needs a 'key' of letters, digits and underscores")
    local pack = t.key:lower()
    check(VANILLA_PACK_NAMES[pack] == nil,
        "Booster '" .. t.key .. "' reuses a vanilla pack name")
    local clash = SMODS.BoosterByPack[pack]
    check(clash == nil, "Booster '" .. t.key .. "': the pack '" .. pack
        .. "' is already registered by " .. (clash and clash.mod.id or "?"))
    local id = mod.prefix .. "_" .. t.key
    check(SMODS.Boosters[id] == nil,
        "Booster '" .. t.key .. "' is defined twice (id " .. id .. ")")

    check(type(t.pool) == "table",
        "Booster '" .. t.key .. "': pool must be a table: { consumable = \"<kind>\" }, "
        .. "{ jokers = true } or { playing = true }")
    local pool_kind, consumable_kind
    if t.pool.consumable ~= nil then
        pool_kind = "consumable"
        local want = t.pool.consumable
        if type(want) == "string" and SMODS.ConsumableKinds[want] then
            consumable_kind = want
        elseif type(want) == "string" then
            local lower = want:lower()
            if lower == "tarot" or lower == "planet" or lower == "spectral" then
                consumable_kind = lower
            else
                for _, e in pairs(SMODS.ConsumableKinds) do
                    if e.kind:lower() == lower then consumable_kind = e.kind break end
                end
            end
        end
        check(consumable_kind ~= nil,
            "Booster '" .. t.key .. "': pool.consumable '" .. tostring(want)
            .. "' is not a consumable kind (a vanilla kind, or one registered "
            .. "with SMODS.ConsumableType first)")
    elseif t.pool.jokers then
        pool_kind = "jokers"
    elseif t.pool.playing then
        pool_kind = "playing"
    end
    check(pool_kind ~= nil,
        "Booster '" .. t.key .. "': pool names no source: { consumable = \"<kind>\" }, "
        .. "{ jokers = true } or { playing = true }")

    local card_count = t.card_count == nil and 3 or math.floor(tonumber(t.card_count) or -1)
    check(card_count >= 1 and card_count <= 10,
        "Booster '" .. t.key .. "': card_count must be a whole number from 1 to 10")
    local picks = t.picks == nil and 1 or math.floor(tonumber(t.picks) or -1)
    check(picks >= 1 and picks <= card_count,
        "Booster '" .. t.key .. "': picks must be a whole number from 1 to card_count")
    local cost = t.cost == nil and 4 or math.floor(tonumber(t.cost) or -1)
    check(cost >= 0, "Booster '" .. t.key .. "': cost must be a whole number >= 0")
    local weight = t.weight == nil and 60 or tonumber(t.weight)
    check(weight ~= nil and weight >= 0,
        "Booster '" .. t.key .. "': weight must be a number >= 0 (0 keeps it out of the shop roll)")

    local loc = loc_for(t.loc_txt, "en") or {}
    local entry = {
        id = id, key = t.key, pack = pack, mod = mod,
        name = tostring(loc.name or t.name or t.key),
        pool_kind = pool_kind, consumable_kind = consumable_kind,
        card_count = card_count, picks = picks, cost = cost, weight = weight,
        colour = type(t.colour) == "table" and t.colour or nil,
        loc_txt = t.loc_txt,
        order = next_booster_order,
    }
    next_booster_order = next_booster_order + 1
    if t.sprite ~= nil then
        entry.sprite = register_sprite(mod, t.sprite, "Booster", t.key, "sprite")
    end
    SMODS.Boosters[id] = entry
    SMODS.BoosterByPack[pack] = entry
    mod.registered.boosters = mod.registered.boosters or {}
    mod.registered.boosters[#mod.registered.boosters + 1] = id
    register_center_strings(mod, "booster", pack, t.loc_txt)
    t.mod = mod
    t.original_key = t.key
    t.key = id
    return t
end

--- The registered pack a name means, or nil: the pack string a shop offer
--- carries (the bare key, in any case) or the full id.
function SMODS.booster_entry_for(name)
    if type(name) ~= "string" or name == "" then return nil end
    return SMODS.Boosters[name] or SMODS.BoosterByPack[name]
        or SMODS.BoosterByPack[name:lower()]
end

--- The custom half of the shop's booster profile pool: one entry per
--- registered pack with weight, shaped like the vanilla entries
--- (`key` = the pack's full id, `size` = "normal" -- a registered pack has
--- one size of its own), in registration order. Empty while no pack is
--- registered, and the vanilla pool is then exactly what it was.
function SMODS.booster_profile_entries()
    local out = {}
    for _, entry in pairs(SMODS.Boosters) do
        if entry.weight > 0 then
            out[#out + 1] = {
                key = entry.id, pack = entry.pack, size = "normal",
                weight = entry.weight, frame = nil, booster = entry,
            }
        end
    end
    table.sort(out, function(a, b) return a.booster.order < b.booster.order end)
    return out
end

--------------------------------------------------------------------------------
-- Rollback
--------------------------------------------------------------------------------

--- Undo everything a mod registered. A mod that throws halfway through its main file is not
--- left half-installed: everything it registered goes with it.
function SMODS.rollback(mod)
    if type(mod) ~= "table" or type(mod.registered) ~= "table" then return end
    for _, id in ipairs(mod.registered.jokers) do
        if JOKER_DEFS then JOKER_DEFS[id] = nil end
        SMODS.Centers[id] = nil
        JokerEffects.unregister(id)
    end
    for _, id in ipairs(mod.registered.consumables or {}) do
        if CONSUMABLE_DEFS then CONSUMABLE_DEFS[id] = nil end
        SMODS.Centers[id] = nil
    end
    for _, id in ipairs(mod.registered.vouchers or {}) do
        if VOUCHER_DEFS then VOUCHER_DEFS[id] = nil end
        SMODS.Centers[id] = nil
    end
    for _, id in ipairs(mod.registered.rarities or {}) do
        local entry = SMODS.Rarities[id]
        if entry then SMODS.RarityByIndex[entry.index] = nil end
        SMODS.Rarities[id] = nil
    end
    mod.registered.rarities = {}
    for _, id in ipairs(mod.registered.consumable_types or {}) do
        local entry = SMODS.ConsumableTypes[id]
        if entry then SMODS.ConsumableKinds[entry.kind] = nil end
        SMODS.ConsumableTypes[id] = nil
    end
    mod.registered.consumable_types = {}
    for _, id in ipairs(mod.registered.tags or {}) do
        local entry = SMODS.Tags[id]
        if entry then
            SMODS.TagByType[entry.type] = nil
            SMODS.TagBySkipId[entry.skip_id] = nil
        end
        SMODS.Tags[id] = nil
    end
    mod.registered.tags = {}
    for _, id in ipairs(mod.registered.boosters or {}) do
        local entry = SMODS.Boosters[id]
        if entry then SMODS.BoosterByPack[entry.pack] = nil end
        SMODS.Boosters[id] = nil
    end
    mod.registered.boosters = {}
    for _, id in ipairs(mod.registered.enhancements or {}) do
        local entry = SMODS.Enhancements[id]
        if entry then SMODS.EnhancementByValue[entry.value] = nil end
        SMODS.Enhancements[id] = nil
    end
    mod.registered.enhancements = {}
    for _, id in ipairs(mod.registered.seals or {}) do
        local entry = SMODS.Seals[id]
        if entry then SMODS.SealByValue[entry.value] = nil end
        SMODS.Seals[id] = nil
    end
    mod.registered.seals = {}
    for _, id in ipairs(mod.registered.editions or {}) do
        local entry = SMODS.Editions[id]
        if entry then SMODS.EditionByValue[entry.value] = nil end
        SMODS.Editions[id] = nil
    end
    mod.registered.editions = {}
    for _, name in ipairs(mod.registered.suits or {}) do SMODS.Suits[name] = nil end
    mod.registered.suits = {}
    for _, name in ipairs(mod.registered.poker_hands or {}) do
        -- The registry forgets the hand, so no game built from now on lists it. A
        -- game already built keeps the name in its `handlist` (with its stats):
        -- removing it mid-run would renumber every hand after it, and the saved
        -- run's mod check refuses to continue on a changed mod set anyway.
        SMODS.PokerHandByName[name] = nil
        for i = #SMODS.PokerHands, 1, -1 do
            if SMODS.PokerHands[i].key == name then table.remove(SMODS.PokerHands, i) end
        end
    end
    mod.registered.poker_hands = {}
    for _, set in ipairs(mod.registered.strings or {}) do
        if I18N and I18N.remove_strings then I18N.remove_strings(set.language, set.keys) end
    end
    mod.registered.strings = {}
    for _, skin in ipairs(mod.registered.deck_skins or {}) do CardArt.unregister(skin.suit, skin.id) end
    mod.registered.deck_skins = {}
    for _, key in ipairs(mod.registered.sprites or {}) do SMODS.Sprites[key] = nil end
    mod.registered.jokers, mod.registered.sprites = {}, {}
    mod.registered.consumables, mod.registered.vouchers = {}, {}
end

return SMODS
