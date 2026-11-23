--[[--
Quick translation overlay for the Translate-as-Annotation flow: the
auto-saved translation is shown in a small floating panel anchored above
the selection (below it when there is no room above, centered when there
is no room on either side), instead of the near-fullscreen result window.

Tap anywhere (or Back) dismisses it; it closes itself after `timeout`
seconds. The note already carries the full text, so the panel simply
shows what was saved.
]]
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local GestureRange = require("ui/gesturerange")
local _ = require("core/gettext")

local Screen = Device.screen

local M = {}

local QuickTranslate = InputContainer:extend{
    text = nil,        -- the translation, as saved into the note
    boxes = nil,       -- selection screen rects (list of Geom); nil/empty centers the panel
    assistant = nil,   -- for the response_direction setting
    timeout = 6,       -- seconds before the panel closes itself
    modal = true,
}

--- Region and align for the panel: above the selection when the frame
--- fits, below it otherwise, centered when neither side has room.
--- Pure numbers, so the geometry stays testable without a Screen.
---@param boxes table[] screen rects ({y, h, ...}) of the selection
---@param frame_h number panel height in pixels
---@param screen_w number
---@param screen_h number
---@param pad number pixels kept between the selection and the panel
---@return table {x, y, w, h, align} align is "bottom" (above the
---        selection), "top" (below it) or "center"
function M.anchor_region(boxes, frame_h, screen_w, screen_h, pad)
    if not (boxes and #boxes > 0) then
        return { x = 0, y = 0, w = screen_w, h = screen_h, align = "center" }
    end
    local top, bottom = math.huge, -math.huge
    for i = 1, #boxes do
        local box = boxes[i]
        if box.y < top then top = box.y end
        local box_bottom = box.y + box.h
        if box_bottom > bottom then bottom = box_bottom end
    end
    top = top - pad
    bottom = bottom + pad
    if top >= frame_h then
        return { x = 0, y = 0, w = screen_w, h = top, align = "bottom" }
    end
    if screen_h - bottom >= frame_h then
        return { x = 0, y = bottom, w = screen_w, h = screen_h - bottom, align = "top" }
    end
    return { x = 0, y = 0, w = screen_w, h = screen_h, align = "center" }
end

function QuickTranslate:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    local header_face = Font:getFace("x_smallinfofont")
    local body_face = Font:getFace("cfont", 20)

    local frame_padding = Size.padding.default
    local content_width = math.min(
        screen_w - 2 * Size.margin.default - 2 * Size.border.window,
        math.floor(screen_w * 0.8))

    -- Body: the saved note text. Translations are short by prompt contract;
    -- a rambling answer is clipped, the note keeps the full text.
    local alignment = self.assistant
        and self.assistant.settings:readSetting("response_direction") == "rtl"
        and "right" or "left"
    local body = TextBoxWidget:new{
        text = self.text,
        face = body_face,
        width = content_width,
        alignment = alignment,
    }
    local max_body_h = math.floor(screen_h * 0.35)
    if body:getSize().h > max_body_h then
        body:free(true)
        body = TextBoxWidget:new{
            text = self.text,
            face = body_face,
            width = content_width,
            height = max_body_h,
            alignment = alignment,
        }
    end

    local header = TextBoxWidget:new{
        text = _("Saved as Annotation"),
        face = header_face,
        width = content_width,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = frame_padding,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Size.padding.small },
            body,
        },
    }
    self.movable = MovableContainer:new{ self.frame }

    local region = M.anchor_region(self.boxes, self.frame:getSize().h,
        screen_w, screen_h, Size.padding.small)
    -- WidgetContainer honors align + dimen, the same positioning primitive
    -- DictQuickLookup uses; the region offsets ride inside dimen.
    self[1] = WidgetContainer:new{
        align = region.align,
        dimen = Geom:new{ x = region.x, y = region.y, w = region.w, h = region.h },
        self.movable,
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
            },
        }
    end
end

function QuickTranslate:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
    if self.timeout then
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(self.timeout, self._timeout_func)
    end
    return true
end

function QuickTranslate:onCloseWidget()
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    UIManager:setDirty(nil, function()
        return "ui", self.movable.dimen
    end)
end

function QuickTranslate:onTapClose()
    UIManager:close(self)
    return true
end

function QuickTranslate:onClose()
    UIManager:close(self)
    return true
end

M.QuickTranslate = QuickTranslate
return M
