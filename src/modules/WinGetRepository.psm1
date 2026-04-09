#Requires -Version 5.1

function Get-ManifestPath {
    <#
    .SYNOPSIS
        Converts a PackageIdentifier to its winget-pkgs manifest directory path.

    .DESCRIPTION
        Derives the manifest path used in the microsoft/winget-pkgs repository from a
        WinGet PackageIdentifier. The path follows the pattern:
        manifests/{firstLetterLower}/{Part1}/{Part2}/...

    .PARAMETER PackageIdentifier
        The WinGet package identifier (e.g., "Google.Chrome").

    .EXAMPLE
        Get-ManifestPath -PackageIdentifier 'Google.Chrome'
        # Returns: manifests/g/Google/Chrome

    .EXAMPLE
        Get-ManifestPath -PackageIdentifier 'Notepad++.Notepad++'
        # Returns: manifests/n/Notepad++/Notepad++
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageIdentifier
    )

    $parts = $PackageIdentifier.Split('.')
    $firstLetter = $parts[0][0].ToString().ToLower()
    $subPath = $parts -join '/'

    return "manifests/$firstLetter/$subPath"
}

function Build-GitHubHeaders {
    <#
    .SYNOPSIS
        Builds standard headers for GitHub API requests.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GitHubToken
    )

    $headers = @{
        'Accept'     = 'application/vnd.github.v3+json'
        'User-Agent' = 'WinGetConveyerBelt'
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers['Authorization'] = "Bearer $GitHubToken"
    }

    return $headers
}

function Test-RateLimited {
    <#
    .SYNOPSIS
        Checks if a GitHub API response indicates rate limiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    if ($Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
        $statusCode = [int]$Exception.Response.StatusCode
        if ($statusCode -eq 403) {
            Write-Warning 'GitHub API rate limit reached. Provide a GitHubToken to increase limits.'
            return $true
        }
    }

    return $false
}

function Test-WinGetVersionExists {
    <#
    .SYNOPSIS
        Checks if a specific version already exists in the winget-pkgs repository.

    .DESCRIPTION
        Queries the GitHub REST API to determine whether a manifest directory exists
        for the given PackageIdentifier and Version in microsoft/winget-pkgs.

    .PARAMETER PackageIdentifier
        The WinGet package identifier (e.g., "Google.Chrome").

    .PARAMETER Version
        The version string to check (e.g., "120.0.6099.130").

    .PARAMETER GitHubToken
        Optional GitHub personal access token to avoid rate limiting.

    .EXAMPLE
        Test-WinGetVersionExists -PackageIdentifier 'Google.Chrome' -Version '120.0.6099.130'
        # Returns $true if the version manifest exists, $false otherwise.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageIdentifier,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter()]
        [string]$GitHubToken
    )

    $manifestPath = Get-ManifestPath -PackageIdentifier $PackageIdentifier
    $uri = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$manifestPath/$Version"
    $headers = Build-GitHubHeaders -GitHubToken $GitHubToken

    try {
        $null = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
        Write-Verbose "Version $Version of $PackageIdentifier exists in winget-pkgs."
        return $true
    }
    catch {
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and
            [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-Verbose "Version $Version of $PackageIdentifier not found in winget-pkgs."
            return $false
        }

        if (Test-RateLimited -Exception $_.Exception) {
            return $false
        }

        Write-Warning "Error checking winget-pkgs for ${PackageIdentifier} ${Version}: $($_.Exception.Message)"
        return $false
    }
}

function Test-WinGetPRExists {
    <#
    .SYNOPSIS
        Checks if an open PR exists in winget-pkgs for a given package and version.

    .DESCRIPTION
        Uses the GitHub Search API to look for open pull requests in microsoft/winget-pkgs
        that mention the specified PackageIdentifier and Version.

    .PARAMETER PackageIdentifier
        The WinGet package identifier (e.g., "Google.Chrome").

    .PARAMETER Version
        The version string to search for (e.g., "120.0.6099.130").

    .PARAMETER GitHubToken
        Optional GitHub personal access token to avoid rate limiting.

    .EXAMPLE
        Test-WinGetPRExists -PackageIdentifier 'Google.Chrome' -Version '120.0.6099.130'
        # Returns $true if a matching open PR is found.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageIdentifier,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter()]
        [string]$GitHubToken
    )

    $query = "repo:microsoft/winget-pkgs is:pr is:open `"$PackageIdentifier`" `"$Version`""
    $encodedQuery = [System.Uri]::EscapeDataString($query)
    $uri = "https://api.github.com/search/issues?q=$encodedQuery"
    $headers = Build-GitHubHeaders -GitHubToken $GitHubToken

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop

        if ($response.total_count -gt 0) {
            Write-Verbose "Found $($response.total_count) open PR(s) for $PackageIdentifier $Version."
            return $true
        }

        Write-Verbose "No open PRs found for $PackageIdentifier $Version."
        return $false
    }
    catch {
        if (Test-RateLimited -Exception $_.Exception) {
            return $false
        }

        Write-Warning "Error searching PRs for ${PackageIdentifier} ${Version}: $($_.Exception.Message)"
        return $false
    }
}

function Get-LatestWinGetVersion {
    <#
    .SYNOPSIS
        Gets the latest version of a package in the winget-pkgs repository.

    .DESCRIPTION
        Queries the GitHub REST API for the directory listing of a package's manifest
        path in microsoft/winget-pkgs, then sorts the version directories to find
        the latest one.

    .PARAMETER PackageIdentifier
        The WinGet package identifier (e.g., "Google.Chrome").

    .PARAMETER GitHubToken
        Optional GitHub personal access token to avoid rate limiting.

    .EXAMPLE
        Get-LatestWinGetVersion -PackageIdentifier 'Google.Chrome'
        # Returns the latest version string, e.g. "120.0.6099.130"

    .OUTPUTS
        System.String or $null if the package is not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageIdentifier,

        [Parameter()]
        [string]$GitHubToken
    )

    $manifestPath = Get-ManifestPath -PackageIdentifier $PackageIdentifier
    $uri = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$manifestPath"
    $headers = Build-GitHubHeaders -GitHubToken $GitHubToken

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    }
    catch {
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and
            [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-Verbose "Package $PackageIdentifier not found in winget-pkgs."
            return $null
        }

        if (Test-RateLimited -Exception $_.Exception) {
            return $null
        }

        Write-Warning "Error fetching versions for ${PackageIdentifier}: $($_.Exception.Message)"
        return $null
    }

    $versionDirs = $response | Where-Object { $_.type -eq 'dir' }

    if (-not $versionDirs -or $versionDirs.Count -eq 0) {
        Write-Verbose "No version directories found for $PackageIdentifier."
        return $null
    }

    $versionNames = $versionDirs | ForEach-Object { $_.name }

    # Try parsing as System.Version for accurate sorting; fall back to string sort
    $parsed = @()
    $unparsable = @()

    foreach ($v in $versionNames) {
        $ver = $null
        if ([System.Version]::TryParse($v, [ref]$ver)) {
            $parsed += [PSCustomObject]@{ Original = $v; Parsed = $ver }
        }
        else {
            $unparsable += $v
        }
    }

    if ($parsed.Count -gt 0) {
        $latest = ($parsed | Sort-Object -Property Parsed | Select-Object -Last 1).Original
    }
    else {
        $latest = $unparsable | Sort-Object | Select-Object -Last 1
    }

    Write-Verbose "Latest version of $PackageIdentifier in winget-pkgs: $latest"
    return $latest
}

Export-ModuleMember -Function @(
    'Get-ManifestPath'
    'Test-WinGetVersionExists'
    'Test-WinGetPRExists'
    'Get-LatestWinGetVersion'
)
