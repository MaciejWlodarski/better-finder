# BetterFinder

**A native macOS file manager with dual-pane browsing, indexed search, and disk analysis.**

BetterFinder brings everyday file operations and developer tools into one SwiftUI and AppKit app. Browse two folders side by side, find files with structured queries, inspect metadata, and explore what is taking up space without leaving the window.

[Get started](#get-started) · [Features](#features) · [Search syntax](#search-syntax) · [Keyboard shortcuts](#keyboard-shortcuts) · [Development](#development)

## Project status

BetterFinder is under active development. This README describes the code on `main`; fixes and improvements in [open pull requests](https://github.com/MaciejWlodarski/better-finder/pulls) are not part of `main` until merged. Check the relevant branch and its checks when evaluating a change.

The app's interface is currently mostly in Polish, with some English labels. This README is in English; it does not indicate that the app has been fully translated.

Use backups and disposable test files when trying destructive operations. See [Data, permissions, and safety](#data-permissions-and-safety) before working with important files.

## Get started

### Requirements

- **macOS 14 Sonoma or later.** The app uses macOS-only frameworks.
- **Apple Command Line Tools or Xcode**, with Swift and a macOS SDK available through `xcrun`. `Package.swift` declares Swift tools version **5.10**; this is not a guarantee that every compiler version from 5.10 onward has been tested.
- **Git** to clone the repository.

### Build and launch

```sh
git clone https://github.com/MaciejWlodarski/better-finder.git
cd better-finder
zsh ./build_app.sh
open BetterFinder.app
```

The build script compiles an optimized app for your Mac's current architecture, generates its icon, and applies a local ad-hoc code signature. It creates `BetterFinder.app` in the repository root. This is a local development build, not a notarized distribution build.

An existing app bundle is kept until compilation, icon generation, and signing succeed. The script uses a private temporary build directory and removes it when finished.

## Features

### Browse your way

- **Dual panes** for side-by-side browsing, folder comparison, and copying a selection to the other pane.
- **Four views:** list, icon grid, Miller columns, and a disk-usage treemap.
- **Tabs** with duplication, reopening closed tabs, and basic restoration of tab paths and the active tab.
- **Editable breadcrumbs** with support for `~` and relative paths.
- **Adjustable layout** with resizable panes, an optional sidebar and inspector, and system light and dark appearances.

### Find files and keep useful searches

- Search the **current folder**, its **subfolders**, or the **configured file index**.
- Combine names with extension, size, modification-time, path, file-type, tag-color, content, and Git-status filters.
- Use fuzzy matching, quoted phrases, exclusions, and regular expressions.
- Save queries as **smart folders** in the sidebar.
- The built-in engine uses bulk filesystem enumeration, an in-memory index, optional memory-mapped caching, and FSEvents updates. No separate search service is required for the built-in engine.

### Work with files

- Copy, cut, paste, duplicate, rename, create files and folders, and move items to Trash.
- Drag selections from the list or icon grid; hold **Option** to request a copy.
- Use conflict handling and in-memory undo/redo for supported file operations.
- Work with Finder tags, Open With, sharing, and archive creation or extraction.
- Inspect previews, metadata, POSIX permissions, and SHA-256 or MD5 checksums; use **Quick Look** for a larger preview.

### Explore folders and projects

- Visualize disk usage and inspect large files in the analysis view.
- Find duplicate candidates using file sizes and SHA-256 hashes. Review them before deleting anything.
- See Git-status information for files in a repository.
- Run shell commands in the active folder using the embedded command drawer. It invokes `zsh -c` and displays output; it is **not a full interactive terminal emulator**.

## Search syntax

Type a query into the search bar or open quick search with **⌘P**.

| Query | Purpose |
| --- | --- |
| `report ext:pdf` | Find PDFs matching “report” |
| `size:>10mb mtime:<7d` | Find files over 10 MiB modified within the last 7 days |
| `type:image` | Filter by image type |
| `in:Sources grep:TODO` | Look for TODO content in matching source paths |
| `git:modified` | Filter by recorded Git status |
| `"annual report" !draft` | Match a phrase and exclude a term |
| `!ext:log` | Exclude an extension |

Additional syntax includes `regex:`, `tag:`, `^prefix`, and `suffix$`. The Filters menu provides syntax help and removable filter chips.

**The index is not the entire disk.** Even where the UI calls it “Whole Disk (fsearch),” it covers configured roots, subject to exclusions, permissions, and search limits. Default roots include existing Desktop, Documents, Downloads, `dev`, `Projects`, and `Developer` folders in your home directory, plus `/Applications`. Review the indexing settings before relying on its coverage.

Content search and Git filters also have bounded coverage. A search result is not an exhaustive filesystem or repository audit.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | New tab / close the active tab or pane, or the last window |
| ⇧⌘T | Reopen a closed tab |
| ⌃Tab / ⇧⌃Tab | Next / previous tab |
| ⌘F / ⌘P | Focus search / open quick search |
| ⌘L / ⇧⌘G | Enter a folder path |
| ⌘[ / ⌘] / ⌘↑ | Back / forward / parent folder |
| ⌘↓ | Open the selected item |
| ⌘R | Refresh the folder and active search |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | List / icons / columns / disk analysis |
| ⌘A / ⇧↑ or ⇧↓ | Select all / extend the selection |
| Return | Rename the selected item |
| Space / ⌘Y | Toggle Quick Look |
| ⇧⌘N / ⌥⌘N | New folder / new file from a template |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste |
| ⌥⌘C / ⌘D | Copy paths / duplicate selection |
| ⌘Delete | Move the selection to Trash |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⇧⌘. | Toggle hidden files |
| ⌃⌘S / ⌘I | Toggle sidebar / inspector |
| ⇧⌘D | Toggle dual panes |
| Control + backtick | Toggle the command drawer |
| ⌘, | Open settings |

Text-editing commands act on the focused text field rather than the file selection. Selection and preview shortcuts apply when a file view, not a text field or modal, has focus.

## Data, permissions, and safety

- **Local state:** preferences, bookmarks, smart folders, and basic tab paths are stored locally through macOS preferences. The optional index cache stores filesystem metadata at `~/Library/Caches/BetterFinder/fsearch_index.bin`; the current implementation falls back to `/tmp/betterfinder_fsearch_index.bin` if that directory cannot be created. Paths and filenames may be sensitive.
- **Filesystem access:** browsing, indexing, and previews depend on your account's permissions and macOS privacy controls. Inaccessible locations may be missing from results. Grant access only to locations you intend the app to use.
- **Undo is not a backup:** operation history is held in memory, not a durable recovery journal. It does not survive an app restart or crash. Replacement handling attempts to preserve the previous item in Trash and roll back failures, but it is not a guarantee against data loss.
- **Cancellation is between files:** cancelling a multi-file transfer does not interrupt the file currently being processed. Emptying Trash is irreversible.
- **Commands and repositories require trust:** shell commands run with your user's access. The current Git integration invokes Git in browsed repositories and does not isolate repository-configured helpers. Use trusted repositories, and do not run unfamiliar commands.
- **Analysis is a guide:** scan limits, unreadable files, and concurrent filesystem changes can affect searches, size totals, comparisons, and duplicate results. Inspect the actual files before cleanup or replacement.

## Development

### Run regression checks

On a Mac with the build requirements installed:

```sh
zsh ./scripts/run_tests.sh
```

On `main`, this script compiles the model and engine sources with the regression runner, then runs a separate file-operation harness. The harness exercises replacement, rollback, history, clipboard ownership logic, and tag metadata. Replacement tests use a fixture-local substitute for Trash.

The runner on `main` does not isolate your home directory or preferences. Use a disposable macOS account when isolation matters.

Use the repository's runner rather than assuming `swift test` is equivalent: `Package.swift` currently declares an executable target, not a test target.

### Preview the native UI

From an active graphical macOS session:

```sh
zsh ./scripts/preview_app.sh
```

This builds a separate preview app, exercises keyboard interactions, and writes native view renders to `.build/previews`. Scenarios include list and search views, a narrow window, dual panes, the inspector, renaming, and dark-mode icons. These renders are not desktop screenshots or a substitute for full interactive UI validation.

Run the preview harness in a disposable macOS account or test environment. The version on `main` can read real user locations and write preferences; a separate app bundle does not make it isolated.

### Branch-specific validation

Test isolation, additional regression cases, and macOS CI are being developed in the open pull requests. Follow the scripts and checks on the branch you are testing. A successful check on a pull request does not establish that `main` passes the same suite, and automated checks do not replace interactive testing of Quick Look, permissions, filesystem events, or external volumes.

### Contributing

Keep changes focused and include reproduction steps for bugs. For a file-operation issue, describe the source and destination volumes, the operation, expected behavior, and actual result. Use disposable fixtures and redact private paths from logs.

Before proposing a change, review the [open pull requests](https://github.com/MaciejWlodarski/better-finder/pulls) to avoid duplicating ongoing work. Run the relevant regression checks and note your macOS version, Swift version, and any manual UI testing in the pull request.
