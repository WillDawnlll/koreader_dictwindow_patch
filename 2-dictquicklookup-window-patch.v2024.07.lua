-- koreader version 2024.07 2023.08 tested
-- tldr : DictQuickLookup width=width/2 definition_height=definition_height/2
    -- search "-- HOOK" to find modified lines
-- hook init function copy from DictQuickLookup.init() [koreader/frontend/ui/widget/dictquicklookup.lua]  
    -- 2c9bb33 https://github.com/koreader/koreader/blob/master/frontend/ui/widget/dictquicklookup.lua
-- https://github.com/koreader/koreader/wiki/User-patches

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Math = require("optmath")
local MovableContainer = require("ui/widget/container/movablecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local Translator = require("ui/translator")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local Input = Device.input
local Screen = Device.screen
local T = require("ffi/util").template
local time = require("ui/time")


local DictQuickLookup = require("ui/widget/dictquicklookup")
local i = DictQuickLookup.init

DictQuickLookup.init=function (self)
--    print("enter init")
--    print("call org init")
--    i(self)
--    print("called org init, change w h")
--    self.width = self.width /4
--    self.height = self.height /4
--    print("end init, w h changed")
--end

    self.dict_font_size = G_reader_settings:readSetting("dict_font_size") or 20
    self.content_face = Font:getFace("cfont", self.dict_font_size)
    local font_size_alt = self.dict_font_size - 4
    if font_size_alt < 8 then
        font_size_alt = 8
    end
    self.image_alt_face = Font:getFace("cfont", font_size_alt)
    if Device:hasKeys() then
        self.key_events.ReadPrevResult = { { Input.group.PgBack } }
        self.key_events.ReadNextResult = { { Input.group.PgFwd } }
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.ShowResultsMenu = { { "Menu" } }
        if Device:hasKeyboard() then
            self.key_events.ChangeToPrevDict = { { "Shift", "Left" } }
            self.key_events.ChangeToNextDict = { { "Shift", "Right" } }
        elseif Device:hasScreenKB() then
            self.key_events.ChangeToPrevDict = { { "ScreenKB", "Left" } }
            self.key_events.ChangeToNextDict = { { "ScreenKB", "Right" } }
        end
    end
    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                },
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                },
            },
            -- This was for selection of a single word with simple hold
            -- HoldWord = {
            --     GestureRange:new{
            --         ges = "hold",
            --         range = function()
            --             return self.region
            --         end,
            --     },
            --     -- callback function when HoldWord is handled as args
            --     args = function(word)
            --         self.ui:handleEvent(
            --             -- don't pass self.highlight to subsequent lookup, we want
            --             -- the first to be the only one to unhighlight selection
            --             -- when closed
            --             Event:new("LookupWord", word, true, {self.word_box}))
            --     end
            -- },
            -- Allow selection of one or more words (see textboxwidget.lua) :
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = range,
                },
                -- callback function when HoldReleaseText is handled as args
                args = function(text, hold_duration)
                    -- do this lookup in the same domain (dict/wikipedia)
                    local lookup_wikipedia = self.is_wiki
                    if hold_duration >= time.s(3) then
                        -- but allow switching domain with a long hold
                        lookup_wikipedia = not lookup_wikipedia
                    end
                    -- We don't pass self.highlight to subsequent lookup, we want the
                    -- first to be the only one to unhighlight selection when closed
                    if lookup_wikipedia then
                        self:lookupWikipedia(false, text)
                    else
                        self.ui:handleEvent(Event:new("LookupWord", text))
                    end
                end
            },
            -- These will be forwarded to MovableContainer after some checks
            ForwardingTouch = { GestureRange:new{ ges = "touch", range = range, }, },
            ForwardingPan = { GestureRange:new{ ges = "pan", range = range, }, },
            ForwardingPanRelease = { GestureRange:new{ ges = "pan_release", range = range, }, },
        }
    end

    -- We no longer support setting a default dict with Tap on title.
    -- self:changeToDefaultDict()
    -- Now, dictionaries can be ordered (although not yet per-book), so trust the order set
    self:changeDictionary(1, true) -- don't call update

    -- And here comes the initial widget layout...
    if self.is_wiki then
        -- Get a copy of ReaderWikipedia.wiki_languages, with the current result
        -- lang first (rotated, or added)
        self.wiki_languages, self.update_wiki_languages_on_close = self.ui.wikipedia:getWikiLanguages(self.lang)
    end

    -- Bigger window if fullpage Wikipedia article being shown,
    -- or when large windows for dict requested
    local is_large_window = self.is_wiki_fullpage or G_reader_settings:isTrue("dict_largewindow")
    if is_large_window then
        self.width = Screen:getWidth() - 2*Size.margin.default
    else
        -- HOOK
        --self.width = Screen:getWidth() - Screen:scaleBySize(80)
        print("w/2")
        self.width = (Screen:getWidth() - Screen:scaleBySize(80))/2
    end
    local frame_bordersize = Size.border.window
    local inner_width = self.width - 2*frame_bordersize
    -- Height will be computed below, after we build top an bottom
    -- components, when we know how much height they are taking.

    -- Dictionary title
    self.dict_title = TitleBar:new{
        width = inner_width,
        title = self.displaydictname,
        with_bottom_line = true,
        bottom_v_padding = 0, -- padding handled below
        close_callback = function() self:onClose() end,
        close_hold_callback = function() self:onHoldClose() end,
        -- visual hint: title left aligned for dict, centered for Wikipedia
        align = self.is_wiki and "center" or "left",
        show_parent = self,
        lang = self.lang_out,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            if self.is_wiki then
                self:showWikiResultsMenu()
            else
                self:onShowResultsMenu()
            end
        end,
        left_icon_hold_callback = not self.is_wiki and function() self:showResultsAltMenu() end or nil,
    }
    -- Scrollable offsets of the various showResults* menus and submenus,
    -- so we can reopen them in the same state they were when closed.
    self.menu_scrolled_offsets = {}
    -- We'll also need to close any opened such menu when closing this DictQuickLookup
    -- (needed if closing all DictQuickLookups via long-press on Close on the top one)
    self.menu_opened = {}

    -- This padding and the resulting width apply to the content
    -- below the title:  lookup word and definition
    local content_padding_h = Size.padding.large
    local content_padding_v = Size.padding.large -- added via VerticalSpan
    self.content_width = inner_width - 2*content_padding_h

    -- Spans between components
    local top_to_word_span = VerticalSpan:new{ width = content_padding_v }
    local word_to_definition_span = VerticalSpan:new{ width = content_padding_v }
    local definition_to_bottom_span = VerticalSpan:new{ width = content_padding_v }

    -- Lookup word
    local word_font_face = "tfont"
    -- Ensure this word doesn't get smaller than its definition
    local word_font_size = math.max(22, self.dict_font_size)
    -- Get the line height of the normal font size, as a base for sizing this component
    if not self.word_line_height then
        local test_widget = TextWidget:new{
            text = "z",
            face = Font:getFace(word_font_face, word_font_size),
        }
        self.word_line_height = test_widget:getSize().h
        test_widget:free()
    end
    if self.is_wiki then
        -- Wikipedia has longer titles, so use a smaller font,
        word_font_size = math.max(18, self.dict_font_size)
    end
    local icon_size = Screen:scaleBySize(32)
    local lookup_height = math.max(self.word_line_height, icon_size)
    -- Edit button
    local lookup_edit_button = IconButton:new{
        icon = "edit",
        width = icon_size,
        height = icon_size,
        padding = 0,
        padding_left = Size.padding.small,
        callback = function()
            -- allow adjusting the queried word
            self:lookupInputWord(self.word)
        end,
        hold_callback = function()
            -- allow adjusting the current result word
            self:lookupInputWord(self.lookupword)
        end,
        overlap_align = "right",
        show_parent = self,
    }
    local lookup_edit_button_w = lookup_edit_button:getSize().w
    -- Nb of results (if set)
    local lookup_word_nb
    local lookup_word_nb_w = 0
    if self.displaynb then
        self.displaynb_text = TextWidget:new{
            text = self.displaynb,
            face = Font:getFace("cfont", word_font_size),
            padding = 0, -- smaller height for better aligmnent with icon
        }

        lookup_word_nb = FrameContainer:new{
            margin = 0,
            bordersize = 0,
            padding = 0,
            padding_left = Size.padding.small,
            padding_right = lookup_edit_button_w + Size.padding.default,
            overlap_align = "right",
            self.displaynb_text,
        }
        lookup_word_nb_w = lookup_word_nb:getSize().w
    end
    -- Lookup word
    self.lookup_word_text = TextWidget:new{
        text = self.displayword,
        face = Font:getFace(word_font_face, word_font_size),
        bold = true,
        max_width = self.content_width - math.max(lookup_edit_button_w, lookup_word_nb_w),
        padding = 0, -- to be aligned with lookup_word_nb
        lang = self.lang_in
    }
    -- Group these 3 widgets
    local lookup_word = OverlapGroup:new{
        dimen = {
            w = self.content_width,
            h = lookup_height,
        },
        self.lookup_word_text,
        lookup_edit_button,
        lookup_word_nb, -- last, as this might be nil
    }

    -- Different sets of buttons whether fullpage or not
    local buttons
    if self.is_wiki_fullpage then
        -- A save and a close button
        buttons = {
            {
                {
                    id = "save",
                    text = _("Save as EPUB"),
                    callback = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local ConfirmBox = require("ui/widget/confirmbox")
                        -- if forced_lang was specified, it may not be in our wiki_languages,
                        -- but ReaderWikipedia will have put it in result.lang
                        local lang = self.lang or self.wiki_languages[1]
                        -- Find a directory to save file into
                        local dir
                        if G_reader_settings:isTrue("wikipedia_save_in_book_dir") and not self:isDocless() then
                            local last_file = G_reader_settings:readSetting("lastfile")
                            dir = last_file and last_file:match("(.*)/")
                        end
                        dir = dir or G_reader_settings:readSetting("wikipedia_save_dir") or DictQuickLookup.getWikiSaveEpubDefaultDir()
                        if not util.pathExists(dir) then
                            lfs.mkdir(dir)
                        end
                        -- Just to be safe (none of the invalid chars, except ':' for uninteresting
                        -- Portal: or File: wikipedia pages, should be in lookupword)
                        local filename = self.lookupword .. "."..string.upper(lang)..".epub"
                        filename = util.getSafeFilename(filename, dir):gsub("_", " ")
                        local epub_path = dir .. "/" .. filename
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Save as %1?"), BD.filename(filename)),
                            ok_callback = function()
                                UIManager:scheduleIn(0.1, function()
                                    local Wikipedia = require("ui/wikipedia")
                                    Wikipedia:createEpubWithUI(epub_path, self.lookupword, lang, function(success)
                                        if success then
                                            UIManager:show(ConfirmBox:new{
                                                text = T(_("Article saved to:\n%1\n\nWould you like to read the downloaded article now?"), BD.filepath(epub_path)),
                                                ok_callback = function()
                                                    -- close all dict/wiki windows, without scheduleIn(highlight.clear())
                                                    self:onHoldClose(true)
                                                    -- close current ReaderUI in 1 sec, and create a new one
                                                    UIManager:scheduleIn(1.0, function()
                                                        UIManager:broadcastEvent(Event:new("SetupShowReader"))

                                                        if self.ui then
                                                            -- close Highlight menu if any still shown
                                                            if self.ui.highlight and self.ui.highlight.highlight_dialog then
                                                                self.ui.highlight:onClose()
                                                            end
                                                            self.ui:onClose()
                                                        end

                                                        local ReaderUI = require("apps/reader/readerui")
                                                        ReaderUI:showReader(epub_path)
                                                    end)
                                                end,
                                            })
                                        else
                                            UIManager:show(InfoMessage:new{
                                                text = _("Saving Wikipedia article failed or interrupted."),
                                            })
                                        end
                                    end)
                                end)
                            end
                        })
                    end,
                },
                {
                    id = "close",
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                    hold_callback = function()
                        self:onHoldClose()
                    end,
                },
            },
        }
    else
        local prev_dict_text = "◁◁"
        local next_dict_text = "▷▷"
        if BD.mirroredUILayout() then
            prev_dict_text, next_dict_text = next_dict_text, prev_dict_text
        end
        buttons = {
            {
                {
                    id = "prev_dict",
                    text = prev_dict_text,
                    vsync = true,
                    enabled = self:isPrevDictAvaiable(),
                    callback = function()
                        self:onChangeToPrevDict()
                    end,
                    hold_callback = function()
                        self:changeToFirstDict()
                    end,
                },
                {
                    id = "highlight",
                    text = _("Highlight"),
                    enabled = not self:isDocless() and self.highlight ~= nil,
                    callback = function()
                        self.save_highlight = not self.save_highlight
                        -- Just update, repaint and refresh *this* button
                        local this = self.button_table:getButtonById("highlight")
                        this:setText(self.save_highlight and _("Unhighlight") or _("Highlight"), this.width)
                        this:refresh()
                    end,
                },
                {
                    id = "next_dict",
                    text = next_dict_text,
                    vsync = true,
                    enabled = self:isNextDictAvaiable(),
                    callback = function()
                        self:onChangeToNextDict()
                    end,
                    hold_callback = function()
                        self:changeToLastDict()
                    end,
                },
            },
            {
                {
                    id = "wikipedia",
                    -- if dictionary result, do the same search on wikipedia
                    -- if already wiki, get the full page for the current result
                    text_func = function()
                        if self.is_wiki then
                            -- @translators Full Wikipedia article.
                            return C_("Button", "Wikipedia full")
                        else
                            return _("Wikipedia")
                        end
                    end,
                    callback = function()
                        UIManager:scheduleIn(0.1, function()
                            self:lookupWikipedia(self.is_wiki) -- will get_fullpage if is_wiki
                        end)
                    end,
                },
                -- Rotate thru available wikipedia languages, or Search in book if dict window
                {
                    id = "search",
                    -- if more than one language, enable it and display "current lang > next lang"
                    -- otherwise, just display current lang
                    text = self.is_wiki
                        and ( #self.wiki_languages > 1 and BD.wrap(self.wiki_languages[1]).." > "..BD.wrap(self.wiki_languages[2])
                                                        or self.wiki_languages[1] ) -- (this " > " will be auro-mirrored by bidi)
                        or _("Search"),
                    enabled = self:canSearch(),
                    callback = function()
                        if self.is_wiki then
                            -- We're rotating: forward this flag from the one we're closing so
                            -- that ReaderWikipedia can give it to the one we'll be showing
                            DictQuickLookup.rotated_update_wiki_languages_on_close = self.update_wiki_languages_on_close
                            self:lookupWikipedia(false, nil, nil, self.wiki_languages[2])
                            self:onClose(true)
                        else
                            self.ui:handleEvent(Event:new("HighlightSearch"))
                            self:onClose(true) -- don't unhighlight (or we might erase a search hit)
                        end
                    end,
                },
                {
                    id = "close",
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                    hold_callback = function()
                        self:onHoldClose()
                    end,
                },
            },
        }
        if not self.is_wiki and self.selected_link ~= nil then
            -- If highlighting some word part of a link (which should be rare),
            -- add a new first row with a single button to follow this link.
            table.insert(buttons, 1, {
                {
                    id = "link",
                    text = _("Follow Link"),
                    callback = function()
                        local link = self.selected_link.link or self.selected_link
                        self.ui.link:onGotoLink(link)
                        self:onClose()
                    end,
                },
            })
        end
    end
    if self.ui then
        self.ui:handleEvent(Event:new("DictButtonsReady", self, buttons))
    end
    -- Bottom buttons get a bit less padding so their line separators
    -- reach out from the content to the borders a bit more
    local buttons_padding = Size.padding.default
    local buttons_width = inner_width - 2*buttons_padding
    self.button_table = ButtonTable:new{
        width = buttons_width,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }

    -- Margin from screen edges
    local margin_top = Size.margin.default
    local margin_bottom = Size.margin.default
    if self.ui and self.ui.view and self.ui.view.footer_visible then
        -- We want to let the footer visible (as it can show time, battery level
        -- and wifi state, which might be useful when spending time reading
        -- definitions or wikipedia articles)
        margin_bottom = margin_bottom + self.ui.view.footer:getHeight()
    end
    local avail_height = Screen:getHeight() - margin_top - margin_bottom
    -- Region in which the window will be aligned center/top/bottom:
    self.region = Geom:new{
        x = 0,
        y = margin_top,
        w = Screen:getWidth(),
        h = avail_height,
    }
    self.align = "center"

    local others_height = frame_bordersize * 2 -- DictQuickLookup border
                        + self.dict_title:getHeight()
                        + top_to_word_span:getSize().h
                        + lookup_word:getSize().h
                        + word_to_definition_span:getSize().h
                        + definition_to_bottom_span:getSize().h
                        + self.button_table:getSize().h

    -- To properly adjust the definition to the height of text, we need
    -- the line height a ScrollTextWidget will use for the current font
    -- size (we'll then use this perfect height for ScrollTextWidget,
    -- but also for ScrollHtmlWidget, where it doesn't matter).
    if not self.definition_line_height then
        local test_widget = ScrollTextWidget:new{
            text = "z",
            face = self.content_face,
            width = self.content_width,
            height = self.definition_height,
            for_measurement_only = true, -- flag it as a dummy, so it won't trigger any bogus repaint/refresh...
        }
        self.definition_line_height = test_widget:getLineHeight()
        test_widget:free(true)
    end

    if is_large_window then
        -- Available height for definition + components
        self.height = avail_height
        self.definition_height = self.height - others_height
        local nb_lines = math.floor(self.definition_height / self.definition_line_height)
        self.definition_height = nb_lines * self.definition_line_height
        local pad = self.height - others_height - self.definition_height
        -- put that unused height on the above span
        word_to_definition_span.width = word_to_definition_span.width + pad
    else
        -- Definition height was previously computed as 0.5*0.7*screen_height, so keep
        -- it that way. Components will add themselves to that.
        self.definition_height = math.floor(avail_height * 0.5 * 0.7)
        -- But we want it to fit to the lines that will show, to avoid
        -- any extra padding
        local nb_lines = Math.round(self.definition_height / self.definition_line_height)
        -- HOOK
        print("h/4")
        self.definition_height = (nb_lines * self.definition_line_height)/2
        --self.definition_height = nb_lines * self.definition_line_height
        self.height = self.definition_height + others_height
        if self.word_boxes and #self.word_boxes > 0 then
            -- Try to not hide the highlighted word. We don't want to always
            -- get near it if we can stay center, so that more context around
            -- the word is still visible with the dict result.
            -- But if we were to be drawn over the word, move a bit if possible.

            -- In most cases boxes will be a single sbox, but handle multiple
            -- sboxes by taking the top and bottom y values.
            local word_box_top
            local word_box_bottom
            for _, box in ipairs(self.word_boxes) do
                local box_top = box.y
                local box_bottom = box.y + box.h
                if not word_box_top or word_box_top > box_top then
                    word_box_top = box_top
                end
                if not word_box_bottom or word_box_bottom < box_bottom then
                    word_box_bottom = box_bottom
                end
            end

            -- Don't stick to the box, ensure a minimal padding between box and
            -- window.
            word_box_top = word_box_top - Size.padding.small
            word_box_bottom = word_box_bottom + Size.padding.small

            local half_visible_height = (avail_height - self.height) / 2
            if word_box_bottom > half_visible_height and word_box_top <= half_visible_height + self.height then
                -- word would be covered by our centered window
                if word_box_bottom <= avail_height - self.height then
                    -- Window can be moved just below word
                    self.region.y = word_box_bottom
                    self.region.h = self.region.h - word_box_bottom
                    self.align = "top"
                elseif word_box_top > self.height then
                    -- Window can be moved just above word
                    self.region.y = 0
                    self.region.h = word_box_top
                    self.align = "bottom"
                end
            end
        end
    end

    -- Instantiate self.text_widget
    self:_instantiateScrollWidget()

    -- word definition
    self.definition_widget = FrameContainer:new{
        padding = 0,
        padding_left = content_padding_h,
        padding_right = content_padding_h,
        margin = 0,
        bordersize = 0,
        self.text_widget,
    }

    self.dict_frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = frame_bordersize,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.dict_title,
            top_to_word_span,
            -- word
            CenterContainer:new{
                dimen = Geom:new{
                    w = inner_width,
                    h = lookup_word:getSize().h,
                },
                lookup_word,
            },
            word_to_definition_span,
            -- definition
            CenterContainer:new{
                dimen = Geom:new{
                    w = inner_width,
                    h = self.definition_widget:getSize().h,
                },
                self.definition_widget,
            },
            definition_to_bottom_span,
            -- buttons
            CenterContainer:new{
                dimen = Geom:new{
                    w = inner_width,
                    h = self.button_table:getSize().h,
                },
                self.button_table,
            }
        }
    }

    self.movable = MovableContainer:new{
        -- We'll handle these events ourselves, and call appropriate
        -- MovableContainer's methods when we didn't process the event
        ignore_events = {
            -- These have effects over the definition widget, and may
            -- or may not be processed by it
            "swipe", "hold", "hold_release", "hold_pan",
            -- These do not have direct effect over the definition widget,
            -- but may happen while selecting text: we need to check
            -- a few things before forwarding them
            "touch", "pan", "pan_release",
        },
        self.dict_frame,
    }

    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.movable,
    }

    -- NT: add dict_title.left_button and lookup_edit_button to FocusManager.
    -- It is better to add these two buttons into self.movable, but it is not a FocusManager.
    -- Only self.button_table is a FocusManager, so workaground is inserting these two buttons into self.button_table.layout.
    if Device:hasDPad() then
        table.insert(self.button_table.layout, 1, { self.dict_title.left_button });
        table.insert(self.button_table.layout, 2, { lookup_edit_button });
    end

    -- We're a new window
    table.insert(DictQuickLookup.window_list, self)
end
