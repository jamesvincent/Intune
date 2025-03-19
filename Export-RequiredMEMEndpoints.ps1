# Creates a Table of the information provided at https://learn.microsoft.com/en-us/mem/intune-service/fundamentals/intune-endpoints
# Gives you a bit more detail than the one liner Microsoft supply
# James Vincent - March 2025

$Data = Invoke-RestMethod -Uri ("https://endpoints.office.com/endpoints/WorldWide?ServiceAreas=MEM`&clientrequestid=" + ([GUID]::NewGuid()).Guid)

$FilteredData = $Data | Where-Object { $_.ServiceArea -eq "MEM" -and $_.urls -and $_.Required -eq "true" }

$FormattedData = foreach ($entry in $FilteredData) {
    foreach ($url in $entry.urls) {
        [PSCustomObject]@{
            id   = $entry.id
            ServiceArea   = $entry.ServiceArea
            TCPPorts      = ($entry.TCPPorts -join ", ")
            UDPPorts      = ($entry.UDPPorts -join ", ")
            URLs          = $url
        }
    }
}

$FormattedData | Export-Csv -Path .\MicrosoftMEM_RequiredEndpoints.csv -NoTypeInformation
