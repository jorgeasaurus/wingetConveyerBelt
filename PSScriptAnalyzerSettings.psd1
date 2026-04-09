@{
    Severity = @('Error', 'Warning', 'Information')

    IncludeDefaultRules = $true

    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
