# WinGet Conveyer Belt

Automates WinGet manifest submissions for popular apps by detecting new upstream versions and opening PRs to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs).

## How It Works

1. Scrapes upstream sources for latest app versions (APIs, GitHub Releases, web scraping)
2. Checks winget-pkgs for existing manifests and open PRs
3. Submits new manifests via [wingetcreate](https://github.com/microsoft/winget-create) if a version is missing

## Monitored Apps

| App | Package ID | Version Source |
|-----|-----------|----------------|
| Google Chrome | `Google.Chrome` | Google versionhistory API |
| Mozilla Firefox | `Mozilla.Firefox` | Mozilla product-details API |
| VLC | `VideoLAN.VLC` | videolan.org (web scrape) |
| Notepad++ | `Notepad++.Notepad++` | GitHub Releases |
| Greenshot | `Greenshot.Greenshot` | GitHub Releases |

## Setup

1. Fork this repo
2. Create a GitHub PAT with `public_repo` scope
3. Add the PAT as a repository secret named `WINGET_PAT`
4. The workflow runs daily at 06:00 UTC, or trigger manually from the Actions tab

## Manual Run

```
gh workflow run update-check.yml -f package_filter=Google.Chrome -f skip_submission=true
```

## Local Testing

```powershell
# Dry run (no submissions)
./src/Invoke-WinGetConveyerBelt.ps1 -SkipSubmission -Verbose

# Process specific app
./src/Invoke-WinGetConveyerBelt.ps1 -PackageFilter 'Mozilla.Firefox' -GitHubToken $token -SkipSubmission

# Full run (Windows only, requires wingetcreate)
./src/Invoke-WinGetConveyerBelt.ps1 -GitHubToken $token
```

## Adding Apps

Edit `config/apps.json`. Each entry needs a `PackageIdentifier`, `InstallerUrls` (use `{{version}}` placeholder), and a `VersionDetection` block with one of three types:

- **`api`** — Fetches JSON from a URL and extracts the version via `JsonPath`.
- **`github-release`** — Hits the GitHub Releases API; strips an optional `TagPrefix` from the tag name.
- **`web-scrape`** — Downloads an HTML page and matches the version with a regex `Pattern`.

```json
{
  "PackageIdentifier": "Notepad++.Notepad++",
  "Name": "Notepad++",
  "VersionDetection": {
    "Type": "github-release",
    "Url": "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest",
    "JsonPath": "tag_name",
    "TagPrefix": "v"
  },
  "InstallerUrls": [
    "https://github.com/.../npp.{{version}}.Installer.x64.exe"
  ]
}
```

## Project Structure

```
src/
  Invoke-WinGetConveyerBelt.ps1    # Orchestrator
  modules/
    AppVersionDetector.psm1         # Version scraping
    WinGetRepository.psm1           # winget-pkgs checks
    ManifestSubmitter.psm1          # wingetcreate wrapper
config/apps.json                    # App definitions
tests/                              # Pester tests
.github/workflows/update-check.yml  # Daily schedule
```

## Running Tests

```powershell
Invoke-Pester ./tests/ -Output Detailed
```

## License

No license has been added yet. Choose one that fits your needs.
