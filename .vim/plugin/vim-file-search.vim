" ============================================================================
" VIM-FILE-SEARCH — SELF-DOCUMENTING PLUGIN / AI HANDOFF CONTRACT
" ============================================================================
" File:        vim-file-search.vim
" Type:        Classic Vimscript plugin (not a Neovim-only plugin)
" Purpose:     Project content search, path-aware filename search, regex replacement,
"              per-tab buffer management, and tab-page creation/switching.
" Required:    Vim compiled with +popupwin.
" Optional:    git, ripgrep (rg), grep, awk, sed. The plugin has fallbacks.
" Install:     Put this file at ~/.vim/plugin/vim-file-search.vim.
"
" IMPORTANT FOR FUTURE MAINTENANCE / AI HANDOFF
" ---------------------------------------------
" This header is the canonical specification of the public behavior and the
" internal architecture. The implementation below is the source of truth for
" details. A new contributor or assistant should be able to work from this
" single file without relying on chat history. When behavior changes, update
" this contract and the nearby function comments in the same edit.
"
" DESIGN INTENT
" -------------
" * Exactly two search modes are exposed: file CONTENTS and path-aware NAMES.
" * Content search is case-insensitive and literal (fixed substring), not a
"   regular-expression search. Regex is used only by the separate replace UI.
" * Name search supports case-insensitive substring, glob/path masks and
"   optional fuzzy subsequence ranking. Path fragments may start mid-path.
" * In path masks, '*' stays within one path component and '**' crosses any
"   number of components. A trailing '*' is implicit for a partial filename.
" * There is deliberately no separate path-search command, no <leader>n/N
"   mapping, and no separate <leader>R command.
" * Search/replace uses Vim's regular-expression and replacement syntax.
" * UI is built with popup_create()/popup_settext(); no external UI framework.
" * Popup surfaces use a subtle gray tint and theme-aware border, selected from
"   &background; ColorScheme/background changes refresh the palette.
"
" PUBLIC HOTKEYS (Normal mode; configurable via g:file_search_map_keys)
" ---------------------------------------------------------------------
" <leader>f  Search file CONTENTS; respect Git ignore rules.
" <leader>F  Search file CONTENTS; include ignored untracked files.
" <leader>g  Search by file NAME/PATH mask; respect Git ignore rules.
" <leader>G  Search by file NAME/PATH mask; include ignored untracked files.
" <leader>r  Vim-regex project search & replace; respect Git ignore rules.
" <leader>b  Open the buffer manager for the current tab page.
" <leader>t  Create a new tab with Vim's default directory and unnamed buffer.
" <leader>T  Open the tab-page list popup.
" Search popup: F5 forces a fresh index and clears/cancels preview cache work.
"
" PUBLIC EX COMMANDS (available even when mappings are disabled)
" --------------------------------------------------------------
" :GrepFiles              Content search; respect Git ignores.
" :GrepFilesAll           Content search; include ignored untracked files.
" :FileNames              Filename/path-mask search; respect Git ignores.
" :FileNamesAll           Filename/path-mask search; include ignored files.
" :VimFileReplace         Open Vim-regex project replacement.
" :VimFileReplaceUndo     Restore the newest safe persistent replacement batch.
" :VimFileReplaceHistory  Browse retained replacement batches and undo one.
" :FileBuffers            Open the per-tab buffer manager.
" :FileTab [dir] [name]   Create a tab with optional tab-local cwd and label.
" :FileTabs               Open the two-column tab-page list.
" :VimFileWorkspaceSave [name] Save clean tab/file/cursor state as a workspace.
" :VimFileWorkspaceLoad [name] Append tabs/files from a saved workspace.
" :VimFileWorkspaceList   List saved workspace names.
" :VimFileSearchInfo      Show runtime diagnostics and effective settings.
" :VimFileSearchClearCache Clear the file index and preview-context caches.
"
" PUBLIC FUNCTIONS
" ----------------
" VimFileTabCreate([directory [, name]]) Create a new tab; directory is applied
"                             as tab-local :tcd and optional name is tab-local.
" VimFileTabList()             Open the popup listing all tab pages.
" VimFileWorkspaceSave([name]) Save current clean workspace state.
" VimFileWorkspaceLoad([name]) Restore workspace tabs without closing current tabs.
" VimFileWorkspaceList()       Return saved workspace names.
" VimFileSearchInfo()          Open diagnostics popup.
"
" KEY MAPS (when g:file_search_map_keys is nonzero)
" -------------------------------------------------
" <leader>f/F/g/G/r/b/t/T   The eight default Normal-mode mappings above.
" Setting g:file_search_map_keys=0 disables all eight, not the Ex commands.
"
" SEARCH POPUP KEYS
" -----------------
" Enter                 Open selected file; in content mode jump to occurrence.
" Up/Down, Ctrl-P/N     Move through result files.
" PageUp/PageDown       Move through result list by a page.
" Left/Right            In content mode, cycle through occurrences.
" Backspace/Ctrl-H       Delete one query character; Ctrl-U clears the query.
" Ctrl-F                Toggle fuzzy subsequence matching in filename/path mode.
" Ctrl-Up/Down          Navigate persisted search history.
" Ctrl-X / Ctrl-V/T     Open selection in split / vsplit / new tab.
" Ctrl-O                Toggle the content-result preview (content mode only).
" F5                    Rebuild the index and cancel obsolete search/preview work.
" Esc/Ctrl-C            Close the popup.
" Search history is stored under g:file_search_data_dir, bounded by its limit.
" `ext:vim` or `ext:.vim,txt` filters results by extension; the directive is
" removed from the actual content/path query.
"
" SEARCH BEHAVIOR AND ORDERING
" ----------------------------
" * Search root is the Git top-level directory when inside a Git repository;
"   otherwise it is the current working directory.
" * Git mode indexes tracked files plus non-ignored untracked files. The
"   include-ignored mode additionally indexes ignored untracked files.
"   Tracked files remain included even if a current ignore rule matches them.
" * Outside a Git repository, or if Git file listing fails, filesystem
"   traversal is used. Git ignore rules cannot be fully applied in this
"   fallback and the popup displays a warning.
" * Content queries are literal, case-insensitive substrings. NUL-containing
"   files are treated as binary and skipped. Search prefers asynchronous rg
"   jobs when Vim has +job, /bin/sh and POSIX tr; other environments use the
"   synchronous rg/grep/Vim fallback. Async rg receives explicit indexed file
"   batches, so the Git-aware file index remains the single source of truth.
"   Two jobs compute occurrence and matching-line counts in parallel per
"   bounded batch; batches run sequentially. New queries and popup closure
"   cancel obsolete jobs, and callbacks from old query generations are ignored.
" * Content results are ranked by distinct matching-line count (descending),
"   then occurrence count (descending), then relative path (ascending).
" * The total occurrence count appears after the path as `(N)` only when N>1.
" * The content preview shows the current occurrence and nearby context.
"   Left/Right cycles through occurrences. Typing is debounced (default 300ms;
"   minimum configurable delay 100ms) when Vim timers are available.
" * The file index is cached by project root and ignore mode for the configured
"   TTL (default 5 seconds, max four cache entries). BufWritePost invalidates
"   it. F5 in the search popup or :VimFileSearchClearCache forces a rebuild.
" * Plain name queries are case-insensitive basename substrings. A query
"   containing '/' is matched against the indexed relative path from any
"   position, so it need not start at the project root. Path queries ending
"   in '/' select all files below matching directories. A terminal '/*' or
"   '/**' is also a directory selector: '*' selects one child directory and
"   '**' selects any descendant depth. In a file mask, '*' matches within one
"   path component; '**' may cross separators. A partial final filename gets
"   an implicit trailing '*'. Query separators may be '/' or '\'.
" * Search operates on disk files, not unsaved in-memory buffer contents.
" * :FileTab accepts an optional directory followed by an optional display name.
"   The directory is resolved before tab creation and applied with :tcd, so it
"   becomes the new tab's local working directory without changing other tabs.
"   With no arguments, Vim's normal :tabnew defaults are retained. In the Ex
"   command, quote or escape directory paths containing spaces; remaining
"   argument words are joined as the display name. Names are stored per tab.
" * :FileTabs opens a two-column popup listing every tab: display name, then
"   absolute path plus the current buffer's filename. Enter switches tabs;
"   j/k or Up/Down navigate; r renames the selected tab; d closes it safely;
"   Esc/q closes the list. The last remaining tab cannot be deleted, and tabclose
"   is never forced, so Vim protects modified buffers.
"
" SEARCH IGNORE POLICY (important)
" --------------------------------
" In a Git repository, the index uses Git's --exclude-standard behavior, which
" includes .gitignore, .git/info/exclude and configured global excludes.
" Include-ignored mode adds ignored UNTRACKED files; tracked files are retained
" in both modes. On a non-Git directory or failed Git listing, the filesystem
" fallback cannot interpret Git ignore rules and warns rather than pretending
" to have applied them.
"
" REGEX REPLACE (<leader>r / :VimFileReplace)
" --------------------------------------------
" * Uses Vim regexp syntax in Find and Vim substitute() replacement syntax in
"   Replace with (e.g. \( ... \) groups and \1/\2 backreferences). Matching
"   and replacement are line-oriented; matches cannot span line boundaries.
" * Candidate files come from the Git-ignore-respecting project index. Modified
"   open buffers, binary files, symlinks, non-regular files and files larger
"   than g:file_search_replace_max_file_bytes are skipped.
" * Scan snapshots include metadata and SHA-256 where available. The file is
"   revalidated before every write; changed files are skipped to avoid stale
"   overwrites. Each write uses a same-directory temporary file + rename.
" * `a` creates a read-only whole-project plan. Space toggles file inclusion;
"   `d` opens a per-file occurrence diff. In the diff, Space toggles an
"   individual occurrence; Up/Down or j/k navigate, PageUp/PageDown (or [ / ])
"   paginate, and Enter/Esc closes. Selection is applied with Vim regex match
"   offsets/backreferences; files with incomplete capped match records only
"   support whole-file inclusion/exclusion.
" * `y`/Enter commits the selected plan; Esc/`b` returns without writing.
"   Enter/`o` enters one-by-one review; y/Enter accepts, n skips, a applies all
"   remaining records, q/Esc saves safe accepted changes.
" * Replacement undo is persisted on disk in g:file_search_undo_dir (or
"   g:file_search_data_dir/undo by default). It retains up to
"   g:file_search_undo_history_limit batches (default 10). :VimFileReplaceHistory
"   browses these batches; Enter loads a batch for guarded undo. Restoration
"   checks current post-write content and modified buffers per file. Conflicts
"   remain in the journal for later retry; Esc keeps completed restores.
" * Persistent backup files contain original project content in plain form;
"   protect the configured data directory. Undo is per-file, not a global
"   transaction. A hard crash during an in-progress batch may leave a pending
"   directory that needs manual cleanup; committed journals survive restarts.
" * One-by-one review stores at most 30,000 occurrence records. The file limit
"   defaults to 8 MiB; set it to 0 to disable. One file's read/hash/regex/write
"   remains synchronous even though outer work is timer-sliced.
" * `VimFileReplaceHistory` displays timestamp, file count and query summary.
"   The selected batch is revalidated at undo time; stale files are not restored.
"
" BUFFER MANAGER (<leader>b / :FileBuffers)
" -----------------------------------------
" * Logical membership and cursor positions are maintained per tab page;
"   Vim buffers themselves remain global.
" * Filter with `/` then type; Enter accepts the filter, Esc leaves filter mode,
"   Backspace edits and Ctrl-U clears. A `[+]` marker identifies modified buffers.
" * Space marks/unmarks the selected row; `X` closes all marked buffers that
"   are safe to close. `d`, `x` or Delete closes/removes the selected buffer.
"   Modified buffers, buffers visible in windows, or tracked in another tab
"   are protected from global deletion.
" * `c` copies the selected buffer's absolute path to the unnamed register.
"   Enter switches and restores the saved cursor position. Esc/q closes.
"
" TAB PAGES AND WORKSPACES
" -----------------------
" * :FileTabs supports r rename, d close, p pin/unpin, Shift-Left/Right move,
"   x close other eligible tabs, and X close eligible tabs to the right.
"   Pinned tabs cannot be moved across/closed by these operations. Close uses
"   non-forced :tabclose, so modified buffers remain protected by Vim.
" * :VimFileWorkspaceSave [name] serializes tab-local cwd/name/pin state, file
"   buffers, active file and cursor positions to a JSON manifest. Saving is
"   refused if a file buffer is modified. Workspace names are restricted to
"   safe filename characters.
" * :VimFileWorkspaceLoad [name] appends restored tab pages; it does not replace
"   or close the currently open tabs. Missing files/directories are skipped and
"   counted. Split/window layout, folds, options and unsaved buffer contents
"   are not persisted. :VimFileWorkspaceList lists available saved names.
"
" CONFIGURATION (set before this file is sourced)
" ------------------------------------------------
" g:file_search_max_height            Maximum popup height; default 20.
" g:file_search_map_keys              Define eight <leader> mappings; default 1.
" g:file_search_debounce_ms            Content-search delay; default 300ms.
" g:file_search_fuzzy_default         Initial fuzzy mode; default 0.
" g:file_search_show_hidden_default   Initial hidden-file visibility; default 1.
" g:file_search_history_limit         Persisted search queries; default 50.
" g:file_search_data_dir              Persistent history/undo root; default
"                                     ~/.vim/vim-file-search.
" g:file_search_undo_dir              Override persistent undo directory;
"                                     empty uses <data_dir>/undo.
" g:file_search_undo_history_limit    Committed undo batches retained; default 10.
" g:file_search_workspace_dir         Workspace manifests; default
"                                     <data_dir>/workspaces.
" g:file_search_index_cache_seconds   Index TTL; default 5, max four entries.
" g:file_search_preview_cache_seconds Preview TTL; default 5, max 64 entries.
" g:file_search_replace_max_file_bytes Replacement size cap; default 8 MiB;
"                                     set 0 to disable.
" g:file_search_popup_dark_bg/fg/border and popup_light_bg/fg/border
"                                     Six-digit hex colors for popup surfaces.
" Example:
"   let g:file_search_data_dir = expand('~/.vim/vim-file-search')
"   let g:file_search_history_limit = 50
"   let g:file_search_undo_history_limit = 10
"   let g:file_search_fuzzy_default = 0
"   let g:file_search_map_keys = 1
"   let g:file_search_popup_dark_bg = '#1C1C1C'
"   let g:file_search_popup_light_bg = '#F2F2F2'
"
" DEPENDENCIES AND FALLBACKS
" -------------------------
" * +popupwin is mandatory; otherwise loading stops with an error.
" * git is optional. Without it, file enumeration uses the filesystem.
" * rg is the preferred content search and occurrence locator.
" * grep is the next content-search fallback; pure Vim scanning is last resort.
" * awk helps select one occurrence from rg output; sed fetches only nearby
"   preview lines. Without rg or awk, occurrence preview fallback scans only
"   the first 4,000 lines; later occurrences may have no preview. Without sed,
"   context fallback reads from the file start to the target line and can be slow.
" * Vim timers are optional; without timer_start(), content search starts
"   immediately and replacement scan/bulk work use synchronous fallbacks.
"   With timers, replacement scan and bulk/remainder processing yield between
"   bounded slices; each individual file read/regex/write remains synchronous.
" * sha256() strengthens replacement conflict checks when available; without it,
"   the plugin falls back to file metadata. Atomic replacement uses rename().
" * Async indexing requires +job, /bin/sh and POSIX tr. Git projects use
"   git ls-files; non-Git directories use rg --files when rg is available.
"   Unsupported builds use synchronous filesystem/Git fallbacks.
" * Async content search requires +job, rg, /bin/sh and POSIX tr. Async preview
"   requires +job, rg, awk, sed and /bin/sh. Unsupported systems use synchronous
"   fallbacks.
"
" ARCHITECTURE / FUNCTION INDEX
" -----------------------------
" POPUP PRESENTATION:
"   s:ApplyPopupHighlights     Set configurable popup fill/text/border colors.
"
" FILE INDEX AND SEARCH:
"   s:SplitNulOutput          Decode NUL-delimited command output (Vim system()
"                             represents NUL as SOH in returned strings).
"   s:NormalizeRelative       Normalize separators and strip root/./ prefixes.
"   s:AddExistingFiles        Add readable files once, using a seen dictionary.
"   s:IndexFilesystem         Recursively enumerate files as a Git fallback.
"   s:IndexFiles              Establish project root and build ignore-aware file
"                             index; fills s:files and s:file_set.
"   s:ShellArgs               Shell-escape a bounded list of file paths.
"   s:SlowContentSearch       Pure Vim fixed-substring fallback.
"   s:SearchContentBatch      Search one bounded path batch with rg/grep/Vim.
"   s:CollectContentPathList  Keep only result paths present in the file index.
"   s:CollectContentPaths     Split command output, then collect indexed paths.
"   s:ParseRgCountOutput      Parse rg path + total occurrence-count records.
"   s:CountLineOccurrences    Count non-overlapping literal matches in a line.
"   s:CountFileMetrics        Read one file and count total occurrences/lines.
"   s:CountMatchingLinesBatch  Count matching lines for one bounded rg batch.
"   s:CountMatchingLines      Split line-count work into OS-safe batches.
"   s:CompareContentPaths     Sort comparator: lines, occurrences, path.
"   s:SortContentPaths        Apply the content result comparator.
"   s:RestrictSearchPaths     Keep content matches within current search candidates.
"   s:ParseRgLineCountOutput  Parse rg path + matching-line-count records.
"   s:ResultLabel             Format path and optional `(occurrences)` suffix.
"   s:FormatPreviewContext    Render a short context window and mark the match.
"   s:FindOccurrenceFallback  Locate occurrence by bounded Vim scan if rg absent.
"   s:PreviewOccurrence       Locate occurrence and fetch only nearby preview lines.
"   s:SearchContentsWithRg    Fast rg search + git grep tracked-file supplement.
"   s:SearchContents          Choose fast search or portable fallback; rank files.
"   s:GlobRegex                Convert a filename/path glob to a Vim regex.
"   s:BuildNamePattern         Classify and compile a basename/path query.
"   s:BuildSearchCandidateFiles  Build the search-only path set after hidden filtering.
"   s:IsHiddenPath             Detect hidden components in a relative path.
"   s:FilterFiles              Apply current content/name query to indexed files.
"   s:ModeLabel                Return the user-facing search-mode name.
"   s:UpdatePreview            Refresh preview for selected result/occurrence.
"   s:DelayedSearch            Timer callback that executes pending query.
"   s:RunPendingSearch         Stop timer and execute a pending query immediately.
"   s:ScheduleSearch           Debounce text input and schedule the next query.
"   s:ToggleGitIgnore         Switch Git ignore policy and reindex the current project.
"   s:AsyncSearchSupported     Detect the safe asynchronous rg pipeline.
"   s:BuildSearchBatches       Split indexed paths under command-line limits.
"   s:BuildAsyncRgCommand      Build a count-metrics command for one batch.
"   s:StartAsyncContentSearch  Initialize an asynchronous content search.
"   s:StartNextAsyncBatch      Start the next pair of rg metric jobs.
"   s:AsyncSearchOut           Collect raw job output for one metric stream.
"   s:AsyncSearchExit          Coordinate completion of an rg metric job.
"   s:FinishAsyncBatch         Parse counts and advance to the next batch.
"   s:FinishAsyncSearch        Sort results and refresh popup/preview.
"   s:CancelAsyncSearch        Stop obsolete jobs after edits/close/refresh.
"   s:AsyncSearchFallback      Use synchronous search if job startup fails.
"   s:IndexCacheClear          Drop all cached file indexes.
"   s:IndexCacheStore          Store one root/ignore-mode file index.
"   s:PrepareAsyncIndex        Resolve root/cache before background Git/rg file enumeration.
"   s:StartAsyncIndex          Launch Git or non-Git rg file listing in the background.
"   s:AsyncIndexExit           Parse completed Git/rg index and resume pending search or replacement.
"   s:CancelAsyncIndex         Stop obsolete index jobs and clean temp files.
"   s:PreviewCacheClear        Clear memoized preview contexts after writes/cache reset.
"   s:PreviewCacheStore        Memoize preview lines with TTL and bounded size.
"   s:RequestPreview           Serve cached preview or launch async preview retrieval.
"   s:StartAsyncPreview        Fetch occurrence location/context outside Vim's UI loop.
"   s:AsyncPreviewOut          Collect preview job output.
"   s:AsyncPreviewExit         Format/cache preview after background completion.
"   s:CancelAsyncPreview       Stop obsolete preview jobs.
"   s:Render                   Draw/update the main search popup.
"   s:Close                    Stop pending timer and close search popup.
"   s:OpenSelected             Open selected result and jump to chosen occurrence.
"   s:HandleKey                Handle keyboard input for the search popup.
"   VimFileSearch              Public search entry point; initializes popup/state.
"
" REGEX REPLACEMENT:
"   s:ReplaceClip              Clip long text to popup width.
"   s:ReplacePopupClose        Close the replacement popup safely.
"   s:BuildReplaceBufferMap    Build absolute-path -> buffer-number lookup once per scan.
"   s:ReplaceFindBuffer        Find an already-open buffer for a disk path.
"   s:ReplaceSyncBuffer        Refresh a loaded, unmodified buffer from disk.
"   s:ReplaceSaveCache         Atomically save dirty review edits only if the source is unchanged.
"   s:ReplaceLoadCache         Save prior edits and load only a verified scan-time file.
"   s:ReplaceFileStat          Read regular-file metadata for change detection.
"   s:ReplaceStatEqual         Compare the relevant file metadata fields.
"   s:ReplaceContentHash       Fingerprint readfile('b') lines with SHA-256.
"   s:ReplaceReadSnapshot      Read a stable file snapshot and its fingerprint.
"   s:ReplaceSnapshotMatches   Verify disk metadata and optionally file content.
"   s:ReplaceMarkChanged       Count/report each externally changed path once.
"   s:ReplaceTempPath          Allocate a unique temporary sibling path.
"   s:ReplaceAtomicWrite       Safely write a sibling temp file, journal original
"                             bytes, and rename it over the target.
"   s:ReplaceUndoBackup        Create and verify a persistent per-file undo backup.
"   s:ReplaceUndoRegister      Register the committed file's pre/post snapshots.
"   s:ReplaceUndoDiscard       Remove a backup when its target write did not commit.
"   s:ReplacePlanFile          Build a read-only, per-file replacement preview.
"   s:ReplacePlanStart         Initialize whole-project replacement planning.
"   s:ReplacePlanStep          Process bounded planning slices.
"   s:ReplaceActualLineCount   Account for readfile('b') trailing-EOL marker.
"   s:ReplaceScan              Validate regex and start incremental indexed-file scanning.
"   s:ReplaceScanFile          Scan a size-bounded candidate and retain its fingerprint.
"   s:ReplaceScanStep          Process a bounded timer slice and render progress.
"   s:ReplaceCurrentLine       Compute the current occurrence's proposed line.
"   s:ReplaceFormatLine        Sanitize and clip a context line for preview.
"   s:ReplaceReviewPreview     Render original/updated line preview.
"   s:ReplaceRender            Render input/action/review/done popup states.
"   s:ReplaceFinish            Save dirty cache and move to done state.
"   s:ReplaceAdvance           Advance one-by-one review to next match.
"   s:ReplaceApplyCurrent      Apply the accepted current occurrence.
"   s:ReplaceAll               Start timer-sliced confirmed bulk replacement.
"   s:ReplaceAllFile           Replace one snapshotted candidate file and write it.
"   s:ReplaceAllStep           Process a time/file-bounded bulk replacement slice.
"   s:ReplaceAllRemainingOne   Apply one remaining review record.
"   s:ReplaceAllRemaining      Start timer-sliced completion of one-by-one review.
"   s:ReplaceAllRemainingStep  Process a bounded slice of remaining review records.
"   s:ReplaceHandleKey         Handle keyboard input for replacement popup.
"   s:ReplaceUndoRender        Render undo confirmation/progress/result states.
"   s:ReplaceUndoOne           Restore one still-matching file from its backup.
"   s:ReplaceUndoFinish        Retain only unresolved entries after partial undo.
"   s:ReplaceUndoStep          Run undo in timer-sliced reverse file order.
"   s:ReplaceUndoClose         Stop undo and compact the partial journal safely.
"   s:ReplaceUndoHandleKey     Handle undo confirmation/cancellation keys.
"   s:ReplaceUndoCleanup       Remove incomplete pending backup directories on exit.
"   VimFileReplaceUndo         Public command to restore the latest safe batch.
"   VimFileReplace             Public replacement entry point; starts ignore-aware
"                             scan and opens the replacement popup.
"
" PER-TAB BUFFER MANAGER:
"   s:TabBuffers               Read tab-local buffer membership list.
"   s:TabBufferPositions       Read tab-local buffer cursor-position map.
"   s:SetTabBuffers            Store tab-local buffer membership list.
"   s:SetTabBufferPositions    Store tab-local cursor-position map.
"   s:SaveBufferPosition       Save current buffer line/column for this tab.
"   s:TrackCurrentBuffer       Add current buffer and optionally restore position.
"   s:ForgetWipedBuffer        Remove deleted buffer from every tab's state.
"   s:BufferVisibleCount       Count windows showing a buffer in one tab.
"   s:BufferVisibleAnywhere    Check whether any window shows a buffer.
"   s:BufferTrackedInOtherTab  Check membership in another tab's list.
"   s:BufferPopupClose         Close buffer popup safely.
"   s:BufferLabel              Format one buffer row for the popup.
"   s:BufferRender             Rebuild and draw the tab's buffer list.
"   s:BufferSwitchSelected     Switch to selected buffer and restore position.
"   s:BufferCloseSelected      Close/remove selected buffer with safety checks.
"   s:BufferHandleKey          Handle keyboard input for buffer popup.
"   VimFileBuffers             Public entry point; opens current-tab buffer popup.
"   s:ParseTabCommandArgs      Parse quoted/escaped path and display-name arguments.
"   s:CreateTabFromCommand     Adapt :FileTab raw arguments to the public function.
"   s:TabDirectory             Return the directory associated with a tab page.
"   s:TabDisplayName           Resolve custom or default display text for a tab.
"   s:TabCurrentPath           Get the selected window's full path/current buffer label.
"   s:TabListClip              Truncate a field by display width, preserving its end.
"   s:TabListClose             Close the tab-list popup and reset its ID.
"   s:TabListRender            Render two columns for every Vim tab page.
"   s:TabListReopen            Reopen the list and preserve a target/row selection.
"   s:TabListSwitchSelected    Close the list and switch to the selected tab.
"   s:TabListRenameSelected    Rename the selected tab without changing its cwd.
"   s:TabListDeleteSelected    Close the selected tab without force or data loss.
"   s:TabListHandleKey         Navigate, rename, close or activate a tab.
"   VimFileTabCreate           Create a tab with optional tab-local directory/name.
"   VimFileTabList             Public entry point; opens the tab-page list popup.
"
" SEARCH UX, PERSISTENCE AND DIAGNOSTICS:
"   VimFileReplaceHistory  Public command to browse persisted replacement generations.
"   VimFileSearchInfo  Public diagnostics popup for runtime features and settings.
"   VimFileWorkspaceList  List saved workspace manifest names.
"   VimFileWorkspaceLoad  Restore saved tab pages, cwd, buffers and cursor positions.
"   VimFileWorkspaceSave  Persist clean tab pages and their file/cursor state.
"   s:BufferCloseMarked  Safely close all selected buffers while retaining blocked entries.
"   s:BufferCopySelectedPath  Copy the selected buffer absolute path to the unnamed register.
"   s:BufferToggleMark  Toggle the batch-close mark on the selected buffer.
"   s:CompareFuzzyPaths  Sort fuzzy filename candidates by descending score, then path.
"   s:FuzzyScore  Score a subsequence query using adjacency and word boundaries.
"   s:InfoClose  Close and reset the diagnostics popup.
"   s:InfoHandleKey  Navigate and close the diagnostics popup.
"   s:RememberSearchQuery  Deduplicate and persist the last bounded search queries.
"   s:ReplaceDataDirectory  Resolve the private persistent plugin data directory.
"   s:ReplaceDiffClose  Close the current per-file replacement diff popup.
"   s:ReplaceDiffHandleKey  Navigate pages and toggle individual replacement occurrences.
"   s:ReplaceDiffRender  Render selectable per-occurrence before/after diff rows.
"   s:ReplaceHistoryClose  Close the persisted replacement-history popup.
"   s:ReplaceHistoryHandleKey  Navigate history and load a selected batch for guarded undo.
"   s:ReplaceHistoryRender  Render replacement batch dates, files and find/replace summary.
"   s:ReplacePlanOccurrenceKey  Build a stable key for one scanned replacement occurrence.
"   s:ReplacePlanOccurrencePreview  Recreate one original Vim-regex match and replacement preview.
"   s:ReplacePlanSelectedMatches  Count occurrences selected across checked plan files.
"   s:ReplacePlanSelectedPaths  Return checked plan files with at least one checked occurrence.
"   s:ReplacePlanShowDiff  Verify a candidate snapshot and open its diff/occurrence chooser.
"   s:ReplaceSelectedMatchCount  Count selected occurrence records for one path.
"   s:ReplaceUndoLoad  Load and validate a persistent undo manifest and its backups.
"   s:ReplaceUndoLoadLatest  Load the newest committed persistent replacement journal.
"   s:ReplaceUndoManifestPath  Return a batch manifest path.
"   s:ReplaceUndoPersist  Atomically write the persistent undo manifest.
"   s:ReplaceUndoPrune  Remove undo generations beyond the configured retention limit.
"   s:ReplaceUndoRoot  Resolve/create the configured persistent undo root.
"   s:SearchHistoryLoad  Load bounded search history from persistent storage.
"   s:SearchHistoryMove  Move through history while preserving the current query draft.
"   s:SearchHistorySave  Atomically persist the bounded search-query history.
"   s:TabListCloseBatch  Close eligible unpinned tabs except the current tab or tabs to its left.
"   s:TabListMoveSelected  Move an unpinned tab one position without crossing a pinned tab.
"   s:TabListTogglePin  Toggle the selected tab protection flag.
"   s:WorkspaceName  Validate a workspace filename-safe logical name.
"   s:WorkspacePath  Resolve a workspace JSON manifest path.

" STATE VARIABLES (script-local s: variables)
" -------------------------------------------
" Search state:
"   s:popup                  Main search popup window ID (-1 = closed).
"   s:query                  Current typed search substring.
"   s:files                  Indexed relative paths allowed by ignore policy.
"   s:file_set               Dictionary membership mirror for s:files.
"   s:search_files           Search candidate paths after optional hidden filtering.
"   s:search_file_set        O(1) membership map for the filtered search candidates.
"   s:show_hidden            Whether dot-prefixed path components are included in searches.
"   s:matches                Current filtered/ranked result paths.
"   s:match_counts           Total literal occurrences per content result.
"   s:match_line_counts      Distinct matching lines per content result.
"   s:selected               Zero-based selected result index.
"   s:root                   Absolute normalized project/search root.
"   s:error                  Current message shown in search popup.
"   s:index_warning          Warning produced while indexing files.
"   s:content_warning        Warning produced by content-search fallback.
"   s:respect_gitignore      1 = respect Git excludes; 0 = include ignored files.
"   s:is_git_repo             Whether s:root belongs to a Git repository.
"   s:search_mode            'content' or path-aware 'name' mode.
"   s:popup_width             Width used for search/preview formatting.
"   s:search_timer            Debounce timer ID (-1 = none).
"   s:search_pending          Whether debounce/search work is still in progress.
"   s:search_generation       Token used to ignore callbacks from obsolete jobs.
"   s:search_jobs             Handles for current asynchronous rg jobs.
"   s:async_search_running    Whether an asynchronous content search is active.
"   s:async_batches           Batches of indexed paths for async rg.
"   s:async_batch_index       Current asynchronous batch number.
"   s:async_batch_outputs     Raw count/line-count output for current batch.
"   s:async_seen              Paths already collected across async batches.
"   s:open_after_search       Whether Enter was pressed while search was running.
"   s:index_cache             In-memory index cache keyed by root and ignore mode.
"   s:index_cache_order       Bounded FIFO order for cached index keys.
"   s:index_job               Active asynchronous Git/rg file-index job handle.
"   s:index_tempfiles         Temporary raw/output files owned by index job.
"   s:index_generation        Token that invalidates obsolete index callbacks.
"   s:index_cache_epoch       Invalidation counter incremented by cache clears/writes.
"   s:index_start_cache_epoch Epoch captured by the active index job to detect stale snapshots.
"   s:index_purpose           Pending destination after indexing: search or replace.
"   s:indexing                Whether Git file enumeration is still running.
"   s:preview_job             Active asynchronous preview job handle.
"   s:preview_job_output      Raw metadata/context received from preview job.
"   s:preview_generation      Token that invalidates obsolete preview callbacks.
"   s:preview_cache            Bounded memoized context for recent occurrences.
"   s:preview_cache_order      FIFO order for preview cache keys.
"   s:preview_request_path     File currently being resolved by async preview.
"   s:preview_request_query    Literal content query for the active preview.
"   s:preview_request_occurrence One-based occurrence requested by the active preview.
"   s:replace_buffer_map       Absolute path -> buffer number map built once per scan.
"   s:preview_lines           Render-ready lines for the selected occurrence.
"   s:preview_occurrence      One-based occurrence index in selected file.
"   s:preview_occurrence_path Path whose occurrence index is currently retained.
" Replacement state:
"   s:replace_popup           Replacement popup window ID (-1 = closed).
"   s:replace_find            Vim regular-expression search pattern.
"   s:replace_with            Vim substitute() replacement expression.
"   s:replace_active_field    Input focus: 'find' or 'replace'.
"   s:replace_stage           Popup state: input/indexing/scanning/action/planning/plan/review/bulk/bulk_review/done.
"   s:replace_matches         Stored one-by-one match records (capped at 30,000).
"   s:replace_paths           Files containing matches (all candidates).
"   s:replace_path_counts     Number of matches per path.
"   s:replace_path_snapshots  Scan-time metadata and content fingerprints by path.
"   s:replace_conflicted_paths Paths already counted as changed after scan.
"   s:replace_temp_counter    Unique temporary-file suffix counter.
"   s:replace_index           Zero-based current review-record index.
"   s:replace_total_count     Total scanned matches, including beyond storage cap.
"   s:replace_skipped_modified Count of files skipped due to modified buffers.
"   s:replace_skipped_binary Count of NUL-containing binary files skipped.
"   s:replace_skipped_large  Count of files over the configured size limit.
"   s:replace_skipped_changed Count of files changed since scan/review.
"   s:replace_skipped_unsafe Count of symlinks and non-regular files skipped.
"   s:replace_warning         Indexing/ignore-policy warning, kept separate from errors.
"   s:replace_error           Validation/read/write/replacement status message.
"   s:replace_width           Popup width.
"   s:replace_cache_path      Path currently held in one-by-one edit cache.
"   s:replace_cache_lines     Current file's cached lines.
"   s:replace_cache_dirty     Whether cached current file needs writing.
"   s:replace_cache_original_lines Original bytes/lines retained for undo journaling.
"   s:replace_cache_accepted_count Number of accepted records staged in this file.
"   s:replace_line_deltas     Per-line length shifts after earlier replacements.
"   s:replace_files_changed   Number of files written by one-by-one workflow.
"   s:replace_changed_count   Number of accepted/replaced occurrences.
"   s:replace_max_stored      Maximum stored one-by-one records (30,000).
"   s:replace_execution       'none', 'one-by-one', or 'all'.
"   s:replace_scan_timer      Timer handle for cooperative background scan.
"   s:replace_bulk_timer      Timer handle for cooperative bulk/remainder replacement.
"   s:replace_bulk_generation Token invalidating stale bulk callbacks.
"   s:replace_bulk_index      Next file/record in a timer-sliced replacement pass.
"   s:replace_bulk_total     Number of files/records in the active bulk pass.
"   s:replace_bulk_processed Number of matches processed by bulk replacement.
"   s:replace_bulk_written   Number of files successfully written by bulk replacement.
"   s:replace_bulk_errors    Number of file-level errors in bulk replacement.
"   s:replace_scan_generation Token invalidating stale replacement scan callbacks.
"   s:replace_scan_index      Next indexed file to scan.
"   s:replace_scan_total_paths Total number of candidate files in current scan.
"   s:replace_buffer_map_ready Whether the open-buffer map has been initialized.
"   s:replace_plan_timer       Timer handle for whole-project read-only planning.
"   s:replace_plan_generation  Token invalidating obsolete preview-plan callbacks.
"   s:replace_plan_index       Next candidate in replacement plan.
"   s:replace_plan_total       Candidate count for the current plan.
"   s:replace_plan_files       Files with verified proposed changes.
"   s:replace_plan_examples   Bounded before/after line examples for the plan popup.
"   s:replace_plan_matches    Occurrence count reported by the plan.
"   s:replace_plan_conflicts  Files changed/modified since scan and excluded.
"   s:replace_plan_errors     Files whose preview could not be completed.
"   s:replace_undo_dir        Private directory for the active undo journal.
"   s:replace_undo_pending_dir Private directory being prepared for next batch.
"   s:replace_undo_pending_generation Scan generation associated with pending backups.
"   s:replace_undo_entries    Paths, before/after snapshots and backup references.
"   s:replace_undo_generation Scan generation currently represented by undo journal.
"   s:replace_undo_popup      Undo confirmation/progress popup window ID.
"   s:replace_undo_width      Width of undo popup.
"   s:replace_undo_stage      Undo popup state: idle/confirm/undo/done.
"   s:replace_undo_timer      Timer handle for sliced restore pass.
"   s:replace_undo_generation_token Cancels stale undo callbacks.
"   s:replace_undo_index      Number of undo entries processed.
"   s:replace_undo_restored   Number of files successfully restored.
"   s:replace_undo_skipped    Number of files skipped during restore.
" Buffer manager state:
"   s:buffer_popup            Buffer popup window ID (-1 = closed).
"   s:buffer_items            Buffer numbers in current tab's logical list.
"   s:buffer_selected         Zero-based selected buffer index.
"   s:buffer_status           Status/warning displayed in buffer popup.
"   s:buffer_popup_width      Popup width.
" Tab-list popup state:
"   s:tab_popup               Tab-list popup window ID (-1 = closed).
"   s:tab_items               Tab-page numbers shown in the current list.
"   s:tab_selected            Zero-based selected row in the tab list.
"   s:tab_popup_width         Width used to clip tab-list rows.
" Tab variables owned by this plugin:
"   t:vfs_tab_buffers         Logical buffer membership list for each tab.
"   t:vfs_tab_buffer_positions Dict: buffer number -> [line, column] per tab.
"   t:vfs_tab_name            Optional custom display name set by :FileTab.
" Global configuration variables:
"   g:file_search_max_height, g:file_search_map_keys,
"   g:file_search_debounce_ms, g:file_search_index_cache_seconds,
"   g:file_search_preview_cache_seconds
"                             (see CONFIGURATION above).
" Function-local l: variables and a: arguments are temporary implementation
" details; their meaning is documented by the function/parameter names and
" nearby comments. Script-local s: names are private to this plugin file.
"
" Additional state for fuzzy search, persistent history/undo, previews and workspaces:
"   s:buffer_filter                   Current buffer popup filter text.
"   s:buffer_filter_active            Whether the buffer filter field is active.
"   s:buffer_marked                   Dictionary of buffer numbers selected for batch close.
"   s:buffer_visible_items            Buffer numbers currently visible after filtering.
"   s:effective_query                 Search text after removing extension filter directives.
"   s:fuzzy_scores                    Computed fuzzy scores keyed by relative result path.
"   s:info_popup                      Diagnostics popup ID (-1 = closed).
"   s:replace_diff_lines              Original line metadata used by the diff view.
"   s:replace_diff_original_lines     Verified original lines for the open occurrence diff.
"   s:replace_diff_page_start         Zero-based first occurrence row shown in the diff popup.
"   s:replace_diff_path               Relative path currently shown by occurrence diff.
"   s:replace_diff_popup              Replacement diff popup ID (-1 = closed).
"   s:replace_diff_records            Complete scanned occurrence records shown by the diff.
"   s:replace_diff_selectable         Whether the current diff supports individual occurrence toggles.
"   s:replace_diff_selected_index     Zero-based current occurrence index in the diff.
"   s:replace_history_items           Persisted replacement batch metadata shown in history.
"   s:replace_history_popup           Replacement history popup ID (-1 = closed).
"   s:replace_history_selected        Zero-based selected replacement history item.
"   s:replace_match_records_by_path   Per-file match records and completeness flag for occurrence selection.
"   s:replace_plan_occurrence_selection Per-file occurrence-key selection dictionary; missing keys default selected.
"   s:replace_plan_selected           Per-file inclusion flags in the whole-project replacement plan.
"   s:replace_plan_selected_index     Zero-based selected file index in the plan popup.
"   s:replace_undo_created            Timestamp of the active persistent replacement generation.
"   s:replace_undo_find               Original Vim regex stored in the undo manifest.
"   s:replace_undo_id                 Identifier of the active persistent undo generation.
"   s:replace_undo_replacement        Replacement expression stored in the undo manifest.
"   s:search_fuzzy                    Whether filename/path filtering uses fuzzy subsequence scoring.
"   s:search_history                  Bounded persisted list of recent search queries.
"   s:search_history_draft            User query saved while browsing history.
"   s:search_history_index            Current history cursor (-1 means not browsing).
"   s:search_open_mode                Next result opening mode: edit, split, vsplit or tab.
"   s:search_preview_enabled          Whether content-mode preview rows are displayed.
"   s:tab_bulk_status                 Transient status for pin, move and bulk tab operations.
"   s:workspace_restore_status        Latest workspace-restore outcome message.
"   s:workspace_status                Status returned by workspace save/load operations.

" AUTOMATIC EVENTS
" ----------------
" VimFileSearchPopupTheme reapplies popup colors after ColorScheme changes or
" an explicit change to the 'background' option. Popup entry points also refresh
" the groups immediately before creation, covering direct colorscheme sourcing.
" VimFileSearchTabBuffers saves cursor positions on BufLeave/WinLeave, tracks
" buffers on BufEnter, and removes wiped/deleted buffers from every tab's
" plugin-owned list on BufDelete/BufWipeout. Persistent replacement journals
" are retained across Vim restarts; only incomplete pending journals are cleaned
" on VimLeavePre. TabEnter is intentionally not used:
" Vim fires it before the new tab's BufEnter, while the previous buffer can
" still be current, which would incorrectly add that old buffer to the new tab.
" BufWritePost invalidates the
" in-memory file index so the next search sees files created/removed by Vim.
" ============================================================================

if exists('g:loaded_vim_file_search')
    finish
endif

if !has('popupwin')
    echoerr 'vim-file-search requires Vim compiled with +popupwin'
    finish
endif

let g:loaded_vim_file_search = 1

let s:popup = -1
let s:query = ''
let s:effective_query = ''
let s:files = []
let s:file_set = {}
let s:search_files = []
let s:search_file_set = {}
let s:show_hidden = 1
let s:matches = []
let s:match_counts = {}
let s:match_line_counts = {}
let s:selected = 0
let s:root = ''
let s:error = ''
let s:index_warning = ''
let s:content_warning = ''
let s:respect_gitignore = 1
let s:is_git_repo = 0
let s:search_mode = 'name'
let s:search_fuzzy = 0
let s:fuzzy_scores = {}
let s:search_history = []
let s:search_history_index = -1
let s:search_history_draft = ''
let s:search_preview_enabled = 1
let s:search_open_mode = 'edit'
let s:popup_width = 80
let s:search_timer = -1
let s:search_pending = 0
let s:search_generation = 0
let s:search_jobs = []
let s:async_search_running = 0
let s:async_batches = []
let s:async_batch_index = 0
let s:async_batch_outputs = {}
let s:async_seen = {}
let s:open_after_search = 0
let s:index_cache = {}
let s:index_cache_order = []
let s:index_job = ''
let s:index_tempfiles = []
let s:index_generation = 0
let s:index_cache_epoch = 0
let s:index_start_cache_epoch = 0
let s:indexing = 0
let s:index_purpose = 'search'
let s:preview_job = ''
let s:preview_job_output = ''
let s:preview_generation = 0
let s:preview_cache = {}
let s:preview_cache_order = []
let s:preview_request_path = ''
let s:preview_request_query = ''
let s:preview_request_occurrence = 1
let s:replace_buffer_map = {}
let s:replace_buffer_map_ready = 0
let s:preview_lines = []
let s:preview_occurrence = 1
let s:preview_occurrence_path = ''
let s:replace_popup = -1
let s:replace_find = ''
let s:replace_with = ''
let s:replace_active_field = 'find'
let s:replace_stage = 'input'
let s:replace_matches = []
let s:replace_paths = []
let s:replace_path_counts = {}
let s:replace_match_records_by_path = {}
let s:replace_path_snapshots = {}
let s:replace_conflicted_paths = {}
let s:replace_temp_counter = 0
let s:replace_index = 0
let s:replace_total_count = 0
let s:replace_skipped_modified = 0
let s:replace_skipped_binary = 0
let s:replace_skipped_large = 0
let s:replace_skipped_changed = 0
let s:replace_skipped_unsafe = 0
let s:replace_warning = ''
let s:replace_error = ''
let s:replace_width = 80
let s:replace_cache_path = ''
let s:replace_cache_lines = []
let s:replace_cache_original_lines = []
let s:replace_cache_dirty = 0
let s:replace_cache_accepted_count = 0
let s:replace_line_deltas = {}
let s:replace_files_changed = 0
let s:replace_changed_count = 0
let s:replace_max_stored = 30000
let s:replace_execution = 'none'
let s:replace_scan_timer = -1
let s:replace_bulk_timer = -1
let s:replace_plan_timer = -1
let s:replace_plan_generation = 0
let s:replace_plan_index = 0
let s:replace_plan_total = 0
let s:replace_plan_files = []
let s:replace_plan_examples = []
let s:replace_plan_matches = 0
let s:replace_plan_conflicts = 0
let s:replace_plan_errors = 0
let s:replace_plan_selected = {}
let s:replace_plan_selected_index = 0
let s:replace_diff_popup = -1
let s:replace_diff_lines = []
let s:replace_diff_path = ''
let s:replace_diff_records = []
let s:replace_diff_original_lines = []
let s:replace_diff_selected_index = 0
let s:replace_diff_page_start = 0
let s:replace_diff_selectable = 0
let s:replace_plan_occurrence_selection = {}
let s:replace_undo_dir = ''
let s:replace_undo_pending_dir = ''
let s:replace_undo_pending_generation = -1
let s:replace_undo_entries = []
let s:replace_undo_generation = -1
let s:replace_undo_popup = -1
let s:replace_undo_width = 72
let s:replace_undo_stage = 'idle'
let s:replace_undo_timer = -1
let s:replace_undo_generation_token = 0
let s:replace_undo_index = 0
let s:replace_undo_restored = 0
let s:replace_undo_skipped = 0
let s:replace_undo_id = ''
let s:replace_undo_created = ''
let s:replace_history_popup = -1
let s:replace_history_items = []
let s:replace_history_selected = 0
let s:replace_bulk_generation = 0
let s:replace_bulk_index = 0
let s:replace_bulk_total = 0
let s:replace_bulk_processed = 0
let s:replace_bulk_written = 0
let s:replace_bulk_errors = 0
let s:replace_scan_generation = 0
let s:replace_scan_index = 0
let s:replace_scan_total_paths = 0
let s:replace_buffer_map_ready = 0
let s:buffer_popup = -1
let s:buffer_items = []
let s:buffer_selected = 0
let s:buffer_status = ''
let s:buffer_popup_width = 80
let s:buffer_filter = ''
let s:buffer_filter_active = 0
let s:buffer_visible_items = []
let s:buffer_marked = {}
let s:tab_popup = -1
let s:tab_items = []
let s:tab_selected = 0
let s:tab_popup_width = 80
let s:tab_bulk_status = ''
let s:workspace_restore_status = ''
let s:replace_diff_popup = -1
let s:replace_diff_lines = []
let s:replace_plan_selected = {}
let s:replace_plan_selected_index = 0
let s:replace_history_popup = -1
let s:replace_history_items = []
let s:replace_history_selected = 0
let s:workspace_status = ''

if !exists('g:file_search_max_height')
    let g:file_search_max_height = 20
endif

if !exists('g:file_search_map_keys')
    let g:file_search_map_keys = 1
endif

if !exists('g:file_search_fuzzy_default')
    let g:file_search_fuzzy_default = 0
endif
if !exists('g:file_search_show_hidden_default')
    let g:file_search_show_hidden_default = 1
endif
if !exists('g:file_search_history_limit')
    let g:file_search_history_limit = 50
endif
if !exists('g:file_search_data_dir')
    let g:file_search_data_dir = expand('~/.vim/vim-file-search')
endif
if !exists('g:file_search_undo_history_limit')
    let g:file_search_undo_history_limit = 10
endif
if !exists('g:file_search_workspace_dir')
    let g:file_search_workspace_dir = expand(g:file_search_data_dir . '/workspaces')
endif

if !exists('g:file_search_index_cache_seconds')
    let g:file_search_index_cache_seconds = 5
endif

if !exists('g:file_search_preview_cache_seconds')
    let g:file_search_preview_cache_seconds = 5
endif

" Vim's system() translates NUL bytes in command output to SOH (0x01),
" so Git/grep/rg NUL-separated filename output is split on "\x01" here.
" Purpose: Decode NUL-delimited output from external tools (NUL is represented as SOH by system()).
" Purpose: Define the subtle popup palette for the active light/dark background.
" GUI colors match the supplied minimal themes; cterm colors provide close
" terminal equivalents on both 256-color and basic terminal palettes.
function! s:ApplyPopupHighlights(...) abort
    let l:background = a:0 ? a:1 : &background
    if l:background ==# 'dark'
        let l:bg = get(g:, 'file_search_popup_dark_bg', '#1C1C1C')
        let l:fg = get(g:, 'file_search_popup_dark_fg', '#FFFFFF')
        let l:border = get(g:, 'file_search_popup_dark_border', '#D0D0D0')
        if l:bg !~# '^#[0-9A-Fa-f]\{6}$' | let l:bg = '#1C1C1C' | endif
        if l:fg !~# '^#[0-9A-Fa-f]\{6}$' | let l:fg = '#FFFFFF' | endif
        if l:border !~# '^#[0-9A-Fa-f]\{6}$' | let l:border = '#D0D0D0' | endif
        execute 'highlight VimFileSearchPopup guifg=' . l:fg . ' guibg=' . l:bg . ' gui=NONE ctermfg=White ctermbg=DarkGray cterm=NONE'
        execute 'highlight VimFileSearchPopupBorder guifg=' . l:border . ' guibg=' . l:bg . ' gui=NONE ctermfg=LightGray ctermbg=DarkGray cterm=NONE'
    else
        let l:bg = get(g:, 'file_search_popup_light_bg', '#F2F2F2')
        let l:fg = get(g:, 'file_search_popup_light_fg', '#000000')
        let l:border = get(g:, 'file_search_popup_light_border', '#000000')
        if l:bg !~# '^#[0-9A-Fa-f]\{6}$' | let l:bg = '#F2F2F2' | endif
        if l:fg !~# '^#[0-9A-Fa-f]\{6}$' | let l:fg = '#000000' | endif
        if l:border !~# '^#[0-9A-Fa-f]\{6}$' | let l:border = '#000000' | endif
        execute 'highlight VimFileSearchPopup guifg=' . l:fg . ' guibg=' . l:bg . ' gui=NONE ctermfg=Black ctermbg=LightGray cterm=NONE'
        execute 'highlight VimFileSearchPopupBorder guifg=' . l:border . ' guibg=' . l:bg . ' gui=NONE ctermfg=Black ctermbg=LightGray cterm=NONE'
    endif
endfunction

call s:ApplyPopupHighlights()

function! s:SplitNulOutput(output) abort
    let l:items = split(a:output, "\x01", 1)
    if !empty(l:items) && empty(l:items[-1])
        call remove(l:items, -1)
    endif
    return l:items
endfunction

" Purpose: Normalize a path to the plugin root-relative slash-separated form.
function! s:NormalizeRelative(path) abort
    let l:path = substitute(a:path, '\\', '/', 'g')
    let l:path = substitute(l:path, '^\./', '', '')
    if !empty(s:root) && stridx(l:path, s:root . '/') == 0
        let l:path = strpart(l:path, strlen(s:root) + 1)
    endif
    return l:path
endfunction

" Purpose: Append readable, unique paths to a target list and its seen dictionary.
function! s:AddExistingFiles(paths, target, seen) abort
    for l:raw_path in a:paths
        if empty(l:raw_path)
            continue
        endif

        let l:path = s:NormalizeRelative(l:raw_path)
        if empty(l:path) || has_key(a:seen, l:path)
            continue
        endif

        let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . l:path
        if filereadable(l:absolute)
            let a:seen[l:path] = 1
            call add(a:target, l:path)
        endif
    endfor
endfunction

" Recursive filesystem fallback. Includes dotfiles, but never descends into
" .git or follows directory symlinks (which could create traversal loops).
" Purpose: Recursively enumerate regular files when Git indexing is unavailable.
function! s:IndexFilesystem(root, target, seen) abort
    if exists('*readdir')
        let l:stack = [[a:root, '']]
        while !empty(l:stack)
            let l:item = remove(l:stack, -1)
            let l:dir = l:item[0]
            let l:relative_dir = l:item[1]

            try
                let l:names = readdir(l:dir)
            catch
                continue
            endtry

            for l:name in l:names
                if l:name ==# '.' || l:name ==# '..' || l:name ==# '.git'
                    continue
                endif

                let l:absolute = l:dir . '/' . l:name
                let l:relative = empty(l:relative_dir)
                            \ ? l:name : l:relative_dir . '/' . l:name

                if isdirectory(l:absolute)
                    if getftype(l:absolute) !=# 'link'
                        call add(l:stack, [l:absolute, l:relative])
                    endif
                elseif filereadable(l:absolute) && !has_key(a:seen, l:relative)
                    let a:seen[l:relative] = 1
                    call add(a:target, l:relative)
                endif
            endfor
        endwhile
    else
        " Compatibility fallback for old Vim versions without readdir().
        let l:paths = globpath(a:root, '**/*', 0, 1)
        for l:path in l:paths
            if isdirectory(l:path) || !filereadable(l:path)
                continue
            endif
            let l:absolute = substitute(fnamemodify(l:path, ':p'), '\\', '/', 'g')
            let l:prefix = substitute(fnamemodify(a:root, ':p'), '\\', '/', 'g')
            let l:prefix = substitute(l:prefix, '[\\/]\+$', '', '') . '/'
            let l:relative = strpart(l:absolute, strlen(l:prefix))
            if !has_key(a:seen, l:relative)
                let a:seen[l:relative] = 1
                call add(a:target, l:relative)
            endif
        endfor
    endif
endfunction

" Purpose: Clear all in-memory file-index cache entries.
function! s:IndexCacheClear() abort
    let s:index_cache_epoch += 1
    let s:index_cache = {}
    let s:index_cache_order = []
endfunction

" Purpose: Store an indexed path list for a root and ignore mode with bounded memory use.
function! s:IndexCacheStore(key) abort
    if has_key(s:index_cache, a:key)
        let l:old_pos = index(s:index_cache_order, a:key)
        if l:old_pos >= 0
            call remove(s:index_cache_order, l:old_pos)
        endif
    endif
    let s:index_cache[a:key] = {
                \ 'created': reltime(),
                \ 'files': copy(s:files),
                \ 'file_set': copy(s:file_set),
                \ 'warning': s:index_warning,
                \ 'is_git_repo': s:is_git_repo
                \ }
    call add(s:index_cache_order, a:key)
    while len(s:index_cache_order) > 4
        let l:oldest = remove(s:index_cache_order, 0)
        if has_key(s:index_cache, l:oldest)
            call remove(s:index_cache, l:oldest)
        endif
    endwhile
endfunction

" Build a fresh index only when the cache is expired or explicitly cleared.
" A dictionary makes de-duplication O(1) on average instead of repeated index().
" Purpose: Select the project root and create the indexed file set according to Git ignore policy.
function! s:IndexFiles(respect_gitignore) abort
    let s:error = ''
    let s:index_warning = ''
    let s:content_warning = ''

    let l:cwd = substitute(fnamemodify(getcwd(), ':p'), '\\', '/', 'g')
    let s:root = l:cwd
    let l:is_git_repo = 0

    if executable('git')
        let l:root_output = system('git -C ' . shellescape(l:cwd)
                    \ . ' rev-parse --show-toplevel 2>/dev/null')
        let l:root_status = v:shell_error
        if l:root_status == 0 && !empty(trim(l:root_output))
            let s:root = substitute(trim(l:root_output), '\\', '/', 'g')
            let l:is_git_repo = 1
        endif
    endif

    if s:root !=# '/'
        let s:root = substitute(s:root, '[\\/]\+$', '', '')
    endif

    let s:is_git_repo = l:is_git_repo
    let l:cache_key = s:root . "\x1f" . (a:respect_gitignore ? 'respect' : 'all')
    let l:cache_ttl = max([0, get(g:, 'file_search_index_cache_seconds', 5)])
    if l:cache_ttl > 0 && has_key(s:index_cache, l:cache_key)
        let l:cached = s:index_cache[l:cache_key]
        if reltimefloat(reltime(l:cached.created)) < l:cache_ttl
            let s:files = copy(l:cached.files)
            let s:file_set = copy(l:cached.file_set)
            let s:index_warning = l:cached.warning
            let s:is_git_repo = l:cached.is_git_repo
            return len(s:files)
        endif
        call remove(s:index_cache, l:cache_key)
        let l:cache_pos = index(s:index_cache_order, l:cache_key)
        if l:cache_pos >= 0
            call remove(s:index_cache_order, l:cache_pos)
        endif
    endif

    let s:files = []
    let s:file_set = {}

    if l:is_git_repo
        let l:cmd = 'git -c core.quotePath=false -C ' . shellescape(s:root)
                    \ . ' ls-files --full-name -z --cached --others --exclude-standard 2>/dev/null'
        let l:output = system(l:cmd)
        let l:status = v:shell_error

        if l:status == 0
            call s:AddExistingFiles(s:SplitNulOutput(l:output), s:files, s:file_set)

            if !a:respect_gitignore
                let l:ignored_cmd = 'git -c core.quotePath=false -C ' . shellescape(s:root)
                            \ . ' ls-files --full-name -z --others --ignored --exclude-standard 2>/dev/null'
                let l:ignored_output = system(l:ignored_cmd)
                let l:ignored_status = v:shell_error
                if l:ignored_status == 0
                    call s:AddExistingFiles(
                                \ s:SplitNulOutput(l:ignored_output),
                                \ s:files, s:file_set)
                else
                    let s:index_warning = 'Git could not list ignored files'
                endif
            endif
        else
            call s:IndexFilesystem(s:root, s:files, s:file_set)
            let s:index_warning = 'Git listing failed; filesystem fallback cannot fully apply .gitignore'
        endif
    else
        call s:IndexFilesystem(s:root, s:files, s:file_set)
        if a:respect_gitignore
            let s:index_warning = 'Not in a Git repository; .gitignore rules are unavailable'
        endif
    endif

    call sort(s:files)
    if l:cache_ttl > 0
        call s:IndexCacheStore(l:cache_key)
    endif
    return len(s:files)
endfunction


" Resolve the project root and test the short-lived index cache before async work.
" Return: 2 = cache hit, 1 = Git async indexing can start, 0 = use sync fallback.
function! s:PrepareAsyncIndex(respect_gitignore) abort
    let s:error = ''
    let s:index_warning = ''
    let s:content_warning = ''
    let l:cwd = substitute(fnamemodify(getcwd(), ':p'), '\\', '/', 'g')
    let s:root = l:cwd
    let s:is_git_repo = 0

    if executable('git')
        let l:root_output = system('git -C ' . shellescape(l:cwd)
                    \ . ' rev-parse --show-toplevel 2>/dev/null')
        if v:shell_error == 0 && !empty(trim(l:root_output))
            let s:root = substitute(trim(l:root_output), '\\', '/', 'g')
            let s:is_git_repo = 1
        endif
    endif
    if s:root !=# '/'
        let s:root = substitute(s:root, '[\\/]\+$', '', '')
    endif

    let l:key = s:root . "\x1f" . (a:respect_gitignore ? 'respect' : 'all')
    let l:ttl = max([0, get(g:, 'file_search_index_cache_seconds', 5)])
    if l:ttl > 0 && has_key(s:index_cache, l:key)
        let l:cached = s:index_cache[l:key]
        if reltimefloat(reltime(l:cached.created)) < l:ttl
            let s:files = copy(l:cached.files)
            let s:file_set = copy(l:cached.file_set)
            let s:index_warning = l:cached.warning
            let s:is_git_repo = l:cached.is_git_repo
            return 2
        endif
        call remove(s:index_cache, l:key)
        let l:pos = index(s:index_cache_order, l:key)
        if l:pos >= 0
            call remove(s:index_cache_order, l:pos)
        endif
    endif

    let s:files = []
    let s:file_set = {}
    if has('job') && exists('*job_start') && executable('tr')
                \ && executable('/bin/sh') && !has('win32') && !has('win64')
                \ && (s:is_git_repo || executable('rg'))
        return 1
    endif
    return 0
endfunction

" Stop an unfinished Git index job and remove all temporary files it owns.
function! s:CancelAsyncIndex() abort
    let s:index_generation += 1
    if !empty(s:index_job)
        try
            if job_status(s:index_job) ==# 'run'
                call job_stop(s:index_job, 'kill')
            endif
        catch
        endtry
        let s:index_job = ''
    endif
    for l:tmp in s:index_tempfiles
        if filereadable(l:tmp)
            call delete(l:tmp)
        endif
    endfor
    let s:index_tempfiles = []
    let s:indexing = 0
endfunction

" Finish an async Git enumeration, update the index cache, and resume pending work.
function! s:AsyncIndexExit(generation, tempfiles, job, status) abort
    if a:generation != s:index_generation
        for l:tmp in a:tempfiles
            if filereadable(l:tmp)
                call delete(l:tmp)
            endif
        endfor
        return
    endif
    let s:index_job = ''
    let l:output_file = get(a:tempfiles, 2, '')
    let l:raw = ''
    let l:output_exists = !empty(l:output_file) && filereadable(l:output_file)
    if a:status == 0 && l:output_exists
        try
            let l:raw = join(readfile(l:output_file, 'b'), "\n")
        catch
            let l:raw = ''
        endtry
    endif
    for l:tmp in a:tempfiles
        if filereadable(l:tmp)
            call delete(l:tmp)
        endif
    endfor
    let s:index_tempfiles = []
    let s:indexing = 0

    " A save or explicit cache clear during enumeration makes this snapshot stale.
    if s:index_start_cache_epoch != s:index_cache_epoch
        call s:StartAsyncIndex()
        return
    endif

    if (a:status == 0 || (!s:is_git_repo && a:status == 1)) && l:output_exists
        call s:AddExistingFiles(s:SplitNulOutput(l:raw), s:files, s:file_set)
        call sort(s:files)
        if !s:is_git_repo && s:respect_gitignore
            let s:index_warning = 'Not in a Git repository; .gitignore rules are unavailable'
        endif
        let l:key = s:root . "\x1f" . (s:respect_gitignore ? 'respect' : 'all')
        if get(g:, 'file_search_index_cache_seconds', 5) > 0
            call s:IndexCacheStore(l:key)
        endif
    else
        " A Git command failure is unusual; preserve correctness via sync fallback.
        call s:IndexFiles(s:respect_gitignore)
        let s:index_warning = empty(s:index_warning)
                    \ ? 'Asynchronous Git listing failed; synchronous fallback was used'
                    \ : s:index_warning . ' | asynchronous listing failed'
    endif

    if s:index_purpose ==# 'replace'
        let s:replace_warning = s:index_warning
        let s:replace_stage = 'input'
        call s:ReplaceRender()
        return
    endif

    if s:search_pending
        call s:RunPendingSearch()
    else
        call s:FilterFiles()
        call s:UpdatePreview()
        call s:Render()
        if s:open_after_search && !s:async_search_running
            let s:open_after_search = 0
            call s:OpenSelected()
        endif
    endif
endfunction

" Run git ls-files in the background; NUL path separators are converted to SOH
" in a temporary file, then decoded using the same routine as system() output.
function! s:StartAsyncIndex() abort
    call s:CancelAsyncIndex()
    let s:indexing = 1
    let s:files = []
    let s:file_set = {}
    let l:normal = tempname()
    let l:ignored = tempname()
    let l:output = tempname()
    let s:index_tempfiles = [l:normal, l:ignored, l:output]
    if s:is_git_repo
        let l:git = 'git -c core.quotePath=false -C ' . shellescape(s:root)
                    \ . ' ls-files --full-name -z --cached --others --exclude-standard'
        let l:cmd = l:git . ' > ' . shellescape(l:normal) . ' 2>/dev/null; s1=$?; '
        if !s:respect_gitignore
            let l:ignored_git = 'git -c core.quotePath=false -C ' . shellescape(s:root)
                        \ . ' ls-files --full-name -z --others --ignored --exclude-standard'
            let l:cmd .= l:ignored_git . ' > ' . shellescape(l:ignored) . ' 2>/dev/null; s2=$?; '
        else
            let l:cmd .= ': > ' . shellescape(l:ignored) . '; s2=$?; '
        endif
        let l:ok = '[ "$s1" -eq 0 ] && [ "$s2" -eq 0 ]'
    else
        " rg --files provides NUL-delimited filesystem enumeration outside Git.
        " No ignore policy is claimed for this mode; .git is excluded explicitly.
        let l:cmd = 'cd ' . shellescape(s:root) . ' && rg --files --no-config --hidden --no-ignore --null --glob ''!.git/**'' .'
                    \ . ' > ' . shellescape(l:normal) . ' 2>/dev/null; s1=$?; '
                    \ . ': > ' . shellescape(l:ignored) . '; s2=0; '
        let l:ok = '[ "$s1" -le 1 ] && [ "$s2" -eq 0 ]'
    endif
    let l:cmd .= '{ tr ''\000'' ''\001'' < ' . shellescape(l:normal)
                \ . '; tr ''\000'' ''\001'' < ' . shellescape(l:ignored)
                \ . '; } > ' . shellescape(l:output) . '; '
                \ . 'rm -f ' . shellescape(l:normal) . ' ' . shellescape(l:ignored) . '; '
                \ . l:ok
    let l:generation = s:index_generation
    let s:index_start_cache_epoch = s:index_cache_epoch
    let s:index_job = job_start(['/bin/sh', '-c', l:cmd], {
                \ 'out_io': 'null', 'err_io': 'null',
                \ 'exit_cb': function('s:AsyncIndexExit', [l:generation, copy(s:index_tempfiles)])
                \ })
    if job_status(s:index_job) ==# 'fail'
        let s:index_job = ''
        call s:CancelAsyncIndex()
        call s:IndexFiles(s:respect_gitignore)
        if s:index_purpose ==# 'replace'
            let s:replace_warning = s:index_warning
            let s:replace_stage = 'input'
            call s:ReplaceRender()
        else
            let s:search_pending = 0
            call s:FilterFiles()
            call s:UpdatePreview()
            call s:Render()
        endif
    endif
endfunction


" Purpose: Shell-escape each path before passing explicit path batches to external commands.
function! s:ShellArgs(paths) abort
    let l:args = []
    for l:path in a:paths
        call add(l:args, shellescape(l:path))
    endfor
    return join(l:args, ' ')
endfunction

" Purpose: Last-resort content search implemented in Vim without rg or grep.
function! s:SlowContentSearch(query, paths) abort
    let l:matches = []
    let l:needle = tolower(a:query)

    for l:path in a:paths
        let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . l:path
        try
            let l:lines = readfile(l:absolute, 'b')
        catch
            continue
        endtry

        let l:is_binary = 0
        for l:line in l:lines
            if stridx(l:line, "\n") >= 0
                let l:is_binary = 1
                break
            endif
        endfor
        if l:is_binary
            continue
        endif

        let l:found = 0
        for l:line in l:lines
            if stridx(tolower(l:line), l:needle) >= 0
                let l:found = 1
                break
            endif
        endfor
        if l:found
            call add(l:matches, l:path)
        endif
    endfor

    return l:matches
endfunction

" Search a bounded batch of indexed paths. Explicit paths ensure that this
" mode obeys exactly the same ignore/include policy as the file index.
" Purpose: Search a bounded batch with rg, grep, or the pure-Vim fallback.
function! s:SearchContentBatch(query, paths) abort
    let l:args = s:ShellArgs(a:paths)
    let l:prefix = 'cd ' . shellescape(s:root) . ' && '

    if executable('rg')
        let l:cmd = l:prefix . 'rg --no-config --no-ignore --hidden --no-messages --files-with-matches'
                    \ . ' --fixed-strings --ignore-case --null -- '
                    \ . shellescape(a:query) . ' ' . l:args . ' 2>/dev/null'
        let l:output = system(l:cmd)
        let l:status = v:shell_error
        if l:status <= 1
            return {'paths': s:SplitNulOutput(l:output), 'slow': 0}
        endif
    endif

    if executable('grep')
        let l:cmd = l:prefix . 'grep -I -H -l -F -i -Z -e '
                    \ . shellescape(a:query) . ' -- ' . l:args . ' 2>/dev/null'
        let l:output = system(l:cmd)
        let l:status = v:shell_error
        if l:status <= 1
            return {'paths': s:SplitNulOutput(l:output), 'slow': 0}
        endif
    endif

    return {'paths': s:SlowContentSearch(a:query, a:paths), 'slow': 1}
endfunction

" Purpose: Accept only search results that are members of the current file index.
function! s:CollectContentPathList(paths, target, seen) abort
    for l:raw_path in a:paths
        let l:path = s:NormalizeRelative(l:raw_path)
        if has_key(s:file_set, l:path) && !has_key(a:seen, l:path)
            let a:seen[l:path] = 1
            call add(a:target, l:path)
        endif
    endfor
endfunction

" Purpose: Decode NUL-delimited output and collect only indexed paths.
function! s:CollectContentPaths(output, target, seen) abort
    call s:CollectContentPathList(s:SplitNulOutput(a:output), a:target, a:seen)
endfunction

" Parse ripgrep --count-matches --null output. Each record is:
" path<SOH>count<NL>; Vim system() translates NUL from ripgrep to SOH.
" Purpose: Parse ripgrep records containing a path and total occurrence count.
function! s:ParseRgCountOutput(output, target, seen, counts) abort
    let l:offset = 0
    let l:size = strlen(a:output)

    while l:offset < l:size
        let l:nul = stridx(a:output, "\x01", l:offset)
        if l:nul < 0
            break
        endif

        let l:raw_path = strpart(a:output, l:offset, l:nul - l:offset)
        let l:count_start = l:nul + 1
        let l:newline = stridx(a:output, "\n", l:count_start)
        if l:newline < 0
            let l:count_text = strpart(a:output, l:count_start)
            let l:offset = l:size
        else
            let l:count_text = strpart(a:output, l:count_start,
                        \ l:newline - l:count_start)
            let l:offset = l:newline + 1
        endif

        let l:path = s:NormalizeRelative(l:raw_path)
        if has_key(s:file_set, l:path)
                    \ && !has_key(a:seen, l:path)
            let a:seen[l:path] = 1
            call add(a:target, l:path)
            let a:counts[l:path] = str2nr(l:count_text)
        endif
    endwhile
endfunction

" Count non-overlapping literal occurrences in one line.
" Purpose: Count non-overlapping, case-insensitive literal occurrences in one line.
function! s:CountLineOccurrences(line, pattern) abort
    let l:count = 0
    let l:start = 0
    let l:regex = '\c\V' . escape(a:pattern, '\\')

    while l:start <= strlen(a:line)
        let l:position = match(a:line, l:regex, l:start)
        if l:position < 0
            break
        endif
        let l:end = matchend(a:line, l:regex, l:start)
        let l:count += 1
        let l:start = l:end > l:position ? l:end : l:position + 1
    endwhile

    return l:count
endfunction

" Purpose: Calculate total occurrence count and distinct matching-line count for one file.
function! s:CountFileMetrics(path, query) abort
    if empty(a:query)
        return {'occurrences': 0, 'lines': 0}
    endif

    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    try
        let l:content = readfile(l:absolute, 'b')
    catch
        return {'occurrences': 0, 'lines': 0}
    endtry

    for l:line in l:content
        if stridx(l:line, "\n") >= 0
            return {'occurrences': 0, 'lines': 0}
        endif
    endfor

    let l:occurrences = 0
    let l:matched_lines = 0
    for l:line in l:content
        let l:line_count = s:CountLineOccurrences(l:line, a:query)
        let l:occurrences += l:line_count
        if l:line_count > 0
            let l:matched_lines += 1
        endif
    endfor
    return {'occurrences': l:occurrences, 'lines': l:matched_lines}
endfunction

" Rank content matches by breadth (distinct matching lines), then occurrence
" count, both descending. Path is the deterministic final tie-breaker.
" Count matched lines in bounded groups of already-matching files. This
" avoids platform command-line limits on repositories with many results.
" Purpose: Count distinct matching lines for one bounded batch of matching files.
function! s:CountMatchingLinesBatch(query, paths, line_counts) abort
    if empty(a:paths)
        return
    endif

    let l:args = s:ShellArgs(a:paths)
    let l:cmd = 'cd ' . shellescape(s:root) . ' && rg --no-config --no-ignore --hidden --no-messages'
                \ . ' --count --fixed-strings --ignore-case --null --with-filename -- '
                \ . shellescape(a:query) . ' ' . l:args . ' 2>/dev/null'
    let l:output = system(l:cmd)
    let l:status = v:shell_error
    if l:status <= 1
        call s:ParseRgLineCountOutput(l:output, a:line_counts)
    else
        " Rare fallback for an unusable rg invocation or an unusual filename.
        for l:path in a:paths
            let a:line_counts[l:path] = s:CountFileMetrics(l:path, a:query).lines
        endfor
    endif
endfunction

" Purpose: Batch matching-line counting to stay within operating-system command-line limits.
function! s:CountMatchingLines(query, paths, line_counts) abort
    let l:batch = []
    let l:budget = 0
    let l:limit = (has('win32') || has('win64')) ? 12000 : 160000

    for l:path in a:paths
        let l:cost = strlen(l:path) * 4 + 64
        if !empty(l:batch) && l:budget + l:cost > l:limit
            call s:CountMatchingLinesBatch(a:query, l:batch, a:line_counts)
            let l:batch = []
            let l:budget = 0
        endif
        call add(l:batch, l:path)
        let l:budget += l:cost
    endfor

    if !empty(l:batch)
        call s:CountMatchingLinesBatch(a:query, l:batch, a:line_counts)
    endif
endfunction

" Purpose: Sort by matching lines, then occurrences, then path.
function! s:CompareContentPaths(left, right) abort
    let l:left_lines = get(s:match_line_counts, a:left, 0)
    let l:right_lines = get(s:match_line_counts, a:right, 0)
    if l:left_lines != l:right_lines
        return l:left_lines > l:right_lines ? -1 : 1
    endif

    let l:left_count = get(s:match_counts, a:left, 0)
    let l:right_count = get(s:match_counts, a:right, 0)
    if l:left_count != l:right_count
        return l:left_count > l:right_count ? -1 : 1
    endif

    return a:left ==# a:right ? 0 : (a:left <# a:right ? -1 : 1)
endfunction

" Purpose: Sort content results using the plugin ranking comparator.
function! s:SortContentPaths(paths) abort
    return sort(a:paths, function('s:CompareContentPaths'))
endfunction

" Parse rg --count output (path<SOH>matched-line-count<NL>). Unlike JSON
" mode, this stays compact even for broad one-character searches.
" Purpose: Parse ripgrep path-to-matching-line-count output.
function! s:ParseRgLineCountOutput(output, line_counts) abort
    let l:offset = 0
    let l:size = strlen(a:output)
    while l:offset < l:size
        let l:nul = stridx(a:output, "\x01", l:offset)
        if l:nul < 0
            break
        endif

        let l:raw_path = strpart(a:output, l:offset, l:nul - l:offset)
        let l:count_start = l:nul + 1
        let l:newline = stridx(a:output, "\n", l:count_start)
        if l:newline < 0
            let l:count_text = strpart(a:output, l:count_start)
            let l:offset = l:size
        else
            let l:count_text = strpart(a:output, l:count_start,
                        \ l:newline - l:count_start)
            let l:offset = l:newline + 1
        endif

        let l:path = s:NormalizeRelative(l:raw_path)
        if has_key(s:file_set, l:path)
            let a:line_counts[l:path] = str2nr(l:count_text)
        endif
    endwhile
endfunction

" Purpose: Format a result path with an occurrence suffix when count exceeds one.
function! s:ResultLabel(path) abort
    let l:count = get(s:match_counts, a:path, 0)
    return a:path . (l:count > 1 ? ' (' . l:count . ')' : '')
endfunction

" Purpose: Build a compact context preview and bracket the selected literal match.
function! s:FormatPreviewContext(raw_lines, start_line, target_line, target_col, match_text) abort
    let l:raw = copy(a:raw_lines)
    if !empty(l:raw) && empty(l:raw[-1])
        call remove(l:raw, -1)
    endif
    let l:result = []
    let l:max_chars = max([12, s:popup_width - 20])

    for l:i in range(0, max([0, len(l:raw) - 1]))
        if empty(l:raw)
            break
        endif
        let l:line_no = a:start_line + l:i
        let l:text = l:raw[l:i]
        if l:line_no == a:target_line
            let l:offset = max([0, a:target_col - 1])
            let l:before = strpart(l:text, 0, l:offset)
            let l:matched = strpart(l:text, l:offset, strlen(a:match_text))
            let l:after = strpart(l:text, l:offset + strlen(l:matched))
            let l:before = substitute(l:before, '\t', '  ', 'g')
            let l:matched = substitute(l:matched, '\t', '  ', 'g')
            let l:after = substitute(l:after, '\t', '  ', 'g')
            let l:before = substitute(l:before, '[[:cntrl:]]', ' ', 'g')
            let l:matched = substitute(l:matched, '[[:cntrl:]]', ' ', 'g')
            let l:after = substitute(l:after, '[[:cntrl:]]', ' ', 'g')
            let l:rendered = l:before . '[' . l:matched . ']' . l:after
            if strchars(l:rendered) > l:max_chars
                let l:match_center = strchars(l:before) + 1
                let l:from = max([0, l:match_center - float2nr((l:max_chars - strchars(l:matched) - 2) / 2)])
                let l:rendered = (l:from > 0 ? '…' : '')
                            \ . strcharpart(l:rendered, l:from, l:max_chars - (l:from > 0 ? 1 : 0))
            endif
            let l:text = l:rendered
        else
            let l:text = substitute(l:text, '\t', '  ', 'g')
            let l:text = substitute(l:text, '[[:cntrl:]]', ' ', 'g')
            let l:text = strcharpart(l:text, 0, l:max_chars)
        endif
        call add(l:result, (l:line_no == a:target_line ? '> ' : '  ')
                    \ . printf('%4d: ', l:line_no) . l:text)
    endfor
    return l:result
endfunction

" Purpose: Find an occurrence with a bounded Vim scan when rg is not available.
function! s:FindOccurrenceFallback(path, query, wanted) abort
    " Bounded fallback for installations without ripgrep. This deliberately
    " avoids loading an arbitrarily large file into memory.
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    try
        let l:content = readfile(l:absolute, '', 4000)
    catch
        return {}
    endtry
    let l:pattern = '\c\V' . escape(a:query, '\')
    let l:seen = 0
    for l:i in range(0, max([0, len(l:content) - 1]))
        if empty(l:content)
            break
        endif
        let l:start = 0
        while l:start <= strlen(l:content[l:i])
            let l:pos = match(l:content[l:i], l:pattern, l:start)
            if l:pos < 0
                break
            endif
            let l:end = matchend(l:content[l:i], l:pattern, l:start)
            let l:seen += 1
            if l:seen == a:wanted
                let l:match_text = strpart(l:content[l:i], l:pos, max([0, l:end - l:pos]))
                let l:context_start = max([0, l:i - 1])
                let l:context_end = min([len(l:content) - 1, l:i + 1])
                return {'line': l:i + 1, 'col': l:pos + 1, 'match': l:match_text,
                            \ 'raw_lines': l:content[l:context_start : l:context_end],
                            \ 'start_line': l:context_start + 1}
            endif
            let l:start = l:end > l:pos ? l:end : l:pos + 1
        endwhile
    endfor
    return {}
endfunction

" Purpose: Locate a requested occurrence and fetch only its nearby context lines.
function! s:PreviewOccurrence(path, query, wanted) abort
    if empty(a:query)
        return ['  Type a substring to preview matching lines']
    endif

    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:found = {}

    if executable('rg') && executable('awk')
        " -o emits one record per occurrence. awk exits as soon as the selected
        " occurrence arrives, avoiding a huge result buffer for common queries.
        " --max-count is in matching lines, so wanted occurrences are guaranteed
        " to be included without scanning/outputting every later match.
        let l:cmd = 'rg --no-config --no-messages --color never --hidden --no-ignore'
                    \ . ' --no-filename --line-number --column --only-matching'
                    \ . ' --fixed-strings --ignore-case --max-count ' . a:wanted
                    \ . ' -- ' . shellescape(a:query) . ' ' . shellescape(l:absolute)
                    \ . ' 2>/dev/null | awk -v n=' . a:wanted
                    \ . ' ''NR == n { print; exit }'' 2>/dev/null'
        let l:location = system(l:cmd)
        if v:shell_error == 0 && !empty(l:location)
            let l:location = substitute(l:location, '\n$', '', '')
            let l:parts = matchlist(l:location, '^\(\d\+\):\(\d\+\):')
            if !empty(l:parts)
                let l:found = {'line': str2nr(l:parts[1]),
                            \ 'col': str2nr(l:parts[2]),
                            \ 'match': strpart(l:location, strlen(l:parts[0]))}
            endif
        endif
    endif

    if empty(l:found)
        let l:found = s:FindOccurrenceFallback(a:path, a:query, a:wanted)
        if empty(l:found)
            return ['  [Preview unavailable or occurrence beyond fallback limit]']
        endif
        return s:FormatPreviewContext(l:found.raw_lines, l:found.start_line,
                    \ l:found.line, l:found.col, l:found.match)
    endif

    " Fetch only the three lines surrounding the selected match. sed streams
    " the file and returns just this small window, unlike readfile() on a huge
    " source file.
    let l:start_line = max([1, l:found.line - 1])
    let l:end_line = l:found.line + 1
    let l:sed_cmd = 'sed -n ' . shellescape(l:start_line . ',' . l:end_line . 'p')
                \ . ' ' . shellescape(l:absolute) . ' 2>/dev/null'
    let l:context = system(l:sed_cmd)
    if v:shell_error == 0
        let l:raw_lines = split(l:context, "\n", 1)
        if !empty(l:raw_lines) && empty(l:raw_lines[-1])
            call remove(l:raw_lines, -1)
        endif
        if !empty(l:raw_lines)
            return s:FormatPreviewContext(l:raw_lines, l:start_line,
                        \ l:found.line, l:found.col, l:found.match)
        endif
    endif

    " Fallback for environments without sed; read only up to the target line.
    try
        let l:content = readfile(l:absolute, '', l:found.line + 1)
    catch
        return ['  [Preview unavailable]']
    endtry
    let l:context_start = max([0, l:found.line - 2])
    let l:context_end = min([len(l:content) - 1, l:found.line])
    return s:FormatPreviewContext(l:content[l:context_start : l:context_end],
                \ l:context_start + 1, l:found.line, l:found.col, l:found.match)
endfunction

" Prefer recursive ripgrep for occurrence counts, then count matched lines
" only within the result files for ranking. The file index remains the source
" of truth, so every result is filtered through file_set.
" In ignore-respecting Git mode, git grep supplements ripgrep because Git
" still searches tracked files even when a later .gitignore pattern matches.
" Purpose: Run fast ripgrep search, add tracked Git matches, calculate metrics and rank.
" Purpose: Return whether a project-relative path contains a hidden component.
function! s:IsHiddenPath(path) abort
    let l:normalized = substitute(a:path, '\\', '/', 'g')
    for l:component in split(l:normalized, '/')
        if !empty(l:component) && l:component !=# '.' && l:component !=# '..'
                    \ && strpart(l:component, 0, 1) ==# '.'
            return 1
        endif
    endfor
    return 0
endfunction

" Purpose: Rebuild the search-only candidate set without changing the full project index.
function! s:BuildSearchCandidateFiles() abort
    let s:search_files = []
    let s:search_file_set = {}
    for l:path in s:files
        if s:show_hidden || !s:IsHiddenPath(l:path)
            call add(s:search_files, l:path)
            let s:search_file_set[l:path] = 1
        endif
    endfor
    return len(s:search_files)
endfunction

" Purpose: Keep content-search results inside the current hidden-file candidate set.
function! s:RestrictSearchPaths(paths) abort
    let l:filtered = []
    for l:path in a:paths
        if has_key(s:search_file_set, l:path)
            call add(l:filtered, l:path)
        endif
    endfor
    return l:filtered
endfunction

function! s:SearchContentsWithRg(query) abort
    call s:BuildSearchCandidateFiles()
    if !executable('rg')
        return {'ok': 0, 'paths': []}
    endif

    let l:cmd = 'cd ' . shellescape(s:root) . ' && rg --no-config --no-messages'
                \ . ' --no-ignore-dot --count-matches --fixed-strings --ignore-case --null --hidden'
                \ . ' --glob ' . shellescape('!.git/**')

    if !s:respect_gitignore || !s:is_git_repo
        let l:cmd .= ' --no-ignore'
    endif

    let l:cmd .= ' -- ' . shellescape(a:query) . ' . 2>/dev/null'
    let l:output = system(l:cmd)
    let l:status = v:shell_error
    if l:status > 1
        return {'ok': 0, 'paths': []}
    endif

    let l:paths = []
    let l:seen = {}
    let l:counts = {}
    let l:line_counts = {}
    call s:ParseRgCountOutput(l:output, l:paths, l:seen, l:counts)
    let l:paths = s:RestrictSearchPaths(l:paths)
    let l:allowed_counts = {}
    for l:path in l:paths
        if has_key(l:counts, l:path)
            let l:allowed_counts[l:path] = l:counts[l:path]
        endif
    endfor
    let l:counts = l:allowed_counts

    " Count matching lines only in files already known to match. This avoids
    " sending every matching source line back to Vim and keeps broad queries
    " memory-efficient; batches also stay under OS command-line limits.
    if s:is_git_repo && s:respect_gitignore
        let l:git_cmd = 'git -C ' . shellescape(s:root)
                    \ . ' -c core.quotePath=false grep -I -i -F -l -z -e '
                    \ . shellescape(a:query) . ' 2>/dev/null'
        let l:git_output = system(l:git_cmd)
        let l:git_status = v:shell_error
        if l:git_status > 1
            return {'ok': 0, 'paths': []}
        endif
        call s:CollectContentPaths(l:git_output, l:paths, l:seen)
    endif

    let l:paths = s:RestrictSearchPaths(l:paths)
    call s:CountMatchingLines(a:query, l:paths, l:line_counts)

    " Supplement tracked files skipped by rg because of ignore rules, and
    " recover metrics for paths that could not be parsed by the compact rg
    " count output (for example, unusual filenames).
    for l:path in l:paths
        if !has_key(l:counts, l:path) || !has_key(l:line_counts, l:path)
            let l:metrics = s:CountFileMetrics(l:path, a:query)
            if !has_key(l:counts, l:path)
                let l:counts[l:path] = l:metrics.occurrences
            endif
            if !has_key(l:line_counts, l:path)
                let l:line_counts[l:path] = l:metrics.lines
            endif
        endif
    endfor

    let s:match_counts = l:counts
    let s:match_line_counts = l:line_counts
    return {'ok': 1, 'paths': s:SortContentPaths(l:paths),
                \ 'counts': l:counts, 'line_counts': l:line_counts}
endfunction

" Purpose: Run content search with portable fallback and return ranked file paths.
function! s:SearchContents(query) abort
    call s:BuildSearchCandidateFiles()
    let l:recursive = s:SearchContentsWithRg(a:query)
    if l:recursive.ok
        let s:match_counts = l:recursive.counts
        let s:match_line_counts = l:recursive.line_counts
        return l:recursive.paths
    endif

    " Portable fallback for systems without a usable ripgrep executable.
    " Batches are bounded to avoid ARG_MAX failures in large repositories.
    let l:matches = []
    let l:seen = {}
    let l:batch = []
    let l:budget = 0
    let l:limit = (has('win32') || has('win64')) ? 12000 : 160000

    for l:path in s:search_files
        let l:cost = strlen(l:path) * 4 + 64
        if !empty(l:batch) && l:budget + l:cost > l:limit
            let l:result = s:SearchContentBatch(a:query, l:batch)
            if l:result.slow
                let s:content_warning = 'rg/grep unavailable; content search is using a slower fallback'
            endif
            call s:CollectContentPathList(l:result.paths, l:matches, l:seen)
            let l:batch = []
            let l:budget = 0
        endif
        call add(l:batch, l:path)
        let l:budget += l:cost
    endfor

    if !empty(l:batch)
        let l:result = s:SearchContentBatch(a:query, l:batch)
        if l:result.slow
            let s:content_warning = 'rg/grep unavailable; content search is using a slower fallback'
        endif
        call s:CollectContentPathList(l:result.paths, l:matches, l:seen)
    endif

    let s:match_counts = {}
    let s:match_line_counts = {}
    for l:path in l:matches
        let l:metrics = s:CountFileMetrics(l:path, a:query)
        let s:match_counts[l:path] = l:metrics.occurrences
        let s:match_line_counts[l:path] = l:metrics.lines
    endfor
    return s:SortContentPaths(l:matches)
endfunction

" Purpose: Convert a user glob into a case-insensitive Vim regex.
" In path mode, '*' never crosses '/', while '**' may cross any separators.
function! s:GlobRegex(pattern, path_mode) abort
    let l:regex = '\c\v'
    let l:i = 0
    let l:length = strchars(a:pattern)

    while l:i < l:length
        let l:char = strcharpart(a:pattern, l:i, 1)
        if l:char ==# '*'
            let l:next = l:i + 1 < l:length
                        \ ? strcharpart(a:pattern, l:i + 1, 1) : ''
            if a:path_mode && l:next ==# '*'
                let l:after_globstar = l:i + 2 < l:length
                            \ ? strcharpart(a:pattern, l:i + 2, 1) : ''
                if l:after_globstar ==# '/'
                    " A globstar followed by '/' represents zero or more
                    " directory components, including a file at this level.
                    let l:regex .= '(.*/)?'
                    let l:i += 3
                else
                    let l:regex .= '.*'
                    let l:i += 2
                    while l:i < l:length && strcharpart(a:pattern, l:i, 1) ==# '*'
                        let l:i += 1
                    endwhile
                endif
                continue
            endif
            let l:regex .= a:path_mode ? '[^/]*' : '.*'
        else
            let l:regex .= escape(l:char, '\\.^$~[](){}*+?|')
        endif
        let l:i += 1
    endwhile

    return l:regex
endfunction

" Purpose: Compile filename/path input; path fragments are deliberately unanchored.
" Plain queries preserve basename-substring behavior. A slash switches to path
" matching; a trailing slash or terminal /* / ** selects directories, not names.
function! s:BuildNamePattern(query) abort
    let l:query = substitute(a:query, '\\', '/', 'g')
    let l:query = substitute(l:query, '^\./', '', '')

    if stridx(l:query, '/') < 0
        let l:regex = s:GlobRegex(l:query, 0)
        if l:query !~# '\*$'
            let l:regex .= '.*'
        endif
        return {'pattern': l:regex, 'path': 0, 'directory': 0}
    endif

    " A leading slash cannot anchor a project-relative index, so ignore it.
    let l:query = substitute(l:query, '^/\+', '', '')
    let l:directory = 0

    if l:query =~# '/$'
        let l:directory = 1
        let l:query = strpart(l:query, 0, strlen(l:query) - 1)
        if l:query ==# '**'
            let l:regex = '.*'
        elseif l:query ==# '*'
            let l:regex = '[^/]+/'
        elseif l:query =~# '/\*\*$'
            let l:base = strpart(l:query, 0, strlen(l:query) - 3)
            let l:regex = s:GlobRegex(l:base, 1) . '/.*'
        elseif l:query =~# '/\*$'
            let l:base = strpart(l:query, 0, strlen(l:query) - 2)
            let l:regex = s:GlobRegex(l:base, 1) . '/[^/]+/'
        else
            let l:regex = s:GlobRegex(l:query, 1) . '/'
        endif
    elseif l:query =~# '/\*\{1,2}$'
        let l:directory = 1
        let l:tail = l:query =~# '/\*\*$' ? '**' : '*'
        let l:base = strpart(l:query, 0, strlen(l:query) - strlen(l:tail) - 1)
        let l:regex = s:GlobRegex(l:base, 1)
        let l:regex .= l:tail ==# '*' ? '/[^/]+/' : '/.*'
    else
        let l:regex = s:GlobRegex(l:query, 1)
        " The final component is a basename, not a directory prefix. Match
        " its remaining characters and require the end of the indexed path.
        if l:query !~# '\*$'
            let l:regex .= '[^/]*'
        endif
        let l:regex .= '$'
    endif

    return {'pattern': l:regex, 'path': 1, 'directory': l:directory}
endfunction

" Purpose: Score a subsequence fuzzy match; word starts and adjacent chars rank higher.
function! s:FuzzyScore(haystack, needle) abort
    if empty(a:needle)
        return 0
    endif
    let l:position = 0
    let l:score = 0
    let l:last = -2
    for l:char in split(a:needle, '\zs')
        let l:found = stridx(strpart(a:haystack, l:position), l:char)
        if l:found < 0
            return -1
        endif
        let l:position += l:found
        let l:boundary = l:position == 0 || strpart(a:haystack, l:position - 1, 1) =~# '[/_. -]'
        let l:score += 10 + (l:last + 1 == l:position ? 12 : 0) + (l:boundary ? 8 : 0) - min([8, l:position / 8])
        let l:last = l:position
        let l:position += 1
    endfor
    return l:score - (strlen(a:haystack) - l:position) / 20
endfunction

" Purpose: Sort fuzzy candidates by score descending and path ascending.
function! s:CompareFuzzyPaths(left, right) abort
    let l:left = get(s:fuzzy_scores, a:left, -1)
    let l:right = get(s:fuzzy_scores, a:right, -1)
    if l:left != l:right
        return l:right - l:left
    endif
    return a:left ==# a:right ? 0 : (a:left ># a:right ? 1 : -1)
endfunction

" Purpose: Persist bounded search history as one query per line.
function! s:SearchHistorySave() abort
    let l:dir = expand(g:file_search_data_dir)
    if mkdir(l:dir, 'p', 0700) != 1 && !isdirectory(l:dir)
        return 0
    endif
    let l:path = l:dir . '/search-history.txt'
    let l:temp = l:path . '.tmp-' . getpid()
    if writefile(s:search_history, l:temp) != 0
        call delete(l:temp)
        return 0
    endif
    if exists('*setfperm')
        call setfperm(l:temp, 'rw-------')
    endif
    if rename(l:temp, l:path) != 0
        call delete(l:temp)
        return 0
    endif
    return 1
endfunction

function! s:SearchHistoryLoad() abort
    let l:path = expand(g:file_search_data_dir . '/search-history.txt')
    if filereadable(l:path)
        try
            let s:search_history = readfile(l:path)
            let s:search_history = s:search_history[max([0, len(s:search_history) - max([1, g:file_search_history_limit])]) :]
        catch
            let s:search_history = []
        endtry
    endif
endfunction

function! s:RememberSearchQuery() abort
    if empty(s:query)
        return
    endif
    if empty(s:search_history) || s:search_history[-1] !=# s:query
        call filter(s:search_history, 'v:val !=# s:query')
        call add(s:search_history, s:query)
        let s:search_history = s:search_history[max([0, len(s:search_history) - max([1, g:file_search_history_limit])]) :]
        call s:SearchHistorySave()
    endif
    let s:search_history_index = -1
endfunction

function! s:SearchHistoryMove(direction) abort
    if empty(s:search_history)
        return
    endif
    if s:search_history_index < 0
        let s:search_history_draft = s:query
        let s:search_history_index = len(s:search_history)
    endif
    let s:search_history_index = max([0, min([len(s:search_history), s:search_history_index + a:direction])])
    let s:query = s:search_history_index == len(s:search_history)
                \ ? s:search_history_draft : s:search_history[s:search_history_index]
    let s:selected = 0
    call s:ScheduleSearch()
endfunction

" Purpose: Apply the current content/name query to the indexed candidate list.
function! s:FilterFiles() abort
    call s:BuildSearchCandidateFiles()
    let s:matches = []
    let s:match_counts = {}
    let s:match_line_counts = {}
    let s:content_warning = ''
    let s:error = s:index_warning

    let l:query = s:query
    let l:extension_filter = []
    if l:query =~? '^ext:[^ ]\+\s*'
        let l:filter = matchstr(l:query, '^ext:[^ ]\+')
        for l:extension in split(strpart(l:filter, 4), ',')
            let l:extension = tolower(substitute(l:extension, '^\.', '', ''))
            if !empty(l:extension)
                call add(l:extension_filter, l:extension)
            endif
        endfor
        let l:query = substitute(l:query, '^ext:[^ ]\+\s*', '', '')
    endif
    let s:effective_query = l:query
    if empty(l:query)
        let s:matches = copy(s:search_files)
    elseif s:search_mode ==# 'content'
        let s:matches = s:SearchContents(l:query)
    else
        if s:search_fuzzy
            let s:fuzzy_scores = {}
            let l:needle = substitute(tolower(l:query), '\s\+', '', 'g')
            for l:file in s:search_files
                let l:subject = l:query =~# '[/\\]' ? tolower(l:file) : tolower(fnamemodify(l:file, ':t'))
                let l:score = s:FuzzyScore(l:subject, l:needle)
                if l:score >= 0
                    let s:fuzzy_scores[l:file] = l:score
                    call add(s:matches, l:file)
                endif
            endfor
            call sort(s:matches, function('s:CompareFuzzyPaths'))
        elseif !empty(l:query)
            let l:spec = s:BuildNamePattern(l:query)
            try
                call match('', l:spec.pattern)
            catch
                let s:error = empty(s:error)
                            \ ? 'Invalid filename/path mask'
                            \ : s:error . ' | Invalid filename/path mask'
                return
            endtry
            for l:file in s:search_files
                let l:subject = l:spec.path
                            \ ? substitute(l:file, '\\\\', '/', 'g')
                            \ : fnamemodify(l:file, ':t')
                if match(l:subject, l:spec.pattern) >= 0
                    call add(s:matches, l:file)
                endif
            endfor
        else
            let s:matches = copy(s:search_files)
        endif
    endif
    if !empty(l:extension_filter)
        let l:extension_matches = []
        for l:file in s:matches
            if index(l:extension_filter, tolower(fnamemodify(l:file, ':e'))) >= 0
                call add(l:extension_matches, l:file)
            endif
        endfor
        let s:matches = l:extension_matches
    endif

    if !empty(s:content_warning)
        let s:error = empty(s:error) ? s:content_warning : s:error . ' | ' . s:content_warning
    endif
    if empty(s:matches)
        let s:selected = 0
    else
        let s:selected = max([0, min([s:selected, len(s:matches) - 1])])
    endif
endfunction

" Purpose: Return the user-facing search-mode name.
function! s:ModeLabel() abort
    return s:search_mode ==# 'content' ? 'file contents' : 'file name/path'
endfunction

" Drop recent preview contexts after a file is saved or changed on disk.
function! s:PreviewCacheClear() abort
    let s:preview_cache = {}
    let s:preview_cache_order = []
endfunction

" Store a rendered preview with a short TTL and bounded entry count.
function! s:PreviewCacheStore(key, lines) abort
    let s:preview_cache[a:key] = {'created': reltime(), 'lines': copy(a:lines)}
    let l:old = index(s:preview_cache_order, a:key)
    if l:old >= 0
        call remove(s:preview_cache_order, l:old)
    endif
    call add(s:preview_cache_order, a:key)
    while len(s:preview_cache_order) > 64
        let l:expired = remove(s:preview_cache_order, 0)
        if has_key(s:preview_cache, l:expired)
            call remove(s:preview_cache, l:expired)
        endif
    endwhile
endfunction

" Stop a preview job when selection/query changes or its popup closes.
function! s:CancelAsyncPreview() abort
    let s:preview_generation += 1
    if !empty(s:preview_job)
        try
            if job_status(s:preview_job) ==# 'run'
                call job_stop(s:preview_job, 'kill')
            endif
        catch
        endtry
        let s:preview_job = ''
    endif
    let s:preview_job_output = ''
endfunction

" Receive the small metadata/context payload emitted by the preview job.
function! s:AsyncPreviewOut(generation, channel, message) abort
    if a:generation != s:preview_generation
        return
    endif
    let s:preview_job_output .= a:message
endfunction

" Format and memoize a completed preview; stale callbacks never redraw the popup.
function! s:AsyncPreviewExit(generation, job, status) abort
    if a:generation != s:preview_generation
        return
    endif
    let s:preview_job = ''
    let l:output = s:preview_job_output
    let s:preview_job_output = ''
    let l:separator = stridx(l:output, "\x02")
    if a:status != 0 || l:separator < 0
        let s:preview_lines = ['  [Preview unavailable]']
    else
        let l:metadata = strpart(l:output, 0, l:separator)
        if l:metadata ==# 'NONE'
            let s:preview_lines = ['  [Occurrence not found on disk]']
        else
            let l:parts = matchlist(l:metadata, '^\(\d\+\):\(\d\+\):\(.*\)$')
            if empty(l:parts)
                let s:preview_lines = ['  [Could not parse preview location]']
            else
                let l:line = str2nr(l:parts[1])
                let l:col = str2nr(l:parts[2])
                let l:match = l:parts[3]
                let l:raw = strpart(l:output, l:separator + 1)
                let l:context = split(l:raw, "\n", 1)
                if !empty(l:context) && empty(l:context[-1])
                    call remove(l:context, -1)
                endif
                let s:preview_lines = s:FormatPreviewContext(l:context,
                            \ max([1, l:line - 1]), l:line, l:col, l:match)
            endif
        endif
    endif

    let l:key = s:root . "\x1f" . s:preview_request_path . "\x1f"
                \ . s:preview_request_query . "\x1f" . s:preview_request_occurrence
    call s:PreviewCacheStore(l:key, s:preview_lines)

    if s:popup != -1 && s:preview_request_path ==# s:preview_occurrence_path
                \ && s:preview_request_query ==# s:query
                \ && s:preview_request_occurrence == s:preview_occurrence
                \ && s:preview_request_path ==# get(s:matches, s:selected, '')
        call s:Render()
    endif
endfunction

" Launch ripgrep/awk/sed as one background task so moving between occurrences
" does not synchronously stall Vim. The result is deliberately limited to three
" context lines plus one location record.
function! s:StartAsyncPreview(path, query, wanted) abort
    if !has('job') || !exists('*job_start') || !executable('rg')
                \ || !executable('awk') || !executable('sed')
                \ || !executable('/bin/sh') || has('win32') || has('win64')
        return 0
    endif

    call s:CancelAsyncPreview()
    let s:preview_request_path = a:path
    let s:preview_request_query = a:query
    let s:preview_request_occurrence = a:wanted
    let s:preview_lines = ['  Loading preview…']
    let s:preview_job_output = ''
    let l:generation = s:preview_generation
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:rg = 'rg --no-config --no-messages --color never --hidden --no-ignore'
                \ . ' --no-filename --line-number --column --only-matching'
                \ . ' --fixed-strings --ignore-case --max-count ' . a:wanted
                \ . ' -- ' . shellescape(a:query) . ' ' . shellescape(l:absolute)
    let l:awk = shellescape('NR == n { print; exit }')
    let l:cmd = 'loc=$(' . l:rg . ' 2>/dev/null | awk -v n=' . a:wanted . ' ' . l:awk . '); '
                \ . 'if [ -z "$loc" ]; then printf "NONE\\002"; exit 0; fi; '
                \ . 'line=${loc%%:*}; rest=${loc#*:}; col=${rest%%:*}; '
                \ . 'start=$((line - 1)); if [ "$start" -lt 1 ]; then start=1; fi; '
                \ . 'end=$((line + 1)); printf "%s\\002" "$loc"; '
                \ . 'sed -n "${start},${end}p" ' . shellescape(l:absolute) . ' 2>/dev/null'
    let l:opts = {
                \ 'out_mode': 'raw',
                \ 'err_io': 'null',
                \ 'out_cb': function('s:AsyncPreviewOut', [l:generation]),
                \ 'exit_cb': function('s:AsyncPreviewExit', [l:generation])
                \ }
    let s:preview_job = job_start(['/bin/sh', '-c', l:cmd], l:opts)
    if job_status(s:preview_job) ==# 'fail'
        let s:preview_job = ''
        return 0
    endif
    return 1
endfunction

" Return cached preview, run the background lookup, or use the portable fallback.
function! s:RequestPreview(path, query, wanted) abort
    call s:CancelAsyncPreview()
    let s:preview_request_path = a:path
    let s:preview_request_query = a:query
    let s:preview_request_occurrence = a:wanted
    let l:key = s:root . "\x1f" . a:path . "\x1f" . a:query . "\x1f" . a:wanted
    if has_key(s:preview_cache, l:key)
        let l:cached = s:preview_cache[l:key]
        if reltimefloat(reltime(l:cached.created)) < max([0, get(g:, 'file_search_preview_cache_seconds', 5)])
            let s:preview_lines = copy(l:cached.lines)
            return
        endif
        call remove(s:preview_cache, l:key)
        let l:cache_pos = index(s:preview_cache_order, l:key)
        if l:cache_pos >= 0
            call remove(s:preview_cache_order, l:cache_pos)
        endif
    endif
    if s:StartAsyncPreview(a:path, a:query, a:wanted)
        return
    endif
    let s:preview_request_path = a:path
    let s:preview_request_query = a:query
    let s:preview_request_occurrence = a:wanted
    let s:preview_lines = s:PreviewOccurrence(a:path, a:query, a:wanted)
    call s:PreviewCacheStore(l:key, s:preview_lines)
endfunction

" Refresh preview lines for the selected content result and occurrence.
function! s:UpdatePreview() abort
    let s:preview_lines = []
    if s:search_mode ==# 'content' && !empty(s:effective_query) && !empty(s:matches)
        let l:path = s:matches[s:selected]
        if l:path !=# s:preview_occurrence_path
            let s:preview_occurrence_path = l:path
            let s:preview_occurrence = 1
        endif
        let l:total = get(s:match_counts, l:path, 0)
        let s:preview_occurrence = max([1, min([s:preview_occurrence, max([1, l:total])])])
        call s:RequestPreview(l:path, s:effective_query, s:preview_occurrence)
    else
        call s:CancelAsyncPreview()
        let s:preview_occurrence = 1
        let s:preview_occurrence_path = ''
    endif
endfunction

" Purpose: Determine whether this Vim can run the NUL-safe asynchronous rg pipeline.
function! s:AsyncSearchSupported() abort
    return has('job') && exists('*job_start') && executable('rg')
                \ && executable('tr') && executable('/bin/sh')
                \ && !has('win32') && !has('win64')
endfunction

" Purpose: Split indexed paths into shell-safe batches below command-line limits.
function! s:BuildSearchBatches() abort
    let l:batches = []
    let l:batch = []
    let l:budget = 0
    let l:limit = 120000
    for l:path in s:search_files
        let l:cost = strlen(l:path) * 4 + 64
        if !empty(l:batch) && l:budget + l:cost > l:limit
            call add(l:batches, l:batch)
            let l:batch = []
            let l:budget = 0
        endif
        call add(l:batch, l:path)
        let l:budget += l:cost
    endfor
    if !empty(l:batch)
        call add(l:batches, l:batch)
    endif
    return l:batches
endfunction

" Purpose: Construct one count-metrics command; tr converts NUL separators to SOH for Vim raw channels.
function! s:BuildAsyncRgCommand(query, paths, metric, output_file) abort
    let l:args = s:ShellArgs(a:paths)
    let l:option = a:metric ==# 'occ' ? '--count-matches' : '--count'
    let l:tmp = shellescape(a:output_file)
    let l:cmd = 'cd ' . shellescape(s:root) . ' && { rg --no-config --no-ignore'
                \ . ' --hidden --no-messages ' . l:option
                \ . ' --fixed-strings --ignore-case --null --with-filename --'
                \ . ' ' . shellescape(a:query) . ' ' . l:args
                \ . ' > ' . l:tmp . ' 2>/dev/null; status=$?;'
                \ . " tr '\\000' '\\001' < " . l:tmp
                \ . '; rm -f ' . l:tmp . '; exit "$status"; }'
    return l:cmd
endfunction

" Purpose: Stop jobs belonging to the current content search and invalidate their callbacks.
function! s:CancelAsyncSearch() abort
    let s:search_generation += 1
    for l:job in s:search_jobs
        if job_status(l:job) ==# 'run'
            call job_stop(l:job, 'kill')
        endif
    endfor
    for l:tmp in values(get(s:async_batch_outputs, 'tempfiles', {}))
        if filereadable(l:tmp)
            call delete(l:tmp)
        endif
    endfor
    let s:search_jobs = []
    let s:async_search_running = 0
    let s:async_batches = []
    let s:async_batch_index = 0
    let s:async_batch_outputs = {}
    let s:async_seen = {}
    let s:open_after_search = 0
endfunction

" Purpose: Append one raw metric stream while ignoring stale query generations.
function! s:AsyncSearchOut(generation, metric, channel, message) abort
    if a:generation != s:search_generation || !s:async_search_running
        return
    endif
    if has_key(s:async_batch_outputs, a:metric)
        let s:async_batch_outputs[a:metric] .= a:message
    endif
endfunction

" Purpose: Record a metric job exit and continue once both rg jobs are complete.
function! s:AsyncSearchExit(generation, metric, job, status) abort
    if a:generation != s:search_generation || !s:async_search_running
        return
    endif
    if !has_key(s:async_batch_outputs, 'done')
        return
    endif
    let s:async_batch_outputs.done[a:metric] = 1
    let s:async_batch_outputs.status[a:metric] = a:status
    if get(s:async_batch_outputs.done, 'occ', 0)
                \ && get(s:async_batch_outputs.done, 'lines', 0)
        call s:FinishAsyncBatch(a:generation)
    endif
endfunction

" Purpose: Start the next pair of occurrence-count and matching-line-count jobs.
function! s:StartNextAsyncBatch(generation) abort
    if a:generation != s:search_generation || !s:async_search_running
        return
    endif
    if s:async_batch_index >= len(s:async_batches)
        call s:FinishAsyncSearch(a:generation)
        return
    endif

    let l:paths = s:async_batches[s:async_batch_index]
    let s:async_batch_outputs = {
                \ 'occ': '', 'lines': '',
                \ 'done': {'occ': 0, 'lines': 0},
                \ 'status': {}, 'tempfiles': {}
                \ }
    let s:search_jobs = []
    for l:metric in ['occ', 'lines']
        let l:tmp = tempname()
        let s:async_batch_outputs.tempfiles[l:metric] = l:tmp
        let l:cmd = s:BuildAsyncRgCommand(s:query, l:paths, l:metric, l:tmp)
        let l:opts = {
                    \ 'out_mode': 'raw',
                    \ 'err_io': 'null',
                    \ 'out_cb': function('s:AsyncSearchOut', [a:generation, l:metric]),
                    \ 'exit_cb': function('s:AsyncSearchExit', [a:generation, l:metric])
                    \ }
        let l:job = job_start(['/bin/sh', '-c', l:cmd], l:opts)
        if job_status(l:job) ==# 'fail'
            call s:AsyncSearchFallback(a:generation, 'Could not start rg background job')
            return
        endif
        call add(s:search_jobs, l:job)
    endfor
endfunction

" Purpose: Parse one completed batch, merge its metrics, then start the next batch.
function! s:FinishAsyncBatch(generation) abort
    if a:generation != s:search_generation || !s:async_search_running
        return
    endif
    if get(s:async_batch_outputs.status, 'occ', 0) > 1
                \ || get(s:async_batch_outputs.status, 'lines', 0) > 1
        call s:AsyncSearchFallback(a:generation, 'rg background search failed; using synchronous fallback')
        return
    endif

    for l:tmp in values(get(s:async_batch_outputs, 'tempfiles', {}))
        if filereadable(l:tmp)
            call delete(l:tmp)
        endif
    endfor

    call s:ParseRgCountOutput(s:async_batch_outputs.occ, s:matches,
                \ s:async_seen, s:match_counts)
    call s:ParseRgLineCountOutput(s:async_batch_outputs.lines, s:match_line_counts)
    let s:search_jobs = []
    let s:async_batch_index += 1
    call s:StartNextAsyncBatch(a:generation)
endfunction

" Purpose: Complete an asynchronous content search and refresh results and preview.
function! s:FinishAsyncSearch(generation) abort
    if a:generation != s:search_generation || !s:async_search_running
        return
    endif
    let s:matches = s:SortContentPaths(s:matches)
    let s:async_search_running = 0
    let s:search_pending = 0
    let s:search_jobs = []
    let s:async_batches = []
    let s:async_batch_outputs = {}
    let s:async_seen = {}
    call s:UpdatePreview()
    call s:Render()

    if s:open_after_search
        let s:open_after_search = 0
        call s:OpenSelected()
    endif
endfunction

" Purpose: Fall back to the proven synchronous search if an async job cannot run.
function! s:AsyncSearchFallback(generation, reason) abort
    if a:generation != s:search_generation
        return
    endif
    let l:open_after = s:open_after_search
    let l:warning = a:reason
    call s:CancelAsyncSearch()
    let s:open_after_search = l:open_after
    let s:search_pending = 0
    call s:FilterFiles()
    let s:content_warning = l:warning
    call s:UpdatePreview()
    call s:Render()
    if s:open_after_search
        let s:open_after_search = 0
        call s:OpenSelected()
    endif
endfunction

" Purpose: Initialize a new asynchronous search and its indexed path batches.
function! s:StartAsyncContentSearch() abort
    if !s:AsyncSearchSupported()
        return 0
    endif
    let s:search_generation += 1
    let s:async_search_running = 1
    let s:async_batches = s:BuildSearchBatches()
    let s:async_batch_index = 0
    let s:async_seen = {}
    let s:matches = []
    let s:match_counts = {}
    let s:match_line_counts = {}
    let s:content_warning = ''
    call s:Render()
    call s:StartNextAsyncBatch(s:search_generation)
    return 1
endfunction

" Purpose: Timer callback that executes a pending debounced search.
function! s:DelayedSearch(timer) abort
    let s:search_timer = -1
    if s:popup == -1 || !s:search_pending
        return
    endif
    call s:RunPendingSearch()
endfunction

" Purpose: Start pending work now; content queries use async rg when supported.
function! s:RunPendingSearch() abort
    if s:indexing
        return
    endif
    if !s:search_pending || s:async_search_running
        return
    endif
    if s:search_timer != -1 && exists('*timer_stop')
        call timer_stop(s:search_timer)
    endif
    let s:search_timer = -1
    call s:BuildSearchCandidateFiles()

    if s:search_mode ==# 'content' && !empty(s:query) && s:query !~? '^ext:' && s:StartAsyncContentSearch()
        return
    endif

    let s:search_pending = 0
    call s:FilterFiles()
    call s:UpdatePreview()
    call s:Render()
endfunction

" Purpose: Debounce typed content/filename queries before recomputing results.
function! s:ScheduleSearch() abort
    call s:CancelAsyncSearch()
    call s:CancelAsyncPreview()
    let s:open_after_search = 0
    let s:search_pending = 1
    let s:matches = []
    let s:match_counts = {}
    let s:match_line_counts = {}
    let s:preview_lines = []
    let s:preview_occurrence = 1
    let s:preview_occurrence_path = ''
    if s:search_timer != -1 && exists('*timer_stop')
        call timer_stop(s:search_timer)
    endif
    if exists('*timer_start')
        let l:delay = exists('g:file_search_debounce_ms')
                    \ ? max([100, g:file_search_debounce_ms]) : 300
        let s:search_timer = timer_start(l:delay, function('s:DelayedSearch'))
        call s:Render()
    else
        call s:RunPendingSearch()
    endif
endfunction

" Purpose: Render the main search popup, results, status, and optional content preview.
function! s:Render() abort
    if s:popup == -1 || empty(popup_getpos(s:popup))
        return
    endif

    let s:error = s:index_warning
    if !empty(s:content_warning)
        let s:error = empty(s:error) ? s:content_warning : s:error . ' | ' . s:content_warning
    endif

    let l:height = min([max([4, g:file_search_max_height]), max([4, &lines - 6])])
    let l:show_preview = s:search_mode ==# 'content' && s:search_preview_enabled
                \ && !empty(s:effective_query) && l:height >= 8 && !s:search_pending
    let l:preview_rows = l:show_preview ? 7 : 0
    let l:visible = max([1, l:height - 3 - l:preview_rows])
    let l:offset = max([0, min([
                \ s:selected - float2nr(l:visible / 2),
                \ len(s:matches) - l:visible
                \ ])])
    let l:ignore = s:respect_gitignore ? 'respect .gitignore' : 'include ignored'
    let l:rule = repeat('-', min([64, max([24, s:popup_width - 8])]))

    let l:status = s:indexing ? ' Indexing files…' : (s:search_pending ? ' Searching…' : ' ' . len(s:matches) . ' matches' . (s:search_fuzzy ? ' | fuzzy' : '') . (s:query =~? '^ext:' ? ' | extension filter' : ''))
    let l:status .= ' | hidden ' . (s:show_hidden ? 'ON' : 'OFF')
    let l:status .= ' | Git ignore ' . (s:respect_gitignore ? 'ON' : 'OFF')
    let l:lines = [
                \ ' Search ' . s:ModeLabel() . ' [' . l:ignore . ']: ' . s:query,
                \ l:status . (empty(s:error) ? '' : ' | ' . s:error),
                \ l:rule,
                \ ' F6: Git ignore | F7: hidden | Ctrl-Up/Down: history',
                \ ' Ctrl-X/V/T: split/vsplit/tab | Ctrl-O: preview | Ctrl-F: fuzzy'
                \ ]

    if s:indexing
        call add(l:lines, ' Building the Git file index in the background…')
    elseif s:search_pending
        call add(l:lines, ' Searching after typing…')
    elseif empty(s:matches)
        call add(l:lines, ' No matching files')
    else
        let l:last = min([len(s:matches) - 1, l:offset + l:visible - 1])
        for l:i in range(l:offset, l:last)
            let l:prefix = l:i == s:selected ? '> ' : '  '
            call add(l:lines, l:prefix . s:ResultLabel(s:matches[l:i]))
        endfor
    endif

    if l:show_preview
        call add(l:lines, l:rule)
        if empty(s:matches)
            call add(l:lines, ' Preview: no selected file')
            call add(l:lines, '  Enter a substring to preview matching lines')
            call add(l:lines, '')
            call add(l:lines, '')
        else
            let l:path = s:matches[s:selected]
            let l:count = get(s:match_counts, l:path, 0)
            let l:counter = l:count > 1
                        \ ? ' Preview (' . s:preview_occurrence . '/' . l:count . '): '
                        \ : ' Preview: '
            call add(l:lines, l:counter . l:path)
            let l:preview = copy(s:preview_lines)
            while len(l:preview) < 3
                call add(l:preview, '')
            endwhile
            call extend(l:lines, l:preview)
        endif
    endif

    " Resize to the rendered text explicitly. Reserving preview rows above keeps
    " the preview visible instead of letting the result list consume the popup.
    call popup_setoptions(s:popup, {'maxheight': min([len(l:lines), max([4, &lines - 6])])})
    call popup_settext(s:popup, l:lines)
endfunction

" Purpose: Stop the pending search timer and close the main search popup.
function! s:Close() abort
    if s:popup != -1
        call s:RememberSearchQuery()
    endif
    call s:CancelAsyncPreview()
    call s:CancelAsyncIndex()
    if s:search_timer != -1 && exists('*timer_stop')
        call timer_stop(s:search_timer)
        let s:search_timer = -1
    endif
    call s:CancelAsyncSearch()
    let s:search_pending = 0
    if s:popup != -1
        if !empty(popup_getpos(s:popup))
            call popup_close(s:popup)
        endif
        let s:popup = -1
    endif
endfunction

" Purpose: Open the selected result and position the cursor at the chosen content occurrence.
function! s:OpenSelected(...) abort
    if empty(s:matches) || s:selected < 0 || s:selected >= len(s:matches)
        return
    endif

    let l:path = s:root . (s:root =~# '/$' ? '' : '/') . s:matches[s:selected]
    let l:jump_to_content_match = s:search_mode ==# 'content' && !empty(s:effective_query)
    let l:match_count = get(s:match_counts, s:matches[s:selected], 0)
    let l:wanted_occurrence = max([1, min([s:preview_occurrence, max([1, l:match_count])])])
    let l:pattern = '\c\V' . escape(s:effective_query, '\')

    let l:open_mode = a:0 ? a:1 : 'edit'
    call s:RememberSearchQuery()
    call s:Close()
    if l:open_mode ==# 'split'
        execute 'split ' . fnameescape(l:path)
    elseif l:open_mode ==# 'vsplit'
        execute 'vsplit ' . fnameescape(l:path)
    elseif l:open_mode ==# 'tab'
        execute 'tabedit ' . fnameescape(l:path)
    else
        execute 'edit ' . fnameescape(l:path)
    endif

    if l:jump_to_content_match
        call cursor(1, 1)
        " Always update Vim's search register so n/N continues this query even
        " when the selected file contains only one occurrence.
        let @/ = l:pattern
        if search(@/, 'cW') > 0
            " Subsequent search() calls advance to the selected occurrence,
            " including another occurrence on the same line.
            for l:i in range(2, l:wanted_occurrence)
                if search(@/, 'W') == 0
                    break
                endif
            endfor
        endif
    endif
endfunction

" Purpose: Dispatch keyboard input for the main search popup.
" Purpose: Toggle the active Git ignore policy and rebuild the index asynchronously when possible.
function! s:ToggleGitIgnore() abort
    let s:respect_gitignore = !s:respect_gitignore
    call s:CancelAsyncSearch()
    call s:CancelAsyncPreview()
    call s:CancelAsyncIndex()
    if s:search_timer != -1 && exists('*timer_stop')
        call timer_stop(s:search_timer)
    endif
    let s:search_timer = -1
    let s:search_pending = 1
    let s:index_purpose = 'search'
    let s:selected = 0
    let s:preview_lines = []
    let s:preview_occurrence = 1
    let s:preview_occurrence_path = ''
    let l:index_state = s:PrepareAsyncIndex(s:respect_gitignore)
    if l:index_state == 1
        let s:index_purpose = 'search'
        call s:Render()
        call s:StartAsyncIndex()
    elseif l:index_state == 0
        call s:IndexFiles(s:respect_gitignore)
        call s:BuildSearchCandidateFiles()
        call s:RunPendingSearch()
    else
        call s:BuildSearchCandidateFiles()
        call s:RunPendingSearch()
    endif
endfunction

function! s:HandleKey(id, key) abort
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
        call s:Close()
        return 1
    endif

    if a:key ==# "\<F6>"
        call s:ToggleGitIgnore()
        return 1
    endif

    if a:key ==# "\<F7>"
        let s:show_hidden = !s:show_hidden
        let s:selected = 0
        call s:ScheduleSearch()
        return 1
    endif

    if a:key ==# "\<F5>"
        call s:CancelAsyncSearch()
        call s:CancelAsyncIndex()
        call s:CancelAsyncPreview()
        call s:PreviewCacheClear()
        call s:IndexCacheClear()
        let s:selected = 0
        let s:search_pending = 1
        let l:index_state = s:PrepareAsyncIndex(s:respect_gitignore)
        if l:index_state == 1
            call s:Render()
            call s:StartAsyncIndex()
        elseif l:index_state == 0
            call s:IndexFiles(s:respect_gitignore)
            call s:ScheduleSearch()
        else
            call s:ScheduleSearch()
        endif
        return 1
    endif

    if a:key ==# "\<C-X>" || a:key ==# "\<C-V>" || a:key ==# "\<C-T>"
        if !empty(s:matches) && !s:indexing && !s:search_pending
            call s:OpenSelected(a:key ==# "\<C-X>" ? 'split' : (a:key ==# "\<C-V>" ? 'vsplit' : 'tab'))
        endif
        return 1
    endif

    if a:key ==# "\<C-O>" && s:search_mode ==# 'content'
        let s:search_preview_enabled = !s:search_preview_enabled
        call s:Render()
        return 1
    endif
    if a:key ==# "\<C-F>" && s:search_mode ==# 'name'
        let s:search_fuzzy = !s:search_fuzzy
        let s:selected = 0
        call s:ScheduleSearch()
        return 1
    endif
    if a:key ==# "\<C-Up>"
        call s:SearchHistoryMove(-1)
        return 1
    endif
    if a:key ==# "\<C-Down>"
        call s:SearchHistoryMove(1)
        return 1
    endif

    if a:key ==# "\<CR>"
        if s:indexing
            let s:open_after_search = 1
            return 1
        endif
        if s:search_pending
            call s:RunPendingSearch()
            if s:async_search_running
                let s:open_after_search = 1
                return 1
            endif
        endif
        call s:OpenSelected()
        return 1
    endif

    if a:key ==# "\<Left>" || a:key ==# "\<Right>"
        if s:search_pending
            call s:RunPendingSearch()
        endif
        if s:async_search_running
            return 1
        endif
        if s:search_mode ==# 'content' && !empty(s:matches)
            let l:path = s:matches[s:selected]
            let l:total = get(s:match_counts, l:path, 0)
            if l:total > 1
                if a:key ==# "\<Right>"
                    let s:preview_occurrence = s:preview_occurrence >= l:total
                                \ ? 1 : s:preview_occurrence + 1
                else
                    let s:preview_occurrence = s:preview_occurrence <= 1
                                \ ? l:total : s:preview_occurrence - 1
                endif
                call s:UpdatePreview()
                call s:Render()
            endif
        endif
        return 1
    endif

    if a:key ==# "\<Down>" || a:key ==# "\<C-N>"
        if !empty(s:matches)
            let s:selected = min([s:selected + 1, len(s:matches) - 1])
            call s:UpdatePreview()
            call s:Render()
        endif
        return 1
    endif

    if a:key ==# "\<Up>" || a:key ==# "\<C-P>"
        if !empty(s:matches)
            let s:selected = max([s:selected - 1, 0])
            call s:UpdatePreview()
            call s:Render()
        endif
        return 1
    endif

    if a:key ==# "\<PageDown>"
        if !empty(s:matches)
            let s:selected = min([
                        \ s:selected + max([1, g:file_search_max_height - 3]),
                        \ len(s:matches) - 1
                        \ ])
            call s:UpdatePreview()
            call s:Render()
        endif
        return 1
    endif

    if a:key ==# "\<PageUp>"
        let s:selected = max([
                    \ s:selected - max([1, g:file_search_max_height - 3]), 0])
        call s:UpdatePreview()
        call s:Render()
        return 1
    endif

    if a:key ==# "\<BS>" || a:key ==# "\<C-H>"
        if !empty(s:query)
            let s:query = strcharpart(s:query, 0, strchars(s:query) - 1)
            let s:selected = 0
            call s:ScheduleSearch()
        endif
        return 1
    endif

    if a:key ==# "\<C-U>"
        let s:query = ''
        let s:selected = 0
        call s:ScheduleSearch()
        return 1
    endif

    if strchars(a:key) == 1 && char2nr(a:key) >= 32 && char2nr(a:key) != 127
        let s:query .= a:key
        let s:selected = 0
        call s:ScheduleSearch()
    endif

    return 1
endfunction

" Purpose: Public entry point that indexes files and creates the search popup.
function! VimFileSearch(respect_gitignore, ...) abort
    call s:Close()

    let s:respect_gitignore = a:respect_gitignore ? 1 : 0
    let s:search_mode = a:0 > 0 && index(['name', 'content'], a:1) >= 0
                \ ? a:1 : 'name'
    let s:search_fuzzy = !!g:file_search_fuzzy_default
    let s:show_hidden = !!g:file_search_show_hidden_default
    let s:search_history_index = -1
    let s:search_preview_enabled = 1
    call s:SearchHistoryLoad()
    let s:index_purpose = 'search'
    let l:index_state = s:PrepareAsyncIndex(s:respect_gitignore)
    if l:index_state == 0
        call s:IndexFiles(s:respect_gitignore)
    endif

    let s:query = ''
    let s:selected = 0
    let s:search_pending = 0
    let s:preview_lines = []
    let s:preview_occurrence = 1
    let s:preview_occurrence_path = ''
    let s:content_warning = ''

    let l:width = max([12, min([100, &columns - 8])])
    let s:popup_width = l:width
    let l:height = min([max([4, g:file_search_max_height]), max([4, &lines - 6])])

    call s:ApplyPopupHighlights()
    let s:popup = popup_create([' Search ', ' Indexing…'], {
                \ 'pos': 'center',
                \ 'minwidth': l:width,
                \ 'maxwidth': l:width,
                \ 'minheight': 4,
                \ 'maxheight': l:height,
                \ 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'],
                \ 'padding': [0, 1, 0, 1],
                \ 'title': ' Vim File Search ',
                \ 'mapping': 0,
                \ 'filter': function('s:HandleKey'),
                \ 'wrap': 0,
                \ 'scrollbar': 1,
                \ 'highlight': 'VimFileSearchPopup'
                \ })

    if l:index_state == 1
        call s:Render()
        call s:StartAsyncIndex()
    else
        call s:FilterFiles()
        call s:UpdatePreview()
        call s:Render()
    endif
endfunction


" -------------------------------------------------------------------------
" Regex search & replace popup (<leader>r)
" Uses Vim's own regexp and replacement syntax: \(...\), \1, \2, & etc.
" -------------------------------------------------------------------------
" Purpose: Clip long strings to fit the replacement popup.
function! s:ReplaceClip(text, width) abort
    let l:max = max([1, a:width])
    if strchars(a:text) <= l:max
        return a:text
    endif
    return strcharpart(a:text, 0, max([1, l:max - 1])) . '…'
endfunction

" Purpose: Close the replacement popup and clear its window ID.
function! s:ReplacePopupClose() abort
    if s:replace_diff_popup > 0 && !empty(popup_getpos(s:replace_diff_popup))
        call popup_close(s:replace_diff_popup)
    endif
    let s:replace_diff_popup = -1
    " If another plugin entry point closes the popup during review, commit any
    " already accepted per-file edits through the same conflict-safe path.
    if s:replace_cache_dirty
        call s:ReplaceSaveCache()
    endif
    " Esc during async Git indexing must cancel the job as well as close the UI.
    if s:replace_stage ==# 'indexing' && s:indexing && s:index_purpose ==# 'replace'
        call s:CancelAsyncIndex()
        let s:index_purpose = 'search'
    endif
    let s:replace_scan_generation += 1
    let s:replace_bulk_generation += 1
    let s:replace_plan_generation += 1
    if s:replace_plan_timer != -1 && exists('*timer_stop')
        call timer_stop(s:replace_plan_timer)
        let s:replace_plan_timer = -1
    endif
    if s:replace_bulk_timer != -1 && exists('*timer_stop')
        call timer_stop(s:replace_bulk_timer)
        let s:replace_bulk_timer = -1
    endif
    if s:replace_scan_timer != -1 && exists('*timer_stop')
        call timer_stop(s:replace_scan_timer)
        let s:replace_scan_timer = -1
    endif
    if s:replace_popup != -1
        if !empty(popup_getpos(s:replace_popup))
            call popup_close(s:replace_popup)
        endif
        let s:replace_popup = -1
    endif
endfunction

" Purpose: Find whether a project file already has an associated Vim buffer.
function! s:BuildReplaceBufferMap() abort
    let s:replace_buffer_map = {}
    let s:replace_buffer_map_ready = 1
    if exists('*getbufinfo')
        for l:info in getbufinfo()
            let l:name = bufname(l:info.bufnr)
            if empty(l:name)
                continue
            endif
            let l:absolute = substitute(fnamemodify(l:name, ':p'), '\\', '/', 'g')
            let s:replace_buffer_map[l:absolute] = l:info.bufnr
        endfor
    endif
endfunction

" Build the open-buffer lookup once per replacement scan instead of calling
" getbufinfo() for every indexed file. This changes O(files * buffers) into
" O(files + buffers) average-time lookup.
function! s:ReplaceFindBuffer(path) abort
    let l:target = substitute(fnamemodify(s:root . (s:root =~# '/$' ? '' : '/') . a:path, ':p'), '\\', '/', 'g')
    if s:replace_buffer_map_ready && has_key(s:replace_buffer_map, l:target)
        let l:cached = s:replace_buffer_map[l:target]
        if bufexists(l:cached)
            let l:cached_name = bufname(l:cached)
            if !empty(l:cached_name)
                        \ && substitute(fnamemodify(l:cached_name, ':p'), '\\', '/', 'g') ==# l:target
                return l:cached
            endif
        endif
        call remove(s:replace_buffer_map, l:target)
    endif

    " The map is a fast path, not a frozen truth: buffers may be opened after
    " the scan starts. Check bufnr() and refresh the map before any disk write.
    let l:buf = bufnr(l:target)
    if l:buf > 0 && bufexists(l:buf)
        if s:replace_buffer_map_ready
            let s:replace_buffer_map[l:target] = l:buf
        endif
        return l:buf
    endif
    if exists('*getbufinfo')
        for l:item in getbufinfo()
            let l:name = bufname(l:item.bufnr)
            if !empty(l:name) && substitute(fnamemodify(l:name, ':p'), '\\', '/', 'g') ==# l:target
                if s:replace_buffer_map_ready
                    let s:replace_buffer_map[l:target] = l:item.bufnr
                endif
                return l:item.bufnr
            endif
        endfor
    endif
    return -1
endfunction

" Purpose: Return metadata only for an ordinary file (never follow a symlink for writes).
function! s:ReplaceFileStat(path) abort
    let l:type = getftype(a:path)
    if l:type !=# 'file'
        return {}
    endif
    let l:size = getfsize(a:path)
    let l:mtime = getftime(a:path)
    if l:size < 0 || l:mtime < 0
        return {}
    endif
    return {'type': l:type, 'size': l:size, 'mtime': l:mtime,
                \ 'perm': getfperm(a:path)}
endfunction

" Purpose: Compare file type, size, mtime, and rwx permissions.
function! s:ReplaceStatEqual(left, right) abort
    if empty(a:left) || empty(a:right)
        return 0
    endif
    return a:left.type ==# a:right.type
                \ && a:left.size == a:right.size
                \ && a:left.mtime == a:right.mtime
                \ && a:left.perm ==# a:right.perm
endfunction

" Purpose: Fingerprint the exact logical bytes represented by readfile(..., 'b').
function! s:ReplaceContentHash(lines) abort
    if exists('*sha256')
        return sha256(join(a:lines, "\n"))
    endif
    return ''
endfunction

" Purpose: Read a regular file and ensure its metadata did not change during the read.
function! s:ReplaceReadSnapshot(path) abort
    let l:before = s:ReplaceFileStat(a:path)
    if empty(l:before)
        return {'ok': 0, 'changed': 0, 'large': 0, 'lines': [], 'snapshot': {}}
    endif
    let l:max_size = get(g:, 'file_search_replace_max_file_bytes', 8 * 1024 * 1024)
    if l:max_size > 0 && l:before.size > l:max_size
        return {'ok': 0, 'changed': 0, 'large': 1, 'lines': [], 'snapshot': {}}
    endif
    try
        let l:lines = readfile(a:path, 'b')
    catch
        return {'ok': 0, 'changed': 0, 'large': 0, 'lines': [], 'snapshot': {}}
    endtry
    let l:after = s:ReplaceFileStat(a:path)
    if !s:ReplaceStatEqual(l:before, l:after)
        return {'ok': 0, 'changed': 1, 'large': 0, 'lines': [], 'snapshot': {}}
    endif
    let l:snapshot = copy(l:after)
    let l:snapshot.hash = s:ReplaceContentHash(l:lines)
    return {'ok': 1, 'changed': 0, 'large': 0, 'lines': l:lines, 'snapshot': l:snapshot}
endfunction

" Purpose: Verify that a file still matches its scan-time snapshot.
function! s:ReplaceSnapshotMatches(path, snapshot, verify_content) abort
    if empty(a:snapshot)
        return 0
    endif
    let l:current = s:ReplaceFileStat(a:path)
    if !s:ReplaceStatEqual(a:snapshot, l:current)
        return 0
    endif
    if a:verify_content && !empty(get(a:snapshot, 'hash', ''))
        try
            let l:lines = readfile(a:path, 'b')
        catch
            return 0
        endtry
        if s:ReplaceContentHash(l:lines) !=# a:snapshot.hash
            return 0
        endif
        let l:after = s:ReplaceFileStat(a:path)
        if !s:ReplaceStatEqual(a:snapshot, l:after)
            return 0
        endif
    endif
    return 1
endfunction

" Purpose: Count each external-change conflict once and expose a clear status message.
function! s:ReplaceMarkChanged(path) abort
    if !has_key(s:replace_conflicted_paths, a:path)
        let s:replace_conflicted_paths[a:path] = 1
        let s:replace_skipped_changed += 1
    endif
    let s:replace_error = 'Changed since scan; skipped: ' . a:path
endfunction

" Purpose: Build a unique temporary path beside the target for same-filesystem rename.
function! s:ReplaceTempPath(path) abort
    let l:dir = fnamemodify(a:path, ':h')
    let l:tries = 0
    while l:tries < 100
        let s:replace_temp_counter += 1
        let l:nonce = fnamemodify(tempname(), ':t')
        let l:temp = l:dir . '/.vfs-' . getpid()
                    \ . '-' . l:nonce . '-' . s:replace_temp_counter . '.tmp'
        if getftype(l:temp) ==# ''
            return l:temp
        endif
        let l:tries += 1
    endwhile
    return ''
endfunction

" Purpose: Resolve the private, persistent data directory used by the plugin.
function! s:ReplaceDataDirectory() abort
    let l:dir = expand(get(g:, 'file_search_data_dir', '~/.vim/vim-file-search'))
    if !isdirectory(l:dir)
        if mkdir(l:dir, 'p', 0700) != 1 && !isdirectory(l:dir)
            return ''
        endif
    endif
    return simplify(fnamemodify(l:dir, ':p'))
endfunction

function! s:ReplaceUndoRoot() abort
    let l:configured = get(g:, 'file_search_undo_dir', '')
    let l:root = empty(l:configured)
                \ ? s:ReplaceDataDirectory() . '/undo'
                \ : expand(l:configured)
    if empty(l:root)
        return ''
    endif
    if !isdirectory(l:root) && mkdir(l:root, 'p', 0700) != 1 && !isdirectory(l:root)
        return ''
    endif
    return simplify(fnamemodify(l:root, ':p'))
endfunction

function! s:ReplaceUndoManifestPath(directory) abort
    return a:directory . '/manifest.json'
endfunction

" Purpose: Atomically persist the current replacement generation metadata.
function! s:ReplaceUndoPersist() abort
    if empty(s:replace_undo_dir) || empty(s:replace_undo_id)
                \ || !exists('*json_encode')
        return 0
    endif
    let l:entries = []
    for l:item in s:replace_undo_entries
        call add(l:entries, {
                    \ 'path': l:item.path,
                    \ 'backup': fnamemodify(l:item.backup, ':t'),
                    \ 'before': l:item.before,
                    \ 'after': l:item.after,
                    \ 'restored': get(l:item, 'restored', 0)})
    endfor
    let l:manifest = {
                \ 'version': 1,
                \ 'id': s:replace_undo_id,
                \ 'created': s:replace_undo_created,
                \ 'find': get(s:, 'replace_undo_find', ''),
                \ 'replacement': get(s:, 'replace_undo_replacement', ''),
                \ 'entries': l:entries}
    let l:path = s:ReplaceUndoManifestPath(s:replace_undo_dir)
    let l:temp = l:path . '.tmp-' . getpid()
    try
        if writefile([json_encode(l:manifest)], l:temp) != 0
            call delete(l:temp)
            return 0
        endif
        if exists('*setfperm')
            call setfperm(l:temp, 'rw-------')
        endif
        if rename(l:temp, l:path) != 0
            call delete(l:temp)
            return 0
        endif
    catch
        call delete(l:temp)
        return 0
    endtry
    return 1
endfunction

" Purpose: Delete old undo batches beyond the configured retention limit.
function! s:ReplaceUndoPrune() abort
    let l:root = s:ReplaceUndoRoot()
    if empty(l:root)
        return
    endif
    let l:dirs = glob(l:root . '/batch-*', 0, 1)
    call sort(l:dirs, {a, b -> getftime(s:ReplaceUndoManifestPath(b)) - getftime(s:ReplaceUndoManifestPath(a))})
    let l:limit = max([1, get(g:, 'file_search_undo_history_limit', 10)])
    for l:dir in l:dirs[l:limit :]
        if l:dir !=# s:replace_undo_dir
            call delete(l:dir, 'rf')
        endif
    endfor
endfunction

" Purpose: Load and validate one persistent undo generation from its manifest.
function! s:ReplaceUndoLoad(directory) abort
    let l:manifest_path = s:ReplaceUndoManifestPath(a:directory)
    if !filereadable(l:manifest_path) || !exists('*json_decode')
        return 0
    endif
    try
        let l:lines = readfile(l:manifest_path)
        if empty(l:lines)
            return 0
        endif
        let l:manifest = json_decode(join(l:lines, "\n"))
    catch
        return 0
    endtry
    if type(l:manifest) != type({}) || get(l:manifest, 'version', 0) != 1
                \ || type(get(l:manifest, 'entries', 0)) != type([])
        return 0
    endif
    let l:entries = []
    for l:item in l:manifest.entries
        if type(l:item) != type({}) || empty(get(l:item, 'path', ''))
                    \ || empty(get(l:item, 'backup', ''))
            continue
        endif
        let l:backup = a:directory . '/' . fnamemodify(l:item.backup, ':t')
        if !filereadable(l:backup)
            continue
        endif
        let l:entry = {
                    \ 'path': l:item.path,
                    \ 'backup': l:backup,
                    \ 'before': get(l:item, 'before', {}),
                    \ 'after': get(l:item, 'after', {}),
                    \ 'restored': get(l:item, 'restored', 0)}
        " Recover a crash between restoring the original and updating the manifest.
        if !get(l:entry, 'restored', 0)
                    \ && s:ReplaceSnapshotMatches(l:entry.path, l:entry.before, 1)
            let l:entry.restored = 1
            call delete(l:backup)
            continue
        endif
        if !get(l:entry, 'restored', 0)
            call add(l:entries, l:entry)
        else
            call delete(l:backup)
        endif
    endfor
    let s:replace_undo_dir = a:directory
    let s:replace_undo_id = get(l:manifest, 'id', fnamemodify(a:directory, ':t'))
    let s:replace_undo_created = get(l:manifest, 'created', '')
    let s:replace_undo_find = get(l:manifest, 'find', '')
    let s:replace_undo_replacement = get(l:manifest, 'replacement', '')
    let s:replace_undo_entries = l:entries
    let s:replace_undo_generation = -1
    call s:ReplaceUndoPersist()
    return !empty(l:entries)
endfunction

" Purpose: Load the newest available persistent undo batch at plugin startup.
function! s:ReplaceUndoLoadLatest() abort
    let l:root = s:ReplaceUndoRoot()
    if empty(l:root)
        return
    endif
    let l:dirs = glob(l:root . '/batch-*', 0, 1)
    call sort(l:dirs, {a, b -> getftime(s:ReplaceUndoManifestPath(b)) - getftime(s:ReplaceUndoManifestPath(a))})
    for l:dir in l:dirs
        if s:ReplaceUndoLoad(l:dir)
            return
        endif
    endfor
endfunction

" Purpose: Create a private backup of a verified pre-write snapshot for the undo journal.
function! s:ReplaceUndoBackup(path, original_lines, expected) abort
    if !s:ReplaceStatEqual(a:expected, s:ReplaceFileStat(a:path))
        return {}
    endif
    if !empty(get(a:expected, 'hash', ''))
                \ && s:ReplaceContentHash(a:original_lines) !=# a:expected.hash
        return {}
    endif

    if s:replace_undo_generation == s:replace_scan_generation
        let l:dir = s:replace_undo_dir
    else
        if s:replace_undo_pending_generation != s:replace_scan_generation
            if !empty(s:replace_undo_pending_dir)
                call delete(s:replace_undo_pending_dir, 'rf')
            endif
            let l:root = s:ReplaceUndoRoot()
            if empty(l:root)
                return {}
            endif
            let s:replace_undo_pending_dir = l:root . '/.pending-' . getpid()
                        \ . '-' . s:replace_scan_generation . '-' . localtime()
            let s:replace_undo_pending_generation = s:replace_scan_generation
            if mkdir(s:replace_undo_pending_dir, 'p', 0700) != 1
                let s:replace_undo_pending_dir = ''
                return {}
            endif
        endif
        let l:dir = s:replace_undo_pending_dir
    endif
    if empty(l:dir) || !isdirectory(l:dir)
        return {}
    endif

    let l:number = len(glob(l:dir . '/before-*.bak', 0, 1)) + 1
    let l:backup = l:dir . '/before-' . printf('%06d', l:number) . '.bak'
    while getftype(l:backup) !=# ''
        let l:number += 1
        let l:backup = l:dir . '/before-' . printf('%06d', l:number) . '.bak'
    endwhile
    if writefile(a:original_lines, l:backup, 'b') != 0
        call delete(l:backup)
        return {}
    endif
    let l:perm = get(a:expected, 'perm', '')
    if !empty(l:perm) && exists('*setfperm') && setfperm(l:backup, l:perm) != 1
        call delete(l:backup)
        return {}
    endif
    try
        let l:check = readfile(l:backup, 'b')
    catch
        call delete(l:backup)
        return {}
    endtry
    if s:ReplaceContentHash(l:check) !=# s:ReplaceContentHash(a:original_lines)
        call delete(l:backup)
        return {}
    endif
    return {'path': l:backup, 'directory': l:dir}
endfunction

" Purpose: Promote a new undo generation only after its first disk write commits.
function! s:ReplaceUndoRegister(path, backup, before, after) abort
    let l:backup = a:backup
    let l:journal_path = a:path =~# '^/' ? simplify(a:path)
                \ : simplify(s:root . (s:root =~# '/$' ? '' : '/') . a:path)
    if s:replace_undo_generation != s:replace_scan_generation
        let l:pending = s:replace_undo_pending_dir
        if empty(l:pending) || !isdirectory(l:pending)
            return
        endif
        let l:root = s:ReplaceUndoRoot()
        let l:id = strftime('%Y%m%d-%H%M%S') . '-' . getpid() . '-' . s:replace_scan_generation
        let l:destination = l:root . '/batch-' . l:id
        let l:suffix = 0
        while getftype(l:destination) !=# ''
            let l:suffix += 1
            let l:destination = l:root . '/batch-' . l:id . '-' . l:suffix
        endwhile
        if rename(l:pending, l:destination) != 0
            return
        endif
        let l:backup = l:destination . '/' . fnamemodify(a:backup, ':t')
        let s:replace_undo_dir = l:destination
        let s:replace_undo_id = fnamemodify(l:destination, ':t')
        let s:replace_undo_created = strftime('%Y-%m-%d %H:%M:%S')
        let s:replace_undo_find = s:replace_find
        let s:replace_undo_replacement = s:replace_with
        let s:replace_undo_pending_dir = ''
        let s:replace_undo_pending_generation = -1
        let s:replace_undo_entries = []
        let s:replace_undo_generation = s:replace_scan_generation
    endif

    " A path should normally be committed once per run. Retain earliest before-image.
    if !empty(s:replace_undo_entries)
      for l:index in range(0, len(s:replace_undo_entries) - 1)
        if s:replace_undo_entries[l:index].path ==# l:journal_path
            if a:backup !=# s:replace_undo_entries[l:index].backup
                call delete(a:backup)
            endif
            let s:replace_undo_entries[l:index].after = copy(a:after)
            call s:ReplaceUndoPersist()
            call s:ReplaceUndoPrune()
            return
        endif
      endfor
    endif
    call add(s:replace_undo_entries, {
                \ 'path': l:journal_path,
                \ 'backup': l:backup,
                \ 'before': copy(a:before),
                \ 'after': copy(a:after),
                \ 'restored': 0})
    call s:ReplaceUndoPersist()
    call s:ReplaceUndoPrune()
endfunction

" Purpose: Discard a backup that was prepared for a write which did not commit.
function! s:ReplaceUndoDiscard(backup) abort
    if empty(a:backup)
        return
    endif
    call delete(a:backup.path)
    if s:replace_undo_generation != s:replace_scan_generation
                \ && !empty(s:replace_undo_pending_dir)
                \ && empty(glob(s:replace_undo_pending_dir . '/*.bak'))
        call delete(s:replace_undo_pending_dir, 'rf')
        let s:replace_undo_pending_dir = ''
        let s:replace_undo_pending_generation = -1
    endif
endfunction

" Purpose: Write atomically through a sibling temp file while preserving rwx mode.
" Optional arguments: original lines and whether to create an undo backup.
function! s:ReplaceAtomicWrite(path, lines, expected, ...) abort
    " The caller has already read/verified the source. The full fingerprint is
    " checked after the temp write, immediately before the final rename.
    let l:temp = s:ReplaceTempPath(a:path)
    if empty(l:temp)
        return {'ok': 0, 'changed': 0, 'error': 'could not allocate temporary file'}
    endif
    if writefile(a:lines, l:temp, 'b') != 0
        if getftype(l:temp) !=# '' | call delete(l:temp) | endif
        return {'ok': 0, 'changed': 0, 'error': 'could not write temporary file'}
    endif
    let l:perm = get(a:expected, 'perm', '')
    if !empty(l:perm) && exists('*setfperm') && setfperm(l:temp, l:perm) != 1
        call delete(l:temp)
        return {'ok': 0, 'changed': 0, 'error': 'could not preserve file permissions'}
    endif

    let l:backup = {}
    let l:journal = a:0 >= 2 ? a:2 : 0
    if l:journal
        let l:original = a:0 >= 1 ? a:1 : []
        let l:backup = s:ReplaceUndoBackup(a:path, l:original, a:expected)
        if empty(l:backup)
            call delete(l:temp)
            return {'ok': 0, 'changed': 0, 'error': 'could not create safe undo backup'}
        endif
    endif

    " Recheck after the temp and backup writes, immediately before replacing.
    if !s:ReplaceSnapshotMatches(a:path, a:expected, 1)
        call delete(l:temp)
        call s:ReplaceUndoDiscard(l:backup)
        return {'ok': 0, 'changed': 1, 'error': 'file changed while preparing write'}
    endif
    if rename(l:temp, a:path) != 0
        call delete(l:temp)
        call s:ReplaceUndoDiscard(l:backup)
        return {'ok': 0, 'changed': 0, 'error': 'atomic rename failed; original kept'}
    endif

    let l:stat = s:ReplaceFileStat(a:path)
    if empty(l:stat)
        " The rename has already committed; keep the backup for manual recovery.
        if !empty(l:backup)
            call s:ReplaceUndoRegister(a:path, l:backup.path, a:expected, a:expected)
        endif
        return {'ok': 1, 'changed': 0, 'error': 'post-write metadata unavailable; undo backup retained', 'snapshot': {}}
    endif
    let l:stat.hash = s:ReplaceContentHash(a:lines)
    if !empty(l:backup)
        call s:ReplaceUndoRegister(a:path, l:backup.path, a:expected, l:stat)
    endif
    return {'ok': 1, 'changed': 0, 'error': '', 'snapshot': l:stat}
endfunction

" Purpose: Refresh an already-loaded, unmodified buffer after its disk file changes.
function! s:ReplaceSyncBuffer(path) abort
    let l:absolute = a:path =~# '^/' ? a:path : s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:buf = a:path =~# '^/' ? bufnr(l:absolute) : s:ReplaceFindBuffer(a:path)
    if l:buf <= 0 || !bufloaded(l:buf) || getbufvar(l:buf, '&modified')
        return
    endif

    try
        let l:lines = readfile(l:absolute)
    catch
        return
    endtry
    if empty(l:lines)
        let l:lines = ['']
    endif

    let l:old_count = len(getbufline(l:buf, 1, '$'))
    if l:old_count < 1
        return
    endif
    let l:common = min([l:old_count, len(l:lines)])
    if l:common > 0
        call setbufline(l:buf, 1, l:lines[0 : l:common - 1])
    endif
    if len(l:lines) > l:old_count
        call appendbufline(l:buf, l:old_count, l:lines[l:old_count :])
    elseif len(l:lines) < l:old_count
        call deletebufline(l:buf, len(l:lines) + 1, l:old_count)
    endif
    call setbufvar(l:buf, '&modified', 0)
endfunction

" Purpose: Persist the dirty one-by-one cache only if the scanned source is unchanged.
function! s:ReplaceSaveCache() abort
    if empty(s:replace_cache_path)
        return 1
    endif
    if !s:replace_cache_dirty
        let s:replace_cache_accepted_count = 0
        return 1
    endif

    let l:path = s:replace_cache_path
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . l:path
    let l:expected = get(s:replace_path_snapshots, l:path, {})
    let l:buf = s:ReplaceFindBuffer(l:path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        if !has_key(s:replace_conflicted_paths, l:path)
            let s:replace_conflicted_paths[l:path] = 1
            let s:replace_skipped_modified += 1
        endif
        let s:replace_changed_count = max([0,
                    \ s:replace_changed_count - s:replace_cache_accepted_count])
        let s:replace_error = 'Modified buffer appeared; discarded staged replacements: ' . l:path
        let s:replace_cache_accepted_count = 0
        let s:replace_cache_dirty = 0
        let s:replace_cache_path = ''
        let s:replace_cache_lines = []
        let s:replace_cache_original_lines = []
        return 1
    endif
    let l:result = s:ReplaceAtomicWrite(l:absolute, s:replace_cache_lines, l:expected, s:replace_cache_original_lines, 1)
    if !l:result.ok
        if l:result.changed
            let l:discarded = s:replace_cache_accepted_count
            let s:replace_changed_count = max([0, s:replace_changed_count - l:discarded])
            call s:ReplaceMarkChanged(l:path)
            if l:discarded > 0
                let s:replace_error = 'Changed since scan; discarded '
                            \ . l:discarded . ' staged replacements: ' . l:path
            endif
            let s:replace_cache_accepted_count = 0
            let s:replace_cache_dirty = 0
            let s:replace_cache_path = ''
            let s:replace_cache_lines = []
            let s:replace_cache_original_lines = []
            return 1
        endif
        let s:replace_error = 'Could not safely write ' . l:path . ': ' . l:result.error
        return 0
    endif

    let s:replace_path_snapshots[l:path] = l:result.snapshot
    call s:ReplaceSyncBuffer(l:path)
    call s:IndexCacheClear()
    call s:PreviewCacheClear()
    let s:replace_cache_dirty = 0
    let s:replace_cache_original_lines = copy(s:replace_cache_lines)
    let s:replace_cache_accepted_count = 0
    let s:replace_files_changed += 1
    return 1
endfunction

" Purpose: Save the previous cache, then load a verified scan-time file snapshot.
function! s:ReplaceLoadCache(path) abort
    if s:replace_cache_path ==# a:path
        return 1
    endif
    if !s:ReplaceSaveCache()
        return 0
    endif
    if has_key(s:replace_conflicted_paths, a:path)
        return 0
    endif

    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:expected = get(s:replace_path_snapshots, a:path, {})
    let l:buf = s:ReplaceFindBuffer(a:path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        if !has_key(s:replace_conflicted_paths, a:path)
            let s:replace_conflicted_paths[a:path] = 1
            let s:replace_skipped_modified += 1
        endif
        return 0
    endif
    let l:read = s:ReplaceReadSnapshot(l:absolute)
    if !l:read.ok
        if l:read.large
            let s:replace_skipped_large += 1
            call s:ReplaceMarkChanged(a:path)
        elseif l:read.changed || !s:ReplaceSnapshotMatches(l:absolute, l:expected, 0)
            call s:ReplaceMarkChanged(a:path)
        else
            let s:replace_error = 'Could not read: ' . a:path
        endif
        return 0
    endif
    if !s:ReplaceStatEqual(l:expected, l:read.snapshot)
                \ || (!empty(get(l:expected, 'hash', ''))
                \ && l:expected.hash !=# l:read.snapshot.hash)
        call s:ReplaceMarkChanged(a:path)
        return 0
    endif

    let s:replace_cache_lines = l:read.lines
    let s:replace_cache_original_lines = copy(l:read.lines)
    let s:replace_cache_path = a:path
    let s:replace_cache_dirty = 0
    let s:replace_cache_accepted_count = 0
    let s:replace_line_deltas = {}
    return 1
endfunction

" Purpose: Exclude readfile binary-mode trailing-EOL marker from logical line count.
function! s:ReplaceActualLineCount(path, lines) abort
    if empty(a:lines)
        return 0
    endif
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    " readfile(..., 'b') keeps a final empty list item as the EOL marker.
    " Do not count that marker as an additional buffer line, except for an
    " actually empty file, which Vim represents as one empty buffer line.
    if getfsize(l:absolute) > 0 && empty(a:lines[-1])
        return len(a:lines) - 1
    endif
    return len(a:lines)
endfunction

" Purpose: Scan a size-bounded regular file and retain matches only if its snapshot stayed stable.
function! s:ReplaceScanFile(path) abort
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:buf = s:ReplaceFindBuffer(a:path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        let s:replace_skipped_modified += 1
        return
    endif

    let l:before = s:ReplaceFileStat(l:absolute)
    if empty(l:before)
        let s:replace_skipped_unsafe += 1
        return
    endif
    let l:max_size = get(g:, 'file_search_replace_max_file_bytes', 8 * 1024 * 1024)
    if l:max_size > 0 && l:before.size > l:max_size
        let s:replace_skipped_large += 1
        return
    endif

    let l:read = s:ReplaceReadSnapshot(l:absolute)
    if !l:read.ok
        if l:read.large
            let s:replace_skipped_large += 1
        elseif l:read.changed || !s:ReplaceStatEqual(l:before,
                    \ s:ReplaceFileStat(l:absolute))
            call s:ReplaceMarkChanged(a:path)
        endif
        return
    endif
    let l:lines = l:read.lines

    " NUL bytes are represented as NL characters inside a readfile('b') item.
    for l:line in l:lines
        if stridx(l:line, "\n") >= 0
            let s:replace_skipped_binary += 1
            return
        endif
    endfor

    let l:path_count = 0
    let l:found_records = []
    " A non-zero match() start offset becomes a new regex start for ^. Use
    " the anchored positional fallback only for expressions containing a
    " line-start atom; ordinary expressions retain the faster offset API.
    let l:anchor_sensitive = stridx(s:replace_find, '^') >= 0
                \ || stridx(s:replace_find, '\%^') >= 0
    let l:line_count = s:ReplaceActualLineCount(a:path, l:lines)
    if l:line_count > 0
        for l:idx in range(0, l:line_count - 1)
            let l:line = l:lines[l:idx]
            let l:start = 0
            let l:line_size = strlen(l:line)
            while l:start <= l:line_size
                try
                    if l:anchor_sensitive && l:start > 0
                        " For ^ / \%^ patterns, match(..., start) treats the
                        " offset as a new regex start. Keep the original line
                        " anchor with a byte-column position atom instead.
                        " The non-capturing wrapper preserves user's capture IDs.
                        let l:scan_pattern = '\%>' . l:start . 'c\%('
                                    \ . s:replace_find . '\m\)'
                        if exists('*matchstrpos')
                            let l:match = matchstrpos(l:line, l:scan_pattern)
                            let l:pos = l:match[1]
                            if l:pos < 0 | break | endif
                            let l:end = l:match[2]
                        else
                            let l:pos = match(l:line, l:scan_pattern)
                            if l:pos < 0 | break | endif
                            let l:end = matchend(l:line, l:scan_pattern)
                        endif
                    elseif exists('*matchstrpos')
                        " One Vim regex evaluation returns text, start and end.
                        let l:match = matchstrpos(l:line, s:replace_find, l:start)
                        let l:pos = l:match[1]
                        if l:pos < 0 | break | endif
                        let l:end = l:match[2]
                    else
                        let l:pos = match(l:line, s:replace_find, l:start)
                        if l:pos < 0 | break | endif
                        let l:end = matchend(l:line, s:replace_find, l:start)
                    endif
                catch
                    let s:replace_error = 'Regex error: ' . v:exception
                    return
                endtry

                let l:path_count += 1
                if len(s:replace_matches) + len(l:found_records) < s:replace_max_stored
                    call add(l:found_records, {
                                \ 'path': a:path,
                                \ 'line': l:idx + 1,
                                \ 'col': l:pos,
                                \ 'end': max([l:pos, l:end]),
                                \ 'scan_start': l:start
                                \ })
                endif

                if l:end > l:pos
                    let l:start = l:end
                elseif l:pos >= l:line_size
                    break
                else
                    let l:char = matchstr(strpart(l:line, l:pos), '^.')
                    let l:start = l:pos + max([1, strlen(l:char)])
                endif
            endwhile
        endfor
    endif

    if l:path_count > 0
        " Keep the read-time fingerprint. The apply/review phase checks it again
        " before writing, avoiding a redundant second full-file read during scan.
        call extend(s:replace_matches, l:found_records)
        let s:replace_match_records_by_path[a:path] = {
                    \ 'records': copy(l:found_records),
                    \ 'complete': len(l:found_records) == l:path_count}
        let s:replace_total_count += l:path_count
        call add(s:replace_paths, a:path)
        let s:replace_path_counts[a:path] = l:path_count
        let s:replace_path_snapshots[a:path] = l:read.snapshot
    endif
endfunction

" Process a small group of files per timer tick so the replacement popup stays
" responsive. A single very large file is still scanned as one unit.
function! s:ReplaceScanStep(generation, timer) abort
    if a:generation != s:replace_scan_generation || s:replace_stage !=# 'scanning'
                \ || s:replace_popup == -1 || empty(popup_getpos(s:replace_popup))
        return
    endif
    let s:replace_scan_timer = -1
    let l:started = reltime()
    let l:processed = 0
    while s:replace_scan_index < s:replace_scan_total_paths
                \ && l:processed < 8
                \ && reltimefloat(reltime(l:started)) < 0.020
        let l:path = s:files[s:replace_scan_index]
        let s:replace_scan_index += 1
        let l:processed += 1
        call s:ReplaceScanFile(l:path)
        if !empty(s:replace_error)
            let s:replace_scan_index = s:replace_scan_total_paths
            break
        endif
    endwhile

    if s:replace_scan_index >= s:replace_scan_total_paths
        let s:replace_stage = 'action'
        if s:replace_total_count == 0 && empty(s:replace_error)
            let s:replace_error = 'No matches found'
        endif
        call s:ReplaceRender()
    else
        call s:ReplaceRender()
        let s:replace_scan_timer = timer_start(10,
                    \ function('s:ReplaceScanStep', [a:generation]))
    endif
endfunction

" Validate regex and initialize an incremental, timer-driven project scan.
" Returns -1 while scanning, 0 for validation error, or the match count in
" timer-less Vim builds where the portable synchronous path is required.
function! s:ReplaceScan() abort
    let s:replace_matches = []
    let s:replace_paths = []
    let s:replace_path_counts = {}
    let s:replace_match_records_by_path = {}
    let s:replace_path_snapshots = {}
    let s:replace_conflicted_paths = {}
    let s:replace_total_count = 0
    let s:replace_skipped_modified = 0
    let s:replace_skipped_binary = 0
    let s:replace_skipped_large = 0
    let s:replace_skipped_changed = 0
    let s:replace_skipped_unsafe = 0
    let s:replace_error = ''
    let s:replace_cache_path = ''
    let s:replace_cache_lines = []
    let s:replace_cache_dirty = 0
    let s:replace_cache_accepted_count = 0
    let s:replace_line_deltas = {}
    let s:replace_files_changed = 0
    let s:replace_changed_count = 0
    let s:replace_max_stored = 30000
    call s:BuildReplaceBufferMap()

    if empty(s:replace_find)
        let s:replace_error = 'Search pattern cannot be empty'
        return 0
    endif
    try
        call match('', s:replace_find)
    catch
        let s:replace_error = 'Invalid Vim regular expression: ' . v:exception
        return 0
    endtry

    let s:replace_scan_generation += 1
    let s:replace_scan_index = 0
    let s:replace_scan_total_paths = len(s:files)
    if exists('*timer_start')
        let s:replace_stage = 'scanning'
        let l:generation = s:replace_scan_generation
        let s:replace_scan_timer = timer_start(0,
                    \ function('s:ReplaceScanStep', [l:generation]))
        return -1
    endif

    for l:path in s:files
        call s:ReplaceScanFile(l:path)
        if !empty(s:replace_error)
            return 0
        endif
    endfor
    return s:replace_total_count
endfunction

" Purpose: Compute the proposed replacement for the selected record using prior line shifts.
function! s:ReplaceCurrentLine() abort
    if s:replace_index < 0 || s:replace_index >= len(s:replace_matches)
        return {}
    endif
    let l:item = s:replace_matches[s:replace_index]
    if !s:ReplaceLoadCache(l:item.path)
        return {}
    endif
    if l:item.line < 1 || l:item.line > len(s:replace_cache_lines)
        return {}
    endif

    let l:line = s:replace_cache_lines[l:item.line - 1]
    let l:delta = get(s:replace_line_deltas, string(l:item.line), 0)
    let l:col = max([0, l:item.col + l:delta])
    let l:anchor = '\%' . (l:col + 1) . 'c\%(' . s:replace_find . '\)'
    let l:pos = match(l:line, l:anchor)
    if l:pos < 0
        return {'path': l:item.path, 'line': l:item.line,
                    \ 'col': l:col, 'original': l:line, 'updated': l:line,
                    \ 'matched': '', 'failed': 1}
    endif
    let l:actual_start = match(l:line, l:anchor)
    let l:actual_end = matchend(l:line, l:anchor)
    let l:matched = strpart(l:line, l:actual_start,
                \ max([0, l:actual_end - l:actual_start]))
    try
        let l:updated = substitute(l:line, l:anchor, s:replace_with, '')
    catch
        let s:replace_error = 'Replacement error: ' . v:exception
        let l:updated = l:line
    endtry
    return {'path': l:item.path, 'line': l:item.line, 'col': l:actual_start,
                \ 'original': l:line, 'updated': l:updated,
                \ 'matched': l:matched, 'failed': 0}
endfunction

" Purpose: Sanitize tabs/control characters and clip a line for popup preview.
function! s:ReplaceFormatLine(prefix, line, width) abort
    let l:text = substitute(a:line, '\t', '  ', 'g')
    let l:text = substitute(l:text, '[[:cntrl:]]', ' ', 'g')
    return a:prefix . s:ReplaceClip(l:text, a:width)
endfunction

" Purpose: Show the before/after line preview for the current replacement.
function! s:ReplaceReviewPreview() abort
    let l:current = s:ReplaceCurrentLine()
    if empty(l:current)
        return ['  [Unable to load current match]']
    endif
    if get(l:current, 'failed', 0)
        return ['  [Match could not be located after earlier replacements]',
                    \ s:ReplaceFormatLine('  ', l:current.original, s:replace_width - 8)]
    endif

    let l:lines = []
    let l:idx = l:current.line - 1
    if l:idx > 0 && l:idx - 1 < len(s:replace_cache_lines)
        call add(l:lines, s:ReplaceFormatLine('  ', s:replace_cache_lines[l:idx - 1], s:replace_width - 8))
    endif
    call add(l:lines, s:ReplaceFormatLine('- ', l:current.original, s:replace_width - 8))
    call add(l:lines, s:ReplaceFormatLine('+ ', l:current.updated, s:replace_width - 8))
    if l:idx + 1 < len(s:replace_cache_lines)
        call add(l:lines, s:ReplaceFormatLine('  ', s:replace_cache_lines[l:idx + 1], s:replace_width - 8))
    endif
    return l:lines
endfunction

" Purpose: Render input, action, one-by-one review, and completion states.
function! s:ReplaceRender() abort
    if s:replace_popup == -1 || empty(popup_getpos(s:replace_popup))
        return
    endif

    let l:width = max([12, s:replace_width - 8])
    let l:lines = []
    if s:replace_stage ==# 'indexing'
        call add(l:lines, ' Preparing replacement file index…')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Git is enumerating the project files in the background.')
        call add(l:lines, ' Esc: cancel')
    elseif s:replace_stage ==# 'input'
        call add(l:lines, ' Vim Regex Search & Replace')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, (s:replace_active_field ==# 'find' ? '> ' : '  ')
                    \ . 'Find (Vim regex): ' . s:ReplaceClip(s:replace_find, l:width - 22))
        call add(l:lines, (s:replace_active_field ==# 'replace' ? '> ' : '  ')
                    \ . 'Replace with: ' . s:ReplaceClip(s:replace_with, l:width - 20))
        call add(l:lines, '')
        call add(l:lines, ' Groups: \(…\)  Replacement: \1, \2, …')
        call add(l:lines, ' Tab: switch field | Enter: next / scan')
        call add(l:lines, ' Backspace: delete | Ctrl-U: clear field | Esc: cancel')
        if !empty(s:replace_warning)
            call add(l:lines, ' WARNING: ' . s:ReplaceClip(s:replace_warning, l:width - 12))
        endif
        if !empty(s:replace_error)
            call add(l:lines, ' ERROR: ' . s:ReplaceClip(s:replace_error, l:width - 10))
        endif
    elseif s:replace_stage ==# 'scanning'
        call add(l:lines, ' Scanning project files…')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Files scanned: ' . s:replace_scan_index . ' / ' . s:replace_scan_total_paths)
        call add(l:lines, ' Matches found: ' . s:replace_total_count)
        call add(l:lines, ' Stored for one-by-one: ' . len(s:replace_matches) . ' / ' . s:replace_max_stored)
        call add(l:lines, ' Esc: cancel scan and close')
        if s:replace_skipped_modified > 0
            call add(l:lines, ' Skipped modified buffers: ' . s:replace_skipped_modified)
        endif
        if s:replace_skipped_binary > 0
            call add(l:lines, ' Skipped binary files: ' . s:replace_skipped_binary)
        endif
        if s:replace_skipped_large > 0
            call add(l:lines, ' Skipped large files: ' . s:replace_skipped_large)
        endif
        if s:replace_skipped_changed > 0
            call add(l:lines, ' Skipped changed files: ' . s:replace_skipped_changed)
        endif
        if s:replace_skipped_unsafe > 0
            call add(l:lines, ' Skipped links/non-regular files: ' . s:replace_skipped_unsafe)
        endif
    elseif s:replace_stage ==# 'planning'
        call add(l:lines, ' Building whole-project change preview…')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Files checked: ' . s:replace_plan_index . ' / ' . s:replace_plan_total)
        call add(l:lines, ' Files with changes: ' . len(s:replace_plan_files))
        call add(l:lines, ' Esc: return to action screen; no files have been written')
    elseif s:replace_stage ==# 'plan'
        let l:selected_paths = s:ReplacePlanSelectedPaths()
        call add(l:lines, ' Preview — no files have been written')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Files selected: ' . len(l:selected_paths) . ' / ' . len(s:replace_plan_files))
        call add(l:lines, ' Occurrences selected: ' . s:ReplacePlanSelectedMatches())
        if s:replace_plan_conflicts > 0
            call add(l:lines, ' Changed / modified since scan: ' . s:replace_plan_conflicts)
        endif
        if s:replace_plan_errors > 0
            call add(l:lines, ' Preview errors / unreadable files: ' . s:replace_plan_errors)
        endif
        if !empty(s:replace_plan_files)
            let l:last = min([len(s:replace_plan_files) - 1, s:replace_plan_selected_index + 9])
            let l:first = max([0, l:last - 9])
            for l:i in range(l:first, l:last)
                let l:path = s:replace_plan_files[l:i]
                let l:mark = get(s:replace_plan_selected, l:path, 0) ? '[x] ' : '[ ] '
                let l:cursor = l:i == s:replace_plan_selected_index ? '> ' : '  '
                call add(l:lines, l:cursor . l:mark . s:ReplaceClip(l:path, l:width - 10))
            endfor
        else
            call add(l:lines, ' No files remain eligible for replacement')
        endif
        call add(l:lines, ' j/k: select | Space: include/exclude | d: file diff')
        call add(l:lines, ' y / Enter: replace selected files | Esc / b: go back')
    elseif s:replace_stage ==# 'action'
        call add(l:lines, ' Vim Regex Search & Replace')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Find: ' . s:ReplaceClip(s:replace_find, l:width - 14))
        call add(l:lines, ' Replace: ' . s:ReplaceClip(s:replace_with, l:width - 17))
        call add(l:lines, ' Matches: ' . s:replace_total_count . ' in ' . len(s:replace_paths) . ' files')
        if s:replace_skipped_modified > 0
            call add(l:lines, ' Skipped modified buffers: ' . s:replace_skipped_modified)
        endif
        if s:replace_skipped_binary > 0
            call add(l:lines, ' Skipped binary files: ' . s:replace_skipped_binary)
        endif
        if s:replace_skipped_large > 0
            call add(l:lines, ' Skipped large files: ' . s:replace_skipped_large)
        endif
        if s:replace_skipped_changed > 0
            call add(l:lines, ' Skipped changed files: ' . s:replace_skipped_changed)
        endif
        if s:replace_skipped_unsafe > 0
            call add(l:lines, ' Skipped links/non-regular files: ' . s:replace_skipped_unsafe)
        endif
        if !empty(s:replace_warning)
            call add(l:lines, ' WARNING: ' . s:ReplaceClip(s:replace_warning, l:width - 12))
        endif
        if s:replace_total_count > len(s:replace_matches)
            call add(l:lines, ' One-by-one list limited to first ' . len(s:replace_matches) . ' matches')
        endif
        call add(l:lines, '')
        call add(l:lines, ' Enter / o: review one by one (y/n/a/q)')
        call add(l:lines, ' a: preview ALL changes | e: edit fields | Esc: cancel')
        if !empty(s:replace_error)
            call add(l:lines, ' ERROR: ' . s:ReplaceClip(s:replace_error, l:width - 10))
        endif
    elseif s:replace_stage ==# 'bulk' || s:replace_stage ==# 'bulk_review'
        call add(l:lines, s:replace_stage ==# 'bulk' ? ' Replacing files…' : ' Applying remaining reviewed matches…')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Progress: ' . s:replace_bulk_index . ' / ' . s:replace_bulk_total)
        call add(l:lines, ' Matches processed: ' . s:replace_bulk_processed)
        call add(l:lines, ' Files written: ' . s:replace_bulk_written)
        call add(l:lines, ' Esc: stop; completed writes are kept (undo available)')
    elseif s:replace_stage ==# 'review'
        if s:replace_index >= len(s:replace_matches)
            call add(l:lines, ' All listed matches reviewed')
            call add(l:lines, ' Enter / Esc: finish')
        else
            let l:item = s:replace_matches[s:replace_index]
            call add(l:lines, ' Replace one by one (' . (s:replace_index + 1) . '/' . len(s:replace_matches) . ')')
            call add(l:lines, ' ' . s:ReplaceClip(l:item.path, l:width - 3))
            call add(l:lines, ' Line ' . l:item.line . ', occurrence ' . (s:replace_index + 1)
                        \ . ' of ' . s:replace_total_count)
            call extend(l:lines, s:ReplaceReviewPreview())
            call add(l:lines, '')
            call add(l:lines, ' y / Enter: replace | n: skip | a: replace all remaining')
            call add(l:lines, ' q / Esc: stop; save safe changes')
            if s:replace_skipped_binary > 0
                call add(l:lines, ' Skipped binary files: ' . s:replace_skipped_binary)
            endif
            if s:replace_skipped_changed > 0
                call add(l:lines, ' Skipped changed files: ' . s:replace_skipped_changed)
            endif
            if !empty(s:replace_warning)
                call add(l:lines, ' WARNING: ' . s:ReplaceClip(s:replace_warning, l:width - 12))
            endif
            if !empty(s:replace_error)
                call add(l:lines, ' ERROR: ' . s:ReplaceClip(s:replace_error, l:width - 10))
            endif
        endif
    else
        call add(l:lines, ' Search & Replace finished')
        call add(l:lines, repeat('-', min([64, l:width])))
        call add(l:lines, ' Replacements accepted: ' . s:replace_changed_count)
        call add(l:lines, ' Files written: ' . s:replace_files_changed)
        if s:replace_skipped_modified > 0
            call add(l:lines, ' Skipped modified buffers/files: ' . s:replace_skipped_modified)
        endif
        if s:replace_skipped_binary > 0
            call add(l:lines, ' Skipped binary files: ' . s:replace_skipped_binary)
        endif
        if s:replace_skipped_large > 0
            call add(l:lines, ' Skipped large files: ' . s:replace_skipped_large)
        endif
        if s:replace_skipped_changed > 0
            call add(l:lines, ' Skipped changed files: ' . s:replace_skipped_changed)
        endif
        if s:replace_skipped_unsafe > 0
            call add(l:lines, ' Skipped links/non-regular files: ' . s:replace_skipped_unsafe)
        endif
        if !empty(s:replace_warning)
            call add(l:lines, ' WARNING: ' . s:ReplaceClip(s:replace_warning, l:width - 12))
        endif
        if s:replace_execution ==# 'one-by-one' && s:replace_total_count > len(s:replace_matches)
            call add(l:lines, ' Not reviewed due to safety limit: ' . (s:replace_total_count - len(s:replace_matches)))
        endif
        if !empty(s:replace_error)
            call add(l:lines, ' Note: ' . s:ReplaceClip(s:replace_error, l:width - 9))
        endif
        if !empty(s:replace_undo_entries)
            call add(l:lines, ' Undo available: :VimFileReplaceUndo')
        endif
        call add(l:lines, ' Enter / Esc: close')
    endif

    call popup_setoptions(s:replace_popup, {'maxheight': min([len(l:lines), max([8, &lines - 6])])})
    call popup_settext(s:replace_popup, l:lines)
endfunction

" Purpose: Write any dirty cache and switch the replacement popup to its done state.
function! s:ReplaceFinish() abort
    call s:ReplaceSaveCache()
    let s:replace_stage = 'done'
    call s:ReplaceRender()
endfunction

" Purpose: Move to the next stored replacement record or finish the workflow.
function! s:ReplaceAdvance() abort
    let s:replace_index += 1
    if s:replace_index >= len(s:replace_matches)
        call s:ReplaceFinish()
    else
        let s:replace_error = ''
        call s:ReplaceRender()
    endif
endfunction

" Purpose: Accept and apply the current one-by-one replacement.
function! s:ReplaceApplyCurrent() abort
    let l:current = s:ReplaceCurrentLine()
    if empty(l:current) || get(l:current, 'failed', 0)
        let s:replace_error = 'Could not locate this match; skipped'
        call s:ReplaceAdvance()
        return
    endif

    let l:item = s:replace_matches[s:replace_index]
    let l:delta = get(s:replace_line_deltas, string(l:item.line), 0)
    let l:old_line = s:replace_cache_lines[l:item.line - 1]
    let l:new_line = l:current.updated
    let s:replace_cache_lines[l:item.line - 1] = l:new_line
    let s:replace_line_deltas[string(l:item.line)] = l:delta + strlen(l:new_line) - strlen(l:old_line)
    if l:new_line !=# l:old_line
        let s:replace_cache_dirty = 1
    endif
    let s:replace_changed_count += 1
    let s:replace_cache_accepted_count += 1
    call s:ReplaceAdvance()
endfunction

" Purpose: Build a stable key for one scanned occurrence in the original file.
function! s:ReplacePlanOccurrenceKey(item) abort
    return a:item.line . ':' . get(a:item, 'scan_start', a:item.col)
                \ . ':' . a:item.col . ':' . a:item.end
endfunction

" Purpose: Expand one scanned Vim-regex occurrence without changing regex semantics.
function! s:ReplacePlanOccurrencePreview(line, item) abort
    let l:scan_start = get(a:item, 'scan_start', a:item.col)
    let l:pattern = '\%>' . l:scan_start . 'c\%(' . s:replace_find . '\m\)'
    try
        let l:start = match(a:line, l:pattern)
        if l:start < 0
            return {'ok': 0, 'error': 'Could not relocate occurrence'}
        endif
        let l:end = matchend(a:line, l:pattern)
        let l:updated = substitute(a:line, l:pattern, s:replace_with, '')
    catch
        return {'ok': 0, 'error': v:exception}
    endtry
    let l:prefix = strpart(a:line, 0, l:start)
    let l:suffix = strpart(a:line, l:end)
    let l:chunk_length = strlen(l:updated) - strlen(l:prefix) - strlen(l:suffix)
    if l:chunk_length < 0
        return {'ok': 0, 'error': 'Could not isolate replacement text'}
    endif
    return {'ok': 1, 'start': l:start, 'end': l:end,
                \ 'old': a:line, 'new': l:updated,
                \ 'chunk': strpart(l:updated, l:start, l:chunk_length)}
endfunction

" Purpose: Count selected occurrences for a path (unopened diff means all selected).
function! s:ReplaceSelectedMatchCount(path) abort
    let l:records = get(s:replace_match_records_by_path, a:path, {})
    let l:selection = get(s:replace_plan_occurrence_selection, a:path, {})
    if empty(l:selection) || !get(l:records, 'complete', 0)
        return get(s:replace_path_counts, a:path, 0)
    endif
    let l:count = 0
    for l:item in get(l:records, 'records', [])
        if get(l:selection, s:ReplacePlanOccurrenceKey(l:item), 1)
            let l:count += 1
        endif
    endfor
    return l:count
endfunction

" Purpose: Return selected file paths that still contain at least one selected occurrence.
function! s:ReplacePlanSelectedPaths() abort
    let l:result = []
    for l:path in s:replace_plan_files
        if get(s:replace_plan_selected, l:path, 0)
                    \ && s:ReplaceSelectedMatchCount(l:path) > 0
            call add(l:result, l:path)
        endif
    endfor
    return l:result
endfunction

function! s:ReplacePlanSelectedMatches() abort
    let l:total = 0
    for l:path in s:ReplacePlanSelectedPaths()
        let l:total += s:ReplaceSelectedMatchCount(l:path)
    endfor
    return l:total
endfunction

function! s:ReplaceDiffClose() abort
    if s:replace_diff_popup > 0 && !empty(popup_getpos(s:replace_diff_popup))
        call popup_close(s:replace_diff_popup)
    endif
    let s:replace_diff_popup = -1
    let s:replace_diff_selectable = 0
endfunction

" Purpose: Render one page of occurrence-level diff rows for an eligible file.
function! s:ReplaceDiffRender() abort
    if s:replace_diff_popup <= 0 || empty(popup_getpos(s:replace_diff_popup))
        return
    endif
    let l:page_size = 40
    let l:total = len(s:replace_diff_records)
    let l:page = float2nr(s:replace_diff_page_start / l:page_size) + 1
    let l:pages = max([1, float2nr((l:total + l:page_size - 1) / l:page_size)])
    let l:first = s:replace_diff_page_start
    let l:last = min([l:total - 1, l:first + l:page_size - 1])
    let l:lines = [' Diff: ' . s:replace_diff_path,
                \ ' Occurrence selection — page ' . l:page . '/' . l:pages
                \ . ' | selected ' . s:ReplaceSelectedMatchCount(s:replace_diff_path)
                \ . '/' . l:total,
                \ repeat('-', min([100, &columns - 8])),
                \ ' Space: include/exclude | Up/Down or j/k: select',
                \ ' PageUp/[ and PageDown/]: change page | Esc/Enter: close', '']
    if l:total > 0 && l:first <= l:last
        for l:i in range(l:first, l:last)
            let l:item = s:replace_diff_records[l:i]
            let l:key = s:ReplacePlanOccurrenceKey(l:item)
            let l:enabled = get(s:replace_plan_occurrence_selection[s:replace_diff_path], l:key, 1)
            let l:marker = l:i == s:replace_diff_selected_index ? '>' : ' '
            let l:check = l:enabled ? '[x]' : '[ ]'
            let l:old = get(s:replace_diff_original_lines, l:item.line - 1, '')
            let l:preview = s:ReplacePlanOccurrencePreview(l:old, l:item)
            call add(l:lines, printf('%s %s line %d, column %d', l:marker, l:check, l:item.line, l:item.col + 1))
            if get(l:preview, 'ok', 0)
                call add(l:lines, s:ReplaceFormatLine('- ', l:old, &columns - 14))
                call add(l:lines, s:ReplaceFormatLine('+ ', l:preview.new, &columns - 14))
            else
                call add(l:lines, '  [Preview error: ' . s:ReplaceClip(get(l:preview, 'error', 'unknown'), &columns - 22) . ']')
            endif
        endfor
    else
        call add(l:lines, ' No stored occurrences')
    endif
    call popup_settext(s:replace_diff_popup, l:lines)
endfunction

function! s:ReplaceDiffHandleKey(id, key) abort
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'q' || a:key ==# "\<CR>"
        call s:ReplaceDiffClose()
    elseif s:replace_diff_selectable
        let l:page_size = 40
        if a:key ==# "\<Down>" || a:key ==# 'j'
            let s:replace_diff_selected_index = min([len(s:replace_diff_records) - 1, s:replace_diff_selected_index + 1])
            if s:replace_diff_selected_index >= s:replace_diff_page_start + l:page_size
                let s:replace_diff_page_start = s:replace_diff_selected_index
            endif
            call s:ReplaceDiffRender()
        elseif a:key ==# "\<Up>" || a:key ==# 'k'
            let s:replace_diff_selected_index = max([0, s:replace_diff_selected_index - 1])
            if s:replace_diff_selected_index < s:replace_diff_page_start
                let s:replace_diff_page_start = max([0, s:replace_diff_selected_index - l:page_size + 1])
            endif
            call s:ReplaceDiffRender()
        elseif a:key ==# ' '
            if !empty(s:replace_diff_records)
                let l:item = s:replace_diff_records[s:replace_diff_selected_index]
                let l:key = s:ReplacePlanOccurrenceKey(l:item)
                let l:selection = s:replace_plan_occurrence_selection[s:replace_diff_path]
                let l:selection[l:key] = !get(l:selection, l:key, 1)
                let s:replace_plan_occurrence_selection[s:replace_diff_path] = l:selection
                call s:ReplaceDiffRender()
            endif
        elseif a:key ==# "\<PageDown>" || a:key ==# ']'
            let s:replace_diff_page_start = min([max([0, len(s:replace_diff_records) - 1]), s:replace_diff_page_start + l:page_size])
            let s:replace_diff_selected_index = s:replace_diff_page_start
            call s:ReplaceDiffRender()
        elseif a:key ==# "\<PageUp>" || a:key ==# '['
            let s:replace_diff_page_start = max([0, s:replace_diff_page_start - l:page_size])
            let s:replace_diff_selected_index = s:replace_diff_page_start
            call s:ReplaceDiffRender()
        endif
    else
        if a:key ==# "\<Down>" || a:key ==# 'j'
            call popup_scroll(s:replace_diff_popup, 1, 'line')
        elseif a:key ==# "\<Up>" || a:key ==# 'k'
            call popup_scroll(s:replace_diff_popup, -1, 'line')
        elseif a:key ==# "\<PageDown>"
            call popup_scroll(s:replace_diff_popup, 1, 'page')
        elseif a:key ==# "\<PageUp>"
            call popup_scroll(s:replace_diff_popup, -1, 'page')
        endif
    endif
    return 1
endfunction

" Purpose: Show verified line diff and allow selecting individual matches when fully indexed.
function! s:ReplacePlanShowDiff(path) abort
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:expected = get(s:replace_path_snapshots, a:path, {})
    if empty(l:expected) || !s:ReplaceSnapshotMatches(l:absolute, l:expected, 1)
        let s:replace_error = 'File changed after preview; diff refused: ' . a:path
        call s:ReplaceRender()
        return
    endif
    let l:read = s:ReplaceReadSnapshot(l:absolute)
    if !l:read.ok || !s:ReplaceStatEqual(l:expected, l:read.snapshot)
                \ || (!empty(get(l:expected, 'hash', '')) && l:expected.hash !=# l:read.snapshot.hash)
        let s:replace_error = 'Could not verify file for diff: ' . a:path
        call s:ReplaceRender()
        return
    endif

    let l:match_data = get(s:replace_match_records_by_path, a:path, {})
    if get(l:match_data, 'complete', 0) && !empty(get(l:match_data, 'records', []))
        let s:replace_diff_path = a:path
        let s:replace_diff_records = copy(l:match_data.records)
        let s:replace_diff_original_lines = copy(l:read.lines)
        let s:replace_diff_selected_index = 0
        let s:replace_diff_page_start = 0
        if !has_key(s:replace_plan_occurrence_selection, a:path)
            let l:selection = {}
            for l:item in s:replace_diff_records
                let l:selection[s:ReplacePlanOccurrenceKey(l:item)] = 1
            endfor
            let s:replace_plan_occurrence_selection[a:path] = l:selection
        endif
        call s:ReplaceDiffClose()
        let s:replace_diff_selectable = 1
        call s:ApplyPopupHighlights()
        let s:replace_diff_popup = popup_create(['Occurrence diff'], {
                    \ 'pos': 'center', 'minwidth': max([40, min([110, &columns - 8])]),
                    \ 'maxwidth': max([40, min([110, &columns - 8])]),
                    \ 'minheight': 8, 'maxheight': max([8, &lines - 6]),
                    \ 'border': [1, 1, 1, 1], 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                    \ 'borderhighlight': ['VimFileSearchPopupBorder'], 'padding': [0, 1, 0, 1],
                    \ 'title': ' Replacement Diff ', 'mapping': 0,
                    \ 'filter': function('s:ReplaceDiffHandleKey'), 'wrap': 0,
                    \ 'scrollbar': 1, 'highlight': 'VimFileSearchPopup'})
        call s:ReplaceDiffRender()
        return
    endif

    let l:lines = [' Diff: ' . a:path, repeat('-', min([100, &columns - 8])), ' - old line', ' + replacement line', '']
    let l:count = 0
    let l:line_count = s:ReplaceActualLineCount(a:path, l:read.lines)
    if l:line_count > 0
        for l:i in range(0, l:line_count - 1)
            let l:old = l:read.lines[l:i]
            try
                let l:new = substitute(l:old, s:replace_find, s:replace_with, 'g')
            catch
                let s:replace_error = 'Regex error while building diff: ' . v:exception
                return
            endtry
            if l:new !=# l:old
                call add(l:lines, '@@ line ' . (l:i + 1) . ' @@')
                call add(l:lines, s:ReplaceFormatLine('- ', l:old, &columns - 12))
                call add(l:lines, s:ReplaceFormatLine('+ ', l:new, &columns - 12))
                let l:count += 1
                if l:count >= 300
                    call add(l:lines, '… diff truncated after 300 changed lines …')
                    break
                endif
            endif
        endfor
    endif
    if l:count == 0
        call add(l:lines, ' No line-level changes in this file')
    endif
    call add(l:lines, '')
    call add(l:lines, ' Up/Down or j/k: scroll | Esc/q/Enter: close')
    call s:ReplaceDiffClose()
    call s:ApplyPopupHighlights()
    let s:replace_diff_popup = popup_create(l:lines, {
                \ 'pos': 'center', 'minwidth': max([40, min([110, &columns - 8])]),
                \ 'maxwidth': max([40, min([110, &columns - 8])]),
                \ 'minheight': 8, 'maxheight': max([8, &lines - 6]),
                \ 'border': [1, 1, 1, 1], 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'], 'padding': [0, 1, 0, 1],
                \ 'title': ' Replacement Diff ', 'mapping': 0,
                \ 'filter': function('s:ReplaceDiffHandleKey'), 'wrap': 0,
                \ 'scrollbar': 1, 'highlight': 'VimFileSearchPopup'})
endfunction

" Purpose: Build one file's non-writing preview and retain a few before/after examples.
function! s:ReplacePlanFile(path) abort
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:expected = get(s:replace_path_snapshots, a:path, {})
    if empty(l:expected) || !s:ReplaceSnapshotMatches(l:absolute, l:expected, 1)
        call s:ReplaceMarkChanged(a:path)
        let s:replace_plan_conflicts += 1
        return
    endif
    let l:buf = s:ReplaceFindBuffer(a:path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        call s:ReplaceMarkChanged(a:path)
        let s:replace_plan_conflicts += 1
        return
    endif
    let l:read = s:ReplaceReadSnapshot(l:absolute)
    if !l:read.ok
        let s:replace_plan_errors += 1
        return
    endif
    if !s:ReplaceStatEqual(l:expected, l:read.snapshot)
                \ || (!empty(get(l:expected, 'hash', ''))
                \ && l:expected.hash !=# l:read.snapshot.hash)
        call s:ReplaceMarkChanged(a:path)
        let s:replace_plan_conflicts += 1
        return
    endif
    for l:line in l:read.lines
        if stridx(l:line, "\n") >= 0
            let s:replace_plan_errors += 1
            return
        endif
    endfor

    let l:changed = 0
    let l:line_count = s:ReplaceActualLineCount(a:path, l:read.lines)
    if l:line_count > 0
        for l:index in range(0, l:line_count - 1)
            let l:old = l:read.lines[l:index]
            try
                let l:new = substitute(l:old, s:replace_find, s:replace_with, 'g')
            catch
                let s:replace_plan_errors += 1
                return
            endtry
            if l:new !=# l:old
                let l:changed = 1
                if len(s:replace_plan_examples) < 10
                    call add(s:replace_plan_examples, {
                                \ 'path': a:path,
                                \ 'line': l:index + 1,
                                \ 'old': l:old,
                                \ 'new': l:new})
                endif
            endif
        endfor
    endif
    if l:changed
        call add(s:replace_plan_files, a:path)
        let s:replace_plan_selected[a:path] = 1
        let s:replace_plan_matches += get(s:replace_path_counts, a:path, 0)
    endif
endfunction

" Purpose: Start the timer-sliced, whole-project preview without writing files.
function! s:ReplacePlanStart() abort
    let s:replace_plan_generation += 1
    let s:replace_plan_index = 0
    let s:replace_plan_total = len(s:replace_paths)
    let s:replace_plan_files = []
    let s:replace_plan_selected = {}
    let s:replace_plan_occurrence_selection = {}
    let s:replace_diff_path = ''
    let s:replace_diff_records = []
    let s:replace_diff_original_lines = []
    let s:replace_diff_selected_index = 0
    let s:replace_diff_page_start = 0
    let s:replace_diff_selectable = 0
    let s:replace_plan_selected_index = 0
    let s:replace_plan_examples = []
    let s:replace_plan_matches = 0
    let s:replace_plan_conflicts = 0
    let s:replace_plan_errors = 0
    let s:replace_stage = 'planning'
    if !exists('*timer_start')
        for l:path in s:replace_paths
            call s:ReplacePlanFile(l:path)
        endfor
        let s:replace_stage = 'plan'
        call s:ReplaceRender()
        return
    endif
    let l:generation = s:replace_plan_generation
    let s:replace_plan_timer = timer_start(0, function('s:ReplacePlanStep', [l:generation]))
    call s:ReplaceRender()
endfunction

" Purpose: Process a small group of files per preview timer tick.
function! s:ReplacePlanStep(generation, timer) abort
    if a:generation != s:replace_plan_generation || s:replace_stage !=# 'planning'
                \ || s:replace_popup == -1 || empty(popup_getpos(s:replace_popup))
        return
    endif
    let s:replace_plan_timer = -1
    let l:started = reltime()
    let l:processed = 0
    while s:replace_plan_index < s:replace_plan_total
                \ && l:processed < 4
                \ && reltimefloat(reltime(l:started)) < 0.020
        let l:path = s:replace_paths[s:replace_plan_index]
        let s:replace_plan_index += 1
        let l:processed += 1
        call s:ReplacePlanFile(l:path)
    endwhile
    call s:ReplaceRender()
    if s:replace_plan_index < s:replace_plan_total
        let s:replace_plan_timer = timer_start(10, function('s:ReplacePlanStep', [a:generation]))
    else
        let s:replace_stage = 'plan'
        call s:ReplaceRender()
    endif
endfunction

" Purpose: Replace all matches in one snapshotted regular file and commit atomically.
function! s:ReplaceAllFile(path) abort
    let l:absolute = s:root . (s:root =~# '/$' ? '' : '/') . a:path
    let l:expected = get(s:replace_path_snapshots, a:path, {})
    if empty(l:expected)
        call s:ReplaceMarkChanged(a:path)
        return
    endif

    let l:max_size = get(g:, 'file_search_replace_max_file_bytes', 8 * 1024 * 1024)
    if l:max_size > 0 && l:expected.size > l:max_size
        let s:replace_skipped_large += 1
        return
    endif

    let l:buf = s:ReplaceFindBuffer(a:path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        let s:replace_skipped_modified += 1
        return
    endif
    let l:read = s:ReplaceReadSnapshot(l:absolute)
    if !l:read.ok
        if l:read.large
            let s:replace_skipped_large += 1
            call s:ReplaceMarkChanged(a:path)
        elseif l:read.changed || !s:ReplaceSnapshotMatches(l:absolute, l:expected, 0)
            call s:ReplaceMarkChanged(a:path)
        else
            let s:replace_bulk_errors += 1
        endif
        return
    endif
    if !s:ReplaceStatEqual(l:expected, l:read.snapshot)
                \ || (!empty(get(l:expected, 'hash', ''))
                \ && l:expected.hash !=# l:read.snapshot.hash)
        call s:ReplaceMarkChanged(a:path)
        return
    endif
    let l:lines = copy(l:read.lines)

    for l:line in l:lines
        if stridx(l:line, "\n") >= 0
            let s:replace_skipped_binary += 1
            return
        endif
    endfor

    let l:changed = 0
    let l:actual_count = s:ReplaceActualLineCount(a:path, l:lines)
    let l:match_data = get(s:replace_match_records_by_path, a:path, {})
    let l:selection = get(s:replace_plan_occurrence_selection, a:path, {})
    let l:selective = get(l:match_data, 'complete', 0) && !empty(l:selection)
                \ && s:ReplaceSelectedMatchCount(a:path) < get(s:replace_path_counts, a:path, 0)
    if l:selective
        let l:by_line = {}
        for l:item in l:match_data.records
            let l:line_key = string(l:item.line)
            if !has_key(l:by_line, l:line_key)
                let l:by_line[l:line_key] = []
            endif
            call add(l:by_line[l:line_key], l:item)
        endfor
    endif
    if l:actual_count > 0
        for l:i in range(0, l:actual_count - 1)
            let l:oldline = l:lines[l:i]
            try
                if l:selective && has_key(l:by_line, string(l:i + 1))
                    let l:cursor = 0
                    let l:newline = ''
                    for l:item in l:by_line[string(l:i + 1)]
                        let l:key = s:ReplacePlanOccurrenceKey(l:item)
                        if !get(l:selection, l:key, 1)
                            continue
                        endif
                        let l:preview = s:ReplacePlanOccurrencePreview(l:oldline, l:item)
                        if !get(l:preview, 'ok', 0) || l:preview.start < l:cursor
                            let s:replace_error = 'Could not safely apply selected occurrence in ' . a:path
                            let s:replace_bulk_errors += 1
                            return
                        endif
                        let l:newline .= strpart(l:oldline, l:cursor, l:preview.start - l:cursor)
                                    \ . l:preview.chunk
                        let l:cursor = l:preview.end
                    endfor
                    let l:newline .= strpart(l:oldline, l:cursor)
                else
                    let l:newline = substitute(l:oldline, s:replace_find, s:replace_with, 'g')
                endif
            catch
                let s:replace_error = 'Replacement error: ' . v:exception
                let s:replace_bulk_errors += 1
                return
            endtry
            if l:newline !=# l:oldline
                let l:lines[l:i] = l:newline
                let l:changed = 1
            endif
        endfor
    endif

    let l:selected_count = s:ReplaceSelectedMatchCount(a:path)
    if !l:changed
        let s:replace_bulk_processed += l:selected_count
        return
    endif

    let l:result = s:ReplaceAtomicWrite(l:absolute, l:lines, l:expected, l:read.lines, 1)
    if l:result.ok
        let s:replace_path_snapshots[a:path] = l:result.snapshot
        let s:replace_bulk_processed += l:selected_count
        let s:replace_bulk_written += 1
        call s:ReplaceSyncBuffer(a:path)
        call s:PreviewCacheClear()
        call s:IndexCacheClear()
    elseif l:result.changed
        call s:ReplaceMarkChanged(a:path)
    else
        let s:replace_bulk_errors += 1
        let s:replace_error = 'Could not safely write ' . a:path . ': ' . l:result.error
    endif
endfunction

" Purpose: Process a time- and file-bounded slice of the bulk replacement.
function! s:ReplaceAllStep(generation, timer) abort
    if a:generation != s:replace_bulk_generation || s:replace_stage !=# 'bulk'
                \ || s:replace_popup == -1 || empty(popup_getpos(s:replace_popup))
        return
    endif
    let s:replace_bulk_timer = -1
    let l:started = reltime()
    let l:processed = 0
    while s:replace_bulk_index < s:replace_bulk_total
                \ && l:processed < 4
                \ && reltimefloat(reltime(l:started)) < 0.020
        let l:path = s:replace_paths[s:replace_bulk_index]
        let s:replace_bulk_index += 1
        let l:processed += 1
        call s:ReplaceAllFile(l:path)
    endwhile
    call s:ReplaceRender()
    if s:replace_bulk_index < s:replace_bulk_total
        let s:replace_bulk_timer = timer_start(10, function('s:ReplaceAllStep', [a:generation]))
    else
        let s:replace_changed_count = s:replace_bulk_processed
        let s:replace_files_changed = s:replace_bulk_written
        if s:replace_bulk_errors > 0
            let s:replace_error = s:replace_bulk_errors . ' file read/write or replacement errors'
        endif
        call s:ReplaceFinish()
    endif
endfunction

" Purpose: Start timer-sliced bulk replacement without blocking the Vim event loop.
function! s:ReplaceAll() abort
    let s:replace_execution = 'all'
    call s:BuildReplaceBufferMap()
    let s:replace_bulk_generation += 1
    let s:replace_bulk_index = 0
    let s:replace_bulk_total = len(s:replace_paths)
    let s:replace_bulk_processed = 0
    let s:replace_bulk_written = 0
    let s:replace_bulk_errors = 0
    let s:replace_stage = 'bulk'
    if !exists('*timer_start')
        for l:path in s:replace_paths
            call s:ReplaceAllFile(l:path)
        endfor
        let s:replace_changed_count = s:replace_bulk_processed
        let s:replace_files_changed = s:replace_bulk_written
        if s:replace_bulk_errors > 0
            let s:replace_error = s:replace_bulk_errors . ' file read/write or replacement errors'
        endif
        call s:ReplaceFinish()
        return
    endif
    let l:generation = s:replace_bulk_generation
    let s:replace_bulk_timer = timer_start(0, function('s:ReplaceAllStep', [l:generation]))
    call s:ReplaceRender()
endfunction

" Purpose: Apply one stored review record, preserving the per-file edit cache.
function! s:ReplaceAllRemainingOne() abort
    let l:item = s:replace_matches[s:replace_index]
    if !s:ReplaceLoadCache(l:item.path)
        let s:replace_index += 1
        return
    endif
    let l:current = s:ReplaceCurrentLine()
    if !empty(l:current) && !get(l:current, 'failed', 0)
        let l:delta = get(s:replace_line_deltas, string(l:item.line), 0)
        let l:old_line = s:replace_cache_lines[l:item.line - 1]
        let s:replace_cache_lines[l:item.line - 1] = l:current.updated
        let s:replace_line_deltas[string(l:item.line)] = l:delta
                    \ + strlen(l:current.updated) - strlen(l:old_line)
        if l:current.updated !=# l:old_line
            let s:replace_cache_dirty = 1
        endif
        let s:replace_changed_count += 1
        let s:replace_cache_accepted_count += 1
    endif
    let s:replace_index += 1
endfunction

" Purpose: Process a bounded slice of remaining one-by-one replacement records.
function! s:ReplaceAllRemainingStep(generation, timer) abort
    if a:generation != s:replace_bulk_generation || s:replace_stage !=# 'bulk_review'
                \ || s:replace_popup == -1 || empty(popup_getpos(s:replace_popup))
        return
    endif
    let s:replace_bulk_timer = -1
    let l:started = reltime()
    let l:processed = 0
    while s:replace_index < len(s:replace_matches)
                \ && l:processed < 100
                \ && reltimefloat(reltime(l:started)) < 0.020
        call s:ReplaceAllRemainingOne()
        let l:processed += 1
    endwhile
    let s:replace_bulk_index = s:replace_index
    call s:ReplaceRender()
    if s:replace_index < len(s:replace_matches)
        let s:replace_bulk_timer = timer_start(10, function('s:ReplaceAllRemainingStep', [a:generation]))
    else
        call s:ReplaceFinish()
    endif
endfunction

" Purpose: Start timer-sliced completion of all remaining reviewed matches.
function! s:ReplaceAllRemaining() abort
    let s:replace_bulk_generation += 1
    let s:replace_bulk_index = s:replace_index
    let s:replace_bulk_total = len(s:replace_matches)
    let s:replace_stage = 'bulk_review'
    if !exists('*timer_start')
        while s:replace_index < len(s:replace_matches)
            call s:ReplaceAllRemainingOne()
        endwhile
        call s:ReplaceFinish()
        return
    endif
    let l:generation = s:replace_bulk_generation
    let s:replace_bulk_timer = timer_start(0, function('s:ReplaceAllRemainingStep', [l:generation]))
    call s:ReplaceRender()
endfunction

" Purpose: Dispatch keyboard input according to the replacement popup stage.
function! s:ReplaceHandleKey(id, key) abort
    if s:replace_stage ==# 'done'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# "\<CR>"
            call s:ReplacePopupClose()
        endif
        return 1
    endif

    if s:replace_stage ==# 'planning'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
            let s:replace_plan_generation += 1
            if s:replace_plan_timer != -1 && exists('*timer_stop')
                call timer_stop(s:replace_plan_timer)
                let s:replace_plan_timer = -1
            endif
            let s:replace_stage = 'action'
            call s:ReplaceRender()
        endif
        return 1
    endif

    if s:replace_stage ==# 'plan'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'b'
            call s:ReplaceDiffClose()
            let s:replace_stage = 'action'
            call s:ReplaceRender()
        elseif a:key ==# "\<Down>" || a:key ==# 'j'
            let s:replace_plan_selected_index = min([s:replace_plan_selected_index + 1, len(s:replace_plan_files) - 1])
            call s:ReplaceRender()
        elseif a:key ==# "\<Up>" || a:key ==# 'k'
            let s:replace_plan_selected_index = max([0, s:replace_plan_selected_index - 1])
            call s:ReplaceRender()
        elseif a:key ==# ' '
            if !empty(s:replace_plan_files)
                let l:path = s:replace_plan_files[s:replace_plan_selected_index]
                let s:replace_plan_selected[l:path] = !get(s:replace_plan_selected, l:path, 0)
                call s:ReplaceRender()
            endif
        elseif a:key ==# 'd'
            if !empty(s:replace_plan_files)
                call s:ReplacePlanShowDiff(s:replace_plan_files[s:replace_plan_selected_index])
            endif
        elseif a:key ==# "\<CR>" || a:key ==# 'y'
            let s:replace_paths = s:ReplacePlanSelectedPaths()
            let s:replace_total_count = s:ReplacePlanSelectedMatches()
            if empty(s:replace_paths)
                let s:replace_error = 'Select at least one file to replace'
                call s:ReplaceRender()
            else
                call s:ReplaceDiffClose()
                call s:ReplaceAll()
            endif
        endif
        return 1
    endif

    if s:replace_stage ==# 'review'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'q'
            call s:ReplaceFinish()
        elseif a:key ==# "\<CR>" || a:key ==# 'y'
            call s:ReplaceApplyCurrent()
        elseif a:key ==# 'n'
            call s:ReplaceAdvance()
        elseif a:key ==# 'a'
            call s:ReplaceAllRemaining()
        endif
        return 1
    endif

    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
        call s:ReplacePopupClose()
        return 1
    endif

    if s:replace_stage ==# 'indexing'
        return 1
    endif

    if s:replace_stage ==# 'scanning'
        return 1
    endif

    if s:replace_stage ==# 'bulk'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
            let s:replace_bulk_generation += 1
            if s:replace_bulk_timer != -1 && exists('*timer_stop')
                call timer_stop(s:replace_bulk_timer)
                let s:replace_bulk_timer = -1
            endif
            let s:replace_error = 'Stopped by user; completed file writes were kept'
            let s:replace_changed_count = s:replace_bulk_processed
            let s:replace_files_changed = s:replace_bulk_written
            call s:ReplaceFinish()
        endif
        return 1
    endif

    if s:replace_stage ==# 'bulk_review'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
            let s:replace_bulk_generation += 1
            if s:replace_bulk_timer != -1 && exists('*timer_stop')
                call timer_stop(s:replace_bulk_timer)
                let s:replace_bulk_timer = -1
            endif
            let s:replace_error = 'Stopped by user; completed replacements were kept'
            call s:ReplaceFinish()
        endif
        return 1
    endif

    if s:replace_stage ==# 'action'
        if a:key ==# 'a'
            call s:ReplacePlanStart()
        elseif a:key ==# 'o' || a:key ==# "\<CR>"
            let s:replace_execution = 'one-by-one'
            let s:replace_index = 0
            let s:replace_stage = 'review'
            if empty(s:replace_matches)
                call s:ReplaceFinish()
            else
                call s:ReplaceRender()
            endif
        elseif a:key ==# 'e'
            let s:replace_stage = 'input'
            let s:replace_active_field = 'find'
            let s:replace_error = ''
            call s:ReplaceRender()
        endif
        return 1
    endif

    " Input stage
    if a:key ==# "\<Tab>"
        let s:replace_active_field = s:replace_active_field ==# 'find' ? 'replace' : 'find'
        call s:ReplaceRender()
        return 1
    endif
    if a:key ==# "\<CR>"
        if s:replace_active_field ==# 'find'
            let s:replace_active_field = 'replace'
            call s:ReplaceRender()
        else
            let l:scan_result = s:ReplaceScan()
            if l:scan_result == -1
                let s:replace_stage = 'scanning'
            elseif l:scan_result > 0
                let s:replace_stage = 'action'
            elseif empty(s:replace_error)
                let s:replace_error = 'No matches found'
                let s:replace_stage = 'action'
            else
                let s:replace_stage = 'input'
            endif
            call s:ReplaceRender()
        endif
        return 1
    endif
    if a:key ==# "\<BS>" || a:key ==# "\<C-H>"
        if s:replace_active_field ==# 'find'
            let s:replace_find = strcharpart(s:replace_find, 0, max([0, strchars(s:replace_find) - 1]))
        else
            let s:replace_with = strcharpart(s:replace_with, 0, max([0, strchars(s:replace_with) - 1]))
        endif
        let s:replace_error = ''
        call s:ReplaceRender()
        return 1
    endif
    if a:key ==# "\<C-U>"
        if s:replace_active_field ==# 'find'
            let s:replace_find = ''
        else
            let s:replace_with = ''
        endif
        let s:replace_error = ''
        call s:ReplaceRender()
        return 1
    endif
    if strchars(a:key) == 1 && char2nr(a:key) >= 32 && char2nr(a:key) != 127
        if s:replace_active_field ==# 'find'
            let s:replace_find .= a:key
        else
            let s:replace_with .= a:key
        endif
        let s:replace_error = ''
        call s:ReplaceRender()
    endif
    return 1
endfunction

" Purpose: Render confirmation, progress and result states for safe undo.
function! s:ReplaceUndoRender() abort
    if s:replace_undo_popup == -1 || empty(popup_getpos(s:replace_undo_popup))
        return
    endif
    let l:count = len(s:replace_undo_entries)
    let l:lines = []
    if s:replace_undo_stage ==# 'confirm'
        call add(l:lines, ' Undo latest replacement batch?')
        call add(l:lines, repeat('-', 54))
        call add(l:lines, ' Files in journal: ' . l:count)
        call add(l:lines, ' Only files still matching their post-replacement fingerprint will be restored.')
        call add(l:lines, ' Files edited externally or in modified buffers will be skipped.')
        call add(l:lines, ' Journal is persistent across Vim restarts; restore checks each file before writing.')
        for l:item in s:replace_undo_entries[0 : min([l:count - 1, 7])]
            call add(l:lines, '  ' . s:ReplaceClip(fnamemodify(l:item.path, ':~:.'), 54))
        endfor
        call add(l:lines, ' Enter / y: restore | Esc: cancel')
    elseif s:replace_undo_stage ==# 'undo'
        call add(l:lines, ' Restoring replacement batch…')
        call add(l:lines, repeat('-', 54))
        call add(l:lines, ' Files processed: ' . s:replace_undo_index . ' / ' . l:count)
        call add(l:lines, ' Files restored: ' . s:replace_undo_restored)
        call add(l:lines, ' Files skipped: ' . s:replace_undo_skipped)
        call add(l:lines, ' Esc: stop; already restored files stay restored')
    else
        call add(l:lines, ' Undo finished')
        call add(l:lines, repeat('-', 54))
        call add(l:lines, ' Files restored: ' . s:replace_undo_restored)
        call add(l:lines, ' Files skipped / conflicted: ' . s:replace_undo_skipped)
        if !empty(s:replace_undo_entries)
            call add(l:lines, ' Remaining backups are retained for another attempt.')
        else
            call add(l:lines, ' Undo journal cleared.')
        endif
        call add(l:lines, ' Enter / Esc: close')
    endif
    call popup_settext(s:replace_undo_popup, l:lines)
    call popup_setoptions(s:replace_undo_popup, {'maxheight': min([len(l:lines), max([8, &lines - 6])])})
endfunction

" Purpose: Restore one file only if its current bytes still match the recorded post-write snapshot.
function! s:ReplaceUndoOne(index) abort
    let l:item = s:replace_undo_entries[a:index]
    let l:buf = bufnr(l:item.path)
    if l:buf > 0 && getbufvar(l:buf, '&modified')
        let s:replace_undo_skipped += 1
        return
    endif
    if !s:ReplaceSnapshotMatches(l:item.path, l:item.after, 1)
        let s:replace_undo_skipped += 1
        return
    endif
    try
        let l:original = readfile(l:item.backup, 'b')
    catch
        let s:replace_undo_skipped += 1
        return
    endtry
    if !empty(get(l:item.before, 'hash', ''))
                \ && s:ReplaceContentHash(l:original) !=# l:item.before.hash
        let s:replace_undo_skipped += 1
        return
    endif
    let l:result = s:ReplaceAtomicWrite(l:item.path, l:original, l:item.after, [], 0)
    if !l:result.ok
        let s:replace_undo_skipped += 1
        return
    endif
    let l:item.restored = 1
    let s:replace_undo_restored += 1
    call delete(l:item.backup)
    call s:ReplaceUndoPersist()
    call s:ReplaceSyncBuffer(l:item.path)
    call s:IndexCacheClear()
    call s:PreviewCacheClear()
endfunction

" Purpose: Finish a partial/full undo and retain only backups for conflicted files.
function! s:ReplaceUndoFinish() abort
    let l:remaining = []
    for l:item in s:replace_undo_entries
        if !get(l:item, 'restored', 0)
            call add(l:remaining, l:item)
        endif
    endfor
    let s:replace_undo_entries = l:remaining
    if empty(s:replace_undo_entries)
        if !empty(s:replace_undo_dir)
            call delete(s:replace_undo_dir, 'rf')
        endif
        let s:replace_undo_dir = ''
        let s:replace_undo_id = ''
        let s:replace_undo_generation = -1
    else
        call s:ReplaceUndoPersist()
    endif
    let s:replace_undo_stage = 'done'
    call s:ReplaceUndoRender()
endfunction

" Purpose: Process undo entries in reverse order using bounded timer slices.
function! s:ReplaceUndoStep(generation, timer) abort
    if a:generation != s:replace_undo_generation_token || s:replace_undo_stage !=# 'undo'
                \ || s:replace_undo_popup == -1 || empty(popup_getpos(s:replace_undo_popup))
        return
    endif
    let s:replace_undo_timer = -1
    let l:started = reltime()
    let l:processed = 0
    while s:replace_undo_index < len(s:replace_undo_entries)
                \ && l:processed < 4
                \ && reltimefloat(reltime(l:started)) < 0.020
        let l:entry_index = len(s:replace_undo_entries) - 1 - s:replace_undo_index
        call s:ReplaceUndoOne(l:entry_index)
        let s:replace_undo_index += 1
        let l:processed += 1
    endwhile
    if s:replace_undo_index >= len(s:replace_undo_entries)
        call s:ReplaceUndoFinish()
    else
        call s:ReplaceUndoRender()
        let s:replace_undo_timer = timer_start(10, function('s:ReplaceUndoStep', [a:generation]))
    endif
endfunction

" Purpose: Cancel/close undo popup without undoing already restored files.
function! s:ReplaceUndoClose() abort
    let s:replace_undo_generation_token += 1
    if s:replace_undo_timer != -1 && exists('*timer_stop')
        call timer_stop(s:replace_undo_timer)
        let s:replace_undo_timer = -1
    endif
    " If the user cancels a running undo, compact the journal now: files
    " already restored have had their backup removed and must not be retried.
    if s:replace_undo_stage ==# 'undo'
        call s:ReplaceUndoFinish()
    endif
    if s:replace_undo_popup != -1
        if !empty(popup_getpos(s:replace_undo_popup))
            call popup_close(s:replace_undo_popup)
        endif
        let s:replace_undo_popup = -1
    endif
endfunction

" Purpose: Handle confirmation/cancellation keys for the undo popup.
function! s:ReplaceUndoHandleKey(id, key) abort
    if s:replace_undo_stage ==# 'confirm'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
            call s:ReplaceUndoClose()
        elseif a:key ==# 'y' || a:key ==# "\<CR>"
            let s:replace_undo_stage = 'undo'
            let s:replace_undo_index = 0
            let s:replace_undo_restored = 0
            let s:replace_undo_skipped = 0
            let s:replace_undo_generation_token += 1
            let l:generation = s:replace_undo_generation_token
            if exists('*timer_start')
                let s:replace_undo_timer = timer_start(0, function('s:ReplaceUndoStep', [l:generation]))
                call s:ReplaceUndoRender()
            else
                while s:replace_undo_index < len(s:replace_undo_entries)
                    let l:index = len(s:replace_undo_entries) - 1 - s:replace_undo_index
                    call s:ReplaceUndoOne(l:index)
                    let s:replace_undo_index += 1
                endwhile
                call s:ReplaceUndoFinish()
            endif
        endif
        return 1
    endif
    if s:replace_undo_stage ==# 'undo'
        if a:key ==# "\<Esc>" || a:key ==# "\<C-C>"
            call s:ReplaceUndoClose()
        endif
        return 1
    endif
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# "\<CR>"
        call s:ReplaceUndoClose()
    endif
    return 1
endfunction

" Purpose: Persist committed journals and remove incomplete pending backups on exit.
function! s:ReplaceUndoCleanup() abort
    " Committed batch journals are intentionally retained across Vim restarts.
    call s:ReplaceUndoPersist()
    if !empty(s:replace_undo_pending_dir)
        call delete(s:replace_undo_pending_dir, 'rf')
    endif
    let s:replace_undo_pending_dir = ''
    let s:replace_undo_pending_generation = -1
endfunction

" Purpose: List persisted replacement batches and allow choosing an older batch to undo.
function! s:ReplaceHistoryClose() abort
    if s:replace_history_popup > 0 && !empty(popup_getpos(s:replace_history_popup))
        call popup_close(s:replace_history_popup)
    endif
    let s:replace_history_popup = -1
endfunction

function! s:ReplaceHistoryRender() abort
    if s:replace_history_popup <= 0 || empty(popup_getpos(s:replace_history_popup))
        return
    endif
    let l:lines = [' Replacement history', repeat('-', 64), ' Enter: select batch | Esc/q: close']
    if empty(s:replace_history_items)
        call add(l:lines, ' No replacement history found')
    else
        for l:i in range(0, len(s:replace_history_items) - 1)
            let l:item = s:replace_history_items[l:i]
            let l:prefix = l:i == s:replace_history_selected ? '> ' : '  '
            call add(l:lines, l:prefix . l:item.created . ' | ' . len(l:item.entries) . ' files | ' . s:ReplaceClip(l:item.find . ' -> ' . l:item.replacement, 48))
        endfor
    endif
    call popup_settext(s:replace_history_popup, l:lines)
    call popup_setoptions(s:replace_history_popup, {'maxheight': min([len(l:lines), max([8, &lines - 6])])})
endfunction

function! s:ReplaceHistoryHandleKey(id, key) abort
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'q'
        call s:ReplaceHistoryClose()
    elseif a:key ==# "\<Up>" || a:key ==# 'k'
        let s:replace_history_selected = max([0, s:replace_history_selected - 1])
        call s:ReplaceHistoryRender()
    elseif a:key ==# "\<Down>" || a:key ==# 'j'
        let s:replace_history_selected = min([max([0, len(s:replace_history_items) - 1]), s:replace_history_selected + 1])
        call s:ReplaceHistoryRender()
    elseif a:key ==# "\<CR>" && !empty(s:replace_history_items)
        let l:item = s:replace_history_items[s:replace_history_selected]
        call s:ReplaceHistoryClose()
        if s:ReplaceUndoLoad(l:item.directory)
            call VimFileReplaceUndo()
        else
            echohl WarningMsg | echomsg 'Selected replacement journal is unavailable or empty' | echohl None
        endif
    endif
    return 1
endfunction

function! VimFileReplaceHistory() abort
    let s:replace_history_items = []
    let l:root = s:ReplaceUndoRoot()
    if empty(l:root)
        echoerr 'VimFileReplaceHistory: cannot access undo directory'
        return
    endif
    let l:dirs = glob(l:root . '/batch-*', 0, 1)
    call sort(l:dirs, {a, b -> getftime(s:ReplaceUndoManifestPath(b)) - getftime(s:ReplaceUndoManifestPath(a))})
    for l:dir in l:dirs
        let l:path = s:ReplaceUndoManifestPath(l:dir)
        if !filereadable(l:path)
            continue
        endif
        try
            let l:data = json_decode(join(readfile(l:path), "\n"))
            call add(s:replace_history_items, {'directory': l:dir, 'created': get(l:data, 'created', ''), 'find': get(l:data, 'find', ''), 'replacement': get(l:data, 'replacement', ''), 'entries': get(l:data, 'entries', [])})
        catch
        endtry
    endfor
    let s:replace_history_selected = 0
    call s:ApplyPopupHighlights()
    call s:ReplaceHistoryClose()
    let s:replace_history_popup = popup_create([' Replacement history '], {
                \ 'pos': 'center', 'minwidth': min([100, &columns - 8]), 'maxwidth': min([100, &columns - 8]),
                \ 'minheight': 6, 'maxheight': max([8, &lines - 6]),
                \ 'border': [1, 1, 1, 1], 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'], 'padding': [0, 1, 0, 1],
                \ 'title': ' Replacement History ', 'mapping': 0,
                \ 'filter': function('s:ReplaceHistoryHandleKey'), 'wrap': 0,
                \ 'highlight': 'VimFileSearchPopup'})
    call s:ReplaceHistoryRender()
endfunction

" Public command entry point: ask before restoring the latest safe replacement batch.
function! VimFileReplaceUndo() abort
    if s:replace_popup != -1 && s:replace_stage !=# 'done'
        echohl WarningMsg
        echomsg 'VimFileReplaceUndo: finish or cancel the active replacement first'
        echohl None
        return
    endif
    if s:replace_popup != -1
        call s:ReplacePopupClose()
    endif
    if s:replace_undo_popup != -1
        return
    endif
    if empty(s:replace_undo_entries)
        echo 'VimFileReplaceUndo: no persistent replacement undo batch is available'
        return
    endif
    let s:replace_undo_stage = 'confirm'
    let s:replace_undo_width = max([56, min([88, &columns - 8])])
    call s:ApplyPopupHighlights()
    let s:replace_undo_popup = popup_create([' Undo replacement '], {
                \ 'pos': 'center',
                \ 'minwidth': s:replace_undo_width,
                \ 'maxwidth': s:replace_undo_width,
                \ 'minheight': 8,
                \ 'maxheight': min([16, &lines - 6]),
                \ 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'],
                \ 'padding': [0, 1, 0, 1],
                \ 'title': ' Undo Search & Replace ',
                \ 'mapping': 0,
                \ 'filter': function('s:ReplaceUndoHandleKey'),
                \ 'wrap': 0,
                \ 'highlight': 'VimFileSearchPopup'
                \ })
    call s:ReplaceUndoRender()
endfunction

" Purpose: Public entry point that indexes with Git ignores respected and opens regex replacement.
function! VimFileReplace() abort
    call s:Close()
    call s:ReplacePopupClose()
    " Replacement retains its documented safe default regardless of the
    " interactive search popup's temporary F6 Git-ignore toggle.
    let s:respect_gitignore = 1
    let s:index_purpose = 'replace'
    let l:index_state = s:PrepareAsyncIndex(1)
    if l:index_state == 0
        call s:IndexFiles(1)
    endif

    let s:replace_find = ''
    let s:replace_with = ''
    let s:replace_active_field = 'find'
    let s:replace_stage = l:index_state == 1 ? 'indexing' : 'input'
    let s:replace_matches = []
    let s:replace_paths = []
    let s:replace_index = 0
    let s:replace_total_count = 0
    let s:replace_skipped_modified = 0
    let s:replace_skipped_binary = 0
    let s:replace_skipped_large = 0
    let s:replace_warning = l:index_state == 1 ? '' : s:index_warning
    let s:replace_error = ''
    let s:replace_cache_path = ''
    let s:replace_cache_lines = []
    let s:replace_cache_original_lines = []
    let s:replace_cache_dirty = 0
    let s:replace_plan_timer = -1
    let s:replace_plan_index = 0
    let s:replace_plan_total = 0
    let s:replace_plan_files = []
    let s:replace_plan_examples = []
    let s:replace_plan_matches = 0
    let s:replace_line_deltas = {}
    let s:replace_files_changed = 0
    let s:replace_changed_count = 0
    let s:replace_execution = 'none'
    let s:replace_scan_timer = -1
    let s:replace_bulk_timer = -1
    let s:replace_bulk_generation += 1
    let s:replace_scan_index = 0
    let s:replace_scan_total_paths = 0
    let s:replace_buffer_map_ready = 0
    let s:replace_width = max([60, min([108, &columns - 8])])
    let l:height = min([14, max([8, &lines - 6])])

    call s:ApplyPopupHighlights()
    let s:replace_popup = popup_create([' Vim Regex Search & Replace '], {
                \ 'pos': 'center',
                \ 'minwidth': s:replace_width - 8,
                \ 'maxwidth': s:replace_width - 8,
                \ 'minheight': 8,
                \ 'maxheight': l:height,
                \ 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'],
                \ 'padding': [0, 1, 0, 1],
                \ 'title': ' Vim Search & Replace ',
                \ 'mapping': 0,
                \ 'filter': function('s:ReplaceHandleKey'),
                \ 'wrap': 0,
                \ 'scrollbar': 0,
                \ 'highlight': 'VimFileSearchPopup'
                \ })
    call s:ReplaceRender()
    if l:index_state == 1
        call s:StartAsyncIndex()
    endif
endfunction

" -------------------------------------------------------------------------
" Per-tab buffer list popup (<leader>b).
" Vim buffers are global objects, so the plugin keeps a separate membership
" list and cursor position map in each tab page's variables.
" -------------------------------------------------------------------------
" Purpose: Return the current tab page's logical buffer membership list.
function! s:TabBuffers(tabnr) abort
    return gettabvar(a:tabnr, 'vfs_tab_buffers', [])
endfunction

" Purpose: Return the current tab page's saved buffer cursor positions.
function! s:TabBufferPositions(tabnr) abort
    return gettabvar(a:tabnr, 'vfs_tab_buffer_positions', {})
endfunction

" Purpose: Store the logical buffer list in a tab-local variable.
function! s:SetTabBuffers(tabnr, buffers) abort
    call settabvar(a:tabnr, 'vfs_tab_buffers', a:buffers)
endfunction

" Purpose: Store the cursor-position dictionary in a tab-local variable.
function! s:SetTabBufferPositions(tabnr, positions) abort
    call settabvar(a:tabnr, 'vfs_tab_buffer_positions', a:positions)
endfunction

" Purpose: Save the current normal file buffer line and column for this tab.
function! s:SaveBufferPosition() abort
    if &buftype !=# '' || !bufexists(bufnr('%'))
        return
    endif
    let l:tab = tabpagenr()
    let l:positions = s:TabBufferPositions(l:tab)
    let l:positions[string(bufnr('%'))] = [line('.'), col('.')]
    call s:SetTabBufferPositions(l:tab, l:positions)
endfunction

" Purpose: Maintain current-tab membership and optionally restore the buffer cursor position.
function! s:TrackCurrentBuffer(restore_position) abort
    if &buftype !=# '' || !bufexists(bufnr('%'))
        return
    endif

    let l:tab = tabpagenr()
    let l:buf = bufnr('%')
    let l:list = s:TabBuffers(l:tab)
    let l:clean = []
    for l:item in l:list
        if type(l:item) == type(0) && bufexists(l:item) && index(l:clean, l:item) < 0
            call add(l:clean, l:item)
        endif
    endfor
    if index(l:clean, l:buf) < 0
        call add(l:clean, l:buf)
    endif
    call s:SetTabBuffers(l:tab, l:clean)

    if a:restore_position
        let l:positions = s:TabBufferPositions(l:tab)
        let l:key = string(l:buf)
        if has_key(l:positions, l:key) && type(l:positions[l:key]) == type([])
                    \ && len(l:positions[l:key]) >= 2
            let l:line = max([1, min([line('$'), l:positions[l:key][0]])])
            let l:col = max([1, l:positions[l:key][1]])
            call cursor(l:line, l:col)
        endif
    endif
endfunction

" Purpose: Remove a deleted/wiped buffer from all tab membership and position records.
function! s:ForgetWipedBuffer(bufnr) abort
    if has_key(s:buffer_marked, string(a:bufnr)) | call remove(s:buffer_marked, string(a:bufnr)) | endif
    let l:key = string(a:bufnr)
    for l:tab in range(1, tabpagenr('$'))
        let l:list = s:TabBuffers(l:tab)
        let l:new_list = []
        for l:item in l:list
            if l:item != a:bufnr && bufexists(l:item)
                call add(l:new_list, l:item)
            endif
        endfor
        call s:SetTabBuffers(l:tab, l:new_list)
        let l:positions = s:TabBufferPositions(l:tab)
        if has_key(l:positions, l:key)
            call remove(l:positions, l:key)
            call s:SetTabBufferPositions(l:tab, l:positions)
        endif
    endfor
endfunction

" Purpose: Count windows in one tab that currently display a given buffer.
function! s:BufferVisibleCount(bufnr, tabnr) abort
    let l:count = 0
    for l:win in getwininfo()
        if get(l:win, 'bufnr', -1) == a:bufnr && get(l:win, 'tabnr', -1) == a:tabnr
            let l:count += 1
        endif
    endfor
    return l:count
endfunction

" Purpose: Check if a buffer is displayed in any window in the current Vim session.
function! s:BufferVisibleAnywhere(bufnr) abort
    for l:win in getwininfo()
        if get(l:win, 'bufnr', -1) == a:bufnr
            return 1
        endif
    endfor
    return 0
endfunction

" Purpose: Check whether another tab page still tracks the target buffer.
function! s:BufferTrackedInOtherTab(bufnr, current_tab) abort
    for l:tab in range(1, tabpagenr('$'))
        if l:tab != a:current_tab && index(s:TabBuffers(l:tab), a:bufnr) >= 0
            return 1
        endif
    endfor
    return 0
endfunction

" Purpose: Close the buffer manager popup safely.
function! s:BufferPopupClose() abort
    if s:buffer_popup != -1
        if !empty(popup_getpos(s:buffer_popup))
            call popup_close(s:buffer_popup)
        endif
        let s:buffer_popup = -1
    endif
endfunction

" Purpose: Build one display row with name, saved cursor, modified marker, and current marker.
function! s:BufferLabel(bufnr) abort
    let l:name = bufname(a:bufnr)
    if empty(l:name)
        let l:name = '[No Name #' . a:bufnr . ']'
    else
        let l:name = fnamemodify(l:name, ':~:.')
    endif
    let l:positions = s:TabBufferPositions(tabpagenr())
    let l:key = string(a:bufnr)
    let l:pos = get(l:positions, l:key, [1, 1])
    let l:mark = getbufvar(a:bufnr, '&modified') ? '[+]' : '[ ]'
    let l:current = a:bufnr == bufnr('%') ? ' * ' : '   '
    let l:marked = has_key(s:buffer_marked, string(a:bufnr)) ? '[x] ' : '[ ] '
    let l:label = l:current . l:marked . l:mark . ' ' . l:name . '  [' . l:pos[0] . ':' . l:pos[1] . ']'
    let l:maxchars = max([8, s:buffer_popup_width - 8])
    if strdisplaywidth(l:label) > l:maxchars
        let l:label = strcharpart(l:label, 0, max([1, l:maxchars - 1])) . '~'
    endif
    return l:label
endfunction

" Purpose: Reconcile and render the current tab page buffer list.
function! s:BufferRender() abort
    if s:buffer_popup == -1 || empty(popup_getpos(s:buffer_popup))
        return
    endif

    let l:tab = tabpagenr()
    let l:list = s:TabBuffers(l:tab)
    let l:clean = []
    for l:item in l:list
        if type(l:item) == type(0) && bufexists(l:item) && index(l:clean, l:item) < 0
            call add(l:clean, l:item)
        endif
    endfor
    if len(l:clean) != len(l:list)
        call s:SetTabBuffers(l:tab, l:clean)
    endif
    let s:buffer_items = l:clean
    let s:buffer_visible_items = []
    for l:buf in s:buffer_items
        let l:name = bufname(l:buf)
        let l:subject = tolower(empty(l:name) ? '[no name]' : fnamemodify(l:name, ':~:.'))
        if empty(s:buffer_filter) || stridx(l:subject, tolower(s:buffer_filter)) >= 0
            call add(s:buffer_visible_items, l:buf)
        endif
    endfor
    if empty(s:buffer_visible_items)
        let s:buffer_selected = 0
    else
        let s:buffer_selected = max([0, min([s:buffer_selected, len(s:buffer_visible_items) - 1])])
    endif

    let l:height = min([max([7, g:file_search_max_height]), max([7, &lines - 6])])
    let l:visible = max([1, l:height - 5])
    let l:offset = max([0, min([
                \ s:buffer_selected - float2nr(l:visible / 2),
                \ len(s:buffer_visible_items) - l:visible])])
    let l:marked_count = len(keys(s:buffer_marked))
    let l:lines = [
                \ ' Buffers in tab ' . l:tab . (empty(s:buffer_filter) ? '' : ' | filter: ' . s:buffer_filter),
                \ ' Enter: switch | /: filter | Space: mark | X: close marked',
                \ ' d: close | c: copy path | Up/Down or j/k: move | Esc: close',
                \ repeat('-', min([54, s:buffer_popup_width - 6]))]

    if empty(s:buffer_visible_items)
        call add(l:lines, empty(s:buffer_filter) ? ' No buffers in this tab' : ' No buffers match filter')
    else
        let l:last = min([len(s:buffer_visible_items) - 1, l:offset + l:visible - 1])
        for l:i in range(l:offset, l:last)
            let l:prefix = l:i == s:buffer_selected ? '>' : ' '
            call add(l:lines, l:prefix . s:BufferLabel(s:buffer_visible_items[l:i]))
        endfor
    endif
    call add(l:lines, ' Marked: ' . l:marked_count . (empty(s:buffer_status) ? '' : ' | ' . s:buffer_status))
    call popup_setoptions(s:buffer_popup, {'maxheight': min([len(l:lines), l:height])})
    call popup_settext(s:buffer_popup, l:lines)
endfunction

" Purpose: Switch to the selected buffer and restore its saved position.
function! s:BufferSwitchSelected() abort
    if empty(s:buffer_visible_items) || s:buffer_selected < 0 || s:buffer_selected >= len(s:buffer_visible_items)
        return
    endif
    let l:target = s:buffer_visible_items[s:buffer_selected]
    if !bufexists(l:target)
        let s:buffer_status = 'Buffer no longer exists'
        call s:BufferRender()
        return
    endif
    if l:target != bufnr('%') && getbufvar(bufnr('%'), '&modified') && !&hidden
        let s:buffer_status = 'Current buffer has unsaved changes; write it first'
        call s:BufferRender()
        return
    endif

    call s:SaveBufferPosition()
    let l:positions = s:TabBufferPositions(tabpagenr())
    let l:pos = get(l:positions, string(l:target), [])
    call s:BufferPopupClose()
    try
        execute 'buffer ' . l:target
        if len(l:pos) >= 2
            call cursor(max([1, min([line('$'), l:pos[0]])]), max([1, l:pos[1]]))
        endif
    catch
        echohl WarningMsg
        echomsg 'FileBuffers: ' . v:exception
        echohl None
    endtry
endfunction

" Purpose: Close/remove a selected buffer only when unsaved/visibility safeguards allow it.
function! s:BufferCloseSelected() abort
    if empty(s:buffer_visible_items) || s:buffer_selected < 0 || s:buffer_selected >= len(s:buffer_visible_items)
        return
    endif

    let l:target = s:buffer_visible_items[s:buffer_selected]
    let l:tab = tabpagenr()
    if !bufexists(l:target)
        let s:buffer_status = 'Buffer no longer exists'
        call s:BufferRender()
        return
    endif
    if getbufvar(l:target, '&modified')
        let s:buffer_status = 'Unsaved buffer: write it before closing'
        call s:BufferRender()
        return
    endif
    let l:visible_here = s:BufferVisibleCount(l:target, l:tab)
    if l:visible_here > 1 || (l:target != bufnr('%') && l:visible_here > 0)
        let s:buffer_status = 'Buffer is displayed in another window of this tab'
        call s:BufferRender()
        return
    endif

    if l:target == bufnr('%')
        let l:replacement = -1
        for l:item in s:buffer_items
            if l:item != l:target && bufexists(l:item)
                let l:replacement = l:item
                break
            endif
        endfor
        try
            if l:replacement > 0
                execute 'buffer ' . l:replacement
            else
                enew
            endif
        catch
            let s:buffer_status = 'Cannot close current buffer: ' . v:exception
            call s:BufferRender()
            return
        endtry
    endif

    let l:list = s:TabBuffers(l:tab)
    let l:new_list = []
    for l:item in l:list
        if l:item != l:target && bufexists(l:item)
            call add(l:new_list, l:item)
        endif
    endfor
    call s:SetTabBuffers(l:tab, l:new_list)
    let l:positions = s:TabBufferPositions(l:tab)
    if has_key(l:positions, string(l:target))
        call remove(l:positions, string(l:target))
        call s:SetTabBufferPositions(l:tab, l:positions)
    endif

    if !s:BufferVisibleAnywhere(l:target) && !s:BufferTrackedInOtherTab(l:target, l:tab)
        try
            execute 'bdelete ' . l:target
        catch
            let s:buffer_status = 'Removed from tab list; Vim kept the buffer'
            call s:BufferRender()
            return
        endtry
        let s:buffer_status = 'Closed buffer'
    else
        let s:buffer_status = 'Removed from this tab; buffer is still used elsewhere'
    endif

    let l:new_len = len(s:TabBuffers(l:tab))
    if l:new_len == 0
        let s:buffer_selected = 0
    else
        let s:buffer_selected = min([s:buffer_selected, l:new_len - 1])
    endif
    call s:BufferRender()
endfunction

" Purpose: Mark/unmark the currently selected buffer for a batch close.
function! s:BufferToggleMark() abort
    if empty(s:buffer_visible_items)
        return
    endif
    let l:buf = s:buffer_visible_items[s:buffer_selected]
    let l:key = string(l:buf)
    if has_key(s:buffer_marked, l:key)
        call remove(s:buffer_marked, l:key)
    else
        let s:buffer_marked[l:key] = 1
    endif
    call s:BufferRender()
endfunction

" Purpose: Safely close every marked buffer; conflicts remain marked and visible.
function! s:BufferCloseMarked() abort
    let l:targets = []
    for l:key in keys(s:buffer_marked)
        let l:buf = str2nr(l:key)
        if bufexists(l:buf)
            call add(l:targets, l:buf)
        endif
    endfor
    if empty(l:targets)
        let s:buffer_status = 'No buffers marked'
        call s:BufferRender()
        return
    endif
    let s:buffer_filter = ''
    for l:buf in l:targets
        call s:BufferRender()
        let l:index = index(s:buffer_visible_items, l:buf)
        if l:index >= 0
            let s:buffer_selected = l:index
            call s:BufferCloseSelected()
        endif
    endfor
    let s:buffer_status = 'Batch close finished; blocked buffers remain marked'
    call s:BufferRender()
endfunction

" Purpose: Copy the selected buffer's absolute path to Vim's unnamed register.
function! s:BufferCopySelectedPath() abort
    if empty(s:buffer_visible_items)
        return
    endif
    let l:buf = s:buffer_visible_items[s:buffer_selected]
    let l:name = bufname(l:buf)
    if empty(l:name) || getbufvar(l:buf, '&buftype') !=# ''
        let s:buffer_status = 'Selected buffer has no filesystem path'
        call s:BufferRender()
        return
    endif
    let l:path = simplify(fnamemodify(l:name, ':p'))
    call setreg('"', l:path)
    let s:buffer_status = 'Path copied to unnamed register'
    call s:BufferRender()
endfunction

" Purpose: Dispatch keyboard input for the buffer manager popup.
function! s:BufferHandleKey(id, key) abort
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'q'
        if s:buffer_filter_active
            let s:buffer_filter_active = 0
            call s:BufferRender()
        else
            call s:BufferPopupClose()
        endif
        return 1
    endif
    if a:key ==# '/' 
        let s:buffer_filter_active = 1
        let s:buffer_filter = ''
        call s:BufferRender()
        return 1
    endif
    if s:buffer_filter_active
        if a:key ==# "\<CR>"
            let s:buffer_filter_active = 0
            call s:BufferRender()
        elseif a:key ==# "\<BS>" || a:key ==# "\<C-H>"
            let s:buffer_filter = strcharpart(s:buffer_filter, 0, max([0, strchars(s:buffer_filter) - 1]))
            call s:BufferRender()
        elseif a:key ==# "\<C-U>"
            let s:buffer_filter = ''
            call s:BufferRender()
        elseif strchars(a:key) == 1 && char2nr(a:key) >= 32 && char2nr(a:key) != 127
            let s:buffer_filter .= a:key
            call s:BufferRender()
        endif
        return 1
    endif
    if a:key ==# "\<CR>"
        call s:BufferSwitchSelected()
        return 1
    endif
    if a:key ==# 'd' || a:key ==# 'x' || a:key ==# "\<Del>"
        call s:BufferCloseSelected()
        return 1
    endif
    if a:key ==# ' ' 
        call s:BufferToggleMark()
        return 1
    endif
    if a:key ==# 'X'
        call s:BufferCloseMarked()
        return 1
    endif
    if a:key ==# 'c'
        call s:BufferCopySelectedPath()
        return 1
    endif
    if a:key ==# "\<Down>" || a:key ==# 'j' || a:key ==# "\<C-N>"
        if !empty(s:buffer_visible_items)
            let s:buffer_selected = min([s:buffer_selected + 1, len(s:buffer_visible_items) - 1])
            let s:buffer_status = ''
            call s:BufferRender()
        endif
        return 1
    endif
    if a:key ==# "\<Up>" || a:key ==# 'k' || a:key ==# "\<C-P>"
        if !empty(s:buffer_visible_items)
            let s:buffer_selected = max([s:buffer_selected - 1, 0])
            let s:buffer_status = ''
            call s:BufferRender()
        endif
        return 1
    endif
    if a:key ==# "\<PageDown>"
        let s:buffer_selected = min([s:buffer_selected + max([1, g:file_search_max_height - 4]), len(s:buffer_visible_items) - 1])
        call s:BufferRender()
        return 1
    endif
    if a:key ==# "\<PageUp>"
        let s:buffer_selected = max([s:buffer_selected - max([1, g:file_search_max_height - 4]), 0])
        call s:BufferRender()
        return 1
    endif
    return 1
endfunction

" Purpose: Public entry point that opens the current tab page buffer manager.
function! VimFileBuffers() abort
    call s:Close()
    call s:ReplacePopupClose()
    call s:SaveBufferPosition()
    call s:TrackCurrentBuffer(0)
    let s:buffer_status = ''
    let s:buffer_filter = ''
    let s:buffer_filter_active = 0
    let s:buffer_marked = {}
    let s:buffer_items = s:TabBuffers(tabpagenr())
    let s:buffer_selected = max([0, index(s:buffer_items, bufnr('%'))])
    let s:buffer_popup_width = max([30, min([100, &columns - 8])])
    let l:height = min([max([7, g:file_search_max_height]), max([7, &lines - 6])])

    call s:ApplyPopupHighlights()
    let s:buffer_popup = popup_create([' Buffers '], {
                \ 'pos': 'center',
                \ 'minwidth': s:buffer_popup_width,
                \ 'maxwidth': s:buffer_popup_width,
                \ 'minheight': 6,
                \ 'maxheight': l:height,
                \ 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'],
                \ 'padding': [0, 1, 0, 1],
                \ 'title': ' Vim Buffers ',
                \ 'mapping': 0,
                \ 'filter': function('s:BufferHandleKey'),
                \ 'wrap': 0,
                \ 'scrollbar': 1,
                \ 'highlight': 'VimFileSearchPopup'
                \ })
    call s:BufferRender()
endfunction

" -------------------------------------------------------------------------
" Tab creation and tab-page list.
" :FileTab [directory] [display name] creates a tab and scopes the directory
" with :tcd. :FileTabs opens a popup for switching among all tab pages.
" -------------------------------------------------------------------------
" Purpose: Parse :FileTab arguments; quoted/escaped whitespace stays in one token.
function! s:ParseTabCommandArgs(raw) abort
    let l:tokens = []
    let l:token = ''
    let l:quote = ''
    let l:started = 0
    let l:chars = split(a:raw, '\zs')
    let l:i = 0

    while l:i < len(l:chars)
        let l:char = l:chars[l:i]
        if !empty(l:quote)
            if l:char ==# l:quote
                let l:quote = ''
            elseif l:char ==# '\' && l:quote ==# '"' && l:i + 1 < len(l:chars)
                let l:i += 1
                let l:token .= l:chars[l:i]
            else
                let l:token .= l:char
            endif
            let l:started = 1
        elseif l:char ==# '"' || l:char ==# "'"
            let l:quote = l:char
            let l:started = 1
        elseif l:char =~# '\s'
            if l:started
                call add(l:tokens, l:token)
                let l:token = ''
                let l:started = 0
            endif
        elseif l:char ==# '\' && l:i + 1 < len(l:chars)
                    \ && (l:chars[l:i + 1] =~# '\s' || l:chars[l:i + 1] ==# '"'
                    \ || l:chars[l:i + 1] ==# "'")
            let l:i += 1
            let l:token .= l:chars[l:i]
            let l:started = 1
        else
            let l:token .= l:char
            let l:started = 1
        endif
        let l:i += 1
    endwhile

    if !empty(l:quote)
        throw 'FileTab: unmatched quote in arguments'
    endif
    if l:started
        call add(l:tokens, l:token)
    endif

    return {
                \ 'path': empty(l:tokens) ? '' : l:tokens[0],
                \ 'name': len(l:tokens) > 1 ? join(l:tokens[1:], ' ') : ''
                \ }
endfunction

" Purpose: Adapt :FileTab's raw Ex arguments to VimFileTabCreate().
function! s:CreateTabFromCommand(raw) abort
    try
        let l:args = s:ParseTabCommandArgs(a:raw)
        return VimFileTabCreate(l:args.path, l:args.name)
    catch
        echohl WarningMsg
        echomsg v:exception
        echohl None
        return -1
    endtry
endfunction

" Purpose: Return the effective working directory of the active window in a tab.
function! s:TabDirectory(tabnr) abort
    try
        let l:window = tabpagewinnr(a:tabnr)
        return getcwd(l:window, a:tabnr)
    catch
        return ''
    endtry
endfunction

" Purpose: Resolve a tab's custom display name or a meaningful default title.
function! s:TabDisplayName(tabnr) abort
    let l:custom = gettabvar(a:tabnr, 'vfs_tab_name', '')
    if type(l:custom) == type('') && !empty(l:custom)
        return l:custom
    endif

    let l:buffers = tabpagebuflist(a:tabnr)
    let l:window = tabpagewinnr(a:tabnr)
    if !empty(l:buffers) && l:window >= 1 && l:window <= len(l:buffers)
        let l:buffer_name = bufname(l:buffers[l:window - 1])
        if !empty(l:buffer_name)
            return fnamemodify(l:buffer_name, ':t')
        endif
    endif
    return '[No Name]'
endfunction

" Purpose: Return the current buffer's absolute path within a tab's own cwd.
function! s:TabCurrentPath(tabnr) abort
    let l:buffers = tabpagebuflist(a:tabnr)
    let l:window = tabpagewinnr(a:tabnr)
    let l:directory = s:TabDirectory(a:tabnr)
    if empty(l:directory)
        let l:directory = getcwd()
    endif

    let l:base = substitute(l:directory, '/\+$', '', '')
    if empty(l:base)
        let l:base = '/'
    endif
    let l:separator = l:base ==# '/' ? '' : '/'

    if empty(l:buffers) || l:window < 1 || l:window > len(l:buffers)
        return l:base . l:separator . '[No Name]'
    endif

    let l:buffer = l:buffers[l:window - 1]
    let l:name = bufname(l:buffer)
    if empty(l:name)
        return l:base . l:separator . '[No Name]'
    endif

    " Non-file buffers (terminal/help/quickfix, etc.) have no filesystem path.
    if getbufvar(l:buffer, '&buftype') !=# ''
        return l:name
    endif

    if l:name =~# '^/'
        return simplify(l:name)
    endif
    return simplify(l:base . l:separator . l:name)
endfunction

" Purpose: Clip a string to display cells, optionally keeping its rightmost part.
function! s:TabListClip(text, width, ...) abort
    if a:width <= 0
        return ''
    endif
    if strdisplaywidth(a:text) <= a:width
        return a:text
    endif

    let l:keep_right = a:0 ? a:1 : 0
    let l:result = a:text
    if l:keep_right
        while !empty(l:result)
                    \ && strdisplaywidth('…' . l:result) > a:width - 0
            let l:result = strcharpart(l:result, 1)
        endwhile
        return '…' . l:result
    endif

    while !empty(l:result)
                \ && strdisplaywidth(l:result . '…') > a:width
        let l:result = strcharpart(l:result, 0, strchars(l:result) - 1)
    endwhile
    return l:result . '…'
endfunction

" Purpose: Close the tab-list popup and reset its window ID.
function! s:TabListClose() abort
    if s:tab_popup > 0 && !empty(popup_getpos(s:tab_popup))
        call popup_close(s:tab_popup)
    endif
    let s:tab_popup = -1
endfunction

" Purpose: Render every Vim tab in two columns: custom name and full current path.
function! s:TabListRender() abort
    if s:tab_popup <= 0 || empty(popup_getpos(s:tab_popup))
        return
    endif

    let s:tab_items = range(1, tabpagenr('$'))
    let s:tab_selected = max([0, min([s:tab_selected, len(s:tab_items) - 1])])
    let l:height = min([max([7, g:file_search_max_height]), max([7, &lines - 6])])
    let l:visible = max([1, l:height - 4])
    let l:offset = max([0, min([
                \ s:tab_selected - float2nr(l:visible / 2),
                \ len(s:tab_items) - l:visible])])
    let l:inner_width = max([20, s:tab_popup_width - 4])
    let l:name_width = min([28, max([12, float2nr(l:inner_width * 0.34)])])
    let l:path_width = max([8, l:inner_width - l:name_width - 3])
    let l:header_name = s:TabListClip('TAB NAME', l:name_width)
    let l:header_path = s:TabListClip('PATH / FILE', l:path_width)
    let l:lines = [
                \ ' Vim tab pages: ' . len(s:tab_items),
                \ ' Enter: switch | r: rename | p: pin | d: close | x: close others | X: close right',
                \ (empty(s:tab_bulk_status) ? '' : ' ' . s:tab_bulk_status),
                \ ' ' . l:header_name . repeat(' ', max([0, l:name_width - strdisplaywidth(l:header_name)]))
                \ . ' | ' . l:header_path,
                \ repeat('-', l:inner_width)]

    if empty(s:tab_items)
        call add(l:lines, ' No tab pages')
    else
        let l:last = min([len(s:tab_items) - 1, l:offset + l:visible - 1])
        for l:i in range(l:offset, l:last)
            let l:tab = s:tab_items[l:i]
            let l:current = l:tab == tabpagenr() ? '*' : ' '
            let l:pinned = gettabvar(l:tab, 'vfs_tab_pinned', 0) ? 'P' : ' '
            let l:prefix = l:i == s:tab_selected ? '>' : ' '
            let l:name = s:TabDisplayName(l:tab)
            let l:name_text = printf('%s%s%s %2d %s', l:prefix, l:current, l:pinned, l:tab, l:name)
            let l:path_text = s:TabCurrentPath(l:tab)
            let l:name_text = s:TabListClip(l:name_text, l:name_width)
            let l:path_text = s:TabListClip(l:path_text, l:path_width, 1)
            let l:row = l:name_text
                        \ . repeat(' ', max([0, l:name_width - strdisplaywidth(l:name_text)]))
                        \ . ' | ' . l:path_text
            call add(l:lines, l:row)
        endfor
    endif

    call popup_setoptions(s:tab_popup, {'maxheight': min([len(l:lines), l:height])})
    call popup_settext(s:tab_popup, l:lines)
endfunction

" Purpose: Reopen the list and keep selection on a target tab or nearest row.
function! s:TabListReopen(target, ...) abort
    let l:status = s:tab_bulk_status
    call VimFileTabList()
    let s:tab_bulk_status = l:status
    let l:index = index(s:tab_items, a:target)
    if l:index < 0 && a:0
        let l:index = min([max([0, a:1]), len(s:tab_items) - 1])
    endif
    if l:index >= 0
        let s:tab_selected = l:index
        call s:TabListRender()
    endif
endfunction

" Purpose: Close the list and activate the selected tab page.
function! s:TabListSwitchSelected() abort
    if empty(s:tab_items) || s:tab_selected < 0 || s:tab_selected >= len(s:tab_items)
        return
    endif
    let l:target = s:tab_items[s:tab_selected]
    if l:target < 1 || l:target > tabpagenr('$')
        call s:TabListRender()
        return
    endif
    call s:SaveBufferPosition()
    call s:TabListClose()
    execute 'tabnext ' . l:target
endfunction

" Purpose: Prompt for a new display name; an empty response cancels the rename.
function! s:TabListRenameSelected() abort
    if empty(s:tab_items) || s:tab_selected < 0 || s:tab_selected >= len(s:tab_items)
        return
    endif

    let l:target = s:tab_items[s:tab_selected]
    if l:target < 1 || l:target > tabpagenr('$')
        call s:TabListRender()
        return
    endif
    let l:old_name = s:TabDisplayName(l:target)
    call s:TabListClose()

    try
        let l:new_name = trim(input('Rename tab ' . l:target . ' (empty cancels): ', l:old_name))
        if !empty(l:new_name) && l:target <= tabpagenr('$')
            call settabvar(l:target, 'vfs_tab_name', l:new_name)
        endif
    catch
        echohl WarningMsg
        echomsg 'FileTabs rename failed: ' . v:exception
        echohl None
    endtry

    if l:target <= tabpagenr('$')
        call s:TabListReopen(l:target)
    else
        call VimFileTabList()
    endif
endfunction

" Purpose: Close the selected tab safely; never force-close modified buffers.
function! s:TabListDeleteSelected() abort
    if empty(s:tab_items) || s:tab_selected < 0 || s:tab_selected >= len(s:tab_items)
        return
    endif

    let l:target = s:tab_items[s:tab_selected]
    let l:old_index = s:tab_selected
    if gettabvar(l:target, 'vfs_tab_pinned', 0)
        echohl WarningMsg | echomsg 'FileTabs: pinned tabs cannot be closed; press p to unpin first' | echohl None
        return
    endif
    if tabpagenr('$') <= 1
        echohl WarningMsg
        echomsg 'FileTabs: cannot close the last remaining tab'
        echohl None
        return
    endif
    if l:target < 1 || l:target > tabpagenr('$')
        call s:TabListRender()
        return
    endif

    call s:SaveBufferPosition()
    call s:TabListClose()
    try
        execute 'tabclose ' . l:target
        call s:TabListReopen(min([l:target, tabpagenr('$')]), l:old_index)
    catch
        echohl WarningMsg
        echomsg 'FileTabs: tab was not closed: ' . v:exception
        echohl None
        if l:target <= tabpagenr('$')
            call s:TabListReopen(l:target)
        else
            call VimFileTabList()
        endif
    endtry
endfunction

" Purpose: Toggle the selected tab's protected/pinned status.
function! s:TabListTogglePin() abort
    if empty(s:tab_items)
        return
    endif
    let l:tab = s:tab_items[s:tab_selected]
    let l:value = !gettabvar(l:tab, 'vfs_tab_pinned', 0)
    call settabvar(l:tab, 'vfs_tab_pinned', l:value)
    let s:tab_bulk_status = l:value ? 'Pinned tab ' . l:tab : 'Unpinned tab ' . l:tab
    call s:TabListRender()
endfunction

" Purpose: Move selected unpinned tab one place without crossing a pinned tab.
function! s:TabListMoveSelected(direction) abort
    if empty(s:tab_items)
        return
    endif
    let l:tab = s:tab_items[s:tab_selected]
    let l:neighbor = l:tab + (a:direction < 0 ? -1 : 1)
    if l:tab < 1 || l:neighbor < 1 || l:neighbor > tabpagenr('$')
        return
    endif
    if gettabvar(l:tab, 'vfs_tab_pinned', 0) || gettabvar(l:neighbor, 'vfs_tab_pinned', 0)
        let s:tab_bulk_status = 'Pinned tabs cannot be moved or crossed'
        call s:TabListRender()
        return
    endif
    call s:TabListClose()
    execute 'tabnext ' . l:tab
    " Move by one position: :tabmove N places the current tab after N.
    execute 'tabmove ' . (a:direction < 0 ? l:tab - 2 : l:tab + 1)
    let l:newtab = tabpagenr()
    call s:TabListReopen(l:newtab)
endfunction

" Purpose: Safely close all unpinned tabs except the selected one (or to its right).
function! s:TabListCloseBatch(mode) abort
    if empty(s:tab_items)
        return
    endif
    let l:target = s:tab_items[s:tab_selected]
    call s:TabListClose()
    execute 'tabnext ' . l:target
    let l:closed = 0
    let l:blocked = 0
    let l:n = tabpagenr('$')
    while l:n >= 1
        let l:current = tabpagenr()
        let l:eligible = a:mode ==# 'others' ? l:n != l:current : l:n > l:current
        if l:eligible && !gettabvar(l:n, 'vfs_tab_pinned', 0)
            try
                execute 'tabclose ' . l:n
                let l:closed += 1
            catch
                let l:blocked += 1
            endtry
        endif
        let l:n -= 1
    endwhile
    let s:tab_bulk_status = 'Closed ' . l:closed . ' tabs; protected/modified: ' . l:blocked
    call s:TabListReopen(tabpagenr())
endfunction

" Purpose: Navigate, rename, close or activate the tab-list popup.
function! s:TabListHandleKey(id, key) abort
    if a:key ==# "\<Esc>" || a:key ==# "\<C-C>" || a:key ==# 'q'
        call s:TabListClose()
        return 1
    endif
    if a:key ==# "\<CR>"
        call s:TabListSwitchSelected()
        return 1
    endif
    if a:key ==# 'r'
        call s:TabListRenameSelected()
        return 1
    endif
    if a:key ==# 'd'
        call s:TabListDeleteSelected()
        return 1
    endif
    if a:key ==# 'p'
        call s:TabListTogglePin()
        return 1
    endif
    if a:key ==# "\<S-Left>"
        call s:TabListMoveSelected(-1)
        return 1
    endif
    if a:key ==# "\<S-Right>"
        call s:TabListMoveSelected(1)
        return 1
    endif
    if a:key ==# 'x'
        call s:TabListCloseBatch('others')
        return 1
    endif
    if a:key ==# 'X'
        call s:TabListCloseBatch('right')
        return 1
    endif
    if a:key ==# "\<Down>" || a:key ==# 'j' || a:key ==# "\<C-N>"
        let s:tab_selected = min([s:tab_selected + 1, len(s:tab_items) - 1])
        call s:TabListRender()
        return 1
    endif
    if a:key ==# "\<Up>" || a:key ==# 'k' || a:key ==# "\<C-P>"
        let s:tab_selected = max([s:tab_selected - 1, 0])
        call s:TabListRender()
        return 1
    endif
    if a:key ==# "\<Home>" || a:key ==# 'g'
        let s:tab_selected = 0
        call s:TabListRender()
        return 1
    endif
    if a:key ==# "\<End>" || a:key ==# 'G'
        let s:tab_selected = max([0, len(s:tab_items) - 1])
        call s:TabListRender()
        return 1
    endif
    if a:key ==# "\<PageDown>"
        let s:tab_selected = min([s:tab_selected + max([1, g:file_search_max_height - 4]), len(s:tab_items) - 1])
        call s:TabListRender()
        return 1
    endif
    if a:key ==# "\<PageUp>"
        let s:tab_selected = max([s:tab_selected - max([1, g:file_search_max_height - 4]), 0])
        call s:TabListRender()
        return 1
    endif
    return 1
endfunction

" Purpose: Create a new tab with optional tab-local directory and display name.
" Arguments: [directory [, display_name]]. Empty arguments keep Vim defaults.
function! VimFileTabCreate(...) abort
    if a:0 > 2
        echohl WarningMsg
        echomsg 'VimFileTabCreate: expected [directory [, display_name]]'
        echohl None
        return -1
    endif

    let l:directory = ''
    if a:0 >= 1 && !empty(a:1)
        let l:directory = simplify(fnamemodify(a:1, ':p'))
        if !isdirectory(l:directory)
            echohl WarningMsg
            echomsg 'VimFileTabCreate: directory does not exist: ' . l:directory
            echohl None
            return -1
        endif
    endif
    let l:name = a:0 >= 2 ? trim(a:2) : ''

    call s:Close()
    call s:ReplacePopupClose()
    call s:BufferPopupClose()
    call s:TabListClose()
    call s:SaveBufferPosition()

    try
        tabnew
        if !empty(l:directory)
            execute 'tcd ' . fnameescape(l:directory)
        endif
        if !empty(l:name)
            let t:vfs_tab_name = l:name
        else
            unlet! t:vfs_tab_name
        endif
        call s:TrackCurrentBuffer(0)
        return tabpagenr()
    catch
        echohl ErrorMsg
        echomsg 'VimFileTabCreate: ' . v:exception
        echohl None
        return -1
    endtry
endfunction

" Purpose: Open a popup listing all Vim tab pages; Enter jumps to the selected tab.
function! VimFileTabList() abort
    let s:tab_bulk_status = ''
    call s:Close()
    call s:ReplacePopupClose()
    call s:BufferPopupClose()
    call s:TabListClose()
    call s:SaveBufferPosition()

    let s:tab_items = range(1, tabpagenr('$'))
    let s:tab_selected = max([0, index(s:tab_items, tabpagenr())])
    let s:tab_popup_width = max([30, min([110, &columns - 8])])
    let l:height = min([max([7, g:file_search_max_height]), max([7, &lines - 6])])

    call s:ApplyPopupHighlights()
    let s:tab_popup = popup_create([' Vim tab pages '], {
                \ 'pos': 'center',
                \ 'minwidth': s:tab_popup_width,
                \ 'maxwidth': s:tab_popup_width,
                \ 'minheight': 5,
                \ 'maxheight': l:height,
                \ 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'],
                \ 'padding': [0, 1, 0, 1],
                \ 'title': ' Vim Tabs ',
                \ 'mapping': 0,
                \ 'filter': function('s:TabListHandleKey'),
                \ 'wrap': 0,
                \ 'scrollbar': 1,
                \ 'highlight': 'VimFileSearchPopup'
                \ })
    call s:TabListRender()
    return s:tab_popup
endfunction

" -------------------------------------------------------------------------
" Workspace persistence (tab pages, cwd, per-tab buffer membership and cursors).
" Modified buffers must be written before saving so no unsaved text is implied.
" -------------------------------------------------------------------------
function! s:WorkspaceName(name) abort
    let l:name = empty(a:name) ? 'default' : a:name
    if l:name !~# '^[A-Za-z0-9._-]\+$' || l:name ==# '.' || l:name ==# '..'
        throw 'workspace name must contain only letters, digits, dot, underscore or dash'
    endif
    return l:name
endfunction

function! s:WorkspacePath(name) abort
    let l:dir = expand(g:file_search_workspace_dir)
    if !isdirectory(l:dir) && mkdir(l:dir, 'p', 0700) != 1 && !isdirectory(l:dir)
        throw 'cannot create workspace directory: ' . l:dir
    endif
    return simplify(fnamemodify(l:dir, ':p')) . '/' . s:WorkspaceName(a:name) . '.json'
endfunction

function! VimFileWorkspaceSave(...) abort
    try
        let l:name = s:WorkspaceName(a:0 ? a:1 : 'default')
    catch
        echohl ErrorMsg | echomsg 'VimFileWorkspaceSave: ' . v:exception | echohl None
        return 0
    endtry
    " Capture visible window positions even if the user has not left those buffers.
    for l:window in getwininfo()
        let l:tab = get(l:window, 'tabnr', 0)
        let l:buf = get(l:window, 'bufnr', 0)
        if l:tab > 0 && l:buf > 0
            let l:positions = s:TabBufferPositions(l:tab)
            let l:cursor = getcurpos(get(l:window, 'winid', 0))
            let l:positions[string(l:buf)] = [max([1, l:cursor[1]]), max([1, l:cursor[2]])]
            call s:SetTabBufferPositions(l:tab, l:positions)
        endif
    endfor
    let l:tabs = []
    for l:tab in range(1, tabpagenr('$'))
        let l:cwd = s:TabDirectory(l:tab)
        let l:bufs = gettabvar(l:tab, 'vfs_tab_buffers', tabpagebuflist(l:tab))
        let l:positions = gettabvar(l:tab, 'vfs_tab_buffer_positions', {})
        let l:entries = []
        let l:seen = {}
        let l:active = tabpagebuflist(l:tab)[tabpagewinnr(l:tab) - 1]
        let l:active_path = ''
        for l:buf in l:bufs + tabpagebuflist(l:tab)
            if !bufexists(l:buf) || has_key(l:seen, string(l:buf))
                continue
            endif
            let l:seen[string(l:buf)] = 1
            if getbufvar(l:buf, '&modified')
                echohl WarningMsg | echomsg 'Workspace not saved: write modified buffers first (' . bufname(l:buf) . ')' | echohl None
                return 0
            endif
            let l:path = bufname(l:buf)
            if empty(l:path) || getbufvar(l:buf, '&buftype') !=# ''
                continue
            endif
            let l:path = l:path =~# '^/' ? simplify(l:path) : simplify(l:cwd . '/' . l:path)
            let l:pos = get(l:positions, string(l:buf), [1, 1])
            call add(l:entries, {'path': l:path, 'line': get(l:pos, 0, 1), 'column': get(l:pos, 1, 1)})
            if l:buf == l:active
                let l:active_path = l:path
            endif
        endfor
        call add(l:tabs, {'cwd': l:cwd, 'name': gettabvar(l:tab, 'vfs_tab_name', ''),
                    \ 'pinned': gettabvar(l:tab, 'vfs_tab_pinned', 0),
                    \ 'buffers': l:entries, 'active': l:active_path})
    endfor
    let l:data = {'version': 1, 'name': l:name, 'saved': strftime('%Y-%m-%d %H:%M:%S'), 'tabs': l:tabs}
    try
        let l:path = s:WorkspacePath(l:name)
        let l:temp = l:path . '.tmp-' . getpid()
        if writefile([json_encode(l:data)], l:temp) != 0
            call delete(l:temp)
            throw 'cannot write workspace manifest'
        endif
        if exists('*setfperm') | call setfperm(l:temp, 'rw-------') | endif
        if rename(l:temp, l:path) != 0
            call delete(l:temp)
            throw 'cannot atomically save workspace manifest'
        endif
        echomsg 'Workspace saved: ' . l:name . ' (' . len(l:tabs) . ' tabs)'
        return 1
    catch
        echohl ErrorMsg | echomsg 'VimFileWorkspaceSave: ' . v:exception | echohl None
        return 0
    endtry
endfunction

function! VimFileWorkspaceLoad(...) abort
    try
        let l:name = s:WorkspaceName(a:0 ? a:1 : 'default')
        let l:path = s:WorkspacePath(l:name)
        if !filereadable(l:path)
            throw 'workspace does not exist: ' . l:name
        endif
        let l:data = json_decode(join(readfile(l:path), "\n"))
        if type(l:data) != type({}) || get(l:data, 'version', 0) != 1 || type(get(l:data, 'tabs', 0)) != type([])
            throw 'unsupported or invalid workspace format'
        endif
    catch
        echohl ErrorMsg | echomsg 'VimFileWorkspaceLoad: ' . v:exception | echohl None
        return 0
    endtry
    let l:original_tab = tabpagenr()
    let l:created = []
    let l:missing = 0
    for l:item in l:data.tabs
        if !isdirectory(get(l:item, 'cwd', ''))
            let l:missing += 1
            continue
        endif
        let l:newtab = -1
        try
            tabnew
            let l:newtab = tabpagenr()
            execute 'tcd ' . fnameescape(l:item.cwd)
            if !empty(get(l:item, 'name', '')) | let t:vfs_tab_name = l:item.name | endif
            let t:vfs_tab_pinned = !!get(l:item, 'pinned', 0)
            let l:bufs = []
            let l:positions = {}
            let l:active_buf = -1
            for l:entry in get(l:item, 'buffers', [])
                let l:file = get(l:entry, 'path', '')
                if empty(l:file) || !filereadable(l:file)
                    let l:missing += 1
                    continue
                endif
                let l:buf = bufadd(l:file)
                if l:buf <= 0
                    let l:missing += 1
                    continue
                endif
                call bufload(l:buf)
                call add(l:bufs, l:buf)
                let l:positions[string(l:buf)] = [max([1, get(l:entry, 'line', 1)]), max([1, get(l:entry, 'column', 1)])]
                if l:file ==# get(l:item, 'active', '') | let l:active_buf = l:buf | endif
            endfor
            call s:SetTabBuffers(l:newtab, l:bufs)
            call s:SetTabBufferPositions(l:newtab, l:positions)
            if l:active_buf > 0
                execute 'buffer ' . l:active_buf
                let l:pos = get(l:positions, string(l:active_buf), [1, 1])
                call cursor(min([line('$'), l:pos[0]]), l:pos[1])
            elseif !empty(l:bufs)
                execute 'buffer ' . l:bufs[0]
            else
                enew
            endif
            call add(l:created, l:newtab)
        catch
            let l:missing += 1
            " Do not leave a half-restored page behind after a malformed entry.
            if l:newtab > 0 && l:newtab <= tabpagenr('$') && tabpagenr('$') > 1
                try
                    execute 'tabnext ' . l:newtab
                    tabclose
                catch
                endtry
            endif
        endtry
    endfor
    if !empty(l:created)
        execute 'tabnext ' . l:created[0]
    else
        execute 'tabnext ' . l:original_tab
    endif
    echomsg 'Workspace loaded: ' . l:name . ' | tabs: ' . len(l:created) . ' | missing paths/tabs: ' . l:missing
    return len(l:created)
endfunction

function! VimFileWorkspaceList() abort
    let l:dir = expand(g:file_search_workspace_dir)
    let l:files = glob(l:dir . '/*.json', 0, 1)
    if empty(l:files)
        echomsg 'No saved Vim File Search workspaces'
        return []
    endif
    let l:names = map(l:files, 'fnamemodify(v:val, ":t:r")')
    echomsg 'Saved workspaces: ' . join(l:names, ', ')
    return l:names
endfunction

" -------------------------------------------------------------------------
" Diagnostics popup: build and show effective runtime capabilities/settings.
" -------------------------------------------------------------------------
let s:info_popup = -1
function! s:InfoClose() abort
    if s:info_popup > 0 && !empty(popup_getpos(s:info_popup)) | call popup_close(s:info_popup) | endif
    let s:info_popup = -1
endfunction
function! s:InfoHandleKey(id, key) abort
    if a:key ==# \"\<Esc>\" || a:key ==# 'q' || a:key ==# \"\<CR>\"
        call s:InfoClose()
    elseif a:key ==# \"\<Down>\" || a:key ==# 'j'
        call popup_scroll(s:info_popup, 1, 'line')
    elseif a:key ==# \"\<Up>\" || a:key ==# 'k'
        call popup_scroll(s:info_popup, -1, 'line')
    elseif a:key ==# \"\<PageDown>\"
        call popup_scroll(s:info_popup, 1, 'page')
    elseif a:key ==# \"\<PageUp>\"
        call popup_scroll(s:info_popup, -1, 'page')
    endif
    return 1
endfunction
function! VimFileSearchInfo() abort
    let l:lines = [' Vim File Search — runtime diagnostics', repeat('-', 66),
                \ 'Version: 2.3.0', 'Vim: ' . v:version . ' | ' . v:progpath,
                \ 'Platform: ' . (has('unix') ? 'Unix-like' : 'other'),
                \ 'Features: popupwin=' . has('popupwin') . ' job=' . has('job') . ' timers=' . has('timers') . ' multibyte=' . has('multi_byte'),
                \ 'Tools: git=' . executable('git') . ' rg=' . executable('rg') . ' awk=' . executable('awk') . ' sed=' . executable('sed'),
                \ 'Search: mode=' . s:search_mode . ' fuzzy=' . s:search_fuzzy . ' hidden=' . s:show_hidden . ' GitIgnore=' . s:respect_gitignore . ' candidates=' . len(s:search_files) . ' results=' . len(s:matches),
                \ 'Settings: hiddenDefault=' . g:file_search_show_hidden_default,
                \ 'Caches: index=' . len(keys(s:index_cache)) . '/4 preview=' . len(keys(s:preview_cache)) . '/64',
                \ 'Jobs: index=' . (!empty(s:index_job)) . ' search=' . len(s:search_jobs) . ' preview=' . (!empty(s:preview_job)),
                \ 'History: queries=' . len(s:search_history) . ' replacement batches=' . len(glob(s:ReplaceUndoRoot() . '/batch-*', 0, 1)),
                \ 'Settings: debounce=' . get(g:, 'file_search_debounce_ms', 300) . 'ms indexTTL=' . g:file_search_index_cache_seconds . 's previewTTL=' . g:file_search_preview_cache_seconds . 's',
                \ 'Settings: replaceMax=' . get(g:, 'file_search_replace_max_file_bytes', 8 * 1024 * 1024) . ' bytes undoHistory=' . g:file_search_undo_history_limit,
                \ 'Mappings enabled=' . g:file_search_map_keys . ' | background=' . &background,
                \ 'Data: ' . s:ReplaceDataDirectory(), 'Esc/q/Enter: close']
    call s:ApplyPopupHighlights()
    call s:InfoClose()
    let s:info_popup = popup_create(l:lines, {'pos': 'center', 'minwidth': max([58, min([104, &columns - 8])]),
                \ 'maxwidth': max([58, min([104, &columns - 8])]), 'minheight': 8,
                \ 'maxheight': max([8, &lines - 6]), 'border': [1, 1, 1, 1],
                \ 'borderchars': ['-', '|', '-', '|', '+', '+', '+', '+'],
                \ 'borderhighlight': ['VimFileSearchPopupBorder'], 'padding': [0, 1, 0, 1],
                \ 'title': ' Vim File Search Info ', 'mapping': 0,
                \ 'filter': function('s:InfoHandleKey'), 'wrap': 0, 'scrollbar': 1,
                \ 'highlight': 'VimFileSearchPopup'})
    return s:info_popup
endfunction

" Public Ex commands. These remain available when g:file_search_map_keys=0.
command! FileNames    call VimFileSearch(1, 'name')
command! FileNamesAll call VimFileSearch(0, 'name')
command! GrepFiles    call VimFileSearch(1, 'content')
command! GrepFilesAll call VimFileSearch(0, 'content')
command! VimFileReplace call VimFileReplace()
command! VimFileReplaceUndo call VimFileReplaceUndo()
command! VimFileReplaceHistory call VimFileReplaceHistory()
command! -nargs=? VimFileWorkspaceSave call VimFileWorkspaceSave(<q-args>)
command! -nargs=? VimFileWorkspaceLoad call VimFileWorkspaceLoad(<q-args>)
command! VimFileWorkspaceList call VimFileWorkspaceList()
command! VimFileSearchInfo call VimFileSearchInfo()

" Default Normal-mode mappings; set g:file_search_map_keys=0 to disable all.
if g:file_search_map_keys
    nnoremap <silent> <leader>f :GrepFiles<CR>
    nnoremap <silent> <leader>F :GrepFilesAll<CR>
    nnoremap <silent> <leader>g :FileNames<CR>
    nnoremap <silent> <leader>G :FileNamesAll<CR>
    nnoremap <silent> <leader>r :VimFileReplace<CR>
    nnoremap <silent> <leader>b :FileBuffers<CR>
    nnoremap <silent> <leader>t :FileTab<CR>
    nnoremap <silent> <leader>T :FileTabs<CR>
endif

command! FileBuffers call VimFileBuffers()
command! -nargs=* -complete=dir FileTab call <SID>CreateTabFromCommand(<q-args>)
command! FileTabs call VimFileTabList()
command! VimFileSearchClearCache call s:IndexCacheClear() | call s:CancelAsyncPreview() | call s:PreviewCacheClear() | echo 'Vim file-search caches cleared'

augroup VimFileSearchIndexCache
    autocmd!
    autocmd BufWritePost * call <SID>IndexCacheClear() | call <SID>CancelAsyncPreview() | call <SID>PreviewCacheClear()
augroup END

" Keep plugin-owned per-tab buffer membership and cursor positions in sync.
augroup VimFileSearchTabBuffers
    autocmd!
    autocmd BufLeave,WinLeave * call <SID>SaveBufferPosition()
    autocmd BufEnter * call <SID>TrackCurrentBuffer(1)
    autocmd BufDelete,BufWipeout * call <SID>ForgetWipedBuffer(str2nr(expand('<abuf>')))
augroup END

call s:TrackCurrentBuffer(0)

augroup VimFileSearchPopupTheme
    autocmd!
    autocmd ColorScheme * call <SID>ApplyPopupHighlights()
    autocmd OptionSet background call <SID>ApplyPopupHighlights(v:option_new)
augroup END

" Persist the replacement journal and remove only incomplete pending data.
augroup VimFileSearchUndoCleanup
    autocmd!
    autocmd VimLeavePre * call <SID>ReplaceUndoCleanup()
augroup END

" Load the newest committed replacement journal from the persistent data directory.
call s:ReplaceUndoLoadLatest()
