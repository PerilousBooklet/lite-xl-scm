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
--
-- Diff gutters: the two divider strips between left/center and
-- center/right are also used to draw "who changed what" indicators --
-- one shape per changed block, colored the same way the single-doc
-- gutter highlighter already colors additions/deletions/modifications
-- (see plugins.scm's DocView:draw_line_gutter override). The block data
-- itself comes from a plain Myers line-diff (plugins.scm.linediff)
-- computed directly between the two documents' current buffers, not
-- from git: it doesn't matter whether left/right are real files, virtual
-- ReadDocs holding another branch's version of the file, or anything
-- else DocView can wrap.

local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"
local linediff = require "plugins.scm.linediff"

-- FUTURE_TODO: use Guldoman's CanvasView to draw smooth gutter shapes

-- FIX: in-place mouse scrolling for left/right views

-- TODO: check if `minimap` plugin is installed, if it is, adjust coordinate system to avoid overlapping on minimap
-- TODO: add super-scrollbar (coordinate auto-scroll of other scrollbars in relation to super-scrollbar)
-- TODO: draw gutter shapes to indicate merge direction of code blocks
-- TODO: draw gutter buttons to handle diff code

---@class plugins.scm.mergeview : core.docview
---@field super core.docview
local MergeView = DocView:extend()

---How often (in seconds) to check whether the center document changed
---and, if so, recompute both diff-gutters. Recomputation itself yields
---internally (see linediff.diff's yield_every) so even an expensive
---recompute on a large/very different file won't stall the editor --
---this interval just controls how eagerly we look for changes.
local DIFF_POLL_INTERVAL = 0.5

---Depth-iterations between internal coroutine.yield() calls inside the
---Myers diff. Only has an effect when running inside a coroutine (i.e.
---always true here, since recompute_diffs is only ever called from the
---core.add_thread body below).
local DIFF_YIELD_EVERY = 64

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
  self.divider_width = math.ceil(4 * (SCALE or 1)) * 10
  self.divider_color = style.background2

  -- which pane is currently receiving a mouse drag, if any; false means
  -- the center (self) pane
  self.dragging_pane = false
  self.hovered_view = nil

  -- diff-gutter state: blocks are {a1, a2, b1, b2, type} (see
  -- plugins.scm.linediff for the exact convention). left_blocks diffs
  -- left_view.doc (a) against self.doc (b); right_blocks diffs self.doc
  -- (a) against right_view.doc (b).
  self.left_blocks = {}
  self.right_blocks = {}
  self.diff_center_change_id = nil

  -- scroll-sync state: last frame's scroll.to.y for each pane, used by
  -- sync_scrolling() to detect which pane just received new scroll
  -- input this frame (see that function for the full explanation).
  self.prev_scroll_to_y = {
    left = self.left_view.scroll.to.y,
    center = self.scroll.to.y,
    right = self.right_view.scroll.to.y,
  }

  self:start_diff_thread()
end

function MergeView:get_name()
  return "Merge: " .. (self.doc and self.doc:get_name() or "")
end

--------------------------------------------------------------------------------
-- Diff computation
--------------------------------------------------------------------------------

---Returns the center doc's current change id, or nil if the doc doesn't
---expose one (older core.doc versions / unusual doc subclasses) -- in
---that case we just recompute unconditionally every poll tick, which is
---strictly safe, just potentially wasteful.
function MergeView:get_center_change_id()
  if self.doc.get_change_id then
    return self.doc:get_change_id()
  end
  return nil
end

---Recomputes both diff-gutters against the docs' current buffers, if
---the center document changed since the last time we did this. Safe to
---call often; it's a no-op when nothing changed. Meant to be called
---from inside a coroutine (the background thread started in :new()) so
---that the internal yielding in linediff actually has somewhere to
---yield to.
function MergeView:recompute_diffs()
  local change_id = self:get_center_change_id()
  if change_id ~= nil and change_id == self.diff_center_change_id then
    return
  end

  local left_lines = self.left_view.doc.lines
  local center_lines = self.doc.lines
  local right_lines = self.right_view.doc.lines

  self.left_blocks = linediff.diff(left_lines, center_lines, DIFF_YIELD_EVERY)
  if coroutine.isyieldable() then coroutine.yield() end
  self.right_blocks = linediff.diff(center_lines, right_lines, DIFF_YIELD_EVERY)

  self.diff_center_change_id = change_id
end

---Starts the per-view background thread that keeps the diff-gutters in
---sync with the center doc as it's edited. Tied to `self` via
---core.add_thread's weak-reference form, so it stops on its own once
---this view is closed and garbage collected -- nothing to clean up by
---hand.
function MergeView:start_diff_thread()
  core.add_thread(function()
    while true do
      self:recompute_diffs()
      coroutine.yield(DIFF_POLL_INTERVAL)
    end
  end, self)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

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

function MergeView:sync_scrolling()
  local panes = {
    { key = "left",   view = self.left_view },
    { key = "center", view = self },
    { key = "right",  view = self.right_view },
  }

  local source
  for _, pane in ipairs(panes) do
    local prev = self.prev_scroll_to_y[pane.key]
    local cur = pane.view.scroll.to.y
    if cur ~= prev then
      local own_max = self:get_pane_max_scroll_y(pane.view)
      -- A pane whose own document is shorter clamps its scroll.to.y to
      -- its own max every time it updates. If we forced it past that
      -- max last frame (because a taller pane had scrolled further),
      -- its own next update() call pulls it straight back down to
      -- own_max -- that's just the pane's own clamp catching up with
      -- last frame's sync, not new input, and must not be treated as a
      -- fresh source: doing so would drag the whole merge view's
      -- scroll back down to the shortest document's ceiling every
      -- time, which is exactly the bug this is fixing.
      if not (cur == own_max and prev > own_max) then
        source = pane
        break
      end
    end
  end

  if source then
    local target_y = source.view.scroll.to.y
    for _, pane in ipairs(panes) do
      if pane.key ~= source.key then
        pane.view.scroll.y = target_y
        pane.view.scroll.to.y = target_y
      end
    end
  end

  for _, pane in ipairs(panes) do
    self.prev_scroll_to_y[pane.key] = pane.view.scroll.to.y
  end
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

  -- must run last: all three panes have now processed this frame's
  -- input, so whichever one changed is reliably this frame's source
  self:sync_scrolling()
end

---Returns whichever of left_view/self/right_view currently has the
---most lines -- i.e. whichever one's own natural vertical-scroll clamp
---reaches furthest. Recomputed on demand (not cached), since any of the
---three docs can grow or shrink as they're edited.
---@return core.docview
function MergeView:get_tallest_view()
  local left_n = #self.left_view.doc.lines
  local center_n = #self.doc.lines
  local right_n = #self.right_view.doc.lines

  if left_n >= center_n and left_n >= right_n then
    return self.left_view
  elseif right_n >= center_n then
    return self.right_view
  end
  return self
end

---Returns how many pixels `view` can scroll down before reaching the
---end of its own document, given its current on-screen height. Uses the
---same doc-height/line-height arithmetic a DocView clamps its own
---scroll.to.y against, so this always agrees with that pane's own
---natural ceiling.
---@param view core.docview
---@return number
function MergeView:get_pane_max_scroll_y(view)
  local content_h = #view.doc.lines * view:get_line_height()
  return math.max(0, content_h - view.size.y)
end

--------------------------------------------------------------------------------
-- Diff-gutter rendering
--------------------------------------------------------------------------------

---Color for a given block type, matching the colors plugins.scm already
---uses for the single-doc gutter highlighter.
---@param block_type string "addition" | "deletion" | "modification"
---@return renderer.color
local function color_for_type(block_type)
  if block_type == "addition" then
    return style.good
  elseif block_type == "deletion" then
    return style.error
  end
  return style.warn
end

---Returns a copy of `color` with its alpha replaced.
local function with_alpha(color, a)
  return { color[1], color[2], color[3], a }
end

function MergeView:get_line_edge_y(view, line)
  local n = #view.doc.lines
  local lh = view:get_line_height()

  -- Computed directly rather than via view:get_line_screen_position,
  -- which only needs to be accurate for currently-visible lines and may
  -- clamp or otherwise misbehave far outside the current scroll
  -- position -- exactly the case here, since a block's line can be
  -- anywhere in the file regardless of where the view is scrolled to.
  -- This is the same position - scroll + offset arithmetic DocView
  -- positioning is built from, but it stays correct arbitrarily far
  -- off-screen, which the visibility cull in draw_diff_shape depends on.
  local base_y = view.position.y - view.scroll.y

  if n == 0 then
    return view.position.y
  end
  if line > n then
    return base_y + n * lh
  end
  if line < 1 then
    return base_y
  end
  return base_y + (line - 1) * lh
end

---Draws a single diff-gutter shape spanning horizontally from x1 to x2,
---with the "from" side's vertical extent given by (y1_top, y1_bot) and
---the "to" side's by (y2_top, y2_bot). When both extents match this is
---just a rectangle; when one side has zero height (a pure addition or
---deletion, since that side's line range is empty) it comes out as a
---triangle collapsing to a point on that side; otherwise it's a
---diagonal-ish trapezoid.
---
---The renderer only exposes axis-aligned rect fills, so the trapezoid is
---approximated with a handful of thin vertical strips, each interpolated
---to the correct height for its position between x1 and x2 -- the
---classic "staircase" polygon-fill trick.
---@param x1 number
---@param x2 number
---@param y1_top number
---@param y1_bot number
---@param y2_top number
---@param y2_bot number
---@param color renderer.color
function MergeView:draw_diff_shape(x1, x2, y1_top, y1_bot, y2_top, y2_bot, color)
  local w = x2 - x1
  if w <= 0 then return end

  -- also skip if the whole shape falls outside the view's visible
  -- vertical range, to avoid wasted draw calls while scrolled
  local top = math.min(y1_top, y2_top)
  local bot = math.max(y1_bot, y2_bot)
  if bot < self.position.y or top > self.position.y + self.size.y then
    return
  end

  local steps = math.max(1, math.min(64, math.ceil(w / 1.5)))
  local step_w = w / steps

  local fill = with_alpha(color, 90)
  for i = 0, steps - 1 do
    -- interpolate using the slice's midpoint, so a pure point-to-range
    -- shape (triangle) still narrows all the way to a point at its edge
    -- instead of jumping straight to full height on the first slice
    local t = (i + 0.5) / steps
    local seg_top = y1_top + (y2_top - y1_top) * t
    local seg_bot = y1_bot + (y2_bot - y1_bot) * t
    local h = math.max(1, seg_bot - seg_top)
    renderer.draw_rect(x1 + i * step_w, seg_top, step_w + 1, h, fill)
  end

  -- crisp solid accent bars flush against each edge, echoing the small
  -- solid bars the single-doc gutter highlighter already draws, so the
  -- exact boundary of a change is still legible even when the
  -- translucent fill is subtle
  local accent = with_alpha(color, 220)
  local bar_w = math.min(3, w)
  if y1_bot > y1_top then
    renderer.draw_rect(x1, y1_top, bar_w, y1_bot - y1_top, accent)
  end
  if y2_bot > y2_top then
    renderer.draw_rect(x2 - bar_w, y2_top, bar_w, y2_bot - y2_top, accent)
  end
end

---Draws every block in `blocks` into the gutter strip [x1, x2], mapping
---each block's `a` range through `view_a` and `b` range through
---`view_b`.
---@param blocks table
---@param view_a core.docview
---@param view_b core.docview
---@param x1 number
---@param x2 number
function MergeView:draw_diff_blocks(blocks, view_a, view_b, x1, x2)
  for _, block in ipairs(blocks) do
    local y1_top = self:get_line_edge_y(view_a, block.a1)
    local y1_bot = self:get_line_edge_y(view_a, block.a2 + 1)
    local y2_top = self:get_line_edge_y(view_b, block.b1)
    local y2_bot = self:get_line_edge_y(view_b, block.b2 + 1)

    self:draw_diff_shape(
      x1, x2, y1_top, y1_bot, y2_top, y2_bot, color_for_type(block.type)
    )
  end
end

---Draws both diff-gutters (left|center and center|right). Called from
---draw(), after the plain divider-color background strips are already
---down, so these shapes sit on top of them.
function MergeView:draw_diff_gutters()
  local left_x, center_x, right_x, pane_w = self:get_pane_metrics()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  self:draw_diff_blocks(
    self.left_blocks, self.left_view, self,
    left_x + pane_w, center_x
  )
  self:draw_diff_blocks(
    self.right_blocks, self, self.right_view,
    center_x + pane_w, right_x
  )

  core.pop_clip_rect()
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

  -- drawn last, on top of the flat divider strips and after both panes,
  -- so the shapes are never occluded by anything
  self:draw_diff_gutters()
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
  -- Vertical scrolling is always driven off whichever of the three
  -- panes holds the tallest document, never off whichever pane happens
  -- to be under the cursor. A pane showing a shorter document clamps
  -- its own scroll.to.y to its own (smaller) height as soon as it
  -- reaches the end; if that pane were the one actually processing the
  -- wheel event, further scrolling over it would silently do nothing
  -- once it hit its own end, even though a taller document among the
  -- three still has more to show below. Routing through the tallest
  -- pane means the wheel's own natural clamp ceiling always equals the
  -- true maximum scroll for the merge view as a whole.
  --
  -- Trade-off: a horizontal wheel-scroll (e.g. shift+wheel) performed
  -- while hovering a *side* pane will now act on whichever pane is
  -- tallest instead of the one under the cursor. Vertical scrolling is
  -- the common case here, so that's judged an acceptable trade for
  -- never getting stuck.
  local reference_view = self:get_tallest_view()

  if reference_view == self then
    return self:with_center_bounds(MergeView.super.on_mouse_wheel, self, ...)
  end
  return reference_view:on_mouse_wheel(...)
end

function MergeView:on_text_input(...)
  -- typing always targets the center document; the left/right panes are
  -- reference views for now, not the focus of text input
  MergeView.super.on_text_input(self, ...)
end

return MergeView
