# get.ps1 —— 一行命令安装（在 PowerShell 里运行）：
#   irm https://raw.githubusercontent.com/luzhifang/win-context-menu/main/get.ps1 | iex
# 下载最新 Release 的源码包（还没有 Release 时用 main 分支），解压到临时目录，运行 install.ps1，最后删除临时目录。
# 本文件不带 BOM：它是给 irm | iex 用的，不要直接双击运行。
& {
    $ErrorActionPreference = 'Stop'
    $Repo = 'luzhifang/win-context-menu'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $tmp = Join-Path $env:TEMP ('win-context-menu-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp)
    try {
        $url = "https://github.com/$Repo/archive/refs/heads/main.zip"
        try {
            $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
            if ($rel.zipball_url) { $url = $rel.zipball_url; Write-Host "最新版本：$($rel.tag_name)" }
        } catch { Write-Host '没有找到 Release，使用 main 分支。' }

        $zip = Join-Path $tmp 'src.zip'
        Write-Host "下载 $url"
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp
        $src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $src) { throw '解压后没有找到源码目录。' }

        # 安装脚本需要 Windows PowerShell 5.1（编译 cm.exe 和写注册表都基于 .NET Framework）
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src.FullName 'install.ps1')
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
