local userpatch = require("userpatch")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Geom = require("ui/geometry")
local util = require("util")
local _ = require("gettext")

local PATCH_FLAG = "_intellireading_menu_patch_inplace"
local LOOKUP_PATCH_FLAG = "_intellireading_bionic_lookup_patch_inplace"
local BIONIC_MENU_KEY = "intellireading_bionic_reading"
local GUIDED_MENU_KEY = "intellireading_guided_dots"
local HANDMADE_PATCH_FLAG = "_intellireading_handmade_patch_inplace"
local DISPATCHER_PATCH_FLAG = "_intellireading_dispatcher_patch_inplace"
local BACKUP_SUFFIX = ".intellireading.orig"
local STATE_SUFFIX = ".intellireading.state"
local FEATURE_BIONIC = "bionic"
local FEATURE_GUIDED = "guided"
local GUIDE_DOT_ENTITY = "&middot;"

local TOC_FILENAMES = {
    ["nav.xhtml"] = true,
    ["nav.html"] = true,
    ["toc.xhtml"] = true,
    ["toc.html"] = true,
}

local function get_extension(path)
    return (path:match("%.([^./\\]+)$") or ""):lower()
end

local function is_epub_path(path)
    local ext = get_extension(path)
    return ext == "epub" or ext == "kepub"
end

local function is_xhtml_path(path)
    local ext = get_extension(path)
    return ext == "xhtml" or ext == "html" or ext == "htm"
end

local function is_supported_file(path)
    return is_epub_path(path) or is_xhtml_path(path)
end

local function get_backup_path(path)
    return path .. BACKUP_SUFFIX
end

local function get_state_path(path)
    return path .. STATE_SUFFIX
end

local function file_exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function copy_file(src, dst)
    local input = io.open(src, "rb")
    if not input then
        return nil, "unable to read source"
    end
    local data = input:read("*all")
    input:close()

    local temp = dst .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write target"
    end
    out:write(data)
    out:close()

    os.remove(dst)
    if not os.rename(temp, dst) then
        os.remove(temp)
        return nil, "unable to finalize target"
    end
    return true
end

local function normalize_feature_state(state)
    return {
        bionic = state and state.bionic and true or false,
        guided = state and state.guided and true or false,
    }
end

local function has_active_feature(state)
    return state and (state.bionic or state.guided) or false
end

local function read_feature_state(path)
    local state = normalize_feature_state(nil)
    local state_path = get_state_path(path)
    local has_state_file = file_exists(state_path)

    if has_state_file then
        local input = io.open(state_path, "rb")
        if input then
            for line in input:lines() do
                local key, value = line:match("^([%a_]+)=([01])$")
                if key == FEATURE_BIONIC then
                    state.bionic = value == "1"
                elseif key == FEATURE_GUIDED then
                    state.guided = value == "1"
                end
            end
            input:close()
        end
    elseif file_exists(get_backup_path(path)) then
        -- Legacy mode from old patch: backup file meant bionic was enabled.
        state.bionic = true
    end

    return state
end

local function write_feature_state(path, state)
    local normalized = normalize_feature_state(state)
    local state_path = get_state_path(path)
    local temp = state_path .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write state"
    end

    out:write(FEATURE_BIONIC, "=", normalized.bionic and "1" or "0", "\n")
    out:write(FEATURE_GUIDED, "=", normalized.guided and "1" or "0", "\n")
    out:close()

    os.remove(state_path)
    if not os.rename(temp, state_path) then
        os.remove(temp)
        return nil, "unable to finalize state"
    end
    return true
end

local function is_bionic_active_for_file(path)
    if not path then
        return false
    end
    return read_feature_state(path).bionic
end

local function is_guided_active_for_file(path)
    if not path then
        return false
    end
    return read_feature_state(path).guided
end

local function bold_word(word)
    local len = #word
    local midpoint = (len == 1 or len == 3) and 1 or math.ceil(len / 2)
    return "<b>" .. word:sub(1, midpoint) .. "</b>" .. word:sub(midpoint + 1)
end

local function inject_guided_separator(separator)
    local replaced, count = separator:gsub("%s+", " " .. GUIDE_DOT_ENTITY .. " ", 1)
    if count > 0 then
        return replaced
    end
    return separator
end

local function tokenize_text(text)
    local tokens = {}
    local index = 1
    local text_len = #text

    while index <= text_len do
        local s, e = text:find("%w+", index)
        if not s then
            table.insert(tokens, { is_word = false, text = text:sub(index) })
            break
        end
        if s > index then
            table.insert(tokens, { is_word = false, text = text:sub(index, s - 1) })
        end
        table.insert(tokens, { is_word = true, text = text:sub(s, e) })
        index = e + 1
    end

    return tokens
end

local function transform_text_part(part, state)
    if part == "" then
        return part
    end

    local tokens = tokenize_text(part)
    if #tokens == 0 then
        return part
    end

    local pieces = {}
    for i, token in ipairs(tokens) do
        if token.is_word then
            pieces[#pieces + 1] = state.bionic and bold_word(token.text) or token.text
        else
            local separator = token.text
            if state.guided
                and i > 1 and i < #tokens
                and tokens[i - 1].is_word
                and tokens[i + 1].is_word then
                separator = inject_guided_separator(separator)
            end
            pieces[#pieces + 1] = separator
        end
    end

    return table.concat(pieces)
end

local function transform_text_node(text, state)
    local pieces = {}
    local index = 1

    while true do
        local s, e, entity = text:find("(&[#%a][%w]*;)", index)
        if not s then
            pieces[#pieces + 1] = transform_text_part(text:sub(index), state)
            break
        end
        if s > index then
            pieces[#pieces + 1] = transform_text_part(text:sub(index, s - 1), state)
        end
        pieces[#pieces + 1] = entity
        index = e + 1
    end

    return table.concat(pieces)
end

local function transform_html_document(html, state)
    if not has_active_feature(state) then
        return html
    end

    local body_open, body_content = html:match("(<body[^>]*>)([%z\1-\255]-)</body>")
    if not body_open then
        return html
    end

    local transformed = body_content:gsub(">([^<]-)<", function(text)
        if text:match("^%s*$") then
            return ">" .. text .. "<"
        end
        return ">" .. transform_text_node(text, state) .. "<"
    end)

    return html:gsub("(<body[^>]*>)[%z\1-\255]-(</body>)", "%1" .. transformed .. "%2", 1)
end

local function transform_xhtml_file(input_file, output_file, state)
    local input = io.open(input_file, "rb")
    if not input then
        return nil, "unable to read source"
    end
    local content = input:read("*all")
    input:close()

    local temp = output_file .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write output"
    end
    out:write(transform_html_document(content, state))
    out:close()

    os.remove(output_file)
    if not os.rename(temp, output_file) then
        os.remove(temp)
        return nil, "unable to finalize output"
    end
    return true
end

local function transform_epub_file(input_file, output_file, state)
    local ok_archive, Archive = pcall(require, "ffi/archiver")
    if not ok_archive or not Archive then
        return nil, "archiver unavailable"
    end

    local temp = output_file .. ".tmp"
    os.remove(temp)

    local reader = Archive.Reader:new()
    if not reader:open(input_file) then
        return nil, reader.err or "unable to open source epub"
    end
    local writer = Archive.Writer:new()
    if not writer:open(temp, "zip") then
        reader:close()
        return nil, writer.err or "unable to open output epub"
    end

    -- EPUB requirement: "mimetype" first and stored.
    if not writer:setZipCompression("store") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to set store compression"
    end
    if not writer:addFileFromMemory("mimetype", "application/epub+zip") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to write mimetype"
    end
    if not writer:setZipCompression("deflate") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to set deflate compression"
    end

    local ok = true
    local err = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path == "mimetype" then
                goto continue
            end
            local content = reader:extractToMemory(entry.index)
            if content == nil then
                ok = false
                err = reader.err or ("unable to read " .. entry.path)
                break
            end
            local lower = entry.path:lower()
            local filename = lower:match("([^/]+)$") or lower
            if is_xhtml_path(lower) and not TOC_FILENAMES[filename] then
                content = transform_html_document(content, state)
            end
            if not writer:addFileFromMemory(entry.path, content) then
                ok = false
                err = writer.err or ("unable to write " .. entry.path)
                break
            end
        end
        ::continue::
    end
    reader:close()
    writer:close()

    if not ok then
        os.remove(temp)
        return nil, err
    end

    os.remove(output_file)
    if not os.rename(temp, output_file) then
        os.remove(temp)
        return nil, "unable to finalize output epub"
    end
    return true
end

local function validate_epub_file(filepath)
    local ok_archive, Archive = pcall(require, "ffi/archiver")
    if not ok_archive or not Archive then
        return nil, "archiver unavailable"
    end
    local reader = Archive.Reader:new()
    if not reader:open(filepath) then
        return nil, reader.err or "unable to open generated epub"
    end
    local has_mimetype, has_container = false, false
    local mimetype_content = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path == "mimetype" then
                has_mimetype = true
                mimetype_content = reader:extractToMemory(entry.index)
            elseif entry.path == "META-INF/container.xml" then
                has_container = true
            end
        end
    end
    reader:close()
    if not has_mimetype then
        return nil, "missing mimetype"
    end
    if mimetype_content ~= "application/epub+zip" then
        return nil, "invalid mimetype content"
    end
    if not has_container then
        return nil, "missing container.xml"
    end
    return true
end

local function apply_feature_state_inplace(file, new_state)
    local state = normalize_feature_state(new_state)
    local backup = get_backup_path(file)
    local state_path = get_state_path(file)
    local had_backup = file_exists(backup)
    local rollback = file .. ".intellireading.rollback.tmp"
    os.remove(rollback)
    copy_file(file, rollback)

    local function restore_previous_file()
        if file_exists(rollback) then
            copy_file(rollback, file)
        end
        os.remove(rollback)
    end

    if not has_active_feature(state) then
        if had_backup then
            local ok_copy, err_copy = copy_file(backup, file)
            if not ok_copy then
                restore_previous_file()
                return nil, err_copy
            end
            os.remove(backup)
        end
        os.remove(state_path)
        os.remove(rollback)
        return true
    end

    if not had_backup then
        local ok_copy, err_copy = copy_file(file, backup)
        if not ok_copy then
            restore_previous_file()
            return nil, err_copy
        end
    end

    local ok_transform, err_transform
    if is_epub_path(file) then
        ok_transform, err_transform = transform_epub_file(backup, file, state)
        if ok_transform then
            local valid, valid_err = validate_epub_file(file)
            if not valid then
                ok_transform = nil
                err_transform = valid_err
            end
        end
    else
        ok_transform, err_transform = transform_xhtml_file(backup, file, state)
    end

    if not ok_transform then
        restore_previous_file()
        if not had_backup and not file_exists(state_path) then
            os.remove(backup)
        end
        return nil, err_transform or "transform failed"
    end

    local ok_state, err_state = write_feature_state(file, state)
    if not ok_state then
        restore_previous_file()
        if not had_backup then
            os.remove(backup)
        end
        return nil, err_state or "unable to persist state"
    end

    os.remove(rollback)
    return true
end

local function clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function normalize_toc_title(title)
    return (title or "")
        :gsub("\13", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :lower()
end

local function resolve_saved_chapter(ui, snapshot)
    if not ui or not ui.toc or not snapshot then
        return nil
    end

    local toc = ui.toc.toc
    if type(toc) ~= "table" then
        return nil
    end

    local saved_title = normalize_toc_title(snapshot.chapter_title)
    local saved_index = tonumber(snapshot.chapter_index)

    local function make_result(item, index)
        if not item then
            return nil
        end
        return {
            index = index,
            page = item.page,
            xpointer = item.xpointer,
            title = item.title,
        }
    end

    if saved_index and toc[saved_index] then
        local item = toc[saved_index]
        if saved_title == "" or normalize_toc_title(item.title) == saved_title then
            return make_result(item, saved_index)
        end
    end

    if saved_title ~= "" then
        for index, item in ipairs(toc) do
            if normalize_toc_title(item.title) == saved_title then
                return make_result(item, index)
            end
        end
    end

    return nil
end

local function resolve_chapter_target_page(ui, snapshot)
    local chapter = resolve_saved_chapter(ui, snapshot)
    if not chapter or not chapter.page then
        return nil
    end

    local target_page = tonumber(chapter.page)
    if not target_page then
        return nil
    end

    local old_chapter_pages = tonumber(snapshot.chapter_page_count) or 0
    local old_chapter_done = tonumber(snapshot.chapter_pages_done) or 0
    if old_chapter_pages > 1 and old_chapter_done > 0 and ui.toc and ui.toc.getChapterPageCount then
        local new_chapter_pages = tonumber(ui.toc:getChapterPageCount(target_page)) or 0
        if new_chapter_pages > 1 then
            local chapter_ratio = old_chapter_done / math.max(old_chapter_pages - 1, 1)
            target_page = target_page + round(chapter_ratio * math.max(new_chapter_pages - 1, 0))
        end
    end

    return target_page
end

local function capture_progress(ui)
    if not ui or not ui.document then
        return nil
    end

    local document = ui.document
    local snapshot = {
        current_page = document.getCurrentPage and document:getCurrentPage() or nil,
        page_count = document.getPageCount and document:getPageCount() or nil,
    }

    if ui.rolling then
        snapshot.mode = "rolling"
        snapshot.view_mode = ui.rolling.view and ui.rolling.view.view_mode or nil
        snapshot.current_pos = document.getCurrentPos and document:getCurrentPos() or nil
        snapshot.doc_height = document.info and document.info.doc_height or nil
    elseif ui.paging then
        snapshot.mode = "paging"
        snapshot.location = ui.paging.getBookLocation and ui.paging:getBookLocation() or nil
    end

    if ui.toc then
        snapshot.chapter_index = ui.toc.getTocIndexByPage and ui.toc:getTocIndexByPage(snapshot.current_page) or nil
        snapshot.chapter_title = ui.toc.getTocTitleByPage and ui.toc:getTocTitleByPage(snapshot.current_page) or nil
        snapshot.chapter_pages_done = ui.toc.getChapterPagesDone and ui.toc:getChapterPagesDone(snapshot.current_page) or nil
        snapshot.chapter_page_count = ui.toc.getChapterPageCount and ui.toc:getChapterPageCount(snapshot.current_page) or nil
        if snapshot.chapter_index and ui.toc.toc and ui.toc.toc[snapshot.chapter_index] then
            snapshot.chapter_page = ui.toc.toc[snapshot.chapter_index].page
            snapshot.chapter_xpointer = ui.toc.toc[snapshot.chapter_index].xpointer
        end
    end

    return snapshot
end

local function restore_progress(ui, snapshot)
    if not ui or not snapshot or not ui.document then
        return
    end

    local document = ui.document
    local old_pages = tonumber(snapshot.page_count) or 0
    local new_pages = tonumber(document:getPageCount()) or 0
    local current_page = tonumber(snapshot.current_page) or 1
    local chapter_target_page = resolve_chapter_target_page(ui, snapshot)

    if ui.rolling then
        if chapter_target_page and new_pages > 0 then
            ui.rolling:_gotoPage(clamp(chapter_target_page, 1, new_pages))
            return
        end
        if snapshot.view_mode == "page" then
            if new_pages <= 0 then
                return
            end
            local new_page
            if old_pages > 1 then
                local ratio = (current_page - 1) / (old_pages - 1)
                new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
            else
                new_page = current_page
            end
            ui.rolling:_gotoPage(clamp(new_page, 1, new_pages))
            return
        end

        local old_height = tonumber(snapshot.doc_height) or 0
        local old_pos = tonumber(snapshot.current_pos) or 0
        local new_height = document.info and tonumber(document.info.doc_height) or 0
        if old_height > 0 and new_height > 0 then
            local new_pos = round((old_pos / old_height) * new_height)
            ui.rolling:_gotoPos(new_pos)
        elseif new_pages > 0 then
            local new_page
            if old_pages > 1 then
                local ratio = (current_page - 1) / (old_pages - 1)
                new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
            else
                new_page = current_page
            end
            ui.rolling:_gotoPage(clamp(new_page, 1, new_pages))
        end
        return
    end

    if ui.paging then
        if snapshot.location and old_pages > 0 then
            ui.paging:onRestoreBookLocation(snapshot.location)
            return
        end
        if chapter_target_page and new_pages > 0 then
            ui.paging:onGotoPage(clamp(chapter_target_page, 1, new_pages))
            return
        end
        if new_pages <= 0 then
            return
        end
        local new_page
        if old_pages > 1 then
            local ratio = (current_page - 1) / (old_pages - 1)
            new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
        else
            new_page = current_page
        end
        ui.paging:onGotoPage(clamp(new_page, 1, new_pages))
    end
end

local function get_feature_name(feature)
    if feature == FEATURE_GUIDED then
        return _("Guided dots")
    end
    return _("Bionic reading")
end

local function get_toggle_success_message(feature, enabled)
    if feature == FEATURE_GUIDED then
        return enabled and _("Guided dots enabled.") or _("Guided dots disabled.")
    end
    return enabled and _("Bionic reading enabled.") or _("Bionic reading disabled.")
end

local function get_toggle_failure_message(feature)
    if feature == FEATURE_GUIDED then
        return _("Guided dots failed.")
    end
    return _("Bionic reading failed.")
end

local function on_toggle_feature(ui, feature)
    if not ui or not ui.document or not is_supported_file(ui.document.file) then
        UIManager:show(InfoMessage:new{
            text = _("Intelli reading supports EPUB/HTML/XHTML files only."),
            timeout = 2,
        })
        return
    end

    local file = ui.document.file
    local state = read_feature_state(file)
    local new_state = normalize_feature_state(state)
    new_state[feature] = not new_state[feature]
    local enabled = new_state[feature]
    local progress_snapshot = capture_progress(ui)
    local reload_result = { ok = true, err = nil }

    ui:reloadDocument(function()
        local ok, err = apply_feature_state_inplace(file, new_state)
        reload_result.ok = ok and true or false
        reload_result.err = err
    end, nil, function(reloaded_ui)
        if reload_result.ok then
            restore_progress(reloaded_ui, progress_snapshot)
            UIManager:show(InfoMessage:new{
                text = get_toggle_success_message(feature, enabled),
                timeout = 2,
            })
        else
            UIManager:show(InfoMessage:new{
                text = get_toggle_failure_message(feature),
                timeout = 2,
            })
        end
    end)
end

local function insert_menu_key_before(order, before_key, new_key)
    for _, key in ipairs(order) do
        if key == new_key then
            return true
        end
    end

    for index, key in ipairs(order) do
        if key == before_key then
            table.insert(order, index, new_key)
            return true
        end
    end

    return false
end

local function insert_menu_key_after(order, after_key, new_key)
    for _, key in ipairs(order) do
        if key == new_key then
            return true
        end
    end

    for index, key in ipairs(order) do
        if key == after_key then
            table.insert(order, index + 1, new_key)
            return true
        end
    end

    return false
end

local function patch_reader_menu_order()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or not order or not order.typeset then
        return false
    end

    local inserted_guided = insert_menu_key_before(order.typeset, "typography", GUIDED_MENU_KEY)
    local inserted_bionic = insert_menu_key_before(order.typeset, "typography", BIONIC_MENU_KEY)
    return inserted_guided or inserted_bionic
end

local function patch_dispatcher_reader_actions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher or type(Dispatcher.registerAction) ~= "function" then
        return false
    end
    if not debug or type(debug.getupvalue) ~= "function" then
        return false
    end
    if Dispatcher[DISPATCHER_PATCH_FLAG] then
        return true
    end

    local settings_list
    local menu_order
    for i = 1, 32 do
        local name, value = debug.getupvalue(Dispatcher.registerAction, i)
        if not name then
            break
        end
        if name == "settingsList" then
            settings_list = value
        elseif name == "dispatcher_menu_order" then
            menu_order = value
        end
    end
    if not settings_list or not menu_order then
        return false
    end

    local function register_after(after_key, action_key, action_value)
        if settings_list[action_key] then
            return true
        end

        settings_list[action_key] = action_value

        local inserted = false
        for index, key in ipairs(menu_order) do
            if key == after_key then
                table.insert(menu_order, index + 1, action_key)
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(menu_order, action_key)
        end
        return true
    end

    register_after("toggle_handmade_flows", "toggle_bionic_reading", {
        category = "none",
        event = "ToggleBionicReading",
        title = _("Toggle bionic reading"),
        reader = true,
        condition = Device:isTouchDevice() or (Device:hasDPad() and Device:useDPadAsActionKeys()),
    })
    register_after("toggle_bionic_reading", "toggle_guided_dots", {
        category = "none",
        event = "ToggleGuidedDots",
        title = _("Toggle guided dots"),
        reader = true,
        condition = Device:isTouchDevice() or (Device:hasDPad() and Device:useDPadAsActionKeys()),
    })

    Dispatcher[DISPATCHER_PATCH_FLAG] = true
    return true
end

local function patch_readerhandmade_actions()
    local ok, ReaderHandMade = pcall(require, "apps/reader/modules/readerhandmade")
    if not ok or not ReaderHandMade then
        return false
    end
    if ReaderHandMade[HANDMADE_PATCH_FLAG] then
        return true
    end

    ReaderHandMade.onToggleBionicReading = function(self)
        on_toggle_feature(self and self.ui, FEATURE_BIONIC)
    end
    ReaderHandMade.onToggleGuidedDots = function(self)
        on_toggle_feature(self and self.ui, FEATURE_GUIDED)
    end

    ReaderHandMade[HANDMADE_PATCH_FLAG] = true
    return true
end

local function patch_readertypography_menu()
    local ok, ReaderTypography = pcall(require, "apps/reader/modules/readertypography")
    if not ok or not ReaderTypography or type(ReaderTypography.addToMainMenu) ~= "function" then
        return false
    end
    if ReaderTypography[PATCH_FLAG] then
        return true
    end

    local orig_add_to_main_menu = ReaderTypography.addToMainMenu
    ReaderTypography.addToMainMenu = function(self, menu_items)
        orig_add_to_main_menu(self, menu_items)
        menu_items[GUIDED_MENU_KEY] = {
            text = _("Guided dots"),
            checked_func = function()
                local file = self and self.ui and self.ui.document and self.ui.document.file
                return is_guided_active_for_file(file)
            end,
            callback = function()
                on_toggle_feature(self and self.ui, FEATURE_GUIDED)
            end,
        }
        menu_items[BIONIC_MENU_KEY] = {
            text = _("Bionic reading"),
            checked_func = function()
                local file = self and self.ui and self.ui.document and self.ui.document.file
                return is_bionic_active_for_file(file)
            end,
            callback = function()
                on_toggle_feature(self and self.ui, FEATURE_BIONIC)
            end,
        }
    end

    ReaderTypography[PATCH_FLAG] = true
    return true
end

local function is_non_space_text(text)
    if not text or text == "" then
        return false
    end
    if text:match("%s") then
        return false
    end
    -- Allow only word-ish content, plus '-' as requested.
    local stripped = text:gsub("%-", "")
    return stripped ~= "" and not stripped:match("[%p%s]")
end

local function expand_selection_across_non_spaces(document, selected_text)
    if not document or not selected_text or not selected_text.pos0 or not selected_text.pos1 then
        return nil
    end
    if type(document.getPrevVisibleChar) ~= "function"
        or type(document.getNextVisibleChar) ~= "function"
        or type(document.getTextFromXPointers) ~= "function" then
        return nil
    end

    local pos0 = selected_text.pos0
    local pos1 = selected_text.pos1
    local changed = false

    for _ = 1, 128 do
        local prev = document:getPrevVisibleChar(pos0)
        if not prev then
            break
        end
        local candidate = document:getTextFromXPointers(prev, pos1, true)
        if not is_non_space_text(util.cleanupSelectedText(candidate or "")) then
            break
        end
        pos0 = prev
        changed = true
    end

    for _ = 1, 128 do
        local nextp = document:getNextVisibleChar(pos1)
        if not nextp then
            break
        end
        local candidate = document:getTextFromXPointers(pos0, nextp, true)
        if not is_non_space_text(util.cleanupSelectedText(candidate or "")) then
            break
        end
        pos1 = nextp
        changed = true
    end

    if not changed then
        return nil
    end

    local new_text = document:getTextFromXPointers(pos0, pos1, true)
    if not new_text or new_text == "" then
        return nil
    end

    local sboxes = type(document.getScreenBoxesFromPositions) == "function"
        and document:getScreenBoxesFromPositions(pos0, pos1, true)
        or nil

    return {
        text = util.cleanupSelectedText(new_text),
        pos0 = pos0,
        pos1 = pos1,
        sboxes = (sboxes and #sboxes > 0) and sboxes or selected_text.sboxes,
        pboxes = selected_text.pboxes,
    }
end

local function patch_readerhighlight_lookup()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or not ReaderHighlight or type(ReaderHighlight.onHold) ~= "function" then
        return false
    end
    if ReaderHighlight[LOOKUP_PATCH_FLAG] then
        return true
    end

    local orig_on_hold = ReaderHighlight.onHold
    ReaderHighlight.onHold = function(self, arg, ges)
        local handled = orig_on_hold(self, arg, ges)
        local ui = self and self.ui
        local doc = ui and ui.document

        if handled and self and self.is_word_selection and self.selected_text
            and ui and is_bionic_active_for_file(doc and doc.file) then
            local expanded = expand_selection_across_non_spaces(doc, self.selected_text)
            if expanded then
                self.selected_text = expanded
                if self.ui and self.ui.paging and self.hold_pos and self.selected_text.sboxes then
                    self.view.highlight.temp[self.hold_pos.page] = self.selected_text.sboxes
                    UIManager:setDirty(self.dialog, "ui")
                elseif self.selected_text.sboxes then
                    UIManager:setDirty(self.dialog, "ui", Geom.boundingBox(self.selected_text.sboxes))
                else
                    UIManager:setDirty(self.dialog, "ui")
                end
            end
        end
        return handled
    end

    ReaderHighlight[LOOKUP_PATCH_FLAG] = true
    return true
end

local function apply_patch()
    patch_dispatcher_reader_actions()
    patch_readerhandmade_actions()
    patch_reader_menu_order()
    patch_readertypography_menu()
    patch_readerhighlight_lookup()
end

apply_patch()

userpatch.registerPatchPluginFunc("perceptionexpander", function()
    apply_patch()
end)
