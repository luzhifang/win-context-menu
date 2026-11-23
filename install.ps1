<#
install.ps1 —— 安装右键菜单增强（一般直接双击 install.cmd）
  - 把运行所需文件复制到 %LOCALAPPDATA%\ContextMenu，并登记到"设置 > 应用"和"控制面板 > 程序和功能"
  - 只写 HKCU，不需要管理员；重复运行 = 先清理旧版再装新版
  - 按本机实际安装的软件生成菜单：没装的软件不加对应菜单项

用法: install.ps1 [-Classic Ask|Yes|No] [-DryRun]
  -Classic  Win11 是否恢复经典右键菜单。Ask（默认）= 运行时询问
  -DryRun   只显示检测结果和将要写入的菜单，不做任何修改
#>
param(
    [ValidateSet('Ask', 'Yes', 'No')][string]$Classic = 'Ask',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot
. (Join-Path $Src 'common.ps1')
$Dir = $InstallDir
$Version = '2.0.0'

if ($Src.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { throw "请从解压出来的安装包目录运行 install，而不是从 $Dir 运行。" }

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

# JetBrains IDE 产品表。只认 exe 名，不依赖版本和安装目录（点击时由 cm.exe --jb 查找最新版）。
# IntelliJ IDEA 暂不加入：它的安装程序可能已经自带了右键菜单项，会重复。需要时取消下面一行的注释。
$JetBrains = @(
    [pscustomobject]@{ Name = 'GoLand'; Exe = 'goland64.exe'; Ico = 'goland.ico'; Order = '12' }
    # [pscustomobject]@{ Name = 'IntelliJ IDEA'; Exe = 'idea64.exe'; Ico = 'idea.ico'; Order = '13' }
)

# 「新建」菜单模板（templates\template<扩展名>）
$NewExts = '.txt', '.md', '.sh', '.ps1', '.json', '.yaml', '.py', '.go'

# ======================= 1. 检测 =======================
Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $Src 'cm.cs') -Raw -Encoding UTF8) -Language CSharp -ReferencedAssemblies System.Core

function Find-VSCode {
    $uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($u in $uninst) {
        foreach ($e in @(Get-ItemProperty -Path $u -ErrorAction SilentlyContinue)) {
            if ($e.DisplayName -like 'Microsoft Visual Studio Code*' -and $e.DisplayName -notlike '*Insiders*' -and $e.InstallLocation) {
                $exe = Join-Path $e.InstallLocation 'Code.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
        }
    }
    # 便携版 / Scoop：PATH 里的 <安装目录>\bin\code.cmd
    foreach ($c in @(Get-Command code.cmd -All -ErrorAction SilentlyContinue)) {
        $exe = Join-Path (Split-Path (Split-Path $c.Source)) 'Code.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    foreach ($exe in (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
                     (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'),
                     (Join-Path $env:USERPROFILE 'scoop\apps\vscode\current\Code.exe')) {
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Find-Chrome {
    foreach ($root in $HKCU, $HKLM) {
        $p = Get-Val 'Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' '' $root
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

$VSCode = Find-VSCode
# VS Code 安装程序自带的「通过 Code 打开」（用户版写 HKCU，系统版写 HKLM）
$VSCodeOwnMenu = @(foreach ($c in '*', 'Directory', 'Directory\Background') {
    if ((Test-Key "$Classes\$c\shell\VSCode") -or (Test-Key "$Classes\$c\shell\VSCode" $HKLM)) { $c }
})
$WT = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
if (-not (Test-Path -LiteralPath $WT)) { $WT = $null }
$Distro = Get-DefaultDistro
$HasWsl = [bool]$Distro -and (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\wsl.exe'))
$Chrome = Find-Chrome
$IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000
foreach ($p in $JetBrains) { $p | Add-Member -NotePropertyName Path -NotePropertyValue ([ContextMenuTool]::FindJetBrains($p.Exe)) }

function Show-Found([string]$Name, $Value, [string]$Missing = '未找到，不添加相关菜单') {
    if ($Value) { Say ("  {0,-18} {1}" -f $Name, $Value) 'Green' } else { Say ("  {0,-18} {1}" -f $Name, $Missing) 'DarkYellow' }
}
Say '检测到的软件：' 'Cyan'
Show-Found 'VS Code' $VSCode
if ($VSCode -and $VSCodeOwnMenu) { Say ("  {0,-18} {1}" -f '', "VS Code 已自带「通过 Code 打开」（$($VSCodeOwnMenu -join '、')），不再重复添加") 'DarkYellow' }
Show-Found 'Windows Terminal' $WT '未找到，终端改为直接打开窗口'
Show-Found 'WSL 默认发行版' $(if ($HasWsl) { $Distro })
foreach ($p in $JetBrains) { Show-Found $p.Name $p.Path }
Show-Found 'Chrome' $Chrome '未找到，不添加「发送到」快捷方式'

# 旧安装（本工具改过的东西），用来区分"用户原有设置"和"我们写的"
$OldState = Read-State $Dir
$Legacy = (-not $OldState) -and (@(Find-CMVerbs).Count -gt 0)
$Ours = Get-Ours $OldState $Legacy
if ($Legacy) { Say '检测到旧版（.reg 方式安装的）菜单，安装时会先清理。' 'Cyan' }

function Test-OursKey([string]$Path) {
    foreach ($k in $Ours.Keys) { if ($Path -eq $k -or $Path.StartsWith("$k\")) { return $true } }
    return $false
}
# 用户自己的 HKCU 值（我们写的不算）
function Get-UserVal([string]$Path, [string]$Name = '') {
    if (Test-OursKey $Path) { return $null }
    $v = Get-Val $Path $Name
    $o = $Ours.Vals["$Path|$Name"]
    if ($null -ne $o -and $v -eq $o) { return $null }
    return $v
}
function Test-UserKey([string]$Path) { return (-not (Test-OursKey $Path)) -and (Test-Key $Path) }

# ---- 经典菜单 ----
$ClassicBefore = Test-Key $ClassicKey
$ClassicForeign = $ClassicBefore -and -not (Test-OursKey $ClassicKey)
$WantClassic = $false
if (-not $IsWin11) {
    Say '经典右键菜单：Windows 10 不需要。'
} elseif ($ClassicForeign) {
    Say '经典右键菜单：已由其他方式开启，保持不变。'
} elseif ($Classic -eq 'Ask' -and -not $DryRun) {
    $def = if ($ClassicBefore) { 'Y' } else { 'N' }
    $ans = Read-Host "`nWin11 是否恢复经典右键菜单（不用再点「显示更多选项」）？[Y/N，直接回车 = $def]"
    if (-not $ans) { $ans = $def }
    $WantClassic = $ans -match '^\s*[Yy]'
} else {
    $WantClassic = ($Classic -eq 'Yes') -or ($Classic -eq 'Ask' -and $ClassicBefore)
}

# ---- 「新建」菜单：每个扩展名怎么处理 ----
# ShellNew 只有在扩展名指向一个有显示名称的 ProgID 时才会出现在「新建」里
$TxtName = '文本文档'
function Resolve-NewItem([string]$Ext) {
    $tpl = Join-Path $Src "templates\template$Ext"
    if ($Ext -ne '.txt' -and -not (Test-Path -LiteralPath $tpl)) { return @{ Do = 'skip'; Why = '缺少模板文件' } }
    if ((Test-Key "$Classes\$Ext\ShellNew" $HKLM) -or (Test-UserKey "$Classes\$Ext\ShellNew")) {
        return @{ Do = 'skip'; Why = '系统里已经有这个新建项' }
    }
    $progId = Get-UserVal "$Classes\$Ext"
    if (-not $progId) { $progId = Get-Val "$Classes\$Ext" '' $HKLM }
    if ($progId) {
        $name = Get-UserVal "$Classes\$progId"
        if (-not $name) { $name = Get-Val "$Classes\$progId" '' $HKLM }
        if ($name) { return @{ Do = 'shellnew'; Why = "使用已有类型 $progId（$name）" } }
        if ($Ext -eq '.txt') { return @{ Do = 'name'; ProgId = $progId; Why = "类型 $progId 缺少名称，补上「$TxtName」" } }
    }
    if ($VSCode -and ((Test-Key "$Classes\VSCode$Ext") -or (Test-Key "$Classes\VSCode$Ext" $HKLM))) {
        return @{ Do = 'vscode'; Why = "扩展名没有关联类型，指向 VS Code 的 VSCode$Ext" }
    }
    return @{ Do = 'skip'; Why = '没有可用的文件类型（没装能打开它的软件）' }
}

# ======================= 2. 生成菜单定义 =======================
$Exe = Join-Path $Dir 'cm.exe'
$WslIcon = Join-Path $env:WINDIR 'System32\wsl.exe'
$PsIcon = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$CmdIcon = Join-Path $env:WINDIR 'System32\cmd.exe'
$ShieldIcon = 'imageres.dll,-78'

$Plan = New-Object System.Collections.Generic.List[object]
function Add-Key([string]$Path, [hashtable]$Values = @{}) { $Plan.Add([pscustomobject]@{ Path = "$Classes\$Path"; Values = $Values }) }
function Add-Verb($Cls, $Name, $Label, $Command, $Icon) {
    $p = "$Cls\shell\$Prefix$Name"
    $v = @{ MUIVerb = $Label }
    if ($Icon) { $v.Icon = $Icon }
    Add-Key $p $v
    Add-Key "$p\command" @{ '' = $Command }
}
function Item($Key, $Label, $Command, $Icon) { [pscustomobject]@{ Key = $Key; Label = $Label; Command = $Command; Icon = $Icon } }
function Add-Submenu($Cls, $Name, $Label, $Items, $Icon) {
    $p = "$Cls\shell\$Prefix$Name"
    $v = @{ MUIVerb = $Label; SubCommands = '' }
    if ($Icon) { $v.Icon = $Icon }
    Add-Key $p $v
    $i = 0
    foreach ($it in @($Items)) {
        $sp = "$p\shell\" + ('{0:D2}' -f $i) + $it.Key
        $sv = @{ MUIVerb = $it.Label }
        if ($it.Icon) { $sv.Icon = $it.Icon }
        Add-Key $sp $sv
        Add-Key "$sp\command" @{ '' = $it.Command }
        $i++
    }
}
# 调用 cm.exe 的动作。-V：参数来自 "%V."（末尾补点，避开 "C:\" 的反斜杠吃掉引号）
function Cm($Action, $Arg, [switch]$V) {
    $f = if ($V) { ' -V' } else { '' }
    "`"$Exe`" $Action$f `"$Arg`""
}

# ---- 1. 终端：文件夹 / 文件夹空白处 / 驱动器 ----
foreach ($cls in 'Directory', 'Directory\Background', 'Drive') {
    if ($HasWsl) {
        $c = if ($WT) { "`"$WT`" -d `"%V.`" wsl.exe" } else { Cm 'ShellWsl' '%V.' -V }
        Add-Verb $cls '01WslHere' '在此处打开 WSL' $c $WslIcon
    }
    Add-Submenu $cls '02Terminals' '更多终端' @(
        (Item 'PowerShell' 'PowerShell' $(if ($WT) { "`"$WT`" -d `"%V.`" powershell.exe -NoLogo" } else { Cm 'ShellPowerShell' '%V.' -V }) $PsIcon),
        (Item 'Cmd' '命令提示符 (CMD)' $(if ($WT) { "`"$WT`" -d `"%V.`" cmd.exe" } else { Cm 'ShellCmd' '%V.' -V }) $CmdIcon),
        (Item 'Admin' 'PowerShell (管理员)' (Cm 'AdminTerminal' '%V.' -V) $ShieldIcon)
    ) $PsIcon
}

# ---- 2. 编辑器 ----
if ($VSCode) {
    # VS Code 安装时可勾选 "Add 'Open with Code' action"，会写 <类>\shell\VSCode；已有就不再加我们的，避免重复
    foreach ($c in @(@('*', '%1'), @('Directory', '%1'), @('Directory\Background', '%V'))) {
        if ($VSCodeOwnMenu -contains $c[0]) { continue }
        Add-Verb $c[0] '10VSCode' '用 VS Code 打开' "`"$VSCode`" `"$($c[1])`"" $VSCode
    }
    if ($HasWsl) {
        Add-Verb '*' '11VSCodeWsl' '用 VS Code (WSL) 打开' (Cm 'VSCodeWsl' '%1') $VSCode
        Add-Verb 'Directory' '11VSCodeWsl' '用 VS Code (WSL) 打开' (Cm 'VSCodeWsl' '%V.' -V) $VSCode
        Add-Verb 'Directory\Background' '11VSCodeWsl' '用 VS Code (WSL) 打开' (Cm 'VSCodeWsl' '%V.' -V) $VSCode
    }
}
foreach ($p in $JetBrains) {
    if (-not $p.Path) { continue }
    $key = $p.Order + ($p.Name -replace '\s', '')
    $icon = Join-Path $Dir "icons\$($p.Ico)"
    $p | Add-Member -NotePropertyName IconSrc -NotePropertyValue (Join-Path (Split-Path $p.Path) $p.Ico)
    if (-not (Test-Path -LiteralPath $p.IconSrc)) { $icon = $p.Path }
    $label = "用 $($p.Name) 打开"
    Add-Verb '*' $key $label "`"$Exe`" --jb $($p.Exe) `"%1`"" $icon
    Add-Verb 'Directory' $key $label "`"$Exe`" --jb $($p.Exe) `"%1`"" $icon
    Add-Verb 'Directory\Background' $key $label "`"$Exe`" --jb $($p.Exe) `"%V`"" $icon
}

# ---- 3. 复制路径 ----
$items = @((Item 'Win' 'Windows 路径' (Cm 'CopyWinPath' '%1') $null))
if ($HasWsl) { $items += Item 'Wsl' 'WSL 路径 (/mnt/...)' (Cm 'CopyWslPath' '%1') $WslIcon }
$items += Item 'Name' '文件名' (Cm 'CopyName' '%1') $null
Add-Submenu 'AllFilesystemObjects' '20CopyPath' '复制路径' $items

$items = @((Item 'Win' 'Windows 路径' (Cm 'CopyWinPath' '%V.' -V) $null))
if ($HasWsl) { $items += Item 'Wsl' 'WSL 路径 (/mnt/...)' (Cm 'CopyWslPath' '%V.' -V) $WslIcon }
Add-Submenu 'Directory\Background' '20CopyPath' '复制当前文件夹路径' $items

# ---- 4. 用所选项目新建文件夹 ----
Add-Verb 'AllFilesystemObjects' '21NewFolderSel' '用所选项目新建文件夹' (Cm 'NewFolderWithSelection' '%1') 'imageres.dll,-3'

# ---- 5. 开发工具 ----
Add-Submenu '*' '30DevTools' '开发工具' @(
    (Item 'Sha256' '计算 SHA256（复制到剪贴板）' (Cm 'Sha256' '%1') $null),
    (Item 'TakeOwn' '取得所有权（管理员）' (Cm 'TakeOwn' '%1') $ShieldIcon)
)
Add-Submenu 'Directory' '30DevTools' '开发工具' @(
    (Item 'TakeOwn' '取得所有权（管理员，含子项）' (Cm 'TakeOwn' '%1') $ShieldIcon)
)

# ---- 6. 脚本工具 ----
if ($HasWsl) {
    foreach ($e in '.sh', '.bash') { Add-Verb "SystemFileAssociations\$e" '41RunWsl' '在 WSL 中运行 (bash)' (Cm 'RunInWsl' '%1') $WslIcon }
}

# ---- 7. 新建菜单（安装时清理完旧版后再按真实状态计算，这里先预览） ----
$NewPlan = [ordered]@{}
foreach ($e in $NewExts) { $NewPlan[$e] = Resolve-NewItem $e }

# ---- 8. 「发送到」快捷方式 ----
$SendToDir = [Environment]::GetFolderPath('SendTo')
$SendTo = @()
if ($VSCode) { $SendTo += [pscustomobject]@{ Name = 'VS Code'; Target = $VSCode } }
if ($Chrome) { $SendTo += [pscustomobject]@{ Name = 'Chrome'; Target = $Chrome } }

# ======================= 3. 预览 =======================
$verbCount = @($Plan | Where-Object { $_.Values.ContainsKey('MUIVerb') -and $_.Path -notmatch '\\shell\\CM\.[^\\]+\\shell\\' }).Count
Say ''
Say "安装目录：$Dir" 'Cyan'
Say ("右键菜单：{0} 个菜单项（含子菜单），共写入 {1} 个注册表键" -f $verbCount, $Plan.Count) 'Cyan'
if ($DryRun) {
    foreach ($k in $Plan) {
        if ($k.Values.ContainsKey('MUIVerb')) { Say ("  {0}  [{1}]" -f ($k.Path -replace '^Software\\Classes\\', ''), $k.Values.MUIVerb) }
        elseif ($k.Values.ContainsKey('')) { Say ("      -> {0}" -f $k.Values['']) 'DarkGray' }
    }
}
Say '「新建」菜单：' 'Cyan'
foreach ($e in $NewPlan.Keys) {
    $r = $NewPlan[$e]
    Say ("  {0,-6} {1}" -f $e, $r.Why) $(if ($r.Do -eq 'skip') { 'DarkYellow' } else { 'Gray' })
}
Say ("「发送到」：{0}" -f $(if ($SendTo) { ($SendTo.Name -join '、') } else { '无' })) 'Cyan'
if ($IsWin11 -and -not $ClassicForeign) { Say ("经典右键菜单：{0}" -f $(if ($DryRun) { '（实际安装时询问）' } elseif ($WantClassic) { '开启' } else { '不开启' })) 'Cyan' }

if ($DryRun) { Say "`n这是预览（-DryRun），没有做任何修改。" 'Yellow'; return }

# ======================= 4. 安装 =======================
Say "`n开始安装..." 'Cyan'

# 4.1 清掉安装目录里的旧文件（保留安装记录，清理旧版时要用），再编译 cm.exe
[void](New-Item -ItemType Directory -Force -Path $Dir)
if (Test-Path -LiteralPath (Join-Path $Dir $StateName)) {   # 只清理确认是本工具的目录
    Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -ne $StateName } | Remove-Item -Recurse -Force
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$tmpExe = Join-Path $Dir 'cm.new.exe'
$ErrorActionPreference = 'Continue'   # 原生命令的 stderr 在 Stop 模式下会直接抛异常
$out = & $csc /nologo /codepage:65001 /optimize+ /target:winexe /r:System.Core.dll "/out:$tmpExe" (Join-Path $Src 'cm.cs') 2>&1
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw "编译 cm.exe 失败：`n$($out -join "`n")" }
Move-Item -LiteralPath $tmpExe -Destination $Exe -Force

# 4.2 复制文件
foreach ($f in 'common.ps1', 'uninstall.ps1', 'uninstall.cmd', 'README.md') {
    Copy-Item -LiteralPath (Join-Path $Src $f) -Destination $Dir -Force
}
# cm.exe 的配置：安装时检测到的路径
@("vscode=$VSCode", "wt=$WT") | Set-Content -LiteralPath (Join-Path $Dir 'cm.config') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $Src 'templates') -Destination $Dir -Recurse -Force
foreach ($p in $JetBrains) {
    if ($p.Path -and (Test-Path -LiteralPath $p.IconSrc)) {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'icons'))
        Copy-Item -LiteralPath $p.IconSrc -Destination (Join-Path $Dir "icons\$($p.Ico)") -Force
    }
}
Get-ChildItem -LiteralPath $Dir -Recurse -File | Unblock-File   # 去掉下载带来的"来自网络"标记

# 4.3 清理旧版（新旧格式都能清干净）
[void](Remove-Installed $Dir)
$Ours = @{ Keys = @(); Vals = @{} }   # 旧的已清理，后面按真实状态判断

# 4.4 写菜单
function Set-Key([string]$Path, [hashtable]$Values) {
    $k = $HKCU.CreateSubKey($Path)
    try { foreach ($n in $Values.Keys) { $k.SetValue($n, [string]$Values[$n]) } } finally { $k.Close() }
}
foreach ($k in $Plan) { Set-Key $k.Path $k.Values }

# 4.5 其他改动，逐条记录，卸载时按记录还原
$Changes = New-Object System.Collections.Generic.List[object]
function Set-RecordedValue([string]$Path, [string]$Name, [string]$Value) {
    $created = -not (Test-Key $Path)
    $prev = Get-Val $Path $Name
    Set-Key $Path @{ $Name = $Value }
    $Changes.Add([pscustomobject]@{ type = 'value'; path = $Path; name = $Name; set = $Value; prev = $prev; createdKey = $created })
}
function Set-RecordedKey([string]$Path, [hashtable]$Values) {
    Set-Key $Path $Values
    $Changes.Add([pscustomobject]@{ type = 'key'; path = $Path })
}

if ($WantClassic) {
    Set-RecordedKey $ClassicKey @{}
    Set-Key "$ClassicKey\InprocServer32" @{ '' = '' }
}
foreach ($e in $NewExts) {
    $r = Resolve-NewItem $e
    if ($r.Do -eq 'skip') { continue }
    if ($r.Do -eq 'vscode') { Set-RecordedValue "$Classes\$e" '' "VSCode$e" }
    if ($r.Do -eq 'name') { Set-RecordedValue "$Classes\$($r.ProgId)" '' $TxtName }
    $sn = if ($e -eq '.txt') { @{ NullFile = '' } } else { @{ FileName = (Join-Path $Dir "templates\template$e") } }
    Set-RecordedKey "$Classes\$e\ShellNew" $sn
}

# 4.6 「发送到」快捷方式（已存在同名快捷方式就不覆盖）
$created = @()
$sh = New-Object -ComObject WScript.Shell
foreach ($s in $SendTo) {
    $lnk = Join-Path $SendToDir "$($s.Name).lnk"
    if (Test-Path -LiteralPath $lnk) { continue }
    $l = $sh.CreateShortcut($lnk); $l.TargetPath = $s.Target; $l.Save()
    $created += $lnk
}

# 4.7 安装记录（卸载按它还原）
[pscustomobject]@{
    version     = $Version
    installedAt = (Get-Date).ToString('s')
    source      = $Src
    vscode      = $VSCode
    wt          = $WT
    changes     = $Changes.ToArray()
    sendTo      = @($created)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Dir $StateName) -Encoding UTF8

# 4.8 登记到"应用"/"程序和功能"
$k = $HKCU.CreateSubKey($AppKey)
try {
    $k.SetValue('DisplayName', '右键菜单增强')
    $k.SetValue('DisplayVersion', $Version)
    $k.SetValue('InstallLocation', $Dir)
    $k.SetValue('InstallDate', (Get-Date).ToString('yyyyMMdd'))
    $k.SetValue('DisplayIcon', $PsIcon)
    $k.SetValue('UninstallString', "`"$Exe`" --run powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Dir\uninstall.ps1`"")
    $k.SetValue('NoModify', 1, 'DWord')
    $k.SetValue('NoRepair', 1, 'DWord')
    $size = (Get-ChildItem -LiteralPath $Dir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $k.SetValue('EstimatedSize', [int][Math]::Ceiling($size / 1KB), 'DWord')
} finally { $k.Close() }

# 4.9 经典菜单开关有变化时才需要重启资源管理器
if ((Test-Key $ClassicKey) -ne $ClassicBefore) {
    Say '经典菜单设置有变化，正在重启资源管理器...'
    Restart-Explorer
}
Say "`n安装完成。卸载：设置 > 应用 > 已安装的应用 >「右键菜单增强」，或运行 $Dir\uninstall.cmd" 'Green'
