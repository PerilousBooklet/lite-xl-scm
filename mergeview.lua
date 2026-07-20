-- A DocView variant that shows three documents side by side in a single
-- view: left | center | right, separated by thin background-colored
-- columns.
--
-- This class *is* the DocView for the center document -- it inherits
-- DocView directly and is constructed against the center doc, exactly
-- like a normal DocView would be. That means every built-in editing
-- command (typing, arrow keys, selection, undo, etc, all of which act on
-- `core.active_view.doc`) works on the center document with no extra
-- code on our part.
--
-- The left and right documents are shown using two ordinary, separate
-- DocView instances that this view positions and draws inside its own
-- bounds. For now they're just plain DocViews (fully editable, nothing
-- special) -- deciding what actually goes in them, whether they should
-- be read-only, etc, is left for later.
--
-- NOTE: to make the inherited DocView drawing/mouse-to-cursor logic
-- operate only within the center column, this view temporarily narrows
-- self.position.x/self.size.x to the center column's bounds whenever it
-- delegates to the DocView superclass, then restores the real (full)
-- bounds afterwards. That relies on DocView using self.position/self.size
-- for both clipping and screen<->document coordinate translation, which
-- matches the behavior used elsewhere in this plugin already.

local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"

---@class plugins.scm.mergeview : core.docview
---@field super core.docview
local MergeView = DocView:extend()

---@param left_doc core.doc
---@param center_doc core.doc
---@param right_doc core.doc
function MergeView:new(left_doc, center_doc, right_doc)
  -- this makes `self` behave as a normal DocView bound to center_doc:
  -- same cursor, undo stack, scrolling, syntax highlighting, etc.
  MergeView.super.new(self, center_doc)

  self.left_view = DocView(left_doc)
  self.right_view = DocView(right_doc)
  self.left_view.scrollable = true
  self.right_view.scrollable = true

  -- width of the empty, background-colored strip between columns
  self.divider_width = math.ceil(2 * (SCALE or 1)) * 10
  self.divider_color = style.background2

  -- which pane is currently receiving a mouse drag, if any; false means
  -- the center (self) pane
  self.dragging_pane = false
  self.hovered_view = nil
end

function MergeView:get_name()
  return "Merge: " .. (self.doc and self.doc:get_name() or "")
end

---Computes the absolute screen x of each of the three columns plus their
---shared width, based on the view's current (full, untouched) bounds.
---@return number left_x, number center_x, number right_x, number pane_w
function MergeView:get_pane_metrics()
  local dw = self.divider_width
  local pane_w = (self.size.x - dw * 2) / 3
  local left_x = self.position.x
  local center_x = self.position.x + pane_w + dw
  local right_x = self.position.x + (pane_w + dw) * 2
  return left_x, center_x, right_x, pane_w
end

---Runs fn with self.position.x/self.size.x temporarily narrowed down to
---the center column, so anything DocView does internally (drawing,
---clipping, screen-to-document coordinate math) is confined to it.
function MergeView:with_center_bounds(fn, ...)
  local real_x, real_w = self.position.x, self.size.x
  local _, center_x, _, pane_w = self:get_pane_metrics()
  self.position.x, self.size.x = center_x, pane_w
  local ok, a, b, c = pcall(fn, ...)
  self.position.x, self.size.x = real_x, real_w
  if not ok then error(a, 0) end
  return a, b, c
end

local function point_in(px, py, x, y, w, h)
  return px >= x and px < x + w and py >= y and py < y + h
end

---Positions the left/right child views inside their own columns. Called
---from both update() and draw() so their bounds are always correct
---before anything (including their own internal scrollbar) is computed
---or drawn from them, regardless of call order.
function MergeView:layout_side_panes()
  local left_x, _, right_x, pane_w = self:get_pane_metrics()

  self.left_view.position.x, self.left_view.position.y = left_x, self.position.y
  self.left_view.size.x, self.left_view.size.y = pane_w, self.size.y

  self.right_view.position.x, self.right_view.position.y = right_x, self.position.y
  self.right_view.size.x, self.right_view.size.y = pane_w, self.size.y
end

function MergeView:update()
  -- lay out the side panes first, using the view's real (full) bounds
  self:layout_side_panes()
  self.left_view:update()
  self.right_view:update()

  -- scrollbar geometry is computed here, in update(), and only drawn
  -- later in draw() -- both must use the same (narrowed) bounds, or the
  -- center pane's scrollbar ends up sized/positioned against the full
  -- view width and overlaps the right pane when it's actually drawn
  self:with_center_bounds(MergeView.super.update, self)
end

function MergeView:draw()
  self:draw_background(style.background)
  self:layout_side_panes()

  local left_x, center_x, right_x, pane_w = self:get_pane_metrics()

  -- empty, background-colored strips between the three columns, drawn
  -- *before* the panes so nothing a pane draws near its own edge (in
  -- particular its scrollbar) can end up underneath them
  local dw = self.divider_width
  renderer.draw_rect(left_x + pane_w, self.position.y, dw, self.size.y, self.divider_color)
  renderer.draw_rect(center_x + pane_w, self.position.y, dw, self.size.y, self.divider_color)

  self.left_view:draw()
  self.right_view:draw()

  self:with_center_bounds(MergeView.super.draw, self)
end

function MergeView:on_mouse_moved(x, y, dx, dy)
  MergeView.super.on_mouse_moved(self, x, y, dx, dy)

  local left_x, center_x, right_x, pane_w = self:get_pane_metrics()
  if point_in(x, y, left_x, self.position.y, pane_w, self.size.y) then
    self.hovered_view = self.left_view
  elseif point_in(x, y, right_x, self.position.y, pane_w, self.size.y) then
    self.hovered_view = self.right_view
  else
    self.hovered_view = nil -- center pane, i.e. self
  end

  if self.dragging_pane == "left" then
    self.left_view:on_mouse_moved(x, y, dx, dy)
  elseif self.dragging_pane == "right" then
    self.right_view:on_mouse_moved(x, y, dx, dy)
  elseif self.hovered_view then
    self.hovered_view:on_mouse_moved(x, y, dx, dy)
  end
end

function MergeView:on_mouse_pressed(button, x, y, clicks)
  local left_x, center_x, right_x, pane_w = self:get_pane_metrics()

  if point_in(x, y, left_x, self.position.y, pane_w, self.size.y) then
    self.dragging_pane = "left"
    core.set_active_view(self)
    return self.left_view:on_mouse_pressed(button, x, y, clicks)
  elseif point_in(x, y, right_x, self.position.y, pane_w, self.size.y) then
    self.dragging_pane = "right"
    core.set_active_view(self)
    return self.right_view:on_mouse_pressed(button, x, y, clicks)
  end

  self.dragging_pane = false
  return self:with_center_bounds(MergeView.super.on_mouse_pressed, self, button, x, y, clicks)
end

function MergeView:on_mouse_released(button, x, y)
  if self.dragging_pane == "left" then
    self.left_view:on_mouse_released(button, x, y)
  elseif self.dragging_pane == "right" then
    self.right_view:on_mouse_released(button, x, y)
  else
    self:with_center_bounds(MergeView.super.on_mouse_released, self, button, x, y)
  end
  self.dragging_pane = false
end

function MergeView:on_mouse_wheel(...)
  if self.hovered_view then
    return self.hovered_view:on_mouse_wheel(...)
  end
  return self:with_center_bounds(MergeView.super.on_mouse_wheel, self, ...)
end

function MergeView:on_text_input(...)
  -- typing always targets the center document; the left/right panes are
  -- reference views for now, not the focus of text input
  MergeView.super.on_text_input(self, ...)
end

return MergeView
