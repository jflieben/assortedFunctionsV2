# M365PermissionsCloud

Hardened Azure Native app that scans and reports Microsoft 365 permissions across SharePoint, OneDrive, Teams, Exchange, Azure, PowerBI, PowerPlatform, and Entra — deployed via ARM template or the Azure Marketplace with an Azure SQL backend.

![PowerShell 7.x](https://img.shields.io/badge/PowerShell-7.x-5391FE?logo=powershell&logoColor=white)
![Microsoft Azure](https://custom-icon-badges.demolab.com/badge/Microsoft%20Azure-0089D6?logo=msazure&logoColor=white)
![ARM Templates](https://img.shields.io/badge/Deployment-ARM%20Templates-5C2D91)

[![Deploy M365Permissions to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fui.json)

## What is it?
- Retrieves all permissions for all entities in your M365/Azure environment (Users, Groups, Service Principals, Foreign Principals)
- Analyses these permissions for you and reports on multiple dimensions (e.g. oversharing, inactive sharing, etc etc)
- Direct SQL access for your own reporting
- SIEM/SOAR integrations
- Change / Drift detection and alerting
- Responsive GUI for permission delving/analysis
- More info, see [M365Permissions.com website](https://www.m365permissions.com)

## Quick start
- One‑click deploy: use the `Deploy to Azure` button above.
- Follow the wizard

## Requirements
- Azure Subscription where you have Owner rights
- Global Administrator (only temporarily during activation)

## 🔐 Manual authorization
If you cannot or do not want to use the one-time multi-tenant app for permissions setup, you can set permissions manually as follows:

1. Install the marketplace package, wait for the **second** welcome email that asks you to authorize M365Permissions
1. Open Azure cloud shell using your global administrator account
1. Copy our onboarding script [`authorize.ps1`](https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/refs/heads/main/M365PermissionsCloud/authorize.ps1)
1. Replace "xxxxx-xxxxxx-xxxxx-xxxxx-xxxxx" with your Azure Subscription ID
1. Paste the script into Azure Cloud shell
1. Follow the final instruction printed onscreen
1. Happy CISO / ISO / CIO / etc 🛡️ 

## Architecture
[View architecture doc / diagrams](ARCHITECTURE.md)