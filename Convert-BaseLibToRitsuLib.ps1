[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [string]$OldLibRoot = "D:\mod\ctf9\BaseLib-StS2-master",

    [string]$NewLibRoot = "D:\mod\ctf9\STS2-RitsuLib-main",

    [string]$ReportPath,

    [string]$ScaffoldPath,

    [switch]$Apply,

    [switch]$RewriteSafeCode,

    [switch]$GenerateRitsuScaffold,

    [switch]$GenerateLegacyHarmonyBootstrap,

    [switch]$RewritePatchBootstrap,

    [string]$LegacyHarmonyBootstrapPath,

    [switch]$GenerateMigrationSupport,

    [string]$CompatibilitySupportPath,

    [switch]$RewriteMigrationSupportUsings
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$FromDirectory,
        [Parameter(Mandatory)]
        [string]$ToPath
    )

    $fromFull = [System.IO.Path]::GetFullPath($FromDirectory)
    if (-not $fromFull.EndsWith("\") -and -not $fromFull.EndsWith("/")) {
        $fromFull += "\"
    }

    $fromUri = [System.Uri]::new($fromFull)
    $toUri = [System.Uri]::new([System.IO.Path]::GetFullPath($ToPath))
    $relativeUri = $fromUri.MakeRelativeUri($toUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace("/", "\")
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Add-ChangedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Reason
    )

    if (-not $script:ChangedFiles.ContainsKey($Path)) {
        $script:ChangedFiles[$Path] = [System.Collections.Generic.List[string]]::new()
    }

    if (-not $script:ChangedFiles[$Path].Contains($Reason)) {
        $script:ChangedFiles[$Path].Add($Reason)
    }
}

function Get-ProjectFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [string]$Filter = "*"
    )

    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter | Where-Object {
        $_.FullName -notmatch '\\(\.git|bin|obj|packages)\\' -and
        $_.FullName -ne $script:ReportPath -and
        $_.FullName -ne $script:ScaffoldPath -and
        $_.FullName -ne $script:LegacyHarmonyBootstrapPath -and
        $_.FullName -ne $script:MigrationSupportPath -and
        $_.FullName -ne $script:CompatibilitySupportPath
    }
}

function Add-NoWarnCodes {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory)]
        [string[]]$Codes
    )

    $propertyGroups = @($Xml.SelectNodes("/Project/PropertyGroup"))
    $targetNode = $propertyGroups |
        Where-Object { $_.SelectSingleNode("NoWarn") } |
        Select-Object -First 1

    if (-not $targetNode) {
        $targetNode = $Xml.CreateElement("PropertyGroup")
        $null = $Xml.DocumentElement.AppendChild($targetNode)
    }

    $noWarnNode = $targetNode.SelectSingleNode("NoWarn")
    if (-not $noWarnNode) {
        $noWarnNode = $Xml.CreateElement("NoWarn")
        $noWarnNode.InnerText = '$(NoWarn)'
        $null = $targetNode.AppendChild($noWarnNode)
    }

    $existingCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rawCode in ($noWarnNode.InnerText -split ';')) {
        $trimmedCode = $rawCode.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmedCode)) {
            $null = $existingCodes.Add($trimmedCode)
        }
    }

    $updated = $false
    foreach ($code in $Codes) {
        if ($existingCodes.Add($code)) {
            $updated = $true
        }
    }

    if (-not $updated) {
        return $false
    }

    $orderedCodes = @()
    if ($existingCodes.Contains('$(NoWarn)')) {
        $orderedCodes += '$(NoWarn)'
        $null = $existingCodes.Remove('$(NoWarn)')
    }

    $orderedCodes += @($existingCodes | Sort-Object)
    $noWarnNode.InnerText = $orderedCodes -join ';'
    return $true
}

function Get-OrCreateItemGroup {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory)]
        [string]$ChildElementName
    )

    $targetNode = @($Xml.SelectNodes("/Project/ItemGroup")) |
        Where-Object { $_.SelectSingleNode($ChildElementName) } |
        Select-Object -First 1

    if (-not $targetNode) {
        $targetNode = $Xml.CreateElement("ItemGroup")
        $null = $Xml.DocumentElement.AppendChild($targetNode)
    }

    return $targetNode
}

function Ensure-PackageReference {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory)]
        [string]$Include,
        [Parameter(Mandatory)]
        [string]$Version,
        [string]$PrivateAssets
    )

    $node = $Xml.SelectSingleNode("//PackageReference[@Include='$Include']")
    $changed = $false

    if (-not $node) {
        $itemGroup = Get-OrCreateItemGroup -Xml $Xml -ChildElementName "PackageReference"
        $node = $Xml.CreateElement("PackageReference")
        $node.SetAttribute("Include", $Include)
        $null = $itemGroup.AppendChild($node)
        $changed = $true
    }

    if ($node.GetAttribute("Version") -ne $Version) {
        $node.SetAttribute("Version", $Version)
        $changed = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($PrivateAssets) -and $node.GetAttribute("PrivateAssets") -ne $PrivateAssets) {
        $node.SetAttribute("PrivateAssets", $PrivateAssets)
        $changed = $true
    }

    return $changed
}

function Ensure-PublicizeItem {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory)]
        [string]$Include,
        [Parameter(Mandatory)]
        [string]$IncludeVirtualMembers,
        [Parameter(Mandatory)]
        [string]$IncludeCompilerGeneratedMembers
    )

    $node = $Xml.SelectSingleNode("//Publicize[@Include='$Include']")
    $changed = $false

    if (-not $node) {
        $itemGroup = Get-OrCreateItemGroup -Xml $Xml -ChildElementName "Publicize"
        $node = $Xml.CreateElement("Publicize")
        $node.SetAttribute("Include", $Include)
        $null = $itemGroup.AppendChild($node)
        $changed = $true
    }

    if ($node.GetAttribute("IncludeVirtualMembers") -ne $IncludeVirtualMembers) {
        $node.SetAttribute("IncludeVirtualMembers", $IncludeVirtualMembers)
        $changed = $true
    }

    if ($node.GetAttribute("IncludeCompilerGeneratedMembers") -ne $IncludeCompilerGeneratedMembers) {
        $node.SetAttribute("IncludeCompilerGeneratedMembers", $IncludeCompilerGeneratedMembers)
        $changed = $true
    }

    return $changed
}

function Remove-ItemByAttribute {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory)]
        [string]$ItemName,
        [Parameter(Mandatory)]
        [string]$AttributeName,
        [Parameter(Mandatory)]
        [string]$AttributeValue
    )

    $node = $Xml.SelectSingleNode("//$ItemName[@$AttributeName='$AttributeValue']")
    if (-not $node) {
        return $false
    }

    $null = $node.ParentNode.RemoveChild($node)
    return $true
}

function Remove-DuplicateUsingDirective {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [string]$Namespace
    )

    $lineEnding = if ($Text.Contains("`r`n")) {
        "`r`n"
    }
    elseif ($Text.Contains("`n")) {
        "`n"
    }
    else {
        "`r"
    }

    $hasTrailingLineEnding =
        $Text.EndsWith("`r`n") -or
        $Text.EndsWith("`n") -or
        $Text.EndsWith("`r")

    $pattern = "^\s*using\s+" + [System.Text.RegularExpressions.Regex]::Escape($Namespace) + "\s*;\s*$"
    $seen = $false
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in ($Text -split "\r\n|\n|\r")) {
        if ($line -match $pattern) {
            if ($seen) {
                continue
            }

            $seen = $true
        }

        $lines.Add($line)
    }

    $updated = $lines -join $lineEnding
    if ($hasTrailingLineEnding) {
        $updated += $lineEnding
    }

    return $updated
}

function Update-CsprojFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [string]$NewLibCsprojPath,
        [Parameter(Mandatory)]
        [string]$NewPropsPath
    )

    $xml = [System.Xml.XmlDocument]::new()
    $xml.PreserveWhitespace = $true
    $xml.Load($File.FullName)

    $changed = $false
    $fileDirectory = Split-Path -Parent $File.FullName
    $newProjectReference = Get-RelativePath -FromDirectory $fileDirectory -ToPath $NewLibCsprojPath
    $newPropsReference = Get-RelativePath -FromDirectory $fileDirectory -ToPath $NewPropsPath

    $projectReferenceNodes = @($xml.SelectNodes("//ProjectReference"))
    $packageReferenceNodes = @($xml.SelectNodes("//PackageReference[@Include='Alchyr.Sts2.BaseLib']"))
    $assemblyReferenceNodes = @($xml.SelectNodes("//Reference"))
    $hasNewProjectReference = $false

    foreach ($node in $projectReferenceNodes) {
        $include = $node.GetAttribute("Include")
        if ($include -eq $newProjectReference -or $include -like "*STS2-RitsuLib.csproj") {
            $hasNewProjectReference = $true
        }
    }

    foreach ($node in $projectReferenceNodes) {
        $include = $node.GetAttribute("Include")
        if ($include -like "*BaseLib.csproj" -or $include -like "*BaseLib-StS2*.csproj" -or $include -like "*BaseLib-StS2-master*") {
            $node.SetAttribute("Include", $newProjectReference)
            $changed = $true
            $hasNewProjectReference = $true
        }
    }

    foreach ($node in $packageReferenceNodes) {
        if ($hasNewProjectReference) {
            $null = $node.ParentNode.RemoveChild($node)
        }
        else {
            $replacement = $xml.CreateElement("ProjectReference")
            $replacement.SetAttribute("Include", $newProjectReference)
            $null = $node.ParentNode.ReplaceChild($replacement, $node)
            $hasNewProjectReference = $true
        }

        $changed = $true
    }

    foreach ($node in $assemblyReferenceNodes) {
        $include = $node.GetAttribute("Include")
        if (-not ($include -eq "BaseLib" -or $include -like "BaseLib,*")) {
            continue
        }

        if ($hasNewProjectReference) {
            $null = $node.ParentNode.RemoveChild($node)
        }
        else {
            $replacement = $xml.CreateElement("ProjectReference")
            $replacement.SetAttribute("Include", $newProjectReference)
            $null = $node.ParentNode.ReplaceChild($replacement, $node)
            $hasNewProjectReference = $true
        }

        $changed = $true
    }

    foreach ($importNode in @($xml.SelectNodes("//Import"))) {
        $project = $importNode.GetAttribute("Project")
        if (
            $project -like "*BaseLib-StS2-master*Sts2PathDiscovery.props" -or
            $project -like "*BaseLib*Sts2PathDiscovery.props" -or
            $project -like "*$($script:OldLibRootWindows)*" -or
            $project -like "*$($script:OldLibRootForward)*"
        ) {
            $importNode.SetAttribute("Project", $newPropsReference)
            $changed = $true
        }
    }

    foreach ($errorNode in @($xml.SelectNodes("//Error"))) {
        $condition = $errorNode.GetAttribute("Condition")
        $text = $errorNode.GetAttribute("Text")
        if (
            $condition -like "*BaseLibDir*" -or
            $text -like "*BaseLib.dll*" -or
            $text -like "*BaseLib*"
        ) {
            $null = $errorNode.ParentNode.RemoveChild($errorNode)
            $changed = $true
        }
    }

    if (Add-NoWarnCodes -Xml $xml -Codes @("STS001", "STS003")) {
        $changed = $true
    }

    if (Ensure-PackageReference -Xml $xml -Include "Krafs.Publicizer" -Version "2.3.0" -PrivateAssets "all") {
        $changed = $true
    }

    if (Ensure-PublicizeItem -Xml $xml -Include "sts2" -IncludeVirtualMembers "false" -IncludeCompilerGeneratedMembers "false") {
        $changed = $true
    }

    if (Remove-ItemByAttribute -Xml $xml -ItemName "Compile" -AttributeName "Remove" -AttributeValue "packages\**\*.cs") {
        $changed = $true
    }

    if ($changed -and $Apply) {
        $xml.Save($File.FullName)
    }

    if ($changed) {
        Add-ChangedFile -Path $File.FullName -Reason "updated project dependency references"
        Add-ChangedFile -Path $File.FullName -Reason "suppressed BaseLib migration analyzer noise"
        Add-ChangedFile -Path $File.FullName -Reason "enabled sts2 publicizer for generated compatibility shims"
        Add-ChangedFile -Path $File.FullName -Reason "removed incompatible package source exclusions for publicizer"
    }
}

function Update-SolutionFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [string]$NewLibCsprojPath
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $updated = $original
    $solutionDirectory = Split-Path -Parent $File.FullName
    $newProjectReference = Get-RelativePath -FromDirectory $solutionDirectory -ToPath $NewLibCsprojPath

    $updated = $updated.Replace($script:OldLibRootWindows, $script:NewLibRootWindows)
    $updated = $updated.Replace($script:OldLibRootForward, $script:NewLibRootForward)
    $updated = $updated.Replace("BaseLib.csproj", [System.IO.Path]::GetFileName($NewLibCsprojPath))
    $updated = $updated.Replace("BaseLib-StS2.csproj", [System.IO.Path]::GetFileName($NewLibCsprojPath))
    $updated = $updated.Replace("BaseLib-StS2-master\BaseLib.csproj", $newProjectReference)

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(Project\("[^"]+"\) = )"BaseLib"(?=,\s*")',
        '$1"STS2-RitsuLib"'
    )

    if ($updated -ne $original) {
        if ($Apply) {
            Write-Utf8File -Path $File.FullName -Content $updated
        }

        Add-ChangedFile -Path $File.FullName -Reason "updated solution references"
    }
}

function Update-XmlTextFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [string]$NewPropsPath
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $updated = $original
    $fileDirectory = Split-Path -Parent $File.FullName
    $newPropsReference = Get-RelativePath -FromDirectory $fileDirectory -ToPath $NewPropsPath

    $updated = $updated.Replace($script:OldLibRootWindows, $script:NewLibRootWindows)
    $updated = $updated.Replace($script:OldLibRootForward, $script:NewLibRootForward)
    $updated = $updated.Replace("path\to\BaseLib-StS2-master\Sts2PathDiscovery.props", $newPropsReference)
    $updated = $updated.Replace("path/to/BaseLib-StS2-master/Sts2PathDiscovery.props", $newPropsReference.Replace("\", "/"))
    $updated = $updated.Replace("BaseLib.csproj", [System.IO.Path]::GetFileName($script:NewLibCsprojPath))
    $updated = $updated.Replace("BaseLib-StS2.csproj", [System.IO.Path]::GetFileName($script:NewLibCsprojPath))

    if ($updated -ne $original) {
        if ($Apply) {
            Write-Utf8File -Path $File.FullName -Content $updated
        }

        Add-ChangedFile -Path $File.FullName -Reason "updated imported dependency paths"
    }
}

function Update-JsonFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [string]$NewManifestId
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $updated = $original
    $changed = $false

    $match = [System.Text.RegularExpressions.Regex]::Match(
        $updated,
        '(?<prefix>"dependencies"\s*:\s*\[)(?<items>.*?)(?<suffix>\])',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    if ($match.Success -and $match.Groups["items"].Value -match '"BaseLib"') {
        $replacementItems = $match.Groups["items"].Value.Replace('"BaseLib"', '"' + $NewManifestId + '"')
        $updated =
            $updated.Substring(0, $match.Groups["items"].Index) +
            $replacementItems +
            $updated.Substring($match.Groups["items"].Index + $match.Groups["items"].Length)
        $changed = $true
    }

    if ($changed) {
        if ($Apply) {
            Write-Utf8File -Path $File.FullName -Content $updated
        }

        Add-ChangedFile -Path $File.FullName -Reason "updated mod manifest dependencies"
    }
}

function Update-CSharpFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $updated = $original

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.Hooks\s*;',
        '$1using STS2RitsuLib.Combat.HealthBars;'
    )

    $updated = $updated.Replace("BaseLib.Hooks.", "STS2RitsuLib.Combat.HealthBars.")

    if ($updated -ne $original) {
        if ($Apply) {
            Write-Utf8File -Path $File.FullName -Content $updated
        }

        Add-ChangedFile -Path $File.FullName -Reason "rewrote safe health bar forecast namespaces"
    }
}

function Collect-Matches {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string[]]$Extensions,
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.FullName -notmatch '\\(\.git|bin|obj|packages)\\' -and
        $_.FullName -ne $script:ReportPath -and
        $_.FullName -ne $script:ScaffoldPath -and
        $_.FullName -ne $script:LegacyHarmonyBootstrapPath -and
        $_.FullName -ne $script:MigrationSupportPath -and
        $_.FullName -ne $script:CompatibilitySupportPath -and
        ($Extensions -contains $_.Extension)
    }

    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            $lineNumber++
            if ($line -match $Pattern) {
                $results.Add([pscustomobject]@{
                        Path = $file.FullName
                        Line = $lineNumber
                        Text = $line.Trim()
                    })
            }
        }
    }

    return $results
}

function Get-TypeRootName {
    param(
        [Parameter(Mandatory)]
        [string]$TypeName
    )

    $normalized = $TypeName.Trim()
    $normalized = $normalized -replace 'global::', ''
    $normalized = $normalized -replace '<.*$', ''
    $normalized = $normalized -replace '\[\]$', ''
    if ($normalized.Contains(".")) {
        $normalized = $normalized.Split(".")[-1]
    }
    return $normalized.Trim()
}

function Convert-ToPublicEntryToken {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $normalized = $Value.Trim()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '[^A-Za-z0-9]+', '_')
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '([A-Z]+)([A-Z][a-z])', '$1_$2')
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '([a-z0-9])([A-Z])', '$1_$2')
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '_+', '_')
    return $normalized.Trim('_').ToUpperInvariant()
}

function Get-CompatibilityStemVariants {
    param(
        [Parameter(Mandatory)]
        [string]$Stem
    )

    $variants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $trimmedStem = $Stem.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmedStem)) {
        $null = $variants.Add($trimmedStem)
    }

    $segments = @($trimmedStem.Split("_") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -gt 1 -and (@($segments | Where-Object { $_.Length -ne 1 }).Count -eq 0)) {
        $null = $variants.Add(($segments -join ""))
    }

    return @($variants)
}

function Get-ProjectManifestId {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $candidateFiles = Get-ChildItem -LiteralPath $Root -File -Filter "*.json" | Sort-Object Name
    foreach ($file in $candidateFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $match = [System.Text.RegularExpressions.Regex]::Match($text, '"id"\s*:\s*"(?<id>[^"]+)"')
        if ($match.Success) {
            return $match.Groups["id"].Value
        }
    }

    return Split-Path -Leaf $Root
}

function Get-PrimaryProjectFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    return Get-ProjectFiles -Root $Root -Filter "*.csproj" |
        Sort-Object FullName |
        Select-Object -First 1
}

function Get-ProjectAssemblyName {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $projectFile = Get-PrimaryProjectFile -Root $Root
    if ($null -eq $projectFile) {
        return Split-Path -Leaf $Root
    }

    try {
        $xml = [System.Xml.XmlDocument]::new()
        $xml.PreserveWhitespace = $true
        $xml.Load($projectFile.FullName)

        foreach ($propertyGroup in @($xml.SelectNodes("/Project/PropertyGroup"))) {
            $assemblyNameNode = $propertyGroup.SelectSingleNode("AssemblyName")
            if ($null -ne $assemblyNameNode -and -not [string]::IsNullOrWhiteSpace($assemblyNameNode.InnerText)) {
                return $assemblyNameNode.InnerText.Trim()
            }
        }
    }
    catch {
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($projectFile.Name)
}

function Get-ProjectPublicIdTokens {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$ModId
    )

    $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = @(
        $ModId,
        (Get-ProjectAssemblyName -Root $Root)
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = Convert-ToPublicEntryToken -Value $candidate
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $null = $tokens.Add($normalized)
        }
    }

    return @($tokens | Sort-Object)
}

function Convert-JsonObjectToOrderedDictionary {
    param(
        [Parameter(Mandatory)]
        $JsonObject
    )

    $dictionary = [ordered]@{}

    if ($JsonObject -is [System.Collections.IDictionary]) {
        foreach ($key in $JsonObject.Keys) {
            $dictionary[[string]$key] = $JsonObject[$key]
        }

        return $dictionary
    }

    foreach ($property in $JsonObject.PSObject.Properties) {
        $dictionary[[string]$property.Name] = $property.Value
    }

    return $dictionary
}

function Update-LocalizationAliasFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [object[]]$ClassMetadata,
        [Parameter(Mandatory)]
        [string[]]$PublicIdTokens
    )

    $tableSpecsByKind = @{
        card = @{ Table = "cards"; Category = "CARD" }
        relic = @{ Table = "relics"; Category = "RELIC" }
        power = @{ Table = "powers"; Category = "POWER" }
        character = @{ Table = "characters"; Category = "CHARACTER" }
        monster = @{ Table = "monsters"; Category = "MONSTER" }
        potion = @{ Table = "potions"; Category = "POTION" }
        ancient = @{ Table = "ancients"; Category = "ANCIENT" }
        encounter = @{ Table = "encounters"; Category = "ENCOUNTER" }
    }

    $normalizedPublicIdTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($token in $PublicIdTokens) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        $normalized = Convert-ToPublicEntryToken -Value $token
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $null = $normalizedPublicIdTokens.Add($normalized)
        }
    }

    if ($normalizedPublicIdTokens.Count -eq 0) {
        return
    }

    $categoryByTable = @{}
    foreach ($kind in $tableSpecsByKind.Keys) {
        $tableSpec = $tableSpecsByKind[$kind]
        $categoryByTable[$tableSpec.Table] = $tableSpec.Category
    }

    $locFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.json" | Where-Object {
        $_.FullName -notmatch '\\(\.git|bin|obj|packages)\\' -and
        $_.FullName -match '[\\/]+localization[\\/]+[^\\/]+[\\/]+[^\\/]+\.json$'
    }

    foreach ($file in $locFiles) {
        $tableName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if (-not $categoryByTable.ContainsKey($tableName)) {
            continue
        }

        $expectedCategory = $categoryByTable[$tableName]
        $original = Get-Content -LiteralPath $file.FullName -Raw
        $parsed = $original | ConvertFrom-Json
        if ($null -eq $parsed) {
            continue
        }

        $json = Convert-JsonObjectToOrderedDictionary -JsonObject $parsed
        $changed = $false
        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $json.Keys) {
            $keys.Add([string]$key)
        }

        foreach ($key in $keys) {
            $categorizedMatch = [System.Text.RegularExpressions.Regex]::Match(
                $key,
                '^(?<legacyPrefix>.+?)[\-_](?<category>[A-Z]+)[\-_](?<stem>.+?)(?<suffix>\..+)$'
            )
            $legacyMatch = $null

            if ($categorizedMatch.Success) {
                if (-not $categorizedMatch.Groups["category"].Value.Equals($expectedCategory, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $categorizedMatch = $null
                }
            }

            if (-not $categorizedMatch.Success) {
                $legacyMatch = [System.Text.RegularExpressions.Regex]::Match(
                    $key,
                    '^(?<legacyPrefix>.+?)[\-_](?<stem>.+?)(?<suffix>\..+)$'
                )
                if (-not $legacyMatch.Success) {
                    continue
                }
            }

            $match = if ($categorizedMatch.Success) { $categorizedMatch } else { $legacyMatch }
            $stem = $match.Groups["stem"].Value
            $suffix = $match.Groups["suffix"].Value
            if ([string]::IsNullOrWhiteSpace($stem) -or [string]::IsNullOrWhiteSpace($suffix)) {
                continue
            }

            foreach ($stemVariant in (Get-CompatibilityStemVariants -Stem $stem | Sort-Object)) {
                foreach ($publicIdToken in ($normalizedPublicIdTokens | Sort-Object)) {
                    $newKey = $publicIdToken + "_" + $expectedCategory + "_" + $stemVariant + $suffix
                    if ($key -eq $newKey -or $json.Contains($newKey)) {
                        continue
                    }

                    $json[$newKey] = $json[$key]
                    $changed = $true
                }
            }
        }

        if (-not $changed) {
            continue
        }

        if ($Apply) {
            $updated = $json | ConvertTo-Json -Depth 100
            Write-Utf8File -Path $file.FullName -Content ($updated + [Environment]::NewLine)
        }

        Add-ChangedFile -Path $file.FullName -Reason "added localization aliases for Ritsu public entries"
    }
}

function Update-AssetAliasFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [object[]]$ClassMetadata,
        [Parameter(Mandatory)]
        [string[]]$PublicIdTokens
    )

    $assetSpecsByKind = @{
        card = @{ Subdir = "cards"; Category = "card" }
        relic = @{ Subdir = "relics"; Category = "relic" }
        power = @{ Subdir = "powers"; Category = "power" }
    }

    $normalizedPublicIdTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($token in $PublicIdTokens) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        $normalized = Convert-ToPublicEntryToken -Value $token
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $null = $normalizedPublicIdTokens.Add($normalized)
        }
    }

    if ($normalizedPublicIdTokens.Count -eq 0) {
        return
    }

    $assetDirectoriesByKind = @{}
    foreach ($kind in $assetSpecsByKind.Keys) {
        $spec = $assetSpecsByKind[$kind]
        $assetDirectoriesByKind[$kind] = @(
            Get-ChildItem -LiteralPath $Root -Recurse -Directory | Where-Object {
                $_.FullName -notmatch '\\(\.git|bin|obj|packages)\\' -and
                $_.Name -ieq $spec.Subdir -and
                $null -ne $_.Parent -and
                $_.Parent.Name -ieq 'images'
            }
        )
    }

    foreach ($kind in $assetSpecsByKind.Keys) {
        $spec = $assetSpecsByKind[$kind]
        $assetDirectories = @($assetDirectoriesByKind[$kind])
        if ($assetDirectories.Count -eq 0) {
            continue
        }

        foreach ($assetDirectory in $assetDirectories) {
            foreach ($sourceFile in Get-ChildItem -LiteralPath $assetDirectory.FullName -File -Filter "*.png") {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name).ToLowerInvariant()
                $categorizedMatch = [System.Text.RegularExpressions.Regex]::Match(
                    $baseName,
                    '^(?<legacyPrefix>.+?)[\-_](?<category>' + [System.Text.RegularExpressions.Regex]::Escape($spec.Category) + ')[\-_](?<stem>.+)$'
                )
                $legacyMatch = $null

                if ($categorizedMatch.Success) {
                    $typeStemLower = $categorizedMatch.Groups["stem"].Value.ToLowerInvariant()
                }
                else {
                    $legacyMatch = [System.Text.RegularExpressions.Regex]::Match(
                        $baseName,
                        '^(?<legacyPrefix>.+?)[\-_](?<stem>.+)$'
                    )
                    if (-not $legacyMatch.Success) {
                        continue
                    }

                    $typeStemLower = $legacyMatch.Groups["stem"].Value.ToLowerInvariant()
                }

                if ([string]::IsNullOrWhiteSpace($typeStemLower)) {
                    continue
                }

                foreach ($stemVariant in (Get-CompatibilityStemVariants -Stem $typeStemLower | Sort-Object)) {
                    foreach ($publicIdToken in ($normalizedPublicIdTokens | Sort-Object)) {
                        $targetBaseName = $publicIdToken.ToLowerInvariant() + "_" + $spec.Category + "_" + $stemVariant.ToLowerInvariant()
                        if ($baseName.Equals($targetBaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
                            continue
                        }

                        $targetPath = Join-Path $sourceFile.DirectoryName ($targetBaseName + $sourceFile.Extension.ToLowerInvariant())
                        if (Test-Path -LiteralPath $targetPath) {
                            continue
                        }

                        if ($Apply) {
                            Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath
                        }

                        Add-ChangedFile -Path $targetPath -Reason "added asset aliases for Ritsu public entries"
                    }
                }
            }
        }
    }
}

function Get-SanitizedCSharpText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $chars = $Text.ToCharArray()
    $length = $chars.Length
    $index = 0

    while ($index -lt $length) {
        $current = $chars[$index]

        if ($current -eq "/" -and $index + 1 -lt $length) {
            $next = $chars[$index + 1]
            if ($next -eq "/") {
                $chars[$index] = " "
                $chars[$index + 1] = " "
                $index += 2
                while ($index -lt $length -and $chars[$index] -ne "`r" -and $chars[$index] -ne "`n") {
                    $chars[$index] = " "
                    $index++
                }
                continue
            }

            if ($next -eq "*") {
                $chars[$index] = " "
                $chars[$index + 1] = " "
                $index += 2
                while ($index + 1 -lt $length -and -not ($chars[$index] -eq "*" -and $chars[$index + 1] -eq "/")) {
                    if ($chars[$index] -ne "`r" -and $chars[$index] -ne "`n") {
                        $chars[$index] = " "
                    }
                    $index++
                }

                if ($index + 1 -lt $length) {
                    $chars[$index] = " "
                    $chars[$index + 1] = " "
                    $index += 2
                }

                continue
            }
        }

        if ($current -eq '"') {
            $isVerbatimString = $index -gt 0 -and $chars[$index - 1] -eq "@"
            $chars[$index] = " "
            $index++

            while ($index -lt $length) {
                if ($chars[$index] -eq "`r" -or $chars[$index] -eq "`n") {
                    $index++
                    continue
                }

                if ($isVerbatimString) {
                    if ($chars[$index] -eq '"' -and $index + 1 -lt $length -and $chars[$index + 1] -eq '"') {
                        $chars[$index] = " "
                        $chars[$index + 1] = " "
                        $index += 2
                        continue
                    }

                    if ($chars[$index] -eq '"') {
                        $chars[$index] = " "
                        $index++
                        break
                    }

                    $chars[$index] = " "
                    $index++
                    continue
                }

                if ($chars[$index] -eq "\") {
                    $chars[$index] = " "
                    if ($index + 1 -lt $length) {
                        $chars[$index + 1] = " "
                    }
                    $index += 2
                    continue
                }

                if ($chars[$index] -eq '"') {
                    $chars[$index] = " "
                    $index++
                    break
                }

                $chars[$index] = " "
                $index++
            }

            continue
        }

        if ($current -eq "'") {
            $chars[$index] = " "
            $index++

            while ($index -lt $length) {
                if ($chars[$index] -eq "\") {
                    $chars[$index] = " "
                    if ($index + 1 -lt $length) {
                        $chars[$index + 1] = " "
                    }
                    $index += 2
                    continue
                }

                if ($chars[$index] -eq "'") {
                    $chars[$index] = " "
                    $index++
                    break
                }

                if ($chars[$index] -ne "`r" -and $chars[$index] -ne "`n") {
                    $chars[$index] = " "
                }
                $index++
            }

            continue
        }

        $index++
    }

    return (-join $chars)
}

function Find-MatchingDelimiter {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$OpenIndex,
        [Parameter(Mandatory)]
        [char]$OpenChar,
        [Parameter(Mandatory)]
        [char]$CloseChar
    )

    $depth = 0
    for ($index = $OpenIndex; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq $OpenChar) {
            $depth++
            continue
        }

        if ($Text[$index] -eq $CloseChar) {
            $depth--
            if ($depth -eq 0) {
                return $index
            }
        }
    }

    throw "Could not find matching '$CloseChar' for '$OpenChar' at index $OpenIndex."
}

function Get-CSharpNamespaceMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $namespaceRegex = [System.Text.RegularExpressions.Regex]::new(
        '(?m)^[ \t]*namespace\s+(?<name>[\w\.]+)\s*(?<term>;|\{)'
    )

    $spans = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $namespaceRegex.Matches($Text)) {
        $name = $match.Groups["name"].Value
        $term = $match.Groups["term"].Value
        $end = if ($term -eq ";") {
            $Text.Length - 1
        }
        else {
            $openBraceIndex = $match.Index + $match.Value.LastIndexOf("{")
            Find-MatchingDelimiter -Text $Text -OpenIndex $openBraceIndex -OpenChar "{" -CloseChar "}"
        }

        $spans.Add([pscustomobject]@{
                Name = $name
                Start = $match.Index
                End = $end
                FullName = $null
                Level = 0
            })
    }

    $sortedSpans = @($spans | Sort-Object Start, @{ Expression = { $_.End }; Descending = $true })
    $stack = [System.Collections.Generic.List[object]]::new()

    foreach ($span in $sortedSpans) {
        while ($stack.Count -gt 0 -and $span.Start -gt $stack[$stack.Count - 1].End) {
            $stack.RemoveAt($stack.Count - 1)
        }

        $parent = $null
        if ($stack.Count -gt 0 -and $span.End -le $stack[$stack.Count - 1].End) {
            $parent = $stack[$stack.Count - 1]
        }

        $span.Level = if ($null -ne $parent) { $parent.Level + 1 } else { 0 }
        $span.FullName = if ($null -ne $parent) { $parent.FullName + "." + $span.Name } else { $span.Name }
        $stack.Add($span)
    }

    return $sortedSpans
}

function Get-TextWithBlankedRanges {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$BaseOffset,
        [object[]]$Ranges
    )

    if ($null -eq $Ranges -or $Ranges.Count -eq 0) {
        return $Text
    }

    $chars = $Text.ToCharArray()
    foreach ($range in $Ranges) {
        $start = [Math]::Max(0, $range.Start - $BaseOffset)
        $end = [Math]::Min($chars.Length - 1, $range.End - $BaseOffset)

        for ($index = $start; $index -le $end; $index++) {
            if ($chars[$index] -ne "`r" -and $chars[$index] -ne "`n") {
                $chars[$index] = " "
            }
        }
    }

    return (-join $chars)
}

function Get-DirectMethodNames {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $methodRegex = [System.Text.RegularExpressions.Regex]::new(
        '(?ms)(?:^[ \t]*\[[^\r\n]*\][ \t]*\r?\n)*^[ \t]*(?:(?:public|internal|protected|private|static|abstract|virtual|override|sealed|extern|unsafe|async|partial|new)\s+)*(?:[\w<>\[\],\.\?]+\s+)+(?<name>\w+)\s*\('
    )

    return @(
        $methodRegex.Matches($Text) |
            ForEach-Object { $_.Groups["name"].Value } |
            Select-Object -Unique
    )
}

function Get-ClassMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $classRegex = [System.Text.RegularExpressions.Regex]::new(
        '(?ms)(?<attrs>(?:^[ \t]*\[[^\r\n]*\][ \t]*\r?\n)*)^[ \t]*(?<mods>(?:(?:public|internal|protected|private|file|static|abstract|sealed|partial)\s+)*)class\s+(?<name>\w+)(?<generic>\s*<[^>\r\n]+>)?(?:\s*\([^)]*\))?(?:\s*:\s*(?<base>[^{\r\n]+))?\s*\{'
    )

    $classes = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ProjectFiles -Root $Root -Filter "*.cs") {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $sanitizedText = Get-SanitizedCSharpText -Text $text
        $namespaceSpans = Get-CSharpNamespaceMetadata -Text $sanitizedText

        foreach ($match in $classRegex.Matches($sanitizedText)) {
            $name = $match.Groups["name"].Value
            $baseText = $match.Groups["base"].Value.Trim()
            $baseType = if ([string]::IsNullOrWhiteSpace($baseText)) { "" } else { $baseText.Split(",")[0].Trim() }
            $poolMatch = [System.Text.RegularExpressions.Regex]::Match(
                $match.Groups["attrs"].Value,
                '\[(?:\w+\.)*Pool\(typeof\((?<pool>[\w\.]+)\)\)\]'
            )

            $openBraceIndex = $match.Index + $match.Value.LastIndexOf("{")
            $closeBraceIndex = Find-MatchingDelimiter -Text $sanitizedText -OpenIndex $openBraceIndex -OpenChar "{" -CloseChar "}"
            $poolType = if ($poolMatch.Success) { $poolMatch.Groups["pool"].Value } else { $null }

            $enclosingNamespaces = @(
                $namespaceSpans |
                    Where-Object { $_.Start -le $match.Index -and $_.End -ge $closeBraceIndex } |
                    Sort-Object Level -Descending
            )
            $namespace = if ($enclosingNamespaces.Count -gt 0) { $enclosingNamespaces[0].FullName } else { "" }

            $classes.Add([pscustomobject]@{
                    Name = $name
                    FullName = $null
                    Namespace = $namespace
                    File = $file.FullName
                    IsAbstract = $match.Groups["mods"].Value -match '\babstract\b'
                    BaseType = $baseType
                    BaseTypeRoot = if ([string]::IsNullOrWhiteSpace($baseType)) { $null } else { Get-TypeRootName -TypeName $baseType }
                    PoolType = $poolType
                    PoolTypeRoot = if ($poolType) { Get-TypeRootName -TypeName $poolType } else { $null }
                    Text = $text.Substring($match.Index, $closeBraceIndex - $match.Index + 1)
                    AttributesText = $text.Substring($match.Groups["attrs"].Index, $match.Groups["attrs"].Length)
                    HeaderStart = $match.Index
                    OpenBraceIndex = $openBraceIndex
                    End = $closeBraceIndex
                    HeaderText = $text.Substring($match.Index, $openBraceIndex - $match.Index).TrimEnd()
                    BodyText = if ($closeBraceIndex -gt $openBraceIndex) { $text.Substring($openBraceIndex + 1, $closeBraceIndex - $openBraceIndex - 1) } else { "" }
                    BodyTextSanitized = if ($closeBraceIndex -gt $openBraceIndex) { $sanitizedText.Substring($openBraceIndex + 1, $closeBraceIndex - $openBraceIndex - 1) } else { "" }
                    ParentClass = $null
                    ChildClasses = [System.Collections.Generic.List[object]]::new()
                    TypePath = $null
                    DirectBodyTextSanitized = $null
                    DirectMethodNames = @()
                })
        }
    }

    $sortedClasses = @($classes | Sort-Object File, HeaderStart, @{ Expression = { $_.End }; Descending = $true })
    $stack = [System.Collections.Generic.List[object]]::new()
    $currentFile = $null

    foreach ($class in $sortedClasses) {
        if ($class.File -ne $currentFile) {
            $stack.Clear()
            $currentFile = $class.File
        }

        while ($stack.Count -gt 0 -and $class.HeaderStart -gt $stack[$stack.Count - 1].End) {
            $stack.RemoveAt($stack.Count - 1)
        }

        if ($stack.Count -gt 0 -and $class.End -le $stack[$stack.Count - 1].End) {
            $class.ParentClass = $stack[$stack.Count - 1]
            $class.ParentClass.ChildClasses.Add($class)
        }

        $class.TypePath = if ($null -ne $class.ParentClass) { $class.ParentClass.TypePath + "." + $class.Name } else { $class.Name }
        $class.FullName = if ([string]::IsNullOrWhiteSpace($class.Namespace)) { $class.TypePath } else { $class.Namespace + "." + $class.TypePath }
        $stack.Add($class)
    }

    foreach ($class in $sortedClasses) {
        $directBodyText = Get-TextWithBlankedRanges -Text $class.BodyTextSanitized -BaseOffset ($class.OpenBraceIndex + 1) -Ranges @($class.ChildClasses)
        $class.DirectBodyTextSanitized = $directBodyText
        $class.DirectMethodNames = Get-DirectMethodNames -Text $directBodyText
    }

    return $sortedClasses
}

function Resolve-ClassKind {
    param(
        [Parameter(Mandatory)]
        $ClassItem,
        [Parameter(Mandatory)]
        [hashtable]$ClassMap
    )

    $knownKinds = @{
        CustomCardModel = "card"
        ConstructedCardModel = "card"
        CustomRelicModel = "relic"
        CustomPotionModel = "potion"
        CustomCharacterModel = "character"
        PlaceholderCharacterModel = "character"
        CustomMonsterModel = "monster"
        CustomPowerModel = "power"
        CustomTemporaryPowerModel = "power"
        CustomTemporaryPowerModelWrapper = "power"
        CustomCardPoolModel = "cardpool"
        CustomRelicPoolModel = "relicpool"
        CustomPotionPoolModel = "potionpool"
        CustomEncounterModel = "encounter"
        CustomAncientModel = "ancient"
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $current = $ClassItem

    while ($null -ne $current) {
        $baseRoot = $current.BaseTypeRoot
        if ([string]::IsNullOrWhiteSpace($baseRoot)) {
            return $null
        }

        if ($knownKinds.ContainsKey($baseRoot)) {
            return $knownKinds[$baseRoot]
        }

        if (-not $seen.Add($baseRoot)) {
            return $null
        }

        if ($ClassMap.ContainsKey($baseRoot)) {
            $current = $ClassMap[$baseRoot]
            continue
        }

        return $null
    }

    return $null
}

function Test-IsSharedPool {
    param(
        [Parameter(Mandatory)]
        $ClassItem
    )

    return $ClassItem.Text -match 'override\s+bool\s+IsShared\s*=>\s*true\s*;'
}

function Test-IsLegacyHarmonyPatchClass {
    param(
        [Parameter(Mandatory)]
        $ClassItem
    )

    $hasHeaderPatchContext = $ClassItem.AttributesText -match '\bHarmony(?:Patch|Prepare|Cleanup|TargetMethod|TargetMethods|ReversePatch|PatchCategory)\b'
    $hasDirectPatchDeclaration = $ClassItem.DirectBodyTextSanitized -match '\bHarmonyPatch\b'
    $hasDirectPatchImplementation = $ClassItem.DirectBodyTextSanitized -match '\bHarmony(?:Prefix|Postfix|Transpiler|Finalizer|Prepare|Cleanup|TargetMethod|TargetMethods|ReversePatch)\b'
    $hasConventionMethod = @(
        $ClassItem.DirectMethodNames |
            Where-Object { $_ -in @("Prefix", "Postfix", "Transpiler", "Finalizer", "Prepare", "Cleanup", "TargetMethod", "TargetMethods") }
    ).Count -gt 0

    return ($hasHeaderPatchContext -or $hasDirectPatchDeclaration) -and ($hasDirectPatchImplementation -or $hasConventionMethod -or $hasDirectPatchDeclaration)
}

function Add-ClassInventorySection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        [object[]]$Items
    )

    if ($null -eq $Items) {
        $Items = @()
    }

    $Lines.Add("### " + $Title)
    $Lines.Add("")

    if ($Items.Count -eq 0) {
        $Lines.Add("- None detected.")
        $Lines.Add("")
        return
    }

    foreach ($item in $Items) {
        $summary = "- " + $item.FullName + " | base: " + $item.BaseTypeRoot
        if (-not [string]::IsNullOrWhiteSpace($item.PoolTypeRoot)) {
            $summary += " | pool: " + $item.PoolTypeRoot
        }
        $summary += " | file: " + $item.File
        $Lines.Add($summary)
    }

    $Lines.Add("")
}

function Update-GeneratedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$Reason
    )

    $original = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw } else { $null }
    if ($Content -eq $original) {
        return $false
    }

    if ($Apply) {
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -Path $directory -ItemType Directory -Force
        }

        Write-Utf8File -Path $Path -Content $Content
    }

    Add-ChangedFile -Path $Path -Reason $Reason
    return $true
}

function Get-LineNumberFromIndex {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$Index
    )

    if ($Index -le 0) {
        return 1
    }

    return ([System.Text.RegularExpressions.Regex]::Matches($Text.Substring(0, $Index), "`n")).Count + 1
}

function Update-CSharpPatchBootstrapFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $sanitized = Get-SanitizedCSharpText -Text $original
    $callRegex = [System.Text.RegularExpressions.Regex]::new(
        '(?<receiver>\b[A-Za-z_][\w\.]*)\s*\.\s*TryPatchAll\s*\('
    )

    $builder = [System.Text.StringBuilder]::new()
    $cursor = 0
    $replacedCount = 0
    $unsupportedCalls = [System.Collections.Generic.List[object]]::new()

    foreach ($match in $callRegex.Matches($sanitized)) {
        if ($match.Index -lt $cursor) {
            continue
        }

        $openParenIndex = $match.Index + $match.Value.LastIndexOf("(")
        $closeParenIndex = Find-MatchingDelimiter -Text $sanitized -OpenIndex $openParenIndex -OpenChar "(" -CloseChar ")"
        $argumentsText = $original.Substring($openParenIndex + 1, $closeParenIndex - $openParenIndex - 1)
        $receiverText = $original.Substring($match.Groups["receiver"].Index, $match.Groups["receiver"].Length).Trim()

        $null = $builder.Append($original.Substring($cursor, $match.Index - $cursor))

        if ($argumentsText -match ",") {
            $null = $builder.Append($original.Substring($match.Index, $closeParenIndex - $match.Index + 1))
            $unsupportedCalls.Add([pscustomobject]@{
                    Path = $File.FullName
                    Line = Get-LineNumberFromIndex -Text $original -Index $match.Index
                    Text = $original.Substring($match.Index, $closeParenIndex - $match.Index + 1).Trim()
                })
            $cursor = $closeParenIndex + 1
            continue
        }

        $null = $builder.Append('global::BaseLibToRitsu.Generated.LegacyHarmonyPatchBootstrap.Apply(' + $receiverText + ')')
        $cursor = $closeParenIndex + 1
        $replacedCount++
    }

    $null = $builder.Append($original.Substring($cursor))
    $updated = $builder.ToString()

    if ($replacedCount -gt 0 -and $updated -notmatch '\bTryPatchAll\s*\(') {
        $updated = [System.Text.RegularExpressions.Regex]::Replace(
            $updated,
            '(?m)^\s*using\s+BaseLib\.Extensions\s*;\r?\n',
            ''
        )
    }

    if ($updated -ne $original) {
        if ($Apply) {
            Write-Utf8File -Path $File.FullName -Content $updated
        }

        Add-ChangedFile -Path $File.FullName -Reason "rewrote TryPatchAll startup to generated legacy Harmony bootstrap"
    }

    return [pscustomobject]@{
        ReplacedCount = $replacedCount
        UnsupportedCalls = @($unsupportedCalls)
    }
}

function Get-LegacyHarmonyBootstrapContent {
    param(
        [Parameter(Mandatory)]
        [object[]]$PatchClasses
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("using System;")
    $lines.Add("using HarmonyLib;")
    $lines.Add("")
    $lines.Add("namespace BaseLibToRitsu.Generated;")
    $lines.Add("")
    $lines.Add("internal static class LegacyHarmonyPatchBootstrap")
    $lines.Add("{")
    $lines.Add("    public static bool Apply(Harmony harmony)")
    $lines.Add("    {")
    $lines.Add("        bool success = true;")

    foreach ($patchClass in $PatchClasses) {
        $lines.Add('        TryPatch(harmony, typeof(global::' + $patchClass.FullName + '), ref success);')
    }

    $lines.Add("        return success;")
    $lines.Add("    }")
    $lines.Add("")
    $lines.Add("    private static void TryPatch(Harmony harmony, Type patchType, ref bool success)")
    $lines.Add("    {")
    $lines.Add("        try")
    $lines.Add("        {")
    $lines.Add("            harmony.CreateClassProcessor(patchType).Patch();")
    $lines.Add("        }")
    $lines.Add("        catch (Exception ex)")
    $lines.Add("        {")
    $lines.Add('            success = false;')
    $lines.Add('            Console.Error.WriteLine($"[BaseLibToRitsu] Failed to patch {patchType.FullName}: {ex}");')
    $lines.Add("        }")
    $lines.Add("    }")
    $lines.Add("}")

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-MigrationSupportContent {
    $templatePath = Join-Path $PSScriptRoot "BaseLibToRitsuMigrationSupport.template.cs"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Could not find migration support template '$templatePath'."
    }

    return Get-Content -LiteralPath $templatePath -Raw
}

function Get-CompatibilitySupportContent {
    $templatePath = Join-Path $PSScriptRoot "BaseLibToRitsuCompatibility.template.cs"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Could not find compatibility support template '$templatePath'."
    }

    return Get-Content -LiteralPath $templatePath -Raw
}

function Update-CSharpMigrationSupportFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    $original = Get-Content -LiteralPath $File.FullName -Raw
    $updated = $original

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.Utils(?:\.NodeFactories|\.Attributes)?\s*;',
        '$1using BaseLibToRitsu.Generated;'
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.(?:Abstracts|Config)\s*;',
        '$1using BaseLibToRitsu.Generated;'
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.Extensions\s*;',
        '$1using BaseLibToRitsu.Generated;'
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.Patches\.Content\s*;',
        '$1using BaseLibToRitsu.Generated;'
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '(?m)^(\s*)using\s+BaseLib\.Patches\.UI\s*;',
        '$1using BaseLibToRitsu.Generated;'
    )
    $updated = Remove-DuplicateUsingDirective -Text $updated -Namespace "BaseLibToRitsu.Generated"

    $updated = $updated.Replace("BaseLib.Abstracts.", "BaseLibToRitsu.Generated.")
    $updated = $updated.Replace("BaseLib.Config.", "BaseLibToRitsu.Generated.")
    $updated = $updated.Replace("BaseLib.Extensions.", "BaseLibToRitsu.Generated.")
    $updated = $updated.Replace("BaseLib.Patches.Content.", "BaseLibToRitsu.Generated.")
    $updated = $updated.Replace("BaseLib.Patches.UI.", "BaseLibToRitsu.Generated.")

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*<\s*(?<type>[^>]+?)\s*>\s*\.\s*CreateFromScenePath\s*\(',
        'LegacyNodeFactory.CreateFromScenePath<${type}>('
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*<\s*(?<type>[^>]+?)\s*>\s*\.\s*CreateFromScene\s*\(',
        'LegacyNodeFactory.CreateFromScene<${type}>('
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*<\s*(?<type>[^>]+?)\s*>\s*\.\s*CreateFromResource\s*\(',
        'LegacyNodeFactory.CreateFromResource<${type}>('
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*\.\s*Init\s*\(',
        'LegacyNodeFactory.Init('
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*\.\s*RegisterSceneType\b',
        'LegacyNodeFactory.RegisterSceneType'
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*\.\s*IsRegistered\s*\(',
        'LegacyNodeFactory.IsRegistered('
    )

    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $updated,
        '\bNodeFactory\s*\.\s*UnregisterSceneType\s*\(',
        'LegacyNodeFactory.UnregisterSceneType('
    )

    if ($updated -eq $original) {
        return $false
    }

    if ($Apply) {
        Write-Utf8File -Path $File.FullName -Content $updated
    }

    Add-ChangedFile -Path $File.FullName -Reason "rewrote BaseLib.Utils usage to generated migration support"
    return $true
}

function Get-ManualHarmonyPatchSites {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($file in Get-ProjectFiles -Root $Root -Filter "*.cs" | Where-Object { $_.FullName -ne $script:LegacyHarmonyBootstrapPath }) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            $lineNumber++
            if ($line -match '\b[A-Za-z_][\w]*\s*\.\s*Patch\s*\(') {
                $results.Add([pscustomobject]@{
                        Path = $file.FullName
                        Line = $lineNumber
                        Text = $line.Trim()
                    })
            }
        }
    }

    return $results
}

function Get-ContentRegistrationScaffold {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [object[]]$ClassMetadata
    )

    $modId = Get-ProjectManifestId -Root $Root
    $classes = if ($null -ne $ClassMetadata -and $ClassMetadata.Count -gt 0) { @($ClassMetadata) } else { @(Get-ClassMetadata -Root $Root) }
    $classMap = @{}
    foreach ($class in $classes) {
        if (-not $classMap.ContainsKey($class.Name)) {
            $classMap[$class.Name] = $class
        }
    }

    foreach ($class in $classes) {
        $class | Add-Member -NotePropertyName Kind -NotePropertyValue (Resolve-ClassKind -ClassItem $class -ClassMap $classMap) -Force
        $class | Add-Member -NotePropertyName IsSharedPool -NotePropertyValue (Test-IsSharedPool -ClassItem $class) -Force
    }

    $characters = @($classes | Where-Object { $_.Kind -eq "character" -and -not $_.IsAbstract } | Sort-Object FullName)
    $powers = @($classes | Where-Object { $_.Kind -eq "power" -and -not $_.IsAbstract } | Sort-Object FullName)
    $monsters = @($classes | Where-Object { $_.Kind -eq "monster" -and -not $_.IsAbstract } | Sort-Object FullName)
    $encounters = @($classes | Where-Object { $_.Kind -eq "encounter" -and -not $_.IsAbstract } | Sort-Object FullName)
    $ancients = @($classes | Where-Object { $_.Kind -eq "ancient" -and -not $_.IsAbstract } | Sort-Object FullName)
    $cards = @($classes | Where-Object {
        $_.Kind -eq "card" -and -not $_.IsAbstract -and -not [string]::IsNullOrWhiteSpace($_.PoolTypeRoot)
    } | Sort-Object FullName)
    $relics = @($classes | Where-Object {
        $_.Kind -eq "relic" -and -not $_.IsAbstract -and -not [string]::IsNullOrWhiteSpace($_.PoolTypeRoot)
    } | Sort-Object FullName)
    $potions = @($classes | Where-Object {
        $_.Kind -eq "potion" -and -not $_.IsAbstract -and -not [string]::IsNullOrWhiteSpace($_.PoolTypeRoot)
    } | Sort-Object FullName)

    $sharedCardPools = @($classes | Where-Object { $_.Kind -eq "cardpool" -and -not $_.IsAbstract -and $_.IsSharedPool } | Sort-Object FullName)
    $sharedRelicPools = @($classes | Where-Object { $_.Kind -eq "relicpool" -and -not $_.IsAbstract -and $_.IsSharedPool } | Sort-Object FullName)
    $sharedPotionPools = @($classes | Where-Object { $_.Kind -eq "potionpool" -and -not $_.IsAbstract -and $_.IsSharedPool } | Sort-Object FullName)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Ritsu content-pack scaffold")
    $lines.Add("")
    $lines.Add("- Generated from source patterns after removing the BaseLib project dependency.")
    $lines.Add("- This scaffold does not recreate BaseLib APIs; it only proposes RitsuLib registration calls.")
    $lines.Add("- You still need to rewrite BaseLib-based model classes to native game or Ritsu-compatible types before this code can compile.")
    $lines.Add("")
    $lines.Add("## Suggested registration skeleton")
    $lines.Add("")
    $lines.Add('```csharp')
    $lines.Add('RitsuLibFramework.CreateContentPack("' + $modId + '")')

    foreach ($pool in $sharedCardPools) {
        $lines.Add('    .SharedCardPool<' + $pool.FullName + '>()')
    }
    foreach ($pool in $sharedRelicPools) {
        $lines.Add('    .SharedRelicPool<' + $pool.FullName + '>()')
    }
    foreach ($pool in $sharedPotionPools) {
        $lines.Add('    .SharedPotionPool<' + $pool.FullName + '>()')
    }
    foreach ($character in $characters) {
        $lines.Add('    .Character<' + $character.FullName + '>()')
    }
    foreach ($card in $cards) {
        $cardPoolType = if ($classMap.ContainsKey($card.PoolTypeRoot)) { $classMap[$card.PoolTypeRoot].FullName } elseif ($card.PoolType) { $card.PoolType } else { $card.PoolTypeRoot }
        $lines.Add('    .Card<' + $cardPoolType + ', ' + $card.FullName + '>()')
    }
    foreach ($relic in $relics) {
        $relicPoolType = if ($classMap.ContainsKey($relic.PoolTypeRoot)) { $classMap[$relic.PoolTypeRoot].FullName } elseif ($relic.PoolType) { $relic.PoolType } else { $relic.PoolTypeRoot }
        $lines.Add('    .Relic<' + $relicPoolType + ', ' + $relic.FullName + '>()')
    }
    foreach ($potion in $potions) {
        $potionPoolType = if ($classMap.ContainsKey($potion.PoolTypeRoot)) { $classMap[$potion.PoolTypeRoot].FullName } elseif ($potion.PoolType) { $potion.PoolType } else { $potion.PoolTypeRoot }
        $lines.Add('    .Potion<' + $potionPoolType + ', ' + $potion.FullName + '>()')
    }
    foreach ($power in $powers) {
        $lines.Add('    .Power<' + $power.FullName + '>()')
    }

    $lines.Add("    .Apply();")
    $lines.Add("")
    $lines.Add('var content = RitsuLibFramework.GetContentRegistry("' + $modId + '");')

    if (@($monsters).Count -gt 0) {
        foreach ($monster in $monsters) {
            $lines.Add('content.RegisterMonster<' + $monster.FullName + '>();')
        }
    }
    else {
        $lines.Add("// No custom monster classes were detected.")
    }

    if (@($encounters).Count -gt 0) {
        $lines.Add("// Choose one registration style per encounter:")
        foreach ($encounter in $encounters) {
            $lines.Add('// content.RegisterGlobalEncounter<' + $encounter.FullName + '>();')
            $lines.Add('// content.RegisterActEncounter<TAct, ' + $encounter.FullName + '>();')
        }
    }

    if (@($ancients).Count -gt 0) {
        $lines.Add("// Choose one registration style per ancient:")
        foreach ($ancient in $ancients) {
            $lines.Add('// content.RegisterSharedAncient<' + $ancient.FullName + '>();')
            $lines.Add('// content.RegisterActAncient<TAct, ' + $ancient.FullName + '>();')
        }
    }
    $lines.Add('```')
    $lines.Add("")
    $lines.Add("## Detected types")
    $lines.Add("")
    $lines.Add("- Characters: " + @($characters).Count)
    $lines.Add("- Pool-bound cards: " + @($cards).Count)
    $lines.Add("- Pool-bound relics: " + @($relics).Count)
    $lines.Add("- Pool-bound potions: " + @($potions).Count)
    $lines.Add("- Powers: " + @($powers).Count)
    $lines.Add("- Monsters: " + @($monsters).Count)
    $lines.Add("- Encounters: " + @($encounters).Count)
    $lines.Add("- Ancients: " + @($ancients).Count)
    $lines.Add("")
    $lines.Add("## Content model inventory")
    $lines.Add("")
    $lines.Add("- These classes were detected as still inheriting BaseLib content abstractions or depending on BaseLib pool markers.")
    $lines.Add("- Treat this as the rewrite backlog after dependency conversion and Harmony bootstrap migration.")
    $lines.Add("")
    Add-ClassInventorySection -Lines $lines -Title "Shared Card Pools" -Items @($sharedCardPools)
    Add-ClassInventorySection -Lines $lines -Title "Shared Relic Pools" -Items @($sharedRelicPools)
    Add-ClassInventorySection -Lines $lines -Title "Shared Potion Pools" -Items @($sharedPotionPools)
    Add-ClassInventorySection -Lines $lines -Title "Characters" -Items @($characters)
    Add-ClassInventorySection -Lines $lines -Title "Cards" -Items @($cards)
    Add-ClassInventorySection -Lines $lines -Title "Relics" -Items @($relics)
    Add-ClassInventorySection -Lines $lines -Title "Potions" -Items @($potions)
    Add-ClassInventorySection -Lines $lines -Title "Powers" -Items @($powers)
    Add-ClassInventorySection -Lines $lines -Title "Monsters" -Items @($monsters)
    Add-ClassInventorySection -Lines $lines -Title "Encounters" -Items @($encounters)
    Add-ClassInventorySection -Lines $lines -Title "Ancients" -Items @($ancients)

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-MigrationBuckets {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $godotRecommendation = if ($script:EffectiveMigrationSupport) {
        "Prefer the generated LegacyNodeFactory wrappers for generic migration, or rewrite directly to STS2RitsuLib.Scaffolding.Godot.RitsuGodotNodeFactories."
    }
    else {
        "Replace explicit scene creation with STS2RitsuLib.Scaffolding.Godot.RitsuGodotNodeFactories. Review any old RegisterSceneType auto-conversion manually."
    }

    $savedRuntimeRecommendation = if ($script:EffectiveMigrationSupport) {
        "Prefer the generated project-local SpireField/SavedSpireField helpers for generic migration, or replace them with another save strategy."
    }
    else {
        "Port these to project-local helpers or another save strategy. RitsuLib does not provide a drop-in SavedSpireField API."
    }

    $bucketSpecs = @(
        [pscustomobject]@{
            Name = "Config and settings"
            Pattern = 'using BaseLib\.Config|BaseLib\.Config\.|SimpleModConfig|ModConfigRegistry|Config(?:Section|HoverTip|HoverTipsByDefault|Ignore|HideInUI|TextInput|Button|VisibleIf|Slider|ColorPicker)'
            Recommendation = "Rewrite to ModConfig-STS2 or native Ritsu settings. RitsuLib does not expose BaseLib.Config as a drop-in API."
        },
        [pscustomobject]@{
            Name = "Patch bootstrap"
            Pattern = 'TryPatchAll|using BaseLib\.Extensions|RegisterSceneForConversion'
            Recommendation = "Prefer the generated legacy Harmony bootstrap for generic migration: replace TryPatchAll with CreateClassProcessor(...).Patch() calls per annotated class, then review any manual harmony.Patch(...) sites separately. Full Ritsu ModPatcher migration is still manual."
        },
        [pscustomobject]@{
            Name = "Godot node factories"
            Pattern = 'using BaseLib\.Utils\.NodeFactories|\bNodeFactory(?:<|\.)'
            Recommendation = $godotRecommendation
        },
        [pscustomobject]@{
            Name = "Saved runtime fields"
            Pattern = 'SavedSpireField|SpireField'
            Recommendation = $savedRuntimeRecommendation
        },
        [pscustomobject]@{
            Name = "Content models and pool markers"
            Pattern = 'using BaseLib\.Abstracts|\[Pool|Custom(?:Card|Relic|Potion|Character|Monster|Encounter|Ancient|Power|TemporaryPower)Model|ConstructedCardModel|PlaceholderCharacterModel|Custom(?:Card|Relic|Potion)PoolModel'
            Recommendation = "Rewrite BaseLib abstract models to vanilla or Ritsu-native model types, then register them through CreateContentPack / ModContentRegistry."
        }
    )

    $buckets = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($bucket in $bucketSpecs) {
        $matches = Collect-Matches -Root $Root -Extensions @(".cs") -Pattern $bucket.Pattern
        $buckets.Add([pscustomobject]@{
                Name = $bucket.Name
                Recommendation = $bucket.Recommendation
                Matches = $matches
            })
    }

    return $buckets
}

$ProjectRoot = Resolve-FullPath -Path $ProjectRoot
$OldLibRoot = Resolve-FullPath -Path $OldLibRoot
$NewLibRoot = Resolve-FullPath -Path $NewLibRoot
$effectiveGenerateLegacyHarmonyBootstrap = [bool]($GenerateLegacyHarmonyBootstrap -or $RewritePatchBootstrap)
$effectiveGenerateMigrationSupport = [bool]($GenerateMigrationSupport -or $RewriteMigrationSupportUsings)

if (-not $ReportPath) {
    $ReportPath = Join-Path $ProjectRoot "base-lib-to-ritsu-report.md"
}

if (-not $ScaffoldPath) {
    $ScaffoldPath = Join-Path $ProjectRoot "ritsu-content-pack-scaffold.md"
}

if (-not $LegacyHarmonyBootstrapPath) {
    $LegacyHarmonyBootstrapPath = Join-Path $ProjectRoot "Generated\BaseLibToRitsu\LegacyHarmonyPatchBootstrap.g.cs"
}

$MigrationSupportPath = Join-Path $ProjectRoot "Generated\BaseLibToRitsu\LegacyMigrationSupport.g.cs"
if (-not $CompatibilitySupportPath) {
    $CompatibilitySupportPath = Join-Path $ProjectRoot "Generated\BaseLibToRitsu\LegacyCompatibility.g.cs"
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ScaffoldPath = [System.IO.Path]::GetFullPath($ScaffoldPath)
$LegacyHarmonyBootstrapPath = [System.IO.Path]::GetFullPath($LegacyHarmonyBootstrapPath)
$MigrationSupportPath = [System.IO.Path]::GetFullPath($MigrationSupportPath)
$CompatibilitySupportPath = [System.IO.Path]::GetFullPath($CompatibilitySupportPath)
$script:ReportPath = $ReportPath
$script:ScaffoldPath = $ScaffoldPath
$script:LegacyHarmonyBootstrapPath = $LegacyHarmonyBootstrapPath
$script:MigrationSupportPath = $MigrationSupportPath
$script:CompatibilitySupportPath = $CompatibilitySupportPath
$script:EffectiveMigrationSupport = $effectiveGenerateMigrationSupport

$script:OldLibRootWindows = $OldLibRoot
$script:OldLibRootForward = $OldLibRoot.Replace("\", "/")
$script:NewLibRootWindows = $NewLibRoot
$script:NewLibRootForward = $NewLibRoot.Replace("\", "/")
$script:ChangedFiles = @{}
$script:PatchBootstrapRewriteCount = 0
$script:UnsupportedTryPatchAllCalls = @()
$script:MigrationSupportRewriteFileCount = 0

$newLibCsproj = Get-ChildItem -LiteralPath $NewLibRoot -Filter "*.csproj" -File | Select-Object -First 1
if (-not $newLibCsproj) {
    throw "Could not find a .csproj under '$NewLibRoot'."
}

$script:NewLibCsprojPath = $newLibCsproj.FullName
$newPropsPath = Join-Path $NewLibRoot "Sts2PathDiscovery.props"
if (-not (Test-Path -LiteralPath $newPropsPath)) {
    throw "Could not find '$newPropsPath'."
}

$newManifestPath = Join-Path $NewLibRoot "mod_manifest.json"
$newManifestId = "STS2-RitsuLib"
if (Test-Path -LiteralPath $newManifestPath) {
    $manifestText = Get-Content -LiteralPath $newManifestPath -Raw
    $manifestMatch = [System.Text.RegularExpressions.Regex]::Match($manifestText, '"id"\s*:\s*"(?<id>[^"]+)"')
    if ($manifestMatch.Success) {
        $newManifestId = $manifestMatch.Groups["id"].Value
    }
}

$files = Get-ProjectFiles -Root $ProjectRoot
foreach ($file in $files) {
    switch ($file.Extension) {
        ".csproj" {
            Update-CsprojFile -File $file -NewLibCsprojPath $newLibCsproj.FullName -NewPropsPath $newPropsPath
        }
        ".sln" {
            Update-SolutionFile -File $file -NewLibCsprojPath $newLibCsproj.FullName
        }
        ".props" {
            Update-XmlTextFile -File $file -NewPropsPath $newPropsPath
        }
        ".targets" {
            Update-XmlTextFile -File $file -NewPropsPath $newPropsPath
        }
        ".config" {
            Update-XmlTextFile -File $file -NewPropsPath $newPropsPath
        }
        ".json" {
            Update-JsonFile -File $file -NewManifestId $newManifestId
        }
        ".cs" {
            if ($RewriteSafeCode) {
                Update-CSharpFile -File $file
            }
        }
    }
}

$classMetadata = @(Get-ClassMetadata -Root $ProjectRoot)
$classMap = @{}
foreach ($class in $classMetadata) {
    if (-not $classMap.ContainsKey($class.Name)) {
        $classMap[$class.Name] = $class
    }
}

foreach ($class in $classMetadata) {
    $class | Add-Member -NotePropertyName Kind -NotePropertyValue (Resolve-ClassKind -ClassItem $class -ClassMap $classMap) -Force
    $class | Add-Member -NotePropertyName IsSharedPool -NotePropertyValue (Test-IsSharedPool -ClassItem $class) -Force
    $class | Add-Member -NotePropertyName IsLegacyHarmonyPatchClass -NotePropertyValue (Test-IsLegacyHarmonyPatchClass -ClassItem $class) -Force
}

$projectManifestId = Get-ProjectManifestId -Root $ProjectRoot
$projectPublicIdTokens = Get-ProjectPublicIdTokens -Root $ProjectRoot -ModId $projectManifestId
Update-LocalizationAliasFiles -Root $ProjectRoot -ClassMetadata $classMetadata -PublicIdTokens $projectPublicIdTokens
Update-AssetAliasFiles -Root $ProjectRoot -ClassMetadata $classMetadata -PublicIdTokens $projectPublicIdTokens

$legacyHarmonyPatchClasses = @($classMetadata | Where-Object { $_.IsLegacyHarmonyPatchClass } | Sort-Object FullName)
$tryPatchAllSites = Collect-Matches -Root $ProjectRoot -Extensions @(".cs") -Pattern '\bTryPatchAll\s*\('
$legacyHarmonyBootstrapPrepared = $false
$legacyHarmonyBootstrapChanged = $false

if ($effectiveGenerateLegacyHarmonyBootstrap -and $legacyHarmonyPatchClasses.Count -gt 0) {
    $legacyHarmonyBootstrapPrepared = $true
    $legacyHarmonyBootstrapContent = Get-LegacyHarmonyBootstrapContent -PatchClasses $legacyHarmonyPatchClasses
    $legacyHarmonyBootstrapChanged = Update-GeneratedFile -Path $LegacyHarmonyBootstrapPath -Content $legacyHarmonyBootstrapContent -Reason "generated legacy Harmony patch bootstrap"
}

if ($RewritePatchBootstrap -and $tryPatchAllSites.Count -gt 0 -and $legacyHarmonyPatchClasses.Count -eq 0) {
    throw "Detected TryPatchAll usage but could not discover any directly patchable Harmony classes. Refusing to rewrite patch startup automatically."
}

if ($RewritePatchBootstrap) {
    foreach ($file in Get-ProjectFiles -Root $ProjectRoot -Filter "*.cs") {
        $rewriteResult = Update-CSharpPatchBootstrapFile -File $file
        $script:PatchBootstrapRewriteCount += $rewriteResult.ReplacedCount
        if ($rewriteResult.UnsupportedCalls.Count -gt 0) {
            $script:UnsupportedTryPatchAllCalls += @($rewriteResult.UnsupportedCalls)
        }
    }
}

$migrationSupportPrepared = $false
$migrationSupportChanged = $false
$compatibilitySupportPrepared = $false
$compatibilitySupportChanged = $false
if ($effectiveGenerateMigrationSupport) {
    $migrationSupportPrepared = $true
    $migrationSupportContent = Get-MigrationSupportContent
    $migrationSupportChanged = Update-GeneratedFile -Path $MigrationSupportPath -Content $migrationSupportContent -Reason "generated BaseLib utils migration support"
    $compatibilitySupportPrepared = $true
    $compatibilitySupportContent = Get-CompatibilitySupportContent
    $compatibilitySupportChanged = Update-GeneratedFile -Path $CompatibilitySupportPath -Content $compatibilitySupportContent -Reason "generated BaseLib abstract/config compatibility support"
}

if ($RewriteMigrationSupportUsings) {
    foreach ($file in Get-ProjectFiles -Root $ProjectRoot -Filter "*.cs") {
        if (Update-CSharpMigrationSupportFile -File $file) {
            $script:MigrationSupportRewriteFileCount++
        }
    }
}

$codeBlockers = Collect-Matches -Root $ProjectRoot -Extensions @(".cs") -Pattern '\busing\s+BaseLib(?:\.|;)|\bBaseLib\.'
$docMentions = Collect-Matches -Root $ProjectRoot -Extensions @(".md", ".txt", ".yml", ".yaml", ".json") -Pattern 'BaseLib-StS2-master|Alchyr\.Sts2\.BaseLib|"BaseLib"|BaseLib-StS2|BaseLib\.json'
$migrationBuckets = Get-MigrationBuckets -Root $ProjectRoot
$manualHarmonyPatchSites = Get-ManualHarmonyPatchSites -Root $ProjectRoot

$scaffoldGenerated = $false
if ($GenerateRitsuScaffold) {
    $scaffold = Get-ContentRegistrationScaffold -Root $ProjectRoot -ClassMetadata $classMetadata
    $scaffoldGenerated = Update-GeneratedFile -Path $ScaffoldPath -Content $scaffold -Reason "generated Ritsu content-pack scaffold"
}

$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add("# BaseLib -> RitsuLib migration report")
$reportLines.Add("")
$reportLines.Add("## Scope")
$reportLines.Add("")
$reportLines.Add("- This converter removes the BaseLib project/package dependency and points the project to STS2-RitsuLib.")
$reportLines.Add("- It can generate project-local compatibility shims for commonly used BaseLib abstract/config/utils APIs.")
$reportLines.Add("- Migrated projects also get STS001/STS003 analyzer suppression because the stock analyzers do not understand the generated BaseLib compatibility surface.")
$reportLines.Add("")
$reportLines.Add("## Dependency target")
$reportLines.Add("")
$reportLines.Add("- Project root: " + $ProjectRoot)
$reportLines.Add("- Old library root: " + $OldLibRoot)
$reportLines.Add("- New library root: " + $NewLibRoot)
$reportLines.Add("- New project file: " + (Split-Path -Leaf $newLibCsproj.FullName))
$reportLines.Add("- New manifest id: " + $newManifestId)
$reportLines.Add("- Safe C# rewrites enabled: " + [bool]$RewriteSafeCode)
$reportLines.Add("- Legacy Harmony bootstrap requested: " + $effectiveGenerateLegacyHarmonyBootstrap)
$reportLines.Add("- Patch bootstrap rewrite enabled: " + [bool]$RewritePatchBootstrap)
$reportLines.Add("- Migration support requested: " + $effectiveGenerateMigrationSupport)
$reportLines.Add("- Migration support rewrite enabled: " + [bool]$RewriteMigrationSupportUsings)
$reportLines.Add("- Ritsu scaffold enabled: " + [bool]$GenerateRitsuScaffold)
$reportLines.Add("- Legacy Harmony bootstrap path: " + $LegacyHarmonyBootstrapPath)
$reportLines.Add("- Migration support path: " + $MigrationSupportPath)
$reportLines.Add("- Compatibility support path: " + $CompatibilitySupportPath)
$reportLines.Add("")
$reportLines.Add("## Changed files")
$reportLines.Add("")

if ($script:ChangedFiles.Count -eq 0) {
    $reportLines.Add("- No structured dependency changes were required.")
}
else {
    foreach ($entry in $script:ChangedFiles.GetEnumerator() | Sort-Object Name) {
        $reasons = ($entry.Value | Sort-Object) -join "; "
        $reportLines.Add("- " + $entry.Key + ": " + $reasons)
    }
}

if ($GenerateRitsuScaffold) {
    $reportLines.Add("")
    $reportLines.Add("## Generated scaffold")
    $reportLines.Add("")
    if ($Apply) {
        if ($scaffoldGenerated) {
            $reportLines.Add("- Wrote Ritsu registration scaffold: " + $ScaffoldPath)
        }
        else {
            $reportLines.Add("- Ritsu registration scaffold was already up to date: " + $ScaffoldPath)
        }
    }
    else {
        $reportLines.Add("- Scaffold preview was requested but not written because -Apply was not set.")
    }

    $reportLines.Add("- The scaffold now includes a per-type content model inventory for the remaining BaseLib abstract classes.")
}

if ($effectiveGenerateMigrationSupport) {
    $reportLines.Add("")
    $reportLines.Add("## Generated migration support")
    $reportLines.Add("")

    if ($migrationSupportPrepared) {
        if ($Apply) {
            if ($migrationSupportChanged) {
                $reportLines.Add("- Wrote project-local migration support file: " + $MigrationSupportPath)
            }
            else {
                $reportLines.Add("- Migration support file was already up to date: " + $MigrationSupportPath)
            }
        }
        else {
            $reportLines.Add("- Migration support preview was requested but not written because -Apply was not set.")
        }
    }

    $reportLines.Add("- Rewritten C# files: " + $script:MigrationSupportRewriteFileCount)
    if ($compatibilitySupportPrepared) {
        if ($Apply) {
            if ($compatibilitySupportChanged) {
                $reportLines.Add("- Wrote project-local compatibility support file: " + $CompatibilitySupportPath)
            }
            else {
                $reportLines.Add("- Compatibility support file was already up to date: " + $CompatibilitySupportPath)
            }
        }
        else {
            $reportLines.Add("- Compatibility support preview was requested but not written because -Apply was not set.")
        }
    }

    $reportLines.Add("- Scope: BaseLib.Utils / NodeFactory wrappers, project-local SpireField support, BaseLib.Abstracts / BaseLib.Config compatibility shims, and runtime registration / asset patches.")
}

$reportLines.Add("")
$reportLines.Add("## Legacy Harmony bootstrap")
$reportLines.Add("")
$reportLines.Add("- Detected legacy Harmony patch classes: " + $legacyHarmonyPatchClasses.Count)
$reportLines.Add("- TryPatchAll call sites found before rewrite: " + $tryPatchAllSites.Count)
$reportLines.Add("- TryPatchAll call sites rewritten: " + $script:PatchBootstrapRewriteCount)

if ($effectiveGenerateLegacyHarmonyBootstrap) {
    if ($legacyHarmonyBootstrapPrepared) {
        if ($Apply) {
            if ($legacyHarmonyBootstrapChanged) {
                $reportLines.Add("- Wrote legacy Harmony bootstrap file: " + $LegacyHarmonyBootstrapPath)
            }
            else {
                $reportLines.Add("- Legacy Harmony bootstrap file was already up to date: " + $LegacyHarmonyBootstrapPath)
            }
        }
        else {
            $reportLines.Add("- Legacy Harmony bootstrap preview was requested but not written because -Apply was not set.")
        }
    }
    else {
        $reportLines.Add("- No directly patchable Harmony classes were detected, so no bootstrap file was generated.")
    }
}

if ($legacyHarmonyPatchClasses.Count -eq 0) {
    $reportLines.Add("- No legacy Harmony patch classes were detected.")
}
else {
    foreach ($patchClass in $legacyHarmonyPatchClasses | Select-Object -First 120) {
        $reportLines.Add("- " + $patchClass.FullName + " -> " + $patchClass.File)
    }

    if ($legacyHarmonyPatchClasses.Count -gt 120) {
        $reportLines.Add("- ... truncated " + ($legacyHarmonyPatchClasses.Count - 120) + " additional patch classes.")
    }
}

if ($script:UnsupportedTryPatchAllCalls.Count -gt 0) {
    $reportLines.Add("")
    $reportLines.Add("### Unsupported TryPatchAll call shapes")
    $reportLines.Add("")
    $reportLines.Add("- These call sites were left unchanged because they pass extra arguments and need manual review:")
    foreach ($match in $script:UnsupportedTryPatchAllCalls) {
        $reportLines.Add("- " + $match.Path + ":" + $match.Line + " -> " + $match.Text)
    }
}

$reportLines.Add("")
$reportLines.Add("## Manual Harmony patch sites")
$reportLines.Add("")

if ($manualHarmonyPatchSites.Count -eq 0) {
    $reportLines.Add("- No direct harmony.Patch(...) sites were found.")
}
else {
    $reportLines.Add("- Found " + $manualHarmonyPatchSites.Count + " direct harmony.Patch(...) call sites that still need manual review.")
    foreach ($match in $manualHarmonyPatchSites | Select-Object -First 80) {
        $reportLines.Add("- " + $match.Path + ":" + $match.Line + " -> " + $match.Text)
    }

    if ($manualHarmonyPatchSites.Count -gt 80) {
        $reportLines.Add("- ... truncated " + ($manualHarmonyPatchSites.Count - 80) + " additional manual patch sites.")
    }
}

$reportLines.Add("")
$reportLines.Add("## Remaining BaseLib code references")
$reportLines.Add("")

if ($codeBlockers.Count -eq 0) {
    $reportLines.Add("- No BaseLib C# usages were found.")
}
else {
    $reportLines.Add("- Found " + $codeBlockers.Count + " lines that still reference BaseLib namespaces or types.")
    foreach ($match in $codeBlockers | Select-Object -First 200) {
        $reportLines.Add("- " + $match.Path + ":" + $match.Line + " -> " + $match.Text)
    }

    if ($codeBlockers.Count -gt 200) {
        $reportLines.Add("- ... truncated " + ($codeBlockers.Count - 200) + " additional matches.")
    }
}

$reportLines.Add("")
$reportLines.Add("## Migration buckets")
$reportLines.Add("")

foreach ($bucket in $migrationBuckets) {
    $reportLines.Add("### " + $bucket.Name)
    $reportLines.Add("")
    $reportLines.Add("- Recommendation: " + $bucket.Recommendation)
    if ($bucket.Matches.Count -eq 0) {
        $reportLines.Add("- No matches found.")
    }
    else {
        $reportLines.Add("- Match count: " + $bucket.Matches.Count)
        foreach ($match in $bucket.Matches | Select-Object -First 40) {
            $reportLines.Add("- " + $match.Path + ":" + $match.Line + " -> " + $match.Text)
        }
        if ($bucket.Matches.Count -gt 40) {
            $reportLines.Add("- ... truncated " + ($bucket.Matches.Count - 40) + " additional matches.")
        }
    }
    $reportLines.Add("")
}

$reportLines.Add("## Remaining documentation and manifest mentions")
$reportLines.Add("")

if ($docMentions.Count -eq 0) {
    $reportLines.Add("- No non-code BaseLib mentions were found.")
}
else {
    foreach ($match in $docMentions | Select-Object -First 200) {
        $reportLines.Add("- " + $match.Path + ":" + $match.Line + " -> " + $match.Text)
    }

    if ($docMentions.Count -gt 200) {
        $reportLines.Add("- ... truncated " + ($docMentions.Count - 200) + " additional matches.")
    }
}

$reportLines.Add("")
$reportLines.Add("## How to run")
$reportLines.Add("")
$reportLines.Add('.\tools\Convert-BaseLibToRitsuLib.ps1 -ProjectRoot "' + $ProjectRoot + '" -Apply -RewriteSafeCode -RewritePatchBootstrap -GenerateMigrationSupport -RewriteMigrationSupportUsings -GenerateRitsuScaffold')

$report = ($reportLines -join [Environment]::NewLine) + [Environment]::NewLine

if ($Apply) {
    Write-Utf8File -Path $ReportPath -Content $report
}

Write-Host "Project root: $ProjectRoot"
Write-Host "New library project: $($newLibCsproj.FullName)"
Write-Host "New manifest id: $newManifestId"
Write-Host "Structured files changed: $($script:ChangedFiles.Count)"
Write-Host "C# blocker matches: $($codeBlockers.Count)"
Write-Host "Documentation matches: $($docMentions.Count)"
Write-Host "Migration buckets: $($migrationBuckets.Count)"
Write-Host "Legacy Harmony patch classes: $($legacyHarmonyPatchClasses.Count)"
Write-Host "TryPatchAll rewrites: $($script:PatchBootstrapRewriteCount)"
Write-Host "Migration support rewrites: $($script:MigrationSupportRewriteFileCount)"
Write-Host "Manual harmony.Patch sites: $($manualHarmonyPatchSites.Count)"
Write-Host "Scaffold generated: $scaffoldGenerated"
Write-Host "Report path: $ReportPath"
if ($effectiveGenerateLegacyHarmonyBootstrap) {
    Write-Host "Legacy bootstrap path: $LegacyHarmonyBootstrapPath"
}
if ($effectiveGenerateMigrationSupport) {
    Write-Host "Migration support path: $MigrationSupportPath"
    Write-Host "Compatibility support path: $CompatibilitySupportPath"
}
if ($GenerateRitsuScaffold) {
    Write-Host "Scaffold path: $ScaffoldPath"
}
