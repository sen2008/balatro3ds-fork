# Localization Architecture

> Contributed by [Fussyzhy](https://github.com/Fussyzhy), from their Chinese translation of this port
> ([Balatro3DS-zh](https://github.com/Fussyzhy/Balatro3DS-zh)), along with `localization.lua` and the
> `locales/` strings. The font, wrapping and verification sections below describe how it works here.

Balatro3DS keeps gameplay data language-neutral and translates text only when it is displayed.
This document defines the contract for all localization work.

## Supported Languages

- `en`: English and the fallback language.
- `zh_CN`: Simplified Chinese.

Language codes are stable save-file values. Do not rename an existing code after release.

## Translation Keys

Keys use lower-case dot-separated namespaces:

```text
menu.new_run
settings.language
hand.flush
suit.hearts
joker.j_joker.name
joker.j_joker.description
consumable.tarot_fool.name
blind.bl_hook.description
```

Use these top-level namespaces:

- `menu`, `settings`, `controls`, `common`: fixed interface text.
- `hand`, `suit`, `rank`, `term`: shared gameplay terminology.
- `joker`, `consumable`, `deck`, `stake`, `blind`, `voucher`, `tag`: catalog content.
- `tutorial`, `collection`, `shop`, `round`, `game_over`, `win`, `hud`, `blind`, `booster`,
  `deck_view`, `run_info`, `profile`, `career`, `mods`, `pause`, `toast`, `challenge`,
  `joker_display`: screen-specific text.
- `smods`: the vanilla message keys mods pass to `localize` (`smods.k_upgrade_ex`).

Keys identify meaning, not the English sentence. A wording change must not require a key change.

## Internal Values

The following values are gameplay protocol and must remain language-neutral:

- Catalog IDs such as `j_joker`, `tarot_fool`, `b_red`, and `v_overstock_norm`.
- Hand names used by scoring and Joker effects, such as `Pair`, `Flush`, and `Straight Flush`.
- Suit and rank values, such as `Hearts`, `Spades`, `Jack`, and `Ace`.
- State names, save keys, event names, atlas names, and edition names.

Never compare translated text in gameplay code. Translate an internal value only at the display boundary.

## Runtime API

All display text must go through the localization module:

```lua
I18N.t("menu.new_run")
I18N.t("round.score", { score = 120, target = 300 })
I18N.content_name("joker", def.id, def.name)
I18N.content_description("joker", def.id, def.tooltip)
I18N.hand_name("Straight Flush")
I18N.suit_name("Hearts")
```

The runtime uses this lookup order:

1. Selected language.
2. English fallback.
3. Explicit fallback passed by the caller.
4. Translation key, so missing entries remain visible during testing.

Parameters use named placeholders such as `{score}` and `{target}`. Placeholder names must match
between every language.

### Interface text

Screens keep their English in the code and look the translation up beside it:

```lua
love.graphics.printf(I18N.text("pause.title", nil, "Paused"), x, y, w, "center")
string.format(I18N.text("round.cash_out", nil, "Cash Out: $%d"), total)
```

`I18N.text(key, params, english)` returns `english` untouched while the language is English, so
English never depends on `locales/en.lua` matching the code. `locales/en.lua` still lists every key
with the code's English, as the reference translators work from.

Strings drawn every frame use `string.format` directives (`%d`, `%s`) rather than placeholders, so
no parameter table is built per frame. A translation must keep the same directives in the same
order; the tests check this.

Labels that come from a table (menu entries, settings toggles, profile rows) are looked up by the
entry's key at draw time, `I18N.text("menu.entry." .. entry.kind, nil, entry.label)`, so the table
itself stays English. Anything shaped into a cache (TopUI's labels, the shop's buttons) is keyed on
the language as well, so a language change rebuilds it.

How to Play is one table per language (`tutorial.pages`). A translation supplies the same number of
pages as the English.

## Catalog Migration

Existing English catalog fields remain in place as compatibility fallbacks during migration. Display
code derives localization keys from the content type and stable ID. Gameplay code may continue using
the original fields where they form part of an internal rule.

Do not place translated copies directly in catalog definitions. Translations belong in `locales/`.

Large catalogs are split into modules under `locales/content/<language>/`:

```text
locales/content/zh_CN/terms.lua
locales/content/zh_CN/decks.lua
locales/content/zh_CN/stakes.lua
locales/content/zh_CN/blinds.lua
locales/content/zh_CN/vouchers.lua
locales/content/zh_CN/tags.lua
locales/content/zh_CN/consumables.lua
locales/content/zh_CN/jokers.lua
```

English catalog fields remain the fallback source of truth. English content modules are needed only
for shared runtime templates that do not already exist in a catalog field.

## Fonts

English uses `m6x11plus`, baked into one bitmap sheet per size (`fonts.lua`, `dev/build.sh`).

Any other script uses a language face from `Fonts.LANGUAGE_FACES` in `fonts.lua`. Simplified Chinese
uses **GoNotoCJKCore** (`resources/fonts/GoNotoCJKCore.ttf`).

- **Why it's cut down:** a full CJK font can't ship. `mkbcfnt` rasterises every glyph, and a complete
  CJK face is tens of thousands of glyphs, which is hundreds of megabytes or a crash.
- **What the build does:** `dev/build.sh` runs `dev/bake_cjk_font.py` for every entry in `LANGUAGE_FONTS`
  in `dev/config.sh`. It collects every character in that language's locale files, plus printable ASCII,
  cuts the font down to those characters with fontTools, and bakes one `.bcfnt` per cell height. A new
  string is picked up on the next build; there's nothing to maintain by hand. Results are cached by
  font and character set.
- **Sizes:** the sheets are baked at heights `mkbcfnt` can actually produce from GoNoto (13, 17, 21,
  26, 32). Each role draws from the largest one that fits, at exactly 1.0 scale, and never below
  13 px: m6x11plus's 9 px roles are legible for Latin pixel text and unreadable for Chinese. Those
  heights live in `Fonts.LANGUAGE_CELL_HEIGHTS` and `CJK_CELL_HEIGHTS`, and a test fails if they differ.
- **Desktop:** there are no sheets, so the full `.ttf` is drawn at the same sizes.
- **Memory:** only the active language's faces are loaded. Switching language rebuilds `G.FONTS.PIXEL`
  in place (`Fonts.apply`), so screens keep using `G.FONTS.PIXEL.SMALL` and the rest unchanged.

## Layout

All translated text must be measured using the active font. Fixed-width controls must either wrap,
select a smaller font, or truncate only when the screen explicitly permits it. CJK wrapping must work
between UTF-8 characters and must not depend on spaces.

Tooltips must use structured color metadata. Parsing English words such as `chips` or `mult` is a
temporary compatibility path, not a localization mechanism.

Use structured lines when a translation needs semantic coloring:

```lua
["joker.j_joker.description"] = {
    { text = "+4 倍率", color_key = "MULT" },
}
```

Supported tooltip color keys include `MULT`, `CHIPS`, `MONEY`, `CHANCE`, `IMPORTANT`, `PURPLE`, and
`RED`. The shared tooltip renderer wraps UTF-8 text between CJK characters, preserves segment colors,
limits the tooltip to the bottom screen, and truncates only when the full content cannot fit.

## Source Encoding

Lua source and locale files are UTF-8. Runtime code should stay ASCII where practical; non-ASCII text
belongs primarily in locale files.

## Verification

Every localization change should verify:

- English and Simplified Chinese contain the same required keys.
- Placeholder sets match across languages.
- Catalog entries resolve to a translated name and description where applicable.
- No translated value is persisted as an internal gameplay identifier.
- Text stays within the `400x240` top screen and `320x240` bottom screen.

The automated checks run with the rest of the test suite (`./tests/run.sh localization`, in
`tests/test_localization.lua`). They fail on:

- an interface key in another language that English doesn't have;
- placeholder sets that differ from English;
- a catalog entry with no printable name in some language;
- `dev/config.sh` and `fonts.lua` disagreeing on the language font heights;
- a translated format string whose `%d`/`%s` directives differ from English;
- a How to Play translation with a different number of pages;
- English left on a translated screen: the test draws the menus, settings, a run (blind select,
  shop, a booster pack, the cash out, run info, deck view) and both end screens in Chinese, and
  fails on any run of four Latin letters it prints, beyond a short list of button names.

They also cover UTF-8 splitting, CJK line wrapping, the saved setting and the main-menu language
picker.

## Adding A Language

1. Add the language code to `Localization.SUPPORTED_LANGUAGES` in `localization.lua`.
2. Add `locales/<language>.lua` with every fixed-interface key present in `locales/en.lua`.
3. Add the required modules below `locales/content/<language>/`.
4. If `m6x11plus` can't draw it, add a face to `Fonts.LANGUAGE_FACES` in `fonts.lua` and a matching
   `LANGUAGE_FONTS` entry in `dev/config.sh`. For a CJK language, GoNotoCJKCore already covers it.
5. Run `./tests/run.sh localization`.
6. Complete the desktop and 3DS QA checklist before release.

Keep parameter names unchanged across languages. Never translate catalog IDs, hand identifiers, suit
identifiers, save keys, or other values consumed by gameplay code.

## QA Checklist

### Desktop / Emulator

- Start with a new profile in English and Simplified Chinese.
- Switch languages with **Settings → Language** and confirm that the font and visible UI update immediately.
- Restart the game and confirm that each profile restores its own language.
- Visit the main menu, tutorial, deck/stake picker, blind select, shop, booster packs, collection,
  deck view, pause/settings, round win, game over, and victory screens.
- Inspect long Joker, consumable, voucher, blind, tag, deck, enhancement, seal, and edition tooltips.
- Confirm CJK lines wrap without spaces, colored segments remain aligned, and tooltips stay within the
  `320x240` bottom screen.
- Load an existing English save and confirm internal hand, suit, blind, item, and voucher IDs still work.
- Switch back to English and confirm no translation keys are shown to the player.

### Nintendo 3DS Hardware

- Build with the LovePotion/Lovebrew toolchain and launch the generated `.3dsx` on hardware.
- Confirm the baked `zh_CN_h*.bcfnt` sheets load, every character in the translation draws (none
  missing from the cut-down font), and switching language releases the previous faces.
- Repeat the major screen and tooltip checks on both top and bottom displays.
- Verify touch targets, gamepad focus, and text do not overlap at native `400x240` and `320x240` sizes.
- Save, quit, relaunch, and verify the profile language and run snapshot remain compatible.
- Play at least one complete run in each language and inspect score, payout, Boss Blind, dynamic Joker,
  and victory statistics text.

The headless tests can check the strings, wrapping and settings, but not how text actually looks on
the screens, so hardware validation is still required before a multilingual release.
