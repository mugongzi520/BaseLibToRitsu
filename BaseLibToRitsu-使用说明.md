# BaseLibToRitsu 使用说明

`BaseLibToRitsu` 用于把基于 `BaseLib` 的 STS2 Mod 项目迁移到 `RitsuLib` 兼容运行形态。

当前发布包已经包含以下兼容能力：

- 自动重写常见 `BaseLib` 代码引用。
- 自动生成 `Generated\BaseLibToRitsu` 兼容层文件。
- 自动补齐旧式 `Harmony` 启动入口。
- 自动为旧资源命名生成 `RitsuLib` 可识别的资源别名。
- 自动为旧本地化键生成 `RitsuLib` 可识别的 public id 别名。
- 自动兼容缩写类资源/本地化命名差异，例如 `D_C -> DC/dc`。
- 默认从脚本同路径发布包读取 `STS2-RitsuLib` / `BaseLib` 前置目录。
- `GodotPath` 优先读取目标项目配置；没有时首次运行会提示手填并保存在本地设置。

## 适用环境

- 游戏版本：`Slay the Spire 2 v0.99.1`
- 引擎环境：`Godot 4.5.1 Mono`
- Mod 框架：`HarmonyLib + STS2-RitsuLib`
- 操作系统：`Windows`

## 发布包内容

- `Convert-BaseLibToRitsuLib.ps1`
- `BaseLibToRitsu.ps1`
- `Invoke-BaseLibToRitsuMigration.ps1`
- `BaseLibToRitsuCompatibility.template.cs`
- `BaseLibToRitsuMigrationSupport.template.cs`
- `BaseLibToRitsu-使用说明.md`

## 标准使用流程

### 0. 懒人版入口

直接打开：

- `tools\BaseLibToRitsu.ps1`

兼容旧入口：

- `tools\Invoke-BaseLibToRitsuMigration.ps1`

然后按提示输入：

- 目标 Mod 项目根目录路径

执行完成后会输出：

- `by清野 你已经逃离 BaseLib 的石山`

说明：

- 懒人版会自动执行转换和 `dotnet build`
- 默认前置目录读取顺序：
  - `脚本同目录\STS2-RitsuLib-main`
  - `脚本上一级目录\STS2-RitsuLib-main`
  - `BaseLib` 同理
- 如果目标项目自己的 `Sts2PathDiscovery.props` 已配置 `GodotPath`，会直接复用
- 如果没有配置，则第一次 `-Publish` 时会要求输入一次 `Godot Mono` 路径，并保存到 `tools\BaseLibToRitsu.settings.json`
- 如果你从命令行传入 `-ProjectRoot`，则仍可按无交互模式使用

### 1. 迁移项目

在目标 Mod 项目根目录上执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\mod\ctf9\tools\BaseLibToRitsu.ps1" `
  -ProjectRoot "D:\mod\ctf9\你的Mod项目" `
  -Publish
```

如果你只想跑核心转换器，也可以直接执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\mod\ctf9\tools\Convert-BaseLibToRitsuLib.ps1" `
  -ProjectRoot "D:\mod\ctf9\你的Mod项目" `
  -Apply `
  -RewriteSafeCode `
  -RewritePatchBootstrap `
  -GenerateMigrationSupport `
  -RewriteMigrationSupportUsings `
  -GenerateRitsuScaffold
```

### 2. 查看迁移报告

迁移完成后，重点查看项目根目录下的：

- `base-lib-to-ritsu-report.md`

重点确认以下内容：

- 哪些文件被自动改写
- 哪些 Harmony 启动逻辑被替换
- 是否生成了兼容层
- 是否还有需要手工处理的阻塞项

### 3. 编译并部署到游戏目录

懒人版当前会自动做：

- 转换
- `dotnet build`
- 如果传了 `-Publish`，再执行 `dotnet publish`

如果你需要额外部署到游戏目录，继续手动执行：

```powershell
dotnet msbuild "D:\mod\ctf9\你的Mod项目\YourMod.csproj" `
  /t:DeployMod `
  /p:Configuration=Release `
  /p:Sts2Dir="M:\SteamLibrary\steamapps\common\Slay the Spire 2"
```

### 4. 启动游戏验证

重点检查：

- Mod 是否成功加载
- 是否还有 `DuplicateModelException`
- 是否还有 `ModelNotFoundException`
- 是否还有 `LocException: Key=... not found`
- 是否还有 `No loader found for resource`

日志位置：

- `C:\Users\Kayla\AppData\Roaming\SlayTheSpire2\logs\godot.log`

## 迁移后会生成的文件

转换器会在项目内生成：

- `Generated\BaseLibToRitsu\LegacyCompatibility.g.cs`
- `Generated\BaseLibToRitsu\LegacyMigrationSupport.g.cs`
- `Generated\BaseLibToRitsu\LegacyHarmonyPatchBootstrap.g.cs`
- `base-lib-to-ritsu-report.md`

说明：

- `LegacyCompatibility.g.cs`
  负责旧 BaseLib 行为到 Ritsu 运行时的兼容桥接。
- `LegacyMigrationSupport.g.cs`
  负责旧工具方法、迁移辅助逻辑的过渡支持。
- `LegacyHarmonyPatchBootstrap.g.cs`
  负责旧 Harmony Patch 启动模式的兼容接入。

## 当前已验证通过的兼容点

本轮已经实测确认修复：

- 旧 `MARISAMOD-*` 本地化键可自动补出 `MARISA_MOD_*`
- 旧 `MARISAMOD_CARD_*` 本地化键可自动补出 `MARISA_MOD_CARD_*`
- 旧 `marisamod-xxx.png` 卡图可自动补出 `marisa_mod_card_xxx.png`
- 缩写命名差异可自动兼容，例如：
  - `D_C -> DC`
  - `d_c -> dc`

## 推荐的发布前自检

发布前至少做一次以下检查：

1. 清理旧日志后启动游戏。
2. 确认日志中不再出现本 Mod 的：
   - `DuplicateModelException`
   - `ModelNotFoundException`
   - `LocException: Key=MARISA_MOD_*`
   - `No loader found for resource: res://你的Mod路径/...`
3. 进入角色选择、图鉴、开局、战斗、奖励界面各检查一遍资源显示。

## 已知边界

- 如果旧项目使用了非常规注册逻辑、手写反射注册、运行时动态生成模型，仍可能需要手工修正。
- 如果旧资源命名完全不含旧 public id 或实体 stem，自动 alias 可能无法覆盖，需要人工补资源路径。
- 如果前置目录不在脚本同目录或上一级目录，请手动传 `-OldLibRoot` / `-NewLibRoot`。
- 如果你用的是无交互命令行且项目里也没有 `GodotPath`，请手动传 `-GodotPath`。
- 其它 Mod 自身报错不会由本工具修复，例如：
  - 其它 Mod 的 manifest 结构错误
  - 其它 Mod 的 UID / Spine / 场景资源问题
  - 业务逻辑自身的本地化或关键词缺失
