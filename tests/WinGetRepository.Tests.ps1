BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'modules' 'WinGetRepository.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-ManifestPath' {
    Context 'When converting package identifiers to manifest paths' {
        It 'Should convert Google.Chrome correctly' {
            Get-ManifestPath -PackageIdentifier 'Google.Chrome' | Should -Be 'manifests/g/Google/Chrome'
        }

        It 'Should convert Mozilla.Firefox correctly' {
            Get-ManifestPath -PackageIdentifier 'Mozilla.Firefox' | Should -Be 'manifests/m/Mozilla/Firefox'
        }

        It 'Should convert Notepad++.Notepad++ correctly' {
            Get-ManifestPath -PackageIdentifier 'Notepad++.Notepad++' | Should -Be 'manifests/n/Notepad++/Notepad++'
        }

        It 'Should convert VideoLAN.VLC correctly' {
            Get-ManifestPath -PackageIdentifier 'VideoLAN.VLC' | Should -Be 'manifests/v/VideoLAN/VLC'
        }
    }
}

Describe 'Test-WinGetVersionExists' {
    Context 'When the version manifest exists (200)' {
        It 'Should return $true' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ name = 'manifest.yaml' }
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetVersionExists -PackageIdentifier 'Google.Chrome' -Version '120.0.6099.130'
            $result | Should -BeTrue
        }
    }

    Context 'When the version manifest does not exist (404-like error)' {
        It 'Should return $false' {
            Mock Invoke-RestMethod {
                throw 'Not Found (404)'
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetVersionExists -PackageIdentifier 'Google.Chrome' -Version '999.0.0' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }
    }

    Context 'When another error occurs' {
        It 'Should return $false' {
            Mock Invoke-RestMethod {
                throw 'Internal Server Error'
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetVersionExists -PackageIdentifier 'Google.Chrome' -Version '1.0.0' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }
    }
}

Describe 'Test-WinGetPRExists' {
    Context 'When a matching PR is found' {
        It 'Should return $true' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ total_count = 1; items = @() }
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetPRExists -PackageIdentifier 'Google.Chrome' -Version '120.0.6099.130'
            $result | Should -BeTrue
        }
    }

    Context 'When no matching PR is found' {
        It 'Should return $false' {
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ total_count = 0; items = @() }
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetPRExists -PackageIdentifier 'Google.Chrome' -Version '999.0.0'
            $result | Should -BeFalse
        }
    }

    Context 'When an error occurs' {
        It 'Should return $false' {
            Mock Invoke-RestMethod {
                throw 'Service unavailable'
            } -ModuleName 'WinGetRepository'

            $result = Test-WinGetPRExists -PackageIdentifier 'Google.Chrome' -Version '1.0.0' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }
    }
}

Describe 'Get-LatestWinGetVersion' {
    Context 'When version directories exist' {
        It 'Should return the latest version sorted correctly' {
            Mock Invoke-RestMethod {
                @(
                    [PSCustomObject]@{ name = '1.0.0'; type = 'dir' },
                    [PSCustomObject]@{ name = '2.0.0'; type = 'dir' },
                    [PSCustomObject]@{ name = '1.5.0'; type = 'dir' }
                )
            } -ModuleName 'WinGetRepository'

            $result = Get-LatestWinGetVersion -PackageIdentifier 'Some.Package'
            $result | Should -Be '2.0.0'
        }
    }

    Context 'When the package is not found (404-like error)' {
        It 'Should return $null' {
            Mock Invoke-RestMethod {
                throw 'Not Found (404)'
            } -ModuleName 'WinGetRepository'

            $result = Get-LatestWinGetVersion -PackageIdentifier 'Nonexistent.Package' -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }
}

AfterAll {
    Remove-Module WinGetRepository -ErrorAction SilentlyContinue
}
