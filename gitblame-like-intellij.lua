--mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

-- Store blame data per document path: blame_data[filename][line_num] = "YYYY-MM-DD Author"
local blame_data = {}
local pending_jobs = {}
local plugin_enabled = true

-- Configuration for appearance
config.gitblame_inline = {
  date_format = "%Y-%m-%d", -- Format string for date
  max_author_length = 12,   -- Truncate author names longer than this
  padding = 15              -- Extra pixel spacing between blame and line number
}

local function truncate_string(str, max_len)
  if #str > max_len then
    return string.sub(str, 1, max_len - 1) .. "…"
  end
  return str
end

-- Asynchronously fetch git blame for a given document
local function fetch_git_blame(doc)
  if not doc or not doc.filename or pending_jobs[doc.filename] then return end
  
  local filename = doc.filename
  pending_jobs[filename] = true

  -- Run git blame in incremental/porcelain mode for easy parsing
  local proc = process.start({
    "git", "blame", "--line-porcelain", filename
  }, { cwd = common.dirname(filename) })

  if not proc then
    pending_jobs[filename] = nil
    return
  end

  -- Process the output asynchronously
  core.add_thread(function()
    local output = ""
    while true do
      local chunk = proc:read_stdout(2048)
      if not chunk or #chunk == 0 then break end
      output = output .. chunk
      coroutine.yield()
    end
    
    local results = {}
    local current_line = nil
    local author = "Unknown"
    local author_time = 0

    for line in output:gmatch("[^\r\n]+") do
      -- Match header: hash orig_line final_line count
      local _, final_line = line:match("^([0-9a-f]+)%s+%d+%s+(%d+)")
      if final_line then
        current_line = tonumber(final_line)
      elseif line:match("^author ") then
        author = line:sub(8)
      elseif line:match("^author%-time ") then
        author_time = tonumber(line:sub(13)) or 0
      elseif line:match("^\t") and current_line then
        -- Tab indicates the actual code line (end of metadata block for this line)
        local date_str = os.date(config.gitblame_inline.date_format, author_time)
        local clean_author = truncate_string(author, config.gitblame_inline.max_author_length)
        results[current_line] = string.format("%s %s", date_str, clean_author)
        current_line = nil
      end
    end

    blame_data[filename] = results
    pending_jobs[filename] = nil
    core.redraw = true
  end)
end

-- 1. Intercept Gutter Width to make room for our blame string
local orig_get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  local width = orig_get_gutter_width(self)
  if not plugin_enabled or not self.doc or not self.doc.filename then
    return width
  end

  -- Trigger git blame fetch if we don't have the data yet
  if not blame_data[self.doc.filename] then
    fetch_git_blame(self.doc)
    return width
  end

  -- Calculate width required for the blame string based on current font
  local sample_str = "2026-00-00 " .. string.rep("A", config.gitblame_inline.max_author_length)
  local blame_width = self:get_font():get_width(sample_str) + config.gitblame_inline.padding
  
  return width + blame_width
end

-- 2. Intercept Line Number Rendering to draw Blame info before the line number
local orig_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  if not plugin_enabled or not self.doc or not self.doc.filename then
    return orig_draw_line_gutter(self, line, x, y, width)
  end

  local data = blame_data[self.doc.filename]
  if data and data[line] then
    local font = self:get_font()
    local color = style.syntax["comment"] or style.dim -- Dim/muted color for blame
    local blame_text = data[line]
    
    -- Draw the git blame string aligned to the left of the gutter
    renderer.draw_text(font, blame_text, x, y, color)
    
    -- Shrink the remaining width passed to the standard line number drawer
    local blame_text_width = font:get_width("2026-00-00 " .. string.rep("A", config.gitblame_inline.max_author_length)) + config.gitblame_inline.padding
    x = x + blame_text_width
    width = width - blame_text_width
  end

  return orig_draw_line_gutter(self, line, x, y, width)
end

-- Clear cache on file save so blame updates after committing/modifying
local orig_save = core.doc_save
core.doc_save = function(doc, ...)
  if doc and doc.filename then
    blame_data[doc.filename] = nil
  end
  return orig_save(doc, ...)
end

-- Commands to toggle the plugin on/off or refresh manually
command.add(function() return core.active_view:is(DocView) end, {
  ["gitblame-inline:toggle"] = function()
    plugin_enabled = not plugin_enabled
    core.redraw = true
    core.log("Inline Git Blame: %s", plugin_enabled and "Enabled" or "Disabled")
  end,
  ["gitblame-inline:refresh"] = function()
    local doc = core.active_view.doc
    if doc and doc.filename then
      blame_data[doc.filename] = nil
      fetch_git_blame(doc)
      core.log("Refreshed Git Blame for %s", doc.filename)
    end
  end
})
