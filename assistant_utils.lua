local util = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local strbuf = require("string.buffer")
local T = require("ffi/util").template
local koutil = require("util")
local _ = require("assistant_gettext")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local https = require("ssl.https")
local json = require("rapidjson")

local M = {}
local shared_buf = strbuf.new()

function M.getGeneralNotebookFilePath(assistant)
  local notebookfile = nil
  local default_folder = util.tableGetValue(assistant.CONFIGURATION, "features", "default_folder_for_logs")
  local home_dir = G_reader_settings:readSetting("home_dir")
  local current_dir = assistant.ui.file_chooser and assistant.ui.file_chooser.path or assistant.ui:getLastDirFile()
  local target_dir = default_folder and default_folder ~= "" and util.pathExists(default_folder) and default_folder or (home_dir or current_dir)
  if target_dir then
    local notebookfile_path = target_dir .. "/general_notebook.md"
    notebookfile = notebookfile_path
  end
  return notebookfile
end

function M.extractBookTextForAnalysis(CONFIGURATION, ui)
    local book_text = nil
      if not ui.document.info.has_pages then
          -- Only extract text for EPUB documents
          local current_xp = ui.document:getXPointer()
          ui.document:gotoPos(0)
          local start_xp = ui.document:getXPointer()
          ui.document:gotoXPointer(current_xp)
          book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
          local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
          if #book_text > max_text_length_for_analysis then
              book_text = book_text:sub(-max_text_length_for_analysis)
              book_text = book_text:gsub("^[\128-\191]+", "")
              book_text = util.fixUtf8(book_text, "_")
          end
      else
        -- Extract text from the last n pages up to current reading position for page-based documents
        local current_page = ui.view.state.page
        local total_pages = ui.document:getPageCount()
        local max_page_size_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_page_size_for_analysis") or 250
        local start_page = math.max(1, current_page - max_page_size_for_analysis)
        book_text = ""
        for page = start_page, current_page do
            local page_text = ui.document:getPageText(page) or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for i = 1, #block do
                            local span = block[i]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            book_text = book_text .. page_text .. "\n"
        end
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
        if #book_text > max_text_length_for_analysis then
            book_text = book_text:sub(-max_text_length_for_analysis)
            book_text = book_text:gsub("^[\128-\191]+", "")
            book_text = util.fixUtf8(book_text, "_")
        end
    end
    return book_text
end

function M.extractHighlightsNotesAndNotebook(CONFIGURATION, ui, include_notebook)
    local highlights_and_notes = ""
    if ui.annotation and ui.annotation.annotations then
        for _, annotation in ipairs(ui.annotation.annotations) do
            if annotation.text and annotation.text ~= "" then
                highlights_and_notes = highlights_and_notes .. "Highlight: " .. annotation.text .. "\n"
            end
            if annotation.note and annotation.note ~= "" then
                highlights_and_notes = highlights_and_notes .. "Note: " .. annotation.note .. "\n"
            end
            if annotation.chapter then
                highlights_and_notes = highlights_and_notes .. "Chapter: " .. annotation.chapter .. "\n"
            end
            if annotation.pageno then
                highlights_and_notes = highlights_and_notes .. "Page: " .. annotation.pageno .. "\n"
            end
            highlights_and_notes = highlights_and_notes .. "\n"
        end
    end
    
    local notebook_content = ""
    if include_notebook then
      pcall(function()
          local notebookfile = ui.bookinfo:getNotebookFile(ui.doc_settings)
          if notebookfile then
              local json = require("json")
              local file = io.open(notebookfile, "r")
              if file then
                  local content = file:read("*all")
                  file:close()
                  local success, data = pcall(json.decode, content)
                  if success and data then
                      notebook_content = "Notebook Data:\n" .. json.encode(data)
                  else
                      notebook_content = "Notebook Content (raw):\n" .. content
                  end
              end
          end
      end)
    end
    
    local combined = highlights_and_notes
    if notebook_content ~= "" then
        if combined ~= "" then
            combined = combined .. "\n--- Notebook Content ---\n" .. notebook_content
        else
            combined = notebook_content
        end
    end
    
    local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    if #combined > max_text_length_for_analysis then
        combined = combined:sub(-max_text_length_for_analysis)
        combined = combined:gsub("^[\128-\191]+", "")
        combined = util.fixUtf8(combined, "_")
    end
    
    return combined
end

function M.getPageInfo(ui)
  local page_number = nil
  local percentage = 0
  local total_pages = nil
  local chapter_title = nil
  if ui.highlight and ui.highlight.selected_text and ui.highlight.selected_text.pos0 then
    if ui.paging then
      page_number = ui.highlight.selected_text.pos0.page
    else
      -- For rolling mode, we could get page number using document:getPageFromXPointer
      page_number = ui.document:getPageFromXPointer(ui.highlight.selected_text.pos0)
    end
    
    total_pages = ui.document.info.number_of_pages
    if page_number and total_pages and total_pages ~= 0 then
      percentage = math.floor((page_number / total_pages) * 100 + 0.5)
    end
    
    if ui.toc and page_number then
      chapter_title = ui.toc:getTocTitleByPage(page_number)
    end
  end

  local page_lbl = _("Page")
  local page_info = ""
  if page_number and total_pages then
    page_info = string.format(" (%s %s - %s%%)", page_lbl, page_number, percentage)
  elseif page_number then
    page_info = string.format(" (%s %s)", page_lbl, page_number)
  end

  if chapter_title then
    page_info = page_info .. " - " .. chapter_title
  end

  return page_info
end

function M.saveToNotebookFile(assistant, log_entry)
  local success, err = pcall(function()
    local notebookfile = assistant.ui.bookinfo:getNotebookFile(assistant.ui.doc_settings)
    local default_folder = util.tableGetValue(assistant.CONFIGURATION, "features", "default_folder_for_logs")
    if assistant.ui.doc_settings then
      if default_folder and default_folder ~= "" then
        if not notebookfile:find("^" .. default_folder:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) then
          if not util.pathExists(default_folder) then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Cannot access default folder for logs: %1\nUsing original location."), default_folder),
                timeout = 5,
              })
          else
            local original_filename = notebookfile:match("([^/\\]+)$")
            if original_filename then
              original_filename = original_filename:gsub("%.[^.]*$", ".md")
            else
              local doc_path = assistant.ui.document.file
              if doc_path then
                local doc_filename = doc_path:match("([^/\\]+)$")
                if doc_filename then
                  original_filename = doc_filename..".md"
                else
                  original_filename = "notebook.md"
                end
              else
                original_filename = "notebook.md"
              end
            end
            local new_notebookfile = default_folder .. "/" .. original_filename

            assistant.ui.doc_settings:saveSetting("notebook_file", new_notebookfile)

            notebookfile = new_notebookfile
          end
        end
      end

      if notebookfile and not notebookfile:find("%.md$") then
        notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
        if not notebookfile:find("%.md$") then
          notebookfile = notebookfile .. ".md"
        end
        assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
      end
    else
      notebookfile = M.getGeneralNotebookFilePath(assistant)
    end

    if notebookfile then
      local file = io.open(notebookfile, "a")
      if file then
        file:write(log_entry)
        file:close()
      else
        logger.warn("Assistant: Could not open notebook file:", notebookfile)
      end
    end
  end)

  if not success then
    logger.warn("Assistant: Error during notebook save:", err)
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Notebook save failed. Continuing..."),
      timeout = 3,
    })
  end
end

function M.normalizeMarkdownHeadings(content, heading_offset, max_heading_level)
  if type(content) ~= "string" or content == "" then
    return content
  end

  heading_offset = tonumber(heading_offset) or 0
  max_heading_level = tonumber(max_heading_level) or 6

  if heading_offset <= 0 then
    return content
  end

  -- Phase 1: Find the maximum heading level found in the content.
  -- Use a lightweight gmatch pattern that only captures hashes to avoid slicing full lines.
  local max_heading_level_found = nil
  for hashes in content:gmatch("\n%s*(#+)") do
    local level = #hashes
    if not max_heading_level_found or level > max_heading_level_found then
      max_heading_level_found = level
    end
  end
  
  -- Handle the first line separately since the gmatch pattern above relies on a leading newline.
  local first_hashes = content:match("^%s*(#+)")
  if first_hashes then
    local level = #first_hashes
    if not max_heading_level_found or level > max_heading_level_found then
      max_heading_level_found = level
    end
  end

  if not max_heading_level_found then
    return content
  end

  local target_max_level = heading_offset + 1
  local heading_shift = target_max_level - max_heading_level_found
  if heading_shift <= 0 then
    return content
  end

  -- Phase 2: Process and rebuild content using LuaJIT's string.buffer.
  -- Pre-allocate buffer size close to content length to prevent frequent reallocations.
  local buf = shared_buf
  buf:reset()
  
  local start_index = 1
  local content_length = #content

  while start_index <= content_length do
    local newline_index = content:find("\n", start_index, true)
    local line_end = newline_index and (newline_index - 1) or content_length
    
    local line = content:sub(start_index, line_end)
    
    -- Optimized pattern: %s* automatically strips spaces after the hashes.
    local leading_spaces, hashes, heading_text = line:match("^(%s*)(#+)%s*(.*)$")
    
    if hashes then
      -- Trim trailing spaces only, as leading spaces are already handled by the match pattern.
      heading_text = heading_text:gsub("%s*$", "")
      local new_level = #hashes + heading_shift
      
      buf:put(leading_spaces)
      if new_level > max_heading_level then
        if heading_text ~= "" then
          buf:put("**", heading_text, "**")
        else
          buf:put("**", "**")
        end
      else
        buf:put(string.rep("#", new_level)) 
        if heading_text ~= "" then
          buf:put(" ", heading_text)
        end
      end
    else
      -- Regular line, write directly to the buffer.
      buf:put(line)
    end

    if newline_index then
      buf:put("\n")
      start_index = newline_index + 1
    else
      break
    end
  end

  -- Extract the final consolidated string from continuous memory.
  return buf:get()
end

--[[
    Processes the model content, converting everything after the <suggestions> tag
    into Markdown links. It safely handles cases where the closing </suggestions> tag is missing.
    
    @param content string: The raw LLM response text.
    @param shared_buf table: The reusable string.buffer instance.
    @return string: The processed Markdown text.
--]]
function M.process_suggestions(content)
    if type(content) ~= "string" or content == "" then
        return content
    end

    -- Find only the start position of the opening tag
    local tag_start = string.find(content, "<suggestions>")
    if not tag_start then
        return content
    end

    -- Extract the main text before the tag
    local main_body = string.sub(content, 1, tag_start - 1)
    
    -- Extract everything after the "<suggestions>" tag (length is 13)
    local suggestions_block = string.sub(content, tag_start + 13)

    -- Reset the shared buffer to reuse its memory pool
    shared_buf:reset()
    
    -- Append the clean main body first
    shared_buf:put(main_body)
    shared_buf:putf("\n\n%s\n\n", _("##### You may find these topics interesting:"))

    -- Iterate through each line after the opening tag
    for line in string.gmatch(suggestions_block, "[^\r\n]+") do
        -- Extract the question text. If a line is just "</suggestions>", 
        -- it lacks a leading hyphen and will fail this match automatically.
        local question = string.match(line, "^%s*-%s*(.-)%s*$")
        if question and question ~= "" and question:find("[^%-]") then
            -- Append formatted links into C memory
            shared_buf:putf("- [%s](#q:%s)\n", question, koutil.urlEncode(question))
        end
    end

    -- Serialize and return the final string
    return shared_buf:get()
end

--- Sets a metadata attribute on an object
--- The attribute is stored in the object's metatable under the __attr field
--- This keeps metadata separate from the object's own data fields
--- 
--- @param obj table The object to attach metadata to
--- @param key string The attribute key name
--- @param value any The attribute value (can be any Lua type)
--- @throws Error if obj is not a table
function M.set_attr(obj, key, value)
    -- Validate that we're working with a table
    if type(obj) ~= "table" then
        error("obj must be a table")
    end
    
    -- Get or create the metatable
    local mt = getmetatable(obj)
    if not mt then
        mt = {}
        setmetatable(obj, mt)
    end
    
    -- Get or create the __attr sub-table within the metatable
    if not mt.__attr then
        mt.__attr = {}
    end
    
    -- Store the key-value pair in the __attr table
    mt.__attr[key] = value
end

--- Retrieves a metadata attribute from an object
--- Looks up the attribute in the object's metatable __attr field
--- Returns nil if the object has no metatable, no __attr field, or the key doesn't exist
---
--- @param obj table The object to query
--- @param key string The attribute key name
--- @param default any Optional default value to return if attribute doesn't exist
--- @return any The attribute value, or the default value if provided, or nil
function M.get_attr(obj, key, default)
    -- Safety check: ensure we're working with a table
    if type(obj) ~= "table" then
        return default
    end
    
    -- Attempt to retrieve the metatable and __attr field
    local mt = getmetatable(obj)
    if mt and mt.__attr then
        local value = mt.__attr[key]
        -- Explicitly check for nil to distinguish between nil and false
        if value ~= nil then
            return value
        end
    end
    
    -- Return default if attribute doesn't exist or is nil
    return default
end

-- default_value for rapidjson decoded object
function M.json_default(value, default_value)
    if value == nil or value == json.null then
        return default_value
    end
    return value
end

require("ffi/zlib_h")
local libz = ffi.loadlib("z", 1)
local ZLIB_HEADER = "\x78\x9c"
local scratch = strbuf.new()
-- Enhanced uncompress that natively tolerates the Gzip-to-Zlib trailer mismatch
local function zlib_uncompress_gzip(gzip_data, max_datalen)
    local total_len = #gzip_data
    if total_len < 18 then return nil, "Data truncated" end

    local deflate_len = total_len - 18
    local src_ptr = ffi.cast("const uint8_t*", gzip_data)

    -- reused buffer
    scratch:reset()
    -- 1. Prepend a valid standard Zlib header (0x78 0x9C)
    scratch:put(ZLIB_HEADER)
    -- 2. Strip the 10-byte Gzip header
    scratch:putcdata(src_ptr + 10, deflate_len)
    local payload_ptr, payload_len = scratch:ref()

    -- 3. Prepare the memory buffers
    local buf = ffi.new("uint8_t[?]", max_datalen)
    local buflen = ffi.new("unsigned long[1]", max_datalen)

    -- 4. Invoke the low-level libz
    local res = libz.uncompress(buf, buflen,
        ffi.cast("const unsigned char*", payload_ptr), payload_len)

    -- res == 0 means perfect zlib format
    -- res == -3 (Z_DATA_ERROR) happens here because the tail has a Gzip CRC32 instead of Zlib Adler32.
    -- But since the Deflate payload itself is 100% correct, the bytes in 'buf' are ALREADY completely deflated!
    if res == 0 or res == -3 then
        local actual_len = buflen[0]
        if actual_len > 0 then
            return ffi.string(buf, actual_len)
        end
    end
    
    return nil, "Zlib core uncompress failed with severe code: " .. tostring(res)
end

--- GET HTTP HEADER VALUE
--- @param headers table
--- @param header_name string
--- @return string|nil
local function http_get_header(headers, header_name)
    if not headers then return nil end
    local lower_name = header_name:lower()

    for k, v in pairs(headers) do
        if k:lower() == lower_name then
            return v
        end
    end
    return nil
end

--- 
--- Checks content-encoding
local function http_is_encoded(headers, encoding)
    local value = http_get_header(headers, "content-encoding")
    if not value then return false end
    return value:lower():find((encoding or "gzip"):lower()) ~= nil
end

--- 
--- these codes are first defined in api_handlers/base.lua
local BaseHandler = {}
BaseHandler.CODE_CANCELLED          = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR      = "NETWORK_ERROR"
BaseHandler.CODE_TIMEOUT            = "REQUEST_TIMEOUT"
BaseHandler.CODE_UNSUPPORTED_PROTO  = "UNSUPPORTED_PROTOCOL"
BaseHandler.CODE_INCOMPLETE         = "INCOMPLETE_CONTENT"
BaseHandler.CODE_DECOMPRESS_ERROR   = "DECOMPRESS_ERROR"
BaseHandler.CODE_SERVER_ERROR       = "SERVER_ERROR"
M.HANDLERCODE = BaseHandler

-- httpRequest with gzip compress support, GET/POST method only
function M.httpRequest(url, timeout, maxtime, post_body, post_content_type, headers)
    local parsed = socket_url.parse(url)
    if not parsed then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "URL cannot reconized" .. tostring(url)
    end
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "Unsupported protocol"
    end
    if parsed.scheme == "https" then
        https.cert_verify = false
    end
    if not timeout then timeout = 10 end
    socketutil:set_timeout(timeout, maxtime or 30)

    if not headers then
        headers = {}
    end
    headers["Accept-Encoding"] = "gzip"

    local sink = {}
    local request = {
        url     = url,
        method  = post_body and "POST" or "GET",
        headers = headers,
        sink    = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    }
    if post_body then
        if type(post_body) ~= "string" then post_body = json.encode(post_body) end
        request.source = ltn12.source.string(post_body)
        headers["Content-Type"]   = headers["Content-Type"] or post_content_type or "application/json"
        headers["Content-Length"] = headers["Content-Length"] or tostring(#post_body)
    end

    local code, resp_headers, status = socket.skip(1, http.request(request))
    local content = table.concat(sink)
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("request interrupted:", code)
        return false, BaseHandler.CODE_TIMEOUT, "Request interrupted/timed out"
    end
    if resp_headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. (status or code)
    end
    if not code then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        return false, code, content or "Remote server error or unavailable"
    end

    local http_len = http_get_header(resp_headers, "content-length")
    if http_len then
        if #content ~= tonumber(http_len) then
            return false, BaseHandler.CODE_INCOMPLETE, "Incomplete content received"
        end
    end

    if http_is_encoded(resp_headers, "gzip") then
        local decompressed, err = zlib_uncompress_gzip(content, 8*1024*1024)
        if not decompressed then
            logger.warn("Failed to decompress data:", err)
            return false, BaseHandler.CODE_DECOMPRESS_ERROR, "Failed to decompress data: " .. tostring(err)
        end
        content = decompressed
    end

    return true, code, content
end

return M