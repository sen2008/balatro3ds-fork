--- Per-suit card art: which face-card collab each suit uses, and whether it is drawn from
--- the high-contrast sheets.
---
--- The collab sheets live at `resources/textures/1x/collabs/<suit>/collab_<ID>_<n>.png`,
--- one row of three 72x95 cells, J, Q and K left to right -- the deck's own cell size, so
--- they overlay the card front exactly as `8BitDeck.png` does. `_1` is the normal sheet and
--- `_2` the high-contrast one, mirroring `cards_1` / `cards_2`.
---
--- A collab only replaces the three face cards. Contrast applies to the whole suit: a
--- high-contrast suit draws its number cards from `cards_2` and its faces from the collab's
--- `_2` sheet, so the suit reads as one set whichever art it uses.
---
--- Mods add sets of their own (`SMODS.DeckSkin`, `smods.lua`) through `CardArt.register`: same
--- three-cell strip, same `_1` / `_2` pairing, but the files live in the mod's folder, so their
--- entries carry their own paths. They join the end of their suit's carousel.
---
--- This module is pure: it knows the catalog and the rules, and the game owns the settings
--- table and the live cards (`Game:set_card_art`).

local CardArt = {}

--- Suit order, matching the rows of the deck sheets (`card.lua` suit offsets).
CardArt.SUITS = { "Hearts", "Clubs", "Diamonds", "Spades" }

--- Collabs per suit, in carousel order. `id` is the code in the sheet's file name.
CardArt.COLLABS = {
    Hearts = {
        { id = "AU",   name = "Among Us" },
        { id = "BUG",  name = "Bugsnax" },
        { id = "CL",   name = "Lambs in a Cult" },
        { id = "CR",   name = "Critical Role" },
        { id = "D2",   name = "Rivellon Pack" },
        { id = "TBoI", name = "Bible Thump" },
    },
    Clubs = {
        { id = "DBD", name = "The Fog" },
        { id = "FO",  name = "Vault-Tec" },
        { id = "PC",  name = "Potion Craft" },
        { id = "STS", name = "Slay the Spire" },
        { id = "VS",  name = "Survivors" },
        { id = "WF",  name = "Tenno Awakening" },
    },
    Diamonds = {
        { id = "C7",  name = "Civilization VII" },
        { id = "DTD", name = "Dave the Diver" },
        { id = "EG",  name = "Bullet Kin" },
        { id = "R",   name = "Facepunch Survivors" },
        { id = "SV",  name = "Stardew Valley" },
        { id = "XR",  name = "Hekki Grace" },
    },
    Spades = {
        { id = "AC",  name = "Ezio and Friends" },
        { id = "CYP", name = "Night City" },
        { id = "DS",  name = "Nightmare Throne" },
        { id = "SK",  name = "Shovel Knight" },
        { id = "STP", name = "A Path in the Woods" },
        { id = "TW",  name = "The Continent" },
    },
}

CardArt.CELL_W = 72
CardArt.CELL_H = 95

--- Ranks the collab sheets cover, mapped to their cell.
local FACE_CELL = { [11] = 0, [12] = 1, [13] = 2 }

local SUIT_BY_LOWER = { hearts = "Hearts", clubs = "Clubs", diamonds = "Diamonds", spades = "Spades" }

--- Canonical suit name from whatever a card carries ("hearts", "Hearts", or 1..4).
--- @return string|nil
function CardArt.suit_key(suit)
    if type(suit) == "string" then return SUIT_BY_LOWER[suit:lower()] end
    if type(suit) == "number" then return CardArt.SUITS[suit] end
    return nil
end

--- @return table|nil the catalog entry for `id` in `suit`
function CardArt.find(suit, id)
    local key = CardArt.suit_key(suit)
    if not key or type(id) ~= "string" then return nil end
    for _, entry in ipairs(CardArt.COLLABS[key]) do
        if entry.id == id then return entry end
    end
    return nil
end

--- @return string asset-atlas name of one collab sheet
function CardArt.atlas_name(suit, id, contrast)
    return ("collab_%s_%s_%d"):format(CardArt.suit_key(suit):lower(), id, contrast and 2 or 1)
end

--- @return string
function CardArt.sheet_path(suit, id, contrast)
    -- A mod's set names its own files (`CardArt.register`).
    local entry = CardArt.find(suit, id)
    if entry and entry.path_1 then
        return contrast and (entry.path_2 or entry.path_1) or entry.path_1
    end
    return ("resources/textures/1x/collabs/%s/collab_%s_%d.png"):format(
        CardArt.suit_key(suit):lower(), id, contrast and 2 or 1)
end

--- Add a set of face cards to a suit's carousel.
--- @param suit string
--- @param entry table `{ id, name, path_1, path_2?, mod_id? }`; `path_2` is the high-contrast
---   strip, and a set without one uses its normal strip at either contrast
--- @return boolean ok false when the suit is unknown or the id is taken
function CardArt.register(suit, entry)
    local key = CardArt.suit_key(suit)
    if not key or type(entry) ~= "table" or type(entry.id) ~= "string" then return false end
    if CardArt.find(key, entry.id) then return false end
    table.insert(CardArt.COLLABS[key], entry)
    return true
end

--- Take a registered set back out.
function CardArt.unregister(suit, id)
    local list = CardArt.COLLABS[CardArt.suit_key(suit) or ""]
    for i = #(list or {}), 1, -1 do
        if list[i].id == id then table.remove(list, i) end
    end
end

--- Asset-atlas entries for every collab sheet, in the shape `Game` registers `asset_atli`.
--- All lazy: only the sheets a suit actually uses are ever read off the card.
--- @return table[]
function CardArt.atlas_entries()
    local out = {}
    for _, suit in ipairs(CardArt.SUITS) do
        for _, entry in ipairs(CardArt.COLLABS[suit]) do
            for _, contrast in ipairs({ false, true }) do
                out[#out + 1] = {
                    name = CardArt.atlas_name(suit, entry.id, contrast),
                    path = CardArt.sheet_path(suit, entry.id, contrast),
                    px = CardArt.CELL_W, py = CardArt.CELL_H, cols = 3, rows = 1,
                }
            end
        end
    end
    return out
end

--- Carousel entries for one suit: the deck's own art first, then each collab.
--- @return table[] `{ id = string|nil, name = string }`
function CardArt.carousel(suit)
    local out = { { id = nil, name = "Default" } }
    for _, entry in ipairs(CardArt.COLLABS[CardArt.suit_key(suit)] or {}) do
        out[#out + 1] = entry
    end
    return out
end

--- Every suit on the deck's own art at normal contrast. `collab` is absent for the default.
--- @return table
function CardArt.default_settings()
    local out = {}
    for _, suit in ipairs(CardArt.SUITS) do
        out[suit] = { contrast = false }
    end
    return out
end

--- Validate a saved CARD_ART table. Unknown suits and collabs fall back to the default rather
--- than failing the load, so removing a collab from the catalog cannot break a save.
---
--- `legacy_high_contrast` is the old single HIGH_CONTRAST_CARDS switch: a save from before
--- per-suit art carries only that, and it meant every suit.
--- @return table
function CardArt.normalize(data, legacy_high_contrast)
    local out = CardArt.default_settings()
    if type(data) ~= "table" then
        if legacy_high_contrast == true then
            for _, suit in ipairs(CardArt.SUITS) do out[suit].contrast = true end
        end
        return out
    end
    for _, suit in ipairs(CardArt.SUITS) do
        local saved = data[suit]
        if type(saved) == "table" then
            out[suit].contrast = saved.contrast == true
            if CardArt.find(suit, saved.collab) then
                out[suit].collab = saved.collab
            end
        end
    end
    return out
end

--- Where one card's rank-and-suit layer comes from.
---
--- @param art table normalized CARD_ART
--- @param rank number 2..14
--- @param suit any
--- @param default_index number the card's cell in the deck sheets
--- @return string atlas_name
--- @return number index
function CardArt.face_sprite(art, rank, suit, default_index)
    local key = CardArt.suit_key(suit)
    local choice = key and type(art) == "table" and art[key] or nil
    local contrast = choice and choice.contrast == true or false
    local cell = FACE_CELL[tonumber(rank)]
    if choice and cell and CardArt.find(key, choice.collab) then
        return CardArt.atlas_name(key, choice.collab, contrast), cell
    end
    return contrast and "cards_2" or "cards_1", default_index
end

return CardArt
