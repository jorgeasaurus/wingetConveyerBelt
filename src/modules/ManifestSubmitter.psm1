#Requires -Version 5.1

function Install-WinGetCreate {
    <#
    .SYNOPSIS
        Downloads and installs the wingetcreate CLI tool.

    .DESCRIPTION
        Checks whether wingetcreate is already available in PATH or at the
        specified install path. If not found, downloads the latest release
        from the official Microsoft endpoint. Only supported on Windows.

    .PARAMETER InstallPath
        Directory where wingetcreate.exe will be saved.
        Defaults to "$env:TEMP\wingetcreate".

    .EXAMPLE
        $exe = Install-WinGetCreate
        # Returns the full path to wingetcreate.exe

    .EXAMPLE
        $exe = Install-WinGetCreate -InstallPath 'C:\Tools\wingetcreate'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$InstallPath = "$env:TEMP\wingetcreate"
    )

    if ($env:OS -ne 'Windows_NT' -and -not $IsWindows) {
        Write-Warning 'wingetcreate only runs on Windows. Skipping installation.'
        return $null
    }

    # Check PATH first
    $existing = Get-Command 'wingetcreate' -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "wingetcreate found in PATH: $($existing.Source)"
        return $existing.Source
    }

    $exePath = Join-Path $InstallPath 'wingetcreate.exe'

    if (Test-Path $exePath) {
        Write-Verbose "wingetcreate found at: $exePath"
        return $exePath
    }

    Write-Verbose "Downloading wingetcreate to $InstallPath ..."

    if (-not (Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }

    $downloadUrl = 'https://aka.ms/wingetcreate/latest'

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $exePath -UseBasicParsing
        Write-Verbose "wingetcreate downloaded to: $exePath"
    }
    catch {
        throw "Failed to download wingetcreate from $downloadUrl : $_"
    }

    return $exePath
}

function Resolve-InstallerUrls {
    <#
    .SYNOPSIS
        Replaces version placeholders in installer URL templates.

    .DESCRIPTION
        Takes an array of URL templates containing {{version}} placeholders
        and replaces each occurrence with the supplied version string.

    .PARAMETER UrlTemplates
        One or more URL strings that may contain {{version}} placeholders.

    .PARAMETER Version
        The version string to substitute into the templates.

    .EXAMPLE
        Resolve-InstallerUrls -UrlTemplates 'https://example.com/app/{{version}}/setup.exe' -Version '1.2.3'
        # Returns: https://example.com/app/1.2.3/setup.exe

    .EXAMPLE
        $urls = @(
            'https://cdn.example.com/v{{version}}/installer_x64.exe',
            'https://cdn.example.com/v{{version}}/installer_arm64.exe'
        )
        Resolve-InstallerUrls -UrlTemplates $urls -Version '2.0.0'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$UrlTemplates,

        [Parameter(Mandatory)]
        [string]$Version
    )

    [string[]]$resolved = foreach ($template in $UrlTemplates) {
        $template -replace '\{\{version\}\}', $Version
    }

    return $resolved
}

function Submit-WinGetManifest {
    <#
    .SYNOPSIS
        Submits a WinGet package manifest update as a pull request.

    .DESCRIPTION
        Uses the wingetcreate CLI to update an existing package manifest in
        the microsoft/winget-pkgs repository and automatically open a PR.
        Supports -WhatIf and -Confirm via ShouldProcess.

    .PARAMETER PackageIdentifier
        The WinGet package identifier (e.g. "Google.Chrome").

    .PARAMETER Version
        The new version string for the package.

    .PARAMETER InstallerUrls
        One or more direct URLs to the installer binaries.

    .PARAMETER GitHubToken
        A GitHub personal access token with repo scope, used by wingetcreate
        to fork winget-pkgs and open the pull request.

    .PARAMETER WinGetCreatePath
        Optional path to wingetcreate.exe. If omitted, Install-WinGetCreate
        is called automatically.

    .EXAMPLE
        Submit-WinGetManifest -PackageIdentifier 'Google.Chrome' `
            -Version '131.0.6778.109' `
            -InstallerUrls 'https://dl.google.com/chrome/install/131.0.6778.109/chrome_installer.exe' `
            -GitHubToken $token

    .EXAMPLE
        # Preview without submitting
        Submit-WinGetManifest -PackageIdentifier 'Mozilla.Firefox' `
            -Version '133.0' `
            -InstallerUrls @($url64, $urlArm64) `
            -GitHubToken $token -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$PackageIdentifier,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string[]]$InstallerUrls,

        [Parameter(Mandatory)]
        [string]$GitHubToken,

        [Parameter()]
        [string]$WinGetCreatePath
    )

    # Resolve wingetcreate executable
    if (-not $WinGetCreatePath) {
        Write-Verbose 'WinGetCreatePath not specified; attempting install ...'
        $WinGetCreatePath = Install-WinGetCreate
        if (-not $WinGetCreatePath) {
            throw 'wingetcreate is not available and could not be installed.'
        }
    }
    elseif (-not (Test-Path $WinGetCreatePath)) {
        throw "wingetcreate not found at specified path: $WinGetCreatePath"
    }

    # Build argument list
    $urlArgs = $InstallerUrls -join ' '
    $actionDescription = "Submit WinGet manifest for $PackageIdentifier version $Version"

    if (-not $PSCmdlet.ShouldProcess($actionDescription)) {
        Write-Verbose "WhatIf: $actionDescription"
        return [PSCustomObject]@{
            Success           = $false
            PackageIdentifier = $PackageIdentifier
            Version           = $Version
            Output            = 'Skipped due to -WhatIf'
            PullRequestUrl    = $null
        }
    }

    $arguments = @(
        'update'
        '--id',      $PackageIdentifier
        '--version', $Version
        '--urls'
    ) + $InstallerUrls + @(
        '--token',  $GitHubToken
        '--submit'
    )

    Write-Verbose "Executing: $WinGetCreatePath $($arguments -join ' ')"

    try {
        $output = & $WinGetCreatePath @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_.Exception.Message
        $exitCode = 1
    }

    $success = $exitCode -eq 0

    # Extract PR URL from output
    $prUrl = $null
    if ($output -match '(https://github\.com/microsoft/winget-pkgs/pull/\d+)') {
        $prUrl = $Matches[1]
    }

    if (-not $success) {
        Write-Warning "wingetcreate exited with code $exitCode for $PackageIdentifier $Version"
    }
    else {
        Write-Verbose "Successfully submitted manifest for $PackageIdentifier $Version"
    }

    return [PSCustomObject]@{
        Success           = $success
        PackageIdentifier = $PackageIdentifier
        Version           = $Version
        Output            = $output
        PullRequestUrl    = $prUrl
    }
}

Export-ModuleMember -Function @(
    'Install-WinGetCreate'
    'Resolve-InstallerUrls'
    'Submit-WinGetManifest'
)
