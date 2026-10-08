# Windows Backup Utilities

Menu-driven PowerShell tools for copying folders with Robocopy and for measuring folder size. Use them to copy a folder and to check its size before or after the copy.

There are no command-line arguments. Source, destination, and options are entered in the console.

## Requirements

- Windows
- Windows PowerShell 5.1 or later
- Built-in `robocopy.exe`
- Write access so the copy tool can create `C:\Temp\backup_logs`
- Administrator rights (`run.bat` always requests elevation via UAC)

Use a normal `powershell.exe` window for live progress and resize handling. Hosts without interactive console support use sequential output and their normal line input instead; they show results without live screen redraws.

## How to run

Double-click `run.bat`. That opens an elevated PowerShell window in this folder and starts `BackupTool.ps1`. Approve the UAC prompt.

To run the menu yourself (this command does not elevate; right-click PowerShell and run as administrator if you need that):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\windows-backup-utilities\BackupTool.ps1"
```

The console title is `Backup Utilities`. When the host allows it, the window is set to a black background, UTF-8 output, and a minimum width of 80 columns.

The main menu is **Copy Data**, **Folder Size**, **Folder Size Comparison**, and **Exit**. After a copy finishes, you can compare the source and backup, return to the main menu, or exit. After a folder-size or comparison run finishes, you can return to the main menu or exit. Canceling before a run starts (empty path, **Back**) returns to the main menu without that prompt.

Menus, prompts, progress, and summaries share the same screen renderer. Resizing rebuilds the current screen, clears stale rows, and preserves partially entered input and the summary above the **Next** menu. Ordinary updates write only changed rows. Long confirmation paths, summaries, and messages wrap; progress paths keep their ending with a leading `...`. Fitting affects displayed text only. If the console buffer is too short for the entire screen, the last rows remain visible; enlarging the buffer restores the retained content.

Input supports Left/Right, Home/End, Backspace/Delete, Insert to toggle overwrite, Escape to clear the line, and Up/Down for recent input in this session. Ctrl+Left/Right moves by words. Ctrl+V and Shift+Insert paste the first clipboard line without submitting it; Enter submits the value. Ctrl+C cancels. Very long input scrolls horizontally while keeping the complete value. Input history stays in memory and is not written to a file.

## Tools

### Copy Data

Robocopy-based folder copy. Choose a speed preset, or **Back** to the main menu:

| Option | Threads | Meaning |
|--------|---------|---------|
| Slow | 1 | One file at a time |
| Standard | 16 | Up to 16 files at a time |
| Fast | 64 | Up to 64 files at a time |

Enter a source folder (must already exist) and a destination (local, mapped drive, or UNC). Surrounding quotes and a trailing backslash are stripped. Invalid paths can be re-entered. Enter with an empty source or destination cancels and returns to the main menu.

The destination does not have to exist yet. It is accepted when an ancestor folder exists so Robocopy can create the final directory. If no ancestor exists, the tool rejects the path.

You then get a **Confirm Copy** summary (source, destination, preset):

1. Start copy
2. Change source
3. Change destination
4. Change both paths
5. Back to main menu

When changing one path, Enter keeps the current value. Changing both paths and then canceling leaves the previous pair unchanged.

After you start, the tool does a dry run to estimate total size and file count, then copies with live overall progress (data and files) and per-file progress. When it finishes, it shows a summary (paths, size, file count, timing, Robocopy exit code, status, and log path) and writes the same timing summary next to the Robocopy log. The summary's size and file count come from the initial estimate.

The Next menu then offers **Compare source and backup** as option 3. Options 1 and 2 are still **Back to main menu** and **Exit**. Compare scans the source and destination from the copy that just finished. It is also offered when estimation fails or the copy is interrupted, because those paths are already known. Canceling before the copy starts does not show this menu.

Robocopy runs as a separate process and writes directly to its log. Like the Folder Size tool, the copy tool processes available activity continuously and limits only screen refreshes to once every 100 milliseconds. It waits for new data only after catching up with the log, so the read-buffer size does not limit processing to one chunk per refresh. Console rendering cannot block Robocopy through an output pipe.

The display checks console dimensions at each refresh interval, including when there is no new log activity. A resize during drawing is retried without stopping Robocopy. The initial dry run still runs once with the same list-only options, but its process output is drained asynchronously so estimation also allows screen refreshes. Cancellation cleans up an active estimate or copy process.

The original progress display is approximate: file listings do not confirm completed writes, and multithreaded percentage messages do not identify which file they belong to. The Current File box retains the original association with the most recently listed file. Completion is determined by the process exiting, not by a percentage reaching 100%. Log buffering can delay updates. As before, parsing estimates and file activity expects English Robocopy output.

#### What is copied

Copies use:

- `/E` — subfolders, including empty ones
- `/COPY:DAT` and `/DCOPY:DAT` — data, attributes, and timestamps for files and directories (not NTFS ACLs, owner, or auditing)
- `/XJ` — directory junctions are not followed
- `/R:3 /W:5` — 3 retries, 5 seconds between retries
- `/MT:<threads>` — the Slow / Standard / Fast preset
- `/UNILOG:` — Unicode log file, read by the progress display; no `/TEE`
- `/FP` — log full file paths; per-file percentages remain enabled

This is a copy, not a mirror. Extra files already in the destination are left alone. Hidden and system files are included. Junctions are not followed.

#### Logs

Logs and a timing summary are written under `C:\Temp\backup_logs`. The thread count in the folder name is padded to two digits:

| Preset | Folder |
|--------|--------|
| Slow (1) | `C:\Temp\backup_logs\robocopy_01_thread\` |
| Standard (16) | `C:\Temp\backup_logs\robocopy_16_thread\` |
| Fast (64) | `C:\Temp\backup_logs\robocopy_64_thread\` |

Each run writes:

- `robocopy-yyyyMMdd-HHmmss-<id>.log` — Robocopy log in UTF-16, including file activity, errors, and the final summary
- `robocopy-time-yyyyMMdd-HHmmss-<id>.txt` — timing and status summary

The eight-character run ID keeps simultaneous runs from sharing a log. Example: `C:\Temp\backup_logs\robocopy_16_thread\robocopy-20260914-184600-a13b4c5d.log`

The log reader uses 64 KB buffers and immediately reads another chunk when more data is available. On process exit, it reads the final summary without replaying a backlog of activity and uses its copied totals for the final overall progress update when available. Reported duration uses the process start and exit times and excludes the initial estimate and UI cleanup. Ctrl+C or a monitoring error triggers cleanup that stops an active child process and closes the log reader.

#### Robocopy exit codes

Exit codes **0 through 7** are treated as success (no fatal failure). **8 or higher**, or a negative process exit code, means the copy failed; check the log. The copy summary status uses the meaning below.

Robocopy returns a bit mask. The base flags are **1** (files copied), **2** (extra files or directories on the destination), **4** (mismatched files or directories), **8** (copy failures after retries), and **16** (serious error). Combined values are the sum of those flags:

| Code | Flags | Meaning |
|------|-------|---------|
| 0 | | No files were copied. No failure. No mismatches. The trees already match. |
| 1 | 1 | Files were copied successfully. |
| 2 | 2 | Extra files or directories on the destination. No files were copied. |
| 3 | 1+2 | Files were copied. Extra files were present. No failure. |
| 4 | 4 | Mismatched files or directories. No files were copied. |
| 5 | 1+4 | Files were copied. Some files were mismatched. No failure. |
| 6 | 2+4 | Extra files and mismatched files. No files were copied. No failure. |
| 7 | 1+2+4 | Files were copied. Mismatches and extra files were present. No failure. |
| 8 | 8 | Some files or directories could not be copied (retry limit exceeded). |
| 9 | 1+8 | Files were copied, but some copy failures occurred. |
| 10 | 2+8 | Extra files present, and some copy failures. |
| 11 | 1+2+8 | Files were copied, extra files were present, and some copy failures. |
| 12 | 4+8 | Mismatches present, and some copy failures. |
| 13 | 1+4+8 | Files were copied, mismatches were present, and some copy failures. |
| 14 | 2+4+8 | Extra files, mismatches, and some copy failures. |
| 15 | 1+2+4+8 | Files were copied; extra files, mismatches, and copy failures. |
| 16 | 16 | Serious error. Robocopy did not copy any files (usage error or insufficient access). |

### Folder Size

Recursively measures one folder. The path must already exist. Hidden and system items are included. Directory junctions and file symbolic links are not followed, matching the copy tool's `/XJ` switch, so a junction is not counted as well as its target. Cloud placeholder files are included.

Two sizes are recorded for each file:

- **Logical size** is `FileInfo.Length`, the directory metadata length. This is the length Robocopy copies with `/COPY:DAT`.
- **Stored size** comes from `GetCompressedFileSizeW`. For a normal file it matches the logical size. It is smaller for NTFS-compressed files, sparse files, and dehydrated placeholders. Cluster slack is not included, so a 4K volume and a 64K volume can still match.

While it scans, it shows live logical size, stored size, file count, folder count, and the path currently being read. The final summary repeats the path you typed, both totals (human-readable and bytes), the gap, the file and folder counts, the unreadable and reparse counts, and the log path. This main-menu tool does not compare two folders.

When logical size and stored size differ, a second box lists the shallowest folder whose entire subtree differs. Each difference is a short record: path, file count, logical size, stored size, and gap. A folder that contains both matching and differing files is not listed; the differing file, or a uniform child folder, is listed instead. The whole tree is one record, labeled `entire folder`, only when every file differs. No differences produces `No differences.` More than 40 lines stay in the log; the screen shows the first 40 and how many lines remain.

The full report, including every rollup line, unreadable path, and skipped reparse point, is written to `C:\Temp\backup_logs\folder_size\folder-size-<time>-<id>.txt`.

Enumeration runs in an in-process PowerShell worker, publishing a complete progress snapshot at most once every 100 milliseconds and once at completion. The main thread owns all console output and can handle resizing while a filesystem read is waiting. Equal logical and stored size does not prove the bytes are identical, and the scan does not confirm that a concurrent copy has finished. Cancellation stops and disposes the worker.

Long paths are supported via the `\\?\` prefix:

- Local: `C:\folder` → `\\?\C:\folder`
- UNC: `\\server\share\folder` → `\\?\UNC\server\share\folder`
- Drive root: `E:` or `E:\` stays `E:\`. `\\?\E:` is not a valid path, and the root itself is too short to need the prefix.

Access-denied directories and files are counted as unreadable and left out of the totals, so a locked or permission-denied tree can under-report. The log names those paths. An unreadable directory is one line, not a list of every child that could not be read.

Enter with an empty path cancels and returns to the main menu.

#### Compare source and backup

Compare is on the main menu as **Folder Size Comparison**, and it is also option 3 on the Next menu after Copy Data. It is not on the Folder Size Next menu. From the main menu, both folders must already exist. An empty path cancels and returns to the main menu. After a copy, it uses that copy's source and destination and does not ask again. Two workers scan the trees at the same time. One finished worker stays on screen until the other finishes.

The backup matches when every relative path has the same logical size. Paths are compared without regard to case. A stored-size gap is shown and does not by itself fail the backup. The result box states one of:

- **Logical sizes match.** Nothing unreadable, and no path or logical-size difference.
- **Sizes match for items that could be read. Some items were skipped.** No logical-size difference, but at least one item could not be read.
- **Source and backup differ.** A path exists on only one side, or the logical sizes differ.

While those lists are compared, the comparing box shows how many files have been checked. The totals table comes next, with Source, Backup, and Gap columns for logical size, stored size, file count, folder count, unreadable count, and reparse count. Logical and stored rows include the exact byte count on the next line. On a narrow window the columns stack under each metric instead.

The cross-tree, logical-versus-stored, and unreadable sections are each one box with Source and Backup columns. A folder only on one side appears in that column. A logical-size mismatch is one row across both columns. The shallowest uniform folder is listed, labeled `entire folder` when the whole tree differs. Logical versus stored shows path, file count, logical size, stored size, and gap in the column for that tree. Unreadable paths use the same columns, and a side with no paths says `none`. A path under another unreadable path is hidden. Each of those boxes keeps the first 40 lines on screen.

The result box is last, just before the finished rule. It states the verdict above, says this is a size check and that equal logical size does not prove identical bytes, and gives the log path.

If the backup could not read `Secret\`, files under `Secret\` are not also listed as missing from the backup. The unreadable box names `Secret\`. The same rule applies in the other direction.

After a copy, the full report is written next to that copy's Robocopy log as `folder-compare-<time>-<id>.txt`. From the main menu, the same file is written under `C:\Temp\backup_logs\folder_size`. Choosing compare again runs it again. Ctrl+C stops and disposes both workers.

## Paths

You can enter a local path, a mapped drive letter, or a UNC share. Surrounding quotes are stripped. A trailing backslash is removed, except on a drive root: `E:` and `E:\` are both kept as `E:\`.

```
D:\Users\ethanmash
Z:\Backups\user
\\server\share\folder
```

Source (Copy Data) and Path (Folder Size) must already exist. Destination (Copy Data) may be created if a parent folder exists.

## Troubleshooting

### Mapped drives missing in the elevated window (`Z:`, `X:`, and similar)

`run.bat` always starts an **elevated** PowerShell session. Windows gives your normal desktop session and that elevated session separate logon tokens. Drive letters mapped in the normal user session (for example `Z:` to a network share) often do **not** appear in the admin window.

Symptoms:

- `net use Z:` in the elevated window reports that the drive is not there
- The tool says the source or destination folder does not exist when you enter `Z:\...`
- The same path works in a non-admin Explorer or PowerShell window

#### Longer-term fix: `EnableLinkedConnections`

This registry value tells Windows to share those mapped drives between the filtered (standard) token and the elevated token.

Run this from an **elevated** PowerShell, then **restart Windows**:

```powershell
New-ItemProperty `
  -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name 'EnableLinkedConnections' `
  -PropertyType DWord `
  -Value 1 `
  -Force
```

Verify after the reboot:

```powershell
Get-ItemProperty `
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name EnableLinkedConnections
```

You should see:

```
EnableLinkedConnections : 1
```

If `Z:` (or `X:`, or any other mapped letter) is mapped in the same user's normal session, an elevated PowerShell launched by that user should then accept:

```powershell
net use Z:
```

and paths like `Z:\Backups\user` in this tool.

This is a machine-wide setting. Apply it once on each computer.

#### Workaround without a reboot

Type the **UNC path** instead of the drive letter:

```
\\server\share\folder
```

A UNC path does not depend on the mapped letter being visible in the elevated session. You still need permission to that share from the elevated token.

## Project layout

```
BackupTool.ps1     Main menu
run.bat            Elevated launcher (UAC)
lib/
  Ui.ps1           Headers, boxes, menus, colors
  Common.ps1       Shared path prompt and size formatting
  Robocopy.ps1     Copy tool
  FolderSize.ps1   Folder size tool
```
