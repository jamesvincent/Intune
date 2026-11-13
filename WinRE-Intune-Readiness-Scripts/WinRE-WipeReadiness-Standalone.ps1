#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$LogDirectory = "$env:ProgramData\WinREReadiness\Logs",
    [switch]$StrictKB5079471
)

$ErrorActionPreference = 'Stop'
$ExpectedRecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$WinRERecommendedFreeMB = 250
$OSMinimumFreeGB = 10
$OSRecommendedFreeGB = 20
$OSWarningPercent = 10
$Results = [System.Collections.Generic.List[object]]::new()
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDirectory "WinRE_Readiness_$env:COMPUTERNAME`_$Timestamp.log"
$TempPartitionMount = $null
$TempImageMount = $null
$PartitionAccessAdded = $false
$ImageMounted = $false

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','PASS','WARN','FAIL','DEBUG')][string]$Level='INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}
function Add-Result {
    param([string]$Test,[ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,[string]$Value,[string]$Detail)
    $Results.Add([pscustomobject]@{Test=$Test;Status=$Status;Value=$Value;Detail=$Detail})
    Write-Log "$Test | $Value | $Detail" $Status
}
function Get-ReagentValue {
    param([string]$Text,[string]$Label)
    $m = [regex]::Match($Text,([regex]::Escape($Label)+'\s*:\s*(.*)$'),'IgnoreCase,Multiline')
    if($m.Success){ return $m.Groups[1].Value.Trim() }
    return $null
}
function Invoke-Cleanup {
    if($script:ImageMounted -and $script:TempImageMount){
        & dism.exe /Unmount-Image "/MountDir:$script:TempImageMount" /Discard | Out-Null
        $script:ImageMounted=$false
    }
    if($script:TempImageMount -and (Test-Path -LiteralPath $script:TempImageMount)){
        Remove-Item -LiteralPath $script:TempImageMount -Recurse -Force -ErrorAction SilentlyContinue
    }
    if($script:PartitionAccessAdded -and $script:TempPartitionMount -and $script:RecoveryPartition){
        Remove-PartitionAccessPath -DiskNumber $script:RecoveryPartition.DiskNumber -PartitionNumber $script:RecoveryPartition.PartitionNumber -AccessPath $script:TempPartitionMount -ErrorAction SilentlyContinue
        $script:PartitionAccessAdded=$false
    }
    if($script:TempPartitionMount -and (Test-Path -LiteralPath $script:TempPartitionMount)){
        Remove-Item -LiteralPath $script:TempPartitionMount -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Log 'Starting standalone WinRE and Intune Remote Wipe readiness assessment.'
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $DisplayVersion = [string]$cv.DisplayVersion
    $FullBuild = "$($os.BuildNumber).$($cv.UBR)"
    Add-Result 'OperatingSystem' 'INFO' "$($os.Caption); $DisplayVersion; build $FullBuild" 'Detected Windows release and build.'

    $reagentOutput = & reagentc.exe /info 2>&1
    $reagentText = $reagentOutput -join "`n"
    $reagentOutput | ForEach-Object { Write-Log "REAGENTC: $_" 'DEBUG' }
    $WinREStatus = Get-ReagentValue $reagentText 'Windows RE status'
    $WinRELocation = Get-ReagentValue $reagentText 'Windows RE location'
    $ReagentBcd = Get-ReagentValue $reagentText 'Boot Configuration Data (BCD) identifier'
    Add-Result 'WinREStatus' $(if($WinREStatus -eq 'Enabled'){'PASS'}else{'FAIL'}) $WinREStatus 'Windows RE must be enabled for Remote Wipe.'
    Add-Result 'WinRELocation' $(if($WinRELocation){'PASS'}else{'FAIL'}) $(if($WinRELocation){$WinRELocation}else{'Not registered'}) 'Registered WinRE location.'

    $locationMatch = [regex]::Match([string]$WinRELocation,'harddisk(\d+)\\partition(\d+)','IgnoreCase')
    if($locationMatch.Success){
        $RecoveryPartition = Get-Partition -DiskNumber ([int]$locationMatch.Groups[1].Value) -PartitionNumber ([int]$locationMatch.Groups[2].Value)
        $script:RecoveryPartition = $RecoveryPartition
        Add-Result 'WinREPartition' 'PASS' "Disk $($RecoveryPartition.DiskNumber), partition $($RecoveryPartition.PartitionNumber)" 'Registered partition exists.'
    } else {
        Add-Result 'WinREPartition' 'FAIL' 'Unable to map' 'Registered location could not be mapped to a physical partition.'
    }

    $osVolume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
    $osFreeGB = [math]::Round($osVolume.SizeRemaining/1GB,2)
    $osTotalGB = [math]::Round($osVolume.Size/1GB,2)
    $osPct = [math]::Round(($osVolume.SizeRemaining/$osVolume.Size)*100,1)
    $osSpaceStatus = if($osFreeGB -lt $OSMinimumFreeGB){'FAIL'}elseif($osFreeGB -lt $OSRecommendedFreeGB -or $osPct -lt $OSWarningPercent){'WARN'}else{'PASS'}
    Add-Result 'OSVolumeFreeSpace' $osSpaceStatus "$osFreeGB GB free of $osTotalGB GB ($osPct%)" "Operational guardrails: fail below $OSMinimumFreeGB GB; warn below $OSRecommendedFreeGB GB or $OSWarningPercent percent."

    if($RecoveryPartition){
        $osPartition = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
        $same = ($osPartition.DiskNumber -eq $RecoveryPartition.DiskNumber -and $osPartition.PartitionNumber -eq $RecoveryPartition.PartitionNumber)
        Add-Result 'WinRESeparateFromOS' $(if($same){'FAIL'}else{'PASS'}) $(if($same){'Same partition'}else{'Separate partition'}) 'WinRE should use a dedicated recovery partition.'
        if($same){
            Add-Result 'WinREPartitionOrder' 'INFO' 'Same partition' 'See WinRESeparateFromOS for the failure.'
        } elseif($RecoveryPartition.DiskNumber -ne $osPartition.DiskNumber){
            Add-Result 'WinREPartitionOrder' 'INFO' 'Different disks' 'Partition order applies only when WinRE and Windows are on the same disk.'
        } elseif($RecoveryPartition.Offset -lt $osPartition.Offset){
            Add-Result 'WinREPartitionOrder' 'PASS' 'Before Windows (layout advisory)' 'The recovery partition may be harder to extend. See WinREPartitionFreeSpace for servicing headroom.'
        } else {
            Add-Result 'WinREPartitionOrder' 'PASS' 'After Windows (preferred order)' 'Partition offsets show that WinRE follows the Windows partition.'
        }
        if($RecoveryPartition.GptType){
            Add-Result 'RecoveryPartitionType' $(if($RecoveryPartition.GptType.ToString().ToLowerInvariant() -eq $ExpectedRecoveryGptType){'PASS'}else{'WARN'}) $RecoveryPartition.GptType 'Expected Windows Recovery GPT type.'
        }
        $totalMB=[math]::Round($RecoveryPartition.Size/1MB,0)
        Add-Result 'RecoveryPartitionCapacity' $(if($totalMB -lt 500){'WARN'}else{'PASS'}) "$totalMB MB total" 'Total capacity is advisory; free space is tested separately.'

        $existing = @($RecoveryPartition.AccessPaths | Where-Object { $_ }) | Select-Object -First 1
        if($existing){ $RecoveryRoot=$existing } else {
            $TempPartitionMount = Join-Path $env:ProgramData "WinREReadiness\Mount_$PID"
            New-Item -Path $TempPartitionMount -ItemType Directory -Force | Out-Null
            Add-PartitionAccessPath -DiskNumber $RecoveryPartition.DiskNumber -PartitionNumber $RecoveryPartition.PartitionNumber -AccessPath $TempPartitionMount
            $PartitionAccessAdded=$true
            $RecoveryRoot=$TempPartitionMount
        }
        $recoveryVolume = $RecoveryPartition | Get-Volume
        $freeMB=[math]::Round($recoveryVolume.SizeRemaining/1MB,0)
        $volMB=[math]::Round($recoveryVolume.Size/1MB,0)
        $reSpaceStatus = if($recoveryVolume.SizeRemaining -lt ($WinRERecommendedFreeMB * 1MB)){'INFO'}else{'PASS'}
        $spaceDetail = if($reSpaceStatus -eq 'INFO'){
            "Servicing advisory: below $WinRERecommendedFreeMB MB free for WinRE updates."
        } else {
            "Meets the $WinRERecommendedFreeMB MB WinRE servicing target."
        }
        Add-Result 'WinREPartitionFreeSpace' $reSpaceStatus "$freeMB MB free of $volMB MB" $spaceDetail

        $WinREWim = Join-Path $RecoveryRoot 'Recovery\WindowsRE\Winre.wim'
        if(Test-Path -LiteralPath $WinREWim){
            $wimItem=Get-Item -LiteralPath $WinREWim -Force
            Add-Result 'WinREImage' 'PASS' "$([math]::Round($wimItem.Length/1MB,0)) MB" 'Winre.wim exists at the registered location.'
            & dism.exe /English /Get-WimInfo "/WimFile:$WinREWim" | Out-Null
            Add-Result 'WinREImageReadability' $(if($LASTEXITCODE -eq 0){'PASS'}else{'FAIL'}) "DISM exit $LASTEXITCODE" 'DISM image inspection.'

            if($DisplayVersion -in @('24H2','25H2')){
                $TempImageMount = Join-Path $env:ProgramData "WinREReadiness\Image_$PID"
                New-Item -Path $TempImageMount -ItemType Directory -Force | Out-Null
                & dism.exe /Mount-Image "/ImageFile:$WinREWim" /Index:1 "/MountDir:$TempImageMount" /ReadOnly | Out-Null
                if($LASTEXITCODE -eq 0){
                    $ImageMounted=$true
                    $pkgOutput=& dism.exe "/Image:$TempImageMount" /Get-Packages /English 2>&1
                    $pkgText=$pkgOutput -join "`n"
                    $kbDetected=$pkgText -match '5079471'
                    $kbStatus=if($kbDetected){'PASS'}elseif($StrictKB5079471){'FAIL'}else{'WARN'}
                    Add-Result 'WinREUpdate-KB5079471' $kbStatus $(if($kbDetected){'Detected'}else{'Not detected'}) 'Exact package identity check inside WinRE. A later Safe OS update may supersede the KB and remove the literal identity; validate supersedence before treating absence as conclusive.'
                } else {
                    Add-Result 'WinREUpdate-KB5079471' $(if($StrictKB5079471){'FAIL'}else{'WARN'}) 'Unable to inspect' 'WinRE image could not be mounted read-only for package inspection.'
                }
            } else {
                Add-Result 'WinREUpdate-KB5079471' 'INFO' 'Not applicable' "Configured only for Windows 11 24H2 and 25H2; detected $DisplayVersion."
            }
        } else {
            Add-Result 'WinREImage' 'FAIL' 'Missing' 'Winre.wim was not found at the registered location.'
        }
    }

    $bcdOut=& bcdedit.exe /enum '{current}' 2>&1
    $bcdText=$bcdOut -join "`n"
    $seq=[regex]::Match($bcdText,'recoverysequence\s+(\{[0-9a-fA-F-]+\})','IgnoreCase')
    if($seq.Success){
        $RecoverySequence=$seq.Groups[1].Value
        & bcdedit.exe /enum $RecoverySequence | Out-Null
        Add-Result 'BCDRecoverySequence' $(if($LASTEXITCODE -eq 0){'PASS'}else{'FAIL'}) $RecoverySequence 'Active Windows loader recovery sequence.'
        if($ReagentBcd){ Add-Result 'REAgentCBCDConsistency' $(if($ReagentBcd.Trim('{','}') -eq $RecoverySequence.Trim('{','}')){'PASS'}else{'WARN'}) "REAgentC=$ReagentBcd; Loader=$RecoverySequence" 'REAgentC and active loader should reference the same recovery object.' }
    } else { Add-Result 'BCDRecoverySequence' 'FAIL' 'Missing' 'No recoverysequence entry in the active Windows loader.' }

    $dismHealth=& dism.exe /Online /Cleanup-Image /CheckHealth /English 2>&1
    $healthText=$dismHealth -join "`n"
    $healthStatus=if($healthText -match 'No component store corruption detected'){'PASS'}elseif($healthText -match 'cannot be repaired'){'FAIL'}else{'WARN'}
    Add-Result 'ComponentStoreHealth' $healthStatus $(if($healthStatus -eq 'PASS'){'Healthy'}else{'Review required'}) 'DISM /CheckHealth result.'

    try { $rw=Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_RemoteWipe' -ErrorAction Stop; Add-Result 'RemoteWipeCSP' 'PASS' 'Available' 'MDM RemoteWipe provider is exposed.' }
    catch { Add-Result 'RemoteWipeCSP' 'WARN' 'Unable to query' $_.Exception.Message }

    $pending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    Add-Result 'PendingReboot' $(if($pending){'WARN'}else{'PASS'}) $(if($pending){'Yes'}else{'No'}) 'Pending reboot should be cleared before destructive reset validation.'
}
catch {
    Add-Result 'UnhandledAssessmentError' 'FAIL' $_.Exception.GetType().FullName $_.Exception.Message
}
finally { Invoke-Cleanup }

$failures=@($Results|Where-Object Status -eq 'FAIL')
$warnings=@($Results|Where-Object Status -eq 'WARN')
$overall=if($failures.Count){'NOT READY'}elseif($warnings.Count){'READY WITH WARNING'}else{'READY'}
$Results | Format-Table Status,Test,Value,Detail -AutoSize
Write-Host "`nOverall: $overall"
Write-Host "Failures: $($failures.Count); Warnings: $($warnings.Count)"
Write-Host "Log: $LogFile"
Write-Log "OVERALL=$overall; Failures=$($failures.Count); Warnings=$($warnings.Count)" $(if($failures.Count){'FAIL'}elseif($warnings.Count){'WARN'}else{'PASS'})
exit $(if($failures.Count){2}elseif($warnings.Count){1}else{0})
