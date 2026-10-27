# Modding Balatro3DS

Balatro3DS loads mods written in the [Steamodded](https://github.com/Steamodded/smods) style: a folder with a `.json` manifest and a Lua file that calls `SMODS.Joker { ... }`, `SMODS.Consumable { ... }`, `SMODS.Voucher { ... }` and `SMODS.DeckSkin { ... }`. Simple Steamodded Jokers, such as the ones in [Steamodded's examples](https://github.com/Steamodded/examples/tree/master/Mods/JokerExamples), port with few changes. The main one is the art: here **every card is its own image file**, the way the game stores its own Jokers and consumables, instead of Steamodded's atlases. This is not Steamodded, though. There is no Lovely, no `G.GAME` and no shaders, and for now mods can add **Jokers, Tarots, Planets, Spectrals, Vouchers and face-card sets, plus their own rarities, suits, poker hands and consumable types**.

A working example is in [`dev/example_mods/ExampleJokers`](dev/example_mods/ExampleJokers).

## Where mods go

Mods live in a `mods` folder in the game's save directory on the SD card, next to the run saves (`Balatro3DS_run_save_1.lua` and friends). The game creates the folder the first time it starts.

```
mods/
├── mods_log.txt                 written every boot: what loaded, and why anything didn't
├── enabled.txt                  the mods turned on in Options → Mods: the only ones that load
└── ExampleJokers/
    ├── ExampleJokers.json       manifest
    ├── ExampleJokers.lua        main file
    └── assets/1x/               one image per card
        ├── plus_four.t3x        what the 3DS loads
        ├── plus_four.png        optional, for desktop testing
        ├── plus_four_negative.t3x
        └── ...
```

**Options → Mods** in the game lists every mod, whether it loaded, and any errors. Each mod has an **ON/OFF** switch: tap its row, or pick it with Up/Down and press A. **Mods are opt-in: the game starts with none of them loaded.** The ids of the mods that are on are kept in `mods/enabled.txt`, one per line, which you can also edit by hand; that file is the whole selection, so a card with no `mods/enabled.txt` loads no mods at all. (`mods/disabled.txt`, written by older builds, is ignored by this one — the enabled list is the only selection there is. Delete the old file or leave it; it has no effect.)

**Turning a mod ON loads it into the running session at once, with no restart.** Its main file runs exactly as it does at boot (same environment, same rollback if it fails, the error on its row and in `mods_log.txt`), then the collection and the game's hand/rarity/suit tables are refreshed, so its cards can roll and be browsed straight away. Anything it depends on loads first, in dependency order; a dependency that is not installed refuses the load with that reason. A dependency that was not turned on is loaded on the way **and added to `mods/enabled.txt`**, so the set that works in the session is the set that boots next time. Turning a mod on also retries mods that failed only because it was missing. A mod that failed to load can be retried the same way: fix its files, then switch it off and on.

**At boot, only the mods in `mods/enabled.txt` load — dependencies are not pulled in.** An enabled mod whose dependencies are not enabled does not load; its row and `mods_log.txt` give the reason ("needs mod '…', which is turned off"). Turn the dependency on (in the menu, which loads the mod there and then) or add its id to `mods/enabled.txt` by hand.

**Turning a mod OFF only records the choice.** A loaded mod is never unloaded mid-session (its cards may be anywhere), so its content keeps working until the end of the session and it stops loading from the next boot on; its row says "applies next boot". From that next boot it doesn't run at all, and mods that depend on it don't load either.

**Mod switches never load anything while a run is in progress.** The Mods page is reached from the main menu, but if a switch is flipped while a run is in memory, turning a mod on only queues the choice (its row reads "Loads at next boot") and the mod loads when the game next starts.

### Bundled mods (the "super" build)

One build variant — `dev/build.sh --super`, published as `Balatro-super.cia` — carries a set of packs inside the game archive itself, in a `mods_bundled/` folder with the same layout as above. They are part of the game install, not the card:

- Bundled packs appear in **Options → Mods** and in `mods_log.txt` exactly like card mods; the log line marks them `(…, bundled)`. Everything else about them is the same too: they are **opt-in** (nothing loads until you turn it on), turning one on loads it in-session, and the selection still lives in `mods/enabled.txt` on the card.
- **A card copy wins.** Identity is the manifest `id`: if the same id is also in `mods/`, the card copy is the one that loads and the bundled copy is skipped (the log says it was shadowed). To update a bundled pack, drop the newer version in `mods/` as usual; delete the card copy and the bundled one takes over again.
- The archive is read-only, so nothing is ever written into a bundled pack's folder. A bundled pack's compiled cache (the `<main_file>.luac` the loader keeps to skip recompiling) is redirected to `mods/.cache/` on the card; the super build also ships a precompiled cache beside each bundled main file, so even a bundled pack's first load skips compiling.
- **Bundled packs can only be removed by installing a different CIA** (the plain build has none). Turning a bundled pack off just stops it loading, like any other mod.

## Manifest

Steamodded's format. `id`, `prefix` and `main_file` are required.

```json
{
    "id": "ExampleJokers",
    "name": "Example Jokers",
    "author": ["You"],
    "description": "What it does.",
    "prefix": "exj",
    "main_file": "ExampleJokers.lua",
    "version": "1.0.0",
    "dependencies": ["SomeOtherMod (>=1.0.0)"]
}
```

- **`prefix`** namespaces everything the mod defines. A Joker with `key = "plus_four"` becomes `j_exj_plus_four`. Use letters, digits and `_` only. Two mods can't share a prefix.
- **`dependencies`** name other mods by `id`; the version clause is not checked. `Steamodded` is ignored, so manifests copied from Steamodded mods work as they are.
- **`version`** matters for saves (see below). Change it whenever a change would affect a run in progress.

## Images: one file per card, as `.t3x`

Each card points at its own image in `assets/1x/` with `sprite = "plus_four.png"`. The game handles mod images exactly like its own: it loads one when the card first appears and frees it when the last copy goes, so a mod's art costs memory only while it's on screen.

The 3DS only loads textures in its own `.t3x` format, and the game does not convert anything. You do. Name the file as a `.png`. When asked for `plus_four.png`, the console loads `plus_four.t3x` from the same folder. Ship the `.t3x`; the `.png` is only needed for desktop testing.

```sh
tex3ds -f rgba plus_four.png -o plus_four.t3x
```

`tex3ds` comes with [devkitPro](https://devkitpro.org/wiki/Getting_Started) (`3ds-dev`).

Use the same sizes as the game's own art:

| Card | Image |
|---|---|
| Joker (and its soul and negative images) | 70 × 94 |
| Tarot, Planet, Spectral | 64 × 128, with the card in the top 64 × 96 and the rest transparent |
| Voucher | 72 × 95 |
| Deck skin (face cards) | 216 × 95: three 72 × 95 cells, J, Q, K |

Consumables are padded to 64 × 128 on purpose. A `.t3x` is stored at power-of-two sizes, and the game's own consumables use that exact layout so the card is never stretched. Copy it.

- **Missing images:** a missing image file (neither the `.png` nor the `.t3x`) is a load error that names the file.
- **`SMODS.Atlas`:** raises an error that tells you to use `sprite` instead. To port a Steamodded mod, cut its atlas into one image per card.

## Jokers

```lua
SMODS.Joker {
    key = "plus_four",
    loc_txt = { name = "Plus Four", text = { "{C:mult}+#1#{} Mult" } },
    config = { extra = { mult = 4 } },
    rarity = 1,              -- 1-4, a name ("Common" .. "Legendary"), or an SMODS.Rarity key
    cost = 3,
    sprite = "plus_four.png",
    blueprint_compat = true,
    loc_vars = function(self, info_queue, card)
        return { vars = { card.ability.extra.mult } }
    end,
    calculate = function(self, card, context)
        if context.joker_main then
            return { mult = card.ability.extra.mult }
        end
    end,
}
```

### Supported fields

| Field | Notes |
|---|---|
| `key` | Required. The Joker's id is `j_<prefix>_<key>`. |
| `loc_txt.name`, `loc_txt.text` | Name, and description lines. `#1#` is replaced from `loc_vars`. |
| `config` | Copied into `card.ability` for each copy of the Joker, so two copies scale separately. Saved with the run. |
| `rarity`, `cost` | Sell value is half the cost, minimum 1. |
| `sprite` | Required. The Joker's image in `assets/1x`. |
| `soul_sprite` | The floating layer Legendary Jokers have, drawn over the card. |
| `negative_sprite` | Art for a Negative copy (see [Negative art](#negative-art)). |
| `blueprint_compat` | Defaults to `false`, as in Steamodded. |
| `eternal_compat`, `perishable_compat` | Default `true`. |
| `unlocked`, `discovered` | Mod Jokers are unlocked by default. |
| `loc_vars(self, info_queue, card)` | Return `{ vars = { ... } }`. `info_queue` is accepted and ignored. |
| `calculate(self, card, context)` | See below. |
| `calc_dollar_bonus(self, card)` | Money paid at the end of the round, listed in the round's payout. |
| `in_pool(self, args)` | Return `false` to keep the Joker out of the shop and every random roll. `args` is an empty table. |
| `set_ability(self, card, initial)` | Called whenever a copy of the Joker is created (including shop cards), after `config` has been copied into `card.ability`. A loaded run then restores the saved `card.ability` over it. |
| `add_to_deck(self, card, from_debuff)`, `remove_from_deck(...)` | Called when the Joker is gained or lost. Not called when a saved run is loaded, because the save already includes their effects. |
| `suit_aliases = { Spades = "Halberds" }` | While this Joker is held and not debuffed, a card printed with a key suit also counts as the named suit at every `is_suit` check. See [Suit aliasing](#suit-aliasing). |
| `center_overrides = { { center = "m_glass", field = "Xmult", add = 1 } }` | Rewrites named numeric fields of a center's config while this Joker is held. See [Center-config overrides](#center-config-overrides). |

**Description markup:** `{C:mult}`, `{C:chips}`, `{C:money}`, `{C:attention}`, `{C:green}`, `{C:red}`, `{C:purple}` and `{C:inactive}` work, and `{}` resets the colour. `{X:...}` uses its colour for the text. `{s:...}` and `{V:n}` are ignored.

### `calculate` contexts

| Context | When |
|---|---|
| `context.before` | A hand is played, before anything scores. |
| `context.individual` + `context.cardarea == G.play` | Each scored card. `context.other_card` is the card. |
| `context.individual` + `context.cardarea == G.hand` | Each card held in hand. |
| `context.repetition` | Asked per scored card: return `{ repetitions = n }` to retrigger it. |
| `context.retrigger_joker_check` | Asked each time a Joker triggers. `context.other_card` is that Joker and `context.other_context` the context it triggered in. Return `{ repetitions = n }` to run its effect `n` more times; during those passes it sees `context.retrigger_joker`. A repeat is never repeated again. Check `context.other_card ~= card` unless the Joker should repeat itself. There is no `context.other_ret`. Unlike Steamodded, no `optional_features` opt-in is needed. |
| `context.post_trigger` | After each Joker triggers, with the same `other_card` and `other_context`. What you return scores as if this Joker had triggered on that event. |
| `context.probability_success` | Port only. A chance roll just succeeded: Lucky Card, Bloodstone, Business Card, Reserved Parking, Space Joker, 8 Ball, Hallucination, Wheel of Fortune, or a mod's `SMODS.pseudorandom_probability`. Return `{ repetitions = n }` to fire its effect `n` more times. `context.identifier` names the roll and `context.numerator` / `context.denominator` give its odds. Rolls that only go one way (Glass breaking, Gros Michel and Cavendish going extinct, The Wheel) are not asked. |
| `context.mod_probability`, `context.fix_probability` | Before any roll, the game's or a mod's. Return `{ numerator = x, denominator = y }` to change the odds. Every `mod_probability` answer is applied in Joker order, then every `fix_probability` answer. Oops! All 6s is already counted. `context.identifier` names the roll; `context.trigger_obj` is what the mod passed, or nil for the game's own rolls. |
| `context.pseudorandom_result` | After any roll, with `context.result` (true when it hit) and the same fields. A returned `message` is shown; other returns are ignored. |
| `context.joker_main` | The Joker's main scoring step. |
| `context.final_scoring_step` | After every Joker has scored, before the total lands and before Plasma Deck balances it. Returns score as usual. |
| `context.after` | After the hand has scored. |
| `context.end_of_round` | End of the round. |
| `context.blind_defeated` | The Blind's score has been reached, before the end-of-round payouts. |
| `context.discard` | Each discarded card (`context.other_card`). Also `context.pre_discard`. |
| `context.setting_blind`, `context.first_hand_drawn` | Blind selected; first hand of the round. |
| `context.hand_drawn` | A deal to the hand has finished during a round. `context.hand_drawn` is the list of cards just drawn. |
| `context.skip_blind` | A Blind was skipped, after its Tag was given. |
| `context.ante_change` | The Ante changed. `context.ante_change` is the amount (`1`, or `-1` from Hieroglyph and Petroglyph) and `context.ante_end` is true when a Boss was beaten. |
| `context.selling_card`, `context.selling_self` | A Joker is sold; `selling_self` when it's this one. |
| `context.card_added` | A Joker was gained (bought, created or given). `context.card` is the new Joker. Not raised when a saved run is loaded. |
| `context.tag_added` | A Tag was gained. `context.tag_added` is the Tag. |
| `context.starting_shop`, `context.ending_shop` | The shop opens; the player leaves it. |
| `context.reroll_shop`, `context.buying_card`, `context.open_booster`, `context.skipping_booster`, `context.using_consumeable` | Shop and pack events. `buying_card`'s raw event (`context.port`) carries `offer`, `offer_kind`, `offer_id` and `offer_price`. `open_booster` carries the pack itself: see [Shop, voucher and booster APIs](#shop-voucher-and-booster-apis). |
| `context.create_shop_card`, `context.modify_shop_card` | A shop Joker offer is rolled (`create`, a draft: id / edition / stickers) and then priced and shelved (`modify`). `context.card` is a plain view of the offer (`{ id, kind, edition, rarity, price }`) and `context.offer` the live offer table. |
| `context.playing_card_added`, `context.remove_playing_cards` | Cards added to or destroyed from the deck. |
| `context.joker_type_destroyed` | A Joker was destroyed (an effect, self-destruction, Mr. Bones spending itself -- never a sale, and never run teardown or a save restore). `context.card` is the destroyed Joker; it hears about its own destruction too, so compare `context.card == card` to exclude it, as the PC mods do. |
| `context.money_altered` | Money changed. `context.amount` is the signed change and `context.from_shop` is true when a shop purchase, reroll or voucher caused it. Fires for Joker and consumable dollars, shop spends, selling, round-end payout rows and interest, Tag payouts, rental charges, Hermit/Temperance/Immolate/Wraith, and the boss money effects (The Tooth, The Ox). Run setup, save restores and challenge seeding set money directly and do not fire it. A Joker that gains money because money changed nests at most 8 deep; past that the money still lands but raises no further context. |
| `context.debuff_card` | A debuff was applied to a playing card through the canonical setter (`card:set_debuff(true)` or `SMODS.set_debuff(card, true)`). `context.card` is the card and `context.permanent` is true: the debuff is the persistent kind the boss predicate reads under any Blind. Boss-Blind debuffs themselves are predicates over the active Blind, not applications, so they do not fire this -- a card under The Goad is debuffed, but nothing ever "applies" it. Clearing a debuff fires nothing. |
| `context.press_play` | The Play button committed a hand, before the `before` context. `context.full_hand` is the played cards. |
| `context.blind_disabled` | A Boss Blind was disabled (Chicot, Luchador, an effect). `context.blind.id` is the Blind's id. |
| `context.setting_ability` | A card's enhancement or seal changed through its canonical setters (`Card:set_enhancement` / `Card:set_seal` -- every Tarot, effect and `mod_conv` conversion walks through them). `context.other_card` is the card, `context.old` the previous enhancement or seal (nil when there was none), and `context.unchanged` is true when the new value equals the old. Editions on playing cards have no node setter in this engine and do not fire it. |
| `context.destroying_card` | Asked before a playing card is destroyed: `context.destroying_card` is the card, and returning `{ remove = false }` keeps it alive. Any other answer lets the destruction proceed. Cards destroyed from the discard pile or deck (no node) are asked about too, with a view over their data. |
| `context.level_up_hand` | A hand's level rose, from any source (a Planet, a `level_up` return, an effect). `context.level_up_hand` is the hand's NAME (a string, Steamodded's shape), `context.level` the new level and `context.amount` the rise (1 per funnel call). A Joker that levels a hand in answer is heard, but chains cap at 4 deep. |
| `context.game_over` | A lost Blind is about to end the run. Also carries `context.end_of_round = true`; `context.port.round_score` and `context.port.blind_target` hold the final numbers. Return `{ saved = true }` to rescue the run: the first saver in slot order wins (a Blueprint/Brainstorm copying a saver counts at the copy's slot, and Mr. Bones competes by the same order). The engine does not spend the saver -- its consequences are its own. |
| `context.money_transform` | Asked of each held Joker, in slot order, before a money GAIN lands (never for spending). `context.amount` is the gain as the previous Joker left it; return `{ amount = n }` to replace it. Gains through `Game:ease_dollars`, Joker `dollars` returns, card-center dollars and `perma_p_dollars` all pass through here; a round-win payout row is transformed once, when the payout table flushes. Boss-debuffed Jokers are skipped, and a Blueprint copying a transformer does not transform (Bunco's PC wrapper keys off the held Joker itself). |
| `context.joker_debuffed` | A Joker's mod debuff changed (see [Joker debuff](#joker-debuff)). `context.card` is the Joker and `context.debuffed` is the state it changed to. Setting the state a Joker already has fires nothing, and clearing a boss or sticker debuff fires nothing either: this context is only the mod channel's. |

Also available on `context`:
- `blueprint` and `blueprint_card`: set when Blueprint or Brainstorm is copying this Joker.
- `poker_hands`: use `next(context.poker_hands["Flush"])` to check whether the played hand contains a Flush.
- `scoring_name`, `scoring_hand` and `full_hand`.
- `port`: the game's own event table, for anything not translated above.

Playing cards support `:get_id()` (2 to 14, where Jack is 11 and Ace is 14), `:is_face()`, `:is_suit("Hearts")`, `.base.suit` and `.debuff`.

### Return values

`chips`, `mult`, `xmult` (also `x_mult` and `Xmult`), `dollars` and `message`, plus `extra` to chain another table. They score exactly like a vanilla Joker's, with the same popups, sounds and timing. A return with only a `message` (such as `"Upgrade!"`) shows it and counts as the Joker triggering.

The extended total fields Steamodded added are here too, applied to the running totals in this order, after the fields above: `x_chips` (also `xchips`: Chips x n), `e_mult` (also `emult`: Mult = Mult ^ n) and `e_chips` (also `echips`: Chips = Chips ^ n) -- the exponent fields land between them, in Steamodded's order chips, mult, x_mult, e_mult, e_chips, x_chips. Then `xlog_chips = b` (Talisman's field, via MoreFluff) multiplies Chips by log base `b` of Chips, but only when that log is at least 1. Then `swap = true` exchanges Chips and Mult, `balance = true` sets both to the larger of the two (a numeric `balance = f`, 0 < f < 1, moves each total the fraction `f` of the way toward that same target -- the partial form Paperback's plasma-style Jokers use), and `level_up = n` (or `true` for 1) levels the hand being scored: the stored level rises as a Planet would raise it, and the running totals gain the level's Chips/Mult delta, so earlier contributions are kept. Outside a scoring context `level_up` still raises the level and moves no totals. Enhancement, seal and edition `calculate` returns accept the same fields. Past the double range the totals become [big numbers](#big-numbers), which these readers feed transparently.

A return may also ask for retriggers, as in Steamodded: `repetitions = n` runs this Joker's effect `n` more times, and `retrigger_joker = <a held Joker>` (or `true`, for this Joker) runs that Joker's effect again -- once, or `repetitions` times when both are given. The extra passes see `context.retrigger_joker`, are announced with "Again!", and run on the spot inside this Joker's own beat rather than being queued for a beat of their own. A pass that is itself a retrigger never retriggers, and one return buys at most 100 extra passes, so a Joker that always asks cannot loop forever.

A return may also debuff: `debuff_joker = <a held Joker>` (or `true`, for this Joker) debuffs it and `undebuff_joker` clears a mod debuff, applied after the score fields land. See [Joker debuff](#joker-debuff).

### Live readouts (`display`)

With **Settings → Joker Info** on, every Joker shows its current value under the row. Vanilla Jokers have hand-written readouts; a mod Joker gets one declaratively — the readout never calls your `calculate` (it runs while the player is still deciding, and must not be able to change anything). Declare where the number lives:

```lua
SMODS.Joker {
    key = "charged",
    config = { extra = { mult = 0 } },
    display = { field = "my_counter", kind = "mult", note = "Charged" },
    -- ...
}
```

- `field = "name"` reads that field off the live Joker instance — the stored-counter shape, for Jokers whose value accumulates on the card itself.
- `config = "key"` reads a config key instead (the config table first, then its `extra` table).
- `value = n` shows a constant, when neither applies.
- `kind` is how the number is written: `mult` and `chips` as `+N`, `xmult` as `XN`, `money` as `$N`, `count` as a bare number, `plain` as-is. It defaults to `mult`.
- `note = "text"` adds a short reminder line under the value.

With no `display` at all, a Joker whose config carries a standard key still gets a readout: `x_mult`/`Xmult`, `mult`, `chips` or `dollars`, in that order, from the config or its `extra`. A Joker with neither shows nothing — the panel stays blank rather than guessing at what your `calculate` would do.

### Big numbers

Scores are plain Lua numbers until an effect would push one past the double range (about 1.8e308) -- the point where the PC game needs Talisman. At that moment the total *promotes* to a big number: a value that keeps an exact exponent of any size, so `e_mult` chains, `x_mult = 1e100` configs and Cryptid-scale Jokers score finite values instead of overflowing to infinity. Below that range nothing changes: every total is the plain double it always was.

What a mod sees:

- `context.port.chips` and `context.port.mult` may be big numbers once a total has promoted. Adding, subtracting or multiplying them with plain numbers (or each other) works and stays big. **Never `tonumber()` a total**: `tonumber()` of a big number is `nil`, and a total read that way silently becomes whatever fallback follows it. Compare with `SMODS.big_cmp(a, b)` (-1, 0 or 1) -- Lua will not compare a big number against a plain one for you.
- The score fields of a `calculate` return (`chips`, `mult`, `x_mult`, `e_mult`, `e_chips`, `x_chips`) accept big values and pass them through. The exponents themselves (`e_mult = 5.2`) stay plain numbers, as in Steamodded.
- `SMODS.big(mantissa, exponent)` builds one (5, 350 is 5e350); `SMODS.big_pow(base, exponent)` raises a number or big to a plain power, promoting on overflow; `SMODS.is_big(v)` tests; `SMODS.big_to_number(v)` demotes to a double, which past the range is `+/-inf` -- that loss is the point of the call, so it is never done for you silently; `SMODS.big_format(v)` renders one the way the game does.
- Display: a big score prints as a mantissa and a raw exponent (`1.234e456`), the same shape the game already used past 1e11.
- Big totals save and load with the run; a plain run's save is untouched. Money and hand levels stay plain numbers. Blind targets are plain until the endless formula itself passes the double range (around Ante 39), where the target becomes a big number too, capped to two significant figures as always.

### Helpers

All of these use the run's seed:
- `SMODS.pseudorandom_probability(card, seed, numerator, denominator, identifier, no_mod)` returns whether the roll hit. As a port extension, it also returns how many times the effect should run: 1, plus any `probability_success` repetitions. Use `local hit, times = ...` to support Jokers like Natural 20!.
- `SMODS.get_probability_vars(card, numerator, denominator, identifier)` returns the odds a roll would use, for tooltips.
- `pseudorandom(seed)`
- `pseudorandom_element(list, seed)`

Oops! All 6s and every `mod_probability` / `fix_probability` Joker are counted, unless `no_mod` is true. `localize("k_upgrade_ex")` and a few other common message keys work, and so does `ease_dollars(n)`.

### Polls: random enhancements and seals

`SMODS.poll_enhancement(options)` and `SMODS.poll_seal(options)` deal one center from the pool a card could gain and return its port VALUE (a string like `"lucky"` or `"red"` -- feed it to `SMODS.add_card`'s `enhancement` / `seal` or a node's setters):

```lua
local enh = SMODS.poll_enhancement({ guaranteed = true, no_replace = true })
local seal = SMODS.poll_seal({ guaranteed = true, type_key = "my_styled_roll" })
```

The pool is the eight vanilla enhancements (four seals) plus every center mods registered with `SMODS.Enhancement` / `SMODS.Seal`, each weighted by its `config.weight` (default 1); centers with `no_poll` or weight 0 are excluded. The draw is seeded per run, so a given seed polls the same sequence. `guaranteed` and `no_replace` are accepted for Steamodded compatibility (the poll always deals a real center -- nothing on PC overrides it here); `options.key` names one center (by port value, vanilla name or full key) and polls it directly, for the `mf_seaweed`-style effects that deal a fixed enhancement.

### Permanent card effects (`perma_*`)

Steamodded's card-persistent scoring fields work here, stored on the card itself so they save with the run. Write them from a `calculate` with `SMODS.set_perma(card, field, value)` and read with `SMODS.get_perma(card, field)` (a bare `card` node or its `card_data` both work; passing `nil` clears):

- `perma_bonus` / `perma_mult`: flat Chips / Mult added at the card's own scoring step, and
- `perma_x_chips` / `perma_x_mult`: multipliers on the running totals at that same step, after the card's edition.
- `perma_repetitions`: extra passes the card itself grants when it scores (played or held) -- it stacks with Red Seal and retrigger Jokers in the same source list.
- `perma_p_dollars`: dollars paid at round end while the card is held in hand, like a Gold card's pay (a positive pay passes the `money_transform` seat).

Unknown field names are refused. A mod may also write `card.ability.perma_x_mult = 2` directly in a `calculate`, PC style: the value lands on the card's data the same way.

### Sold-Joker history

`G.jokers_sold` is the list of Joker def ids sold this run, in sale order (`"j_cry_cat"`, ...). It saves with the run and resets on a new one. Cryptid's Kidnapping reads it to count sold "Type" Jokers; Necromancer picks a random entry and recreates it.

### Per-mod run state

`SMODS.mod_state(id)` — with your mod's manifest id — returns a table that is yours alone for this run: counters, flags, per-round tallies, whatever a system like Paperback's `G.GAME.paperback` would hold. It is created empty at run start, it is **saved with the run** (it rides the run snapshots beside `jokers_sold`, so save slots and score-preview dry runs restore it too), and another mod's table is never handed to you. Keep it **plain data only** — numbers, strings, booleans and nested tables of those; a function or userdata in it will not survive a save. The same tables are readable as `G.mod_run_state[id]`, but write through `SMODS.mod_state` so the table exists.

### Creating and destroying cards

```lua
local j = SMODS.add_card { set = "Joker", key = "j_joker" }              -- the new Joker, or nil
local c = SMODS.add_card { set = "Tarot", key = "tarot_fool" }           -- the new consumable, or nil
local n = SMODS.add_card { set = "Playing", rank = "Ace", suit = "Spades" }  -- a node in the hand
SMODS.destroy_joker(j)   -- true when it was held and is gone
SMODS.destroy_card(n)    -- true when the card is gone
```

`SMODS.create_card` is the same call as `SMODS.add_card`. Created cards go through the game's own creation paths -- the same ones shop purchases and Spectral cards use -- so they are discovered, saved, scored and have their art freed like any other card. Capacity is the game's: when there is no room the call returns `nil` and creates nothing.

- **`set = "Joker"`:** `key` is a full Joker def id, vanilla (`"j_joker"`) or a mod's (`"j_<prefix>_<key>"`). `edition = "foil"` (or `"holo"`, `"polychrome"`, `"negative"`) makes that edition. A created mod Joker hears its `add_to_deck`, and every Joker hears `context.card_added`. Returns the Joker.
- **`set = "Tarot"`, `"Planet"`, `"Spectral"`, `"Consumable"` or a registered consumable type's name:** `key` is a full consumable def id; the set only has to name the consumable family, the def decides. Returns the consumable.
- **`set = "Playing"`:** `rank` is a number (2-14, Ace is 14), a numeric string, or `"Ace"`, `"King"`, `"Queen"`, `"Jack"`; `suit` is `"Hearts"`, `"Clubs"`, `"Diamonds"` or `"Spades"`, or a suit registered with `SMODS.Suit`. `enhancement` takes a port name (`"gold"`) or a Steamodded key (`"m_gold"`); `seal` is `"gold"`, `"red"`, `"blue"` or `"purple"`; `edition` sets the card's edition. The card joins the hand -- `nil` when the hand is full, unless `bypass_limit = true` -- and the return is its node, the same object contexts hand over. With `area = "deck"` it joins the deck instead and the return is the `card_data` now in the deck.

`SMODS.destroy_joker(joker)` removes a held Joker for good: a mod Joker's `remove_from_deck` runs and its art frees, exactly as when the game itself removes one. It forces past the eternal sticker -- destroying means it, where selling an eternal Joker is refused. `SMODS.destroy_card(card)` destroys a playing card: it leaves the game entirely and never reaches the discard pile. `card` may be a hand card's node, its `card_data`, or a `card_data` in the deck or discard pile. Both return whether anything was actually removed. Steamodded's batch `SMODS.destroy_cards` is not here; destroy one card at a time.

`SMODS.set_debuff(card, true)` debuffs a playing card through the same canonical setter the game's effects use (see `context.debuff_card` above); pass `false` to clear it. On a bare `card_data` the flag is set with no context, since there is no card to show the other Jokers.

## Copying Jokers

```lua
local ret = SMODS.blueprint_effect(card, other_joker, context)  -- other_joker's return, or nil
local clone = SMODS.copy_joker(joker)                          -- a new held Joker, or nil
```

**`SMODS.blueprint_effect(caller, other, context)`** is Steamodded's copy dispatch, callable from a mod Joker's `calculate` (Paperback's Forgery / Master Plan / Photocopy and Cryptid's Old Blueprint are all this one call with a different neighbour). It runs `other`'s calculate with the caller as the acting Joker:

- `other` must be held, must not be the caller, and its def must be `blueprint_compat` -- the same gate the vanilla Blueprint applies. Anything else returns `nil` and nothing fires.
- A debuffed target (boss, Perishable sticker, or a mod debuff) does not fire; the call returns `nil`.
- The copied calculate sees a copy of `context` with `blueprint = true`, `blueprint_card = caller` and `no_blueprint = true`. That last flag is the one-level rule, as on PC: a copier copied by a copier still runs its own logic, but its own `blueprint_effect` calls return `nil`, so copy chains never recurse. Calling `blueprint_effect` with a context that already has `no_blueprint` set returns `nil` at once (Forgery's own guard on PC).
- A **mod** target's calculate return is returned untouched. Return it (or a rewrite of it) from your own `calculate` and the dispatch applies it once, at your slot.
- A **vanilla** target has no calculate table in this engine, so its effect fires in place, through the same delegate path the vanilla Blueprint uses, and the call returns `nil`. Return-rewriting copiers therefore only rewrite mod targets' returns.

**`SMODS.copy_joker(view)`** is an exact clone of a held Joker, PC's `copy_card` (Cryptid's ERROR sells into a row of duplicates; Nostalgic Googol Play Card sells into two copies of the leftmost Joker). The copy has the same def, edition and stickers, and a deep copy of the source's live state -- a mod Joker's `ability`, a vanilla Joker's runtime counters -- and joins the end of the row. Its `add_to_deck` and the other Jokers' `card_added` fire after the state is in place, as PC's explicit `card:add_to_deck()` does. Slot rules, as PC: `copy_card` + `emplace` never check the Joker limit (the limit gates purchases and `SMODS.add_card`, not clones), so a copy is created even when the row is full. Two limits: the copy does not inherit a mod debuff (its debuff state is re-derived from the boss and sticker channels, as PC re-derives `card.debuff`), and a copy of a Negative Joker keeps the edition, and so grants its slot, exactly as the source does. Returns the new Joker, or `nil` when `view` is not a held Joker.

The vanilla Blueprint and Brainstorm are untouched by all of this: they keep copying through the engine's own delegate, chains and all, whether or not any mod registers a `blueprint_compat` Joker.

## Joker debuff

```lua
SMODS.set_joker_debuff(joker, true)    -- debuff; false clears. Returns whether the state now holds.
SMODS.joker_debuffed(joker)            -- true when debuffed through ANY channel
```

A mod can debuff a Joker (Bunco's Gameplan debuffs its neighbours; Conquest debuffs a random other Joker). The state lives on the Joker itself, so it saves with the run and ends when the Joker leaves play -- there is no global patch to leak. A debuffed Joker:

- **does not calculate**, through any seat: the event dispatch, its retrigger and probability-retrigger queries, the `post_trigger` / `retrigger_joker_check` / probability passes, the money-transform and game-over questions, and as a `blueprint_effect` target. A vanilla Blueprint copying a debuffed Joker copies nothing. This applies to vanilla Jokers debuffed by a mod exactly as to mod Jokers.
- **renders debuffed** through the existing display path, the same wash and red X the boss and sticker channels draw.
- **keeps its editions and its passive `config` modifiers** (slots, hand size, `debt_limit`): as on PC, debuff gates `calculate` only.

`SMODS.joker_debuffed(joker)` reads every channel at once: the boss predicate (Crimson Heart), the Perishable sticker, and the mod channel. Boss-blind Joker debuffs are unchanged -- they were always predicates over the active Blind, and they neither set nor clear the mod flag.

Two ways to set it:

- **`SMODS.set_joker_debuff(joker, debuffed)`** from anywhere (an `add_to_deck`, a consumable's `use`, another Joker's `calculate`). Setting the state the Joker already has does nothing.
- **A `calculate` return**: `debuff_joker = <a held Joker>` (or `true` for the Joker itself) debuffs it, `undebuff_joker` clears it, applied after the return's score fields land. This is the seat for debuffing in reaction to the event being answered (Conquest picks its victim at `setting_blind`).

Either way, a change fires `context.joker_debuffed` to every held Joker, with `context.card` the Joker and `context.debuffed` the state it changed to. Notifications nest at most 8 deep, like `money_altered`, so a Joker that debuffs in answer to a debuff cannot loop the row forever.

## Suit aliasing

```lua
SMODS.Joker {
    key = "myopia",
    suit_aliases = { Spades = "Halberds", Clubs = "Halberds" },
    -- ...
}
```

While a Joker declaring `suit_aliases` is held and not debuffed, a card whose printed suit is a key also counts as the named suit at the game's single `is_suit` choke -- every Joker effect, every `card:is_suit(...)` a mod makes, and the Joker Info readouts (which mirror the same helper) agree. This is Bunco's Myopia / Astigmatism: on PC they patch `Card:is_suit` with a per-held-Joker scan, and the scan here is the same shape, so the alias set is derived from the held row on every check: a Joker leaving play, or being debuffed, ends its alias with no cleanup and no leak. The alias only ever adds a match, never removes one, and sits ahead of Smeared Joker's collapsing, as Bunco's patch sits ahead of it on PC. One honest limit: hand-type grouping (which cards a Flush claims) reads suits directly, not through `is_suit`, so an alias does not make a Flush out of mixed printed suits; it speaks to suit checks, which is what the PC Jokers' scoring effects use it for.

## Center-config overrides

```lua
SMODS.Joker {
    key = "sledgehammer",
    center_overrides = {
        { center = "m_glass", field = "Xmult", add = 1 },
        { center = "m_glass", field = "extra", divide = 4, once = true },
    },
    -- ...
}
local cfg = SMODS.center_config("m_glass")   -- the config to read right now, or nil
```

On PC, Bunco's Sledgehammer, Dwarven and Metallurgist rewrite a vanilla center's `config` in `add_to_deck` / `remove_from_deck` and patch every live card's ability to match. This engine never materialised a per-card copy of an enhancement's config -- the numbers are read at the card's scoring step -- so the override lives at the read instead: a Joker declares `center_overrides` and `SMODS.center_config(center)` folds every held Joker's matching entries over the center's base config, in slot order, at every read. Nothing is written anywhere, so an override is per-run and reversible by construction: sell the Joker and the next read is vanilla again, and with no matching Joker held the base config itself is returned.

- **`center`** names the center by its PC key (`"m_glass"`, `"m_stone"`, `"m_steel"`, `"m_gold"`, `"m_bonus"`, `"m_mult"`, or a registered enhancement's `"m_<prefix>_<key>"`) or a registered enhancement's bare value (`"copper"`).
- **`field`** is a config field in PC's names. The vanilla bases are `m_glass = { Xmult = 2, extra = 4 }` (the `extra` is the break odds: 1 in 4), `m_steel = { h_x_mult = 1.5 }`, `m_stone = { chips = 50 }`, `m_gold = { h_dollars = 3 }`, `m_bonus = { bonus = 30 }`, `m_mult = { mult = 4 }`; a registered enhancement's base is its own `config`.
- **Exactly one operation** per entry: `add = n`, `set = n`, `multiply = n`, `divide = n`, or `add_from = { center = ..., field = ... }`, which adds the BASE value of another center's field (Dwarven lends Stone Steel's `h_x_mult` and Gold's `h_dollars` this way). A field the config does not carry counts as 0 for `add` / `add_from`.
- Entries apply **once per held copy** of their Joker, unless `once = true`, when only the first held copy applies them (Sledgehammer's odds divide once no matter how many are held; each copy still adds its own XMult).
- The readers are the scoring steps themselves: Glass reads `Xmult` when it scores and `extra` at the break roll; Bonus / Mult read their flats; Steel reads `h_x_mult` while held; Stone reads `chips` when played and -- only while an override lends them -- `h_chips` / `h_mult` / `h_x_mult` while held and `h_dollars` at round end; Gold reads `h_dollars` at round end and any lent `h_*` while held. A registered enhancement's `config` readers go through the same fold. Card tooltips keep the vanilla text; the numbers on the table are the overridden ones.

## Negative art

The PC game recolours a Negative card with a shader. The 3DS can't, so vanilla ships a separate negative image for every Joker, and a mod can do the same. Jokers and consumables accept `negative_sprite = "plus_four_negative.png"`, an image the same size as the normal one.

Without it, a Negative copy keeps its normal art. The example mod has negative art for all its Jokers and its Tarot.

### Making negative art

Don't recolour it by hand: run the shader's own transform over the normal image. It reproduces the game's own `Jokers1_negative_*.png` files pixel for pixel.

```sh
python3 dev/make_negative.py plus_four.png                 # writes plus_four_negative.png
python3 dev/make_negative.py *.png --t3x                   # every image, plus each .t3x (needs tex3ds)
python3 dev/make_negative.py plus_four.png -o neg.png      # choose the output name
```

It needs only Python 3, nothing to install. With Aseprite, `dev/aseprite/hsl_invert_transform.lua` does the same thing, either from **File → Scripts**, or from the command line:

```sh
aseprite -b plus_four.png --script dev/aseprite/hsl_invert_transform.lua --save-as plus_four_negative.png
```

Run it on the finished normal image; don't edit the negative afterwards.

## Translations

`loc_txt` can hold one table per language, as in Steamodded. Use `en-us` for English, and the game's own codes (as in `locales/`, e.g. `zh_CN`) for the others:

```lua
loc_txt = {
    ["en-us"] = { name = "Plus Four", text = { "{C:mult}+#1#{} Mult" } },
    zh_CN     = { name = "加四", text = { "{C:mult}+#1#{}倍率" } },
},
```

The card shows the player's chosen language when it has one, and English when it doesn't. A single `{ name, text }` table works too; it is used for every language.

## Modifiers

A Joker or Voucher changes these numbers just by declaring them in `config`. The effect lasts while the Joker is held or the Voucher is owned, and needs no code:

| Key | Changes |
|---|---|
| `h_size` | Hand size |
| `d_size` | Discards per round |
| `hands` | Hands per round |
| `joker_slots` | Joker slots |
| `consumable_slots` | Consumable slots |

```lua
config = { h_size = 1 }   -- like Juggler
```

## Consumables

```lua
SMODS.Consumable {
    set = "Tarot",           -- "Tarot", "Planet", "Spectral", or a type registered with SMODS.ConsumableType
    key = "gild",            -- id is c_<prefix>_<key>
    loc_txt = { name = "Gild", text = { "Enhances up to {C:attention}#1#{}", "cards into {C:money}Gold Cards{}" } },
    config = { max_highlighted = 2, mod_conv = "m_gold" },
    sprite = "gild.png",     -- 64x128, card in the top 64x96
    loc_vars = function(self, info_queue, card)
        return { vars = { card.ability.max_highlighted } }
    end,
}
```

They appear in packs and the shop alongside the vanilla cards of their set, and in the collection. A consumable in a set of the mod's own appears in the shop at its type's rate; custom sets have no packs or collection tab (see [Custom rarities, suits, poker hands and consumable types](#custom-rarities-suits-poker-hands-and-consumable-types)).

**Built in.** As in Steamodded, a consumable that only declares data needs no code:

| `config` | Does |
|---|---|
| `max_highlighted`, `min_highlighted` | How many selected cards it needs (`min` defaults to 1). It can't be used until that many are selected. |
| `mod_conv = "m_gold"` | Enhances the selected cards: `m_bonus`, `m_mult`, `m_wild`, `m_glass`, `m_steel`, `m_stone`, `m_gold`, `m_lucky`. |
| `suit_conv = "Hearts"` | Changes the selected cards to that suit. |
| `hand_type = "Flush"` | Planet only: levels up that hand, with the vanilla level-up animation. |

**Code:**
- **`can_use(self, card)`:** return `true` when the card can be used right now. The game has already checked that consumables can be used at all, and that the right number of cards is selected.
- **`use(self, card, area, copier)`:** does the effect. It runs after any built-in conversion. For a Planet with a `hand_type`, it runs after the level-up.
- **Selection:** `G.hand.highlighted` is the list of selected cards, in order, while either function runs.
- **State:** `card.ability` is this copy's own copy of `config` and is saved with the run.
- **Other fields:** `cost` (defaults to the set's price) and `negative_sprite`.

**Targeting a Joker.** Declare `target_joker = true` on the consumable (or in its `config`) and it acts on one chosen Joker instead of selected cards:

- **`can_use(self, card, target)`** receives the chosen Joker (or nil) as its last argument; with no `can_use` of your own, the consumable can only be used when a target resolves.
- **`use(self, card, area, copier, target)`** receives it as its last argument, and `G.jokers.highlighted` holds `{ target }` while `can_use` and `use` run, as Steamodded mods expect.
- The choice resolves in this order: a target handed to the use directly (`Game:use_consumable(index, joker)`), the Joker under the gamepad focus while the focus layer is the Joker row, then the Joker whose tooltip is open. A target that is not currently held never counts. There is no separate pick-a-Joker screen: on touch, the player opens the Joker's tooltip first, then uses the consumable.

Using a mod consumable counts toward The Fool, consumable stats, and Jokers that react to consumables being used.

## Vouchers

```lua
SMODS.Voucher {
    key = "bigger_hand",     -- id is v_<prefix>_<key>
    loc_txt = { name = "Bigger Hand", text = { "{C:attention}+#1#{} hand size" } },
    config = { h_size = 1 },
    sprite = "bigger_hand.png",   -- 72x95
    loc_vars = function(self, info_queue, card)
        return { vars = { card.ability.h_size } }
    end,
}

SMODS.Voucher {
    key = "biggest_hand",
    loc_txt = { name = "Biggest Hand", text = { "{C:attention}+1{} hand size again" } },
    config = { h_size = 1 },
    requires = { "bigger_hand" },
    cost = 12,
    sprite = "biggest_hand.png",
    redeem = function(self, card) ease_dollars(5) end,
}
```

- **`requires`:** the voucher only appears in the shop once all of these are owned. Each entry can be a vanilla voucher's id (Steamodded's `v_overstock_norm` and `v_reroll_surplus` work too), a full mod id, or one of your own keys. Define a required voucher before the one that requires it.
- **`config`:** its [modifiers](#modifiers) apply for as long as the voucher is owned.
- **`redeem(self, card)`:** runs once, when the voucher is bought.
- **`cost`:** defaults to 10.
- **`loc_vars`:** fills the description shown in the shop and the collection.

Mod vouchers join the shop's voucher pool after the vanilla ones. With no mods installed the pool, and so every seed, is exactly vanilla's.

## Custom rarities, suits, poker hands and consumable types

Four registries for the things a mod used to only be able to borrow from vanilla.
All four register at load, before any game exists, and land in each game as it is
built; a game built with nothing registered is the vanilla game, untouched.

**`SMODS.Rarity { key, loc_txt, badge_colour, weight }`** is a rarity of the mod's
own. It takes the next free rarity number after Legendary (5, 6, ... in registration
order), and a Joker declares it by name:

```lua
SMODS.Rarity {
    key = "mythic",
    loc_txt = { name = "Mythic" },
    badge_colour = "#B26CBB",          -- or { r, g, b } in 0..1
    weight = 3,
}
SMODS.Joker { key = "big_one", rarity = "mythic", ... }        -- this mod's key
SMODS.Joker { key = "guest", rarity = "otherprefix_mythic", ... } -- or the full id
```

`rarity = 9` and unknown names are load errors, as before. The badge on the Joker's
tooltip wears the rarity's name and `badge_colour`. `weight` is the rarity's share
of the shop roll, in the units of the vanilla roll (Common 70, Uncommon 25, Rare 5
out of 100): the default 3 makes it about as present as a second Rare, and the
vanilla three keep their proportions between themselves. Weight 0 keeps the rarity
out of the shop entirely (its Jokers can still be created directly, and rolls by
rarity still find them). Legendary stays out of the shop, as vanilla has it.

**`SMODS.Suit { key, loc_txt, ui_colour, card_key }`** is a suit of the mod's own.
The key *is* the suit: the string a card carries, one capitalised word.

```lua
SMODS.Suit { key = "Stars", loc_txt = { name = "Stars" }, ui_colour = "#FFAA00" }
local card = SMODS.add_card { set = "Playing", rank = 7, suit = "Stars" }
```

Suit checks in this port compare names, and flush detection counts cards per suit
name, so a custom suit needs no further wiring: `card:is_suit("Stars")` works, five
Stars flush, and a consumable's `suit_conv` can convert cards into it. Cards enter
play through creation and conversion; the standard deck stays the four vanilla
suits. Random creation (Standard packs, shop playing cards) is the one gated
route: while a suit's optional `in_pool(self, game)` passes, one front per rank
in that suit joins the random-front pool, and a suit with no `in_pool` is always
in. That is how Bunco's exotic suits stay out of packs and the shop until the
first Spectrum-family hand is scored, then start turning up. Two honest limits: there is no art sheet for a mod suit, so its cards draw on
the Hearts row of the deck sheets (the game's own fallback for a suit it has no row
for), and `SMODS.DeckSkin` covers the vanilla suits only. `ui_colour` is worn
wherever a suit is named in colour in the UI. `card_key` is accepted for
Steamodded compatibility and stored; nothing here keys cards by it.

**`SMODS.PokerHand { key, loc_txt, chips, mult, l_chips, l_mult, evaluate, order }`**
is a poker hand of the mod's own. The key is the hand's name: its `handlist` entry,
what `context.scoring_name` reads, and what a Planet levels by
(`config = { hand_type = "Spectrum" }`).

```lua
SMODS.PokerHand {
    key = "Spectrum",
    loc_txt = { name = "Spectrum", text = { "Five cards, all different suits" } },
    chips = 30, mult = 4, l_chips = 30, l_mult = 3,
    order = 55,
    evaluate = function(self, hand)
        -- return the scoring cards, true for all of them, or nil for no match
    end,
}
```

`order` is the hand's strength on the vanilla scale (Flush Five 120 down to High
Card 10; Flush 60, Straight 50). A play is offered to registered hands strongest
first, and only to hands that outrank the vanilla hand the cards made: the first
whose `evaluate` matches takes the play, with its own Chips/Mult and the cards
`evaluate` named as the scoring cards. The same `evaluate` answers feed
`context.poker_hands`, so a Joker keyed on
`next(context.poker_hands["Spectrum"])` fires whenever the played cards satisfy it,
whatever the play finally scores as. `evaluate` gets the played cards as card views
(the same objects `calculate` sees) and runs error-contained like a `calculate`: a
hand that throws simply does not match.

One structural note: custom hands are *appended* to the hand list, after High Card,
not placed at their `order`. The engine names a play by its hand's position in that
list (the evaluation chain's positions are the vanilla twelve), so inserting a hand
in the middle would rename every vanilla hand below it. `order` decides every
contest; it just does not order the list. And if a poker-hand mod is switched off
mid-run, a game already built keeps the hand listed (positions must not move under
a save) but can no longer evaluate it; the run's own mod check refuses to continue
on a changed mod set anyway.

**`SMODS.ConsumableType { key, loc_txt, shop_rate, packs }`** is a consumable set
of the mod's own. Register it before the consumables that use it:

```lua
SMODS.ConsumableType {
    key = "Minor",
    loc_txt = { name = "Minor Arcana" },
    shop_rate = 6,
    packs = { arcana = 2 },   -- optional
}
SMODS.Consumable { set = "Minor", key = "coin", ... }   -- the type's key,
SMODS.Consumable { set = "ct_Minor", key = "sigil", ... } -- or its full id
```

The type's key *is* the kind its cards carry (their `kind`), the way a Tarot's kind
is `"tarot"`. Kinds are global: no two mods can register the same kind, and a kind
may not reuse a vanilla set's name. A consumable that names an unregistered set is
a load error that says which set. Everything that treats the three vanilla sets as
"a consumable" treats a registered kind the same way: the consumable area, the
shop (buying, and buy-and-use), selling, `SMODS.add_card { set = "Minor", ... }`,
effects that create a random consumable of a kind (they roll the kind's own pool),
discovery, and saving and loading. The cards themselves work like any other mod
consumable: `can_use` / `use`, `mod_conv` / `suit_conv` targeting, their own
`cost` (until a card declares one, the generic default price applies; the vanilla
sets' prices are theirs alone).

`shop_rate` is the kind's weight in the shop roll, in the units of the vanilla
weights (Jokers 20, Tarot 4, Planet 4; Spectrals only on decks that rate them).
The default 4 makes the kind as present as a vanilla one. The Tarot and Planet
merchant vouchers raise only their own kinds. A kind joins the roll only while it
has cards and a positive rate; rate 0 keeps it out of the shop, and its cards can
still be created directly.

`packs` opts the kind into the vanilla booster packs: keys are `arcana`,
`celestial` and `spectral` (any other key is a load error naming it), values are
weights in the same units as `shop_rate` -- the pack's own kind weighs 4, so
`packs = { arcana = 2 }` makes about a third of an Arcana pack's slots deal from
the kind's own pool instead. A substituted slot deals by the pack's own rules:
cards already in play, duplicates within the pack and challenge bans are culled,
exactly as for the pack's own kind. Rates of 0, or omitting `packs`, keep the kind
out of packs entirely; the shop behaviour above is unaffected either way. Choose
the packs a kind joins with its cards' `use` in mind: a card that targets hand
cards can only be played in a pack that shows the hand (Arcana and Spectral do;
Celestial does not, so a targeting card dealt there cannot be used from it).

The kind also gets a **collection category of its own**, named by its `loc_txt`
name and listed with the Tarots, Planets and Spectrals: its cards appear there
with their discovery states, and they count toward the collection's totals.

One honest limit remains: **hand-levelling stays Planet-only**:
`config.hand_type` on a custom kind does nothing, because levelling is the Planet
branch of the use flow, not a property of the set. Level from `use` if a card
must. And booster packs *of* a custom kind cannot be registered: packs themselves
(their sizes, prices and art) belong to the five vanilla pack kinds; `packs` only
lets a kind's cards be dealt by the packs that exist.

## Custom enhancements, seals and editions

The centers a playing card itself carries can be registered too. A center's
**value** -- the registration key, lowercased (`"copper"` for key `"Copper"`) -- is
the string cards carry, the way a card carries `"steel"` or `"gold"`. Values are
global: no two mods may register the same one, and none may reuse a vanilla name
(`bonus`, `mult`, `wild`, `glass`, `steel`, `stone`, `gold`, `lucky` for
enhancements; `gold`, `red`, `blue`, `purple` for seals; `foil`, `holo`,
`polychrome`, `negative`, `base` for editions). Registering one that clashes is a
load error naming it.

**`SMODS.Enhancement { key, loc_txt, config, calculate, weight, sprite }`**

```lua
SMODS.Enhancement {
    key = "copper",
    loc_txt = { name = "Copper", text = { "{C:chips}+#1#{} Chips" } },
    config = { chips = 25, h_chips = 10, h_dollars = 2 },
    sprite = "copper.png",
    loc_vars = function(self, info_queue, card) return { vars = { self.config.chips } } end,
    calculate = function(self, card, context)
        if context.card_played then return { mult = 3 } end
    end,
}
```

`config` is applied by the engine itself, mirroring the vanilla centers:
`chips` / `mult` / `x_mult` when the card scores (Bonus / Mult / Glass),
`h_chips` / `h_mult` / `h_x_mult` while it is held in hand (Steel), and
`h_dollars` at round end while held (Gold). `calculate(self, card, context)`
fires at the same three moments -- `context.card_played`, `context.held_in_hand`,
`context.on_round_end`, with `context.other_card` the card -- and its return's
`chips` / `mult` / `x_mult` land on the running totals and `dollars` in the
player's money. Its returns accept the extended total fields too (`x_chips`,
`e_mult`, `e_chips`, `swap`, `balance`, `level_up`), in the order the
"Return values" section gives. A debuffed card's enhancement does nothing,
like a vanilla one.

An enhancement value is accepted everywhere a vanilla one is:
`SMODS.add_card { set = "Playing", enhancement = "copper" }` (or `"m_copper"`,
Steamodded-style, or `"m_<prefix>_copper"`), and a consumable's
`mod_conv = "m_copper"` converts selected cards to it. In the random-enhancement
polls -- Grim / Familiar / Incantation and enhanced Standard-pack or shop cards --
it takes `weight` slots among the vanilla names (default 1, the vanilla-like
share; 0 keeps it out of the polls).

**`SMODS.Seal { key, loc_txt, config, calculate, weight, sprite }`** -- a seal's behavior
is its `calculate`, fired at the moments the engine raises for cards:
`context.card_played` (the Gold Seal's moment), `context.held_in_hand`,
`context.on_round_end` (the Blue Seal's) and `context.on_discard` (the Purple
Seal's, with `context.discard_reason`). Returns work as for enhancements.
Retriggers -- the Red Seal's trick -- come from `config.retrigger` /
`config.retrigger_held` counts, or from `calculate` returning `repetitions` when
asked with `context.repetition`. In the Standard-pack seal poll a registered seal
takes `weight` slots among the four vanilla seals (default 1; 0 keeps it out).
`SMODS.add_card { set = "Playing", seal = "lime" }` applies one directly.

**`SMODS.Edition { key, loc_txt, config, weight, cost }`** -- `config` is what the
edition contributes: `chips` / `mult` / `x_mult`. On a playing card all three land
in its scoring step; on a Joker the flat `chips` / `mult` land before its effect
and `x_mult` after it, the slots Foil / Holo and Polychrome sit in.
`config.joker_slots` grants that many extra Joker slots while a Joker carrying
the edition is held -- Negative's trick, as data. `cost` is the extra dollars a
Joker carrying the edition costs -- the vanilla editions add $2 / $3 / $5 / $5
of their own -- applied where theirs are: the spawned Joker's price (and so its
sell value, half the price) and the shop's offer price. Default 0; it may be
negative for a discount edition. `weight` is in the shop
ladder's units, percent of the roll (vanilla: Foil 4, Holo 2, Polychrome 0.6;
default 2); Standard packs roll at double rates, and in guaranteed-edition rolls
(Aura, Wheel of Fortune, Illusion) a registered edition shares the Foil band by
weight, Foil itself counting 50. Weight 0 keeps an edition out of every poll
while leaving it creatable: `SMODS.add_card { set = "Joker", key = "...",
edition = "fluoro" }` or `edition = "e_fluoro"`.

An unregistered center name in `SMODS.add_card` or a consumable's `mod_conv` is an
error naming it -- unlike an unknown rank or suit, which only refuses the card.

**Art.** All three centers -- and tags -- take an optional
`sprite = "Name.png"`, a single image in `assets/1x` like every other mod
image here (Steamodded's `atlas` / `pos` are not how this port stores art).
What the image is drawn as follows the slot it fills:

- An **enhancement's** sprite is card-sized art drawn as the card's whole
  face, with rank and suit still overlaid. It replaces the face, so no
  edition shader pass runs over it (a registered edition's overlay still
  stacks on top).
- A **seal's** sprite is a full-card image, transparent but for the stamp,
  drawn where a vanilla seal's stamp goes.
- An **edition's** sprite is a full-card overlay drawn over the face -- a
  Joker's front or a playing card's face. There is no shader pass for a
  registered edition and no reveal sting; the overlay is its treatment.
- A **tag's** sprite is its icon, fitted to the tag box.

Without a `sprite`, the fallbacks are the old ones: an enhanced card draws
the plain card face, a sealed card draws without a stamp, an edition's
cards draw plain, and a tag draws as a plain outline. Naming a file that
isn't in `assets/1x` is a load error naming it. (The tooltip always shows
the center's name and its `loc_txt` lines.)

One more honest limit:

- **Saves degrade gracefully, not magically.** A card's center is saved as its
  value string, like a vanilla one. A run continued without the mod is refused by
  the run's mod check as usual; but a value that reaches the engine unregistered
  by any other path simply does nothing -- the card scores as a plain card --
  rather than crashing the load.

## Custom card attachments

An enhancement and a seal are one slot each. When an effect needs to live on a
card **beside** them — with its own persistent state and its own `calculate` —
register an attachment (Paperback's paperclips are the working example):

**`SMODS.Attachment { key, loc_txt, config, calculate, loc_vars, sprite }`**

```lua
SMODS.Attachment {
    key = "red_clip",
    loc_txt = { name = "Red Clip", text = { "+#1# Mult per Clip held" } },
    config = { mult_mod = 5 },
    sprite = "red_clip.png",
    calculate = function(self, card, context)
        if context.card_played then return { mult = context.state.mult_mod } end
    end,
}
```

- The attachment's full key is `<your prefix>_<key>`. Fasten it to a card with
  `SMODS.set_attachment(card, key)` (a node, a view, or anything carrying
  `card_data`); its state is seeded as a deep copy of `config` and stored in
  `card_data.attachments[full_key]`, so it saves with the run like the card's
  own fields. `SMODS.get_attachment` / `SMODS.has_attachment` /
  `SMODS.remove_attachment` / `SMODS.attachment_keys` read and unfasten. A card
  may carry several attachments; whether it may carry more than one of a family
  is your mod's rule, not the channel's.
- `calculate(self, card, context)` fires at the same card moments a seal's
  does — `card_played`, `held_in_hand`, `on_round_end`, `on_discard` — after
  the seal, in registration order, plus one moment of its own:
  `context.after_scoring`, dispatched to the played cards and the hand when a
  hand's scoring finalizes (the seat for "resets after the hand" effects).
  `context.state` is the attachment's own state table on that card — write to
  it and the writes persist. Returns merge by the center rules (`chips`,
  `mult`, `x_mult`, `x_chips`, `dollars`, and the rest of the return table).
- Retriggers mirror seals: `retrigger` / `retrigger_held` counts in the state
  (or the def's `config`), or a `calculate` asked with `context.repetition`
  returning `repetitions`.
- A debuffed card's attachments never fire.
- Honest limit: `sprite` registers the art (for tooltips and collections), but
  the card face draws no attachment badge in this build.

## Custom tags

**`SMODS.Tag { key, loc_txt, config, apply, weight, min_ante, in_pool, sprite }`**

```lua
SMODS.Tag {
    key = "windfall",
    loc_txt = { name = "Windfall Tag", text = { "Gain {C:money}$#1#{}" } },
    config = { type = "immediate", dollars = 7 },
    sprite = "windfall.png",
    loc_vars = function(self, info_queue, tag) return { vars = { self.config.dollars } } end,
    apply = function(self, tag, context)
        G.money = G.money + tag.ability.dollars
        return true
    end,
}
```

A tag's **type** -- the bare key, as written -- is the string a held tag carries
(`tag.type`), the way a consumable kind is its set's key. Types are global: no
two mods may register the same one, and none may reuse a vanilla tag's name.
Registering a clash is a load error naming it.

A registered tag is gained exactly like a vanilla one: `G:addTag("windfall")`
or `G:addTag("tg_windfall")` (bare key or full id), the skip poll, a Double Tag
copy. Naming a tag that is neither vanilla nor registered is an error naming
it. The held tag's `ability` is a copy of the def's `config`.

- **Moments.** `config.type` says when the tag's `apply(self, tag, context)`
  runs (`context.type` names the moment, `context.tag` is the held tag):
  `immediate` (as the tag is gained -- the default), `new_blind_choice` (at
  blind select, one tag per screen, like the pack tags), `shop_start` and
  `shop_final_pass` (bracketing the shop roll as the shop is entered),
  `round_start_bonus` (as a blind starts, Juggle Tag's seat), and `eval` (in
  the Boss payout, Investment Tag's seat; the context carries the payout's
  `add_round_win_payout(name, dollars)`). Returning true consumes the tag;
  returning false -- or having no `apply` -- leaves it held.
- **Shop moments.** Two moments run in the shop, with the offer itself as
  `context.card` (a plain table: `id`, `edition`, `price`, `stickers`,
  `create_params`): `store_joker_create` fires as a shop Joker offer is
  rolled -- over a draft carrying only `id` / `edition` / `stickers`, before
  the offer is priced or built, so rewriting the draft's `id` or `edition`
  changes the offer that lands (the Uncommon / Rare Tags' seat; booster-pack
  rolls are not shop offers and never fire it). `store_joker_modify` fires
  over the finished offer as it takes its shelf slot -- after the vanilla
  edition tags and Coupon have had their say, so a price it sets sticks --
  and again when a shelved offer is rebuilt under a new id (a pool swap).
  The vanilla `voucher_add` / `tag_add` types still cannot be registered:
  nothing in this engine runs a tag's own effect when a voucher is redeemed
  or a tag is gained (a gain raises the `tag_added` Joker context instead).
- **The skip poll.** A registered tag joins the poll at its `weight`, where
  every vanilla tag weighs 1: default 1, 0 keeps it out (it can still be
  created directly). `min_ante` gates it like a vanilla tag's, and
  `in_pool(self, game)` may veto it. The custom draw runs on its own random
  stream, so the vanilla picks are exactly what they would be with no tags
  registered.
- **Art and collection.** A mod tag may carry `sprite = "Name.png"` as its
  icon; without one it draws as a plain outline. Either way it is listed in
  the collection's Tags category alongside the vanilla tags, discovered when
  first gained. Its tooltip -- on the blind-select skip reward -- shows its
  name and `loc_txt` lines.
- **Saves.** A held tag saves as its type string, like a vanilla one, and a
  tag whose mod is gone loads harmlessly: it never fires, and a fresh restore
  skips its type rather than failing.

## Custom booster packs

**`SMODS.Booster { key, loc_txt, pool, card_count, picks, cost, weight, sprite, colour }`**

```lua
SMODS.Booster {
    key = "vault",
    loc_txt = { name = "Vault Pack", text = { "Choose {C:attention}1{} of {C:attention}4{} Minor Arcana" } },
    pool = { consumable = "Minor" },
    card_count = 4, picks = 1,
    cost = 6, weight = 100,
    sprite = "vault.png",
    colour = { 0.5, 0.9, 0.6 },
}
```

A pack's **name** -- the registration key, lowercased -- is the string a shop
offer carries, the way a consumable kind is its set's key. Names are global:
no two mods may register the same one, and none may reuse a vanilla name
(`arcana`, `celestial`, `spectral`, `standard`, `buffoon`).

- **The shop roll.** A registered pack joins the shop's booster profile
  pool at its `weight`, in the pool's own units (a vanilla normal pack
  weighs 100, a Jumbo 100, a Mega 25; the default here is 60). The roll
  stays a single draw: with no packs registered the pool and its seeded
  sequence are exactly vanilla's, and with some registered the vanilla
  shares dilute, the way custom consumable kinds dilute the shop's card
  roll. `weight = 0` keeps a pack out of the shop (it can still be opened
  by id). A challenge can ban a pack by its full id, like a vanilla centre.
- **One size of its own.** Vanilla packs come in normal / jumbo / mega; a
  registered pack declares its size directly: `card_count` cards (default
  3, at most 10), `picks` of them chosen (default 1). `cost` is its shop
  price (default $4) before inflation and discounts -- the price a
  refresh recomputes, so it sticks. Buying one discovers its collection
  entry, like a vanilla pack.
- **Pools.** `pool` names where the cards come from, dealt through the
  same builders the vanilla kinds use: `{ consumable = "<kind>" }` deals
  that consumable kind -- a vanilla one, or a kind registered with
  `SMODS.ConsumableType` -- Soul / Black Hole polls included for the kinds
  that have them; `{ jokers = true }` deals unique Jokers, like a Buffoon
  pack; `{ playing = true }` deals playing cards, like a Standard pack.
  `{ mixed_mod = true }` deals only mod content, coin-flipped per card
  between a Joker and a consumable (MoreFluff's Modded packs). A
  consumable pack shows the hand when a card it dealt needs one, judged
  card by card like the pick gates judge them. One honest limit: the
  engine culls duplicates and in-play copies from a pack, so a pack whose
  pool holds fewer distinct cards than its `card_count` comes up short
  rather than repeating itself.
- **Art.** `sprite = "Name.png"` is the wrapper: drawn on the shop shelf,
  as the pack flies open, and in the collection. `colour = { r, g, b }`
  tints the opening burst. Without a sprite the pack draws the plain
  booster fallback panel and a white burst.
- **Collection.** Registered packs list in the Boosters category after
  the vanilla packs, under the name and art of the registration.

## Shop, voucher and booster APIs

The shop's shelves are offer tables, and Wave 6 lets a mod put offers on
them, take vouchers on and off the redeemed list, and reach inside an
opening booster pack. Every function here is a no-op (or returns nil)
outside the state it belongs to, and none of them spends a random draw
while no mod uses them: a seeded vanilla shop, pack contents included,
is unchanged until a mod acts.

### Inserting offers

- **`SMODS.add_booster_to_shop(pack, opts)`** shelves a booster pack
  offer: a vanilla pack name (`"arcana"`, `"celestial"`, `"spectral"`,
  `"buffoon"`, `"standard"`) or a registered booster's pack name or full
  id. `opts.size` picks a vanilla size (default `"normal"`); `opts.free`
  shelves it at $0 (Paperback's Backpack coupons its pack); `opts.price`
  overrides the base price before discounts (MoreFluff's lettergem B
  sells its Buffoon pack for $7). Returns the offer, or nil outside a
  shop or for an unknown pack.
- **`SMODS.add_shop_card(spec)`** shelves a card or consumable offer:
  `spec.set` is `"Joker"` or a consumable kind, `spec.key` the centre
  id, `spec.edition` an edition string, `spec.free` / `spec.price` as
  above. A Joker offer is built like a rolled one -- stickers, create
  params and price -- and the shelf may grow past the slot count, the
  way PC's shop area grows for Bunco's Running Joke. The inserted offer
  hears `modify_shop_card` before it is shelved.
- **`SMODS.add_voucher_to_shop(opts)`** shelves one more voucher offer:
  a fresh roll excluding the shelved and the owned, or `opts.key` for a
  specific voucher. `opts.price_fac` multiplies its price (MoreFluff's
  Junk Mail charges 1.5x); the factor lives on the offer, so repricing
  keeps it and later offers never see it.
- **`SMODS.multiply_shop_prices(fac)`** multiplies every current shelf
  price (cards, boosters, vouchers) by `fac`, Cryptid's ://DIVIDE.
  Per-offer, like `price_fac`: new offers are unaffected, a $0 offer
  stays $0, and the factor dies with the offer on reroll.

### Vouchers: grant and unredeem

- **`SMODS.grant_voucher(id)`** redeems a voucher without a purchase:
  the id joins the redeemed list and its effect applies as if bought
  (a mod voucher's `redeem` runs; a vanilla one applies through the
  game's own path). Returns false when the voucher is already held or
  unknown. A grant is not a buy: no `buying_card` fires.
- **`SMODS.unredeem_voucher(id)`** takes a redeemed voucher back,
  Cryptid's Trade seat. A mod voucher runs its `unredeem` callback with
  the ability snapshot its `redeem` was handed. Vanilla vouchers
  reverse what redeem applies as a delta (Overstock's shop slot, Paint
  Brush's hand size) plus the capacity refreshes; everything the game
  reads live from the voucher list (rates, caps, weights, Observatory,
  Magic Trick) simply stops applying. One-time effects already spent
  are not rewound: Hieroglyph's ante drop stands.

### Inside an opening pack

`context.open_booster` fires once the pack's choices are dealt and its
session exists:

- **`context.booster`** (also `context.card`, PC's seat) is the pack
  view: `{ pack, size, name, pool_kind, consumable_kind, card_count,
  picks }`. `pool_kind` is `"consumable"`, `"jokers"`, `"playing"` or
  `"mixed_mod"`; for a vanilla consumable pack `consumable_kind` is
  `"tarot"`, `"planet"` or `"spectral"` (Cryptid's Digital
  Hallucinations reads exactly this).
- **`context.choices`** is the session's live choice list. A `calculate`
  may rewrite an entry in place -- enhance a dealt playing card, say,
  the way Bunco's JMJB does -- and the player picks from the rewritten
  deal.
- **`SMODS.add_card_to_booster(spec)`** appends one choice, in the same
  shapes the pack dealt: `{ set = "Joker", rarity = n }` (or `key` for
  a specific Joker), `{ set = "<kind>" }` for a consumable, `{ set =
  "Playing" }`. MoreFluff's Bonus Sheet is the model caller.
- Returning **`{ add_picks = n }`** grants extra picks from the open
  pack, clamped to the number of choices (Bunco's Aristocrat).
- **`SMODS.queue_next_booster_bonus(cards, picks)`** queues a bonus for
  the NEXT pack opened (Cryptid's ://OFFBYONE): that many extra dealt
  cards and picks on top of the pack's own. It is spent by the opening
  itself, never by previews or rerolls, and survives a snapshot.

### Declared modifiers

Passive seats a mod declares in a Joker's or voucher's `config`, summed
over held Jokers and redeemed mod vouchers by `SMODS.modifier_total`
(the [Modifiers](#modifiers) machinery), all zero in a vanilla run:

- **`booster_size_mod`** -- every pack deals that many extra cards
  (Paperback's Protocol).
- **`voucher_limit_mod`** -- the shop shelves that many extra voucher
  offers (Paperback's Everything Must Go).
- **`shop_size_mod`** -- the shop fills that many extra card slots
  (Paperback's Shopping Center).
- **`spectral_rate_mod`** -- adds to the shop queue's Spectral rate,
  on top of the deck's own (Paperback's Ouija Board).
- **`free_shop_purchases`** -- while any held Joker declares it
  non-zero, card and consumable offers are $0 (Paperback's NormalJKR).
  Vouchers and boosters still charge. A price that reaches $0 stays $0
  for the rest of the shop visit, the same behaviour the Astronomer's
  free Planets already have in this engine.

Two one-off seats ride along:

- **`game.rare_mod`** is a plain field on the game (default 1) that
  scales the shop's Rare band; a Joker moves it from `add_to_deck` /
  `remove_from_deck` the way PC moves `G.GAME.rare_mod` (MoreFluff's
  Gem Alert multiplies it by 6.7). Uncommon keeps its 25% band beneath
  the widened Rare band.
- **`replace_common_rarity = true`** on a Joker def (Bunco's
  Doorhanger): while such a Joker is held, a Common shop rarity roll
  becomes Uncommon, or Rare on a seeded 1-in-50 roll. The rewrite
  happens before the pool is picked and draws nothing when no such
  Joker is held.
- A numeric **`swap = f`** return blends the running totals: each
  moves the fraction `f` toward the other (`swap = true` stays the
  full exchange). MoreFluff's Plasma Sliver trades a tenth this way.
- A consumable centre may declare **`end_of_round(self, card, game)`**:
  it fires once per round end for each held copy, after the round-end
  Joker batch -- the seat MoreFluff's Colour cards grow on.

## Custom decks

**`SMODS.Back { key, loc_txt, config, unlocked, unlock_condition, pos, sprite, apply, start_consumables, start_vouchers, omit }`**

```lua
SMODS.Back {
    key = "hearts_only",
    loc_txt = { name = "Hearts Only", text = { "Start with only {C:attention}Hearts{}" } },
    config = { discards = 1 },
    unlocked = true,
    pos = { x = 5, y = 2 },
    apply = function(game, back, is_sleeve)
        for i = #game.deck.cards, 1, -1 do
            if game.deck.cards[i].suit ~= "Hearts" then
                table.remove(game.deck.cards, i)
            end
        end
    end,
}
```

A registered deck's id is `b_<prefix>_<key>`, the shape vanilla deck ids
already have. It joins the deck catalog after the vanilla decks: the
deck-select carousel (and the sleeve carousel) lists it, the collection
shows it, and snapshots record it by id like any deck.

- **`config`** is in the catalog's own terms: `hands`, `discards`,
  `dollars`, `hand_size`, `joker_slots`, `consumable_slots`,
  `extra_hand_bonus`, `extra_discard_bonus`, `no_interest`,
  `spectral_rate`, and the deck rewrites `no_face_cards`, `suit_filter`
  and `suit_split` (a run applies at most one rewrite: the primary
  deck's, or the sleeve's when the primary has none). One term is this
  port's own: `ante_scale`, a multiplier on the blind requirement
  (Plasma's doubling is the vanilla precedent). Numbers merge the way
  sleeves merge: modifiers add, `no_interest` ORs, `ante_scale`
  multiplies.
- **`apply(game, back, is_sleeve)`** fires once at run setup, after the
  deck is built, any rewrite ran, and `start_consumables` /
  `start_vouchers` were given. `game.deck.cards` holds the raw
  `card_data` tables (`rank`, `suit`, `enhancement`, `seal`, `edition`),
  so a deck that keeps only some cards, or stamps the rest, edits that
  list; starters beyond the start lists go through `SMODS.add_card`.
  Loading a saved run never refires it: restore reapplies the modifiers
  only, like a vanilla deck.
- **Unlocks.** `unlocked = true` starts open. Otherwise declare the
  gate vanilla decks use: `unlock_condition = { type =
  "discover_amount", amount = N }` opens at N discoveries, and
  `{ type = "deck_win", deck_id = ..., stake_id = ... }` (either field
  nil means any) opens on a run win. With neither, the deck starts
  locked and nothing opens it.
- **Art.** `pos` is the playing-card back the deck wears in a run: a
  vanilla `centers` index, or `{ x, y }` in that atlas' 7-wide grid.
  `sprite = "Name.png"` is a card-sized image in `assets/1x` the deck
  carousel draws instead of the atlas back; a locked deck still shows
  the locked back. In-run backs stay atlas backs either way.

Two scoring/money seats registered decks and Jokers share:

- **`SMODS.adjust_blind_target(delta)`** moves the current blind's
  requirement by `delta` (negative lowers it), Big-aware and floored at
  0, and returns the new target.
- **`debt_limit`** in a Joker's `config` (so it lands on its ability):
  while that Joker is held, the player may spend that far below $0. It
  adds to the Credit Card's limit, and the money-loss floor drops with
  it. Vanilla Jokers never declare it, so a run without one plays by
  the vanilla money rules.

## Card faces

```lua
SMODS.DeckSkin {
    key = "royal_court",
    suit = "Spades",                          -- "Hearts", "Clubs", "Diamonds" or "Spades"
    loc_txt = { name = "Royal Court" },       -- or just loc_txt = "Royal Court"
    sprite = "royal_court_spades.png",        -- 216x95 strip: J, Q, K
    hc_sprite = "royal_court_spades_hc.png",  -- optional high-contrast strip
}
```

A deck skin is a set of Jack, Queen and King art for one suit, like the built-in collab sets. It shows up in **Options → Art** at the end of its suit's carousel, and the player picks it there the same way.

- **`sprite`:** one strip of three 72 × 95 cells, Jack, Queen and King from left to right. This is the same format as the game's own sets in `resources/textures/1x/collabs/`. Keep everything outside the art transparent so the card front shows through. The deck's own faces keep their art between x = 6 and x = 64 of each cell.
- **`hc_sprite`:** the strip used when the player ticks High Contrast for the suit. Without one, `sprite` is used at both settings.
- **Ranks:** only the face cards can be replaced. If `ranks` is given, it must be `{ "Jack", "Queen", "King" }`.
- **Atlases:** Steamodded's `lc_atlas` and `hc_atlas` aren't supported. Use `sprite` and `hc_sprite`.

Deck skins are cosmetic. If the mod is removed, a suit that used one goes back to the deck's own art.

## Saved runs and mods

A run remembers exactly which mods, and which versions, it was played with. It can only be continued with that same set installed and turned on. If a mod is missing, turned off, at a different version, or newly added, **Continue** opens the Mods screen and lists what to install, turn on, or turn off. The save is kept, not deleted, and works again once the mods match. Switching mods on that screen updates the list as you go.

This is why `version` matters: bump it when a change would break a run in progress (adding or removing a card, changing what `config` holds), and keep it when it wouldn't.

## Score preview dry runs

The **Preview** setting (pause menu → Settings → General, off by default) shows the exact score of the current selection before it is played. There is no pure evaluate function in this engine, so the preview plays the hand inside a snapshot and restores the run afterwards — RNG streams included, so random effects (Lucky, Glass) preview to the exact number the real play then produces.

For mod authors this means `calculate` runs during a dry run too. Run state is restored bit-for-bit afterwards, and profile-level effects (career stats, unlocks, discovery) are suppressed while it runs — but treat `calculate` as a pure query, the way the contexts section above already asks: anything your code changes **outside** the run (files, globals your mod keeps between calls) is not rewound.

## What doesn't work (yet)

- **No other content yet.** Blinds can't be added. (Rarities, suits, poker hands, consumable types, enhancements, seals, editions, tags, booster packs and decks can: see [Custom rarities, suits, poker hands and consumable types](#custom-rarities-suits-poker-hands-and-consumable-types), [Custom enhancements, seals and editions](#custom-enhancements-seals-and-editions), [Custom tags](#custom-tags), [Custom booster packs](#custom-booster-packs) and [Custom decks](#custom-decks).) Vouchers have no `calculate`, and deck skins cover only the face cards.
- **No `G.GAME`, `G.jokers.cards`, `G.E_MANAGER`, `SMODS.destroy_cards` (the one-card `SMODS.destroy_card` above exists), `SMODS.calculate_effect`, hooks into `Game:init_game_object`, or `reset_game_globals`.** The port's game state is laid out differently. Code that touches these raises a runtime error. The error is caught: that Joker does nothing for that call, and the error appears on the Mods screen and in `mods_log.txt`.
- **No shaders.** Foil, Holographic and Polychrome mod Jokers are drawn with the port's own additive texture passes, like vanilla Jokers. Negative needs its own art (see [Negative art](#negative-art)).
- **`yes_pool_flag`, `no_pool_flag` and `info_queue` are ignored.** `in_pool` returns only whether the Joker can roll; a second `allow_duplicates` return is ignored.
- **Contexts not raised yet:** `debuff_hand`, `modify_scoring_hand`, `evaluate_poker_hand`, `check_enhancement`, `initial_scoring_step`, `playing_card_end_of_round`, `change_rank` and `change_suit`. The scoring set is computed in one pass with the Blind rules interleaved, and rank/suit changes are direct writes with no setter to hang a context on, so these need deeper changes to the port's scoring and deck code rather than a dispatch point.

## Debugging

- **Load errors:** a mod that fails to load (bad manifest, missing dependency, an error in its main file) is undone completely and listed on the Mods screen with the reason. Other mods still load.
- **Runtime errors:** errors inside `calculate`, `loc_vars`, `can_use`, `use` or `redeem` are caught and listed. The game keeps running.
- **Log:** `mods_log.txt` is rewritten at every boot, on every mod switch, and on every runtime error, so it is always up to date when you read it off the SD card.
