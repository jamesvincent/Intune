#Set Parameters
$AdminSiteURL="https://domain-admin.sharepoint.com"
$SiteCollAdmin = "admin.vincent@hello.domain"
$DELocale = "1031"
$TimezoneName = "(UTC+01:00) Amsterdam, Berlin, Berne, Rome, Stockholm, Vienne"
   
#Connect to PnP Online to the Tenant Admin Site
Connect-PnPOnline -Url $AdminSiteURL -Interactive

#Get All OneDrive for Business Sites
$OneDriveSites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '_domain_com'" | Where-Object {$_.LocaleID -ne $DELocale} 

Try {
    $ErrorActionPreference = "Continue"
        #Loop through each site
        ForEach($Site in $OneDriveSites)
        { 
            $ErrorActionPreference = "Continue"

            Write-Host -f Yellow Processing Site: $Site.URL
            Write-Host -f Gray "##########################################################"
            Write-Host -f Gray "##########################################################"

            #Add Site collection Admin user permission
            Write-Host -f Yellow Adding $SiteCollAdmin to $Site.URL
            Set-PnPTenantSite -Url $Site.URL -Owners $SiteCollAdmin

            #Connect to OneDrive for Business Sites for each user in scope
            Write-Host -f Yellow Connecting to $Site.URL
            Connect-PnPOnline $Site.URL -Interactive
        
            #Get the Web
            Write-Host -f Gray "##########################################################"
            Write-Host -f Yellow "Acquiring current settings..."
            Write-Host -f Gray "##########################################################"
            $web = Get-PnPWeb -Includes RegionalSettings.LocaleId, RegionalSettings.TimeZones, SupportedUILanguageIds

            $CurrentLocaleId = $Web.RegionalSettings.LocaleId
            $Timezone = $Web.RegionalSettings.TimeZones | Where-Object {$_.Description -eq $TimezoneName}
            $CurrentLanguages = $Web.SupportedUILanguageIds

            #Update the Region
            #Get the Locale ID
            Write-Host -f Gray "##########################################################"
            Write-Host -f Yellow "Current LocaleId ="$Web.RegionalSettings.LocaleId
            Write-Host -f Yellow "Current Timezone ="$Web.RegionalSettings.TimeZone.Description
            Write-Host -f Yellow "Current Supported Languages ="$Web.SupportedUILanguageIds
            Write-Host -f Gray "##########################################################"

            If($CurrentLocaleId -ne $DELocale -Or $Null -ne $Timezone -Or $CurrentLanguages -notcontains $DELocale)
            {
            Write-Host -f Gray "##########################################################"
            Write-Host -f Yellow "Modifying user settings, this may take time to apply."
            Write-Host -f Gray "##########################################################"
            }
        
            If($CurrentLocaleId -ne $DELocale)
            {
                #Update Locale of the site
                $Web.RegionalSettings.LocaleId = $DELocale
                $Web.Update()
                Invoke-PnPQuery
                Write-host -f Green Locale has been updated to $DELocale
            } else {
                Write-host -f Magenta Locale already defined as $DELocale. No action taken!
            }    

            #Update the Timezone
            #Get the time zone
            
            If($Null -ne $Timezone)
            {
                #Update time zone of the site
                $Web.RegionalSettings.TimeZone = $Timezone
                $Web.Update()
                Invoke-PnPQuery
                Write-host -f Green Timezone Updated to $TimezoneName
            } else {
                Write-host -f Magenta Timezone $TimezoneName not found!
            }

            #Update the Supported Site Languages
            #Get the current Languages
            If($CurrentLanguages -contains $DELocale)
            {
                Write-host -f Magenta $DELocale is already supported, no changes required. No action taken!
            } else {
                Write-Host -f Green Adding support for additional languages
                Start-Sleep -s 10
                #Update supported languages
                $Web.IsMultilingual = $True
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
                $Web.Update()
                Invoke-PnPQuery
                Start-Sleep -s 1
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
                $Web.Update()
                Invoke-PnPQuery
                Start-Sleep -s 1
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
                $Web.Update()
                Start-Sleep -s 8
                Invoke-PnPQuery
                #Start-Sleep -s 15
                Write-host -f Green Additional language support added Successfully!
            }

            #Remove Site collection Admin user permission
            Write-Host -f Gray "##########################################################"
            Write-Host -f Yellow Removing $SiteCollAdmin from $Site.URL
            Remove-PnPSiteCollectionAdmin -Owners $SiteCollAdmin
            Write-Host -f Gray "##########################################################"
            Write-Host -f Gray "##########################################################"
            Write-Host -f Green "User Modification Complete"
            Write-Host -f Gray "##########################################################"
        }
    }
Catch {
    $_.Exception | Out-File Set-LocaleId-Logfile.log -Append
    #Break
}
