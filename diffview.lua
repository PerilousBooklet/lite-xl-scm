local core = require "core"
local common = require "core.common"
local style = require "core.style"
local DocView = require "core.docview"
local linediff = require "plugins.scm.linediff"
local ReadDoc = require "plugins.scm.readdoc"

-- FIX: left scrollbar handle remains selected and left scrollbar remains open after mouse leaves
-- FIX: mouse cursor doesn't change when hovering above left scrollbar

---@class plugins.scm.diffview : core.docview
---@field super core.docview
local DiffView = DocView:extend()

---How often (in seconds) to check whether either document changed and,
---if so, recompute the diff-gutter. In the common case (both sides are
---static ReadDoc snapshots) this ends up being a cheap no-op forever
---after the first check; it's still done on a timer rather than once so
---nothing breaks if this view is ever pointed at a live/editable doc.
local DIFF_POLL_INTERVAL = 0.5

---Depth-iterations between internal coroutine.yield() calls inside the
---Myers diff. Only has an effect when running inside a coroutine (i.e.
---always true here, since recompute_diff is only ever called from the
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

---How many lines of context to keep above a block's first changed line
---when navigating to it with goto_next_block/goto_previous_block, so
---the change doesn't land flush against the very top edge of the
---viewport.
local GOTO_BLOCK_MARGIN_LINES = 6

---@param view core.docview
local function disable_minimap(view)
  local sb = view.v_scrollbar
  if sb and sb.is_minimap_enabled then
    sb.enabled = false
  end
end

---@param left_doc core.doc The "base"/older revision (e.g. parent branch)
---@param right_doc core.doc The "current"/newer revision (e.g. current branch)
---@param left_label? string Short label drawn over the left pane
---@param right_label? string Short label drawn over the right pane
function DiffView:new(left_doc, right_doc, left_label, right_label)
  -- this makes `self` behave as a normal DocView bound to right_doc:
  -- same cursor, scrolling, syntax highlighting, etc, all for free.
  DiffView.super.new(self, right_doc)
  disable_minimap(self)

  self.left_view = DocView(left_doc)
  disable_minimap(self.left_view)
  self.left_view.scrollable = true

  self.left_label = left_label or "base"
  self.right_label = right_label or "current"

  -- width of the empty, background-colored strip between the two panes
  self.divider_width = math.ceil(4 * (SCALE or 1)) * 10
  self.divider_color = style.background2

  -- which pane is currently receiving a mouse drag, if any; false means
  -- the right (self) pane
  self.dragging_pane = false
  self.hovered_view = nil

  -- diff-gutter state: blocks are {a1, a2, b1, b2, type} (see
  -- plugins.scm.linediff for the exact convention), diffing
  -- left_view.doc (a) against self.doc (b).
  self.blocks = {}
  self.diff_left_change_id = nil
  self.diff_right_change_id = nil

  -- scroll-sync state: last frame's scroll.to.y for each pane, used by
  -- sync_scrolling() to detect which pane just received new scroll
  -- input this frame (see that function for the full explanation).
  self.prev_scroll_to_y = {
    left = self.left_view.scroll.to.y,
    right = self.scroll.to.y,
  }

  -- Tracks, per pane, the exact value sync_scrolling last *forced* onto
  -- that pane (copied down from whichever pane is driving the group
  -- scroll this frame). Lets us tell "this pane's own scroll clamp
  -- caught up with a value we pushed into it" apart from "this pane
  -- genuinely received new input", without needing to know what that
  -- pane's real maximum scroll actually is -- see sync_scrolling.
  self.forced_scroll_to_y = {}

  -- Set by scroll_to_block; consulted by goto_block to know "which
  -- block are we currently on" without being thrown off by the landing
  -- margin scroll_to_block applies (see goto_block for the full
  -- rationale). last_goto_target_y lets goto_block detect whether the
  -- scroll has moved for some other reason (user input) since our own
  -- last jump, in which case this cached line is stale and shouldn't
  -- be trusted.
  self.last_goto_line = nil
  self.last_goto_target_y = nil

  self:start_diff_thread()
end

function DiffView:get_name()
  return "Diff: " .. (self.doc and self.doc:get_name() or "")
end

--------------------------------------------------------------------------------
-- Diff computation
--------------------------------------------------------------------------------

---Returns doc's current change id, or nil if the doc doesn't expose one
---(older core.doc versions / unusual doc subclasses) -- in that case we
---just recompute unconditionally every poll tick, which is strictly
---safe, just potentially wasteful.
---@param doc core.doc
function DiffView:get_doc_change_id(doc)
  if doc.get_change_id then
    return doc:get_change_id()
  end
  return nil
end

---Recomputes the diff-gutter against both docs' current buffers, if
---either changed since the last time we did this. Safe to call often;
---it's a no-op when nothing changed. Meant to be called from inside a
---coroutine (the background thread started in :new()) so that the
---internal yielding in linediff actually has somewhere to yield to.
function DiffView:recompute_diff()
  local left_id = self:get_doc_change_id(self.left_view.doc)
  local right_id = self:get_doc_change_id(self.doc)

  if
    left_id ~= nil and left_id == self.diff_left_change_id
    and
    right_id ~= nil and right_id == self.diff_right_change_id
  then
    return
  end

  self.blocks = linediff.diff(
    self.left_view.doc.lines, self.doc.lines, DIFF_YIELD_EVERY
  )

  self.diff_left_change_id = left_id
  self.diff_right_change_id = right_id
end

---Starts the per-view background thread that keeps the diff-gutter in
---sync with both docs. Tied to `self` via core.add_thread's
---weak-reference form, so it stops on its own once this view is closed
---and garbage collected -- nothing to clean up by hand.
function DiffView:start_diff_thread()
  core.add_thread(function()
    while true do
      self:recompute_diff()
      coroutine.yield(DIFF_POLL_INTERVAL)
    end
  end, self)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

---Computes the absolute screen x of each of the two columns plus their
---shared width, based on the view's current (full, untouched) bounds.
---@return number left_x, number right_x, number pane_w
function DiffView:get_pane_metrics()
  local dw = self.divider_width
  local pane_w = (self.size.x - dw) / 2
  local left_x = self.position.x
  local right_x = self.position.x + pane_w + dw
  return left_x, right_x, pane_w
end

---Runs fn with self.position.x/self.size.x temporarily narrowed down to
---the right column, so anything DocView does internally (drawing,
---clipping, screen-to-document coordinate math) is confined to it.
function DiffView:with_right_bounds(fn, ...)
  local real_x, real_w = self.position.x, self.size.x
  local _, right_x, pane_w = self:get_pane_metrics()
  self.position.x, self.size.x = right_x, pane_w
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
---*diff correspondence* rather than by raw line number.
---
---`line` lives in a continuous coordinate where integer N means "the
---top of line N" and row N itself spans the half-open interval
---[N, N+1) -- the same convention get_line_edge_y already uses for
---placing diff shapes, just inverted here (screen/scroll position ->
---line, instead of line -> screen position). `from_is_a` selects
---direction: true maps an a-side coordinate to its b-side equivalent,
---false maps b-side to a-side.
---
---Outside any block, both sides advance in lockstep (an "unchanged"
---run), so the mapping there is just a constant additive offset
---carried over from the last block. Inside a block, the two sides can
---have different lengths (e.g. 3 lines replaced by 1), so the position
---is interpolated proportionally across whichever span is nonempty; if
---one side is completely empty (a pure insertion/deletion, per
---linediff's a1>a2 / b1>b2 convention), there's nothing to interpolate
---onto and the point collapses to that side's single edge.
---@param blocks table
---@param from_is_a boolean
---@param line number
---@return number
local function map_line(blocks, from_is_a, line)
  -- continuous coordinate marking "one past the last position already
  -- accounted for" on each side; the offset between them is what a
  -- line in the current unchanged run needs added to it
  local prev_from_end, prev_to_end = 0, 0

  for i = 1, #blocks do
    local block = blocks[i]
    local from1 = from_is_a and block.a1 or block.b1
    local from2 = from_is_a and block.a2 or block.b2
    local to1   = from_is_a and block.b1 or block.a1
    local to2   = from_is_a and block.b2 or block.a2

    local from_lo, from_hi = from1, from2 + 1
    if from1 > from2 then from_hi = from_lo end -- empty from-span

    if line < from_lo then
      -- still in the unchanged run before this block
      return line + (prev_to_end - prev_from_end)
    end

    if line < from_hi then
      -- inside this block's own from-span
      if to1 > to2 then
        -- to-side is empty: nothing to interpolate onto
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

---Positions the left child view inside its own column. Called from
---both update() and draw() so its bounds are always correct before
---anything (including its own internal scrollbar) is computed or drawn
---from it, regardless of call order.
function DiffView:layout_left_pane()
  local left_x, _, pane_w = self:get_pane_metrics()
  self.left_view.position.x, self.left_view.position.y = left_x, self.position.y
  self.left_view.size.x, self.left_view.size.y = pane_w, self.size.y
end

---Converts a view's current scroll.to.y into an equivalent (possibly
---fractional) "line at the top of the viewport" coordinate, in the
---same continuous convention map_line uses.
---@param view core.docview
---@return number
function DiffView:scroll_to_line(view)
  return view.scroll.to.y / view:get_line_height() + 1
end

---Inverse of scroll_to_line: converts a line coordinate back into the
---scroll.to.y that would put it at the top of `view`'s viewport.
---@param view core.docview
---@param line number
---@return number
function DiffView:line_to_scroll(view, line)
  return (line - 1) * view:get_line_height()
end

---Synchronizes vertical scroll across both panes so that whichever
---diff block is at the top of one pane's viewport, the *corresponding*
---lines of that same block are kept at the top of the other pane's
---viewport too -- rather than just keeping both panes at the same raw
---pixel offset, which only stays meaningful up until the first block
---that has a different number of lines on each side. See map_line for
---the actual correspondence logic.
---
---Whenever exactly one pane's scroll.to.y changed this frame due to
---real input (wheel, drag, cursor movement, etc), its line position is
---mapped through self.blocks and written into the other pane. A pane
---holding a shorter document clamps its own scroll.to.y to its own
---ceiling once forced past it, which looks identical to real input
---unless we specifically remember (in self.forced_scroll_to_y) the
---exact value we ourselves wrote into it last frame and exclude
---exactly that transition from counting as a new source (see the
---original writeup of this in a previous revision of this function).
function DiffView:sync_scrolling()
  local panes = {
    { key = "left",  view = self.left_view, is_a = true },
    { key = "right", view = self,           is_a = false },
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
    for _, pane in ipairs(panes) do
      if pane.key ~= source.key then
        local mapped_line = map_line(self.blocks, source.is_a, source_line)
        local target_y = self:line_to_scroll(pane.view, mapped_line)
        pane.view.scroll.y = target_y
        pane.view.scroll.to.y = target_y
        self.forced_scroll_to_y[pane.key] = target_y
      else
        -- driven by real input this frame; nothing forced onto it
        self.forced_scroll_to_y[pane.key] = nil
      end
    end
  end

  for _, pane in ipairs(panes) do
    self.prev_scroll_to_y[pane.key] = pane.view.scroll.to.y
  end
end

function DiffView:update()
  -- lay out the left pane first, using the view's real (full) bounds
  self:layout_left_pane()
  self.left_view:update()

  -- scrollbar geometry is computed here, in update(), and only drawn
  -- later in draw() -- both must use the same (narrowed) bounds, or the
  -- right pane's scrollbar ends up sized/positioned against the full
  -- view width and overlaps the divider when it's actually drawn
  self:with_right_bounds(DiffView.super.update, self)

  -- must run last: both panes have now processed this frame's input,
  -- so whichever one changed is reliably this frame's source
  self:sync_scrolling()
end

---Returns whichever of left_view/self currently has the most lines --
---i.e. whichever one's own natural vertical-scroll clamp reaches
---furthest. Recomputed on demand (not cached), since either doc could
---in principle grow or shrink.
---@return core.docview
function DiffView:get_tallest_view()
  local left_n = #self.left_view.doc.lines
  local right_n = #self.doc.lines
  if left_n >= right_n then
    return self.left_view
  end
  return self
end

--------------------------------------------------------------------------------
-- Diff-block navigation
--------------------------------------------------------------------------------

---Scrolls so that `block`'s first changed line sits a few lines below
---the top of the viewport (see GOTO_BLOCK_MARGIN_LINES), rather than
---flush against the very top edge.
---@param block table
function DiffView:scroll_to_block(block)
  local line = math.max(1, block.b1 - GOTO_BLOCK_MARGIN_LINES)
  local target_y = self:line_to_scroll(self, line)
  self.scroll.y = target_y
  self.scroll.to.y = target_y

  -- Remember the block's own (unclamped, un-margined) start line --
  -- goto_block needs this, not the landing line a few lines above it,
  -- to correctly recognize "we're already sitting on this block" the
  -- next time it's called.
  self.last_goto_line = block.b1
  self.last_goto_target_y = target_y
end

---Moves to the next (direction > 0) or previous (direction < 0) diff
---block relative to the current position.
---@param direction number
function DiffView:goto_block(direction)
  if #self.blocks == 0 then
    core.warn("SCM: no changes to navigate.")
    return
  end

  -- "Current" position for comparison. scroll_to_block deliberately
  -- lands a few lines *above* a block's real start (GOTO_BLOCK_MARGIN_LINES),
  -- so reading the position back via scroll_to_line(self) here would
  -- report a line a few lines short of the block we actually just
  -- landed on -- which made that same block look like it still
  -- qualified as "next" on the very next press (repeatedly re-landing
  -- on it, looking like nothing happened), and often made "previous"
  -- right afterwards find nothing at all. Instead: if the scroll
  -- hasn't moved since our own last jump (self.scroll.to.y still equals
  -- what we set then), use the exact block start line we remembered at
  -- the time. Otherwise (first-ever jump, or the user scrolled manually
  -- in between) fall back to reading the live scroll position, same as
  -- before.
  local current
  if self.last_goto_target_y ~= nil and self.scroll.to.y == self.last_goto_target_y then
    current = self.last_goto_line
  else
    current = self:scroll_to_line(self)
  end

  local target

  if direction > 0 then
    for _, block in ipairs(self.blocks) do
      if block.b1 > current + 0.5 then
        target = block
        break
      end
    end
    if not target then
      core.warn("SCM: no more changes below.")
      return
    end
  else
    for i = #self.blocks, 1, -1 do
      local block = self.blocks[i]
      if block.b1 < current - 0.5 then
        target = block
        break
      end
    end
    if not target then
      core.warn("SCM: no more changes above.")
      return
    end
  end

  self:scroll_to_block(target)
end

function DiffView:goto_next_block()
  self:goto_block(1)
end

function DiffView:goto_previous_block()
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

function DiffView:get_line_edge_y(view, line)
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
function DiffView:draw_diff_shape(x1, x2, y1_top, y1_bot, y2_top, y2_bot, color)
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
function DiffView:draw_diff_blocks(blocks, view_a, view_b, x1, x2)
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

---Draws the diff-gutter (left|right). Called from draw(), after the
---plain divider-color background strip is already down, so these
---shapes sit on top of it.
function DiffView:draw_diff_gutter()
  local left_x, right_x, pane_w = self:get_pane_metrics()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  self:draw_diff_blocks(self.blocks, self.left_view, self, left_x + pane_w, right_x)
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
function DiffView:draw_line_highlight_blocks(blocks, side, view, x, w)
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

---Draws the full-line highlight wash for both panes: left_view gets its
---`a` side of `self.blocks`, the right (self) pane gets the `b` side.
function DiffView:draw_line_highlights()
  local left_x, right_x, pane_w = self:get_pane_metrics()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  self:draw_line_highlight_blocks(self.blocks, "a", self.left_view, left_x, pane_w)
  self:draw_line_highlight_blocks(self.blocks, "b", self, right_x, pane_w)

  core.pop_clip_rect()
end

--------------------------------------------------------------------------------
-- Pane labels
--------------------------------------------------------------------------------

---Draws a small badge with `text` at (x, y). Used to show which
---revision each pane is displaying (e.g. branch/ref name) without
---reserving any layout space for it -- it's just drawn on top of the
---pane's own content in a corner, the same way the blame tooltip in
---init.lua overlays the doc rather than pushing it aside.
local function draw_pane_label(x, y, text)
  local font = style.font
  local pad = style.padding.x * 0.5
  local tw = font:get_width(text)
  local th = font:get_height()

  renderer.draw_rect(x, y, tw + pad * 2, th + pad * 2, style.background3)
  common.draw_text(font, style.accent, text, "left", x + pad, y + pad, tw, th)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

function DiffView:draw()
  self:draw_background(style.background)
  self:layout_left_pane()

  local left_x, right_x, pane_w = self:get_pane_metrics()

  -- empty, background-colored strip between the two columns, drawn
  -- *before* the panes so nothing a pane draws near its own edge (in
  -- particular its scrollbar) can end up underneath it
  local dw = self.divider_width
  renderer.draw_rect(left_x + pane_w, self.position.y, dw, self.size.y, self.divider_color)

  self.left_view:draw()
  self:with_right_bounds(DiffView.super.draw, self)

  -- full-line tint over every changed line, drawn on top of the panes'
  -- own content (background + text) so it reads as a translucent wash
  -- over whatever the theme already renders there
  self:draw_line_highlights()

  -- drawn after both panes and the line highlights, on top of the flat
  -- divider strip, so the shapes are never occluded by anything
  self:draw_diff_gutter()

  -- labels drawn last of all, in the corner of each pane, on top of
  -- everything including the diff-gutter shapes
  local margin = style.padding.y * 0.5
  draw_pane_label(left_x + margin, self.position.y + margin, self.left_label)
  draw_pane_label(right_x + margin, self.position.y + margin, self.right_label)
end

--------------------------------------------------------------------------------
-- Input handling
--------------------------------------------------------------------------------

-- FIX: left view mouse input

function DiffView:on_mouse_moved(x, y, dx, dy)
  DiffView.super.on_mouse_moved(self, x, y, dx, dy)

  local left_x, right_x, pane_w = self:get_pane_metrics()
  if point_in(x, y, left_x, self.position.y, pane_w, self.size.y) then
    self.hovered_view = self.left_view
  else
    self.hovered_view = nil -- right pane, i.e. self
  end

  if self.dragging_pane == "left" then
    self.left_view:on_mouse_moved(x, y, dx, dy)
  elseif self.hovered_view then
    self.hovered_view:on_mouse_moved(x, y, dx, dy)
  end
end

function DiffView:on_mouse_pressed(button, x, y, clicks)
  local left_x, right_x, pane_w = self:get_pane_metrics()

  if point_in(x, y, left_x, self.position.y, pane_w, self.size.y) then
    self.dragging_pane = "left"
    core.set_active_view(self)
    return self.left_view:on_mouse_pressed(button, x, y, clicks)
  end

  self.dragging_pane = false
  return self:with_right_bounds(DiffView.super.on_mouse_pressed, self, button, x, y, clicks)
end

function DiffView:on_mouse_released(button, x, y)
  if self.dragging_pane == "left" then
    self.left_view:on_mouse_released(button, x, y)
  else
    self:with_right_bounds(DiffView.super.on_mouse_released, self, button, x, y)
  end
  self.dragging_pane = false
end

function DiffView:on_mouse_wheel(...)
  -- Vertical scrolling is always driven off whichever of the two panes
  -- holds the taller document, never off whichever pane happens to be
  -- under the cursor -- same reasoning (and the same horizontal-scroll
  -- trade-off) as MergeView:on_mouse_wheel.
  local reference_view = self:get_tallest_view()

  if reference_view == self then
    return self:with_right_bounds(DiffView.super.on_mouse_wheel, self, ...)
  end
  return reference_view:on_mouse_wheel(...)
end

function DiffView:on_text_input(...)
  -- both docs are expected to be read-only (plugins.scm.readdoc), so
  -- this is a no-op in practice; forwarded to the right pane anyway so
  -- this view still behaves reasonably if ever pointed at a live doc
  DiffView.super.on_text_input(self, ...)
end

--------------------------------------------------------------------------------
-- Convenience opener
--------------------------------------------------------------------------------

---Opens a DiffView for a single file, comparing its contents at
---`base_ref` (e.g. the parent/base branch) against `compare_ref` (e.g.
---the current branch or a specific commit). Both sides are fetched
---through the backend and shown as read-only virtual buffers, so this
---is safe to use even while the working tree has uncommitted changes --
---neither pane is the on-disk file.
---
---If `compare_ref` is omitted, the right pane instead shows whatever is
---currently on disk at `path`, read directly rather than through the
---backend -- handy for "diff my working copy against the parent branch"
---without needing a ref name for "right now".
---@param path string Absolute path of the file to diff
---@param project_dir string
---@param backend plugins.scm.backend
---@param base_ref string e.g. the parent/base branch name, or a commit/tag
---@param compare_ref? string e.g. the current branch name or a commit/tag
function DiffView.open(path, project_dir, backend, base_ref, compare_ref)
  local base = common.basename(path)

  local function show(base_text, compare_text)
    local left_title = string.format("[%s] %s", base_ref, base)
    ---@type plugins.scm.readdoc
    local left_doc = ReadDoc(left_title, left_title)
    left_doc:set_text(base_text or "")

    local right_label = compare_ref or "working copy"
    local right_title = string.format("[%s] %s", right_label, base)
    ---@type plugins.scm.readdoc
    local right_doc = ReadDoc(right_title, right_title)
    right_doc:set_text(compare_text or "")

    local view = DiffView(left_doc, right_doc, base_ref, right_label)
    local node = core.root_view:get_active_node_default()
    node:add_view(view)
  end

  backend:get_file_at_ref(path, base_ref, project_dir, function(base_text)
    if compare_ref then
      backend:get_file_at_ref(path, compare_ref, project_dir, function(compare_text)
        show(base_text, compare_text)
      end)
    else
      local file = io.open(path, "r")
      local compare_text = file and file:read("*a") or ""
      if file then file:close() end
      show(base_text, compare_text)
    end
  end)
end

return DiffView
