--[[--
Settings menu of the Word Wise feature (Settings -> Word Wise).

The menu works with or without a running controller: inside a book the
controller (assistant.wordwise) applies changes immediately; in the file
manager only the stored settings are changed and the next book picks them up.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local _ = require("core/gettext")
local Core = require("utils/wordwise_core")
local WordWise = require("feature/wordwise")

local T = ffiutil.template

local M = {}

local function cfg(assistant, key)
  local v = assistant.settings:readSetting("wordwise_" .. key)
  if v == nil then return WordWise.DEFAULTS[key] end
  return v
end

local function setCfg(assistant, key, value)
  assistant.settings:saveSetting("wordwise_" .. key, value)
  assistant.updated = true
end

--- Setting that changes WHAT is requested (level, language, density, ...):
--- cached hints of other variants stay on disk, new ones are fetched.
local function requestSettingChanged(assistant)
  local ww = assistant.wordwise
  if ww then ww:onRequestSettingsChanged() end
end

--- Setting that only changes how hints LOOK.
local function appearanceChanged(assistant)
  local ww = assistant.wordwise
  if ww then ww:onAppearanceChanged() end
end

local function info(text)
  UIManager:show(InfoMessage:new { text = text })
end

local function levelLabel(level)
  local labels = {
    A1 = _("A1 - beginner"),
    A2 = _("A2 - elementary"),
    B1 = _("B1 - intermediate"),
    B2 = _("B2 - upper-intermediate"),
    C1 = _("C1 - advanced"),
    C2 = _("C2 - near-native"),
  }
  return labels[level] or level
end

local function densityLabel(density)
  local labels = {
    low = _("Low"),
    medium = _("Medium"),
    high = _("High"),
  }
  return labels[density] or density
end

local function spinItem(assistant, o)
  return {
    text_func = function()
      return T(o.label, cfg(assistant, o.key) .. (o.suffix or ""))
    end,
    callback = function(touchmenu_instance)
      UIManager:show(SpinWidget:new {
        title_text = o.title,
        value = cfg(assistant, o.key),
        value_min = o.min,
        value_max = o.max,
        value_step = o.step or 1,
        default_value = WordWise.DEFAULTS[o.key],
        callback = function(spin)
          setCfg(assistant, o.key, spin.value)
          o.apply(assistant)
        end,
        close_callback = function()
          if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
      })
    end,
    keep_menu_open = true,
    enabled_func = o.enabled_func,
    hold_callback = o.help and function() info(o.help) end or nil,
  }
end

local function genLevelItems(assistant)
  local items = {}
  for _i, level in ipairs(Core.LEVELS) do
    items[#items + 1] = {
      text = levelLabel(level),
      radio = true,
      checked_func = function() return cfg(assistant, "level") == level end,
      callback = function()
        setCfg(assistant, "level", level)
        requestSettingChanged(assistant)
      end,
    }
  end
  return items
end

local function genDensityItems(assistant)
  local items = {}
  for _i, density in ipairs(Core.DENSITIES) do
    items[#items + 1] = {
      text = densityLabel(density),
      radio = true,
      checked_func = function() return cfg(assistant, "density") == density end,
      callback = function()
        setCfg(assistant, "density", density)
        requestSettingChanged(assistant)
      end,
    }
  end
  return items
end

local function styleLabel(style)
  if style == "definition" then return _("Short explanation") end
  return _("Synonym")
end

local function genStyleItems(assistant)
  local items = {}
  for _i, style in ipairs(Core.STYLES) do
    items[#items + 1] = {
      text = styleLabel(style),
      radio = true,
      checked_func = function() return (cfg(assistant, "style") or "synonym") == style end,
      callback = function()
        setCfg(assistant, "style", style)
        requestSettingChanged(assistant)
      end,
    }
  end
  return items
end

local function positionLabel(position)
  if position == "high" then return _("Higher") end
  if position == "middle" then return _("Middle") end
  return _("Close to the word")
end

local function genPositionItems(assistant)
  local items = {}
  for _i, position in ipairs(Core.POSITIONS) do
    items[#items + 1] = {
      text = positionLabel(position),
      radio = true,
      checked_func = function() return (cfg(assistant, "position") or "close") == position end,
      callback = function()
        setCfg(assistant, "position", position)
        appearanceChanged(assistant)
      end,
    }
  end
  return items
end

local function genColorItems(assistant)
  return {
    {
      text = _("Gray"),
      radio = true,
      checked_func = function() return cfg(assistant, "color") ~= "black" end,
      callback = function()
        setCfg(assistant, "color", "gray")
        appearanceChanged(assistant)
      end,
    },
    {
      text = _("Black"),
      radio = true,
      checked_func = function() return cfg(assistant, "color") == "black" end,
      callback = function()
        setCfg(assistant, "color", "black")
        appearanceChanged(assistant)
      end,
    },
  }
end

local function providerLabel(assistant, id, setting)
  local q = assistant.querier
  if q and q.getProviderLabel then
    local ok, label = pcall(q.getProviderLabel, q, setting, id)
    if ok and type(label) == "string" and label ~= "" then return label end
  end
  return id
end

local function genProviderItems(assistant)
  local items = {
    {
      text = _("Same as the AI Assistant"),
      radio = true,
      checked_func = function() return (cfg(assistant, "provider") or "") == "" end,
      callback = function() setCfg(assistant, "provider", "") end,
      separator = true,
    },
  }
  local config = assistant.config
  local settings = config and config:getProviderSettings() or {}
  local ids = {}
  for id in pairs(settings) do
    if config:isProviderEnabled(id) then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _i, id in ipairs(ids) do
    items[#items + 1] = {
      text = providerLabel(assistant, id, settings[id]),
      radio = true,
      checked_func = function() return cfg(assistant, "provider") == id end,
      callback = function() setCfg(assistant, "provider", id) end,
    }
  end
  return items
end

local function showLanguageDialog(assistant, touchmenu_instance)
  local dialog
  dialog = InputDialog:new {
    title = _("Hint Language"),
    input = cfg(assistant, "lang"),
    input_hint = _("English"),
    description = _("Language the hints are written in. English gives synonyms and short definitions in the book's own language; any other language gives translations."),
    buttons = {
      {
        {
          text = _("Cancel"),
          id = "close",
          callback = function() UIManager:close(dialog) end,
        },
        {
          text = _("Use English"),
          callback = function()
            UIManager:close(dialog)
            setCfg(assistant, "lang", WordWise.DEFAULTS.lang)
            requestSettingChanged(assistant)
            if touchmenu_instance then touchmenu_instance:updateItems() end
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local text = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            UIManager:close(dialog)
            if text == "" then text = WordWise.DEFAULTS.lang end
            if text ~= cfg(assistant, "lang") then
              setCfg(assistant, "lang", text)
              requestSettingChanged(assistant)
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

--- The "Word Wise" entry of the Settings menu.
function M.gen(assistant)
  local function ww() return assistant.wordwise end
  local function inReader() return assistant.ui and assistant.ui.document ~= nil end

  local items = {
    {
      text = _("Show Hints While Reading"),
      checked_func = function() return cfg(assistant, "enabled") == true end,
      callback = function(touchmenu_instance)
        local on = cfg(assistant, "enabled") ~= true
        if on and inReader() and not (ww() and ww():isSupported()) then
          info(_("Word Wise works with reflowable books (EPUB, FB2, MOBI, HTML ...) and with PDF files that have a text layer. This document type is not supported."))
          return
        end
        if on and not assistant:isConfigured() then return end
        if ww() then
          ww():setEnabled(on)
        else
          setCfg(assistant, "enabled", on)
          if on then
            info(_("Word Wise is on. Open a reflowable book to see the hints."))
          end
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
      end,
      keep_menu_open = true,
      hold_callback = function()
        info(_([[Prints a short hint above difficult words, phrasal verbs and idioms while you read, like Kindle's Word Wise.

The AI reads each page, decides what is hard for your level and answers with short hints. Pages are fetched in the background and a few pages ahead, so the hints are normally ready when you turn the page. Hints are cached per book.

Works with reflowable books and PDF files that have a text layer. In a PDF the hints go into the gap above each line and are left out where it is too small. An internet connection and an AI provider are needed.]]))
      end,
      separator = true,
    },
    {
      text_func = function() return T(_("My Level: %1"), cfg(assistant, "level")) end,
      sub_item_table = genLevelItems(assistant),
      hold_callback = function()
        info(_("Your proficiency in the language of the book. The AI skips the words you should already know, so a lower level means more hints."))
      end,
    },
    {
      text_func = function() return T(_("Hint Language: %1"), cfg(assistant, "lang")) end,
      callback = function(touchmenu_instance) showLanguageDialog(assistant, touchmenu_instance) end,
      keep_menu_open = true,
      hold_callback = function()
        info(_("English (default) gives synonyms and short explanations in the language of the book. Enter another language to get translations instead."))
      end,
    },
    {
      text_func = function() return T(_("Hint Density: %1"), densityLabel(cfg(assistant, "density"))) end,
      sub_item_table = genDensityItems(assistant),
      hold_callback = function()
        info(_("How many hints at most the AI may add per page."))
      end,
    },
    {
      text_func = function() return T(_("Hint Style: %1"), styleLabel(cfg(assistant, "style") or "synonym")) end,
      sub_item_table = genStyleItems(assistant),
      hold_callback = function()
        info(_("Synonym: a very short word or paraphrase. Short explanation: a few words saying what it means here (raise Maximum Length in Hint Appearance if hints get cut off). Changing it fetches new hints."))
      end,
    },
    {
      text = _("Hint Every Occurrence on a Page"),
      checked_func = function() return cfg(assistant, "all") == true end,
      callback = function()
        setCfg(assistant, "all", not (cfg(assistant, "all") == true))
        requestSettingChanged(assistant)
      end,
      hold_callback = function()
        info(_("By default an expression is hinted only the first time it appears on a page. Turn this on to hint up to three occurrences."))
      end,
      separator = true,
    },
    {
      text = _("Hint Appearance"),
      sub_item_table = {
        spinItem(assistant, {
          key = "size", label = _("Text Size: %1"), suffix = "%",
          title = _("Hint text size (% of the book font)"),
          min = 30, max = 100, step = 5,
          apply = appearanceChanged,
        }),
        spinItem(assistant, {
          key = "max_chars", label = _("Maximum Length: %1"),
          title = _("Longest hint, in characters"),
          min = 8, max = 40,
          apply = requestSettingChanged,
          help = _("Hints are requested no longer than this. Changing it fetches new hints."),
        }),
        {
          text = _("Bold Text"),
          checked_func = function() return cfg(assistant, "bold") ~= false end,
          callback = function()
            setCfg(assistant, "bold", not (cfg(assistant, "bold") ~= false))
            appearanceChanged(assistant)
          end,
        },
        {
          text_func = function()
            return T(_("Position: %1"), positionLabel(cfg(assistant, "position") or "close"))
          end,
          sub_item_table = genPositionItems(assistant),
        },
        spinItem(assistant, {
          key = "offset", label = _("Vertical Offset: %1"),
          title = _("Move hints down (+) or up (-), in pixels"),
          min = -20, max = 20,
          apply = appearanceChanged,
        }),
        spinItem(assistant, {
          key = "pdf_squeeze", label = _("PDF: Squeeze Hints Closer: %1"), suffix = "%",
          title = _("How far a hint may dip into the line above (% of a line)"),
          min = 0, max = 80, step = 5,
          apply = appearanceChanged,
          help = _("In a PDF the lines are set tightly, but there is usually free space between the letters of one line and the capitals of the next; only descenders (g, p, y) reach down into it. A higher value lets hints use more of that space, so more hints fit, but they may touch the letters above. 0 keeps hints strictly inside the measured gap."),
        }),
        spinItem(assistant, {
          key = "pdf_min_size", label = _("PDF: Smallest Hint Size: %1"),
          title = _("Smallest hint text in a PDF (pixels)"),
          min = 5, max = 16,
          apply = appearanceChanged,
          help = _("A PDF has a fixed layout, so a hint has to fit into the gap above its line. The text is made smaller until it fits; a hint that would have to be smaller than this is left out. Lower values show more hints but they get harder to read."),
        }),
        {
          text_func = function()
            return T(_("Color: %1"), cfg(assistant, "color") == "black" and _("Black") or _("Gray"))
          end,
          sub_item_table = genColorItems(assistant),
        },
      },
    },
    spinItem(assistant, {
      key = "prefetch", label = _("Pre-fetch Pages: %1"),
      title = _("Pages to prepare ahead of the one you read"),
      min = 0, max = 6,
      apply = function(a)
        local w = a.wordwise
        if w and w:isEnabled() then w:schedulePlan(0.3) end
      end,
      help = _("More pages ahead means hints are ready sooner after a quick page turn, at the cost of more API requests."),
    }),
    {
      text_func = function()
        local id = cfg(assistant, "provider") or ""
        local label = _("Same as the AI Assistant")
        if id ~= "" then
          label = providerLabel(assistant, id, assistant.config and assistant.config:getProvider(id))
        end
        return T(_("Provider: %1"), label)
      end,
      sub_item_table_func = function() return genProviderItems(assistant) end,
      hold_callback = function()
        info(_("Use a different (for example cheaper and faster) provider for Word Wise than for the rest of the AI Assistant."))
      end,
      separator = true,
    },
    {
      text = _("Change Line Spacing Automatically"),
      checked_func = function() return cfg(assistant, "auto_spacing") ~= false end,
      callback = function()
        setCfg(assistant, "auto_spacing", not (cfg(assistant, "auto_spacing") ~= false))
        local w = ww()
        if w then w:onSpacingSettingChanged() end
      end,
      hold_callback = function()
        info(_("Hints are printed in the gap above each line. When this is on, the line spacing of the book is raised (the font itself is never changed) and restored when Word Wise is turned off. Turn it off to keep your own spacing and set it yourself in the Typeset menu; with tight spacing hints may overlap the line above."))
      end,
    },
    spinItem(assistant, {
      key = "spacing", label = _("Line Spacing for Hints: %1"), suffix = "%",
      title = _("Line spacing that leaves room for hints (%)"),
      min = 100, max = 200, step = 10,
      enabled_func = function() return cfg(assistant, "auto_spacing") ~= false end,
      apply = function(a)
        local w = a.wordwise
        if w then w:onSpacingSettingChanged() end
      end,
    }),
    {
      text = _("Make Room for Hints (Line Spacing)"),
      enabled_func = function() return ww() ~= nil and ww():isReflowable() and true or false end,
      callback = function()
        local w = ww()
        if not w then return end
        if not w:raiseLineSpacing() then
          info(_("The line spacing of this book already leaves enough room for the hints."))
        end
      end,
      hold_callback = function()
        info(_("Hints are printed in the gap above each line. This raises the line spacing of the open book if it is too tight. It is done automatically the first time hints are shown in a book."))
      end,
    },
    {
      text_func = function()
        local w = ww()
        return T(_("Clear Cached Hints (%1)"), w and w:cachedCount() or 0)
      end,
      enabled_func = function() return ww() ~= nil and ww():isSupported() end,
      callback = function(touchmenu_instance)
        UIManager:show(ConfirmBox:new {
          text = _("Delete all cached hints of this book? They will be fetched again as you read."),
          ok_text = _("Clear"),
          ok_callback = function()
            if ww() then ww():clearCache() end
            if touchmenu_instance then touchmenu_instance:updateItems() end
          end,
        })
      end,
      keep_menu_open = true,
    },
  }

  return {
    text = _("Word Wise"),
    sub_item_table = items,
  }
end

return M
