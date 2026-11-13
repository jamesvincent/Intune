#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$LogRoot="$env:ProgramData\WinREReadiness\Logs"
New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
$LogFile=Join-Path $LogRoot 'Remediation.log'
function Write-Log { param([string]$Message,[string]$Level='INFO'); Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue }
function Get-ReagentState {
    $o = & reagentc.exe /info 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "reagentc /info failed with exit code $LASTEXITCODE."
    }
    $t = $o -join "`n"
    $s=[regex]::Match($t,'Windows RE status[ \t]*:[ \t]*([^\r\n]*)$','IgnoreCase,Multiline')
    $l=[regex]::Match($t,'Windows RE location[ \t]*:[ \t]*([^\r\n]*)$','IgnoreCase,Multiline')
    [pscustomobject]@{Status=$(if($s.Success){$s.Groups[1].Value.Trim()}else{$null});Location=$(if($l.Success){$l.Groups[1].Value.Trim()}else{$null});Raw=$t}
}
function Test-Ready($State){ return ($State.Status -eq 'Enabled' -and -not [string]::IsNullOrWhiteSpace($State.Location)) }

Write-Log 'Starting controlled WinRE remediation.'
try {
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $release=[string]$cv.DisplayVersion
    $initial=Get-ReagentState
    Write-Log "Initial status=$($initial.Status); location=$($initial.Location)"

    if(Test-Ready $initial){
        Write-Output 'WinRE already enabled and registered. No registration remediation required. KB5079471 and disk-space findings remain detection/policy items.'
        exit 0
    }

    & reagentc.exe /enable 2>&1 | ForEach-Object { Write-Log "REAGENTC-ENABLE: $_" 'DEBUG' }
    Start-Sleep -Seconds 2
    $state=Get-ReagentState
    if(Test-Ready $state){
        Write-Log "WinRE enabled successfully at $($state.Location)" 'PASS'
        Write-Output "WinRE remediation succeeded: $($state.Location)"
        exit 0
    }

    $defaultDir=Join-Path $env:SystemRoot 'System32\Recovery'
    $defaultWim=Join-Path $defaultDir 'Winre.wim'
    if(-not (Test-Path -LiteralPath $defaultWim)){
        throw "Default Winre.wim is missing at $defaultWim. Partition/image repair is required."
    }
    & dism.exe /English /Get-WimInfo "/WimFile:$defaultWim" | Out-Null
    if($LASTEXITCODE -ne 0){ throw 'Default Winre.wim failed DISM validation.' }

    & reagentc.exe /setreimage /path $defaultDir /target $env:SystemRoot 2>&1 | ForEach-Object { Write-Log "REAGENTC-SETREIMAGE: $_" 'DEBUG' }
    if($LASTEXITCODE -ne 0){ throw "reagentc /setreimage failed with exit code $LASTEXITCODE." }
    & reagentc.exe /enable 2>&1 | ForEach-Object { Write-Log "REAGENTC-ENABLE2: $_" 'DEBUG' }
    Start-Sleep -Seconds 2
    $final=Get-ReagentState
    if(Test-Ready $final){
        Write-Log "WinRE registration remediation succeeded at $($final.Location)" 'PASS'
        Write-Output "WinRE remediation succeeded: $($final.Location)"
        exit 0
    }
    throw "WinRE remains unready. Status=$($final.Status); location=$($final.Location)."
}
catch {
    $message=$_.Exception.Message
    Write-Log $message 'FAIL'
    Write-Output "WinRE remediation requires manual action: $message The script intentionally does not resize partitions or install KB5079471. Deploy KB5079471/Safe OS servicing through an approved update package, then rerun detection."
    exit 1
}
