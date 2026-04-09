BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'modules' 'AppVersionDetector.psm1'
    Import-Module $modulePath -Force
}

Describe 'Resolve-JsonPath' {
    Context 'When navigating JSON-like objects' {
        It 'Should resolve a simple top-level property' {
            InModuleScope 'AppVersionDetector' {
                $obj = [PSCustomObject]@{ LATEST_FIREFOX_VERSION = '133.0' }
                $result = Resolve-JsonPath -Object $obj -Path 'LATEST_FIREFOX_VERSION'
                $result | Should -Be '133.0'
            }
        }

        It 'Should resolve a nested dot-separated property' {
            InModuleScope 'AppVersionDetector' {
                $obj = [PSCustomObject]@{ data = [PSCustomObject]@{ version = '1.0' } }
                $result = Resolve-JsonPath -Object $obj -Path 'data.version'
                $result | Should -Be '1.0'
            }
        }

        It 'Should resolve array indexing' {
            InModuleScope 'AppVersionDetector' {
                $obj = [PSCustomObject]@{ versions = @([PSCustomObject]@{ version = '131.0' }) }
                $result = Resolve-JsonPath -Object $obj -Path 'versions[0].version'
                $result | Should -Be '131.0'
            }
        }

        It 'Should return $null when the path does not exist on the object' {
            InModuleScope 'AppVersionDetector' {
                $obj = [PSCustomObject]@{ foo = 'bar' }
                $result = Resolve-JsonPath -Object $obj -Path 'nonexistent.deep.path'
                $result | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Get-LatestAppVersion' {
    Context 'When VersionDetection type is api' {
        It 'Should return the version extracted via JsonPath' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ LATEST_FIREFOX_VERSION = '133.0' }
            } -ModuleName 'AppVersionDetector'

            $config = [PSCustomObject]@{
                Name             = 'Firefox'
                VersionDetection = [PSCustomObject]@{
                    Type     = 'api'
                    Url      = 'https://example.com/api'
                    JsonPath = 'LATEST_FIREFOX_VERSION'
                }
            }

            $result = Get-LatestAppVersion -AppConfig $config
            $result | Should -Be '133.0'
        }
    }

    Context 'When VersionDetection type is github-release' {
        It 'Should strip the tag prefix and return the version' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ tag_name = 'v8.7.1' }
            } -ModuleName 'AppVersionDetector'

            $config = [PSCustomObject]@{
                Name             = 'SomeApp'
                VersionDetection = [PSCustomObject]@{
                    Type      = 'github-release'
                    Url       = 'https://api.github.com/repos/owner/repo/releases/latest'
                    TagPrefix = 'v'
                }
            }

            $result = Get-LatestAppVersion -AppConfig $config
            $result | Should -Be '8.7.1'
        }

        It 'Should apply VersionPattern and VersionFormat when specified' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    tag_name = 'v1.88.138'
                    name     = 'Release v1.88.138 (Chromium 146.0.7680.178)'
                }
            } -ModuleName 'AppVersionDetector'

            $config = [PSCustomObject]@{
                Name             = 'Brave Browser'
                VersionDetection = [PSCustomObject]@{
                    Type           = 'github-release'
                    Url            = 'https://api.github.com/repos/brave/brave-browser/releases/latest'
                    VersionSource  = 'name'
                    VersionPattern = 'v(?<brave>[\d.]+).*Chromium (?<chromium>\d+)'
                    VersionFormat  = '{chromium}.{brave}'
                }
            }

            $result = Get-LatestAppVersion -AppConfig $config
            $result | Should -Be '146.1.88.138'
        }
    }

    Context 'When VersionDetection type is web-scrape' {
        It 'Should extract the version from HTML content using the regex pattern' {
            Mock Invoke-WebRequest {
                [PSCustomObject]@{ Content = '<h1>Download VLC 3.0.21</h1>' }
            } -ModuleName 'AppVersionDetector'

            $config = [PSCustomObject]@{
                Name             = 'VLC'
                VersionDetection = [PSCustomObject]@{
                    Type    = 'web-scrape'
                    Url     = 'https://example.com/vlc'
                    Pattern = 'VLC\s+([\d.]+)'
                }
            }

            $result = Get-LatestAppVersion -AppConfig $config
            $result | Should -Be '3.0.21'
        }
    }

    Context 'When VersionDetection is missing' {
        It 'Should return $null gracefully' {
            $config = [PSCustomObject]@{
                Name             = 'Incomplete'
                VersionDetection = $null
            }

            $result = Get-LatestAppVersion -AppConfig $config -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'When the HTTP request fails' {
        It 'Should return $null gracefully' {
            Mock Invoke-RestMethod {
                throw 'Simulated network error'
            } -ModuleName 'AppVersionDetector'

            $config = [PSCustomObject]@{
                Name             = 'Firefox'
                VersionDetection = [PSCustomObject]@{
                    Type     = 'api'
                    Url      = 'https://example.com/api'
                    JsonPath = 'LATEST_FIREFOX_VERSION'
                }
            }

            $result = Get-LatestAppVersion -AppConfig $config -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }
}

AfterAll {
    Remove-Module AppVersionDetector -ErrorAction SilentlyContinue
}
