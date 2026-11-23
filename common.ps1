# common.ps1 —— install.ps1 / uninstall.ps1 共用的常量和函数（点源引入）
# 注册表一律用 .NET 的 Microsoft.Win32 接口读写：PowerShell 的注册表驱动器会把键名里的 * 当通配符。

$Classes    = 'Software\Classes'
$Prefix     = 'CM.'
$ClassicKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$AppKey     = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\CM.ContextMenu'
$InstallDir = Join-Path $env:LOCALAPPDATA 'ContextMenu'
$StateName  = 'install-state.json'
$HKCU       = [Microsoft.Win32.Registry]::CurrentUser
$HKLM       = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')

# 旧版（gen_reg.py 生成的 .reg）没有安装记录，按它的 uninstall.reg 清单识别
$LegacyNewExts = '.md', '.sh', '.ps1', '.json', '.yaml', '.py', '.go'

function Test-Key([string]$Path, $Root = $HKCU) {
    $k = $Root.OpenSubKey($Path)
    if ($k) { $k.Close(); return $true }
    return $false
}

function Get-Val([string]$Path, [string]$Name = '', $Root = $HKCU) {
    $k = $Root.OpenSubKey($Path)
    if (-not $k) { return $null }
    try { return $k.GetValue($Name) } finally { $k.Close() }
}

function Get-Parent([string]$Path) { return $Path.Substring(0, $Path.LastIndexOf('\')) }

function Remove-Key([string]$Path) { $HKCU.DeleteSubKeyTree($Path, $false) }

function Test-EmptyKey([string]$Path) {
    $k = $HKCU.OpenSubKey($Path)
    if (-not $k) { return $false }
    try { return ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) } finally { $k.Close() }
}

function Read-State([string]$Dir = $InstallDir) {
    $p = Join-Path $Dir $StateName
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

# WSL 默认发行版名称；没装 WSL 或没有发行版时返回 $null
function Get-DefaultDistro {
    $lx = 'Software\Microsoft\Windows\CurrentVersion\Lxss'
    $id = Get-Val $lx 'DefaultDistribution'
    if (-not $id) { return $null }
    return Get-Val "$lx\$id" 'DistributionName'
}

# 所有 CM. 开头的菜单项（新旧版本都在这些位置下）
function Find-CMVerbs {
    $parents = @('*', 'Directory', 'Directory\Background', 'Drive', 'AllFilesystemObjects')
    $sfa = $HKCU.OpenSubKey("$Classes\SystemFileAssociations")
    if ($sfa) {
        $parents += @($sfa.GetSubKeyNames() | ForEach-Object { "SystemFileAssociations\$_" })
        $sfa.Close()
    }
    foreach ($p in $parents) {
        $sh = "$Classes\$p\shell"
        $k = $HKCU.OpenSubKey($sh)
        if (-not $k) { continue }
        $names = $k.GetSubKeyNames()
        $k.Close()
        foreach ($n in $names) { if ($n.StartsWith($Prefix)) { "$sh\$n" } }
    }
}

# 本工具改动过的非 CM. 项，供安装时判断"这是我们自己写的，不算用户原有设置"
# 返回 @{ Keys = 键路径列表; Vals = @{ '路径|值名' = 我们写入的值 } }
function Get-Ours($State, [bool]$Legacy) {
    $keys = @(); $vals = @{}
    if ($State) {
        foreach ($c in @($State.changes)) {
            if ($c.type -eq 'key') { $keys += $c.path }
            elseif ($c.type -eq 'value') { $vals["$($c.path)|$($c.name)"] = $c.set }
        }
    } elseif ($Legacy) {
        $keys += $ClassicKey, "$Classes\txtfilelegacy", "$Classes\.txt\ShellNew"
        foreach ($e in $LegacyNewExts) {
            $keys += "$Classes\$e\ShellNew"
            $vals["$Classes\$e|"] = "VSCode$e"
        }
    }
    return @{ Keys = $keys; Vals = $vals }
}

function Undo-Change($c) {
    if ($c.type -eq 'key') { Remove-Key $c.path; return }
    $k = $HKCU.OpenSubKey($c.path, $true)
    if (-not $k) { return }
    try {
        # 只在值仍是我们写入的那个时才还原，用户之后自己改过的就不动
        if ([string]$k.GetValue($c.name) -eq [string]$c.set) {
            if ($null -eq $c.prev) { $k.DeleteValue($c.name, $false) } else { $k.SetValue($c.name, [string]$c.prev) }
        }
    } finally { $k.Close() }
    if ($c.createdKey -and (Test-EmptyKey $c.path)) { Remove-Key $c.path }
}

# 清理已安装的内容（不删文件）。新旧版本都能清干净；返回清理前的安装记录
function Remove-Installed([string]$Dir = $InstallDir) {
    $state = Read-State $Dir
    $verbs = @(Find-CMVerbs)
    foreach ($v in $verbs) {
        Remove-Key $v
        # 顺手删掉因此变空的 shell 键，以及我们为它建的 SystemFileAssociations\<扩展名> 键
        $sh = Get-Parent $v
        if (Test-EmptyKey $sh) {
            Remove-Key $sh
            $parent = Get-Parent $sh
            if ($parent -like "$Classes\SystemFileAssociations\*" -and (Test-EmptyKey $parent)) { Remove-Key $parent }
        }
    }

    if ($state) {
        $changes = @($state.changes)
        [array]::Reverse($changes)
        foreach ($c in $changes) { Undo-Change $c }
        foreach ($l in @($state.sendTo)) { if ($l) { Remove-Item -LiteralPath $l -ErrorAction SilentlyContinue } }
    } elseif ($verbs.Count) {
        # 旧版：按旧 uninstall.reg 的清单删除
        $o = Get-Ours $null $true
        foreach ($k in $o.Keys) { Remove-Key $k }
        foreach ($e in $LegacyNewExts) {
            Undo-Change ([pscustomobject]@{ type = 'value'; path = "$Classes\$e"; name = ''; set = "VSCode$e"; prev = $null; createdKey = $true })
        }
        $sendTo = [Environment]::GetFolderPath('SendTo')
        Remove-Item -LiteralPath (Join-Path $sendTo 'VS Code.lnk'), (Join-Path $sendTo 'Chrome.lnk') -ErrorAction SilentlyContinue
    }
    Remove-Key $AppKey
    return $state
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}
