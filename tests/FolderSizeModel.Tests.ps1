BeforeAll {
	. (Join-Path $PSScriptRoot 'TestSetup.ps1')

	function New-TestMetricStats {
		param([object[]]$Files)

		$stats = @{}
		$differences = New-Object System.Collections.Generic.List[object]
		foreach ($file in $Files) {
			$differs = $file[1] -ne $file[2]
			foreach ($dir in (Get-FolderSizeAncestorDirectories $file[0])) {
				if (-not $stats.ContainsKey($dir)) {
					$stats[$dir] = @{ FileCount = [long]0; DifferCount = [long]0; Logical = [uint64]0; Stored = [uint64]0 }
				}
				$node = $stats[$dir]
				$node.FileCount++
				$node.Logical += [uint64]$file[1]
				$node.Stored += [uint64]$file[2]
				if ($differs) { $node.DifferCount++ }
			}
			if ($differs) {
				[void]$differences.Add(@{ RelativePath = $file[0]; Logical = [uint64]$file[1]; Stored = [uint64]$file[2] })
			}
		}
		return @{ Stats = $stats; Differences = $differences.ToArray() }
	}

	function New-TestFileTable {
		param([hashtable]$Sizes)

		$table = @{}
		foreach ($key in $Sizes.Keys) { $table[$key] = @{ Logical = [uint64]$Sizes[$key]; Stored = [uint64]$Sizes[$key] } }
		return $table
	}
}

Describe 'ConvertTo-FolderSizeLongPath' {
	It 'prefixes a local path' {
		ConvertTo-FolderSizeLongPath 'C:\Users\a' | Should -BeExactly '\\?\C:\Users\a'
	}
	It 'prefixes a UNC path' {
		ConvertTo-FolderSizeLongPath '\\server\share\x' | Should -BeExactly '\\?\UNC\server\share\x'
	}
	It 'prefixes a UNC path whose server name is one character' -Skip {
		ConvertTo-FolderSizeLongPath '\\s\share\x' | Should -BeExactly '\\?\UNC\s\share\x'
	}
	It 'leaves an already prefixed path alone' {
		ConvertTo-FolderSizeLongPath '\\?\C:\a' | Should -BeExactly '\\?\C:\a'
	}
	It 'keeps a drive root short: <Path>' -ForEach @(
		@{ Path = 'E:' }, @{ Path = 'E:\' }, @{ Path = '\\?\E:' }, @{ Path = '\\?\E:\' }
	) {
		ConvertTo-FolderSizeLongPath $Path | Should -BeExactly 'E:\'
	}
}

Describe 'Get-FolderSizeAncestorDirectories' {
	It 'lists the root and every parent folder' {
		$result = Get-FolderSizeAncestorDirectories 'a\b\c.txt'
		$result | Should -Be @('', 'a', 'a\b')
	}
	It 'returns only the root for a top-level file' {
		$result = Get-FolderSizeAncestorDirectories 'c.txt'
		$result.Count | Should -Be 1
		$result[0] | Should -BeExactly ''
	}
}

Describe 'Test-FolderSizePathCovered' {
	It 'treats the root as covering everything' {
		Test-FolderSizePathCovered -RelativePath 'a\b' -Ancestors @('') | Should -BeTrue
	}
	It 'matches the path itself and its children, ignoring case' {
		Test-FolderSizePathCovered -RelativePath 'Secret' -Ancestors @('secret') | Should -BeTrue
		Test-FolderSizePathCovered -RelativePath 'Secret\x.txt' -Ancestors @('secret') | Should -BeTrue
	}
	It 'does not match a sibling with the same prefix' {
		Test-FolderSizePathCovered -RelativePath 'SecretPlans\x.txt' -Ancestors @('Secret') | Should -BeFalse
	}
	It 'covers nothing when there are no ancestors' {
		Test-FolderSizePathCovered -RelativePath 'a' -Ancestors @() | Should -BeFalse
	}
}

Describe 'Get-FolderSizeRollup' {
	It 'lists the shallowest uniform folder and single differing files' {
		$data = New-TestMetricStats @(
			, @('a\x.txt', 10, 10)
			, @('b\y.txt', 10, 5)
			, @('b\z.txt', 10, 5)
			, @('c\d\w.txt', 10, 5)
			, @('c\v.txt', 10, 10)
			, @('e\f.txt', 10, 10)
			, @('e\g.txt', 8, 4)
		)
		$entries = Get-FolderSizeRollup -DirectoryStats $data.Stats -Differences $data.Differences
		$entries.RelativePath | Should -Be @('b', 'c\d', 'e\g.txt')
		$entries[0].FileCount | Should -Be 2
		$entries[0].Logical | Should -Be 20
		$entries[0].Stored | Should -Be 10
		$entries[2].FileCount | Should -Be 1
	}
	It 'reports the whole tree once when every file differs' {
		$data = New-TestMetricStats @(
			, @('a\x.txt', 10, 5)
			, @('b\y.txt', 6, 3)
		)
		$entries = Get-FolderSizeRollup -DirectoryStats $data.Stats -Differences $data.Differences
		$entries.Count | Should -Be 1
		$entries[0].RelativePath | Should -BeExactly ''
		$entries[0].FileCount | Should -Be 2
	}
	It 'returns nothing when logical and stored sizes match' {
		$data = New-TestMetricStats @(
			, @('a\x.txt', 10, 10)
		)
		(Get-FolderSizeRollup -DirectoryStats $data.Stats -Differences $data.Differences).Count | Should -Be 0
	}
}

Describe 'Get-CrossTreeRollup' {
	It 'groups uniform folders and keeps mismatches' {
		$source = New-TestFileTable @{ 'a\1.txt' = 10; 'a\2.txt' = 10; 'b\1.txt' = 5; 'c\1.txt' = 7; 'm\same.txt' = 1; 'm\diff.txt' = 2 }
		$backup = New-TestFileTable @{ 'b\1.txt' = 6; 'c\1.txt' = 7; 'd\1.txt' = 3; 'm\same.txt' = 1; 'm\diff.txt' = 9 }
		$entries = Get-CrossTreeRollup -SourceFiles $source -DestFiles $backup
		$entries.RelativePath | Should -Be @('a', 'b', 'd', 'm\diff.txt')
		$entries.State | Should -Be @('OnlyInSource', 'LogicalMismatch', 'OnlyInBackup', 'LogicalMismatch')
		$entries[0].FileCount | Should -Be 2
		$entries[0].SourceLogical | Should -Be 20
		$entries[3].SourceLogical | Should -Be 2
		$entries[3].DestLogical | Should -Be 9
	}
	It 'matches paths without regard to case' {
		$source = New-TestFileTable @{ 'Docs\A.txt' = 4 }
		$backup = New-TestFileTable @{ 'docs\a.txt' = 4 }
		(Get-CrossTreeRollup -SourceFiles $source -DestFiles $backup).Count | Should -Be 0
	}
	It 'does not report files under an unreadable folder on the other side' {
		$source = New-TestFileTable @{ 'Secret\x.txt' = 1; 'Open\y.txt' = 1 }
		$backup = New-TestFileTable @{ 'Open\y.txt' = 1; 'Locked\z.txt' = 1 }
		$entries = Get-CrossTreeRollup -SourceFiles $source -DestFiles $backup -DestUnreadable @('Secret') -SourceUnreadable @('Locked')
		$entries.Count | Should -Be 0
	}
	It 'reports progress for every file' {
		$source = New-TestFileTable @{ 'a.txt' = 1 }
		$backup = New-TestFileTable @{ 'a.txt' = 1; 'b.txt' = 2 }
		$script:calls = @()
		[void](Get-CrossTreeRollup -SourceFiles $source -DestFiles $backup -OnProgress { param($Done, $Total) $script:calls += "$Done/$Total" })
		$script:calls[-1] | Should -BeExactly '3/3'
	}
}
