param(
    # Folder for LunqDebloater, %USERPROFILE%\LunqDebloater by default. To choose another one:
    #   & ([scriptblock]::Create((irm <url>))) -Path D:\LunqDebloater
    [string]$Path
)
# Starts LunqDebloater with one command:
#   irm https://raw.githubusercontent.com/Lunqasd1337/LunqDebloater/main/Install.ps1 | iex
# Downloads the latest release into a folder, updates it on the next run and keeps the user's
# changes in Config, then starts LunqDebloater.ps1 in Windows PowerShell 5.1.
#
# This file is ASCII only and has no BOM, unlike the other scripts: irm hands it to iex as text,
# and Windows PowerShell 5.1 may decode anything else wrongly. That is also why the messages
# and comments here are in English. ARCHITECTURE.md explains it in more detail.

function Test-LunqInstallFolder {
    # Files are copied into the folder, so only a new or empty folder or an earlier install will do.
    # Release folders are replaced as a whole, so a git clone (it has LunqDebloater.ps1 too) is
    # refused: uncommitted work in Modules or Tests would be lost.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path '.lunq-install.json')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path 'LunqDebloater.ps1')) { return $true }
    return -not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

function Protect-LunqInstallFolder {
    # LunqDebloater runs as administrator from this folder, so only its owner, administrators and
    # SYSTEM may change the files. A new folder in the root of a drive (D:\LunqDebloater) inherits
    # a rule that lets every signed-in user change it, and their code would then run as administrator.
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    # NTFS rights exist only on Windows; the tests on Linux set $env:OS, so the platform itself is checked.
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
    try {
        # A new security object changes only the access rules, not the owner of the folder.
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
        foreach ($sid in @($owner, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'), (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    catch {
        # FAT32 and exFAT drives have no access rules at all.
        Write-Warning "Could not limit access to $Path to you and administrators: $($_.Exception.Message)"
    }
}

function Get-LunqInstallState {
    # What the previous run installed: the release tag and the hashes of the Config files.
    param([Parameter(Mandatory)][string]$Path)
    $file = Join-Path $Path '.lunq-install.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Get-LunqLatestRelease {
    # The latest published release, not main: main may be in the middle of changes.
    $repo = 'Lunqasd1337/LunqDebloater'
    $headers = @{ 'User-Agent' = 'LunqDebloater-Install'; 'Accept' = 'application/vnd.github+json' }
    try { $tag = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -UseBasicParsing).tag_name }
    catch {
        # Without a token the API allows 60 requests an hour per IP address, so behind a shared NAT
        # (a school, an office) it answers 403. The releases page has no such limit: it redirects
        # to the page of the latest tag.
        $apiError = $_
        try {
            $response = Invoke-WebRequest -Uri "https://github.com/$repo/releases/latest" -Headers @{ 'User-Agent' = 'LunqDebloater-Install' } -UseBasicParsing
            # Windows PowerShell 5.1 and PowerShell 7 keep the final address in different places.
            $base = $response.BaseResponse
            if ($base.PSObject.Properties['ResponseUri']) { $finalUri = [string]$base.ResponseUri }
            else { $finalUri = [string]$base.RequestMessage.RequestUri }
        }
        catch { throw $apiError }
        if ($finalUri -notmatch '/releases/tag/([^/?#]+)') { throw $apiError }
        $tag = [uri]::UnescapeDataString($Matches[1])
    }
    return [pscustomobject]@{
        Tag    = $tag
        ZipUrl = "https://github.com/$repo/archive/refs/tags/$tag.zip"
    }
}

function Install-LunqFiles {
    # Copies an unpacked release into the folder and returns the Config files that kept the user's version.
    # Folders of the release are replaced as a whole, so files removed from the module do not stay
    # behind. Files that are not in the release (an ISO, Logs) are left alone. A Config file is
    # overwritten only if the user has not changed it since the previous install.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Tag
    )
    $state = Get-LunqInstallState -Path $Destination
    $installedHashes = @{}
    if ($state -and $state.PSObject.Properties['ConfigHashes'] -and $state.ConfigHashes) {
        foreach ($property in $state.ConfigHashes.PSObject.Properties) { $installedHashes[$property.Name] = $property.Value }
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -ne 'Config' })) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }

    $kept = @()
    $hashes = [ordered]@{}
    $sourceConfig = Join-Path $Source 'Config'
    $targetConfig = Join-Path $Destination 'Config'
    if (Test-Path -LiteralPath $sourceConfig) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceConfig -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($sourceConfig.Length).TrimStart('\', '/')
            # The key is the same on every system, so the state file does not depend on where it was written.
            $key = $relative -replace '/', '\'
            $target = Join-Path $targetConfig $relative
            $newHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $hashes[$key] = $newHash
            if (Test-Path -LiteralPath $target) {
                $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($currentHash -eq $newHash) { continue }
                # Without a state file it is unknown who changed the file, so the user's copy stays.
                if ($currentHash -ne $installedHashes[$key]) {
                    $kept += $key
                    continue
                }
            }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }

    [pscustomobject]@{ Tag = $Tag; ConfigHashes = $hashes } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $Destination '.lunq-install.json') -Encoding ASCII
    return , $kept
}

function Start-LunqDebloater {
    # LunqDebloater works only in Windows PowerShell 5.1 and asks for administrator rights by itself.
    param([Parameter(Mandatory)][string]$Path)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Path 'LunqDebloater.ps1')
}

function Invoke-LunqInstall {
    param([string]$Path)
    $ErrorActionPreference = 'Stop'
    # The progress bar makes downloads many times slower in Windows PowerShell 5.1.
    $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT') { throw 'LunqDebloater only works on Windows.' }
    # The user's own folder: LunqDebloater runs as administrator from it, so other users of the
    # computer must not be able to change its files. A folder in the root of C: can be changed by them.
    if (-not $Path) { $Path = Join-Path $env:USERPROFILE 'LunqDebloater' }
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-LunqInstallFolder -Path $Path)) {
        throw "$Path is not empty and is not a LunqDebloater folder. Choose another folder with -Path."
    }
    # Without TLS 1.2 older Windows PowerShell 5.1 setups cannot connect to GitHub.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $installed = Test-Path -LiteralPath (Join-Path $Path 'LunqDebloater.ps1')
    $state = Get-LunqInstallState -Path $Path
    try { $release = Get-LunqLatestRelease }
    catch {
        if (-not $installed) { throw "Could not get the latest release from GitHub: $($_.Exception.Message)" }
        Write-Warning "Could not check for a new version ($($_.Exception.Message)). Starting the installed one."
        $release = $null
    }
    # Earlier installs get the same rights too: before 1.9.2 they kept the rights of the parent folder.
    Protect-LunqInstallFolder -Path $Path

    if ($release -and $installed -and $state -and $state.Tag -eq $release.Tag) {
        Write-Host "LunqDebloater $($release.Tag) is up to date: $Path" -ForegroundColor Green
    }
    elseif ($release) {
        Write-Host "Downloading LunqDebloater $($release.Tag)..." -ForegroundColor Cyan
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('LunqDebloater-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            $zip = Join-Path $temp 'release.zip'
            $unpacked = Join-Path $temp 'release'
            Invoke-WebRequest -Uri $release.ZipUrl -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
            # A GitHub archive has one folder inside, LunqDebloater-<version>.
            $root = @(Get-ChildItem -LiteralPath $unpacked -Directory)
            if ($root.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $root[0].FullName 'LunqDebloater.ps1'))) {
                throw "The archive of $($release.Tag) does not contain LunqDebloater.ps1."
            }
            $kept = Install-LunqFiles -Source $root[0].FullName -Destination $Path -Tag $release.Tag
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "LunqDebloater $($release.Tag) is in $Path" -ForegroundColor Green
        if ($kept.Count -gt 0) {
            Write-Host 'These files in Config were changed by you and were not replaced:'
            foreach ($file in $kept) { Write-Host "  Config\$file" }
        }
    }
    Start-LunqDebloater -Path $Path
}

try { Invoke-LunqInstall -Path $Path }
catch { Write-Host "LunqDebloater: $($_.Exception.Message)" -ForegroundColor Red }
