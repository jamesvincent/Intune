#Set Parameters
$ErrorActionPreference = "Stop"
$AdminSiteURL="https://domain-admin.sharepoint.com"
$SiteCollAdmin = "user@domain.org"
$TimezoneName = "(UTC+01:00) Amsterdam, Berlin, Berne, Rome, Stockholm, Vienne"
$PrimaryLocale = "1033"

#Connect to PnP Online to the Tenant Admin Site
Connect-PnPOnline -Url $AdminSiteURL -Interactive

#Get All OneDrive for Business Sites
$OneDriveSites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'"

Try {
#Loop through each site
        ForEach($Site in $OneDriveSites)
        { 
            Write-Host -f Yellow "Processing Site: "$Site.URL
            
            #Add Site collection Admin user permission
            Set-PnPTenantSite -Url $Site.URL -Owners $SiteCollAdmin

            #Connect to OneDrive for Business Sites for each user in scope
            Connect-PnPOnline $Site.URL -Interactive

            #Get the Web
            $web = Get-PnPWeb -Includes RegionalSettings.LocaleId, RegionalSettings.TimeZones, SupportedUILanguageIds

            #Update the Region
            #Get the Locale ID
            $CurrentLocaleId = $Web.RegionalSettings.LocaleId
            #$Web.RegionalSettings.LocaleId

            If($CurrentLocaleId -ne $Null)
            {
                #Update Locale of the site
                $Web.RegionalSettings.LocaleId = $PrimaryLocale
                $Web.Update()
                Invoke-PnPQuery
                Write-host "`tLocale has been updated to $PrimaryLocale." -ForegroundColor Green
            } else {
                Write-host "Locale not found - no action taken!" -ForegroundColor Red
            }    

            #Update the Timezone
            #Get the time zone
            $Timezone = $Web.RegionalSettings.TimeZones | Where {$_.Description -eq $TimezoneName}
            
            If($Timezone -ne $Null)
            {
                #Update time zone of the site
                $Web.RegionalSettings.TimeZone = $Timezone
                $Web.Update()
                Invoke-PnPQuery
                Write-host "Timezone Updated Successfully!" -ForegroundColor Green
            } else {
                Write-host "Timezone $TimezoneName not found - no action taken!" -ForegroundColor Yellow
            }

            #Update the Supported Site Languages
            #Get the current Languages
            $CurrentLanguages = $Web.SupportedUILanguageIds
            
            If($CurrentLanguages -ne $Null)
            {
                #Update supported languages
                $Web.AddSupportedUILanguage(1036)
                $Web.AddSupportedUILanguage(1031)
                $Web.AddSupportedUILanguage(1025)
                $Web.AddSupportedUILanguage(1026)
                $Web.AddSupportedUILanguage(1027)
                $Web.AddSupportedUILanguage(1028)
                $Web.AddSupportedUILanguage(1029)
                $Web.AddSupportedUILanguage(1030)
                $Web.AddSupportedUILanguage(1032)
                $Web.AddSupportedUILanguage(1033)
                $Web.AddSupportedUILanguage(1035)
                $Web.AddSupportedUILanguage(1037)
                $Web.AddSupportedUILanguage(1038)
                $Web.AddSupportedUILanguage(1040)
                $Web.AddSupportedUILanguage(1055)
                $Web.AddSupportedUILanguage(1054)
                $Web.AddSupportedUILanguage(1053)
                $Web.AddSupportedUILanguage(1051)
                $Web.AddSupportedUILanguage(1050)
                $Web.AddSupportedUILanguage(1049)
                $Web.AddSupportedUILanguage(1048)
                $Web.AddSupportedUILanguage(1046)
                $Web.AddSupportedUILanguage(1045)
                $Web.AddSupportedUILanguage(1044)
                $Web.AddSupportedUILanguage(1043)
                $Web.AddSupportedUILanguage(1042)
                $Web.AddSupportedUILanguage(1041)
                $Web.AddSupportedUILanguage(1057)
                $Web.AddSupportedUILanguage(1058)
                $Web.AddSupportedUILanguage(1060)
                $Web.AddSupportedUILanguage(1061)
                $Web.AddSupportedUILanguage(1062)
                $Web.AddSupportedUILanguage(1063)
                $Web.AddSupportedUILanguage(1066)
                $Web.AddSupportedUILanguage(1068)
                $Web.AddSupportedUILanguage(1069)
                $Web.AddSupportedUILanguage(1071)
                $Web.AddSupportedUILanguage(1081)
                $Web.AddSupportedUILanguage(1086)
                $Web.AddSupportedUILanguage(1087)
                $Web.AddSupportedUILanguage(10266)
                $Web.AddSupportedUILanguage(9242)
                $Web.AddSupportedUILanguage(5146)
                $Web.AddSupportedUILanguage(3082)
                $Web.AddSupportedUILanguage(2108)
                $Web.AddSupportedUILanguage(2070)
                $Web.AddSupportedUILanguage(2052)
                $Web.AddSupportedUILanguage(1164)
                $Web.AddSupportedUILanguage(1110)
                $Web.AddSupportedUILanguage(1106)
                $Web.Update()
                Invoke-PnPQuery
                Write-host "Supported User Interface languages added Successfully!" -ForegroundColor Green
            } else {
                Write-host "UI Languages not found - no action taken!" -ForegroundColor Yellow
            }

            #Remove Site collection Admin user permission
            Remove-PnPSiteCollectionAdmin -Owners $SiteCollAdmin
        }
    }
Catch {
    $_.Exception | Out-File Set-LocaleId-Logfile.log -Append
    Break
}