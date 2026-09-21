# AetherStudy 打包工具

双击 `AetherStudy-OneClick-Package.cmd`，脚本会自动申请管理员权限并执行完整打包。

版本入口：

- `AetherStudy-OneClick-Package.cmd`：主版本快速打包。
- `AetherStudy-Full-Release-Package.cmd`：主版本完整打包。
- `AetherStudy-Government-OneClick-Package.cmd`：政务版本快速打包。
- `AetherStudy-Government-Full-Release-Package.cmd`：政务版本完整打包。

## 目录

- `package-all.ps1`：完整打包流程。
- `MedClaw.iss`：Inno Setup 安装器工程。
- `package/client`：客户端安装载荷。
- `package/tools`：安装、升级、启动和卸载脚本。
- `tools/Inno`：内置 Inno Setup 编译器。
- `node-runner`：打包后端生产包使用的 Node.js。
- `cache`：后端生产包使用的便携 PowerShell 缓存。
- `output`：生成的安装包。
- `logs`：打包日志。

## 源项目

默认从以下位置构建：

- 后端：`E:\openclaw\MedClaw`
- 客户端：`E:\MedClaw`

可在 PowerShell 中传入其他位置：

```powershell
.\package-all.ps1 -BackendRoot "E:\openclaw\MedClaw" -ClientRoot "E:\MedClaw"
```

也可以直接指定版本：

```powershell
.\package-all.ps1 -Edition Main
.\package-all.ps1 -Edition Government
```

主版本安装包输出到 `output`，政务版本输出到 `output-government`。两个版本使用独立的客户端构建目录、安装载荷和快速打包缓存。

完整打包会依次执行后端 `pnpm install`、`pnpm build`、生产包生成、客户端构建和安装器编译。

## 自动更新安装

自动更新隐藏完整安装向导，但会显示真实的安装进度窗口，并在完成后启动新版客户端：

更新会根据相同 `AppId` 的安装记录沿用原安装目录，包括用户选择的其他磁盘或自定义路径。只有找不到已有安装记录时才使用默认目录；显式传入 `/DIR="完整安装目录"` 可覆盖此选择。手动移动安装文件夹不会更新安装记录。

自动启动在 `postinstall` 完成阶段执行，等待后端文件同步、部署脚本和 Gateway 监听检查成功后再打开客户端；部署失败或需要重启 Windows 时不会自动启动。文件复制进度结束后仍可能需要等待后端部署，安装窗口会继续显示当前部署状态。

```powershell
& '.\AetherStudy-Setup-版本号-x64.exe' /SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /AUTOSTART=1
```

`/SILENT` 会隐藏安装向导并保留进度窗口；`/AUTOSTART=1` 是本安装器约定的参数，不传时独立执行的静默安装不会自动启动客户端。新版客户端会以原登录用户身份启动，不会继承安装器的管理员权限。安装器需要管理员权限，因此 Windows 仍可能显示一次 UAC 确认。

## 卸载数据

交互卸载提供“保留用户数据”和“删除所有用户数据”两个选项，默认选择保留。选择删除时会清理本产品的本地/漫游数据、OpenClaw 数据和登录设置。

静默卸载默认保留数据。需要彻底删除时显式传入：

```powershell
& 'C:\Program Files\AetherStudy\unins000.exe' /VERYSILENT /PURGEUSERDATA=1
```
