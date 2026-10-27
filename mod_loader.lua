--- Finds and loads mods from the save directory.
---
--- Layout, Steamodded's:
---
---     <save dir>/sdmc/mods/<Folder>/<Anything>.json    the manifest: id, name, prefix, main_file, version
---     <save dir>/sdmc/mods/<Folder>/<main_file>.lua    run once at boot, before the game is built
---     <save dir>/sdmc/mods/<Folder>/assets/1x/*.t3x     one image per card (named as .png, see smods.lua)
---
--- Mods load in id order, so the same set of mods always registers in the same order. Each runs
--- in its own environment over the game's globals: it can read everything, but globals it
--- defines stay its own instead of landing on top of the game's. A mod that fails -- a bad
--- manifest, a missing dependency, an error in its main file -- is rolled back and listed on the
--- Mods screen with the reason; the others still load.
---
--- Every boot writes `mods/mods_log.txt` beside the mods, so a modder on hardware, with no
--- console, can read why something did not load.
---
--- Mods are opt-in: the game starts with none of them loaded. The player turns mods on in
--- Options > Mods, and the ids of the ones turned on are kept in `mods/enabled.txt`, one per
--- line, so the selection survives a reboot and can be edited off the card. A card with no
--- `enabled.txt` loads no mods at all. (`mods/disabled.txt`, written by older builds, is not
--- read any more -- the enabled list is the only selection there is.)
---
--- Turning a mod ON loads it into the running session there and then (`load_mod`), as long as no
--- run is in memory; turning it OFF only records the choice -- a loaded mod's content is never
--- pulled out mid-session, so it stops loading from the next boot on. See `set_enabled`.
---
--- A build can also carry mods inside the game archive itself, under `mods_bundled/`
--- (the "super" build does; the normal build has no such folder). Those are scanned
--- exactly like card mods and marked `bundled`, with one identity rule across both
--- roots: a manifest id found in `sdmc/mods` shadows the bundled mod of the same id,
--- so a card install or update always wins over the copy in the archive. The archive
--- is read-only, so nothing is ever written into a bundled folder: the selection and
--- the log stay on the card, and a bundled mod's compiled cache redirects to
--- `sdmc/mods/.cache/` (see the cache section below).

local Json = require("json")
require("smods")

local ModLoader = {}

ModLoader.DIR = "sdmc/mods"
ModLoader.BUNDLED_DIR = "mods_bundled"
ModLoader.CACHE_DIR = "sdmc/mods/.cache"
ModLoader.LOG_PATH = "sdmc/mods/mods_log.txt"
ModLoader.ENABLED_PATH = "sdmc/mods/enabled.txt"

--- Every mod found, in load order. Each: `{ id, name, version, prefix, author, description,
--- path, main_file, dependencies, bundled, status = "loaded"|"error"|"disabled"|"pending", error,
--- runtime_errors, registered = { jokers, consumables, vouchers, sprites },
--- timings = { manifest, compile, execute, sprites, refresh, cache } }` (phases in
--- milliseconds, see "Load timing"). "pending" is
--- a mod the player turned on during a run: queued, it loads at the next boot.
ModLoader.mods = {}
ModLoader.by_id = {}
--- Scan notes for the log (a bundled mod shadowed by a card copy, today), rebuilt by
--- every `load_all` and printed by `write_log` under the mod list.
ModLoader.notes = {}
--- The player's saved selection: the ids turned on in Options > Mods, as a set. Read from
--- `ENABLED_PATH` by `load_all`; only these mods load at boot.
ModLoader.enabled = {}
--- The scanned mods that are NOT in the selection, as a set: what will not load. The
--- complement of `enabled` among the mods on the card, computed by `load_all` and kept in
--- step by `set_enabled`, because the load paths ask "is this one off?" a lot.
ModLoader.disabled = {}

--------------------------------------------------------------------------------
-- Load timing
--------------------------------------------------------------------------------

--- Milliseconds on the CPU clock. `love.timer` is the frame clock (the test harness
--- freezes it; hardware steps it per frame), while `os.clock` runs in both places, so
--- phase timings are comparable between them. Only ever take the difference of two
--- calls -- the absolute value means nothing.
local function clock_ms()
    return os.clock() * 1000
end

--- The phases of one mod's load, in milliseconds; every mod record carries one as
--- `timings`. `sprites` is part of `execute` -- sprites register while the main file
--- runs -- broken out because it is the part that stats files on the card. `refresh` is
--- set only on the mod whose load triggered a post-load refresh (nil otherwise).
--- `cache` says how the main file was compiled: "hit" (the precompiled cache beside
--- it, see `compile_main`), "miss" (compiled from source), or nil (never compiled).
local function new_timings()
    return { manifest = 0, compile = 0, execute = 0, sprites = 0, refresh = nil, cache = nil }
end

--- Post-load refresh time across this session (see `refresh_after_load`), in
--- milliseconds over `refresh_calls` calls. `reset` starts them over.
ModLoader.refresh_ms = 0
ModLoader.refresh_calls = 0

local function fs()
    return love and love.filesystem
end

local function is_dir(path)
    local f = fs()
    return f and f.getInfo and f.getInfo(path, "directory") ~= nil
end

local function new_mod(root, folder)
    return {
        id = folder, name = folder, version = "0.0.0", prefix = folder,
        folder = folder, path = root .. "/" .. folder,
        bundled = root == ModLoader.BUNDLED_DIR,
        author = "", description = "", dependencies = {},
        status = "error", error = nil, runtime_errors = {}, timings = new_timings(),
        registered = { jokers = {}, sprites = {}, consumables = {}, vouchers = {}, deck_skins = {}, strings = {} },
    }
end

local function fail(mod, msg)
    mod.status = "error"
    mod.error = tostring(msg)
    return mod
end

--- Read a mod folder's manifest: the first `.json` in it that names a `main_file`.
local function read_manifest(root, folder)
    local mod = new_mod(root, folder)
    local f = fs()
    local items = f.getDirectoryItems(mod.path) or {}
    table.sort(items)
    local parse_error
    for _, item in ipairs(items) do
        if item:lower():match("%.json$") then
            local text = f.read(mod.path .. "/" .. item)
            local ok, data = pcall(Json.decode, text or "")
            if not ok then
                parse_error = item .. ": " .. tostring(data)
            elseif type(data) == "table" and type(data.main_file) == "string" then
                mod.manifest_file = item
                mod.id = type(data.id) == "string" and data.id or folder
                mod.name = type(data.name) == "string" and data.name or mod.id
                mod.version = data.version ~= nil and tostring(data.version) or "0.0.0"
                mod.prefix = type(data.prefix) == "string" and data.prefix or mod.id
                mod.main_file = data.main_file
                mod.description = type(data.description) == "string" and data.description or ""
                if type(data.author) == "table" then
                    mod.author = table.concat(data.author, ", ")
                elseif data.author ~= nil then
                    mod.author = tostring(data.author)
                end
                if type(data.dependencies) == "table" then mod.dependencies = data.dependencies end
                if not mod.prefix:match("^[%w_]+$") then
                    return fail(mod, "prefix '" .. mod.prefix .. "' may only use letters, digits and _")
                end
                mod.status = "pending"
                return mod
            end
        end
    end
    return fail(mod, parse_error or "no manifest: add a .json with id, prefix, main_file and version")
end

--- Steamodded dependency strings look like `"OtherMod (>=1.0.0)"`; the id is everything before
--- the version clause. Steamodded itself is what this loader stands in for, so it is satisfied.
local function dependency_id(dep)
    local id = tostring(dep):match("^%s*([^%s%(<>=]+)")
    return id
end

--- @return string|nil problem why the mod cannot load
--- @return boolean waiting true while a dependency has yet to load
local function check_dependencies(mod)
    local waiting = false
    for _, dep in ipairs(mod.dependencies or {}) do
        local id = dependency_id(dep)
        if id and id:lower() ~= "steamodded" then
            local other = ModLoader.by_id[id]
            if not other then return "needs mod '" .. id .. "', which is not installed", false end
            if other.status == "disabled" then return "needs mod '" .. id .. "', which is turned off", false end
            if other.status == "pending" then
                waiting = true
            elseif other.status ~= "loaded" then
                return "needs mod '" .. id .. "', which failed to load", false
            end
        end
    end
    return nil, waiting
end

--------------------------------------------------------------------------------
-- Precompiled main files
--------------------------------------------------------------------------------

--- Compiling a pack's main file from source is about half its load time, so the loader
--- keeps the compiled chunk beside it (`<main_file>.luac`) and runs that instead when
--- it is provably the same source: the cache's first line records the source's size
--- and modtime, the cache format and the Lua version, and anything that does not
--- match -- or will not load -- falls back to compiling the source, which then
--- rewrites the cache. The known soft spot of a size+modtime key: an edit that keeps
--- the exact byte size and lands inside the filesystem's modtime tick (2s on FAT)
--- would run stale until the next change; deleting the `.luac` file always forces a
--- fresh compile. Semantics are the source's either way -- the dump keeps the
--- original chunk name and line numbers, so errors read as they did from source.
local LUAC_FORMAT = "balatro3ds-luac 1"
local loadstring_ = loadstring or load
local lua_version_tag = (tostring(_VERSION):gsub("%s+", "_"))

--- The cache file that sits beside a main file. For a bundled mod this is the cache
--- shipped inside the archive -- read-only, but readable.
local function luac_beside(mod)
    return mod.path .. "/" .. mod.main_file .. ".luac"
end

--- Where a freshly compiled cache is written: beside the main file for a mod on the
--- card. A bundled mod's folder is inside the game archive and cannot be written,
--- so its cache redirects to a per-id file in the cache dir on the card.
local function luac_write_path(mod)
    if mod.bundled then return ModLoader.CACHE_DIR .. "/" .. mod.id .. ".luac" end
    return luac_beside(mod)
end

--- The cache files a load tries, in order. A bundled mod tries the shipped cache
--- beside its main file first (a build ships cache and source together, so it is
--- the one to trust), then the redirected cache on the card.
local function luac_read_paths(mod)
    if mod.bundled then return { luac_beside(mod), luac_write_path(mod) } end
    return { luac_beside(mod) }
end

--- Read and validate one cache file; returns the compiled chunk or nil.
--- A card source must match the header's size AND modtime (that is what makes an
--- edit invalidate). A bundled source is validated on size, format and Lua version
--- only: its main file can change no other way than a new build, in which source
--- and shipped cache travel together, and the archive filesystem may report no
--- usable modtime for its files. Either way a cache that does not validate -- or
--- whose bytes will not load -- is ignored, never an error.
local function cache_chunk(mod, f, cache_path, main_path, info)
    local raw = f.read(cache_path)
    local nl = raw and raw:find("\n", 1, true)
    if not nl then return nil end
    local header, body = raw:sub(1, nl - 1), raw:sub(nl + 1)
    local size, modtime, version = header:match("^" .. LUAC_FORMAT:gsub("%W", "%%%1") .. " (%d+) (%d+) (%S+)$")
    if not size or tonumber(size) ~= info.size or version ~= lua_version_tag then return nil end
    if not mod.bundled and tonumber(modtime) ~= (info.modtime or 0) then return nil end
    return loadstring_(body, "@" .. main_path)
end

--- @return function|nil chunk, string how: "hit" when a cache supplied it, else "miss"
local function compile_main(mod, f, main_path, info)
    if loadstring_ and info.size and f.read then
        for _, cache_path in ipairs(luac_read_paths(mod)) do
            local chunk = cache_chunk(mod, f, cache_path, main_path, info)
            if chunk then return chunk, "hit" end
        end
    end
    local chunk, err = f.load(main_path)
    if chunk and loadstring_ and string.dump and info.size and f.write then
        local ok, dump = pcall(string.dump, chunk)
        if ok and dump then
            local header = ("%s %d %d %s\n"):format(LUAC_FORMAT, info.size, info.modtime or 0, lua_version_tag)
            if mod.bundled and f.createDirectory then pcall(f.createDirectory, ModLoader.CACHE_DIR) end
            pcall(f.write, luac_write_path(mod), header .. dump)
        end
    end
    if not chunk then return nil, err end
    return chunk, "miss"
end

local function run_mod(mod)
    local f = fs()
    local main_path = mod.path .. "/" .. mod.main_file
    local info = f.getInfo(main_path)
    if not (info and info.type == "file") then
        return fail(mod, "main_file '" .. mod.main_file .. "' not found")
    end
    local tm = mod.timings or new_timings()
    mod.timings = tm
    local t0 = clock_ms()
    local chunk, how = compile_main(mod, f, main_path, info)
    tm.compile = tm.compile + (clock_ms() - t0)
    if not chunk then return fail(mod, how or "could not compile " .. mod.main_file) end
    tm.cache = how
    setfenv(chunk, SMODS.mod_environment(mod))
    local sink = { ms = 0 }
    local prev_sink = SMODS.sprite_time_sink
    SMODS.sprite_time_sink = sink
    SMODS.current_mod = mod
    t0 = clock_ms()
    local ok, run_err = pcall(chunk)
    tm.execute = tm.execute + (clock_ms() - t0)
    SMODS.sprite_time_sink = prev_sink
    tm.sprites = tm.sprites + sink.ms
    SMODS.current_mod = nil
    if not ok then
        SMODS.rollback(mod)
        return fail(mod, run_err)
    end
    mod.status = "loaded"
    mod.error = nil
    -- The mod's registrations are in the game now. They stay there until the next boot's
    -- reload, even if the player turns the mod off in the meantime: `set_enabled` never
    -- unloads, so this flag is what tells it (and `load_mod`) the content is still live.
    mod._live = true
    return mod
end

local function read_enabled()
    local set = {}
    local f = fs()
    if not (f and f.getInfo and f.getInfo(ModLoader.ENABLED_PATH, "file")) then return set end
    for line in tostring(f.read(ModLoader.ENABLED_PATH) or ""):gmatch("[^\r\n]+") do
        local id = line:match("^%s*(.-)%s*$")
        if id ~= "" and id:sub(1, 1) ~= "#" then set[id] = true end
    end
    return set
end

local function write_enabled()
    local f = fs()
    if not (f and f.write) then return false end
    local ids = {}
    for id in pairs(ModLoader.enabled) do ids[#ids + 1] = id end
    table.sort(ids)
    -- The file is written even when the selection is empty: its presence on the card is
    -- the player's saved state, not an absence of one.
    local text = "# Mods turned on in Options > Mods, one id per line.\n"
    if #ids > 0 then text = text .. table.concat(ids, "\n") .. "\n" end
    return (pcall(f.write, ModLoader.ENABLED_PATH, text))
end

--- Record `id` as part of the player's selection, or remove it, keeping the in-memory
--- complement (`disabled`) in step. Saving is `write_enabled`'s job; callers choose when.
local function select(id, on)
    if on then
        ModLoader.enabled[id] = true
        ModLoader.disabled[id] = nil
    else
        ModLoader.enabled[id] = nil
        ModLoader.disabled[id] = true
    end
end

--- Whether the player can turn this mod off and on: it needs a manifest, which is where its id
--- comes from. A folder with no readable manifest has nothing to switch.
function ModLoader.can_toggle(mod)
    return type(mod) == "table" and mod.manifest_file ~= nil
end

function ModLoader.is_enabled(mod)
    return type(mod) == "table" and not ModLoader.disabled[mod.id]
end

--- What has to happen once the registries change, so content registered a moment ago is
--- reachable in a session that is already running: the collection rebuilds its cached
--- entries, and a game that already exists folds the new rarities, suits and poker hands
--- into its own tables. That second step is `SMODS.install_into_game`, the same call the
--- Game constructor makes at boot; it is idempotent, and the shop and selection pools
--- need nothing at all -- they read the registries as they roll, behind caches keyed by
--- the registered ids themselves. At boot no game exists yet, so only the collection
--- step runs, exactly as before.
--- @return number milliseconds the refresh took (also folded into `ModLoader.refresh_ms`)
function ModLoader.refresh_after_load()
    local t0 = clock_ms()
    local ok, catalog = pcall(require, "collection_catalog")
    if ok and type(catalog) == "table" and catalog.invalidate_cache then catalog.invalidate_cache() end
    local game = G
    if type(game) == "table" and SMODS and SMODS.install_into_game then
        SMODS.install_into_game(game)
    end
    local ms = clock_ms() - t0
    ModLoader.refresh_ms = ModLoader.refresh_ms + ms
    ModLoader.refresh_calls = ModLoader.refresh_calls + 1
    return ms
end

--- Whether a mod may be loaded into the running session. Loading registers content and
--- refreshes the pools and collection around it, which is only safe while no run is in
--- memory. The game's own lifecycle field says where we are: `STAGE` is MAIN_MENU at the
--- title and RUN from a run's start until the menu is re-entered -- the same field the
--- game's own "not in run" guards read. Before the game exists (boot, tests) there is
--- no run to disturb. The Mods page is only reachable from the main menu today, so this
--- fence is what keeps the API honest if a path to it ever opens mid-run: there the
--- switch still records the choice, and the mod loads at the next boot instead.
function ModLoader.hot_load_allowed()
    local game = G
    if type(game) ~= "table" then return true end
    if type(game.STAGES) ~= "table" or game.STAGE == nil then return true end
    return game.STAGE == game.STAGES.MAIN_MENU
end

--- Set by `load_with_dependencies` when it pulls a dependency into the selection;
--- `load_mod` saves the selection again when it is set.
local selection_grew = false

--- Run one mod and everything it depends on, dependencies first. A dependency that is
--- not installed refuses the load; one that will not run is retried here and, if it
--- still fails, refuses with "failed to load" -- the boot pass's words. A dependency
--- that simply was not in the player's selection is no refusal in a session: it is
--- loaded on the way and joins the selection, because the boot pass pulls nothing in,
--- so the selection has to name it for the set that works here to survive a reboot.
--- @return boolean loaded
local function load_with_dependencies(mod, visiting)
    if mod.status == "loaded" then return true end
    if not mod.main_file then return false end -- no readable manifest: its error already says why
    if visiting[mod.id] then
        fail(mod, "dependency cycle")
        return false
    end
    visiting[mod.id] = true
    for _, dep in ipairs(mod.dependencies or {}) do
        local id = dependency_id(dep)
        if id and id:lower() ~= "steamodded" then
            local other = ModLoader.by_id[id]
            if not other then
                visiting[mod.id] = nil
                fail(mod, "needs mod '" .. id .. "', which is not installed")
                return false
            elseif other.status ~= "loaded" then
                if not load_with_dependencies(other, visiting) then
                    visiting[mod.id] = nil
                    fail(mod, "needs mod '" .. id .. "', which failed to load")
                    return false
                end
                if not ModLoader.enabled[id] then
                    select(id, true)
                    selection_grew = true
                end
            end
        end
    end
    visiting[mod.id] = nil
    run_mod(mod)
    return mod.status == "loaded"
end

--- Load one scanned mod into the running session, on demand: the same environment,
--- rollback and error capture as the boot pass (`run_mod`), then the post-load refresh
--- the boot sequence performs, and the log is rewritten so the file shows the new state.
--- A mod whose content is still registered from earlier in the session (it was turned
--- off, which never unloads) is simply marked loaded again -- running it twice would
--- register everything twice.
--- @param target table|string the mod, or its id
--- @return boolean ok
--- @return string|nil problem when not ok
function ModLoader.load_mod(target)
    local mod = type(target) == "table" and target or ModLoader.by_id[target]
    if type(mod) ~= "table" then return false, "no such mod" end
    mod.timings = mod.timings or new_timings()
    if mod.status == "loaded" then return true end
    if ModLoader.disabled[mod.id] then
        return false, "mod '" .. mod.id .. "' is not turned on"
    end
    if ModLoader.by_id[mod.id] ~= mod then
        return false, mod.error or ("another mod already uses the id '" .. mod.id .. "'")
    end
    if not ModLoader.can_toggle(mod) then
        return false, mod.error or "no manifest"
    end
    if mod._live then
        mod.status, mod.error = "loaded", nil
        mod.timings.refresh = ModLoader.refresh_after_load()
        ModLoader.write_log()
        return true
    end
    selection_grew = false
    local ok = load_with_dependencies(mod, {})
    if selection_grew then write_enabled() end
    if ok then mod.timings.refresh = ModLoader.refresh_after_load() end
    ModLoader.write_log()
    return ok, ok and nil or mod.error
end

--- After a mod loads, give the mods that failed only because it was missing their chance:
--- a dependant whose error names an absent or failed dependency is retried, in scan
--- order, and keeps its (refreshed) error if it still cannot load. This is what the old
--- reload-everything switch did for free; a single-mod load has to ask for it.
local function retry_dependants()
    for _, other in ipairs(ModLoader.mods) do
        if other.status == "error" and not ModLoader.disabled[other.id]
            and ModLoader.by_id[other.id] == other then
            ModLoader.load_mod(other)
        end
    end
end

--- Turn a mod on or off and save the choice: the selection in `ENABLED_PATH` is the
--- whole of it, for this session and every boot after.
---
--- ON adds the mod to the selection and loads it into the session at once (`load_mod`:
--- the mod, after anything it depends on -- a dependency outside the selection is
--- loaded on the way and joins the selection too), as long as no run is in memory
--- (`hot_load_allowed`); inside a run the choice is queued instead -- the mod's status
--- becomes "pending" and it loads at the next boot. A mod whose content never left the
--- session (turned off earlier, see below) is marked loaded again without being re-run.
---
--- OFF only records the choice. A loaded mod is never unloaded mid-session -- its cards
--- may sit in a collection, a save's history, anywhere -- so its status becomes
--- "disabled" (which is what the saved-run check and the log read) while its content
--- stays registered and working until the next boot, from which it no longer loads.
--- @return boolean ok (the choice was saved)
function ModLoader.set_enabled(id, enabled)
    if type(id) ~= "string" then return false end
    select(id, enabled)
    local saved = write_enabled()
    local mod = ModLoader.by_id[id]
    if mod then
        if enabled then
            if mod.status ~= "loaded" then
                if ModLoader.hot_load_allowed() then
                    if ModLoader.load_mod(mod) then retry_dependants() end
                elseif mod._live then
                    -- Already in the session; only the recorded choice was holding it back.
                    mod.status, mod.error = "loaded", nil
                elseif mod.status == "disabled" then
                    -- Queued for the next boot: no longer off, not loaded yet.
                    mod.status, mod.error = "pending", nil
                end
            end
        else
            mod.status, mod.error = "disabled", nil
        end
        ModLoader.write_log()
    end
    return saved
end

--- Undo every loaded mod and forget them. Used by the tests; the game loads once per boot.
function ModLoader.reset()
    for _, mod in ipairs(ModLoader.mods) do SMODS.rollback(mod) end
    ModLoader.mods = {}
    ModLoader.by_id = {}
    ModLoader.notes = {}
    ModLoader.refresh_ms = 0
    ModLoader.refresh_calls = 0
end

--- Discover and load every mod. Safe to call without a filesystem (does nothing).
function ModLoader.load_all()
    ModLoader.reset()
    local f = fs()
    if not (f and f.getDirectoryItems and f.load and f.read and f.getInfo) then return ModLoader.mods end
    if f.createDirectory then f.createDirectory(ModLoader.DIR) end
    SMODS.install_card_methods()
    ModLoader.enabled = read_enabled()

    -- Scan the card first, then the bundled root, and merge by manifest id: a card
    -- copy shadows the bundled mod of the same id (the shadowed copy is dropped
    -- before it can register or reserve a prefix, and the log says so). Two mods
    -- with the same id in the SAME root both survive the merge; the pass below
    -- flags the second, as it always has. Dot-folders are not mods: the loader's
    -- own cache dir lives under the card root and must not be scanned as one.
    local found, notes = {}, {}
    local function scan(root)
        for _, folder in ipairs(f.getDirectoryItems(root) or {}) do
            if folder:sub(1, 1) ~= "." and is_dir(root .. "/" .. folder) then
                local t0 = clock_ms()
                local mod = read_manifest(root, folder)
                mod.timings.manifest = clock_ms() - t0
                found[#found + 1] = mod
            end
        end
    end
    scan(ModLoader.DIR)
    scan(ModLoader.BUNDLED_DIR)
    local claimed, merged = {}, {}
    for _, mod in ipairs(found) do
        local prev = claimed[mod.id]
        if prev and prev.bundled ~= mod.bundled then
            notes[#notes + 1] = ("bundled %s %s (%s) is shadowed by the copy in %s -- not loaded")
                :format(mod.id, mod.version, (mod.bundled and mod or prev).folder, ModLoader.DIR)
            if mod.bundled then
                -- The card copy is already in; the bundled one is simply dropped.
            else
                claimed[mod.id] = mod
                for i, m in ipairs(merged) do if m == prev then merged[i] = mod break end end
            end
        else
            if not prev then claimed[mod.id] = mod end
            merged[#merged + 1] = mod
        end
    end
    found = merged
    ModLoader.notes = notes

    table.sort(found, function(a, b)
        local la, lb = a.id:lower(), b.id:lower()
        if la ~= lb then return la < lb end
        if a.folder ~= b.folder then return a.folder < b.folder end
        return (a.bundled and 1 or 0) < (b.bundled and 1 or 0)
    end)

    -- The selection is by id, so a mod is off exactly when its id is not in it. (A manifest
    -- that did not read has no trustworthy id to select by; it can never be turned on.)
    ModLoader.disabled = {}
    for _, mod in ipairs(found) do
        if ModLoader.can_toggle(mod) and not ModLoader.enabled[mod.id] then
            ModLoader.disabled[mod.id] = true
        end
    end

    local prefixes = {}
    for _, mod in ipairs(found) do
        ModLoader.mods[#ModLoader.mods + 1] = mod
        -- A mod that is not turned on never runs, so whatever was wrong with it does not apply. It
        -- keeps its id, so dependants and the saved-run check can say it is off, not missing,
        -- but not its prefix: that is only reserved by what actually registers under it.
        if ModLoader.can_toggle(mod) and ModLoader.disabled[mod.id] then
            mod.status, mod.error = "disabled", nil
            ModLoader.by_id[mod.id] = ModLoader.by_id[mod.id] or mod
        end
        if mod.status == "pending" then
            if ModLoader.by_id[mod.id] then
                fail(mod, "another mod already uses the id '" .. mod.id .. "'")
            elseif prefixes[mod.prefix] then
                fail(mod, "prefix '" .. mod.prefix .. "' is already used by " .. prefixes[mod.prefix])
            end
        end
        if mod.status == "pending" then
            ModLoader.by_id[mod.id] = mod
            prefixes[mod.prefix] = mod.id
        end
    end

    -- Dependencies may load after their dependants in id order, so resolve in passes until
    -- nothing more can load.
    local progressed = true
    while progressed do
        progressed = false
        for _, mod in ipairs(ModLoader.mods) do
            if mod.status == "pending" then
                local problem, waiting = check_dependencies(mod)
                if problem then
                    fail(mod, problem)
                    progressed = true
                elseif not waiting then
                    run_mod(mod)
                    progressed = true
                end
            end
        end
    end
    for _, mod in ipairs(ModLoader.mods) do
        if mod.status == "pending" then fail(mod, "dependency cycle") end
    end

    -- The collection caches its entries; mod Jokers have to be in them.
    ModLoader.refresh_after_load()
    ModLoader.write_log()
    return ModLoader.mods
end

--- @return table[] the mods that loaded
function ModLoader.loaded_mods()
    local out = {}
    for _, mod in ipairs(ModLoader.mods) do
        if mod.status == "loaded" then out[#out + 1] = mod end
    end
    return out
end

--- What a run save records: every loaded mod and its version, sorted by id.
--- @return table[] `{ { id, version }, ... }`
function ModLoader.fingerprint()
    local out = {}
    for _, mod in ipairs(ModLoader.loaded_mods()) do
        out[#out + 1] = { id = mod.id, version = mod.version }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Compare a save's mod list against what is loaded now. A run is tied to the mods it was
--- played with: anything missing, at another version, or newly added changes what the run
--- contains or what its pools can roll, so it cannot be continued until the set matches.
--- A save from before mods existed carries no list, which means "no mods".
--- @param saved table|nil the save's `mods`
--- @return table|nil `{ missing = {...}, changed = {...}, extra = {...} }`, nil when they match
function ModLoader.compare(saved)
    local want = {}
    for _, m in ipairs(type(saved) == "table" and saved or {}) do
        if type(m) == "table" and type(m.id) == "string" then want[m.id] = tostring(m.version or "") end
    end
    local have = {}
    for _, m in ipairs(ModLoader.fingerprint()) do have[m.id] = m.version end

    local diff = { missing = {}, changed = {}, extra = {} }
    for id, version in pairs(want) do
        if have[id] == nil then
            diff.missing[#diff.missing + 1] = { id = id, version = version }
        elseif have[id] ~= version then
            diff.changed[#diff.changed + 1] = { id = id, saved = version, installed = have[id] }
        end
    end
    for id, version in pairs(have) do
        if want[id] == nil then diff.extra[#diff.extra + 1] = { id = id, version = version } end
    end
    for _, list in pairs(diff) do table.sort(list, function(a, b) return a.id < b.id end) end
    if #diff.missing == 0 and #diff.changed == 0 and #diff.extra == 0 then return nil end
    return diff
end

--- Plain lines describing a mismatch, for the Mods screen.
function ModLoader.describe_mismatch(diff)
    local lines = {}
    if not diff then return lines end
    for _, m in ipairs(diff.missing) do
        local installed = ModLoader.by_id[m.id]
        if installed and installed.status == "disabled" then
            lines[#lines + 1] = I18N.text("mods.turn_on", { id = m.id }, ("Turn on %s"):format(m.id))
        else
            lines[#lines + 1] = I18N.text("mods.install", { id = m.id, version = m.version }, ("Install %s %s"):format(m.id, m.version))
        end
    end
    for _, m in ipairs(diff.changed) do
        lines[#lines + 1] = I18N.text("mods.changed", { id = m.id, saved = m.saved, installed = m.installed },
            ("%s: saved with %s, installed %s"):format(m.id, m.saved, m.installed))
    end
    for _, m in ipairs(diff.extra) do
        lines[#lines + 1] = I18N.text("mods.remove", { id = m.id, version = m.version },
            ("Turn off %s %s (not in this run)"):format(m.id, m.version))
    end
    return lines
end

local function log_lines()
    local lines = { "Balatro3DS mods -- " .. ModLoader.DIR, "" }
    if #ModLoader.mods == 0 then lines[#lines + 1] = "No mods installed." end
    for _, mod in ipairs(ModLoader.mods) do
        local tag = ({ loaded = "OK", disabled = "OFF", pending = "PENDING" })[mod.status] or "ERROR"
        lines[#lines + 1] = ("[%s] %s %s (%s%s)"):format(tag, mod.id, mod.version, mod.folder,
            mod.bundled and ", bundled" or "")
        if mod.status == "disabled" then
            lines[#lines + 1] = "    not in the enabled set (" .. ModLoader.ENABLED_PATH .. ")"
        elseif mod.status == "pending" then
            lines[#lines + 1] = "    turned on during a run; loads at the next boot"
        elseif mod.status == "loaded" then
            lines[#lines + 1] = ("    %d joker(s), %d consumable(s), %d voucher(s), %d deck skin(s), %d image(s)"):format(
                #mod.registered.jokers, #mod.registered.consumables, #mod.registered.vouchers,
                #mod.registered.deck_skins, #mod.registered.sprites)
        else
            lines[#lines + 1] = "    " .. tostring(mod.error)
        end
        local tm = mod.timings
        if tm and (tm.compile + tm.execute) > 0 then
            local line = ("    timings: manifest %.2f ms, lua %.2f ms (compile %.2f, execute %.2f, sprites %.2f of execute)"):format(
                tm.manifest, tm.compile + tm.execute, tm.compile, tm.execute, tm.sprites)
            if tm.cache then line = line .. ", luac " .. tm.cache end
            if tm.refresh then line = line .. (", refresh %.2f ms"):format(tm.refresh) end
            lines[#lines + 1] = line
        end
        for _, err in ipairs(mod.runtime_errors or {}) do
            lines[#lines + 1] = "    runtime: " .. tostring(err)
        end
    end
    for _, note in ipairs(ModLoader.notes or {}) do
        lines[#lines + 1] = note
    end
    -- Phase totals, so a slow boot reads straight off this file: which part of loading
    -- ate the time, summed over every pack scanned. Refresh is totalled apart from the
    -- per-mod phases: it runs once per load pass (and once per hot-load), not per mod.
    local tman, tcomp, texec, tspr, timed = 0, 0, 0, 0, false
    for _, mod in ipairs(ModLoader.mods) do
        local tm = mod.timings
        if tm then
            timed = true
            tman = tman + tm.manifest
            tcomp = tcomp + tm.compile
            texec = texec + tm.execute
            tspr = tspr + tm.sprites
        end
    end
    if timed then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("Load timings (ms): manifest %.2f, lua %.2f (compile %.2f, execute %.2f, sprites %.2f of execute), refresh %.2f over %d call(s)"):format(
            tman, tcomp + texec, tcomp, texec, tspr, ModLoader.refresh_ms or 0, ModLoader.refresh_calls or 0)
    end
    return lines
end

function ModLoader.write_log()
    local f = fs()
    if not (f and f.write) then return end
    pcall(f.write, ModLoader.LOG_PATH, table.concat(log_lines(), "\n") .. "\n")
end

--- Runtime errors reach the log as they happen, so the file is current when a modder reads it.
SMODS.on_runtime_error = function() ModLoader.write_log() end

return ModLoader
