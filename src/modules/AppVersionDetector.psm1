function Resolve-JsonPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Object,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $current = $Object

    # Split on dots, but keep array brackets attached to their segment
    $segments = [regex]::Matches($Path, '([^.\[\]]+)(\[\d+\])?')

    foreach ($match in $segments) {
        if ($null -eq $current) { return $null }

        $property = $match.Groups[1].Value
        $index    = $match.Groups[2].Value

        $current = $current.$property

        if ($index -and $null -ne $current) {
            $i = [int]($index.Trim('[', ']'))
            $current = $current[$i]
        }
    }

    return $current
}

function Get-VersionFromApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VersionDetection
    )

    try {
        $response = Invoke-RestMethod -Uri $VersionDetection.Url -ErrorAction Stop
        $version  = Resolve-JsonPath -Object $response -Path $VersionDetection.JsonPath
        return [string]$version
    }
    catch {
        Write-Warning "API version detection failed for $($VersionDetection.Url): $_"
        return $null
    }
}

function Get-VersionFromGitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VersionDetection
    )

    $headers = @{ 'User-Agent' = 'wingetConveyerBelt/1.0' }

    try {
        $response = Invoke-RestMethod -Uri $VersionDetection.Url -Headers $headers -ErrorAction Stop

        $jsonPath = if ($VersionDetection.JsonPath) { $VersionDetection.JsonPath } else { 'tag_name' }
        $tag = Resolve-JsonPath -Object $response -Path $jsonPath

        if ($VersionDetection.TagPrefix -and $tag) {
            $tag = $tag -replace "^$([regex]::Escape($VersionDetection.TagPrefix))", ''
        }

        return [string]$tag
    }
    catch {
        Write-Warning "GitHub release version detection failed for $($VersionDetection.Url): $_"
        return $null
    }
}

function Get-VersionFromWebScrape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VersionDetection
    )

    try {
        $html = Invoke-WebRequest -Uri $VersionDetection.Url -UseBasicParsing -ErrorAction Stop

        if ($html.Content -match $VersionDetection.Pattern) {
            return $Matches[1]
        }

        Write-Warning "Pattern '$($VersionDetection.Pattern)' did not match content from $($VersionDetection.Url)"
        return $null
    }
    catch {
        Write-Warning "Web scrape version detection failed for $($VersionDetection.Url): $_"
        return $null
    }
}

function Get-LatestAppVersion {
    <#
    .SYNOPSIS
        Detects the latest upstream version of an application.

    .DESCRIPTION
        Reads an app configuration object (from apps.json) and returns the latest
        version string by dispatching to the appropriate detection strategy based
        on the VersionDetection.Type property. Supported types are 'api',
        'github-release', and 'web-scrape'.

    .PARAMETER AppConfig
        A PSCustomObject representing an app entry from apps.json. Must contain a
        VersionDetection property with at least Type and Url fields.

    .EXAMPLE
        $apps = (Get-Content ./config/apps.json | ConvertFrom-Json).apps
        $version = Get-LatestAppVersion -AppConfig $apps[0]

    .EXAMPLE
        $config = [PSCustomObject]@{
            Name = 'Notepad++'
            VersionDetection = [PSCustomObject]@{
                Type      = 'github-release'
                Url       = 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest'
                JsonPath  = 'tag_name'
                TagPrefix = 'v'
            }
        }
        Get-LatestAppVersion -AppConfig $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$AppConfig
    )

    $detection = $AppConfig.VersionDetection

    if (-not $detection -or -not $detection.Type) {
        Write-Warning "AppConfig for '$($AppConfig.Name)' is missing VersionDetection.Type"
        return $null
    }

    switch ($detection.Type) {
        'api'            { return Get-VersionFromApi            -VersionDetection $detection }
        'github-release' { return Get-VersionFromGitHubRelease  -VersionDetection $detection }
        'web-scrape'     { return Get-VersionFromWebScrape      -VersionDetection $detection }
        default {
            Write-Warning "Unknown version detection type: '$($detection.Type)' for '$($AppConfig.Name)'"
            return $null
        }
    }
}

Export-ModuleMember -Function Get-LatestAppVersion
