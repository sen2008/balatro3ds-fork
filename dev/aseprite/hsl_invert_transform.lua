-- hsl_invert_transform.lua
-- Aseprite script: applies an HSL invert/offset color transform to every
-- pixel, on every cel, across all frames and layers of the active sprite.
--
-- Transform (matches the shader logic described):
--   1. RGB -> HSL
--      L' = 1 - L                (invert brightness)
--      H' = -H + 0.2 (wrapped)   (invert hue, offset by 0.2 on the wheel)
--   2. HSL -> RGB, then add a fixed tint: (79/255, 99/255, 103/255)
--   3. If alpha < 0.7 (i.e. < 178/255), alpha = alpha / 3
--      (color channels are untouched by this step)
--
-- Install: put this file in Aseprite's Scripts folder
--   (File > Scripts > Open Scripts Folder), then
--   File > Scripts > hsl_invert_transform, or just File > Scripts > Rescan
--   Scripts Folder first if it doesn't show up yet.
--
-- Run: File > Scripts > hsl_invert_transform
-- The whole thing is wrapped in one undo-able transaction (Ctrl+Z reverts it).
--
-- Command line (Aseprite's batch mode, no window):
--   aseprite -b plus_four.png --script dev/aseprite/hsl_invert_transform.lua --save-as plus_four_negative.png
--
-- No Aseprite? dev/make_negative.py applies the same transform with just Python.

-- In batch mode there is no window to show an alert in, so report on the console instead.
local function notify(msg)
  if app.isUIAvailable then app.alert(msg) else print(msg) end
end

local spr = app.activeSprite
if not spr then
  notify("No active sprite.")
  return
end

if spr.colorMode ~= ColorMode.RGB then
  notify("Please convert the sprite to RGB color mode first (Sprite > Color Mode > RGB Color).")
  return
end

----------------------------------------------------------------------
-- Color helpers
----------------------------------------------------------------------

-- r,g,b in 0..255 -> h,s,l in 0..1
local function rgbToHsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local h, s
  local l = (maxc + minc) / 2

  if maxc == minc then
    h, s = 0, 0
  else
    local d = maxc - minc
    s = (l > 0.5) and (d / (2 - maxc - minc)) or (d / (maxc + minc))
    if maxc == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif maxc == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end

  return h, s, l
end

local function hue2rgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

-- h,s,l in 0..1 -> r,g,b in 0..255
local function hslToRgb(h, s, l)
  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
    local p = 2 * l - q
    r = hue2rgb(p, q, h + 1 / 3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1 / 3)
  end
  return r * 255, g * 255, b * 255
end

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- Fixed tint added after HSL->RGB reconstruction
local TINT_R = 79 / 255
local TINT_G = 99 / 255
local TINT_B = 103 / 255

local function transformPixel(r, g, b, a)
  local h, s, l = rgbToHsl(r, g, b)

  -- Invert brightness
  l = 1 - l

  -- Invert + offset hue, wrap into [0,1)
  h = -h + 0.2
  h = h - math.floor(h)

  local nr, ng, nb = hslToRgb(h, s, l)

  -- Back to 0..1, add tint, clamp, back to 0..255
  nr = clamp01(nr / 255 + TINT_R) * 255
  ng = clamp01(ng / 255 + TINT_G) * 255
  nb = clamp01(nb / 255 + TINT_B) * 255

  -- Alpha: only reduced further if already below 0.7 (178.5/255)
  local na = a
  if (a / 255) < 0.7 then
    na = a / 3
  end

  return math.floor(nr + 0.5),
         math.floor(ng + 0.5),
         math.floor(nb + 0.5),
         math.floor(na + 0.5)
end

----------------------------------------------------------------------
-- Apply across every layer / frame / cel
----------------------------------------------------------------------

local function processLayer(lyr, frame)
  if lyr.isGroup then
    for _, child in ipairs(lyr.layers) do
      processLayer(child, frame)
    end
    return
  end

  local cel = lyr:cel(frame)
  if cel and cel.image then
    local img = cel.image
    for it in img:pixels() do
      local px = it()
      local a = app.pixelColor.rgbaA(px)
      if a > 0 then
        local r = app.pixelColor.rgbaR(px)
        local g = app.pixelColor.rgbaG(px)
        local b = app.pixelColor.rgbaB(px)
        local nr, ng, nb, na = transformPixel(r, g, b, a)
        it(app.pixelColor.rgba(nr, ng, nb, na))
      end
    end
  end
end

app.transaction(function()
  for _, frame in ipairs(spr.frames) do
    for _, layer in ipairs(spr.layers) do
      processLayer(layer, frame)
    end
  end
end)

if app.isUIAvailable then app.refresh() end
notify("HSL invert/offset transform applied to all frames.")
