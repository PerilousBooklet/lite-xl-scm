-- mod-version:3
--
-- Source Control Management plugin.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
-- Note: Some ideas and bits taken from:
-- https://github.com/vincens2005/lite-xl-gitdiff-highlight
-- https://github.com/lite-xl/lite-xl-plugins/blob/master/plugins/gitstatus.lua
-- Thanks to everyone involved!
--
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local util = require "plugins.scm.util"
local changes = require "plugins.scm.changes"
local Doc = require "core.doc"
local DocView = require "core.docview"
local StatusView = require "core.statusview"
local ReadDoc = require "plugins.scm.readdoc"
local Git = require "plugins.scm.backend.git"
local Fossil = require "plugins.scm.backend.fossil"
local MessageBox = require "libraries.widget.messagebox"
local MergeView = require "plugins.scm.mergeview"
local DiffView = require "plugins.scm.diffview"

-- WIP: intellij-like gitblame

-- FIX: scm: add a space between each diff-stdout-dump text-block in the diff view, for clarity
-- FIX: project status is not colored (look at the diff)
-- FIX: show history is not colored (look at the diff)

-- TODO: add contextmenu item for diffview
-- TODO: replace all readdoc views with custom View that simply draws text

-- TODO: color the "branch-name +n / ~n / -n" in the statusview with green-yellow-red colors
-- TODO: add `scm:scroll-changes`: run a command that gets the list of current file's changes and allows traversing all changes
--       (just like the default search command)
-- TODO: interactive hunk add
-- TODO: detect if file belongs to submodule and show the submodule's data instead of the super-repo

-- TODO: interactive `git add` (fundamental for many files, maybe with long paths)
--  - TODO: add new tab with treeview ?
--          (navigate treeview with arrows)
--          (press tab to view file diff)
--          (press enter to stage file/folder)
-- NOTE: take inspiration from the following:
-- NOTE: https://zed.dev/git
-- NOTE: https://www.sublimetext.com/
-- NOTE: https://www.sublimemerge.com/

-- REVIEW: remove unnecessary comments
-- REVIEW: full code review

---Backends shipped with the plugin.
---@type table<string,plugins.scm.backend>
local BACKENDS

---@class config.plugins.smc
---@field highlighter boolean
---@field highlighter_alignment "right" | "left"
---@field git_path string
---@field fossil_path string
---@field inline_blame_max_author_length integer
---@field inline_blame_padding integer
config.plugins.smc = common.merge({
  highlighter = true,
  highlighter_alignment = "right",
  git_path = "git",
  fossil_path = "fossil",
  inline_blame_max_author_length = 12,
  inline_blame_padding = 15,
  config_spec = {
    name = "Source Control Management",
    {
      label = "Highlighter",
      description = "Display or hide the changes highlighter from the gutter.",
      path = "highlighter",
      type = "toggle",
      default = true
    },
    {
      label = "Highlighter Alignment",
      description = "The position on the gutter to draw the changes highlighter.",
      path = "highlighter_alignment",
      type = "selection",
      default = "left",
      values = {
        {"Left", "left"},
        {"Right", "right"}
      }
    },
    {
      label = "Inline Blame Max Author Length",
      description = "Truncate author names in the inline blame annotation longer than this many characters.",
      path = "inline_blame_max_author_length",
      type = "number",
      default = 12,
      min = 1
    },
    {
      label = "Inline Blame Padding",
      description = "Extra pixel spacing between the inline blame annotation and the line number.",
      path = "inline_blame_padding",
      type = "number",
      default = 15,
      min = 0
    },
    {
      label = "Git Path",
      description = "Path to the Git binary.",
      path = "git_path",
      type = "FILE",
      default = "git",
      filters = {"git$", "git%.exe$"},
      on_apply = function(value)
        if not BACKENDS.Git:set_command(value) then
          BACKENDS.Git:set_command(common.basename(value))
        end
      end
    },
    {
      label = "Fossil Path",
      description = "Path to the Fossil binary.",
      path = "fossil_path",
      type = "FILE",
      default = "fossil",
      filters = {"fossil$", "fossil%.exe$"},
      on_apply = function(value)
        if not BACKENDS.Fossil:set_command(value) then
          BACKENDS.Fossil:set_command(common.basename(value))
        end
      end
    }
  }
}, config.plugins.smc)

-- initialize backends
BACKENDS = { Git = Git(), Fossil = Fossil() }
BACKENDS.Git:set_command(config.plugins.smc.git_path)
BACKENDS.Fossil:set_command(config.plugins.smc.fossil_path)

---@class plugins.scm.filechange : plugins.scm.backend.filechange
---@field color renderer.color?
---@field text string?

---@class plugins.scm
local scm = {}

---Show the blame information of active line.
---@type boolean
scm.show_blame = false

---Show an IntelliJ-style inline blame annotation ("date author") in the
---gutter before the line number, for every line at once -- as opposed
---to scm.show_blame, which only shows blame for the line under the
---cursor, on hover, as a tooltip. Both draw from the same underlying
---backend:get_file_blame data (see update_doc_blame), so turning either
---one on is enough to trigger the fetch; data isn't cleared until both
---are off.
---@type boolean
scm.show_inline_blame = false

---List of loaded projects current branch.
---@type table<string, string>
local BRANCHES = {}

---List of loaded projects current stats.
---@type table<string, plugins.scm.backend.stats>
local STATS = {}

---List of loaded project changes.
---@type table<string,table<string,plugins.scm.filechange>>
local CHANGES = {}

---Opened projects SCM backends list
---@type table<string,plugins.scm.backend>
local PROJECTS = {}
setmetatable(PROJECTS, {
  __index = function(t, k)
    if k == nil then return nil end
    local v = rawget(t, k)
    if v == nil then
      for _, backend in pairs(BACKENDS) do
        if backend:detect(k) then
          v = backend
          backend:get_branch(k, function(branch)
            BRANCHES[k] = branch
            backend:get_stats(k, function(stats) STATS[k] = stats end)
          end)
          if backend.name == "Fossil" then
            table.insert(config.ignore_files, "%-shm$")
            table.insert(config.ignore_files, "%-wal$")
          end
          rawset(t, k, v)
        end
      end
    end
    return v
  end
})

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
---@param doc core.doc
local function update_doc_diff(doc)
  if doc.abs_filename then
    local project_dir = util.get_file_project_dir(doc.abs_filename)
    if project_dir and PROJECTS[project_dir] then
      local backend = PROJECTS[project_dir]
      backend:get_file_diff(doc.abs_filename, project_dir, function(diff)
        if diff and diff ~= "" then
          local parsed_diff = changes.parse(diff)
          doc.scm_diff = nil
          for _, _ in pairs(parsed_diff) do
            doc.scm_diff = parsed_diff
            break
          end
        else
          doc.scm_diff = nil
        end
      end)
      return
    end
  end
  doc.scm_diff = nil
end

---Computes the pixel width of the widest "date author" annotation
---across every line in `list`, using the same truncation the inline
---blame gutter drawing applies -- so the gutter can reserve exactly
---enough space up front instead of guessing at a fixed sample string.
---A fixed guess would have to assume a specific date format, which
---isn't under this plugin's control: it's whatever the backend's
---get_file_blame happens to produce, and that can differ between Git
---and Fossil (or between Git configurations).
---@param list table
---@return number
local function compute_inline_blame_width(list)
  local font = style.code_font
  local max_author_length = config.plugins.smc.inline_blame_max_author_length
  local width = 0
  for _, info in ipairs(list) do
    local author = util.truncate(info.author or "", max_author_length)
    local text = string.format("%s %s", info.date or "", author)
    width = math.max(width, font:get_width(text))
  end
  return width
end

---@param doc core.doc
local function update_doc_blame(doc)
  if not (scm.show_blame or scm.show_inline_blame) then
    if doc.blame_list then doc.blame_list = nil end
    if doc.blame_inline_width then doc.blame_inline_width = nil end
    return
  end
  if doc.abs_filename then
    local project_dir = util.get_file_project_dir(doc.abs_filename)
    if project_dir and PROJECTS[project_dir] then
      local backend = PROJECTS[project_dir]
      backend:get_file_blame(doc.abs_filename, project_dir, function(list)
        if list and #list > 0 then
          doc.blame_list = list
          doc.blame_inline_width = compute_inline_blame_width(list)
        else
          doc.blame_list = nil
          doc.blame_inline_width = nil
        end
      end)
      return
    end
  end
  if doc.blame_list then doc.blame_list = nil end
  if doc.blame_inline_width then doc.blame_inline_width = nil end
end

---@param path string
---@param nonblocking? boolean
local function update_doc_status(path, nonblocking)
  local project_dir = util.get_file_project_dir(path)
  local backend = PROJECTS[project_dir]
  if backend then
    if not nonblocking then backend:set_blocking_mode(true) end
    backend:get_file_status(path, project_dir, function(status)
      if status and status ~= "" then
        local color
        if status == "added" then
          color = style.good
        elseif status == "edited" then
          color = style.warn
        elseif status == "renamed" then
          color = style.warn
        elseif status == "deleted" then
          color = style.error
        elseif status == "untracked" then
          color = style.dim
        end
        if color then
          if not CHANGES[project_dir] then CHANGES[project_dir] = {} end
          CHANGES[project_dir][path] = {
            path = path,
            color = color,
            status = status
          }
        else
          if CHANGES[project_dir] and CHANGES[project_dir][path] then
            CHANGES[project_dir][path] = nil
          end
        end
      end
    end)
    if not nonblocking then backend:set_blocking_mode(true) end
  end
end

--------------------------------------------------------------------------------
-- Source Control Management API
--------------------------------------------------------------------------------
---Get a file branch or current project branch if no file given.
---@param abs_filename? string
---@return string?
function scm.get_branch(abs_filename)
  local project = util.get_project_dir(abs_filename)
  return BRANCHES[project]
end

---Get current project insert and delete stats.
---@return plugins.scm.backend.stats?
function scm.get_stats()
  local project = util.get_current_project()
  return STATS[project]
end

---Get current project scm backend
---@return plugins.scm.backend?
function scm.get_backend()
  local project = util.get_current_project()
  return PROJECTS[project]
end

---@param path string
---@param is_changed? boolean Only get backend if file has changed
---@param is_tracked? boolean Only get backend if file is tracked
---@return plugins.scm.backend?
function scm.get_path_backend(path, is_changed, is_tracked)
  local project_dir = util.get_project_dir(path)
  if project_dir then
    if is_changed then
      if CHANGES[project_dir] and CHANGES[project_dir][path] then
        if is_tracked then
          if
            CHANGES[project_dir][path].status
            and
            CHANGES[project_dir][path].status == "untracked"
          then
            return nil
          end
        end
        return PROJECTS[project_dir]
      end
    else
      local backend = PROJECTS[project_dir]
      if is_tracked and backend then
        ---@type plugins.scm.backend.filestatus
        local status
        backend:set_blocking_mode(true)
        backend:get_file_status(path, project_dir, function(file_status)
          status = file_status
        end)
        backend:set_blocking_mode(false)
        if status == "untracked" then return nil end
      end
      return backend
    end
  end
  return nil
end

---@return plugins.scm.backend.filestatus
function scm.get_path_status(path)
  local backend = scm.get_path_backend(path)
  local project_dir = util.get_project_dir(path)
  if backend and project_dir then
    local status
    backend:set_blocking_mode(true)
    backend:get_file_status(path, project_dir, function(file_status)
      status = file_status
    end)
    backend:set_blocking_mode(false)
    return status
  end
  return "untracked"
end

---@return plugins.scm.filechange?
function scm.get_path_changes(path)
  local project_dir = util.get_project_dir(path)
  if CHANGES[project_dir] and CHANGES[project_dir][path] then
    return CHANGES[project_dir] and CHANGES[project_dir][path]
  end
  return nil
end

---@return boolean
function scm.is_staged(path)
  local backend = scm.get_path_backend(path)
  local project_dir = util.get_project_dir(path)
  if backend and project_dir then
    if CHANGES[project_dir] and CHANGES[project_dir][path] then
      if
        CHANGES[project_dir][path].path
        and
        CHANGES[project_dir][path].new_path
        and
        not system.get_file_info(CHANGES[project_dir][path].path)
        and
        system.get_file_info(CHANGES[project_dir][path].new_path)
      then
        path = CHANGES[project_dir][path].new_path
      else
        return CHANGES[project_dir][path].staged
      end
    end
    local staged_files
    local path_rel = common.relative_path(project_dir, path)
    backend:set_blocking_mode(true)
    backend:get_staged(project_dir, function(files)
      staged_files = files
    end)
    backend:set_blocking_mode(false)
    if staged_files[path_rel] then return true end
  end
  return false
end

---Check if the given project path is source control managed.
---@param path string
---@return boolean
function scm.is_scm_project(path)
  for _, project in ipairs(core.project_directories) do
    if path == project.name and PROJECTS[path] then
      return true
    end
  end
  return false
end

---Add a new SCM backend.
---@param backend plugins.scm.backend
function scm.register_backend(backend)
  BACKENDS[backend.name] = backend
end

---Remove an existing SCM backend.
---@param name string
function scm.unregister_backend(name)
  BACKENDS[name] = nil
end

---@param project_dir? string
function scm.open_diff(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_diff(project_dir, function(diff)
      if diff and diff ~= "" then
        local title = "[CHANGES].diff"
          ---@type plugins.scm.readdoc
          local diffdoc = ReadDoc(title, title)
          diffdoc:set_text(diff)
          core.root_view:open_doc(diffdoc)
      else
        core.warn("SCM: no changes detected.")
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

function scm.open_path_diff(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if backend then
    local path_rel = common.relative_path(project_dir, path)
    backend:get_file_diff(path, project_dir, function(diff)
      if diff and diff ~= "" then
        local title = string.format("%s.diff", path_rel)
        ---@type plugins.scm.readdoc
        local diffdoc = ReadDoc(title, title)
        diffdoc:set_text(diff)
        core.root_view:open_doc(diffdoc)
      else
        local info = system.get_file_info(path)
        if info and info.type == "file" then
          core.warn("SCM: seems like the file is untracked.")
        else
          core.warn("SCM: seems like the path only contains untracked files.")
        end
      end
    end)
  end
end

function scm.open_commit_diff(commit, project_dir)
  local backend = PROJECTS[project_dir]
  if backend then
    core.log("SCM: generating the diff please wait...")
    backend:get_commit_diff(commit, project_dir, function(diff)
      if diff and diff ~= "" then
        local title = string.format("[%s].diff", commit)
        ---@type plugins.scm.readdoc
        local diffdoc = ReadDoc(title, title)
        diffdoc:set_text(diff)
        core.root_view:open_doc(diffdoc)
      else
        core.warn("SCM: could not retrieve the commit diff.")
      end
    end)
  end
end

---@param project_dir? string
function scm.open_project_status(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_status(project_dir, function(status)
      if status and status ~= "" then
        local title = "Project Status"
          ---@type plugins.scm.readdoc
          local doc = ReadDoc(title, title)
          doc:set_text(status)
          core.root_view:open_doc(doc)
      else
        core.warn("SCM: no status to report.")
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir string
function scm.pull(project_dir)
  local backend = PROJECTS[project_dir]
  if backend then
    backend:pull(project_dir, function(success, errmsg)
      if success then
        core.log("SCM: pulled latest changes for '%s'", project_dir)
      else
        core.error("SCM: failed to pull '%s', %s", project_dir, errmsg)
      end
    end)
  end
end

---@param path string
function scm.revert_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    MessageBox.warning(
      "SCM Restore File",
      {
        "Do you really want to revert local changes?\n\n",
        "File: " .. path_rel
      },
      function(_, button_id)
        if button_id == 1 then
          backend:revert_file(path, project_dir, function(success, errmsg)
            if success then
              core.log("SCM: file '%s' changes reverted", path_rel)
              update_doc_status(path)
              util.reload_doc(path)
            else
              core.error("SCM: failed reverting '%s', %s", path_rel, errmsg)
            end
          end)
        end
      end,
      MessageBox.BUTTONS_YES_NO
    )
  end
end

---@param path string
function scm.add_path(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    backend:add_path(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' added", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed adding '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@param path string
function scm.remove_path(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    backend:remove_path(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' removed", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed removing '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@field from string
---@field to string
---@field callback fun(oldname:string, newname:string):any
function scm.move_path(from, to, callback)
  local project_dir = util.get_project_dir(from)
  local backend = PROJECTS[project_dir]
  local moved = false
  if
    backend and common.path_belongs_to(from, project_dir)
    and
    common.path_belongs_to(to, project_dir)
  then
    local from_rel = common.relative_path(project_dir, from)
    local to_rel = common.relative_path(project_dir, to)
    backend:set_blocking_mode(true)
    backend:move_path(from, to, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' moved to '%s'", from_rel, to_rel)
        update_doc_status(to, true)
      else
        core.error(
          "SCM: failed moving '%s' to '%s' with: %s",
          from_rel, to_rel, errmsg
        )
      end
    end)
    backend:set_blocking_mode(false)
  end
  if system.get_file_info(to) then
    return true
  end
  return callback(from, to)
end

---@param path string
function scm.stage_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend and backend:has_staging() then
    local path_rel = common.relative_path(project_dir, path)
    backend:stage_file(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' staged", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed staging '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@param path string
function scm.unstage_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend and backend:has_staging() then
    local path_rel = common.relative_path(project_dir, path)
    backend:unstage_file(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' unstaged", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed unstaging '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---Go to next change in a file.
---@param doc? core.doc
function scm.next_change(doc)
  doc = doc or util.get_current_doc()
	if not doc or not doc.scm_diff then return end
	local line, col = doc:get_selection()

	while doc.scm_diff[line] do
		line = line + 1
	end

	while line < #doc.lines do
		if doc.scm_diff[line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line + 1
	end
end

---Go to previous change in a file.
---@param doc? core.doc
function scm.previous_change(doc)
	doc = doc or util.get_current_doc()
	if not doc or not doc.scm_diff then return end
	local line, col = doc:get_selection()

	while doc.scm_diff[line] do
		line = line - 1
	end

	while line > 0 do
		if doc.scm_diff[line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line - 1
	end
end

---Update the SCM status of all open projects.
function scm.update()
  for project_dir, project_backend in pairs(PROJECTS) do
    project_backend:get_branch(project_dir, function(branch, cached)
      if not cached then BRANCHES[project_dir] = branch end

      project_backend:get_stats(project_dir, function(stats, cached)
        if not cached then STATS[project_dir] = stats end

        project_backend:get_changes(project_dir, function(filechanges, cached)
          if cached then return end
          local changed_files = {}
          for i, change in ipairs(filechanges) do
            local color = style.modified
            if change.status == "added" then
              color = style.good
            elseif change.status == "edited" then
              color = style.warn
            elseif change.status == "renamed" then
              color = style.warn
            elseif change.status == "deleted" then
              color = style.error
            elseif change.status == "untracked" then
              color = style.dim
            end
            change.color = color
            local path = ""
            if change.new_path then
              change.text = common.basename(change.path)
                .. " -> "
                .. common.basename(change.new_path)
              changed_files[change.new_path] = change
              path = common.dirname(change.new_path)
            else
              changed_files[change.path] = change
              path = common.dirname(change.path)
            end
            while path do
              if #path < #project_dir then break end
              changed_files[path] = { color = style.modified }
              path = common.dirname(path)
            end
            if i % 10 == 0 then
              coroutine.yield()
            end
          end
          CHANGES[project_dir] = changed_files
        end)
      end)
    end)
  end
end

--------------------------------------------------------------------------------
-- Merge support
--------------------------------------------------------------------------------

---Opens a MergeView for a single file: left/right panes show the file as
---it exists on the origin/destination branches (virtual, read-only
---buffers), and the center pane is the real, on-disk file opened
---normally, so it's fully editable/saveable like any other doc.
---@param path string Absolute path of the file to review
---@param project_dir string
---@param backend plugins.scm.backend
---@param origin string Origin branch name
---@param destination string Destination branch name
function scm.open_merge_view(path, project_dir, backend, origin, destination)
  backend:get_file_at_ref(path, origin, project_dir, function(origin_text)
    backend:get_file_at_ref(path, destination, project_dir, function(destination_text)
      local base = common.basename(path)

      -- keep the real extension at the very end of the title (branch
      -- name goes as a prefix instead) so Lite XL's syntax detection,
      -- which matches file extensions anchored to the end of the
      -- filename, still picks the right highlighter for these virtual
      -- buffers -- same trick already used by open_diff/open_path_diff.
      local origin_title = string.format("[%s] %s", origin, base)
      ---@type plugins.scm.readdoc
      local origin_doc = ReadDoc(origin_title, origin_title)
      origin_doc:set_text(origin_text or "")

      local destination_title = string.format("[%s] %s", destination, base)
      ---@type plugins.scm.readdoc
      local destination_doc = ReadDoc(destination_title, destination_title)
      destination_doc:set_text(destination_text or "")

      -- the real file, currently sitting mid-merge on disk (possibly
      -- with conflict markers); opened the normal way so editing/saving
      -- behaves exactly like any other doc in the editor.
      local center_doc = core.open_doc(path)

      -- center pane is the destination branch's on-disk file with the
      -- merge already applied (see perform_merge: checkout destination,
      -- then merge origin into it without committing) -- "(working
      -- copy)" makes that distinction from the read-only destination
      -- snapshot on the right clear at a glance.
      local center_label = string.format("%s (working copy)", destination)

      local view = MergeView(origin_doc, center_doc, destination_doc, origin, destination, center_label)
      local node = core.root_view:get_active_node_default()
      node:add_view(view)
    end)
  end)
end

---Checks out the destination branch, merges the origin branch into it
---without committing (leaving conflicts, if any, in the working tree),
---then opens a MergeView tab for every file the merge touched.
---@param project_dir string
---@param backend plugins.scm.backend
---@param destination string
---@param origin string
function scm.perform_merge(project_dir, backend, destination, origin)
  core.log("SCM: checking out '%s'...", destination)
  backend:checkout_branch(destination, project_dir, function(checkout_success, checkout_errmsg)
    if not checkout_success then
      core.error("SCM: could not checkout '%s': %s", destination, checkout_errmsg)
      return
    end

    core.log("SCM: merging '%s' into '%s'...", origin, destination)
    backend:merge_branch(origin, project_dir, function(merge_success, merge_msg)
      if not merge_success then
        core.error("SCM: merge failed: %s", merge_msg)
        return
      end

      backend:get_changes(project_dir, function(file_changes)
        if #file_changes == 0 then
          core.log("SCM: merge completed, no file differences to review.")
          return
        end

        core.log("SCM: %d file(s) to review.", #file_changes)
        for _, change in ipairs(file_changes) do
          scm.open_merge_view(change.path, project_dir, backend, origin, destination)
        end
      end)
    end)
  end)
end

---Starts an interactive merge: prompts for the destination branch, then
---the origin branch (both with fuzzy-matched branch lists), and hands off
---to scm.perform_merge.
---@param project_dir? string
function scm.start_merge(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]

  if not backend then
    core.error("SCM: current project directory is not versioned.")
    return
  end

  backend:get_branches(project_dir, function(branches)
    if not branches or #branches == 0 then
      core.error("SCM: no branches found, or backend does not support merging.")
      return
    end

    core.command_view:enter("Merge into branch (destination)", {
      submit = function(text, item)
        local destination = item and item.text or text
        core.command_view:enter("Merge from branch (origin)", {
          submit = function(text2, item2)
            local origin = item2 and item2.text or text2
            scm.perform_merge(project_dir, backend, destination, origin)
          end,
          suggest = function(text2)
            return common.fuzzy_match(branches, text2)
          end
        })
      end,
      suggest = function(text)
        return common.fuzzy_match(branches, text)
      end
    })
  end)
end

--------------------------------------------------------------------------------
-- Diff support
--------------------------------------------------------------------------------

---Prompts for a branch to compare against (fuzzy-matched, same UX as
---the first prompt of scm.start_merge), then opens a DiffView comparing
---`path`'s current on-disk contents against its contents on the chosen
---branch. Unlike scm.open_path_diff (which dumps the raw `.diff` text
---for whatever is currently staged/unstaged), this always compares
---against a branch of the user's choosing and renders the comparison
---side by side rather than as a patch.
---@param path string
function scm.open_file_diff_view(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]

  if not project_dir or not backend then
    core.error("SCM: current project directory is not versioned.")
    return
  end

  backend:get_branches(project_dir, function(branches)
    if not branches or #branches == 0 then
      core.error("SCM: no branches found, or backend does not support this.")
      return
    end

    core.command_view:enter("Diff against branch", {
      submit = function(text, item)
        local base_ref = item and item.text or text
        -- compare_ref intentionally omitted: DiffView.open then reads
        -- the file straight off disk for the right-hand pane, so this
        -- always reflects the file exactly as it is right now,
        -- including any uncommitted local changes.
        DiffView.open(path, project_dir, backend, base_ref)
      end,
      suggest = function(text)
        return common.fuzzy_match(branches, text)
      end
    })
  end)
end

--------------------------------------------------------------------------------
-- Keep the project branch, changes and stats updated
--------------------------------------------------------------------------------
core.add_thread(function()
  while true do
    scm.update()
    coroutine.yield(1)
  end
end)

--------------------------------------------------------------------------------
-- Override Doc to register diff changes and blame history
--------------------------------------------------------------------------------
local doc_save = Doc.save
function Doc:save(...)
  doc_save(self, ...)
  update_doc_diff(self)
  update_doc_blame(self)
end

local doc_new = Doc.new
function Doc:new(...)
  doc_new(self, ...)
  update_doc_diff(self)
  update_doc_blame(self)
end

local doc_load = Doc.load
function Doc:load(...)
  doc_load(self, ...)
  update_doc_diff(self)
  update_doc_blame(self)
end

local doc_raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  doc_raw_insert(self, line, col, text, undo_stack, time)
  local diffs = self.scm_diff or {}
  if diffs[line] ~= "addition" then
    diffs[line] = "modification"
  end
  local count = line
  for _ in (text .. "\n"):gmatch("(.-)\n") do
    if count ~= line then
      diffs[count] = "addition"
    end
    count = count + 1
  end
  self.scm_diff = diffs
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  local diffs = self.scm_diff or {}
  if line1 ~= line2 then
    local minline = math.min(line1, line2)
    local maxline = math.max(line1, line2)
    for line = minline+1, maxline do
      diffs[line] = "deletion"
    end
  else
    diffs[line1] = "modification"
  end
  self.scm_diff = diffs
end

--------------------------------------------------------------------------------
-- Override DocView to draw changes on gutter, inline blame and blame tooltip
--------------------------------------------------------------------------------
local DIFF_WIDTH = 3
local docview_draw_line_gutter = DocView.draw_line_gutter
local docview_get_gutter_width = DocView.get_gutter_width

---Draws the inline "date author" annotation for `line`, if inline blame
---is enabled and data is available, then returns how many pixels wide
---it (plus its padding) was -- 0 if nothing was drawn. Always called
---first, before any of the diff-highlighter logic below, so the
---annotation sits leftmost regardless of the highlighter's own
---left/right alignment setting: everything below just operates on
---whatever x/width it's handed, same as it always has.
---@param self core.docview
---@param line integer
---@param x number
---@param y number
---@return number
local function draw_inline_blame(self, line, x, y)
  if not scm.show_inline_blame or not self.doc or not self.doc.blame_inline_width then
    return 0
  end

  local info = self.doc.blame_list and self.doc.blame_list[line]
  if info then
    local font = self:get_font()
    local author = util.truncate(
      info.author or "", config.plugins.smc.inline_blame_max_author_length
    )
    local text = string.format("%s %s", info.date or "", author)
    local color = (style.syntax and style.syntax["comment"]) or style.dim
    -- same yoffset the diff-highlighter accent bar below already uses
    -- to align itself within the row -- without it the annotation sits
    -- flush with the row's top edge instead of centered on the text.
    local yoffset = self:get_line_text_y_offset()
    renderer.draw_text(font, text, x, y + yoffset, color)
  end

  return self.doc.blame_inline_width + config.plugins.smc.inline_blame_padding
end

function DocView:draw_line_gutter(line, x, y, width)
  local blame_w = draw_inline_blame(self, line, x, y)
  x = x + blame_w
  width = width - blame_w

  if not self.doc or not self.doc.scm_diff or not config.plugins.smc.highlighter then
    return docview_draw_line_gutter(self, line, x, y, width)
  end

  local lh = self:get_line_height()
  local gw, gpad = docview_get_gutter_width(self)
  local diff_type = self.doc.scm_diff[line]

  local align = config.plugins.smc.highlighter_alignment

  if align == "right" then
    docview_draw_line_gutter(self, line, x, y, gpad and gw - gpad or gw)
  else
    local tox = style.padding.x * DIFF_WIDTH / 12
    docview_draw_line_gutter(self, line, x + tox, y, gpad and gw - gpad or gw)
  end

  if diff_type == nil then return end

  local color = style.good
  if diff_type == "deletion" then
    color = style.error
  elseif diff_type == "modification" then
    color = style.warn
  end

  local colw = self:get_font():get_width(#self.doc.lines)

  -- add margin in between highlight and text
  if align == "right" then
    if colw + style.padding.x * 2 >= gw then
      x = x + style.padding.x * 1.5 + colw
    else
      x = x + gw - style.padding.x * 2 + (style.padding.x * DIFF_WIDTH / 12)
    end
  else
    local spacing = (style.padding.x * DIFF_WIDTH / 12)
    if colw + style.padding.x * 2 >= gw then
      x = x + gw + spacing - colw - gpad
    else
      x = x + math.max(gw, colw) - (colw) - math.min(colw, gw) - spacing
    end
  end

  local yoffset = self:get_line_text_y_offset()
  if diff_type ~= "deletion" then
    renderer.draw_rect(x, y + yoffset, DIFF_WIDTH, self:get_line_height(), color)
    return
  end
  renderer.draw_rect(x - DIFF_WIDTH * 2, y + yoffset, DIFF_WIDTH * 4, 2, color)
  return lh
end

function DocView:get_gutter_width()
  -- docview_get_gutter_width (core's original, saved above) returns
  -- TWO values: the total width, and the padding portion of it that
  -- core's own draw() strips back out before sizing the line-number
  -- text box (see `gpad and gw - gpad or gw` in core.docview's draw).
  -- This override used to return only the first value, silently
  -- dropping gpad -- which made every caller that destructures both
  -- values (draw(), specifically) receive gpad = nil and fall back to
  -- the FULL width instead of the padding-stripped one, widening the
  -- line-number box by 2*style.padding.x and pushing numbers into the
  -- code text's space. Only visible on files where scm_diff stays nil
  -- forever (clean files): draw_line_gutter's other branch (taken once
  -- scm_diff populates on a dirty file) bypasses this override entirely
  -- and calls docview_get_gutter_width directly, which is why dirty
  -- files were never affected once their diff data arrived.
  local orig_width, orig_padding = docview_get_gutter_width(self)
  local width = orig_width

  if self.doc and self.doc.scm_diff and config.plugins.smc.highlighter then
    width = width + style.padding.x * DIFF_WIDTH / 12
  end

  if scm.show_inline_blame and self.doc and self.doc.blame_inline_width then
    width = width + self.doc.blame_inline_width + config.plugins.smc.inline_blame_padding
  end

  return width, orig_padding
end

local function draw_tooltip(text, x, y)
  local font = style.font
  local lh = font:get_height()
  local ty = y + lh + (2 * style.padding.y)
  local width = 0

  local lines = {}
  for line in string.gmatch(text.."\n", "(.-)\n") do
    width = math.max(width, font:get_width(line))
    table.insert(lines, line)
  end

  y = y + lh + style.padding.y

  local height = #lines * font:get_height()

  renderer.draw_rect(
    x, y,
    width + style.padding.x * 2, height + style.padding.y * 2,
    style.background3
  )

  for _, line in pairs(lines) do
    common.draw_text(
      font, style.text, line, "left",
      x + style.padding.x, ty,
      width, lh
    )
    ty = ty + lh
  end
end

local docview_draw = DocView.draw
function DocView:draw()
    docview_draw(self)

    if not self.doc or not scm.get_backend() or not self.doc.blame_list then
      return
    end

    local line = self.doc:get_selection()
    local info = self.doc.blame_list[line]

    if info then
      local x, y = self:get_line_screen_position(line)
      local backend = scm.get_path_backend(self.doc.abs_filename)
      if backend then
        local text

        if not info.text then
          text = string.format(
            "%s Blame | %s | (%s) %s",
            backend.name, info.commit, info.author, info.date
          )
        end

        draw_tooltip(info.text or text, x, y)

        if not info.text and not info.getting then
          info.getting = true
          backend:get_commit_info(
            info.commit,
            util.get_project_dir(self.doc.abs_filename) or "",
            function(commit)
              local message = commit.summary or ""
              if commit.message then
                message = message .. "\n\n" .. commit.message
              end
              info.text = string.format(
                "%s Blame | %s | (%s) %s | %s",
                backend.name, info.commit, info.author, info.date, message
              )
            end
          )
        end
      end
    end
end

--------------------------------------------------------------------------------
-- Override rename to execute it on the SCM
--------------------------------------------------------------------------------
local os_rename = os.rename
function os.rename(oldname, newname)
  return scm.move_path(oldname, newname, os_rename)
end

--------------------------------------------------------------------------------
-- StatusBar Item to show current branch and stats
--------------------------------------------------------------------------------
local scm_status_item = core.status_view:add_item({
  name = "status:scm",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local project = util.get_current_project()

    if
      not PROJECTS[project]
      or
      not BRANCHES[project] or not STATS[project]
    then
      return {}
    end

    local bcolor = (STATS[project].inserts ~= 0 or STATS[project].deletes ~= 0)
      and style.accent or style.text
    local icolor = STATS[project].inserts ~= 0 and style.accent or style.text
    local dcolor = STATS[project].deletes ~= 0 and style.accent or style.text

    return {
      bcolor, BRANCHES[project],
      style.dim, "  ",
      icolor, "+", STATS[project].inserts,
      style.dim, " / ",
      dcolor, "-", STATS[project].deletes,
    }
  end,
  position = -1,
  tooltip = "current branch",
  separator = core.status_view.separator2
})

scm_status_item.on_click = function(button)
  if button == "right" then
    command.perform "scm:global-diff"
  else
    core.command_view:set_text("Scm: ")
    command.perform "core:find-command"
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
command.add(
  function()
    local valid = false
    local project_dir = nil
    local av = core.active_view
    if av and av.doc and av.doc.abs_filename then
      project_dir = util.get_project_dir(av.doc.abs_filename)
      if project_dir and PROJECTS[project_dir] then valid = true end
    end
    if not valid and PROJECTS[core.project_dir] then
      valid, project_dir = true, core.project_dir
    end
    return valid, project_dir
  end, {

  ["scm:global-diff"] = function(project_dir)
    scm.open_diff(project_dir)
  end,

  ["scm:project-status"] = function(project_dir)
    scm.open_project_status(project_dir)
  end,

  ["scm:merge-branches"] = function(project_dir)
    scm.start_merge(project_dir)
  end
})

command.add(nil, {
  ["scm:toggle-blame"] = function()
    scm.show_blame = not scm.show_blame
    for _, doc in ipairs(core.docs) do
      update_doc_blame(doc)
    end
    core.log(
      "SCM: %s blame information",
      scm.show_blame and "showing" or "hiding"
    )
  end
})

-- FIX: format ?
command.add(nil, {
  ["scm:toggle-inline-blame"] = function()
    scm.show_inline_blame = not scm.show_inline_blame
    for _, doc in ipairs(core.docs) do
      update_doc_blame(doc)
    end
    core.log(
      "SCM: %s inline blame",
      scm.show_inline_blame and "showing" or "hiding"
    )
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return scm.show_blame and doc.blame_list, doc
  end, {

  -- FIX: ?
  ["scm:view-blame-diff"] = function(doc)
    ---@cast doc core.doc
    local line = doc:get_selection()
    scm.open_commit_diff(
      doc.blame_list[line].commit,
      util.get_file_project_dir(doc.abs_filename)
    )
	end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_backend(doc.abs_filename)
      and scm.get_path_status(doc.abs_filename) == "untracked"
      , doc
  end, {

  ["scm:file-add"] = function(doc)
    ---@cast doc core.doc
    scm.add_path(doc.abs_filename)
	end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_status(doc.abs_filename) == "unchanged"
      , doc
  end, {

  ["scm:file-remove"] = function(doc)
    scm.remove_path(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local path = doc.abs_filename
      local status = scm.get_path_status(path)
      if status == "edited" and not scm.is_staged(path) then
        local backend = scm.get_path_backend(path)
        if backend and backend:has_staging() then
          return true, doc
        end
      end
    end
    return false
  end, {

  ["scm:staging-add"] = function(doc)
    scm.stage_file(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local backend = scm.get_path_backend(doc.abs_filename)
      if backend and backend:has_staging() then
        if scm.is_staged(doc.abs_filename) then
          return true, doc
        end
      end
    end
    return false
  end, {

  ["scm:staging-remove"] = function(doc)
    scm.unstage_file(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local path = doc.abs_filename
      local status = scm.get_path_status(path)
      local backend = scm.get_path_backend(path)
      if backend and backend:has_staging() then
        if status == "edited" and not scm.is_staged(path) then
          return true
        end
      elseif backend then
        return scm.get_path_backend(doc.abs_filename, true, true), doc
      end
    end
    return false
  end, {

  ["scm:file-revert"] = function(doc)
    scm.revert_file(doc.abs_filename)
  end,
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_status(doc.abs_filename) == "edited"
      and not scm.is_staged(doc.abs_filename)
      , doc
  end, {

  ["scm:file-diff"] = function(doc)
    scm.open_path_diff(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_backend(doc.abs_filename) ~= nil
      , doc
  end, {

  -- Deliberately not gated on the file having local changes or being
  -- tracked: the whole point is comparing against an arbitrary branch,
  -- which is meaningful for an unmodified/committed file too.
  ["scm:file-diff-view"] = function(doc)
    scm.open_file_diff_view(doc.abs_filename)
  end
})

-- Single registration covering all three "goto change" contexts:
-- MergeView, DiffView, and a live editable doc with local (uncommitted)
-- changes. These must live under ONE command.add call, not three: Lite
-- XL's command.add replaces any prior registration for a given command
-- name rather than stacking multiple predicates under it, so splitting
-- this into separate command.add calls per view type (as an earlier
-- revision did) meant each later one silently clobbered the earlier
-- ones -- only the last-registered predicate group ever ran.
command.add(
  function()
    local view = core.active_view
    if view and view:extends(MergeView) then
      return true, "merge", view
    end
    if view and view:extends(DiffView) then
      return true, "diff", view
    end
    local doc = util.get_current_doc()
    if doc then
      local project_dir = util.get_file_project_dir(doc.abs_filename)
      if
        CHANGES[project_dir] and CHANGES[project_dir][doc.abs_filename]
        and
        doc.scm_diff
      then
        return true, "doc", doc
      end
    end
    return false
  end, {

  ["scm:goto-previous-change"] = function(kind, target)
    if kind == "merge" or kind == "diff" then
      target:goto_previous_block()
    else
      scm.previous_change(target)
    end
  end,

  ["scm:goto-next-change"] = function(kind, target)
    if kind == "merge" or kind == "diff" then
      target:goto_next_block()
    else
      scm.next_change(target)
    end
  end,
})


--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------
keymap.add {
  ["ctrl+alt+["]       = "scm:goto-previous-change",
  ["ctrl+alt+]"]       = "scm:goto-next-change",
  ["alt+shift+b"]      = "scm:toggle-blame",
  ["ctrl+alt+shift+b"] = "scm:toggle-inline-blame",
  ["alt+b"]            = "scm:view-blame-diff",
  ["ctrl+alt+d"]       = "scm:file-diff-view",
}

--------------------------------------------------------------------------------
-- Load TreeView support if the plugin is enabled
--------------------------------------------------------------------------------
require "plugins.scm.treeview"


return scm
