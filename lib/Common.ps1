function Show-PathHelp {
	param(
		[string]$Title
	)

	Write-UiLine
	Show-InfoBox -Title $Title -TrailingBlank -Rows @(
		(Format-UiText -Text "  Enter a local path like:" -Style Secondary)
		"    D:\Users\ethanmash"
		""
		(Format-UiText -Text "  Or a network path like:" -Style Secondary)
		"    \\server\share\folder"
	)
}

function Test-FolderPath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[switch]$MustExist
	)

	if (Test-Path -LiteralPath $Path -PathType Container) {
		return $true
	}

	if ($MustExist) {
		return $false
	}

	# Destination may not exist yet. Accept it when an ancestor folder exists
	# so Robocopy can create the final directory.
	if (Test-Path -LiteralPath $Path) {
		return $false
	}

	# Split-Path -LiteralPath -Parent is not valid in Windows PowerShell 5.1.
	$parent = [System.IO.Path]::GetDirectoryName($Path)
	while (-not [string]::IsNullOrWhiteSpace($parent)) {
		if (Test-Path -LiteralPath $parent -PathType Container) {
			return $true
		}

		if (Test-Path -LiteralPath $parent) {
			return $false
		}

		$next = [System.IO.Path]::GetDirectoryName($parent)
		if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $parent) {
			break
		}

		$parent = $next
	}

	return $false
}

function Read-FolderPath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Prompt,

		[switch]$MustExist,

		[switch]$AllowEmpty,

		[scriptblock]$RetryDraw
	)

	while ($true) {
		$value = Read-UiInput -Prompt $Prompt
		$value = $value.Trim().Trim('"').TrimEnd('\')

		if ([string]::IsNullOrWhiteSpace($value)) {
			if (-not $AllowEmpty) {
				Write-ErrorMessage "No $($Prompt.ToLower()) entered."
			}

			return $null
		}

		if (Test-FolderPath -Path $value -MustExist:$MustExist) {
			return $value
		}

		if ($MustExist) {
			$errorMessage = "$Prompt folder does not exist: $value"
		} else {
			$errorMessage = "$Prompt folder does not exist and cannot be created: $value"
		}

		if ($RetryDraw) {
			& $RetryDraw
		}

		Write-ErrorMessage $errorMessage
		Write-UiLine
	}
}

function Format-ByteSize {
	param(
		[Parameter(Mandatory = $true)]
		[double]$Bytes
	)

	if ($Bytes -ge 1GB) {
		return ('{0:N2} GB' -f ($Bytes / 1GB))
	}

	if ($Bytes -ge 1MB) {
		return ('{0:N2} MB' -f ($Bytes / 1MB))
	}

	return ('{0:N2} KB' -f ($Bytes / 1KB))
}
