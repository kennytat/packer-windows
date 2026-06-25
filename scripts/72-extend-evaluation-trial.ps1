#Requires -Version 3.0

<#
.SYNOPSIS
    Automatically extend Windows evaluation / trial activation periods.

.DESCRIPTION
    Detects time-based evaluation licenses (Windows Server and client eval
    editions) and runs slmgr /rearm when the remaining grace period drops
    below a configurable threshold. Rearm is deferred until late in the
    current 180-day window so all six rearms can be used across ~3 years.

    Use -Install to copy this script to ProgramData and register a scheduled
    task that runs at startup and daily.
#>

[CmdletBinding()]
Param (
    [int]$ThresholdDays = 30,
    [switch]$Install,
    [switch]$Force,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'PackerWindows-ExtendEvaluationTrial'
$InstallRoot = Join-Path $env:ProgramData 'PackerWindows'
$InstallPath = Join-Path $InstallRoot 'extend-evaluation-trial.ps1'
$StatePath = Join-Path $InstallRoot 'evaluation-trial.state.json'
$SlmgrPath = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
$EventSource = $ScriptName

function Write-TrialLog {
    param(
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Information'
    )

    Write-Host $Message
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        New-EventLog -LogName Application -Source $EventSource -ErrorAction SilentlyContinue | Out-Null
    }
    Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId 1 -Message $Message -ErrorAction SilentlyContinue
}

function Get-TrialState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{}
    }

    try {
        $json = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $state = @{}
        $json.PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
        return $state
    }
    catch {
        return @{}
    }
}

function Save-TrialState {
    param([hashtable]$State)

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }

    ($State | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Test-EvaluationEdition {
    $versionKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = (Get-ItemProperty -Path $versionKey -Name EditionID -ErrorAction SilentlyContinue).EditionID
    $productName = (Get-ItemProperty -Path $versionKey -Name ProductName -ErrorAction SilentlyContinue).ProductName

    if ($editionId -match 'Eval') {
        return $true
    }

    if ($productName -match 'Evaluation') {
        return $true
    }

    return $false
}

function Get-SlmgrDetailedOutput {
    $output = & cscript.exe //nologo $SlmgrPath /dlv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "slmgr /dlv failed with exit code $LASTEXITCODE`: $output"
    }

    return ($output | Out-String)
}

function Get-EvaluationTrialStatus {
    $status = [ordered]@{
        IsEvaluation = Test-EvaluationEdition
        DaysRemaining = $null
        RearmRemaining = $null
        Description = $null
        LicenseStatus = $null
    }

    if (-not $status.IsEvaluation) {
        return [pscustomobject]$status
    }

    $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
        Where-Object { $_.PartialProductKey -and $_.LicenseStatus -eq 1 } |
        Sort-Object GracePeriodRemaining -Descending |
        Select-Object -First 1

    if ($license -and $null -ne $license.GracePeriodRemaining) {
        $status.DaysRemaining = [math]::Floor($license.GracePeriodRemaining / 1440)
        $status.Description = $license.Description
        $status.LicenseStatus = $license.LicenseStatus
    }

    $dlv = Get-SlmgrDetailedOutput
    if ($dlv -match 'Timebased activation expiration:\s*(\d+)\s+minute\(s\)\s*\((\d+)\s+day\(s\)\)') {
        $status.DaysRemaining = [int]$Matches[2]
    }

    if ($dlv -match 'Remaining Windows rearm count:\s*(\d+)') {
        $status.RearmRemaining = [int]$Matches[1]
    }

    if ($dlv -match 'Description:\s*(.+)') {
        $status.Description = $Matches[1].Trim()
        if ($status.Description -notmatch 'TIMEBASED_EVAL|Eval') {
            $status.IsEvaluation = $false
        }
    }

    return [pscustomobject]$status
}

function Invoke-EvaluationRearm {
    Write-TrialLog "Running slmgr /rearm to reset the evaluation grace period."

    if ($WhatIf) {
        Write-TrialLog "WhatIf: would run slmgr /rearm and schedule a reboot."
        return
    }

    $output = & cscript.exe //nologo $SlmgrPath /rearm 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "slmgr /rearm failed with exit code $LASTEXITCODE`: $output"
    }

    Write-TrialLog "slmgr /rearm succeeded. Scheduling reboot in 60 seconds."
    & shutdown.exe /r /t 60 /c 'Rebooting to apply evaluation trial extension.' /d p:4:1 | Out-Null
}

function Register-EvaluationTrialTask {
    if (-not (Test-Path -LiteralPath $InstallPath)) {
        throw "Installed script not found at $InstallPath. Copy it before registering the task."
    }

    $taskName = $ScriptName
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$InstallPath`""

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $triggerBoot = New-ScheduledTaskTrigger -AtStartup
    $triggerBoot.Delay = 'PT5M'
    $triggerDaily = New-ScheduledTaskTrigger -Daily -At '03:00'
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(15))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($triggerBoot, $triggerDaily) `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    Write-TrialLog "Registered scheduled task '$taskName' (startup + daily at 03:00)."
}

function Install-EvaluationTrialExtension {
    $sourcePath = $MyInvocation.MyCommand.Path
    if (-not $sourcePath) {
        throw 'Unable to determine the path of this script.'
    }

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $InstallPath -Force
    Write-TrialLog "Installed trial extension script to $InstallPath."

    Register-EvaluationTrialTask
}

function Invoke-EvaluationTrialCheck {
    $previousState = Get-TrialState
    if ($previousState.rearmPendingReboot -eq $true) {
        $lastRearm = $null
        if ($previousState.lastRearmAt) {
            $lastRearm = [datetime]$previousState.lastRearmAt
        }

        if ($lastRearm -and ((Get-Date) - $lastRearm).TotalHours -lt 24) {
            Write-TrialLog 'Previous rearm is pending reboot; skipping duplicate rearm attempt.'
            return
        }
    }

    $now = (Get-Date).ToString('o')
    $state = @{
        lastCheckedAt = $now
        lastDaysRemaining = $null
        lastRearmRemaining = $null
        lastAction = 'none'
        rearmPendingReboot = $false
    }

    $status = Get-EvaluationTrialStatus

    if (-not $status.IsEvaluation) {
        Write-TrialLog 'Not an evaluation edition; trial extension is not applicable.'
        $state.lastAction = 'skipped-not-evaluation'
        Save-TrialState -State $state
        return
    }

    $daysText = if ($null -eq $status.DaysRemaining) { 'unknown' } else { "$($status.DaysRemaining)" }
    $rearmText = if ($null -eq $status.RearmRemaining) { 'unknown' } else { "$($status.RearmRemaining)" }

    Write-TrialLog "Evaluation license detected. Days remaining: $daysText. Rearms remaining: $rearmText."

    $state.lastDaysRemaining = $status.DaysRemaining
    $state.lastRearmRemaining = $status.RearmRemaining

    if ($null -ne $status.RearmRemaining -and $status.RearmRemaining -le 0) {
        Write-TrialLog 'No rearms remain. Convert to a licensed edition or rebuild the VM.' -EntryType Warning
        $state.lastAction = 'exhausted'
        Save-TrialState -State $state
        return
    }

    if ($null -eq $status.DaysRemaining) {
        Write-TrialLog 'Could not determine remaining trial days; skipping rearm.' -EntryType Warning
        $state.lastAction = 'skipped-unknown-days'
        Save-TrialState -State $state
        return
    }

    $shouldRearm = $Force -or ($status.DaysRemaining -le $ThresholdDays)

    if (-not $shouldRearm) {
        Write-TrialLog "Trial healthy ($($status.DaysRemaining) days left). Rearm deferred until <= $ThresholdDays days."
        $state.lastAction = 'deferred'
        Save-TrialState -State $state
        return
    }

    Invoke-EvaluationRearm
    $state.lastAction = 'rearm-initiated'
    $state.rearmPendingReboot = $true
    $state.lastRearmAt = $now
    Save-TrialState -State $state
}

# Ensure elevated execution for slmgr and scheduled task registration.
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator privileges are required.'
}

if ($Install) {
    Install-EvaluationTrialExtension
}

Invoke-EvaluationTrialCheck
