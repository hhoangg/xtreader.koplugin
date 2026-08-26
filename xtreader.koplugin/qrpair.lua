--[[
The pairing screen: a QR code with the short code printed under it.

KOReader ships QRMessage, but it draws the code and nothing else. The server's
contract asks for both halves and gives the reason: the QR carries
`verificationUriComplete`, and `userCode` is shown as text underneath as a
fallback for when the screen is too dim to scan. Its alphabet is eight
consonants — no vowels, so a code can never spell a word, and none of the
characters that get misread off low-contrast e-ink.

Modelled directly on QRMessage's own structure (InputContainer, tap-anywhere to
close, CenterContainer over a white FrameContainer) with a VerticalGroup in
place of the bare image.

Dismissing this does NOT cancel pairing. E-ink keeps its last image after power
is lost, so a code on screen can outlive the session it belongs to; the server's
clock is the only authority on expiry, and the poll keeps running either way.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Input = Device.input
local Screen = Device.screen

local QRPair = InputContainer:extend({
    modal = true,
    url = nil,      -- encoded into the QR
    code = nil,     -- shown as text
    prompt = nil,   -- one line above the QR
    hint = nil,     -- one line under the code
    dismiss_callback = nil,
})

function QRPair:init()
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new({
                ges = "tap",
                range = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }),
            }),
        }
    end

    local padding = Size.padding.fullscreen
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local content_w = screen_w - 4 * padding
    -- Leave room for the text stack; the QR stays square either way.
    local qr_size = math.floor(math.min(content_w, screen_h * 0.55))

    local group = VerticalGroup:new({ align = "center" })

    if self.prompt then
        table.insert(group, TextBoxWidget:new({
            text = self.prompt,
            face = Font:getFace("infofont"),
            width = content_w,
            alignment = "center",
        }))
        table.insert(group, VerticalSpan:new({ width = Size.padding.large }))
    end

    table.insert(group, QRWidget:new({
        text = self.url,
        width = qr_size,
        height = qr_size,
    }))
    table.insert(group, VerticalSpan:new({ width = Size.padding.large }))

    if self.code then
        table.insert(group, TextWidget:new({
            text = self.code,
            face = Font:getFace("tfont", 42),
            bold = true,
        }))
    end

    if self.hint then
        table.insert(group, VerticalSpan:new({ width = Size.padding.large }))
        table.insert(group, TextBoxWidget:new({
            text = self.hint,
            face = Font:getFace("smallinfofont"),
            width = content_w,
            alignment = "center",
        }))
    end

    local frame = FrameContainer:new({
        background = Blitbuffer.COLOR_WHITE,
        padding = padding,
        group,
    })
    self[1] = CenterContainer:new({ dimen = Screen:getSize(), frame })
end

function QRPair:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function QRPair:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen
    end)
    if self.dismiss_callback then
        self.dismiss_callback()
        self.dismiss_callback = nil
    end
end

function QRPair:onTapClose()
    UIManager:close(self)
    return true
end
QRPair.onAnyKeyPressed = QRPair.onTapClose

return QRPair
