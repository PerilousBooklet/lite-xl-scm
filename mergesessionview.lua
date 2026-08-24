local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local MergeView = require "plugins.scm.mergeview"
local MessageBox = require "libraries.widget.messagebox"

---One tab of the merge session's internal tab strip.
---@class plugins.scm.mergesessionview.entry
---@field path string absolute path of the file being reviewed
---@field order integer stable position among this session's files,
---  independent of the order files' diff text happens to finish loading in
---@field label string tab title (basename of path)
---@field view plugins.scm.mergeview the three-pane diff for this file
---@field resolved boolean user-toggled "done reviewing this file" flag

---A single View -- and so a single tab in the outer editor's own tab
---strip -- that groups every file touched by one merge operation behind
---its own internal tab bar, with a bottom bar showing how many of them
---are marked resolved. Where the previous design opened one core Node
---tab per file (leaning entirely on core.node's own tab/split/drag
---machinery, see rootview.lua/node.lua), this instead behaves the way
---a single DocView behaves to the rest of the editor -- one Node leaf,
---one entry in the outer tab strip -- and reimplements a much simpler,
---non-splittable, non-draggable tab strip *inside* itself for
---navigating between the merge's files. MergeView itself is completely
---unaware this container exists; it's used exactly as it would be
---standalone, just laid out into a sub-rectangle of this view instead
---of a Node's.
---@class plugins.scm.mergesessionview : core.view
---@field super core.view
local MergeSessionView = View:extend()

-- FIX: mouse-wheel scrolling is broken

--------------------------------------------------------------------------------
-- Sizing constants
--------------------------------------------------------------------------------

---Deliberately mirrors core.node's own get_tab_y_sizes: height +
---padding + the same top margin -- so this view's internal tab strip
---reads as visually consistent with the outer RootView tab strip it
---sits inside one tab of, even though the two implementations don't
---share any code.
local function get_tab_height()
  local margin = (style.margin and style.margin.tab and style.margin.tab.top) or 0
  return style.font:get_height() + style.padding.y * 2 + margin
end

local function get_bottom_bar_height()
  return style.font:get_height() + style.padding.y * 2
end

---Mirrors core.node's local get_scroll_button_width (icon width plus
---padding on both sides).
local function get_scroll_button_width()
  local w = style.icon_font:get_width(">")
  return w * 3
end

-- Fixed-size square drawn at the left edge of every tab showing
-- resolved/unresolved state -- deliberately a plain rect rather than an
-- icon-font glyph, since a checkmark glyph isn't guaranteed to exist
-- across every bundled/user font the way a filled-vs-outlined square
-- reliably renders regardless of font.
local INDICATOR_SIZE = 10
local INDICATOR_PAD = 6

---@param project_dir string
---@param origin string
---@param destination string
function MergeSessionView:new(project_dir, origin, destination)
  MergeSessionView.super.new(self)
  self.project_dir = project_dir
  self.origin = origin
  self.destination = destination

  ---@type plugins.scm.mergesessionview.entry[]
  self.entries = {}
  ---@type integer?
  self.active_index = nil

  self.tab_width = style.tab_width
  self.tab_offset = 1
  self.hovered_tab = nil
  self.hovered_indicator = nil
end

function MergeSessionView:get_name()
  return string.format("Merge: %s <- %s", self.destination, self.origin)
end

function MergeSessionView:supports_text_input()
  return true
end

--------------------------------------------------------------------------------
-- File entries
--------------------------------------------------------------------------------

---Adds one file's three-way diff as a new tab, constructing its
---MergeView internally. Safe to call once per file, in any order: each
---changed file's origin/destination text is fetched asynchronously (see
---scm.open_merge_view), so calls can arrive in whatever order those
---backend requests happen to finish in -- `order` (the file's position
---in the original, synchronous file_changes list) is what actually
---determines tab order, via a re-sort on every insert.
---@param path string absolute path of the file being reviewed
---@param order integer
---@param left_doc core.doc
---@param center_doc core.doc
---@param right_doc core.doc
---@param left_label string
---@param right_label string
---@param center_label string
function MergeSessionView:add_file(path, order, left_doc, center_doc, right_doc, left_label, right_label, center_label)
  local view = MergeView(left_doc, center_doc, right_doc, left_label, right_label, center_label)

  ---@type plugins.scm.mergesessionview.entry
  local entry = {
    path = path,
    order = order,
    label = common.basename(path),
    view = view,
    resolved = false,
  }
  table.insert(self.entries, entry)
  table.sort(self.entries, function(a, b) return a.order < b.order end)

  if not self.active_index then
    self:set_active_index(1)
  end
  core.redraw = true
end

---@return plugins.scm.mergesessionview.entry?
function MergeSessionView:get_active_entry()
  return self.active_index and self.entries[self.active_index]
end

---@return plugins.scm.mergeview?
function MergeSessionView:get_active_view()
  local entry = self:get_active_entry()
  return entry and entry.view
end

---@param index integer
function MergeSessionView:set_active_index(index)
  if not self.entries[index] then return end
  self.active_index = index
  self:scroll_tab_into_view(index)
  core.redraw = true
end

function MergeSessionView:next_file()
  if not self.active_index then return end
  if self.active_index >= #self.entries then
    core.warn("SCM: no more files below.")
    return
  end
  self:set_active_index(self.active_index + 1)
end

function MergeSessionView:previous_file()
  if not self.active_index then return end
  if self.active_index <= 1 then
    core.warn("SCM: no more files above.")
    return
  end
  self:set_active_index(self.active_index - 1)
end

---Toggles the resolved/unresolved marker on the currently active file.
---Deliberately manual: conflict-marker syntax and merge tooling vary
---enough across backends that auto-detecting "this file's conflicts are
---gone" reliably isn't something to guess at, and a false "resolved"
---would be worse than requiring one click. Purely bookkeeping feeding
---get_progress() and the tab/bottom-bar indicators.
function MergeSessionView:toggle_active_resolved()
  local entry = self:get_active_entry()
  if not entry then return end
  entry.resolved = not entry.resolved
  core.redraw = true
end

---@return integer done, integer total
function MergeSessionView:get_progress()
  local done, total = 0, #self.entries
  for _, entry in ipairs(self.entries) do
    if entry.resolved then done = done + 1 end
  end
  return done, total
end

--------------------------------------------------------------------------------
-- Tab bar layout + hit-testing
--------------------------------------------------------------------------------

function MergeSessionView:tabs_overflow()
  return #self.entries * self.tab_width > self.size.x
end

function MergeSessionView:get_visible_tab_count()
  local w = self.size.x
  if self:tabs_overflow() then
    w = w - get_scroll_button_width() * 2
  end
  return math.max(1, math.floor(w / self.tab_width))
end

---@param index integer
function MergeSessionView:get_tab_rect(index)
  local th = get_tab_height()
  local x = self.position.x + self.tab_width * (index - self.tab_offset)
  return x, self.position.y, self.tab_width, th
end

---@param which "left"|"right"
function MergeSessionView:get_scroll_button_rect(which)
  local w = get_scroll_button_width()
  local th = get_tab_height()
  local x = which == "left"
    and (self.position.x + self.size.x - w * 2)
    or (self.position.x + self.size.x - w)
  return x, self.position.y, w, th
end

---@param index integer
function MergeSessionView:scroll_tab_into_view(index)
  local visible = self:get_visible_tab_count()
  if index < self.tab_offset then
    self.tab_offset = index
  elseif index > self.tab_offset + visible - 1 then
    self.tab_offset = index - visible + 1
  end
  self.tab_offset = common.clamp(self.tab_offset, 1, math.max(1, #self.entries - visible + 1))
end

---Returns which tab (if any) contains (px, py), and whether that point
---falls specifically on the tab's resolved-indicator square -- the one
---sub-region of a tab that toggles state instead of switching to it.
---@param px number
---@param py number
---@return integer? index, boolean is_indicator
function MergeSessionView:get_tab_at(px, py)
  local th = get_tab_height()
  if py < self.position.y or py >= self.position.y + th then return nil end

  local visible = self:get_visible_tab_count()
  for i = self.tab_offset, math.min(#self.entries, self.tab_offset + visible - 1) do
    local x, y, w, h = self:get_tab_rect(i)
    if px >= x and px < x + w then
      local ind_x = x + INDICATOR_PAD
      local ind_y = y + (h - INDICATOR_SIZE) / 2
      local is_indicator = px >= ind_x and px < ind_x + INDICATOR_SIZE
        and py >= ind_y and py < ind_y + INDICATOR_SIZE
      return i, is_indicator
    end
  end
  return nil, false
end

--------------------------------------------------------------------------------
-- Content layout
--------------------------------------------------------------------------------

---@return number x, number y, number w, number h
function MergeSessionView:get_content_rect()
  local th = get_tab_height()
  local bh = get_bottom_bar_height()
  return self.position.x, self.position.y + th, self.size.x, self.size.y - th - bh
end

function MergeSessionView:layout_active_view()
  local entry = self:get_active_entry()
  if not entry then return end
  local x, y, w, h = self:get_content_rect()
  entry.view.position.x, entry.view.position.y = x, y
  entry.view.size.x, entry.view.size.y = w, h
end

--------------------------------------------------------------------------------
-- Update / input routing
--------------------------------------------------------------------------------

---Only the *active* entry's MergeView is laid out and updated each
---frame -- inactive entries stay exactly as they were left, which is
---fine: their diff data doesn't depend on update() at all (see
---MergeView:start_diff_thread, a background coroutine independent of
---the normal per-frame update cycle, tied only to the MergeView
---instance's own lifetime), so switching to a tab shows an
---already-current diff, not a stale one.
function MergeSessionView:update()
  MergeSessionView.super.update(self)
  self:layout_active_view()
  local entry = self:get_active_entry()
  if entry then entry.view:update() end
end

function MergeSessionView:on_mouse_moved(x, y, dx, dy)
  MergeSessionView.super.on_mouse_moved(self, x, y, dx, dy)

  local th = get_tab_height()
  if y < self.position.y + th then
    local index, is_indicator = self:get_tab_at(x, y)
    self.hovered_tab = index
    self.hovered_indicator = is_indicator and index or nil
    return
  end
  self.hovered_tab = nil
  self.hovered_indicator = nil

  local entry = self:get_active_entry()
  if entry then entry.view:on_mouse_moved(x, y, dx, dy) end
end

function MergeSessionView:on_mouse_pressed(button, x, y, clicks)
  local th = get_tab_height()

  if y < self.position.y + th then
    if self:tabs_overflow() then
      local lx, ly, lw, lh = self:get_scroll_button_rect("left")
      if x >= lx and x < lx + lw and y >= ly and y < ly + lh then
        self.tab_offset = math.max(1, self.tab_offset - 1)
        return true
      end
      local rx, ry, rw, rh = self:get_scroll_button_rect("right")
      if x >= rx and x < rx + rw and y >= ry and y < ry + rh then
        local visible = self:get_visible_tab_count()
        self.tab_offset = math.min(math.max(1, #self.entries - visible + 1), self.tab_offset + 1)
        return true
      end
    end

    local index, is_indicator = self:get_tab_at(x, y)
    if index then
      if is_indicator then
        self.entries[index].resolved = not self.entries[index].resolved
      else
        self:set_active_index(index)
      end
    end
    return true
  end

  local entry = self:get_active_entry()
  if entry then
    return entry.view:on_mouse_pressed(button, x, y, clicks)
  end
end

function MergeSessionView:on_mouse_released(button, x, y)
  local entry = self:get_active_entry()
  if entry then entry.view:on_mouse_released(button, x, y) end
end

function MergeSessionView:on_mouse_wheel(y, x)
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  local th = get_tab_height()

  if my >= self.position.y and my < self.position.y + th then
    -- wheel over the tab strip scrolls tabs horizontally -- mirrors how
    -- most editor tab bars behave when there are more tabs than fit
    if y > 0 then
      self.tab_offset = math.max(1, self.tab_offset - 1)
    elseif y < 0 then
      local visible = self:get_visible_tab_count()
      self.tab_offset = math.min(math.max(1, #self.entries - visible + 1), self.tab_offset + 1)
    end
    return true
  end

  local entry = self:get_active_entry()
  if entry then return entry.view:on_mouse_wheel(y, x) end
end

function MergeSessionView:on_mouse_left()
  self.hovered_tab = nil
  self.hovered_indicator = nil
  local entry = self:get_active_entry()
  if entry then entry.view:on_mouse_left() end
end

function MergeSessionView:on_text_input(...)
  local entry = self:get_active_entry()
  if entry then entry.view:on_text_input(...) end
end

function MergeSessionView:on_ime_text_editing(...)
  local entry = self:get_active_entry()
  if entry then entry.view:on_ime_text_editing(...) end
end

--------------------------------------------------------------------------------
-- Draw
--------------------------------------------------------------------------------

---@param entry plugins.scm.mergesessionview.entry
---@param index integer
function MergeSessionView:draw_tab(entry, index)
  local x, y, w, h = self:get_tab_rect(index)
  local is_active = index == self.active_index

  renderer.draw_rect(x, y, w, h, is_active and style.background or style.background2)
  if is_active then
    renderer.draw_rect(x, y, w, style.divider_size, style.divider)
  end
  renderer.draw_rect(x + w - style.divider_size, y, style.divider_size, h, style.dim)

  local ind_x = x + INDICATOR_PAD
  local ind_y = y + (h - INDICATOR_SIZE) / 2
  if entry.resolved then
    renderer.draw_rect(ind_x, ind_y, INDICATOR_SIZE, INDICATOR_SIZE, style.good)
  else
    local c = style.dim
    renderer.draw_rect(ind_x, ind_y, INDICATOR_SIZE, 1, c)
    renderer.draw_rect(ind_x, ind_y + INDICATOR_SIZE - 1, INDICATOR_SIZE, 1, c)
    renderer.draw_rect(ind_x, ind_y, 1, INDICATOR_SIZE, c)
    renderer.draw_rect(ind_x + INDICATOR_SIZE - 1, ind_y, 1, INDICATOR_SIZE, c)
  end

  local text_x = ind_x + INDICATOR_SIZE + INDICATOR_PAD
  local text_w = math.max(0, x + w - style.divider_size - text_x - style.padding.x * 0.5)
  local color = is_active and style.text or style.dim

  local text = entry.label
  if style.font:get_width(text) > text_w then
    local dots = style.font:get_width("…")
    for i = 1, #text do
      local reduced = text:sub(1, #text - i)
      if style.font:get_width(reduced) + dots <= text_w then
        text = reduced .. "…"
        break
      end
    end
  end

  core.push_clip_rect(text_x, y, text_w, h)
  common.draw_text(style.font, color, text, "left", text_x, y, text_w, h)
  core.pop_clip_rect()
end

function MergeSessionView:draw_tab_bar()
  local th = get_tab_height()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, th)
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, th, style.background2)
  renderer.draw_rect(
    self.position.x, self.position.y + th - style.divider_size,
    self.size.x, style.divider_size, style.divider
  )

  local visible = self:get_visible_tab_count()
  for i = self.tab_offset, math.min(#self.entries, self.tab_offset + visible - 1) do
    self:draw_tab(self.entries[i], i)
  end

  if self:tabs_overflow() then
    local lx, ly, lw, lh = self:get_scroll_button_rect("left")
    renderer.draw_rect(lx, ly, lw * 2, lh, style.background2)
    local left_style = self.tab_offset > 1 and style.text or style.dim
    common.draw_text(style.icon_font, left_style, "<", "center", lx, ly, lw, lh)

    local rx, ry, rw, rh = self:get_scroll_button_rect("right")
    local right_style = (self.tab_offset + visible - 1 < #self.entries) and style.text or style.dim
    common.draw_text(style.icon_font, right_style, ">", "center", rx, ry, rw, rh)
  end

  core.pop_clip_rect()
end

function MergeSessionView:draw_bottom_bar()
  local bh = get_bottom_bar_height()
  local y = self.position.y + self.size.y - bh
  renderer.draw_rect(self.position.x, y, self.size.x, bh, style.background2)
  renderer.draw_rect(self.position.x, y, self.size.x, style.divider_size, style.divider)

  local done, total = self:get_progress()
  local label = string.format(
    "%s -> %s    %d/%d resolved", self.origin, self.destination, done, total
  )
  local color = (total > 0 and done == total) and style.good or style.text

  common.draw_text(
    style.font, color, label, "left",
    self.position.x + style.padding.x, y,
    self.size.x - style.padding.x * 2, bh
  )
end

function MergeSessionView:draw()
  self:draw_background(style.background)
  self:draw_tab_bar()

  local x, y, w, h = self:get_content_rect()
  local entry = self:get_active_entry()
  if entry then
    core.push_clip_rect(x, y, w, h)
    entry.view:draw()
    core.pop_clip_rect()
  else
    common.draw_text(style.font, style.dim, "Loading merge changes…", "center", x, y, w, h)
  end

  self:draw_bottom_bar()
end

--------------------------------------------------------------------------------
-- Close handling
--------------------------------------------------------------------------------

---Warns before closing the whole session tab (and, with it, every
---file's MergeView -- including their editable center docs) if any file
---is still unmarked resolved. Based on this view's own `resolved`
---bookkeeping rather than inspecting each center_doc for unsaved edits:
---each center_doc is still a normal, on-disk-tracked core.doc opened
---via core.open_doc, so if any of them individually has unsaved
---changes, that surfaces through DocView's/Doc's own regular save
---machinery the ordinary way (nothing here bypasses it) -- this check
---exists specifically to catch the *other* case: files closed while
---logically unresolved even though already saved.
---@param do_close fun()
function MergeSessionView:try_close(do_close)
  local done, total = self:get_progress()
  if total > 0 and done < total then
    MessageBox.warning(
      "Close Merge Session",
      {
        string.format("%d of %d files are not marked resolved.\n\n", total - done, total),
        "Close this merge session anyway?"
      },
      function(_, button_id)
        if button_id == 1 then
          MergeSessionView.super.try_close(self, do_close)
        end
      end,
      MessageBox.BUTTONS_YES_NO
    )
  else
    MergeSessionView.super.try_close(self, do_close)
  end
end

return MergeSessionView
