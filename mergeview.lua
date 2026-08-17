local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"
local linediff = require "plugins.scm.linediff"

-- FIX: merge confirmation button is missing
-- TODO: indicate merge direction of code blocks in gutter shapes
-- TODO: add top-left indicator of branch name (look at diffview)

-- TODO: draw gutter buttons to handle editing diff code (add/remove)

-- FIX: gutter shape transitions while scrolling are flickering

-- FUTURE_TODO: use Guldoman's CanvasView to draw smooth gutter shapes

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

---Alpha (0-255) used for the full-line diff highlight wash drawn across
---each changed line's entire width -- separate from (and much lower
---than) the alpha used for the small gutter-shape fills, since this one
---sits directly on top of the code text and needs to stay legible.
local LINE_HIGHLIGHT_ALPHA = 40

---Height (in pixels, scaled by SCALE at draw time) of the marker line
---drawn at a pure insertion/deletion's boundary -- see
---draw_line_highlight_blocks for why that boundary needs its own marker
---rather than a row wash.
local LINE_MARKER_HEIGHT = 2

---Alpha (0-255) for that marker line. Deliberately much higher than
---LINE_HIGHLIGHT_ALPHA: it's a thin line rather than a wash across the
---whole row, so it can afford (and needs) to be much more opaque in
---order to read as a deliberate mark rather than a stray pixel.
local LINE_MARKER_ALPHA = 200

---How many lines of context (in center-document coordinates) to keep
---above a navigation stop's line when jumping to it, so the change
---doesn't land flush against the very top edge of the viewport.
local GOTO_BLOCK_MARGIN_LINES = 3

---@param view core.docview
local function disable_minimap(view)
  local sb = view.v_scrollbar
  if sb and sb.is_minimap_enabled then
    sb.enabled = false
  end
end

---@param left_doc core.doc
---@param center_doc core.doc
---@param right_doc core.doc
function MergeView:new(left_doc, center_doc, right_doc)
  -- this makes `self` behave as a normal DocView bound to center_doc:
  -- same cursor, undo stack, scrolling, syntax highlighting, etc.
  MergeView.super.new(self, center_doc)

  self.left_view = DocView(left_doc)
  self.right_view = DocView(right_doc)
  disable_minimap(self.left_view)
  disable_minimap(self.right_view)
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

  -- Tracks, per pane, the exact value sync_scrolling last *forced* onto
  -- that pane (copied down from whichever pane is driving the group
  -- scroll this frame). This lets us tell "this pane's own scroll clamp
  -- caught up with a value we pushed into it" apart from "this pane
  -- genuinely received new input", without needing to know what that
  -- pane's real maximum scroll actually is -- see sync_scrolling for
  -- the full rationale.
  self.forced_scroll_to_y = {}

  -- See DiffView.last_goto_line/last_goto_target_y for the full
  -- rationale -- same mechanism, here in center-document coordinates.
  self.last_goto_line = nil
  self.last_goto_target_y = nil

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

---Maps a (possibly fractional) line coordinate from one side of a diff
---block list to the other, so that scroll-syncing can align panes by
---*diff correspondence* rather than by raw line number. See the
---identical helper in diffview.lua for the full writeup of the
---coordinate convention and the interpolation/collapse rules -- this is
---the same function, just duplicated here the way the other small
---diff-math helpers (color_for_type, with_alpha, get_line_edge_y, etc)
---already are between the two files.
---@param blocks table
---@param from_is_a boolean
---@param line number
---@return number
local function map_line(blocks, from_is_a, line)
  local prev_from_end, prev_to_end = 0, 0

  for i = 1, #blocks do
    local block = blocks[i]
    local from1 = from_is_a and block.a1 or block.b1
    local from2 = from_is_a and block.a2 or block.b2
    local to1   = from_is_a and block.b1 or block.a1
    local to2   = from_is_a and block.b2 or block.a2

    local from_lo, from_hi = from1, from2 + 1
    if from1 > from2 then from_hi = from_lo end

    if line < from_lo then
      return line + (prev_to_end - prev_from_end)
    end

    if line < from_hi then
      if to1 > to2 then
        return to1
      end
      local to_lo, to_hi = to1, to2 + 1
      local t = (line - from_lo) / (from_hi - from_lo)
      return to_lo + t * (to_hi - to_lo)
    end

    prev_from_end = from_hi
    prev_to_end = (to1 > to2) and to1 or (to2 + 1)
  end

  return line + (prev_to_end - prev_from_end)
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

---Converts a view's current scroll.to.y into an equivalent (possibly
---fractional) "line at the top of the viewport" coordinate, in the
---same continuous convention map_line uses.
---@param view core.docview
---@return number
function MergeView:scroll_to_line(view)
  return view.scroll.to.y / view:get_line_height() + 1
end

---Inverse of scroll_to_line: converts a line coordinate back into the
---scroll.to.y that would put it at the top of `view`'s viewport.
---@param view core.docview
---@param line number
---@return number
function MergeView:line_to_scroll(view, line)
  return (line - 1) * view:get_line_height()
end

---Given which pane is driving the scroll (`source_key`) and its
---current top-of-viewport line, computes the corresponding line for
---each of the *other* two panes by chaining through whichever block
---list connects them:
---
--- - source "left":   left --left_blocks--> center --right_blocks--> right
--- - source "right":  right --right_blocks--> center --left_blocks--> left
--- - source "center": center --left_blocks--> left
---                     center --right_blocks--> right
---
---i.e. the center pane is always the hinge: a change starting from a
---side pane is first mapped onto the center document, then that
---(already-mapped) center line is mapped again onto the far side pane,
---rather than trying to map directly between left and right (which
---share no block list of their own).
---@param source_key "left"|"center"|"right"
---@param source_line number
---@return table lines keyed by "left"/"center"/"right"
function MergeView:map_all_lines(source_key, source_line)
  local lines = { [source_key] = source_line }

  if source_key == "left" then
    lines.center = map_line(self.left_blocks, true, source_line)
    lines.right = map_line(self.right_blocks, true, lines.center)
  elseif source_key == "right" then
    lines.center = map_line(self.right_blocks, false, source_line)
    lines.left = map_line(self.left_blocks, false, lines.center)
  else -- "center"
    lines.left = map_line(self.left_blocks, false, source_line)
    lines.right = map_line(self.right_blocks, true, source_line)
  end

  return lines
end

---Synchronizes vertical scroll across all three panes so that whichever
---diff block is at the top of one pane's viewport, the *corresponding*
---lines of that same block are kept at the top of the other panes'
---viewports too -- rather than just keeping all three panes at the same
---raw pixel offset, which only stays meaningful up until the first
---block that has a different number of lines across sides. See
---map_line/map_all_lines for the actual correspondence logic.
---
---Whenever exactly one pane's scroll.to.y changed this frame due to
---real input, its line position is mapped onto the other two panes and
---written into them. A pane holding a shorter document clamps its own
---scroll.to.y to its own ceiling once forced past it, which looks
---identical to real input unless we specifically remember (in
---self.forced_scroll_to_y) the exact value we ourselves wrote into it
---last frame and exclude exactly that transition from counting as a
---new source.
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
      local forced_prev = self.forced_scroll_to_y[pane.key]
      if not (forced_prev ~= nil and forced_prev == prev) then
        source = pane
        break
      end
    end
  end

  if source then
    local source_line = self:scroll_to_line(source.view)
    local mapped = self:map_all_lines(source.key, source_line)

    for _, pane in ipairs(panes) do
      if pane.key ~= source.key then
        local target_y = self:line_to_scroll(pane.view, mapped[pane.key])
        pane.view.scroll.y = target_y
        pane.view.scroll.to.y = target_y
        self.forced_scroll_to_y[pane.key] = target_y
      else
        self.forced_scroll_to_y[pane.key] = nil
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

--------------------------------------------------------------------------------
-- Diff-block navigation
--------------------------------------------------------------------------------

---Builds a single, position-sorted list of navigation "stops" by
---merging left_blocks and right_blocks into center-document line
---coordinates: a left_blocks entry's stop is block.b1 (its position on
---the center side of that block list); a right_blocks entry's stop is
---block.a1 (the center side of *that* list). Center is always the
---hinge (see map_all_lines), so this is the one coordinate system both
---block lists share.
---
---Not merged/deduplicated when a left- and a right-side block happen to
---start on the same center line -- both remain separate stops at the
---same position, since that's two independent changes coinciding, not
---one change to collapse into a single stop.
---@return table[] stops, each {line = number, block = table, side = "left"|"right"}
function MergeView:get_navigation_stops()
  local stops = {}
  for _, block in ipairs(self.left_blocks) do
    table.insert(stops, { line = block.b1, block = block, side = "left" })
  end
  for _, block in ipairs(self.right_blocks) do
    table.insert(stops, { line = block.a1, block = block, side = "right" })
  end
  table.sort(stops, function(x, y) return x.line < y.line end)
  return stops
end

---Scrolls so that `stop.line` (already in center-document coordinates)
---sits a few lines below the top of the viewport (see
---GOTO_BLOCK_MARGIN_LINES).
---@param stop table
function MergeView:scroll_to_stop(stop)
  local line = math.max(1, stop.line - GOTO_BLOCK_MARGIN_LINES)
  local target_y = self:line_to_scroll(self, line)
  self.scroll.y = target_y
  self.scroll.to.y = target_y

  -- Remember the stop's own (unclamped, un-margined) line -- goto_block
  -- needs this, not the landing line above it, to correctly recognize
  -- "we're already on this stop" the next time it's called. See
  -- DiffView:goto_block for the full writeup of why.
  self.last_goto_line = stop.line
  self.last_goto_target_y = target_y
end

---Moves to the next (direction > 0) or previous (direction < 0) diff
---block relative to the center pane's current position.
---@param direction number
function MergeView:goto_block(direction)
  local stops = self:get_navigation_stops()
  if #stops == 0 then
    core.warn("SCM: no changes to navigate.")
    return
  end

  local current
  if self.last_goto_target_y ~= nil and self.scroll.to.y == self.last_goto_target_y then
    current = self.last_goto_line
  else
    current = self:scroll_to_line(self)
  end

  local target

  if direction > 0 then
    for _, stop in ipairs(stops) do
      if stop.line > current + 0.5 then
        target = stop
        break
      end
    end
    if not target then
      core.warn("SCM: no more changes below.")
      return
    end
  else
    for i = #stops, 1, -1 do
      local stop = stops[i]
      if stop.line < current - 0.5 then
        target = stop
        break
      end
    end
    if not target then
      core.warn("SCM: no more changes above.")
      return
    end
  end

  self:scroll_to_stop(target)
end

function MergeView:goto_next_block()
  self:goto_block(1)
end

function MergeView:goto_previous_block()
  self:goto_block(-1)
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

  -- Anchored on view:get_content_offset() rather than a hand-rolled
  -- `view.position.y - view.scroll.y`: get_content_offset() is the same
  -- function DocView's own line-drawing anchors on, so it already folds
  -- in whatever top padding/rounding that drawing applies that we'd
  -- otherwise have to guess at -- a mismatch there was exactly why the
  -- diff shapes and line highlights used to come out very slightly
  -- offset against the actual text rows. We still don't call
  -- view:get_line_screen_position() itself, though: unlike
  -- get_content_offset() (a pure position - scroll transform, safe for
  -- any line, on-screen or not), get_line_screen_position() isn't
  -- guaranteed accurate for a line far outside the current scroll
  -- position -- and a block's line can be anywhere in the file
  -- regardless of where the view is currently scrolled to.
  local _, base_y = view:get_content_offset()
  base_y = base_y + style.padding.y

  if n == 0 then
    return base_y
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

--------------------------------------------------------------------------------
-- Full-line highlight rendering
--------------------------------------------------------------------------------

---Draws a translucent tint spanning the full width of `view` over every
---line in `blocks` that touches the given `side` ("a" or "b"). Mirrors
---the same green/red/yellow convention the gutter shapes already use
---(see color_for_type), but washes the color across the whole line
---instead of a thin bar in the divider -- the gutter marks *that*
---something changed, this makes *where* impossible to miss while
---actually reading the code, the same way IntelliJ (and most modern
---diff UIs) highlight changed lines directly in the editor.
---
---A block can also have *no* lines on this side at all: a1 > a2 (or
---b1 > b2) means "no lines here", which is the case for a pure
---addition's `a` side or a pure deletion's `b` side (see
---plugins.scm.linediff's block convention). There's no row to shade
---then, but something still happened at that exact point -- so instead
---a short, solid marker line is drawn straddling the boundary between
---the two surrounding (unchanged) lines. Without it, that side had no
---rendered indication of the change at all beyond the tip of the gutter
---shape over in the divider, which is easy to miss.
---@param blocks table
---@param side "a"|"b"
---@param view core.docview
---@param x number
---@param w number
function MergeView:draw_line_highlight_blocks(blocks, side, view, x, w)
  for _, block in ipairs(blocks) do
    local line1 = side == "a" and block.a1 or block.b1
    local line2 = side == "a" and block.a2 or block.b2
    local color = color_for_type(block.type)

    if line2 >= line1 then
      local y1 = self:get_line_edge_y(view, line1)
      local y2 = self:get_line_edge_y(view, line2 + 1)

      if y2 >= self.position.y and y1 <= self.position.y + self.size.y then
        renderer.draw_rect(x, y1, w, y2 - y1, with_alpha(color, LINE_HIGHLIGHT_ALPHA))
      end
    else
      local mh = LINE_MARKER_HEIGHT * (SCALE or 1)
      local y = self:get_line_edge_y(view, line1) - mh / 2

      if y + mh >= self.position.y and y <= self.position.y + self.size.y then
        renderer.draw_rect(x, y, w, mh, with_alpha(color, LINE_MARKER_ALPHA))
      end
    end
  end
end

---Draws the full-line highlight wash for all three panes: left_blocks
---covers left_view (its `a` side) and the center pane (its `b` side);
---right_blocks covers the center pane again (its `a` side) and
---right_view (its `b` side). The center pane can end up with two
---independent washes from two different neighbors, which is correct --
---a line can simultaneously differ from the left branch and from the
---right branch in different ways, and both are worth showing.
function MergeView:draw_line_highlights()
  local left_x, center_x, right_x, pane_w = self:get_pane_metrics()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  self:draw_line_highlight_blocks(self.left_blocks, "a", self.left_view, left_x, pane_w)
  self:draw_line_highlight_blocks(self.left_blocks, "b", self, center_x, pane_w)
  self:draw_line_highlight_blocks(self.right_blocks, "a", self, center_x, pane_w)
  self:draw_line_highlight_blocks(self.right_blocks, "b", self.right_view, right_x, pane_w)

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

  -- full-line tint over every changed line, drawn on top of the panes'
  -- own content (background + text) so it reads as a translucent wash
  -- over whatever the theme already renders there
  self:draw_line_highlights()

  -- drawn last, on top of the flat divider strips, the line highlights,
  -- and after both panes, so the shapes are never occluded by anything
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
