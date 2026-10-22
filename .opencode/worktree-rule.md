# Worktree rule

Never edit files in the main project folder. All edits happen in an isolated git worktree.

1. Find the main folder: the first path in `git worktree list`. Call its folder name <repo>.
2. If ../<repo>-deepseek does not exist, create it with plain git:
   `git worktree add ../<repo>-deepseek -b deepseek-fixes`
   If the branch already exists: `git worktree add ../<repo>-deepseek deepseek-fixes`
3. If it already exists, run `git merge <main-branch>` inside it first so it is up to date.
4. Do all edits and commands inside the worktree, using full paths into it.
5. When finished, commit in the worktree. Do not merge into the main branch and do not delete the worktree.
6. Start every session by stating the worktree path you are working in.
