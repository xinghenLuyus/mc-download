# MC Download

Windows Minecraft Java 版下载与 `.minecraft` 管理工具，使用 Flutter 开发，不提供游戏启动和账号登录。

## 功能

- 自动发现游戏目录，管理已有版本、Mod、资源包、光影、数据包和世界。
- 下载原版游戏及 Forge、NeoForge、Fabric、Quilt、OptiFine，补全依赖和资源。
- 导入、导出整合包，支持拖入 ZIP / mrpack 自动安装及版本备份恢复。
- 支持系统或手动 HTTP 代理、下载源展示、哈希校验和暂停续传。

## 使用

下载 EXE 后直接运行。首次启动优先选择程序旁已有的 `.minecraft`，也可手动添加启动器目录。

应用数据保存在程序旁的 `.mcdownload/`；退出后删除即可重置，不会删除游戏目录。

发行版已内置 CurseForge 授权时无需填写 Key，DEV 版需在设置中配置自己的 API Key；Forge / NeoForge / OptiFine 安装需要合适的 Java。暂不支持组合加载器、自定义补丁及部分历史整合包。

## 构建

需要 Windows 10/11 x64、Flutter 3.47.7 和 Visual Studio C++ 桌面开发工具链。

```powershell
flutter pub get
./scripts/build-windows.ps1
```

产物位于 `orther/releases/`，默认版本为 `dev`。推送 `v0.1.0` 等标签会自动构建并发布到 GitHub Releases；本地可用 `-Version v0.1.0` 指定版本。

## Thanks

感谢 [PCL](https://github.com/Meloong-Git/PCL)、[HMCL](https://github.com/HMCL-dev/HMCL) 及其开发者提供交互设计和功能流程参考。

本项目是独立第三方工具，与上述项目及 Mojang / Microsoft 官方无关联。

## 许可

[MIT License](LICENSE)。
