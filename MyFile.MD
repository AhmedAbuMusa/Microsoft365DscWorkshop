Hi
Hi Again
admin@M365CPI39455860.onmicrosoft.com
^b426~bHASw]0al[gnuU[L2M711$$^PH

Get-InstalledModule Microsoft.Graph* | Uninstall-Module -AllVersions -Force


Uninstall-Module Microsoft.Graph.Authentication -AllVersions -Force


Uninstall-Module Microsoft.Graph -AllVersions -Force


Import-Module Microsoft.Graph.Auth*ntication -Force
Connect-MgGraph
`*



Connect-MgGraph -Scopes `
"DeviceManagementConfiguration.Read.All",
"DeviceManagementManagedDevices.Read.All"


Connect-MgGraph -Scopes `
"Directory.Read.All",
"Policy.Read.All",
"Application.Read.All",
"Agreement.Read.All",
"AdministrativeUnit.Read.All"



Update-M365DSCAzureAdApplication `
    -ApplicationName "Microsoft365DSC" `
    -AdminConsent `
    -Type Certificate


Update-M365DSCAzureAdApplication `
    -ApplicationName "Microsoft365DSC" `
    -Permissions @("All") `
    -AdminConsent `
    -Type Certificate


Get-Command Update-M365DSCAzureAdApplication -Syntax
