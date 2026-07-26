-- Line-level diff between two arrays of strings using the Myers diff
-- algorithm (the same algorithm behind `diff`/git). Produces a list of
-- contiguous change blocks rather than a raw edit script, since that's
-- what a gutter renderer wants to draw.
local linediff = {}

---Computes the Myers edit graph trace for `a` vs `b`.
---@param a table array of lines (1-indexed)
---@param b table array of lines (1-indexed)
---@return table trace, integer d
---@param yield_every integer|nil call coroutine.yield() roughly every
---  this many depth iterations, so a large/expensive diff computed from
---  inside a core.add_thread body doesn't stall the editor. Pass nil/0
---  to disable.
local function shortest_edit(a, b, yield_every)
  local n, m = #a, #b
  local max = n + m
  local v = { [1] = 0 }
  local trace = {}
  local can_yield = yield_every and yield_every > 0 and coroutine.isyieldable()

  for d = 0, max do
    if can_yield and d > 0 and d % yield_every == 0 then
      coroutine.yield()
    end

    -- snapshot v as it stands *before* this depth's updates, indexed by d
    local vcopy = {}
    for k, val in pairs(v) do vcopy[k] = val end
    trace[d] = vcopy

    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[k - 1] or 0) < (v[k + 1] or 0)) then
        x = v[k + 1] or 0
      else
        x = (v[k - 1] or 0) + 1
      end
      local y = x - k

      while x < n and y < m and a[x + 1] == b[y + 1] do
        x = x + 1
        y = y + 1
      end

      v[k] = x

      if x >= n and y >= m then
        -- store the final state too so backtrack can see depth `d`
        local vfinal = {}
        for kk, vv in pairs(v) do vfinal[kk] = vv end
        trace[d + 1] = vfinal
        return trace, d
      end
    end
  end
end

---Backtracks the trace into a list of ops: {tag = "keep"|"del"|"ins", a = line_in_a_or_nil, b = line_in_b_or_nil}
---in forward order.
local function backtrack(a, b, trace, d)
  local n = #a
  local x, y = n, #b
  local ops = {}

  for depth = d, 0, -1 do
    local v = trace[depth + 1]
    if not v then goto continue end
    local k = x - y

    local prev_k
    if k == -depth or (k ~= depth and (v[k - 1] or 0) < (v[k + 1] or 0)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end

    local prev_v = trace[depth]
    local prev_x = prev_v and (prev_v[prev_k] or 0) or 0
    local prev_y = prev_x - prev_k

    while x > prev_x and y > prev_y do
      table.insert(ops, 1, { tag = "keep", a = x, b = y })
      x, y = x - 1, y - 1
    end

    if depth > 0 then
      if x == prev_x then
        table.insert(ops, 1, { tag = "ins", a = nil, b = y })
      else
        table.insert(ops, 1, { tag = "del", a = x, b = nil })
      end
      x, y = prev_x, prev_y
    end

    ::continue::
  end

  return ops
end

---Diffs two arrays of lines.
---@param a table array of strings
---@param b table array of strings
---@param yield_every integer|nil see shortest_edit
---@return table ops list of {tag, a, b} in forward document order
function linediff.compute_ops(a, b, yield_every)
  if #a == 0 and #b == 0 then return {} end
  local trace, d = shortest_edit(a, b, yield_every)
  return backtrack(a, b, trace, d)
end

---Groups a raw op list into contiguous change blocks, pairing up
---consecutive del+ins runs into "modification" blocks (same convention
---plugins.scm.changes already uses for git hunks), leaving pure runs as
---"addition"/"deletion". Unchanged lines are dropped.
---@param ops table
---@return table blocks list of {a1, a2, b1, b2, type}
---  a1/a2: inclusive 1-based line range in `a` touched by the block
---         (a1 > a2 means "no lines", i.e. a pure addition)
---  b1/b2: inclusive 1-based line range in `b` touched by the block
---         (b1 > b2 means "no lines", i.e. a pure deletion)
function linediff.group_blocks(ops)
  local blocks = {}
  local i = 1
  local n = #ops

  while i <= n do
    if ops[i].tag == "keep" then
      i = i + 1
    else
      local dels, inserts = {}, {}
      while i <= n and ops[i].tag ~= "keep" do
        if ops[i].tag == "del" then
          table.insert(dels, ops[i].a)
        else
          table.insert(inserts, ops[i].b)
        end
        i = i + 1
      end

      local a1, a2
      if #dels > 0 then
        a1, a2 = dels[1], dels[#dels]
      else
        -- pure addition: anchor the (empty) range at the point of
        -- insertion, i.e. right after the last kept line in `a`
        local anchor = 0
        for j = i - 1, 1, -1 do
          if ops[j].tag == "keep" then anchor = ops[j].a; break end
        end
        a1, a2 = anchor + 1, anchor
      end

      local b1, b2
      if #inserts > 0 then
        b1, b2 = inserts[1], inserts[#inserts]
      else
        local anchor = 0
        for j = i - 1, 1, -1 do
          if ops[j].tag == "keep" then anchor = ops[j].b; break end
        end
        b1, b2 = anchor + 1, anchor
      end

      local btype
      if #dels > 0 and #inserts > 0 then
        btype = "modification"
      elseif #inserts > 0 then
        btype = "addition"
      else
        btype = "deletion"
      end

      table.insert(blocks, { a1 = a1, a2 = a2, b1 = b1, b2 = b2, type = btype })
    end
  end

  return blocks
end

---Convenience: diff two line arrays directly into grouped blocks.
---@param a table
---@param b table
---@param yield_every integer|nil see shortest_edit; pass e.g. 64 when
---  calling from inside a core.add_thread body on possibly-large files
---@return table blocks
function linediff.diff(a, b, yield_every)
  local ops = linediff.compute_ops(a, b, yield_every)
  return linediff.group_blocks(ops)
end

return linediff
