# M365PermissionsCloud

Hardened Azure Native app that scans and reports Microsoft 365 permissions across SharePoint, OneDrive, Teams, Exchange, Azure, PowerBI, PowerPlatform, and Entra.

It is deployed via ARM template or the Azure Marketplace and is backed by Azure SQL.

![PowerShell 7.x](https://img.shields.io/badge/PowerShell-7.x-5391FE?logo=powershell&logoColor=white)
![Microsoft Azure](https://custom-icon-badges.demolab.com/badge/Microsoft%20Azure-0089D6?logo=msazure&logoColor=white)
![ARM Templates](https://img.shields.io/badge/Deployment-ARM%20Templates-5C2D91)

[![Deploy M365Permissions to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fui.json)

## Features
*   **Comprehensive Inventory**: Retrieves all permissions for all entities in your M365/Azure environment (Users, Groups, Service Principals, Foreign Principals).
*   **Automated Analysis**: Reports on multiple dimensions including oversharing and inactive sharing.
*   **Direct Access**: Full SQL access for custom reporting.
*   **Integration Ready**: Built-in support for SIEM/SOAR integrations.
*   **Drift Detection**: Automated change tracking and alerting.
*   **Intuitive Interface**: Responsive GUI for permission delving/analysis.
*   For more information, visit [M365Permissions.com](https://www.m365permissions.com).

## Quick Start
1.  Click the **Deploy to Azure** button above.
2.  Follow the deployment wizard.

## Requirements
*   Azure Subscription with **Owner** rights.
*   **Global Administrator** role (required only temporarily during activation).

## 🔐 Manual Authorization
If you prefer not to use the automated multi-tenant app for setup, follow these steps to authorize M365Permissions manually:

1.  Install the marketplace package and wait for the **second** welcome email requesting authorization.
2.  Open **Azure Cloud Shell** with your Global Administrator account.
3.  Download or copy the onboarding script: [`authorize.ps1`](https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/refs/heads/main/M365PermissionsCloud/authorize.ps1).
4.  Edit the script to replace `xxxxx-xxxxxx-xxxxx-xxxxx-xxxxx` with your **Azure Subscription ID** (optional but recommended).
5.  Paste the modified script into the Azure Cloud Shell.
6.  Follow the final on-screen instructions.
7.  Improve your security posture! 🛡️

## Architecture
See [Architecture Documentation](ARCHITECTURE.md).