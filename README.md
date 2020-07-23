# Migrate DNS records from Edgecast to Azure DNS

Basic PowerShell script that automates migrating your DNS zones from Edgecast DNS to Azure DNS.

## Usage example

```powershell
$edgecastCustomerId = Read-Host -Prompt "CustomerId"
$edgecastToken = Read-Host -Prompt "Edgecast token"
$azureSubscriptionId = Read-Host -Prompt "Azure Subscription Id"
$azureResourceGroupName = Read-Host -Prompt "Resource Group"

.\MigrateZones.ps1 -EdgeCastCustomerId $edgecastcustid `
    -EdgeCastToken $edgecasttoken `
    -AzureSubscriptionId $azureSubscriptionId `
    -AzureResourceGroupName $azureResourceGroupName `
    -KillAndFill `
    -ZoneNames "fakezone.com"
```

![demo](demo.mp4)

## Requirements

* [PowerShell 7+](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell?view=powershell-7)
* [Az module](https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az?view=azps-4.4.0)
* [Edgecast token](https://my.edgecast.com/settings/default.aspx)
