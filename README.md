# GridNest

## 痛点

macOS Tahoe 移除了熟悉的 Launchpad。新的应用浏览与搜索方式更依赖“记得应用名称”，但很多人找应用时记得的是图标、它在第几页，或它与哪些应用放在一起。

当已安装应用较多时，这会带来几个直接问题：

- 不记得名称时，搜索无法成为可靠入口；
- Finder 的“应用程序”文件夹不适合作为全屏、按位置浏览的启动界面；
- 常用应用、工具和临时安装的软件难以按自己的空间记忆整理；
- 系统缺少一个可拖拽、可分页、可建立文件夹的 Launchpad 式替代方案。

## GridNest

GridNest 是面向 macOS Tahoe 的本地应用启动器。它以全屏分页网格恢复“按位置找应用”的习惯，并支持拖拽排序、文件夹、即时搜索和全局快捷键。

## 功能

- 扫描系统、用户和 Homebrew Cask 的应用目录
- 本地保存图标位置、页面和文件夹
- 拖拽排序；将应用拖至另一应用上可创建文件夹
- 输入名称即可搜索，回车打开第一项
- 通过 `⌃⌥L` 或设置中的 `F4` 呼出
- 菜单栏与程序坞入口

## 安装

前往 [Releases](https://github.com/yellowkankan/gridnest/releases) 下载 `.dmg` 文件，打开后将 GridNest 拖到“应用程序”文件夹。

当前发行版支持搭载 macOS Tahoe 26 的 Apple Silicon Mac。应用使用本地临时签名构建；首次打开时，如系统提示安全确认，请在 Finder 中按住 Control 点按应用并选择“打开”。

## 构建

在 macOS Tahoe 与 Xcode Command Line Tools 环境运行：

```sh
./build.sh
```

生成的应用位于 `build/GridNest.app`。

## 数据

图标排列仅保存在：

`~/Library/Application Support/PositionLauncher/layout.json`

## 许可证

本项目采用 MIT 许可证。依赖基础代码的版权与许可见 [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md)。
