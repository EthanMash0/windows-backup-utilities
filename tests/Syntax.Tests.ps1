BeforeDiscovery {
	$repo = Split-Path -Parent $PSScriptRoot
	$script:SourceFiles = @(
		Get-ChildItem -Path $repo -Recurse -Filter *.ps1 |
			Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
			ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
	)
}

Describe 'Source file <Name>' -ForEach $script:SourceFiles {
	It 'parses without errors' {
		$tokens = $null
		$errors = $null
		[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
		$errors | Should -BeNullOrEmpty
	}

	It 'has no non-ASCII characters outside comments' {
		# Windows PowerShell 5.1 reads a file without a BOM as ANSI.
		$bytes = [System.IO.File]::ReadAllBytes($Path)
		$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
		if ($hasBom) { return }
		$tokens = $null
		$errors = $null
		[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
		$offenders = @($tokens | Where-Object {
			$_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -match '[^\x00-\x7F]'
		} | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Text })
		$offenders | Should -BeNullOrEmpty
	}

	It 'uses syntax available in Windows PowerShell 5.1' {
		$settings = @{
			IncludeRules = @('PSUseCompatibleSyntax')
			Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
		}
		$findings = @(Invoke-ScriptAnalyzer -Path $Path -Settings $settings | ForEach-Object { 'line {0}: {1}' -f $_.Line, $_.Message })
		$findings | Should -BeNullOrEmpty
	}
}
