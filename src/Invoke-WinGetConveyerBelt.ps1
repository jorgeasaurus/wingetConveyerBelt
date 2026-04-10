<#
.SYNOPSIS
    Orchestrates automated WinGet package manifest submissions.

.DESCRIPTION
    Entry point for the WinGet Conveyer Belt pipeline. Loads app configurations
    from apps.json, detects the latest upstream version of each application,
    checks whether that version already exists in the microsoft/winget-pkgs
    repository (or has an open PR), and submits new manifests via wingetcreate
    for any versions that are missing.

    When running inside GitHub Actions, a markdown step summary is written to
    the file specified by the GITHUB_STEP_SUMMARY environment variable.

.PARAMETER ConfigPath
    Path to the apps.json configuration file.
    Defaults to "$PSScriptRoot/../config/apps.json".

.PARAMETER GitHubToken
    GitHub personal access token used for API calls and wingetcreate
    submissions. Falls back to the GITHUB_TOKEN environment variable.

.PARAMETER PackageFilter
    Optional array of PackageIdentifier strings. When provided, only the
    matching apps from the configuration file are processed.

.PARAMETER SkipSubmission
    When set, the script performs all version detection and comparison steps
    but does not submit manifests to winget-pkgs. Useful for dry-run testing.

.EXAMPLE
    .\Invoke-WinGetConveyerBelt.ps1
    # Processes all apps using defaults.

.EXAMPLE
    .\Invoke-WinGetConveyerBelt.ps1 -PackageFilter 'Google.Chrome','Mozilla.Firefox'
    # Processes only Chrome and Firefox.

.EXAMPLE
    .\Invoke-WinGetConveyerBelt.ps1 -SkipSubmission -Verbose
    # Dry run with verbose logging for all apps.

.EXAMPLE
    .\Invoke-WinGetConveyerBelt.ps1 -ConfigPath './config/apps.json' -GitHubToken $token -WhatIf
    # Preview submissions without executing them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$GitHubToken = $env:GITHUB_TOKEN,

    [Parameter()]
    [string[]]$PackageFilter,

    [Parameter()]
    [switch]$SkipSubmission
)

# ---------------------------------------------------------------------------
# Module imports
# ---------------------------------------------------------------------------
$modulesPath = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulesPath 'AppVersionDetector.psm1') -Force
Import-Module (Join-Path $modulesPath 'WinGetRepository.psm1') -Force
Import-Module (Join-Path $modulesPath 'ManifestSubmitter.psm1') -Force

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot '..' 'config' 'apps.json'
}

$ConfigPath = (Resolve-Path -Path $ConfigPath -ErrorAction Stop).Path
Write-Verbose "Loading configuration from: $ConfigPath"

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$apps = $config.apps

if (-not $apps -or $apps.Count -eq 0) {
    Write-Warning 'No apps found in configuration file.'
    return @()
}

if ($PackageFilter) {
    $apps = $apps | Where-Object { $_.PackageIdentifier -in $PackageFilter }
    if (-not $apps -or @($apps).Count -eq 0) {
        Write-Warning "No apps matched the PackageFilter: $($PackageFilter -join ', ')"
        return @()
    }
}

if (-not $GitHubToken) {
    Write-Warning 'No GitHubToken provided. API calls may be rate-limited and submissions will fail.'
}

# ---------------------------------------------------------------------------
# Process each app
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($app in $apps) {
    $id   = $app.PackageIdentifier
    $name = $app.Name

    Write-Verbose "--- Processing $name ($id) ---"

    try {
        $ErrorActionPreference = 'Stop'

        # (a) Detect latest upstream version
        $upstreamVersion = Get-LatestAppVersion -AppConfig $app

        if (-not $upstreamVersion) {
            Write-Warning "Could not detect upstream version for $name ($id). Skipping."
            $results.Add([PSCustomObject]@{
                PackageIdentifier = $id
                Name              = $name
                UpstreamVersion   = $null
                WinGetVersion     = $null
                Status            = 'DetectionFailed'
                PullRequestUrl    = $null
            })
            continue
        }

        Write-Verbose "Upstream version for $name : $upstreamVersion"

        # Fetch latest WinGet version for reporting
        $wingetVersion = Get-LatestWinGetVersion -PackageIdentifier $id -GitHubToken $GitHubToken

        # (c) Check if version already exists in winget-pkgs
        $versionExists = Test-WinGetVersionExists -PackageIdentifier $id -Version $upstreamVersion -GitHubToken $GitHubToken

        if ($versionExists) {
            Write-Verbose "$name $upstreamVersion already exists in winget-pkgs."
            $results.Add([PSCustomObject]@{
                PackageIdentifier = $id
                Name              = $name
                UpstreamVersion   = $upstreamVersion
                WinGetVersion     = $wingetVersion
                Status            = 'UpToDate'
                PullRequestUrl    = $null
            })
            continue
        }

        # (e) Check if an open PR already exists
        $prExists = Test-WinGetPRExists -PackageIdentifier $id -Version $upstreamVersion -GitHubToken $GitHubToken

        if ($prExists) {
            Write-Verbose "An open PR already exists for $name $upstreamVersion."
            $results.Add([PSCustomObject]@{
                PackageIdentifier = $id
                Name              = $name
                UpstreamVersion   = $upstreamVersion
                WinGetVersion     = $wingetVersion
                Status            = 'PRExists'
                PullRequestUrl    = $null
            })
            continue
        }

        # (g) Resolve installer URLs
        $installerVersion = $upstreamVersion
        if ($app.InstallerVersionTransform) {
            $installerVersion = $upstreamVersion -replace $app.InstallerVersionTransform.Pattern, $app.InstallerVersionTransform.Replacement
            Write-Verbose "InstallerVersionTransform: $upstreamVersion -> $installerVersion"
        }
        $installerUrls = Resolve-InstallerUrls -UrlTemplates $app.InstallerUrls -Version $upstreamVersion -InstallerVersion $installerVersion
        Write-Verbose "Resolved installer URLs: $($installerUrls -join ', ')"

        # (h) Skip submission if requested
        if ($SkipSubmission) {
            Write-Verbose "SkipSubmission set. Would submit $name $upstreamVersion with URLs: $($installerUrls -join ', ')"
            $results.Add([PSCustomObject]@{
                PackageIdentifier = $id
                Name              = $name
                UpstreamVersion   = $upstreamVersion
                WinGetVersion     = $wingetVersion
                Status            = 'Skipped'
                PullRequestUrl    = $null
            })
            continue
        }

        # (i) Submit manifest
        $submitParams = @{
            PackageIdentifier = $id
            Version           = $upstreamVersion
            InstallerUrls     = $installerUrls
            GitHubToken       = $GitHubToken
        }

        if ($WhatIfPreference) {
            $submitResult = Submit-WinGetManifest @submitParams -WhatIf
        }
        else {
            $submitResult = Submit-WinGetManifest @submitParams
        }

        $status = if ($submitResult.Success) { 'Submitted' } else { 'Failed' }

        $results.Add([PSCustomObject]@{
            PackageIdentifier = $id
            Name              = $name
            UpstreamVersion   = $upstreamVersion
            WinGetVersion     = $wingetVersion
            Status            = $status
            PullRequestUrl    = $submitResult.PullRequestUrl
        })
    }
    catch {
        Write-Warning "Error processing $name ($id): $_"
        $results.Add([PSCustomObject]@{
            PackageIdentifier = $id
            Name              = $name
            UpstreamVersion   = $null
            WinGetVersion     = $null
            Status            = 'Failed'
            PullRequestUrl    = $null
        })
    }
    finally {
        $ErrorActionPreference = 'Continue'
    }
}

# ---------------------------------------------------------------------------
# GitHub Actions Step Summary
# ---------------------------------------------------------------------------
if ($env:GITHUB_STEP_SUMMARY) {
    $summary = [System.Text.StringBuilder]::new()
    [void]$summary.AppendLine('## WinGet Conveyer Belt Results')
    [void]$summary.AppendLine()
    [void]$summary.AppendLine('| App | Latest Version | WinGet Version | Status | PR URL |')
    [void]$summary.AppendLine('|-----|----------------|----------------|--------|--------|')

    foreach ($r in $results) {
        $upstream = if ($r.UpstreamVersion) { $r.UpstreamVersion } else { 'N/A' }
        $winget   = if ($r.WinGetVersion)   { $r.WinGetVersion }   else { 'N/A' }
        $prLink   = if ($r.PullRequestUrl)  { "[$($r.PullRequestUrl)]($($r.PullRequestUrl))" } else { '' }
        [void]$summary.AppendLine("| $($r.Name) | $upstream | $winget | $($r.Status) | $prLink |")
    }

    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summary.ToString()
    Write-Verbose 'GitHub Actions step summary written.'
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output 'WinGet Conveyer Belt - Results:'
Write-Output '================================'
$results | Format-Table -Property Name, UpstreamVersion, WinGetVersion, Status, PullRequestUrl -AutoSize | Out-String | Write-Output

# ---------------------------------------------------------------------------
# Return results
# ---------------------------------------------------------------------------
return $results.ToArray()
