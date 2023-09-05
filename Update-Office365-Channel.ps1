#Simple Office365 Channel Change Script
#James Vincent - Sept 2023

#Monthly Enterprise Channel
$MonthlyEnt = @{URL="http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6"; DisplayName="Monthly Enterprise Channel"}

#Current Channel 
$Current = @{URL="http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60"; DisplayName="Current Channel"}

#Current Channel (Preview)
$Preview = @{URL="http://officecdn.microsoft.com/pr/64256afe-f5d9-4f86-8936-8840a6a4f5be"; DisplayName="Current Channel (Preview)"}

#Semi-Annual Enterprise Channel
$SemiAnnual = @{URL="http://officecdn.microsoft.com/pr/7ffbc6bf-bc32-4f92-8982-f9dd17fd3114"; DisplayName="Semi Annual Channel"}

#Semi-Annual Enterprise Channel (Preview)
$SemiAnnualEnt = @{URL="http://officecdn.microsoft.com/pr/b8f9b850-328d-4355-9145-c59439a0c4cf"; DisplayName="Semi Annual Enterprise Channel"}

#Beta Channel
$Beta = @{URL="http://officecdn.microsoft.com/pr/5440fd1f-7ecb-4221-8110-145efaa6372f"; DisplayName="BETA Channel"}

$UpdateChannel = $Current
$CTRPath = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
$CDNBaseUrl = Get-ItemProperty -Path $CTRPath -Name "CDNBaseUrl" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "CDNBaseUrl"
if ($CDNBaseUrl -ne $null) {
    if ($CDNBaseUrl -notmatch $UpdateChannel.URL) {
        # Set new update channel
        Set-ItemProperty -Path $CTRPath -Name "CDNBaseUrl" -Value $UpdateChannel.URL -Force  
		if($?){
            write-output CDNBaseUrl has been changed to $UpdateChannel.DisplayName
            write-output Office will now initiate an background update for changes to take effect.
            #Start-Process -FilePath "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe" -ArgumentList "/frequentupdate SCHEDULEDTASK displaylevel=Full" 
            Start-Process -FilePath "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe" -ArgumentList "/update user displaylevel=Full forceappshutdown=false" 
        }
		else {write-output CDNBaseUrl has not been changed and Office remains on $UpdateChannel.DisplayName}
    } else {write-host The existing Update Channel on the device is the same as specified $UpdateChannel.DisplayName and was not changed.}
} else {write-host "The CDNBaseUrl reg key was not found within the Registry, therefore no changes were made"}

