- FIX: in-place mouse scrolling for left/right views

- TODO: check if `minimap` plugin is installed, if it is, adjust coordinate system to avoid overlapping on minimap
- TODO: add super-scrollbar (coordinate auto-scroll of other scrollbars in relation to super-scrollbar)
- TODO: draw gutter shapes to indicate merge direction of code blocks
- TODO: draw gutter buttons to handle diff code

## Da Riordinare

- WIP: adding tab that contains output of `git log --graph --oneline`
  - WIP: draw colored text in history tab
  - TODO: visualize a complex history graph (when colors are enabled), make a screenshot an put it in the PR's comment

- WIP: adding more commands: `fetch`, `pull`
  - TODO: to pull from remote: add remote check and commandview to pass remote name

- WIP: command: git fetch --all
- WIP: command: git pull

- WIP: intellij-like gitblame (also don't use the gitblame plugin)


- FIX: scm: add a space between each diff-stdout-dump text-block in the diff view, for clarity
- FIX: project status is not colored (look at the diff)
- FIX: show history is not colored (look at the diff)


- TODO: add blame

- TODO: color the "branch-name +n / ~n / -n" in the statusview with green-yellow-red colors

- TODO: **HIGH PRIORITY**: interactive `git add` (fundamental for many files, maybe with long paths)
  - TODO: add new tab with treeview ?
    (navigate treeview with arrows)
    (press tab to view file diff)
    (press enter to stage file/folder)
- NOTE: take inspiration from the following:
- NOTE: https://zed.dev/git
- NOTE: https://www.sublimetext.com/
- NOTE: https://www.sublimemerge.com/

- TODO: add `scm:scroll-changes`: run a command that gets the list of current file's changes and allows traversing all changes
  (just like the default search command)

- TODO: interactive hunk add
  
- TODO: diff view tab: guarda come lo fa Intellij

- TODO: detect if file belongs to submodule and show the submodule's data instead of the super-repo

