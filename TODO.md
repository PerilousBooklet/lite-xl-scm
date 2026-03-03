- FIX: Find/fix the bug that causes warnings in the logs
- FIX: scm/changes.lua:34, attempt to index nil value, local type, HAPPENS WHEN I SAVE


- WIP: All still open files must close after doing a `git checkout/switch branch_name`
- WIP: Add visual history tab (take `git log --oneline --graph`), use ASCII chars


- TODO: Add feature-complete Github-or-Meld-like diff viewtab.
- TODO: allow diff view between two loaded projects (like meld does) (impede opening a third if diff view is open ?)
- TODO: add functionality to close the treeview of the diffs between 2 folders (es. porting al lavoro) and exclude one or more sub-folders (see `OutlineView`)

- TODO: See if there are changes from `pragtical` to port to `lite-xl-scm`
- TODO: Hunk staging: use the same gui as in the `refactor` plugin
      (look at Adam's debugger and see how he implemented breakpoints)
      (could use those to select lines of code to toggle adding them to staging)
- TODO: Add git icons
- TODO: Add buttons for file-add, file-remove from commit.

