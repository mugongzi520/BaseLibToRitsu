[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [string]$OldLibRoot = "D:\mod\ctf9\BaseLib-StS2-master",

    [string]$NewLibRoot = "D:\mod\ctf9\STS2-RitsuLib-main",

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
        if (-not (Test-Path -LiteralPath $trimmed)) {
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
    if (-not (Test-Path -LiteralPath $propsPath)) {
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

    $candidate = $match.Groups["path"].Value.Trim()
    return $(if (Test-Path -LiteralPath $candidate) { $candidate } else { $null })
}

function Get-DiscoveredGodotPath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [string]$RequestedPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "GodotPath does not exist: $RequestedPath"
        }

        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $projectPath = Get-ProjectGodotPath -Root $Root
    if ($projectPath) {
        return (Resolve-Path -LiteralPath $projectPath).Path
    }

    $knownCandidates = @(
        "D:\tools\Godot\4.5.1-mono\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe",
        "D:\tools\Godot\4.5.1-mono\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64_console.exe"
    )

    foreach ($candidate in $knownCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $discovered = Get-ChildItem -LiteralPath "D:\tools\Godot" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "Godot*_mono*_win64.exe" -and
            $_.Name -notlike "*console.exe"
        } |
        Sort-Object FullName |
        Select-Object -First 1

    return $(if ($discovered) { $discovered.FullName } else { $null })
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
    if (-not (Test-Path -LiteralPath $convertScriptPath)) {
        throw "Could not find converter script '$convertScriptPath'."
    }

    Write-Host ""
    Write-Host "==> Migrating BaseLib references in $projectRootFull"
    & powershell -ExecutionPolicy Bypass -File $convertScriptPath `
        -ProjectRoot $projectRootFull `
        -OldLibRoot $OldLibRoot `
        -NewLibRoot $NewLibRoot `
        -Apply `
        -RewriteSafeCode `
        -RewritePatchBootstrap `
        -GenerateMigrationSupport `
        -RewriteMigrationSupportUsings `
        -GenerateRitsuScaffold

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
        $resolvedGodotPath = Get-DiscoveredGodotPath -Root $projectRootFull -RequestedPath $GodotPath
        if ([string]::IsNullOrWhiteSpace($resolvedGodotPath)) {
            throw "Could not discover a usable Godot executable. Pass -GodotPath explicitly."
        }

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
