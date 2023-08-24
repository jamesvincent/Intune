#Config Variables
$SiteURL = "https://domain.sharepoint.com/sites/MigrationData"
$SourceLibraryURL = "Shared Documents/General/Docs/Clients" #Site Relative URL from the current site
$TargetLibraryURL = "/sites/Organisation/Shared Documents/General/AS/Clients" #Server Relative URL of the Target Folder
 
#Connect to PnP Online
Connect-PnPOnline -Url $SiteURL -Interactive
 
#Get all Items from the Document Library
$Items = Get-PnPFolderItem -FolderSiteRelativeUrl $SourceLibraryURL 
 
#Move All Files and Folders Between Document Libraries
Foreach($Item in $Items)
{
    Move-PnPFile -SourceUrl $Item.ServerRelativeUrl -TargetUrl $TargetLibraryURL -AllowSchemaMismatch -Force -AllowSmallerVersionLimitOnDestination
    Write-host "Moved Item:"$Item.ServerRelativeUrl
}