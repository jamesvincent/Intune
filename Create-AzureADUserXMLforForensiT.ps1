# Script used to generate the required .xml file for ForensiT User Profile Wizard migrations.
# James Vincent - September 2023

#Requires -PSEdition Desktop

# Check if AzureADPreview module is installed
if (-not (Get-Module -Name AzureADPreview -ListAvailable)) {
    # AzureADPreview module is missing, so check if the AzureAD module is installed
    if (-not (Get-Module -Name AzureAD -ListAvailable)) {
        # Neither AzureAD or AzureADPreview modules are present, ask which to install
        If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
        {
            Write-Warning "Administrator permissions are needed to install the AzureAD PowerShell module.`nPlease re-run this script as an Administrator."
            Exit
        } else {
        $isValidChoice = $false
        while (-not $isValidChoice) {        
            Write-Warning "The AzureAD or AzureADPreview modules are not installed but are required, please choose which to install."
            # Prompt the user for input
            Write-host "1: AzureAD Module"
            Write-host "2: AzureADPreview Module"
            $ModuleChoice = Read-Host "Type 1 or 2"

                # Use a switch statement to handle different choices
                switch ($ModuleChoice.ToUpper()) {
                    '1' {
                        # Install module A
                        #Install-Module -Name AzureAD -Force
                        Write-Host "The AzureAD module has been installed."
                        $isValidChoice = $true
                    }
                    '2' {
                        # Install module B
                        #Install-Module -Name AzureADPreview -Force
                        Write-Host "The AzureADPreview module has been installed."
                        $isValidChoice = $true
                    }
                    default {
                        # Invalid choice
                        Write-Host -F Red "Invalid choice. Please select 1 or 2."
                    }
                }
            }    
        }
    }
}

if (Get-Module -ListAvailable -Name AzureADPreview) {
    Write-Host "AzureADPreview module exists and will be imported"
    import-module AzureADPreview -ErrorAction Stop
} 
elseif (Get-Module -ListAvailable -Name AzureAD) {
    Write-Host "AzureADPreview module exists and will be imported"
    import-module AzureADPreview -ErrorAction Stop
} 
else {
    Write-Host "Neither AzureADPreview or AzureAD module exists, exiting"
    Exit 1
}

#Connect to Azure AD. This will show a prompt.
Write-Host "Connecting to Azure AD... Authenticate in the popup window."
Connect-AzureAD -ErrorAction Stop

#get the list of users that are in target for migration.

####################
#PERFORM EDITS HERE#
####################

# Define the Business Unit (BU)
$BU = read-host "Enter the BU reference, for example FDT, CUK, ESP"

# Change the UPN(s) to the required user scope, include all domains in scope of the Migration
$BU_UPN_Array = @(
'domain.com.pl',
'domain.pl',
'domain.com')

###################
#DO NOT EDIT BELOW#
###################

# Creates a CSV file based on the UPN in the above script to be imported
#$BU_UPN_File = $BU + '-ForensiTAzureID.csv'

# Creates a ForensitAzureID File which is used to map local users to Azure UPNs
$AzureIDFile = $BU + '-ForensiTAzureID.xml'

'Collecting data, this may take some time.'

# Collect specific user data
$azureADUsers = Get-AzureADUser -all:$true | Where-Object {$BU_UPN_Array -contains $_.UserPrincipalName.split("@")[1]} | Select-Object UserPrincipalName, ObjectId, DisplayName -ErrorAction Stop #| export-csv -path ("$((Get-Location).Path)\$BU_UPN_File") 

# Comment out the line above with # if you want to collect All Data, and remove the # from line 95 -- # $azureADUsers = Get-A....
# Collect All User data from the target tenant.
# $azureADUsers = Get-AzureADUser -all:$true 

'User file has been created - waiting 10 seconds before proceeding'

Start-Sleep -Seconds 10

# Get the tennant details
$Tenant = Get-AzureADTenantDetail

# Get the unformatted data from the temporary file
#$azureADUsers = import-csv ("$((Get-Location).Path)\$BU_UPN_File")

# Create the XML file
$xmlsettings = New-Object System.Xml.XmlWriterSettings
$xmlsettings.Indent = $true
$xmlsettings.IndentChars = "    "

$XmlWriter = [System.XML.XmlWriter]::Create("$((Get-Location).Path)\$AzureIDFile", $xmlsettings)

# Write the XML Declaration and set the XSL
$xmlWriter.WriteStartDocument()
$xmlWriter.WriteProcessingInstruction("xml-stylesheet", "type='text/xsl' href='style.xsl'")

# Start the Root Element 
$xmlWriter.WriteStartElement("ForensiTAzureID")

# Write the Azure AD domain details as attributes
$xmlWriter.WriteAttributeString("ObjectId", $($Tenant.ObjectId))
$xmlWriter.WriteAttributeString("Name", $($Tenant.VerifiedDomains.Name));
$xmlWriter.WriteAttributeString("DisplayName", $($Tenant.DisplayName));


#Parse the data
ForEach ($azureADUser in $azureADUsers){
  
    $xmlWriter.WriteStartElement("User")

        $xmlWriter.WriteElementString("UserPrincipalName",$($azureADUser.UserPrincipalName))
        $xmlWriter.WriteElementString("ObjectId",$($azureADUser.ObjectId))
        $xmlWriter.WriteElementString("DisplayName",$($azureADUser.DisplayName))

    $xmlWriter.WriteEndElement()
    }

$xmlWriter.WriteEndElement()

# Close the XML Document
$xmlWriter.WriteEndDocument()
$xmlWriter.Flush()
$xmlWriter.Close()


# Clean up

write-host "Azure user ID file created: $((Get-Location).Path)\$AzureIDFIle"
