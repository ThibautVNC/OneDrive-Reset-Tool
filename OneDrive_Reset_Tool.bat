<# : OneDrive Reset Tool - batch launcher (the PowerShell GUI code is below)
@echo off
setlocal
set "ODRT_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:ODRT_SCRIPT))"
exit /b
#>

# =====================================================================
#  OneDrive Reset Tool
#
#  Signs the current user out of OneDrive by resetting its configuration
#  and cleans up (ghost) OneDrive / SharePoint entries in File Explorer.
#  Every registry key is exported to a .reg file before it is removed.
#
#  Only HKEY_CURRENT_USER is changed: run this as the affected user.
#  Local files are never deleted.
#
#  OneDrive Reset Tool v1.0
#  Created by Thibaut VNC
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Settings --------------------------------------------------------
$NameSpaceKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
$NameSpaceKeyReg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
$OneDriveKey     = 'HKCU:\Software\Microsoft\OneDrive'
$OneDriveKeyReg  = 'HKCU\Software\Microsoft\OneDrive'
$BackupRoot      = Join-Path $env:LOCALAPPDATA 'OneDriveResetTool\Backups'
$AppName         = 'OneDrive Reset Tool'
$AppVersion      = 'v1.0'
$AppAuthor       = 'Thibaut VNC'
$script:LogFile  = $null
$script:HackerMode = $false

$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin     = ([Security.Principal.WindowsPrincipal]$CurrentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$MySession   = (Get-Process -Id $PID).SessionId

# ---- Helper functions ------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-OneDriveExe {
    # Prefer the path OneDrive registered itself, then the three standard install locations.
    $candidates = @()
    try {
        $registered = (Get-ItemProperty -Path $OneDriveKey -Name OneDrivePath -ErrorAction Stop).OneDrivePath
        if ($registered) { $candidates += $registered }
    } catch { }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    $candidates += (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-NameSpaceEntries {
    # Lists the File Explorer navigation pane entries of the current user.
    if (-not (Test-Path -Path $NameSpaceKey)) { return @() }
    foreach ($key in Get-ChildItem -Path $NameSpaceKey) {
        $guid = $key.PSChildName
        $name = $key.GetValue('')
        if (-not $name) {
            $clsid = "HKCU:\Software\Classes\CLSID\$guid"
            if (Test-Path -LiteralPath $clsid) { $name = (Get-Item -LiteralPath $clsid).GetValue('') }
        }
        if (-not $name) { $name = '(no name)' }
        [pscustomobject]@{
            Guid       = $guid
            Name       = $name
            Path       = $key.PSPath
            IsOneDrive = ($name -match 'OneDrive|SharePoint')
        }
    }
}

function Export-RegKey {
    param([string]$RegPath, [string]$File)
    $p = Start-Process -FilePath 'reg.exe' -ArgumentList @('export', $RegPath, ('"{0}"' -f $File), '/y') `
                       -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $File)) {
        throw "Backup of $RegPath failed (reg.exe exit code $($p.ExitCode)). Nothing has been removed."
    }
    Write-Log "Backed up $RegPath"
}

function Get-SessionProcess {
    param([string]$Name)
    # Only processes of the current user session (important on RDS / terminal servers).
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $MySession }
}

function Stop-OneDrive {
    $procs = @(Get-SessionProcess -Name 'OneDrive')
    if ($procs.Count -eq 0) {
        Write-Log 'OneDrive is not running.'
        return
    }
    $procs | Stop-Process -Force
    $procs | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Write-Log "Stopped OneDrive ($($procs.Count) process(es))."
}

function Restart-Explorer {
    $procs = @(Get-SessionProcess -Name 'explorer')
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 3
    }
    if (@(Get-SessionProcess -Name 'explorer').Count -eq 0) {
        Start-Process -FilePath 'explorer.exe'
    }
    Write-Log 'Restarted File Explorer.'
}

# ---- Explanation text ------------------------------------------------
$InfoText = @"
WHAT THIS TOOL DOES
1. Stops OneDrive for the current user.
2. Backs up the registry keys it is about to change to .reg files (see 'Open backup folder').
3. Removes OneDrive / SharePoint entries from the File Explorer navigation pane.
4. Deletes the OneDrive configuration (HKCU\Software\Microsoft\OneDrive). This signs out EVERY OneDrive account in this user profile.
5. Starts OneDrive again so the user can sign in fresh.

WHEN TO USE IT
- Sync is stuck or keeps failing.
- An old or wrong account is still linked.
- Duplicate or ghost 'OneDrive - Company' entries in File Explorer.
- SharePoint / Teams libraries that will not (re)sync.

GOOD TO KNOW
- Local files are NOT deleted. After signing in, OneDrive may ask whether to use the existing OneDrive folder: choose to use it, otherwise you get a duplicate 'OneDrive - Company (2)' folder.
- SharePoint / Teams libraries have to be synced again afterwards ('Sync' button in SharePoint).
- Save and close open Office documents first.
- Run this as the affected user. Starting it with 'Run as administrator' under a different account resets THAT account instead.
- To undo: close OneDrive and double-click the .reg files in the backup folder.
"@ -replace "`r?`n", "`r`n"

# ---- GUI -------------------------------------------------------------
try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "$AppName $AppVersion - by $AppAuthor"
    $form.ClientSize      = New-Object System.Drawing.Size(700, 712)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = $AppName
    $lblTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(12, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text      = $AppVersion
    $lblVersion.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblVersion.Location  = New-Object System.Drawing.Point(232, 22)
    $lblVersion.AutoSize  = $true
    $form.Controls.Add($lblVersion)

    $txtInfo = New-Object System.Windows.Forms.TextBox
    $txtInfo.Multiline  = $true
    $txtInfo.ReadOnly   = $true
    $txtInfo.ScrollBars = 'Vertical'
    $txtInfo.BackColor  = [System.Drawing.SystemColors]::Window
    $txtInfo.Location   = New-Object System.Drawing.Point(12, 48)
    $txtInfo.Size       = New-Object System.Drawing.Size(676, 195)
    $txtInfo.Text       = $InfoText
    $form.Controls.Add($txtInfo)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text     = "Running as: $($CurrentUser.Name)"
    $lblUser.Location = New-Object System.Drawing.Point(12, 252)
    $lblUser.AutoSize = $true
    $form.Controls.Add($lblUser)

    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblWarn.Location  = New-Object System.Drawing.Point(12, 272)
    $lblWarn.Size      = New-Object System.Drawing.Size(676, 20)
    if ($IsAdmin) {
        $lblWarn.Text = 'Elevated session: make sure this is the affected user''s own account, otherwise the wrong profile is reset.'
    }
    $form.Controls.Add($lblWarn)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text     = 'Options'
    $grp.Location = New-Object System.Drawing.Point(12, 296)
    $grp.Size     = New-Object System.Drawing.Size(676, 175)
    $form.Controls.Add($grp)

    $chkNS = New-Object System.Windows.Forms.CheckBox
    $chkNS.Text     = 'Remove File Explorer navigation pane entries'
    $chkNS.Checked  = $true
    $chkNS.Location = New-Object System.Drawing.Point(15, 24)
    $chkNS.Size     = New-Object System.Drawing.Size(640, 22)
    $grp.Controls.Add($chkNS)

    $rbOD = New-Object System.Windows.Forms.RadioButton
    $rbOD.Text     = 'Only OneDrive / SharePoint entries (recommended)'
    $rbOD.Checked  = $true
    $rbOD.Location = New-Object System.Drawing.Point(38, 47)
    $rbOD.Size     = New-Object System.Drawing.Size(600, 22)
    $grp.Controls.Add($rbOD)

    $rbAll = New-Object System.Windows.Forms.RadioButton
    $rbAll.Text     = 'All entries, incl. Dropbox / Google Drive / iCloud (behaviour of the old script)'
    $rbAll.Location = New-Object System.Drawing.Point(38, 70)
    $rbAll.Size     = New-Object System.Drawing.Size(620, 22)
    $grp.Controls.Add($rbAll)

    $chkCfg = New-Object System.Windows.Forms.CheckBox
    $chkCfg.Text     = 'Reset OneDrive configuration (signs out all OneDrive accounts)'
    $chkCfg.Checked  = $true
    $chkCfg.Location = New-Object System.Drawing.Point(15, 96)
    $chkCfg.Size     = New-Object System.Drawing.Size(640, 22)
    $grp.Controls.Add($chkCfg)

    $chkStart = New-Object System.Windows.Forms.CheckBox
    $chkStart.Text     = 'Start OneDrive afterwards'
    $chkStart.Checked  = $true
    $chkStart.Location = New-Object System.Drawing.Point(15, 120)
    $chkStart.Size     = New-Object System.Drawing.Size(640, 22)
    $grp.Controls.Add($chkStart)

    $chkExplorer = New-Object System.Windows.Forms.CheckBox
    $chkExplorer.Text     = 'Restart File Explorer afterwards (refreshes the navigation pane; closes open Explorer windows)'
    $chkExplorer.Checked  = $false
    $chkExplorer.Location = New-Object System.Drawing.Point(15, 144)
    $chkExplorer.Size     = New-Object System.Drawing.Size(650, 22)
    $grp.Controls.Add($chkExplorer)

    $chkNS.Add_CheckedChanged({
        $rbOD.Enabled  = $chkNS.Checked
        $rbAll.Enabled = $chkNS.Checked
    })

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text     = 'Start reset'
    $btnRun.Location = New-Object System.Drawing.Point(12, 482)
    $btnRun.Size     = New-Object System.Drawing.Size(170, 32)
    $btnRun.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRun)

    $btnBackup = New-Object System.Windows.Forms.Button
    $btnBackup.Text     = 'Open backup folder'
    $btnBackup.Location = New-Object System.Drawing.Point(192, 482)
    $btnBackup.Size     = New-Object System.Drawing.Size(170, 32)
    $form.Controls.Add($btnBackup)

    $btnTheme = New-Object System.Windows.Forms.Button
    $btnTheme.Text     = 'Hacker mode'
    $btnTheme.Location = New-Object System.Drawing.Point(372, 482)
    $btnTheme.Size     = New-Object System.Drawing.Size(136, 32)
    $form.Controls.Add($btnTheme)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(518, 482)
    $btnClose.Size     = New-Object System.Drawing.Size(170, 32)
    $form.Controls.Add($btnClose)
    $form.CancelButton = $btnClose

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline  = $true
    $txtLog.ReadOnly   = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.BackColor  = [System.Drawing.SystemColors]::Window
    $txtLog.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.Location   = New-Object System.Drawing.Point(12, 524)
    $txtLog.Size       = New-Object System.Drawing.Size(676, 154)
    $form.Controls.Add($txtLog)

    $lblCredits = New-Object System.Windows.Forms.Label
    $lblCredits.Text      = "$AppName $AppVersion - Created by $AppAuthor"
    $lblCredits.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblCredits.Location  = New-Object System.Drawing.Point(12, 684)
    $lblCredits.AutoSize  = $true
    $form.Controls.Add($lblCredits)

    # ---- Theme (normal / hacker) -------------------------------------
    function Set-Theme {
        param([bool]$Hacker)

        if ($Hacker) {
            $bg        = [System.Drawing.Color]::Black
            $fg        = [System.Drawing.Color]::FromArgb(0, 255, 65)
            $dim       = [System.Drawing.Color]::FromArgb(0, 160, 60)
            $fieldBg   = [System.Drawing.Color]::Black
            $warn      = [System.Drawing.Color]::Orange
            $font      = New-Object System.Drawing.Font('Consolas', 9)
            $titleFont = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
        } else {
            $bg        = [System.Drawing.SystemColors]::Control
            $fg        = [System.Drawing.SystemColors]::ControlText
            $dim       = [System.Drawing.SystemColors]::GrayText
            $fieldBg   = [System.Drawing.SystemColors]::Window
            $warn      = [System.Drawing.Color]::DarkOrange
            $font      = New-Object System.Drawing.Font('Segoe UI', 9)
            $titleFont = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        }

        $form.BackColor = $bg
        $form.ForeColor = $fg
        $form.Font      = $font

        $apply = {
            param($Parent)
            foreach ($c in $Parent.Controls) {
                if ($c -is [System.Windows.Forms.TextBox]) {
                    $c.BackColor = $fieldBg
                    $c.ForeColor = $fg
                } elseif ($c -is [System.Windows.Forms.Button]) {
                    if ($Hacker) {
                        $c.FlatStyle = 'Flat'
                        $c.BackColor = $bg
                        $c.ForeColor = $fg
                        $c.FlatAppearance.BorderColor = $fg
                    } else {
                        $c.FlatStyle = 'Standard'
                        $c.UseVisualStyleBackColor = $true
                        $c.ForeColor = [System.Drawing.SystemColors]::ControlText
                    }
                } else {
                    $c.BackColor = $bg
                    $c.ForeColor = $fg
                }
                if ($c.Controls.Count -gt 0) { & $apply $c }
            }
        }
        & $apply $form

        # Controls with their own styling
        $lblTitle.Font        = $titleFont
        $lblVersion.ForeColor = $dim
        $lblCredits.ForeColor = $dim
        $lblWarn.ForeColor    = $warn
        $btnRun.Font          = New-Object System.Drawing.Font($font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
        $txtLog.Font          = New-Object System.Drawing.Font('Consolas', 9)
        $form.Refresh()
    }

    # ---- Events ------------------------------------------------------
    $btnTheme.Add_Click({
        $script:HackerMode = -not $script:HackerMode
        Set-Theme -Hacker $script:HackerMode
        if ($script:HackerMode) {
            $btnTheme.Text = 'Normal mode'
            Write-Log 'Hacker mode engaged. Purely cosmetic, nothing else changed.'
        } else {
            $btnTheme.Text = 'Hacker mode'
            Write-Log 'Back to normal mode.'
        }
    })

    $btnClose.Add_Click({ $form.Close() })

    $btnBackup.Add_Click({
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $BackupRoot)
    })

    $form.Add_Shown({
        Write-Log "$AppName $AppVersion - Created by $AppAuthor"
        Write-Log "User: $($CurrentUser.Name)$(if ($IsAdmin) { ' (elevated)' })"
        $exe = Get-OneDriveExe
        if ($exe) { Write-Log "OneDrive found: $exe" } else { Write-Log 'OneDrive.exe not found in the standard locations.' }
        $entries = @(Get-NameSpaceEntries)
        Write-Log "File Explorer navigation entries: $($entries.Count)"
        foreach ($e in $entries) {
            $tag = if ($e.IsOneDrive) { '[OneDrive]' } else { '[other]   ' }
            Write-Log "  $tag $($e.Name)  $($e.Guid)"
        }
        Write-Log 'Ready. Choose your options and click "Start reset".'
    })

    $btnRun.Add_Click({
        if (-not ($chkNS.Checked -or $chkCfg.Checked)) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one of the two reset options.', $AppName,
                'OK', 'Information') | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "OneDrive will be closed and reset for $($CurrentUser.Name).`r`n`r`nSave and close open Office documents first.`r`n`r`nContinue?",
            $AppName, 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $btnRun.Enabled = $false
        $grp.Enabled    = $false
        try {
            # Backup folder + log file for this run
            $backupDir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $script:LogFile = Join-Path $backupDir 'log.txt'
            Write-Log "--- Reset started ($AppName $AppVersion by $AppAuthor) ---"
            Write-Log "Backup folder: $backupDir"

            # Remember where OneDrive lives before its config is removed
            $exe = Get-OneDriveExe

            # 1. Stop OneDrive
            Stop-OneDrive

            # 2. Back up everything first; abort before deleting anything if a backup fails
            if ($chkNS.Checked -and (Test-Path -Path $NameSpaceKey)) {
                Export-RegKey -RegPath $NameSpaceKeyReg -File (Join-Path $backupDir 'Explorer-NameSpace.reg')
            }
            if ($chkCfg.Checked -and (Test-Path -Path $OneDriveKey)) {
                Export-RegKey -RegPath $OneDriveKeyReg -File (Join-Path $backupDir 'OneDrive-Config.reg')
            }

            # 3. File Explorer navigation entries
            if ($chkNS.Checked) {
                if (-not (Test-Path -Path $NameSpaceKey)) {
                    Write-Log 'No navigation entries key found, skipping.'
                } elseif ($rbAll.Checked) {
                    Remove-Item -Path $NameSpaceKey -Recurse -Force
                    Write-Log 'Removed ALL File Explorer navigation entries.'
                } else {
                    $targets = @(Get-NameSpaceEntries | Where-Object { $_.IsOneDrive })
                    foreach ($t in $targets) {
                        Remove-Item -LiteralPath $t.Path -Recurse -Force
                        Write-Log "Removed navigation entry: $($t.Name)"
                    }
                    if ($targets.Count -eq 0) { Write-Log 'No OneDrive / SharePoint navigation entries found.' }
                }
            }

            # 4. OneDrive configuration
            if ($chkCfg.Checked) {
                if (Test-Path -Path $OneDriveKey) {
                    Remove-Item -Path $OneDriveKey -Recurse -Force
                    Write-Log 'Removed OneDrive configuration (all accounts signed out).'
                } else {
                    Write-Log 'No OneDrive configuration found, skipping.'
                }
            }

            # 5. Optional: restart File Explorer
            if ($chkExplorer.Checked) { Restart-Explorer }

            # 6. Start OneDrive again
            if ($chkStart.Checked) {
                if ($exe) {
                    Start-Process -FilePath $exe
                    Write-Log "Started OneDrive: $exe"
                } else {
                    Write-Log 'OneDrive.exe not found; start or reinstall it manually.'
                }
            }

            Write-Log '--- Reset finished ---'
            [System.Windows.Forms.MessageBox]::Show(
                "Done.`r`n`r`nSign in to OneDrive again and re-sync the SharePoint / Teams libraries.`r`n`r`nBackup: $backupDir",
                $AppName, 'OK', 'Information') | Out-Null
        }
        catch {
            Write-Log "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Something went wrong:`r`n`r`n$($_.Exception.Message)",
                $AppName, 'OK', 'Error') | Out-Null
        }
        finally {
            $script:LogFile = $null
            $btnRun.Enabled = $true
            $grp.Enabled    = $true
        }
    })

    [void]$form.ShowDialog()
}
catch {
    [System.Windows.Forms.MessageBox]::Show("The tool could not start:`r`n`r`n$($_.Exception.Message)",
        $AppName, 'OK', 'Error') | Out-Null
}
