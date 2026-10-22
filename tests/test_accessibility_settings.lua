local T = require("tests.testlib")
local bootstrap = require("tests.bootstrap")
local CardArt = require("card_art")

local suite = T.suite()

suite.test("master volume is adjustable and survives settings normalization", function()
    local game = bootstrap.new_game(7301)
    game:set_master_volume(37, { skip_save = true })
    T.assert_eq(game:get_master_volume(), 37)
    T.assert_eq(game:snapshot_settings().SOUND.volume, 37)
    T.assert_eq(game:normalize_settings({ SOUND = { volume = 142 } }).SOUND.volume, 100)
end)

suite.test("ordinary cards default to the standard atlas", function()
    local game = bootstrap.new_game(7302)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    local card = Card(0, 0, 1, 1, { rank = 14, suit = "Spades" })
    T.assert_eq(card.rank_atlas_name, "cards_1")
end)

suite.test("high contrast is per suit and switches existing and future cards", function()
    local game = bootstrap.new_game(7303)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    local hearts = Card(0, 0, 1, 1, { rank = 10, suit = "Hearts" })
    local clubs = Card(0, 0, 1, 1, { rank = 10, suit = "Clubs" })
    local explicit = Card(0, 0, 1, 1, { rank = 9, suit = "Hearts" }, nil,
        { rank_atlas_name = "cards_1" })
    T.assert_true(game:set_card_art("Hearts", nil, true))
    T.assert_eq(hearts.rank_atlas_name, "cards_2")
    T.assert_eq(clubs.rank_atlas_name, "cards_1", "other suits keep their own contrast")
    T.assert_eq(explicit.rank_atlas_name, "cards_1", "explicit atlases are left alone")
    local future = Card(0, 0, 1, 1, { rank = 8, suit = "Hearts" })
    T.assert_eq(future.rank_atlas_name, "cards_2")
end)

suite.test("a collab replaces only that suit's face cards", function()
    local game = bootstrap.new_game(7305)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    game:set_card_art("Clubs", "VS", false)
    local king = Card(0, 0, 1, 1, { rank = 13, suit = "Clubs" })
    local jack = Card(0, 0, 1, 1, { rank = 11, suit = "Clubs" })
    local ten = Card(0, 0, 1, 1, { rank = 10, suit = "Clubs" })
    local other_king = Card(0, 0, 1, 1, { rank = 13, suit = "Spades" })
    T.assert_eq(king.rank_atlas_name, "collab_clubs_VS_1")
    T.assert_eq(jack.rank_atlas_name, "collab_clubs_VS_1")
    T.assert_eq(ten.rank_atlas_name, "cards_1", "number cards stay on the deck sheet")
    T.assert_eq(other_king.rank_atlas_name, "cards_1")
    T.assert_eq(king.rank_index, 13 - 2 + 13, "rank_index still names the deck cell")

    game:set_card_art("Clubs", "VS", true)
    T.assert_eq(king.rank_atlas_name, "collab_clubs_VS_2", "contrast picks the _2 sheet")
    T.assert_eq(ten.rank_atlas_name, "cards_2")

    game:set_card_art("Clubs", nil, false)
    T.assert_eq(king.rank_atlas_name, "cards_1", "Default returns to the deck's own art")
end)

suite.test("collab sprites pick the J, Q and K cells", function()
    local art = CardArt.default_settings()
    art.Diamonds.collab = "SV"
    for rank, cell in pairs({ [11] = 0, [12] = 1, [13] = 2 }) do
        local name, index = CardArt.face_sprite(art, rank, "diamonds", 99)
        T.assert_eq(name, "collab_diamonds_SV_1")
        T.assert_eq(index, cell)
    end
    local name, index = CardArt.face_sprite(art, 14, "Diamonds", 38)
    T.assert_eq(name, "cards_1", "aces are not part of a collab")
    T.assert_eq(index, 38)
end)

suite.test("every catalog entry has both sheets on disk", function()
    for _, entry in ipairs(CardArt.atlas_entries()) do
        local f = io.open(entry.path, "rb")
        T.assert_true(f ~= nil, entry.path .. " should exist")
        if f then f:close() end
    end
end)

suite.test("card art persists and rejects unknown collabs", function()
    local game = bootstrap.new_game(7304)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    game:set_card_art("Spades", "TW", true)
    local snapshot = game:snapshot_settings()
    T.assert_eq(snapshot.CARD_ART.Spades.collab, "TW")
    T.assert_true(snapshot.CARD_ART.Spades.contrast)
    local restored = game:normalize_settings(snapshot).CARD_ART
    T.assert_eq(restored.Spades.collab, "TW")
    T.assert_true(restored.Spades.contrast)
    T.assert_false(restored.Hearts.contrast)

    T.assert_false(game:set_card_art("Spades", "VS", false), "VS is a Clubs collab")
    local bad = game:normalize_settings({ CARD_ART = { Hearts = { collab = "nope", contrast = true } } })
    T.assert_eq(bad.CARD_ART.Hearts.collab, nil)
    T.assert_true(bad.CARD_ART.Hearts.contrast)
end)

suite.test("the old global contrast switch migrates to every suit", function()
    local game = bootstrap.new_game(7306)
    local migrated = game:normalize_settings({ HIGH_CONTRAST_CARDS = true }).CARD_ART
    for _, suit in ipairs(CardArt.SUITS) do
        T.assert_true(migrated[suit].contrast, suit .. " should be high contrast")
        T.assert_eq(migrated[suit].collab, nil)
    end
end)

suite.test("the art panel applies its choice as soon as it changes", function()
    local game = bootstrap.new_game(7307)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    game:open_card_art_panel()
    game:art_select_suit(4) -- Spades
    game:art_cycle(1)
    T.assert_eq(game:get_card_art("Spades").collab, CardArt.COLLABS.Spades[1].id, "stepping the carousel applies it")
    T.assert_false(game:get_card_art("Spades").contrast)
    game:art_toggle_contrast()
    T.assert_true(game:get_card_art("Spades").contrast, "the checkbox applies too")

    game:art_cycle(-1)
    T.assert_eq(game:get_card_art("Spades").collab, nil, "back to the deck's own art")
    T.assert_eq(game:get_card_art("Hearts").collab, nil, "other suits are untouched")
    game:art_select_suit(4)
    T.assert_eq(game._art_pick, 1, "reselecting a suit reloads its saved choice")
end)

suite.test("the art preview is live cards that flip to a new choice and are freed on close", function()
    local game = bootstrap.new_game(7308)
    game.SETTINGS.CARD_ART = CardArt.default_settings()
    local registered = #G.I.CARD
    game:open_card_art_panel()
    game:art_select_suit(2) -- Clubs
    game:art_destroy_preview()
    game:art_ensure_preview_cards()
    T.assert_eq(#game._art_cards, 3)
    T.assert_eq(#G.I.CARD, registered + 3)

    local jack = game._art_cards[1]
    T.assert_eq(jack.rank_atlas_name, "cards_1")
    game:art_cycle(1)
    T.assert_eq(jack.rank_atlas_name, "cards_1", "the art swaps edge-on, not at the press")
    G.real_dt = 1 / 60
    for _ = 1, 60 do jack:update(1 / 60) end
    T.assert_eq(jack.rank_atlas_name, CardArt.atlas_name("Clubs", CardArt.COLLABS.Clubs[1].id, false))
    T.assert_eq(jack.rank_index, 0)
    T.assert_eq(game:get_card_art("Clubs").collab, CardArt.COLLABS.Clubs[1].id, "the shown art is the one in use")

    game:close_card_art_panel()
    T.assert_eq(game._art_cards, nil)
    T.assert_eq(#G.I.CARD, registered, "preview cards leave the card registry")
end)

return suite
