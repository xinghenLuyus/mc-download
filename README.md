# MC Download

基于 Flutter 的 Windows Minecraft Java 版下载与 `.minecraft` 管理工具，不提供游戏启动或账号登录。

## 功能

- 自动发现官方游戏目录，从启动器目录或文件查找并导入 PCL / HMCL 游戏目录。
- 下载原版客户端、服务端及 Fabric、Quilt、Forge、NeoForge、OptiFine，补全支持库和资源。
- 管理版本、隔离目录、Mod、资源包、光影、数据包和世界，支持整合包导入、导出及版本备份恢复。
- 支持系统代理、手动 HTTP 代理、直连，明确下载源、哈希校验、并发下载及暂停续传。

当前支持单一主要加载器；组合加载器、自定义补丁及部分历史整合包暂不支持。CurseForge 需要自己的 API Key，Forge / NeoForge / OptiFine 安装需要合适的 Java。

CurseForge 的查询和文件下载均需先在“设置 → CurseForge”保存 Key。设置页提供官方申请说明、开发者控制台、申请步骤及“保存并验证 Key”；没有 Key 时可使用 Modrinth。

## 开发与构建

Windows 10/11 x64，Flutter 3.47.7，Visual Studio C++ 桌面开发工具链。

```powershell
flutter pub get
flutter run -d windows
./scripts/build-windows.ps1
```

发布包：`orther/releases/MC-Download-Windows-x64.zip`，需分发整个目录。

```sh
flutter analyze
flutter test
```

Windows 构建与系统代理仍需实机验证。开发缓存和验证产物放在 `orther/`；整理命令为 Windows 下的 `./scripts/clean-workspace.ps1` 或 macOS 下的 `bash scripts/clean-workspace.sh`。

## 数据

设置、任务、日志和缓存统一位于程序同级的 `.mcdownload/`，便于携带和删除，不再使用 AppData。删除该目录可重置工具数据，不会删除所选的游戏目录。macOS 开发运行时位于项目当前目录的 `.mcdownload/`。版本替换及移除的备份保留在游戏目录内的 `.mcd-trash/`。代理凭据和 CurseForge Key 保存在本机配置中。

## Thanks

感谢以下开源项目及其开发者，为本项目的交互设计、目录管理和安装流程提供参考：

- [PCL](https://github.com/Meloong-Git/PCL) — 龙腾猫跃 / LTCatt 与贡献者。
- [HMCL](https://github.com/HMCL-dev/HMCL) — huangyuhui 与贡献者。

本项目是独立第三方工具，与上述项目及 Mojang / Microsoft 官方无关联。

## 许可

本项目采用 [MIT License](LICENSE)。
