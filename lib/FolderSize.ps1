$script:FolderSizeProgressIntervalMs = 100
$script:FolderSizeLogRoot = 'C:\Temp\backup_logs\folder_size'
$script:FolderSizeScreenLineCap = 40

# =============================================================================
#  Native size and reparse tag
# =============================================================================

function Initialize-FolderSizeNative {
	# The worker runspace cannot see script functions. This type is loaded once
	# into the process so both runspaces can call it. Re-dot-sourcing this file
	# must not define the type again.
	if ('FolderSizeNative' -as [type]) { return }

	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FolderSizeNative {
	const uint FileReadAttributes = 0x80;
	const uint OpenExisting = 3;
	const uint OpenReparse = 0x00200000;
	const uint BackupSemantics = 0x02000000;
	const uint OpenNoRecall = 0x00100000;
	const uint SymlinkTag = 0xA000000C;
	const uint MountPointTag = 0xA0000003;

	[StructLayout(LayoutKind.Sequential)]
	struct AttributeTagInfo {
		public uint FileAttributes;
		public uint ReparseTag;
	}

	[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
	static extern uint GetCompressedFileSizeW(string path, out uint high);

	[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
	static extern IntPtr CreateFileW(
		string name,
		uint access,
		uint share,
		IntPtr security,
		uint disposition,
		uint flags,
		IntPtr templateFile);

	[DllImport("kernel32.dll", SetLastError = true)]
	static extern bool GetFileInformationByHandleEx(
		IntPtr handle,
		int fileInformationClass,
		out AttributeTagInfo info,
		uint bufferSize);

	[DllImport("kernel32.dll", SetLastError = true)]
	static extern bool CloseHandle(IntPtr handle);

	public static ulong StoredSize(string path) {
		uint high;
		uint low = GetCompressedFileSizeW(path, out high);
		if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0)
			throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
		return ((ulong)high << 32) | low;
	}

	public static bool IsSymlinkOrJunction(string path) {
		IntPtr handle = CreateFileW(
			path,
			FileReadAttributes,
			7,
			IntPtr.Zero,
			OpenExisting,
			OpenReparse | BackupSemantics | OpenNoRecall,
			IntPtr.Zero);
		if (handle == new IntPtr(-1)) return false;
		try {
			AttributeTagInfo info;
			int size = Marshal.SizeOf(typeof(AttributeTagInfo));
			if (!GetFileInformationByHandleEx(handle, 9, out info, (uint)size)) return false;
			return info.ReparseTag == SymlinkTag || info.ReparseTag == MountPointTag;
		}
		finally {
			CloseHandle(handle);
		}
	}
}
'@
}

# =============================================================================
#  Paths, rollup, and report text
# =============================================================================

function ConvertTo-FolderSizeLongPath {
	param([string]$Path)

	if ($Path -like '\\?\*') { return $Path }
	if ($Path -like '\\*') { return '\\?\UNC\' + $Path.TrimStart('\') }
	return '\\?\' + $Path
}

function Get-ParentRelativePath {
	param([string]$RelativePath)

	if ([string]::IsNullOrEmpty($RelativePath)) { return $null }
	$index = $RelativePath.LastIndexOf('\')
	if ($index -lt 0) { return '' }
	return $RelativePath.Substring(0, $index)
}

function Get-FolderSizeAncestorDirectories {
	param([string]$RelativeFile)

	$ancestors = New-Object System.Collections.Generic.List[string]
	[void]$ancestors.Add('')
	$parent = Get-ParentRelativePath $RelativeFile
	if (-not [string]::IsNullOrEmpty($parent)) {
		$built = ''
		foreach ($part in $parent.Split('\')) {
			if ($built.Length -gt 0) { $built = $built + '\' + $part }
			else { $built = $part }
			[void]$ancestors.Add($built)
		}
	}
	# Keep a one-item list intact. An unwrapped return would drop the root entry.
	return ,$ancestors.ToArray()
}

function Format-FolderSizeRelativePath {
	param([string]$RelativePath)

	if ([string]::IsNullOrEmpty($RelativePath)) { return 'entire folder' }
	return $RelativePath
}

function Get-FolderSizeObjectList {
	param($Value)

	# @() enumerates a hashtable into dictionary entries, and a one-item array
	# stored on the worker result comes back as that one item. Neither should
	# be treated as a list of difference records.
	$list = New-Object System.Collections.Generic.List[object]
	if ($null -eq $Value) { return ,$list.ToArray() }
	if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
		[void]$list.Add($Value)
		return ,$list.ToArray()
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($item in $Value) {
			if ($null -eq $item -or $item -is [System.Collections.DictionaryEntry]) { continue }
			[void]$list.Add($item)
		}
		return ,$list.ToArray()
	}
	[void]$list.Add($Value)
	return ,$list.ToArray()
}

function Get-FolderSizeStringList {
	param($Value)

	# A [string[]] parameter turns $null into one empty string, which then
	# displays as a path and also covers every child in the unreadable test.
	$list = New-Object System.Collections.Generic.List[string]
	if ($null -eq $Value) { return ,$list.ToArray() }
	if ($Value -is [string]) {
		[void]$list.Add($Value)
		return ,$list.ToArray()
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($item in $Value) {
			if ($null -ne $item) { [void]$list.Add([string]$item) }
		}
	}
	return ,$list.ToArray()
}

function Test-FolderSizePathCovered {
	param(
		[string]$RelativePath,
		$Ancestors
	)

	foreach ($ancestor in (Get-FolderSizeStringList $Ancestors)) {
		if ([string]::IsNullOrEmpty($ancestor)) { return $true }
		if ($RelativePath -eq $ancestor) { return $true }
		if (-not [string]::IsNullOrEmpty($RelativePath) -and $RelativePath.StartsWith($ancestor + '\', [StringComparison]::OrdinalIgnoreCase)) {
			return $true
		}
	}
	return $false
}

function Test-FolderSizeMetricUniform {
	param($Node)

	return ($null -ne $Node -and $Node.FileCount -gt 0 -and $Node.DifferCount -eq $Node.FileCount)
}

function Get-FolderSizeRollup {
	param(
		$DirectoryStats,
		$Differences
	)

	$entries = New-Object System.Collections.Generic.List[object]
	if ($null -eq $DirectoryStats) { return ,@() }

	foreach ($dir in @($DirectoryStats.Keys)) {
		$node = $DirectoryStats[$dir]
		if (-not (Test-FolderSizeMetricUniform $node)) { continue }
		$parent = Get-ParentRelativePath $dir
		$parentUniform = $false
		if ($null -ne $parent) {
			$parentUniform = Test-FolderSizeMetricUniform $DirectoryStats[$parent]
		}
		if ($parentUniform) { continue }
		if ($null -eq $node.FileCount -or $null -eq $node.Logical -or $null -eq $node.Stored) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$dir
			FileCount = [long]$node.FileCount
			Logical = $node.Logical
			Stored = $node.Stored
		})
	}

	foreach ($diff in (Get-FolderSizeObjectList $Differences)) {
		if ($diff -is [System.Collections.DictionaryEntry]) { continue }
		if ($null -eq $diff.Logical -or $null -eq $diff.Stored) { continue }
		$parent = Get-ParentRelativePath ([string]$diff.RelativePath)
		$parentNode = $null
		if ($null -ne $parent) { $parentNode = $DirectoryStats[$parent] }
		if (Test-FolderSizeMetricUniform $parentNode) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$diff.RelativePath
			FileCount = [long]1
			Logical = $diff.Logical
			Stored = $diff.Stored
		})
	}

	return ,@($entries | Sort-Object RelativePath)
}

function Test-CrossTreeUniform {
	param($Node)

	if ($null -eq $Node -or $Node.FileCount -le 0) { return $false }
	if ($Node.OnlySource -eq $Node.FileCount) { return $true }
	if ($Node.OnlyBackup -eq $Node.FileCount) { return $true }
	if ($Node.Mismatch -eq $Node.FileCount) { return $true }
	return $false
}

function Get-CrossTreeState {
	param($Node)

	if ($Node.OnlySource -eq $Node.FileCount) { return 'OnlyInSource' }
	if ($Node.OnlyBackup -eq $Node.FileCount) { return 'OnlyInBackup' }
	if ($Node.Mismatch -eq $Node.FileCount) { return 'LogicalMismatch' }
	return $null
}

function Add-CrossTreeCount {
	param(
		$Stats,
		[string]$RelativeFile,
		[string]$State,
		$SourceLogical,
		$DestLogical
	)

	foreach ($dir in (Get-FolderSizeAncestorDirectories $RelativeFile)) {
		if (-not $Stats.ContainsKey($dir)) {
			$Stats[$dir] = @{
				FileCount = 0
				OnlySource = 0
				OnlyBackup = 0
				Mismatch = 0
				SourceLogical = [uint64]0
				DestLogical = [uint64]0
			}
		}
		$node = $Stats[$dir]
		$node.FileCount = [long]$node.FileCount + 1
		if ($State -eq 'Match') { continue }
		if ($State -eq 'OnlyInSource') { $node.OnlySource = [long]$node.OnlySource + 1 }
		elseif ($State -eq 'OnlyInBackup') { $node.OnlyBackup = [long]$node.OnlyBackup + 1 }
		elseif ($State -eq 'LogicalMismatch') { $node.Mismatch = [long]$node.Mismatch + 1 }
		$node.SourceLogical = [uint64]([decimal]$node.SourceLogical + [decimal]$SourceLogical)
		$node.DestLogical = [uint64]([decimal]$node.DestLogical + [decimal]$DestLogical)
	}
}

function Update-FolderCompareBuildStatus {
	param(
		[string]$Status,
		$Done,
		$Total
	)

	if ($null -eq $script:FolderCompareBuildProgress) { return }
	$script:FolderCompareBuildProgress.Status = $Status
	if ($null -eq $Done -or $null -eq $Total) {
		$script:FolderCompareBuildProgress.Compared = $null
		$script:FolderCompareBuildProgress.Total = $null
	}
	else {
		$script:FolderCompareBuildProgress.Compared = [long]$Done
		$script:FolderCompareBuildProgress.Total = [long]$Total
	}
	if ($null -ne $script:UiScreen) { $script:UiScreen.Dirty = $true }
	Update-UiScreen -Force
}

function Format-FolderCompareBar {
	param(
		$Layout,
		[long]$Done,
		[long]$Total
	)

	$percent = 0.0
	if ($Total -gt 0) {
		$percent = [Math]::Min(100, ($Done / $Total) * 100)
	}
	$percentText = '{0:N2}%' -f $percent
	$label = ' Comparing: '
	$barWidth = $Layout.InnerWidth - (Get-VisibleTextLength $label) - (Get-VisibleTextLength $percentText) - 3
	if ($barWidth -gt 40) { $barWidth = 40 }
	if ($barWidth -lt 1) { $barWidth = 1 }

	$fillLen = [int][Math]::Round(($percent / 100) * $barWidth)
	if ($fillLen -lt 0) { $fillLen = 0 }
	elseif ($fillLen -gt $barWidth) { $fillLen = $barWidth }
	$emptyLen = $barWidth - $fillLen

	# Block fill and a horizontal empty track, via code points so Windows
	# PowerShell 5.1 can parse this file without a UTF-8 BOM.
	$fillStr = ''
	$emptyStr = ''
	if ($fillLen -gt 0) { $fillStr = Format-UiText -Text ([String]::new([char]0x2588, $fillLen)) -Style Success }
	if ($emptyLen -gt 0) { $emptyStr = Format-UiText -Text ([String]::new([char]0x2500, $emptyLen)) -Style Secondary }
	return $label + '[' + $fillStr + $emptyStr + '] ' + $percentText
}

function Get-CrossTreeRollup {
	param(
		$SourceFiles,
		$DestFiles,
		$SourceUnreadable,
		$DestUnreadable,
		[scriptblock]$OnProgress
	)

	if ($null -eq $SourceFiles) { $SourceFiles = @{} }
	if ($null -eq $DestFiles) { $DestFiles = @{} }
	$stats = @{}
	$leaves = New-Object System.Collections.Generic.List[object]
	$seen = @{}
	$compared = [long]0
	$total = [long]$SourceFiles.Count + [long]$DestFiles.Count
	$progressStep = 5000

	foreach ($rel in @($SourceFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		$seen[$rel] = $true
		$sourceFile = $SourceFiles[$rel]
		if ($null -eq $sourceFile -or $null -eq $sourceFile.Logical) { continue }
		if ($DestFiles.ContainsKey($rel)) {
			$destFile = $DestFiles[$rel]
			if ($null -eq $destFile -or $null -eq $destFile.Logical) { continue }
			if ([uint64]$sourceFile.Logical -ne [uint64]$destFile.Logical) {
				Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'LogicalMismatch' -SourceLogical $sourceFile.Logical -DestLogical $destFile.Logical
				[void]$leaves.Add([pscustomobject]@{
					RelativePath = [string]$rel
					State = 'LogicalMismatch'
					FileCount = 1
					SourceLogical = $sourceFile.Logical
					DestLogical = $destFile.Logical
				})
			}
			else {
				Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'Match' -SourceLogical 0 -DestLogical 0
			}
		}
		elseif (-not (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $DestUnreadable)) {
			Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'OnlyInSource' -SourceLogical $sourceFile.Logical -DestLogical 0
			[void]$leaves.Add([pscustomobject]@{
				RelativePath = [string]$rel
				State = 'OnlyInSource'
				FileCount = 1
				SourceLogical = $sourceFile.Logical
				DestLogical = [uint64]0
			})
		}
	}

	foreach ($rel in @($DestFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		if ($seen.ContainsKey($rel)) { continue }
		if (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $SourceUnreadable) { continue }
		$destFile = $DestFiles[$rel]
		if ($null -eq $destFile -or $null -eq $destFile.Logical) { continue }
		Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'OnlyInBackup' -SourceLogical 0 -DestLogical $destFile.Logical
		[void]$leaves.Add([pscustomobject]@{
			RelativePath = [string]$rel
			State = 'OnlyInBackup'
			FileCount = 1
			SourceLogical = [uint64]0
			DestLogical = $destFile.Logical
		})
	}

	$entries = New-Object System.Collections.Generic.List[object]
	foreach ($dir in @($stats.Keys)) {
		$node = $stats[$dir]
		if (-not (Test-CrossTreeUniform $node)) { continue }
		$parent = Get-ParentRelativePath $dir
		$parentUniform = $false
		if ($null -ne $parent) { $parentUniform = Test-CrossTreeUniform $stats[$parent] }
		if ($parentUniform) { continue }
		$state = Get-CrossTreeState $node
		if ([string]::IsNullOrEmpty($state)) { continue }
		if ($null -eq $node.FileCount -or [long]$node.FileCount -le 0) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$dir
			State = [string]$state
			FileCount = [long]$node.FileCount
			SourceLogical = $node.SourceLogical
			DestLogical = $node.DestLogical
		})
	}

	foreach ($leaf in $leaves) {
		$parent = Get-ParentRelativePath $leaf.RelativePath
		$parentNode = $null
		if ($null -ne $parent) { $parentNode = $stats[$parent] }
		if (Test-CrossTreeUniform $parentNode) { continue }
		[void]$entries.Add($leaf)
	}

	return ,@($entries | Sort-Object RelativePath, State)
}

function Select-ShallowestPaths {
	param($Paths)

	$items = Get-FolderSizeStringList $Paths
	if ($null -eq $items) { return ,@() }
	$ordered = @($items | Sort-Object { if ([string]::IsNullOrEmpty($_)) { -1 } else { $_.Length } }, { $_ })
	$kept = New-Object System.Collections.Generic.List[string]
	foreach ($path in $ordered) {
		if ($null -eq $path) { continue }
		$covered = $false
		foreach ($parent in $kept) {
			if ([string]::IsNullOrEmpty($parent) -or $path -eq $parent) {
				$covered = $true
				break
			}
			if (-not [string]::IsNullOrEmpty($path) -and $path.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
				$covered = $true
				break
			}
		}
		if (-not $covered) { [void]$kept.Add([string]$path) }
	}
	return ,$kept.ToArray()
}

function Get-FolderSizeItemCount {
	param($Value)

	# A one-item or empty array stored on the worker result is unwrapped when
	# the main thread reads it back: one item arrives as that item, and an
	# empty array arrives as $null.
	if ($null -eq $Value) { return 0 }
	if ($Value -is [System.Array]) { return $Value.Length }
	return 1
}

function Format-ByteCount {
	param([decimal]$Bytes)

	return ('{0} ({1:N0} bytes)' -f (Format-ByteSize ([double]$Bytes)), $Bytes)
}

function Format-SignedByteCount {
	param([decimal]$Bytes)

	$sign = ''
	$absolute = $Bytes
	if ($Bytes -lt 0) {
		$sign = '-'
		$absolute = -$Bytes
	}
	return ('{0}{1} ({2:N0} bytes)' -f $sign, (Format-ByteSize ([double]$absolute)), $Bytes)
}

function Test-FolderSizeMetricEntry {
	param($Entry)

	if ($null -eq $Entry) { return $false }
	if ($Entry -is [System.Collections.DictionaryEntry] -or $Entry -is [System.Collections.IDictionary]) { return $false }
	if ($null -eq $Entry.FileCount -or $null -eq $Entry.Logical -or $null -eq $Entry.Stored) { return $false }
	$count = 0L
	try { $count = [long]$Entry.FileCount } catch { return $false }
	return ($count -gt 0)
}

function Test-FolderSizeCrossEntry {
	param($Entry)

	if ($null -eq $Entry) { return $false }
	if ($Entry -is [System.Collections.DictionaryEntry] -or $Entry -is [System.Collections.IDictionary]) { return $false }
	if ($null -eq $Entry.FileCount) { return $false }
	$state = [string]$Entry.State
	if ($state -ne 'OnlyInSource' -and $state -ne 'OnlyInBackup' -and $state -ne 'LogicalMismatch') { return $false }
	$count = 0L
	try { $count = [long]$Entry.FileCount } catch { return $false }
	return ($count -gt 0)
}

function Format-FolderSizePlainCount {
	param([decimal]$Bytes)

	if ($Bytes -eq 0) { return '0' }
	$sign = ''
	$absolute = $Bytes
	if ($Bytes -lt 0) {
		$sign = '-'
		$absolute = -$Bytes
	}
	return ('{0}{1}' -f $sign, (Format-ByteSize ([double]$absolute)))
}

function Format-FolderSizePathCell {
	param(
		[AllowEmptyString()]
		[string]$Path,
		[int]$Width
	)

	return (Format-UiPath -Path (Format-FolderSizeRelativePath $Path) -Width $Width)
}

function Format-FolderSizePad {
	param(
		[AllowEmptyString()]
		[string]$Text,
		[int]$Width
	)

	if ($null -eq $Text) { $Text = '' }
	if ($Width -le 0) { return '' }
	if ((Get-VisibleTextLength $Text) -gt $Width) {
		$Text = Format-UiFittedText -Text $Text -Width $Width
	}
	$pad = $Width - (Get-VisibleTextLength $Text)
	if ($pad -le 0) { return $Text }
	return $Text + (' ' * $pad)
}

function New-FolderSizeTextLayout {
	param(
		[int]$InnerWidth,
		[int]$ValueColumns
	)

	if ($ValueColumns -lt 1) { $ValueColumns = 1 }
	$labelWidth = 12
	$gap = 2
	$overhead = 1 + $labelWidth + $gap + ($gap * ($ValueColumns - 1))
	$cellWidth = 8
	if ($InnerWidth -gt $overhead) {
		$cellWidth = [int][Math]::Floor(($InnerWidth - $overhead) / $ValueColumns)
	}
	$sideBySide = $false
	if ($ValueColumns -eq 1) { $sideBySide = $true }
	elseif ($cellWidth -ge 12 -and $InnerWidth -ge 68) { $sideBySide = $true }
	if (-not $sideBySide) {
		$singleOverhead = 1 + $labelWidth + $gap
		$cellWidth = 8
		if ($InnerWidth -gt $singleOverhead) { $cellWidth = $InnerWidth - $singleOverhead }
	}
	return @{
		LabelWidth = $labelWidth
		CellWidth = $cellWidth
		Gap = $gap
		SideBySide = $sideBySide
		ValueColumns = $ValueColumns
		InnerWidth = $InnerWidth
	}
}

function Format-FolderSizeTableRow {
	param(
		$Layout,
		[AllowEmptyString()]
		[string]$Label,
		$Cells
	)

	$gapText = ' ' * [int]$Layout.Gap
	$text = ' ' + (Format-FolderSizePad -Text $Label -Width ([int]$Layout.LabelWidth))
	foreach ($cell in (Get-FolderSizeStringList $Cells)) {
		$text += $gapText + (Format-FolderSizePad -Text $cell -Width ([int]$Layout.CellWidth))
	}
	if ((Get-VisibleTextLength $text) -gt [int]$Layout.InnerWidth) {
		$text = Format-UiFittedText -Text $text -Width ([int]$Layout.InnerWidth)
	}
	return $text
}

function Format-FolderSizeCompareRows {
	param(
		$Layout,
		[AllowEmptyString()]
		[string]$Label,
		$Cells,
		[string[]]$Headers
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$cellList = Get-FolderSizeStringList $Cells
	if ($Layout.SideBySide) {
		[void]$lines.Add((Format-FolderSizeTableRow -Layout $Layout -Label $Label -Cells $cellList))
	}
	else {
		if (-not [string]::IsNullOrEmpty($Label)) { [void]$lines.Add((' ' + $Label)) }
		$single = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 1
		for ($i = 0; $i -lt $cellList.Count; $i++) {
			$header = ''
			if ($null -ne $Headers -and $i -lt $Headers.Count) { $header = $Headers[$i] }
			[void]$lines.Add((Format-FolderSizeTableRow -Layout $single -Label $header -Cells $cellList[$i]))
		}
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeHeaderRow {
	param(
		$Layout,
		[string[]]$Headers,
		[switch]$Plain
	)

	if (-not $Layout.SideBySide) { return $null }
	$cells = New-Object System.Collections.Generic.List[string]
	foreach ($header in $Headers) {
		if ($Plain) { [void]$cells.Add($header) }
		else { [void]$cells.Add((Format-UiText -Text $header -Style Secondary)) }
	}
	return (Format-FolderSizeTableRow -Layout $Layout -Label '' -Cells $cells.ToArray())
}

function Format-FolderSizeRecordLines {
	param($Layout, $Pairs)

	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($pair in $Pairs) {
		[void]$lines.Add((Format-FolderSizeTableRow -Layout $Layout -Label ([string]$pair[0]) -Cells ([string]$pair[1])))
	}
	return ,$lines.ToArray()
}

function Format-MetricRecordLines {
	param($Entries, [int]$InnerWidth)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 1
	$lines = New-Object System.Collections.Generic.List[string]
	$shown = 0
	foreach ($entry in (Get-FolderSizeObjectList $Entries)) {
		if (-not (Test-FolderSizeMetricEntry $entry)) { continue }
		if ($shown -gt 0) { [void]$lines.Add('') }
		$gap = [decimal]$entry.Logical - [decimal]$entry.Stored
		$path = Format-FolderSizePathCell -Path ([string]$entry.RelativePath) -Width ([int]$layout.CellWidth)
		$pairs = New-Object System.Collections.Generic.List[object]
		[void]$pairs.Add(@('Path', $path))
		[void]$pairs.Add(@('Files', ('{0:N0}' -f [long]$entry.FileCount)))
		[void]$pairs.Add(@('Logical', (Format-ByteSize ([double]$entry.Logical))))
		[void]$pairs.Add(@('Stored', (Format-ByteSize ([double]$entry.Stored))))
		[void]$pairs.Add(@('Gap', (Format-FolderSizePlainCount $gap)))
		foreach ($row in (Format-FolderSizeRecordLines -Layout $layout -Pairs $pairs)) {
			[void]$lines.Add($row)
		}
		$shown++
	}
	if ($shown -eq 0) { [void]$lines.Add('  No differences.') }
	return ,$lines.ToArray()
}

function Get-FolderSizeFitWidth {
	param($Layout)

	if ($Layout.SideBySide) { return [int]$Layout.CellWidth }
	$single = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 1
	return [int]$single.CellWidth
}

function Format-PairedColumnLines {
	param(
		$Layout,
		$LeftBlocks,
		$RightBlocks,
		[string[]]$Headers,
		[switch]$Plain,
		[switch]$NoHeader
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$leftCount = 0
	$rightCount = 0
	if ($null -ne $LeftBlocks) { $leftCount = $LeftBlocks.Count }
	if ($null -ne $RightBlocks) { $rightCount = $RightBlocks.Count }
	$count = $leftCount
	if ($rightCount -gt $count) { $count = $rightCount }
	if ($count -eq 0) { return ,$lines.ToArray() }
	if (-not $NoHeader) {
		$header = Format-FolderSizeHeaderRow -Layout $Layout -Headers $Headers -Plain:$Plain
		if ($null -ne $header) { [void]$lines.Add($header) }
	}
	for ($i = 0; $i -lt $count; $i++) {
		if ($i -gt 0) { [void]$lines.Add('') }
		$leftLines = @()
		$rightLines = @()
		if ($i -lt $leftCount) { $leftLines = Get-FolderSizeStringList $LeftBlocks[$i] }
		if ($i -lt $rightCount) { $rightLines = Get-FolderSizeStringList $RightBlocks[$i] }
		$rowCount = $leftLines.Count
		if ($rightLines.Count -gt $rowCount) { $rowCount = $rightLines.Count }
		for ($row = 0; $row -lt $rowCount; $row++) {
			$leftCell = ''
			$rightCell = ''
			if ($row -lt $leftLines.Count) { $leftCell = [string]$leftLines[$row] }
			if ($row -lt $rightLines.Count) { $rightCell = [string]$rightLines[$row] }
			foreach ($line in (Format-FolderSizeCompareRows -Layout $Layout -Label '' -Cells @($leftCell, $rightCell) -Headers $Headers)) {
				[void]$lines.Add($line)
			}
		}
	}
	return ,$lines.ToArray()
}

function Get-MetricCompareCellLines {
	param($Entry, [int]$Width)

	$lines = New-Object System.Collections.Generic.List[string]
	if (-not (Test-FolderSizeMetricEntry $Entry)) { return ,$lines.ToArray() }
	$gap = [decimal]$Entry.Logical - [decimal]$Entry.Stored
	[void]$lines.Add((Format-FolderSizePathCell -Path ([string]$Entry.RelativePath) -Width $Width))
	[void]$lines.Add(('{0:N0} files' -f [long]$Entry.FileCount))
	[void]$lines.Add(('Logical {0}' -f (Format-ByteSize ([double]$Entry.Logical))))
	[void]$lines.Add(('Stored {0}' -f (Format-ByteSize ([double]$Entry.Stored))))
	[void]$lines.Add(('Gap {0}' -f (Format-FolderSizePlainCount $gap)))
	return ,$lines.ToArray()
}

function Format-MetricCompareTableLines {
	param(
		$SourceEntries,
		$BackupEntries,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$fit = Get-FolderSizeFitWidth $layout
	$left = New-Object System.Collections.Generic.List[object]
	$right = New-Object System.Collections.Generic.List[object]
	foreach ($entry in (Get-FolderSizeObjectList $SourceEntries)) {
		if (Test-FolderSizeMetricEntry $entry) { [void]$left.Add((Get-MetricCompareCellLines -Entry $entry -Width $fit)) }
	}
	foreach ($entry in (Get-FolderSizeObjectList $BackupEntries)) {
		if (Test-FolderSizeMetricEntry $entry) { [void]$right.Add((Get-MetricCompareCellLines -Entry $entry -Width $fit)) }
	}
	if ($left.Count -eq 0 -and $right.Count -eq 0) { return ,@('  No differences.') }
	return Format-PairedColumnLines -Layout $layout -LeftBlocks $left -RightBlocks $right -Headers @('Source', 'Backup') -Plain:$Plain
}

function Get-CrossSideCellLines {
	param($Entry, [int]$Width, [string]$Side)

	$size = $Entry.DestLogical
	if ($Side -eq 'Source') { $size = $Entry.SourceLogical }
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add((Format-FolderSizePathCell -Path ([string]$Entry.RelativePath) -Width $Width))
	[void]$lines.Add(('{0:N0} files, {1}' -f [long]$Entry.FileCount, (Format-ByteSize ([double]$size))))
	return ,$lines.ToArray()
}

function Format-CrossTreeTableLines {
	param(
		$Entries,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$fit = Get-FolderSizeFitWidth $layout
	$onlySource = New-Object System.Collections.Generic.List[object]
	$onlyBackup = New-Object System.Collections.Generic.List[object]
	$mismatches = New-Object System.Collections.Generic.List[object]
	foreach ($entry in (Get-FolderSizeObjectList $Entries)) {
		if (-not (Test-FolderSizeCrossEntry $entry)) { continue }
		if ([string]$entry.State -eq 'OnlyInSource') {
			[void]$onlySource.Add((Get-CrossSideCellLines -Entry $entry -Width $fit -Side Source))
		}
		elseif ([string]$entry.State -eq 'OnlyInBackup') {
			[void]$onlyBackup.Add((Get-CrossSideCellLines -Entry $entry -Width $fit -Side Backup))
		}
		else {
			[void]$mismatches.Add($entry)
		}
	}
	if ($onlySource.Count -eq 0 -and $onlyBackup.Count -eq 0 -and $mismatches.Count -eq 0) {
		return ,@('  No differences.')
	}

	$lines = New-Object System.Collections.Generic.List[string]
	$headers = @('Source', 'Backup')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }
	if ($onlySource.Count -gt 0 -or $onlyBackup.Count -gt 0) {
		foreach ($row in (Format-PairedColumnLines -Layout $layout -LeftBlocks $onlySource -RightBlocks $onlyBackup -Headers $headers -Plain:$Plain -NoHeader)) {
			[void]$lines.Add($row)
		}
	}
	$started = $false
	if ($null -ne $header) { $started = $lines.Count -gt 1 }
	else { $started = $lines.Count -gt 0 }
	foreach ($entry in $mismatches) {
		if ($started) { [void]$lines.Add('') }
		$started = $true
		$path = Format-FolderSizePathCell -Path ([string]$entry.RelativePath) -Width $fit
		$count = '{0:N0}' -f [long]$entry.FileCount
		$pairs = @(
			@{ Label = 'Path'; Left = $path; Right = $path }
			@{ Label = 'Files'; Left = $count; Right = $count }
			@{ Label = 'Logical'; Left = (Format-ByteSize ([double]$entry.SourceLogical)); Right = (Format-ByteSize ([double]$entry.DestLogical)) }
		)
		foreach ($pair in $pairs) {
			foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label $pair.Label -Cells @($pair.Left, $pair.Right) -Headers $headers)) {
				[void]$lines.Add($row)
			}
		}
	}
	return ,$lines.ToArray()
}

function Format-FolderCompareTotalLines {
	param(
		$SourceResult,
		$BackupResult,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 3
	$lines = New-Object System.Collections.Generic.List[string]
	$headers = @('Source', 'Backup', 'Gap')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }

	$metrics = New-Object System.Collections.Generic.List[object]
	[void]$metrics.Add(@{ Name = 'Logical'; Kind = 'bytes'; Source = [decimal]$SourceResult.Logical; Backup = [decimal]$BackupResult.Logical })
	[void]$metrics.Add(@{ Name = 'Stored'; Kind = 'bytes'; Source = [decimal]$SourceResult.Stored; Backup = [decimal]$BackupResult.Stored })
	[void]$metrics.Add(@{ Name = 'Files'; Kind = 'count'; Source = [long]$SourceResult.Files; Backup = [long]$BackupResult.Files })
	[void]$metrics.Add(@{ Name = 'Folders'; Kind = 'count'; Source = [long]$SourceResult.Folders; Backup = [long]$BackupResult.Folders })
	[void]$metrics.Add(@{ Name = 'Unreadable'; Kind = 'count'; Source = [long](Get-FolderSizeItemCount $SourceResult.Unreadable); Backup = [long](Get-FolderSizeItemCount $BackupResult.Unreadable) })
	[void]$metrics.Add(@{ Name = 'Reparse'; Kind = 'count'; Source = [long](Get-FolderSizeItemCount $SourceResult.Reparse); Backup = [long](Get-FolderSizeItemCount $BackupResult.Reparse) })

	foreach ($metric in $metrics) {
		$gap = [decimal]$metric.Source - [decimal]$metric.Backup
		if ($metric.Kind -eq 'bytes') {
			$sourceText = Format-ByteSize ([double]$metric.Source)
			$backupText = Format-ByteSize ([double]$metric.Backup)
			$gapText = Format-FolderSizePlainCount $gap
		}
		else {
			$sourceText = '{0:N0}' -f [long]$metric.Source
			$backupText = '{0:N0}' -f [long]$metric.Backup
			$gapText = '{0:N0}' -f [long]$gap
		}
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label ([string]$metric.Name) -Cells @($sourceText, $backupText, $gapText) -Headers $headers)) {
			[void]$lines.Add($row)
		}
		if ($metric.Kind -eq 'bytes') {
			$sourceBytes = '{0:N0}' -f [decimal]$metric.Source
			$backupBytes = '{0:N0}' -f [decimal]$metric.Backup
			$gapBytes = '{0:N0}' -f $gap
			foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label 'bytes' -Cells @($sourceBytes, $backupBytes, $gapBytes) -Headers $headers)) {
				[void]$lines.Add($row)
			}
		}
	}
	return ,$lines.ToArray()
}

function Format-UnreadableTableLines {
	param(
		$SourcePaths,
		$BackupPaths,
		[int]$InnerWidth,
		[switch]$SingleTree,
		[switch]$Plain
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$sourceItems = Get-FolderSizeStringList (Select-ShallowestPaths $SourcePaths)
	if ($SingleTree) {
		$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 1
		if ($sourceItems.Count -eq 0) { [void]$lines.Add('  none') }
		else {
			foreach ($path in $sourceItems) {
				$cell = Format-FolderSizePathCell -Path $path -Width ([int]$layout.CellWidth)
				[void]$lines.Add((Format-FolderSizeTableRow -Layout $layout -Label 'Path' -Cells $cell))
			}
		}
		return ,$lines.ToArray()
	}

	$backupItems = Get-FolderSizeStringList (Select-ShallowestPaths $BackupPaths)
	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$headers = @('Source', 'Backup')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }
	$count = $sourceItems.Count
	if ($backupItems.Count -gt $count) { $count = $backupItems.Count }
	if ($count -eq 0) {
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label '' -Cells @('none', 'none') -Headers $headers)) {
			[void]$lines.Add($row)
		}
		return ,$lines.ToArray()
	}
	for ($i = 0; $i -lt $count; $i++) {
		$sourceCell = ''
		$backupCell = ''
		if ($i -lt $sourceItems.Count) {
			$sourceCell = Format-FolderSizePathCell -Path $sourceItems[$i] -Width ([int]$layout.CellWidth)
		}
		elseif ($i -eq 0) { $sourceCell = 'none' }
		if ($i -lt $backupItems.Count) {
			$backupCell = Format-FolderSizePathCell -Path $backupItems[$i] -Width ([int]$layout.CellWidth)
		}
		elseif ($i -eq 0) { $backupCell = 'none' }
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label '' -Cells @($sourceCell, $backupCell) -Headers $headers)) {
			[void]$lines.Add($row)
		}
	}
	return ,$lines.ToArray()
}

function Format-ReparseLogLines {
	param(
		$SourcePaths,
		$BackupPaths,
		[switch]$SingleTree
	)

	$lines = New-Object System.Collections.Generic.List[string]
	if ($SingleTree) {
		$paths = Get-FolderSizeStringList $SourcePaths
		$items = @($paths | Sort-Object)
		if ($items.Count -eq 0) { [void]$lines.Add('  none') }
		else {
			foreach ($path in $items) {
				[void]$lines.Add(('  {0}' -f (Format-FolderSizeRelativePath $path)))
			}
		}
	}
	else {
		foreach ($pair in @(
			@{ Label = 'Source'; Paths = $SourcePaths }
			@{ Label = 'Backup'; Paths = $BackupPaths }
		)) {
			$paths = Get-FolderSizeStringList $pair.Paths
			$items = @($paths | Sort-Object)
			if ($items.Count -eq 0) {
				[void]$lines.Add(('  {0}: none' -f $pair.Label))
			}
			else {
				foreach ($path in $items) {
					[void]$lines.Add(('  {0}: {1}' -f $pair.Label, (Format-FolderSizeRelativePath $path)))
				}
			}
		}
	}
	return ,$lines.ToArray()
}

function New-FolderSizeSectionBox {
	param(
		[int]$WindowWidth,
		[string]$Title,
		[string]$TitleStyle,
		$Rows,
		[switch]$WrapRows
	)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$titleText = Format-UiText -Text ('  ' + $Title) -Style $TitleStyle
	$body = New-Object System.Collections.Generic.List[string]
	[void]$body.Add('')
	foreach ($row in (Get-FolderSizeStringList $Rows)) { [void]$body.Add($row) }
	[void]$body.Add('')
	if ($WrapRows) {
		return Format-Box -Layout $layout -Title $titleText -Rows $body.ToArray() -WrapRows
	}
	return Format-Box -Layout $layout -Title $titleText -Rows $body.ToArray()
}

function New-FolderSizeDetailLines {
	param([int]$WindowWidth, $Detail)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$rows = Format-MetricRecordLines -Entries $Detail.Entries -InnerWidth ([int]$layout.InnerWidth)
	$capped = Get-CappedFolderSizeLines -Lines $rows -LogPath $Detail.LogPath
	return @('') + @(New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Logical vs stored' -TitleStyle Header -Rows $capped)
}

function Format-FolderCompareLogLines {
	param($Report)

	$inner = 96
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add(('Source: {0}' -f [string]$Report.Source))
	[void]$lines.Add(('Backup: {0}' -f [string]$Report.Dest))
	[void]$lines.Add('')
	[void]$lines.Add('Result')
	[void]$lines.Add(('  {0}' -f [string]$Report.Status))
	[void]$lines.Add('  Size check only. Equal logical size does not prove identical bytes.')
	if ($Report.StoredDiffers) { [void]$lines.Add('  Stored size differs from logical size.') }
	[void]$lines.Add('')
	[void]$lines.Add('Totals')
	foreach ($row in (Format-FolderCompareTotalLines -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult -InnerWidth $inner -Plain)) {
		[void]$lines.Add($row)
	}
	[void]$lines.Add('')
	[void]$lines.Add('Cross-tree')
	foreach ($row in (Format-CrossTreeTableLines -Entries $Report.Cross -InnerWidth $inner -Plain)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Logical vs stored')
	foreach ($row in (Format-MetricCompareTableLines -SourceEntries $Report.SourceMetrics -BackupEntries $Report.BackupMetrics -InnerWidth $inner -Plain)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Unreadable')
	foreach ($row in (Format-UnreadableTableLines -SourcePaths $Report.SourceUnreadable -BackupPaths $Report.BackupUnreadable -InnerWidth $inner -Plain)) {
		[void]$lines.Add($row)
	}
	[void]$lines.Add('')
	[void]$lines.Add('Reparse points skipped')
	foreach ($row in (Format-ReparseLogLines -SourcePaths $Report.SourceReparse -BackupPaths $Report.BackupReparse)) {
		[void]$lines.Add($row)
	}
	return ,$lines.ToArray()
}

function New-FolderCompareReportLines {
	param([int]$WindowWidth, $Report)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$inner = [int]$layout.InnerWidth
	$resultRows = New-Object System.Collections.Generic.List[string]
	[void]$resultRows.Add(('  ' + (Format-UiText -Text ([string]$Report.Status) -Style ([string]$Report.StatusStyle))))
	[void]$resultRows.Add('  Size check only. Equal logical size does not prove identical bytes.')
	if ($Report.StoredDiffers) { [void]$resultRows.Add('  Stored size differs from logical size.') }
	if ($Report.LogPath) { [void]$resultRows.Add(('  Log: {0}' -f [string]$Report.LogPath)) }
	else { [void]$resultRows.Add(('  Log: could not be written: {0}' -f [string]$Report.LogError)) }

	$lines = @(New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Totals' -TitleStyle Header -Rows (Format-FolderCompareTotalLines -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult -InnerWidth $inner))
	$lines += ''
	$cross = Format-CrossTreeTableLines -Entries $Report.Cross -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Cross-tree' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $cross -LogPath $Report.LogPath)
	$lines += ''
	$stored = Format-MetricCompareTableLines -SourceEntries $Report.SourceMetrics -BackupEntries $Report.BackupMetrics -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Logical vs stored' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $stored -LogPath $Report.LogPath)
	$lines += ''
	$unreadable = Format-UnreadableTableLines -SourcePaths $Report.SourceUnreadable -BackupPaths $Report.BackupUnreadable -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Unreadable' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $unreadable -LogPath $Report.LogPath)
	$lines += ''
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Result' -TitleStyle ([string]$Report.StatusStyle) -Rows $resultRows.ToArray() -WrapRows
	return $lines
}

function New-FolderCompareProgressBox {
	param(
		$Layout,
		$Source,
		$Backup,
		[string]$Status,
		$Compared,
		$Total
	)

	$table = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 2
	$headers = @('Source', 'Backup')
	$rows = New-Object System.Collections.Generic.List[string]
	[void]$rows.Add('')
	$header = Format-FolderSizeHeaderRow -Layout $table -Headers $headers
	if ($null -ne $header) { [void]$rows.Add($header) }
	$metrics = @(
		@{ Name = 'Logical'; Source = (Format-ByteSize $Source.Logical); Backup = (Format-ByteSize $Backup.Logical) }
		@{ Name = 'Stored'; Source = (Format-ByteSize $Source.Stored); Backup = (Format-ByteSize $Backup.Stored) }
		@{ Name = 'Files'; Source = ('{0:N0}' -f $Source.Files); Backup = ('{0:N0}' -f $Backup.Files) }
		@{ Name = 'Folders'; Source = ('{0:N0}' -f $Source.Folders); Backup = ('{0:N0}' -f $Backup.Folders) }
	)
	foreach ($metric in $metrics) {
		foreach ($row in (Format-FolderSizeCompareRows -Layout $table -Label ([string]$metric.Name) -Cells @($metric.Source, $metric.Backup) -Headers $headers)) {
			[void]$rows.Add($row)
		}
	}
	[void]$rows.Add('')
	$sourcePath = Format-UiPath -Path $Source.CurrentPath -Width ([int]$table.CellWidth)
	$backupPath = Format-UiPath -Path $Backup.CurrentPath -Width ([int]$table.CellWidth)
	foreach ($row in (Format-FolderSizeCompareRows -Layout $table -Label 'Path' -Cells @($sourcePath, $backupPath) -Headers $headers)) {
		[void]$rows.Add($row)
	}
	if ($null -ne $Total -and $null -ne $Compared) {
		[void]$rows.Add('')
		[void]$rows.Add((Format-FolderCompareBar -Layout $Layout -Done ([long]$Compared) -Total ([long]$Total)))
	}
	elseif (-not [string]::IsNullOrWhiteSpace($Status)) {
		[void]$rows.Add('')
		[void]$rows.Add((' ' + $Status))
	}
	[void]$rows.Add('')
	$title = Format-UiText -Text ' Comparing' -Style Progress
	return Format-Box -Layout $Layout -Title $title -Rows $rows.ToArray()
}

function New-FolderCompareScreenLines {
	param([int]$WindowWidth, $Progress)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	return @('') + @(New-FolderCompareProgressBox -Layout $layout -Source $Progress.Source -Backup $Progress.Backup -Status $Progress.Status -Compared $Progress.Compared -Total $Progress.Total)
}

function Get-CappedFolderSizeLines {
	param(
		[string[]]$Lines,
		[string]$LogPath
	)

	$rows = @($Lines | Where-Object { $null -ne $_ })
	if ($rows.Count -le $script:FolderSizeScreenLineCap) { return $rows }
	$shown = @($rows | Select-Object -First $script:FolderSizeScreenLineCap)
	$remaining = $rows.Count - $script:FolderSizeScreenLineCap
	$location = if ([string]::IsNullOrWhiteSpace($LogPath)) { 'the log could not be written' } else { $LogPath }
	$shown += ('  {0:N0} more lines in {1}' -f $remaining, $location)
	return $shown
}

function Write-FolderSizeReportFile {
	param(
		[string]$Directory,
		[string]$Prefix,
		[string[]]$Lines
	)

	$name = '{0}-{1}-{2}.txt' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
	$path = Join-Path $Directory $name
	[void][System.IO.Directory]::CreateDirectory($Directory)
	$utf8 = New-Object System.Text.UTF8Encoding $false
	[System.IO.File]::WriteAllLines($path, [string[]]@($Lines), $utf8)
	return $path
}

function New-FolderSizeProgressLayout {
	param([int]$WindowWidth)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$layout | Add-Member -NotePropertyMembers @{
		SizeStr = ' Size:    '
		StoredStr = ' Stored:  '
		FilesStr = ' Files:   '
		FoldersStr = ' Folders: '
		PathStr = ' Path:    '
	} -PassThru
}

function New-FolderSizeProgressBox {
	param(
		$Layout,
		[string]$ItemPath,
		[long]$Files,
		[long]$Folders,
		[uint64]$Logical,
		[uint64]$Stored
	)

	$availableSpace = $Layout.InnerWidth - (Get-VisibleTextLength $Layout.PathStr) - 1
	$ItemPath = Format-UiPath -Path $ItemPath -Width $availableSpace
	$title = Format-UiText -Text ' Scanning' -Style Progress

	return Format-Box -Layout $Layout -Title $title -Rows @(
		''
		($Layout.SizeStr + (Format-ByteSize $Logical))
		($Layout.StoredStr + (Format-ByteSize $Stored))
		($Layout.FilesStr + ('{0:N0}' -f $Files))
		($Layout.FoldersStr + ('{0:N0}' -f $Folders))
		''
		($Layout.PathStr + $ItemPath)
		''
	)
}

function New-FolderSizeScreenLines {
	param([int]$WindowWidth, $Progress)

	$layout = New-FolderSizeProgressLayout -WindowWidth $WindowWidth
	return @('') + @(New-FolderSizeProgressBox -Layout $layout -ItemPath $Progress.CurrentPath -Files $Progress.Files -Folders $Progress.Folders -Logical $Progress.Logical -Stored $Progress.Stored)
}

function New-FolderSizeSnapshot {
	param([string]$CurrentPath)

	return @{
		Files = [long]0
		Folders = [long]0
		Logical = [uint64]0
		Stored = [uint64]0
		CurrentPath = $CurrentPath
	}
}

# =============================================================================
#  Scan worker
# =============================================================================

function Start-FolderSizeScan {
	param(
		[string]$Path,
		[hashtable]$Shared,
		[switch]$CollectFiles
	)

	Initialize-FolderSizeNative
	$worker = [PowerShell]::Create()
	try {
		# A new runspace cannot call the functions in this file. The walk,
		# relative paths, and directory stats stay inside this scriptblock.
		# Nothing in the worker writes to the console.
		[void]$worker.AddScript({
			param($ScanPath, $Shared, $Interval, $CollectFiles)

			function ConvertTo-WorkerLongPath {
				param([string]$Path)
				if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { return $Path }
				if ($Path.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
					return '\\?\UNC\' + $Path.TrimStart('\')
				}
				return '\\?\' + $Path
			}

			function Get-WorkerComparablePath {
				param([string]$Path)
				if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
					return '\\' + $Path.Substring(8)
				}
				if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
					return $Path.Substring(4)
				}
				return $Path
			}

			function Get-WorkerRelativePath {
				param([string]$FullName)
				$display = (Get-WorkerComparablePath $FullName).TrimEnd('\')
				if ($display.Equals($script:WorkerRootDisplay, [StringComparison]::OrdinalIgnoreCase)) { return '' }
				$prefix = $script:WorkerRootDisplay + '\'
				if ($display.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
					return $display.Substring($prefix.Length)
				}
				return $display
			}

			function Publish-WorkerSnapshot {
				$script:ScanShared.Snapshot = @{
					Files = $script:ScanFiles
					Folders = $script:ScanFolders
					Logical = $script:ScanLogical
					Stored = $script:ScanStored
					CurrentPath = $script:ScanCurrentPath
				}
			}

			function Update-WorkerClock {
				if ($script:ScanClock.ElapsedMilliseconds -ge $script:ScanInterval) {
					Publish-WorkerSnapshot
					$script:ScanClock.Restart()
				}
			}

			function Add-WorkerMetric {
				param([string]$RelativeFile, [uint64]$Logical, [uint64]$Stored)
				$differs = $Logical -ne $Stored
				$dirs = New-Object System.Collections.Generic.List[string]
				[void]$dirs.Add('')
				$parent = ''
				$slash = $RelativeFile.LastIndexOf('\')
				if ($slash -ge 0) { $parent = $RelativeFile.Substring(0, $slash) }
				if ($parent.Length -gt 0) {
					$built = ''
					foreach ($part in $parent.Split('\')) {
						if ($built.Length -gt 0) { $built = $built + '\' + $part }
						else { $built = $part }
						[void]$dirs.Add($built)
					}
				}
				foreach ($dir in $dirs) {
					if (-not $script:Stats.ContainsKey($dir)) {
						$script:Stats[$dir] = @{
							FileCount = [long]0
							DifferCount = [long]0
							Logical = [uint64]0
							Stored = [uint64]0
						}
					}
					$node = $script:Stats[$dir]
					$node.FileCount = [long]$node.FileCount + 1
					$node.Logical = [uint64]([decimal]$node.Logical + [decimal]$Logical)
					$node.Stored = [uint64]([decimal]$node.Stored + [decimal]$Stored)
					if ($differs) { $node.DifferCount = [long]$node.DifferCount + 1 }
				}
				if ($differs) {
					[void]$script:Differences.Add(@{
						RelativePath = $RelativeFile
						Logical = $Logical
						Stored = $Stored
					})
				}
				if ($null -ne $script:FilesByPath) {
					$script:FilesByPath[$RelativeFile] = @{ Logical = $Logical; Stored = $Stored }
				}
			}

			function Measure-WorkerFile {
				param($Entry, [string]$FullName, [bool]$IsReparse)
				try {
					$native = ConvertTo-WorkerLongPath $FullName
					# Directory junctions are skipped before this runs. A file
					# reparse point is skipped only when it is a symlink, so a
					# cloud placeholder is still measured.
					if ($IsReparse -and [FolderSizeNative]::IsSymlinkOrJunction($native)) {
						[void]$script:ReparsePaths.Add((Get-WorkerRelativePath $FullName))
						return
					}
					$stored = [uint64]([FolderSizeNative]::StoredSize($native))
					$logical = [uint64]$Entry.Length
					$relative = Get-WorkerRelativePath $FullName
					$script:ScanFiles = [long]$script:ScanFiles + 1
					$script:ScanLogical = [uint64]([decimal]$script:ScanLogical + [decimal]$logical)
					$script:ScanStored = [uint64]([decimal]$script:ScanStored + [decimal]$stored)
					Add-WorkerMetric -RelativeFile $relative -Logical $logical -Stored $stored
				}
				catch {
					[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $FullName))
				}
			}

			$script:ScanFiles = [long]0
			$script:ScanFolders = [long]0
			$script:ScanLogical = [uint64]0
			$script:ScanStored = [uint64]0
			$script:ScanCurrentPath = $ScanPath
			$script:Stats = @{}
			$script:Differences = New-Object System.Collections.Generic.List[object]
			$script:ReparsePaths = New-Object System.Collections.Generic.List[string]
			$script:UnreadablePaths = New-Object System.Collections.Generic.List[string]
			$script:FilesByPath = $null
			if ($CollectFiles) { $script:FilesByPath = @{} }
			$script:WorkerRootDisplay = (Get-WorkerComparablePath $ScanPath).TrimEnd('\')
			$script:ScanShared = $Shared
			$script:ScanInterval = $Interval
			$script:ScanClock = [System.Diagnostics.Stopwatch]::StartNew()

			$walk = $true
			try {
				# DirectoryInfo rejects the \\?\ prefix on .NET Framework. Get-Item accepts it.
				$rootItem = Get-Item -LiteralPath $ScanPath -Force -ErrorAction Stop
				if (-not $rootItem.PSIsContainer) {
					[void]$script:UnreadablePaths.Add('')
					$walk = $false
				}
				elseif (([int]$rootItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
					[void]$script:ReparsePaths.Add('')
					$walk = $false
				}
			}
			catch {
				[void]$script:UnreadablePaths.Add('')
				$walk = $false
			}

			if ($walk) {
				$pending = New-Object 'System.Collections.Generic.Stack[string]'
				$pending.Push($ScanPath)
				while ($pending.Count -gt 0) {
					$dir = $pending.Pop()
					$script:ScanCurrentPath = $dir
					Update-WorkerClock
					try {
						# EnumerateFileSystemInfos treats \\?\ as an illegal path and
						# would leave every total at 0. Get-ChildItem -LiteralPath does not.
						foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
							$fullName = ConvertTo-WorkerLongPath $entry.FullName
							$script:ScanCurrentPath = $fullName
							$isReparse = $false
							try {
								$isReparse = (([int]$entry.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
							}
							catch {
								[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $fullName))
								Update-WorkerClock
								continue
							}
							if ($entry.PSIsContainer) {
								if ($isReparse) {
									[void]$script:ReparsePaths.Add((Get-WorkerRelativePath $fullName))
								}
								else {
									$script:ScanFolders = [long]$script:ScanFolders + 1
									$pending.Push($fullName)
								}
							}
							else {
								Measure-WorkerFile -Entry $entry -FullName $fullName -IsReparse $isReparse
							}
							Update-WorkerClock
						}
					}
					catch {
						[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $dir))
					}
				}
			}

			Publish-WorkerSnapshot
			$script:ScanShared.Result = @{
				Logical = $script:ScanLogical
				Stored = $script:ScanStored
				Files = $script:ScanFiles
				Folders = $script:ScanFolders
				Reparse = $script:ReparsePaths.ToArray()
				Unreadable = $script:UnreadablePaths.ToArray()
				DirectoryStats = $script:Stats
				Differences = $script:Differences.ToArray()
				FilesByPath = $script:FilesByPath
			}
		}).AddArgument($Path).AddArgument($Shared).AddArgument($script:FolderSizeProgressIntervalMs).AddArgument([bool]$CollectFiles)
		return @{ Worker = $worker; Pending = $worker.BeginInvoke() }
	}
	catch {
		$worker.Dispose()
		throw
	}
}

function Stop-FolderSizeScan {
	param($Scan)

	if ($null -eq $Scan) { return }
	try {
		if (-not $Scan.Pending.IsCompleted) { $Scan.Worker.Stop() }
	}
	finally { $Scan.Worker.Dispose() }
}

function Update-FolderSizeScanDisplay {
	param(
		$Scan,
		[hashtable]$Shared,
		$State,
		$Block
	)

	if ($null -eq $Scan) { return $State }
	$snapshot = $Shared.Snapshot
	if (-not [object]::ReferenceEquals($State, $snapshot)) {
		$State = $snapshot
		$Block.Data = $State
		$script:UiScreen.Dirty = $true
	}
	return $State
}

# =============================================================================
#  Single-folder tool
# =============================================================================

function Invoke-FolderSizeTool {
	Reset-UiScreen

	$title = 'Folder Size Counter'
	Show-PathHelp -Title $title

	$inputPath = Read-FolderPath -Prompt 'Path' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
	}
	if ($null -eq $inputPath) {
		return
	}

	$path = ConvertTo-FolderSizeLongPath $inputPath
	Reset-UiScreen
	$state = New-FolderSizeSnapshot -CurrentPath $path
	$shared = [hashtable]::Synchronized(@{ Snapshot = $state })
	$block = @{ Kind = 'Custom'; Builder = ${function:New-FolderSizeScreenLines}; Data = $state }
	Add-UiBlock $block
	$scan = $null

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$scan = Start-FolderSizeScan -Path $path -Shared $shared
		while (-not $scan.Pending.IsCompleted) {
			$state = Update-FolderSizeScanDisplay -Scan $scan -Shared $shared -State $state -Block $block
			# Check for resizing even if a directory or network read is waiting.
			Update-UiScreen
			Start-Sleep -Milliseconds $script:FolderSizeProgressIntervalMs
		}
		[void]$scan.Worker.EndInvoke($scan.Pending)
		$state = $shared.Snapshot
		$block.Data = $state
		Update-UiScreen -Force
		$result = $shared.Result
		if ($null -eq $result) {
			throw 'The folder scan finished without a result.'
		}

		$metricEntries = Get-FolderSizeRollup -DirectoryStats $result.DirectoryStats -Differences $result.Differences
		$gap = [decimal]$result.Logical - [decimal]$result.Stored
		$summary = @(
			('  Path:          {0}' -f $inputPath)
			('  Logical size:  {0}' -f (Format-ByteCount $result.Logical))
			('  Stored size:   {0}' -f (Format-ByteCount $result.Stored))
			('  Gap:           {0}' -f (Format-SignedByteCount $gap))
			('  Files:         {0:N0}' -f $result.Files)
			('  Folders:       {0:N0}' -f $result.Folders)
			('  Unreadable:    {0:N0}' -f (Get-FolderSizeItemCount $result.Unreadable))
			('  Reparse:       {0:N0}' -f (Get-FolderSizeItemCount $result.Reparse))
		)
		$logLines = New-Object System.Collections.Generic.List[string]
		foreach ($row in $summary) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Logical vs stored')
		foreach ($row in (Format-MetricRecordLines -Entries $metricEntries -InnerWidth 96)) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Unreadable')
		foreach ($row in (Format-UnreadableTableLines -SourcePaths $result.Unreadable -InnerWidth 96 -SingleTree -Plain)) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Reparse points skipped')
		foreach ($row in (Format-ReparseLogLines -SourcePaths $result.Reparse -SingleTree)) { [void]$logLines.Add([string]$row) }
		$logPath = $null
		$logError = $null
		try {
			$logPath = Write-FolderSizeReportFile -Directory $script:FolderSizeLogRoot -Prefix 'folder-size' -Lines $logLines.ToArray()
		}
		catch {
			$logError = $_.Exception.Message
		}
		if ($logPath) { $summary += ('  Log:           {0}' -f $logPath) }
		else { $summary += ('  Log:           could not be written: {0}' -f $logError) }

		Set-UiCursorVisible -Visible $true
		Write-UiLine
		Show-InfoBox -Title 'Folder Size' -Rows $summary
		Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderSizeDetailLines}; Data = @{ Entries = $metricEntries; LogPath = $logPath } }
		Update-UiScreen -Force
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage 'Fatal error:'
		Write-ErrorMessage $_.Exception.Message
	}
	finally {
		try { Stop-FolderSizeScan $scan }
		finally { Set-UiCursorVisible -Visible $true }
	}

	return 'Completed'
}

# =============================================================================
#  Post-copy comparison
# =============================================================================

function Invoke-FolderSizeComparison {
	param(
		[string]$Source,
		[string]$Dest,
		[string]$LogFolder
	)

	Reset-UiScreen
	$sourcePath = ConvertTo-FolderSizeLongPath $Source
	$destPath = ConvertTo-FolderSizeLongPath $Dest
	$sourceState = New-FolderSizeSnapshot -CurrentPath $sourcePath
	$backupState = New-FolderSizeSnapshot -CurrentPath $destPath
	$sharedSource = [hashtable]::Synchronized(@{ Snapshot = $sourceState })
	$sharedBackup = [hashtable]::Synchronized(@{ Snapshot = $backupState })
	$progress = @{ Source = $sourceState; Backup = $backupState; Status = ''; Compared = $null; Total = $null }
	$block = @{ Kind = 'Custom'; Builder = ${function:New-FolderCompareScreenLines}; Data = $progress }
	Add-UiBlock $block
	$sourceScan = $null
	$backupScan = $null

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$sourceScan = Start-FolderSizeScan -Path $sourcePath -Shared $sharedSource -CollectFiles
		$backupScan = Start-FolderSizeScan -Path $destPath -Shared $sharedBackup -CollectFiles
		while (-not $sourceScan.Pending.IsCompleted -or -not $backupScan.Pending.IsCompleted) {
			$sourceSnapshot = $sharedSource.Snapshot
			$backupSnapshot = $sharedBackup.Snapshot
			if (-not [object]::ReferenceEquals($progress.Source, $sourceSnapshot) -or -not [object]::ReferenceEquals($progress.Backup, $backupSnapshot)) {
				$progress.Source = $sourceSnapshot
				$progress.Backup = $backupSnapshot
				$script:UiScreen.Dirty = $true
			}
			Update-UiScreen
			Start-Sleep -Milliseconds $script:FolderSizeProgressIntervalMs
		}

		$sourceFailure = $null
		try { [void]$sourceScan.Worker.EndInvoke($sourceScan.Pending) }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { $sourceFailure = $_ }
		try { [void]$backupScan.Worker.EndInvoke($backupScan.Pending) }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { if ($null -eq $sourceFailure) { $sourceFailure = $_ } }
		if ($null -ne $sourceFailure) { throw $sourceFailure }

		$progress.Source = $sharedSource.Snapshot
		$progress.Backup = $sharedBackup.Snapshot
		$script:FolderCompareBuildProgress = $progress
		$sourceResult = $sharedSource.Result
		$backupResult = $sharedBackup.Result
		if ($null -eq $sourceResult -or $null -eq $backupResult) {
			throw 'A folder scan finished without a result.'
		}

		$sourceCount = 0
		$backupCount = 0
		if ($null -ne $sourceResult.FilesByPath) { $sourceCount = $sourceResult.FilesByPath.Count }
		if ($null -ne $backupResult.FilesByPath) { $backupCount = $backupResult.FilesByPath.Count }
		Update-FolderCompareBuildStatus -Done 0 -Total ([long]$sourceCount + [long]$backupCount)
		$crossEntries = Get-CrossTreeRollup -SourceFiles $sourceResult.FilesByPath -DestFiles $backupResult.FilesByPath -SourceUnreadable $sourceResult.Unreadable -DestUnreadable $backupResult.Unreadable -OnProgress {
			param($Done, $Total)
			Update-FolderCompareBuildStatus -Done $Done -Total $Total
		}
		$sourceMetrics = Get-FolderSizeRollup -DirectoryStats $sourceResult.DirectoryStats -Differences $sourceResult.Differences
		$backupMetrics = Get-FolderSizeRollup -DirectoryStats $backupResult.DirectoryStats -Differences $backupResult.Differences
		$sourceStoredGap = [decimal]$sourceResult.Logical - [decimal]$sourceResult.Stored
		$backupStoredGap = [decimal]$backupResult.Logical - [decimal]$backupResult.Stored
		$unreadableCount = (Get-FolderSizeItemCount $sourceResult.Unreadable) + (Get-FolderSizeItemCount $backupResult.Unreadable)
		$crossCount = 0
		foreach ($entry in (Get-FolderSizeObjectList $crossEntries)) {
			if (Test-FolderSizeCrossEntry $entry) { $crossCount++ }
		}
		if ($crossCount -gt 0) {
			$status = 'Source and backup differ.'
			$statusStyle = 'Error'
		}
		elseif ($unreadableCount -gt 0) {
			$status = 'Sizes match for items that could be read. Some items were skipped.'
			$statusStyle = 'Error'
		}
		else {
			$status = 'Logical sizes match.'
			$statusStyle = 'Success'
		}

		$logDirectory = if ([string]::IsNullOrWhiteSpace($LogFolder)) { $script:FolderSizeLogRoot } else { $LogFolder }
		$report = @{
			Status = $status
			StatusStyle = $statusStyle
			StoredDiffers = ($sourceStoredGap -ne 0 -or $backupStoredGap -ne 0)
			Source = $Source
			Dest = $Dest
			SourceResult = $sourceResult
			BackupResult = $backupResult
			Cross = $crossEntries
			SourceMetrics = $sourceMetrics
			BackupMetrics = $backupMetrics
			SourceUnreadable = $sourceResult.Unreadable
			BackupUnreadable = $backupResult.Unreadable
			SourceReparse = $sourceResult.Reparse
			BackupReparse = $backupResult.Reparse
			LogPath = $null
			LogError = $null
		}
		Update-FolderCompareBuildStatus -Status 'Writing the log'
		$logPath = $null
		$logError = $null
		try {
			$logPath = Write-FolderSizeReportFile -Directory $logDirectory -Prefix 'folder-compare' -Lines (Format-FolderCompareLogLines -Report $report)
		}
		catch {
			$logError = $_.Exception.Message
		}
		$report.LogPath = $logPath
		$report.LogError = $logError

		Update-FolderCompareBuildStatus -Status 'Drawing the report'
		$progress.Status = ''
		$script:FolderCompareBuildProgress = $null
		$script:UiScreen.Dirty = $true
		Set-UiCursorVisible -Visible $true
		Write-UiLine
		Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderCompareReportLines}; Data = $report }
		Update-UiScreen -Force
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage 'Fatal error:'
		Write-ErrorMessage $_.Exception.Message
	}
	finally {
		try {
			Stop-FolderSizeScan $sourceScan
			Stop-FolderSizeScan $backupScan
		}
		finally { Set-UiCursorVisible -Visible $true }
	}
}

function Invoke-FolderSizeCompareTool {
	Reset-UiScreen

	$title = 'Folder Size Comparison'
	Show-PathHelp -Title $title

	$source = Read-FolderPath -Prompt 'Source' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
	}
	if ($null -eq $source) {
		return
	}

	Write-UiLine

	$dest = Read-FolderPath -Prompt 'Destination' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
		Write-UiLine -Text "Source: $source"
		Write-UiLine
	}
	if ($null -eq $dest) {
		return
	}

	Invoke-FolderSizeComparison -Source $source -Dest $dest
	return 'Completed'
}
