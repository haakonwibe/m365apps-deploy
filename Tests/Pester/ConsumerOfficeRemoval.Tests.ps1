#Requires -Version 5.1
<#
.SYNOPSIS
    Guards for the OEM consumer Office removal pass added in 1.0.9.

.DESCRIPTION
    Background: <RemoveMSI /> covers Windows Installer products only, so a
    consumer Click-to-Run Office shipped on a vendor image remains registered
    next to O365ProPlusRetail after the enterprise install.
    Install-M365Apps.ps1 can remove it first, behind
    -RemovePreinstalledConsumerOffice.

    The interesting failure mode is not logic, it is drift: the product-ID list
    lives in two places - a PowerShell array in the install script and a set of
    <Product> elements in the removal XML - and a SKU added to one but not the
    other produces a switch that silently half-works. These are static guards
    against exactly that, in the same style as ParamBlockHygiene and
    RegistryAccessHygiene.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ConsumerOfficeRemoval.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot    = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    $script:InstallPath = Join-Path -Path $script:RepoRoot -ChildPath 'M365Apps\Install-M365Apps.ps1'
    $script:RemovePath  = Join-Path -Path $script:RepoRoot -ChildPath 'M365Apps\Configurations\m365apps-remove-consumer.xml'

    # Read $ConsumerProductIds out of the script via the AST rather than by
    # regex, so the test reads the value the script would actually use.
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallPath, [ref]$null, [ref]$errors)
    $script:InstallAst    = $ast
    $script:InstallErrors = $errors

    $assignment = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$ConsumerProductIds'
    }, $true) | Select-Object -First 1

    $script:ScriptProductIds = @()
    if ($null -ne $assignment) {
        $script:ScriptProductIds = @(
            $assignment.Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value }
        )
    }
}

Describe 'm365apps-remove-consumer.xml' {

    It 'exists alongside the other M365Apps configurations' {
        Test-Path -LiteralPath $script:RemovePath -PathType Leaf | Should -BeTrue
    }

    It 'is well-formed XML' {
        # An XML comment may not contain '--', which is easy to introduce with
        # a heading underline and is not obvious until ODT rejects the file.
        { [xml]$null = Get-Content -LiteralPath $script:RemovePath -Raw } | Should -Not -Throw
    }

    It 'contains a Remove block and no Add block' {
        # ODT documents <Remove> standalone, never alongside <Add>. Mixing them
        # is what makes this a separate pass rather than a base-XML edit.
        $xml = [xml](Get-Content -LiteralPath $script:RemovePath -Raw)
        $xml.Configuration.Remove | Should -Not -BeNullOrEmpty
        $xml.Configuration.Add    | Should -BeNullOrEmpty
    }

    It 'is scoped to named products rather than Remove All' {
        # <Remove All="TRUE" /> would take out a legitimate enterprise Office,
        # Visio or Project that happened to be present.
        $xml = [xml](Get-Content -LiteralPath $script:RemovePath -Raw)
        $xml.Configuration.Remove.All | Should -BeNullOrEmpty
        @($xml.Configuration.Remove.Product).Count | Should -BeGreaterThan 0
    }

    It 'never lists the enterprise product it is clearing the way for' {
        $xml = [xml](Get-Content -LiteralPath $script:RemovePath -Raw)
        @($xml.Configuration.Remove.Product.ID) | Should -Not -Contain 'O365ProPlusRetail'
    }

    It 'runs silently and closes blocking apps' {
        $xml = [xml](Get-Content -LiteralPath $script:RemovePath -Raw)
        $xml.Configuration.Display.Level | Should -Be 'None'
        @($xml.Configuration.Property | Where-Object { $_.Name -eq 'FORCEAPPSHUTDOWN' }).Value | Should -Be 'TRUE'
    }

    It 'carries no unresolved build-time tokens' {
        (Get-Content -LiteralPath $script:RemovePath -Raw) | Should -Not -Match '\{\{.*?\}\}'
    }
}

Describe 'Install-M365Apps.ps1 consumer removal wiring' {

    It 'parses cleanly' {
        @($script:InstallErrors).Count | Should -Be 0
    }

    It 'declares -RemovePreinstalledConsumerOffice as an optional switch' {
        $param = $script:InstallAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'RemovePreinstalledConsumerOffice' }
        $param | Should -Not -BeNullOrEmpty
        $param.StaticType.Name | Should -Be 'SwitchParameter'
        # No default value: removing software must stay opt-in.
        $param.DefaultValue | Should -BeNullOrEmpty
    }

    It 'declares -ProgressIntervalSeconds with a sane range' {
        $param = $script:InstallAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ProgressIntervalSeconds' }
        $param | Should -Not -BeNullOrEmpty
        $param.DefaultValue.Extent.Text | Should -Be '30'
    }

    It 'defines a non-empty $ConsumerProductIds list' {
        $script:ScriptProductIds.Count | Should -BeGreaterThan 0
    }

    It 'lists O365HomePremRetail, the most common consumer SKU' {
        $script:ScriptProductIds | Should -Contain 'O365HomePremRetail'
    }

    It 'never lists the enterprise product' {
        $script:ScriptProductIds | Should -Not -Contain 'O365ProPlusRetail'
    }
}

Describe 'Consumer product IDs stay in step across script and XML' {

    It 'the script list and the XML Remove block name exactly the same products' {
        $xml = [xml](Get-Content -LiteralPath $script:RemovePath -Raw)
        $xmlIds = @($xml.Configuration.Remove.Product.ID | Sort-Object)
        $scriptIds = @($script:ScriptProductIds | Sort-Object)

        ($scriptIds -join ',') | Should -Be ($xmlIds -join ',') `
            -Because 'a SKU added to only one of the two places produces a switch that silently half-works'
    }
}
