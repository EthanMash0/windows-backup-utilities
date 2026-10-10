# Folder size manual checklist

These checks need Windows. Run them with `run.bat` (an elevated Windows PowerShell 5.1 window) unless a step says otherwise.

Build the fixture first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\New-FolderSizeFixture.ps1
```

Remove it afterwards with the same command plus `-Remove`.

The fixture creates `C:\Temp\fs_fixture\src`, `bak`, `same_a`, `same_b`, and `readonly_logs`. The source and backup trees differ like this:

| Path under `src` / `bak` | Source | Backup |
|---|---|---|
| `docs\same.txt` | 10 bytes | 10 bytes |
| `docs\only-in-source.txt` | 20 bytes | missing |
| `docs\only-in-backup.txt` | missing | 30 bytes |
| `docs\different-size.txt` | 100 bytes | 200 bytes |
| `EmptyOnlyInSource\` | empty folder | missing |
| `long\Segment01 ...\Segment12 ...\deep-same.txt` | 5 bytes | 5 bytes |
| `long\Segment01 ...\Segment12 ...\deep-different.txt` (over 600 characters) | 50 bytes | 60 bytes |
| `names\same-café 日本.txt` | 7 bytes | 7 bytes |
| `names\only-café 日本.txt` | 8 bytes | missing |
| `names\only-c1-<U+0085>-<U+009B>-name.txt` | 9 bytes | missing |
| `Case\Report.TXT` / `case\report.txt` | 11 bytes | 11 bytes |
| `compressed\big.txt` | 1 MB, NTFS-compressed | 1 MB |
| `sparse\sparse.bin` | 10 MB, sparse | 10 MB |
| `junction` | junction to `docs` | missing |
| `link.txt` | symlink to `docs\same.txt` | missing |
| `denied\` | you cannot list it | missing |

## M1: Folder Size on the source

Main menu **Folder Size**, path `C:\Temp\fs_fixture\src`.

Expected screen:

- At the top, a **Folder Size Counter** box with `Folder: C:\Temp\fs_fixture\src`, laid out like the Confirm Copy box. Below it, the **Scanning** box while it scans. Both stay on screen afterwards.
- Below it, only the **Folder Size** summary box, then the **Next** menu. There is no "Logical vs stored" box.
- The summary shows Files `11`, Folders `20`, Unreadable `1`, Reparse `2`.
- Logical size is `11.00 MB (11,534,556 bytes)`. Stored size is far smaller, roughly 100 KB or less, because the compressed file takes little space and the sparse file takes none.
- `Details in log: 2 logical vs stored, 1 unreadable, 2 reparse points.` and `Log: C:\Temp\backup_logs\folder_size\folder-size-<time>-<id>.txt`.

Expected log (open the file):

- `Started:` and `Finished:` timestamps, then `Path: C:\Temp\fs_fixture\src`.
- `Logical vs stored (2)` lists `C:\Temp\fs_fixture\src\compressed` and `C:\Temp\fs_fixture\src\sparse`, each with exact byte counts.
- `Unreadable (1)`: `C:\Temp\fs_fixture\src\denied` with an `Error:` line saying access is denied.
- `Reparse points skipped (2)`: `...\src\junction` (`Kind: junction or mount point`) and `...\src\link.txt` (`Kind: symlink`).
- No line starts with `...`, and there are no escape codes such as `[38;2;`.

## M2: Folder Size Comparison of source and backup

Main menu **Folder Size Comparison**, source `C:\Temp\fs_fixture\src`, backup `C:\Temp\fs_fixture\bak`.

Expected screen:

- At the top, a **Folder Size Comparison** box with `Source:      C:\Temp\fs_fixture\src` and `Destination: C:\Temp\fs_fixture\bak`, laid out like the Confirm Copy box. Below it, the **Comparing** box, with a progress bar while files are matched. Both stay on screen afterwards.
- Below it, only the **Totals** box and the **Result** box, then the **Next** menu. There are no Cross-tree, Logical vs stored, or Unreadable boxes.
- Result: `Source and backup differ.`, `Stored size differs from logical size.`, `Details in log: 7 cross-tree, 2 logical vs stored, 1 unreadable.`, and the log path under `C:\Temp\backup_logs\folder_size`.
- Totals: Logical `11.00 MB` / `11.00 MB` / `-103 bytes`, Files `11` / `9` / `2`, Folders `20` / `18` / `2`, Unreadable `1` / `0` / `1`, Reparse `2` / `0` / `2`. There are no `bytes` rows; the log's Totals section has the exact counts (`11,534,556` / `11,534,659` / `-103`).

Expected log:

- `Cross-tree: only in source (4)`: `src\docs\only-in-source.txt`, `src\EmptyOnlyInSource` with `Files: 0 (empty folder)`, and the two `src\names\only-...` files. The accented, Japanese, and control-character names are written as they are.
- `Cross-tree: only in backup (1)`: `bak\docs\only-in-backup.txt`.
- `Cross-tree: logical size mismatch (2)`: `docs\different-size.txt` and the long `deep-different.txt`. Each has a `Source:` line and a `Backup:` line with the complete absolute path. The long one is over 600 characters and is not shortened.
- `Case\Report.TXT` is not listed, because names are compared without regard to case.
- `denied` is listed under `Unreadable: source` only. It is not listed as an empty folder.
- `junction` and `link.txt` are listed under `Reparse points skipped: source` only.

## M3: Comparison of identical trees

**Folder Size Comparison**, source `C:\Temp\fs_fixture\same_a`, backup `C:\Temp\fs_fixture\same_b`.

Expected: Result `Logical sizes match.` with `Details in log: 0 cross-tree, 0 logical vs stored, 0 unreadable.` The log lists `none` under every section.

## M4: Compare after Copy Data

**Copy Data**, any preset, source `C:\Temp\fs_fixture\same_a`, destination `C:\Temp\fs_fixture\copy_test`. When it finishes, choose option 3, **Compare source and backup**.

Expected:

- The copy progress bars look the same as before this change: green filled blocks, a gray track, and a percentage.
- The Folder Size Comparison box lists `Source:      C:\Temp\fs_fixture\same_a` and `Destination: C:\Temp\fs_fixture\copy_test`, and the comparison shows `Logical sizes match.`.
- The log path in the Result box is in the same folder as the Robocopy log (`C:\Temp\backup_logs\robocopy_<threads>_thread\folder-compare-<time>-<id>.txt`).

Delete `C:\Temp\fs_fixture\copy_test` afterwards (the fixture's `-Remove` also deletes it).

## M5: Narrow window

Run M2 again. While it scans, and again on the final screen, drag the window narrower than 68 columns, then wider again.

Expected: nothing crashes. Below 68 columns the Totals table stacks Source, Backup, and Gap under each row name. The Result box wraps the log path onto more lines instead of cutting it. Widening restores the side-by-side table.

## M6: Ctrl+C

Ctrl+C ends the tool, which closes a window started by `run.bat`. To see what is left behind, start the tool inside an elevated PowerShell window instead:

```powershell
& .\BackupTool.ps1
```

1. Start **Folder Size** on `C:\` (large enough to take a while) and press Ctrl+C during the scan.
2. Start the tool again, start **Folder Size Comparison** on two large folders, and press Ctrl+C while the Comparing box is on screen.

Expected each time: you are back at the `PS>` prompt at once, with no error text and a visible cursor. `Get-Runspace` then lists only `Runspace1` (the scan workers were stopped and disposed), and CPU use in Task Manager drops back to idle.

## M7: Online-only cloud folder

Pick a Dropbox or OneDrive folder whose files are online-only (cloud icon in Explorer). In PowerShell:

```powershell
(Get-Item 'C:\Users\<you>\Dropbox\<online-only folder>').Attributes
fsutil reparsepoint query 'C:\Users\<you>\Dropbox\<online-only folder>'
```

Expected: the attributes include `ReparsePoint`, and `fsutil` shows a cloud tag (`0x9000xxxx`), not `0xa000000c` (symlink) or `0xa0000003` (junction).

Then run **Folder Size** on that folder. Expected: Files and Logical size match what Explorer's Properties shows for the folder. Stored size is near 0. The folder is not listed as a skipped reparse point. Explorer still shows the cloud icons afterwards, which means nothing was downloaded.

## M8: Log folder that cannot be written

In an elevated PowerShell window in the repository folder:

```powershell
. .\lib\Ui.ps1; . .\lib\Common.ps1; . .\lib\FolderSize.ps1
Invoke-FolderSizeComparison -Source C:\Temp\fs_fixture\same_a -Dest C:\Temp\fs_fixture\same_b -LogFolder C:\Temp\fs_fixture\readonly_logs
```

Expected: the Result box shows `Log: C:\Temp\backup_logs\folder_size\folder-compare-<time>-<id>.txt` and then `Could not write the log to C:\Temp\fs_fixture\readonly_logs: Access to the path ... is denied.` The log file exists at the shown path.

## M9: UNC and relative paths

1. Run **Folder Size** on `\\localhost\C$\Temp\fs_fixture\same_a`. If you have a server with a one-letter name, try `\\s\<share>` as well.
2. Run **Folder Size** on `lib` (a relative path; `run.bat` starts in the repository folder).

Expected for the first: Files `2`, Folders `2`, Logical `30 bytes`, and the log's `Path:` line shows the UNC path as typed. Expected for the second: the scan counts the files in the repository's `lib` folder (not 0 with an unreadable root), and the Folder Size Counter box, summary, and log show the full path, such as `C:\...\windows-backup-utilities\lib`.
