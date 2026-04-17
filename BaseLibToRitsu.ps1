[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [string]$OldLibRoot,

    [string]$NewLibRoot,

    [string]$Configuration = "Release",

    [switch]$Publish,

    [string]$GodotPath
)

$ErrorActionPreference = "Stop"

function Wait-ForExitIfInteractive {
    param(
        [string]$Prompt = "按回车退出"
    )

    if ($Host.Name -match "ConsoleHost|Visual Studio Code Host") {
        Read-Host $Prompt | Out-Null
    }
}

function Get-InteractiveProjectRoot {
    while ($true) {
        Write-Host ""
        $inputPath = Read-Host "请输入 Mod 项目根目录路径"
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            Write-Host "项目路径不能为空，请重新输入。" -ForegroundColor Yellow
            continue
        }

        $trimmed = $inputPath.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
            Write-Host "路径不存在：$trimmed" -ForegroundColor Yellow
            continue
        }

        return $trimmed
    }
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-ExistingFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-SettingsFilePath {
    return Join-Path $PSScriptRoot "BaseLibToRitsu.settings.json"
}

function Get-ToolSettings {
    $settingsPath = Get-SettingsFilePath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return @{}
    }

    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $settings = @{}
        foreach ($property in $parsed.PSObject.Properties) {
            $settings[$property.Name] = [string]$property.Value
        }

        return $settings
    }
    catch {
        return @{}
    }
}

function Save-ToolSettings {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    $settingsPath = Get-SettingsFilePath
    $json = $Settings | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-TargetProjectFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $projects = Get-ChildItem -LiteralPath $Root -File -Filter "*.csproj" | Sort-Object Name
    if ($projects.Count -eq 0) {
        throw "Could not find a .csproj directly under '$Root'."
    }

    if ($projects.Count -eq 1) {
        return $projects[0].FullName
    }

    $manifestCandidates = Get-ChildItem -LiteralPath $Root -File -Filter "*.json" | Sort-Object Name
    foreach ($manifestFile in $manifestCandidates) {
        $candidateNames = [System.Collections.Generic.List[string]]::new()
        $candidateNames.Add([System.IO.Path]::GetFileNameWithoutExtension($manifestFile.Name))

        try {
            $manifestText = Get-Content -LiteralPath $manifestFile.FullName -Raw
            $idMatch = [System.Text.RegularExpressions.Regex]::Match(
                $manifestText,
                '"id"\s*:\s*"(?<id>[^"]+)"'
            )
            if ($idMatch.Success) {
                $candidateNames.Add($idMatch.Groups["id"].Value)
            }
        }
        catch {
            # ignored
        }

        foreach ($candidateName in ($candidateNames | Select-Object -Unique)) {
            $match = $projects | Where-Object { $_.BaseName -eq $candidateName } | Select-Object -First 1
            if ($match) {
                return $match.FullName
            }
        }
    }

    return $projects[0].FullName
}

function Get-ProjectGodotPath {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $propsPath = Join-Path $Root "Sts2PathDiscovery.props"
    if (-not (Test-Path -LiteralPath $propsPath -PathType Leaf)) {
        return $null
    }

    $propsText = Get-Content -LiteralPath $propsPath -Raw
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $propsText,
        '<GodotPath\b[^>]*>(?<path>[^<]+)</GodotPath>'
    )

    if (-not $match.Success) {
        return $null
    }

    return $match.Groups["path"].Value.Trim()
}

function Get-ConfiguredGodotPath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [string]$RequestedPath,
        [bool]$Interactive
    )

    $settings = Get-ToolSettings
    $candidateSources = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidateSources.Add([pscustomobject]@{
                Label = "命令行参数"
                Path = $RequestedPath
            })
    }

    $projectPath = Get-ProjectGodotPath -Root $Root
    if (-not [string]::IsNullOrWhiteSpace($projectPath)) {
        $candidateSources.Add([pscustomobject]@{
                Label = "项目 Sts2PathDiscovery.props"
                Path = $projectPath
            })
    }

    if ($settings.ContainsKey("GodotPath") -and -not [string]::IsNullOrWhiteSpace($settings["GodotPath"])) {
        $candidateSources.Add([pscustomobject]@{
                Label = "本地工具设置"
                Path = $settings["GodotPath"]
            })
    }

    foreach ($candidate in $candidateSources) {
        $resolved = Resolve-ExistingFile -Path $candidate.Path
        if (-not $resolved) {
            continue
        }

        if ($settings["GodotPath"] -ne $resolved) {
            $settings["GodotPath"] = $resolved
            Save-ToolSettings -Settings $settings
        }

        return $resolved
    }

    if (-not $Interactive) {
        throw "找不到可用的 Godot Mono。请在项目的 Sts2PathDiscovery.props 里配置 GodotPath，或命令行传 -GodotPath，或先交互运行一次保存。"
    }

    while ($true) {
        Write-Host ""
        $inputPath = Read-Host "首次使用请输入 Godot Mono 可执行文件路径"
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            Write-Host "GodotPath 不能为空，请重新输入。" -ForegroundColor Yellow
            continue
        }

        $resolved = Resolve-ExistingFile -Path $inputPath.Trim().Trim('"')
        if (-not $resolved) {
            Write-Host "GodotPath 不存在：$inputPath" -ForegroundColor Yellow
            continue
        }

        $settings["GodotPath"] = $resolved
        Save-ToolSettings -Settings $settings
        return $resolved
    }
}

function Invoke-ProjectBuild {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectFile,
        [Parameter(Mandatory)]
        [string]$Configuration
    )

    Write-Host ""
    Write-Host "==> Building $ProjectFile ($Configuration)"
    & dotnet build $ProjectFile -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE."
    }
}

function Invoke-ProjectPublish {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectFile,
        [Parameter(Mandatory)]
        [string]$Configuration,
        [Parameter(Mandatory)]
        [string]$GodotExecutablePath
    )

    Write-Host ""
    Write-Host "==> Publishing with GodotPath=$GodotExecutablePath"
    & dotnet publish $ProjectFile -c $Configuration /p:GodotPath=$GodotExecutablePath
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }
}

function Test-IsPathUnderRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $rootWithSeparator = if ($fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or $fullRoot.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        $fullRoot
    }
    else {
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-UniquePackageFile {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [System.Collections.Generic.HashSet[string]]$FileSet,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-IsPathUnderRoot -Path $fullPath -Root $ProjectRoot)) {
        return
    }

    $null = $FileSet.Add($fullPath)
}

function Get-ChangedFilesFromReport {
    param(
        [Parameter(Mandatory)]
        [string]$ReportPath,
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        return @()
    }

    $files = [System.Collections.Generic.List[string]]::new()
    $inChangedFilesSection = $false

    foreach ($line in Get-Content -LiteralPath $ReportPath) {
        if ($line -eq "## Changed files") {
            $inChangedFilesSection = $true
            continue
        }

        if ($inChangedFilesSection -and $line -match '^## ') {
            break
        }

        if (-not $inChangedFilesSection -or -not $line.StartsWith("- ")) {
            continue
        }

        $candidate = $line.Substring(2)
        $reasonSeparatorIndex = if ($candidate.Length -gt 3) { $candidate.IndexOf(": ", 3) } else { -1 }
        $pathText = if ($reasonSeparatorIndex -gt 0) { $candidate.Substring(0, $reasonSeparatorIndex) } else { $candidate }

        if (-not [string]::IsNullOrWhiteSpace($pathText) -and
            (Test-Path -LiteralPath $pathText -PathType Leaf) -and
            (Test-IsPathUnderRoot -Path $pathText -Root $ProjectRoot)) {
            $files.Add([System.IO.Path]::GetFullPath($pathText))
        }
    }

    return @($files | Select-Object -Unique)
}

function Get-ConversionPackageFiles {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    $files = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($changedFile in Get-ChangedFilesFromReport -ReportPath $ReportPath -ProjectRoot $rootFull) {
        Add-UniquePackageFile -FileSet $files -Path $changedFile -ProjectRoot $rootFull
    }

    $rootPatterns = @(
        "*.sln",
        "*.csproj",
        "*.props",
        "*.targets",
        "*.json",
        "project.godot",
        "export_presets.cfg",
        "Directory.Build.props",
        "Directory.Build.targets",
        "NuGet.Config",
        "base-lib-to-ritsu-report.md",
        "ritsu-content-pack-scaffold.md"
    )

    foreach ($pattern in $rootPatterns) {
        foreach ($file in Get-ChildItem -LiteralPath $rootFull -File -Filter $pattern -ErrorAction SilentlyContinue) {
            Add-UniquePackageFile -FileSet $files -Path $file.FullName -ProjectRoot $rootFull
        }
    }

    $generatedDir = Join-Path $rootFull "Generated\BaseLibToRitsu"
    if (Test-Path -LiteralPath $generatedDir -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $generatedDir -Recurse -File) {
            Add-UniquePackageFile -FileSet $files -Path $file.FullName -ProjectRoot $rootFull
        }
    }

    return @($files | Sort-Object)
}

function New-ConversionArchive {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    $projectName = Split-Path -Leaf $rootFull
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipPath = Join-Path $rootFull ($projectName + "-BaseLibToRitsu-package-" + $timestamp + ".zip")
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BaseLibToRitsu-" + [System.Guid]::NewGuid().ToString("N"))
    $files = @(Get-ConversionPackageFiles -ProjectRoot $rootFull -ReportPath $ReportPath)

    if ($files.Count -eq 0) {
        throw "没有可打包的转换结果。请先确认转换报告是否已生成。"
    }

    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    try {
        foreach ($file in $files) {
            $relativePath = $file.Substring($rootFull.Length).TrimStart('\', '/')
            $destinationPath = Join-Path $stagingRoot $relativePath
            $destinationDirectory = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }

            Copy-Item -LiteralPath $file -Destination $destinationPath -Force
        }

        $manifestLines = [System.Collections.Generic.List[string]]::new()
        $manifestLines.Add("Project root: $rootFull")
        $manifestLines.Add("Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $manifestLines.Add("")
        $manifestLines.Add("Included files:")
        foreach ($file in $files) {
            $manifestLines.Add("- " + $file.Substring($rootFull.Length).TrimStart('\', '/'))
        }

        $manifestPath = Join-Path $stagingRoot "_BaseLibToRitsuPackage.txt"
        [System.IO.File]::WriteAllLines($manifestPath, $manifestLines, [System.Text.UTF8Encoding]::new($false))

        if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        $archiveInputs = @(Get-ChildItem -LiteralPath $stagingRoot -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $archiveInputs -DestinationPath $zipPath -Force

        return [pscustomobject]@{
            ZipPath   = $zipPath
            FileCount = $files.Count
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}

function Show-PostConversionMenu {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$ProjectFile,
        [Parameter(Mandatory)]
        [string]$Configuration,
        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    while ($true) {
        Write-Host ""
        Write-Host "转换完成，接下来请选择：" -ForegroundColor Cyan
        Write-Host "1. 编译测试"
        Write-Host "2. 打包修改后的文件"
        Write-Host "3. 退出"

        $choice = (Read-Host "请输入选项编号").Trim()
        switch ($choice) {
            "1" {
                try {
                    Invoke-ProjectBuild -ProjectFile $ProjectFile -Configuration $Configuration
                    Write-Host ""
                    Write-Host "编译完成。" -ForegroundColor Green
                }
                catch {
                    Write-Host ""
                    Write-Host "编译失败：$($_.Exception.Message)" -ForegroundColor Red
                }
            }
            "2" {
                try {
                    Write-Host ""
                    Write-Host "==> Packaging converted files"
                    $archive = New-ConversionArchive -ProjectRoot $ProjectRoot -ReportPath $ReportPath
                    Write-Host "打包完成：$($archive.ZipPath)" -ForegroundColor Green
                    Write-Host "打包文件数：$($archive.FileCount)" -ForegroundColor Green
                }
                catch {
                    Write-Host ""
                    Write-Host "打包失败：$($_.Exception.Message)" -ForegroundColor Red
                }
            }
            "3" {
                return
            }
            default {
                Write-Host "请输入 1 / 2 / 3。" -ForegroundColor Yellow
            }
        }
    }
}

try {
    Write-Host "BaseLibToRitsu 懒人版" -ForegroundColor Cyan
    Write-Host "直接输入项目路径即可开始转换。" -ForegroundColor Cyan

    $startedInteractive = [string]::IsNullOrWhiteSpace($ProjectRoot)
    if ($startedInteractive) {
        $ProjectRoot = Get-InteractiveProjectRoot
    }

    $projectRootFull = Resolve-ExistingPath -Path $ProjectRoot.Trim().Trim('"')
    $convertScriptPath = Join-Path $PSScriptRoot "Convert-BaseLibToRitsuLib.ps1"
    if (-not (Test-Path -LiteralPath $convertScriptPath -PathType Leaf)) {
        throw "Could not find converter script '$convertScriptPath'."
    }

    Write-Host ""
    Write-Host "==> Migrating BaseLib references in $projectRootFull"
    $convertArguments = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $convertScriptPath,
        "-ProjectRoot", $projectRootFull,
        "-Apply",
        "-RewriteSafeCode",
        "-RewritePatchBootstrap",
        "-GenerateMigrationSupport",
        "-RewriteMigrationSupportUsings",
        "-GenerateRitsuScaffold"
    )

    if (-not [string]::IsNullOrWhiteSpace($OldLibRoot)) {
        $convertArguments += @("-OldLibRoot", $OldLibRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($NewLibRoot)) {
        $convertArguments += @("-NewLibRoot", $NewLibRoot)
    }

    & powershell @convertArguments

    if ($LASTEXITCODE -ne 0) {
        throw "converter script failed with exit code $LASTEXITCODE."
    }

    $projectFile = Get-TargetProjectFile -Root $projectRootFull
    $reportPath = Join-Path $projectRootFull "base-lib-to-ritsu-report.md"

    if ($startedInteractive) {
        Show-PostConversionMenu -ProjectRoot $projectRootFull -ProjectFile $projectFile -Configuration $Configuration -ReportPath $reportPath
    }
    else {
        Invoke-ProjectBuild -ProjectFile $projectFile -Configuration $Configuration

        if ($Publish) {
            $resolvedGodotPath = Get-ConfiguredGodotPath -Root $projectRootFull -RequestedPath $GodotPath -Interactive $false
            Invoke-ProjectPublish -ProjectFile $projectFile -Configuration $Configuration -GodotExecutablePath $resolvedGodotPath
        }
    }

    Write-Host ""
    Write-Host "by清野 你已经逃离BaseLib 的石山" -ForegroundColor Green
    if ($startedInteractive) {
        Wait-ForExitIfInteractive
    }
}
catch {
    Write-Host ""
    Write-Host "转换失败：$($_.Exception.Message)" -ForegroundColor Red
    if ($startedInteractive) {
        Wait-ForExitIfInteractive -Prompt "按回车退出并检查报错"
    }
    else {
        throw
    }
}
