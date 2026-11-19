# DreamSkin Studio

[Codex Dream Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 主题引擎的第三方管理界面，Windows 桌面程序（WPF）。它替换引擎自带的主题管理器，引擎本身和 Codex 程序都不改动。

![工作室页面](docs/settings.jpg)

## 功能

- 预览当前背景，调整背景透出度，暂停或恢复背景，一键恢复 Codex 官方外观。
- 主题收藏：搜索、预览、应用、重命名、移到回收站；导入图片、视频或主题 ZIP。
- 界面的光和强调色取自当前壁纸，在收藏里选中另一张主题时随之渐变；也可以手动指定颜色。
- 预览图放在 3D 平面上，会朝鼠标方向倾斜，带高光和倒影。窗口不在前台时所有动画暂停。
- Wallpaper Engine 联动：读取它保存的配置，导入某个屏幕当前的壁纸，或在管理器运行时自动跟随。支持“复制”布局。场景类壁纸可以先录成视频再关联。
- 连接诊断和操作记录。

## 运行条件

- Windows 10 或 11，64 位。
- 已安装 Codex Dream Skin 引擎。安装脚本只接受 1.7.3，其他版本没有验证过。
- 构建不需要 .NET SDK，用的是系统自带的 .NET Framework 4.8 编译器。

## 构建、自检、安装

```powershell
.\build.ps1                                        # 输出到 dist\
.\dist\DreamSkinStudio.exe --self-test .\dist\qa   # 只读自检，生成各页面截图和 report.json
.\dist\Install-New-Manager.ps1                     # 接入已安装的引擎
```

- 自检需要本机已有引擎和至少一个主题；它不会修改任何设置。
- 安装脚本会关闭正在运行的管理器，替换引擎目录里的管理器和后端脚本，校验文件哈希，并把原管理器备份到 `dist\rollback\`。
- 恢复原管理器：运行 `dist\Restore-Original-Manager.cmd`。壁纸、主题和透出度设置都保留。

## 目录

| 路径 | 内容 |
| --- | --- |
| `MainWindow.xaml` | 界面布局和控件样式 |
| `Studio.cs` | 程序入口、主窗口逻辑、只读自检 |
| `UiPalette.cs` | 配色：从壁纸或手选颜色推导整套界面颜色 |
| `Ambience.cs` | 壁纸取色、缩略图、极光背景和各种动效 |
| `ThemeColorDialog.cs` | 配色设置窗口 |
| `WallpaperLinkPanel.cs` | Wallpaper Engine 联动面板 |
| `backend\` | 管理器调用的 PowerShell 后端（主题操作、联动、场景录制） |
| `install\` | 安装和恢复脚本 |
| `assets\` | 图标，以及生成图标的 `make_icon.py` |
| `test_*.py` | 后端的隔离测试，使用临时目录，不触碰真实配置 |

## 已知限制

- 两处路径是按作者的机器写的，换机器需要修改：
  - `backend\wallpaper-link.ps1` 和 `backend\record-wallpaper.ps1` 里的 Wallpaper Engine 安装目录（`G:\steam\...`）；
  - `backend\record-wallpaper.ps1` 开头的 ffmpeg、ffprobe 路径和录制输出目录。
- 场景录制得到的是固定循环的视频，不会实时响应鼠标或音频。
- 动效需要支持硬件加速的显卡；远程会话或关闭了系统动画时，界面外观相同但保持静止。

## 说明

本仓库只包含管理界面的源码，不包含 Codex Dream Skin 引擎的文件，也不包含任何壁纸素材。引擎由其作者以 MIT 协议发布。
