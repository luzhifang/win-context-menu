<#
uninstall.ps1 —— 卸载右键菜单增强
  由"设置 > 应用"的卸载按钮或 uninstall.cmd 调用。
  按安装记录还原：删除菜单项、还原被改动的扩展名设置、删除「发送到」快捷方式、注销"应用"登记，
  最后删除 %LOCALAPPDATA%\ContextMenu。也能清理旧版（.reg 方式安装的）菜单。
用法: uninstall.ps1 [-Force]    -Force：不弹确认框
#>
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
$Title = '右键菜单增强'

try {
    if (-not $Force) {
        $r = [System.Windows.Forms.MessageBox]::Show('确定要卸载右键菜单增强吗？', $Title, 'YesNo', 'Question')
        if ($r -ne 'Yes') { exit }
    }
    $classicBefore = Test-Key $ClassicKey
    [void](Remove-Installed $InstallDir)

    # 删除安装目录：只删带安装记录的目录，防止误删。本脚本和 uninstall.cmd 自己就在里面，所以延迟 2 秒在后台删
    if (Test-Path -LiteralPath (Join-Path $InstallDir $StateName)) {
        Set-Location -LiteralPath $env:TEMP
        Start-Process cmd.exe -WindowStyle Hidden -WorkingDirectory $env:TEMP `
            -ArgumentList "/c ping -n 3 127.0.0.1 >nul & rd /s /q `"$InstallDir`""
    }
    if ((Test-Key $ClassicKey) -ne $classicBefore) { Restart-Explorer }
    [void][System.Windows.Forms.MessageBox]::Show('已卸载。', $Title, 'OK', 'Information')
} catch {
    [void][System.Windows.Forms.MessageBox]::Show("卸载失败：`n$($_.Exception.Message)", $Title, 'OK', 'Error')
    exit 1
}
