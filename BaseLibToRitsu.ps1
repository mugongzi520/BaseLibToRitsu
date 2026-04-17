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

    Write-Host ""
    Write-Host "==> Building $projectFile ($Configuration)"
    & dotnet build $projectFile -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE."
    }

    if ($Publish) {
        $resolvedGodotPath = Get-ConfiguredGodotPath -Root $projectRootFull -RequestedPath $GodotPath -Interactive $startedInteractive

        Write-Host ""
        Write-Host "==> Publishing with GodotPath=$resolvedGodotPath"
        & dotnet publish $projectFile -c $Configuration /p:GodotPath=$resolvedGodotPath
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish failed with exit code $LASTEXITCODE."
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
