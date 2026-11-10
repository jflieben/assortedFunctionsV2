# M365Permissions

M365Permissions runs in your own Azure subscription and shows who can reach what in Microsoft 365, Entra ID and Azure.
See [m365permissions.com](https://www.m365permissions.com).

The usual way to install it is the [Azure Marketplace](https://portal.azure.com/#create/liebenconsultancy.m365permissionsstandardv2).

## Install with tags on the resource group

The Marketplace form cannot tag the managed application. Its managed resource group takes its tags from the
application, so a policy that requires tags on resource groups refuses that install. This template creates the same
Marketplace application, with your tags on it:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Frefs%2Fheads%2Fmain%2FM365PermissionsCloud%2Fui.json)

1. Create the resource group for the application first, with the tags your policies require, and choose it on Basics.
2. On the Tags step, choose **Managed application** as the resource and add the required tags. The managed resource
   group gets them too. Tag the other resources there as well if your policies require that.
3. The rest is the same as the Marketplace install: a few minutes after the deployment you get a mail with a page that
   follows the installation, and the instance shows the setup command a Global Administrator runs.

Billing, updates and support are the same as with the Marketplace install.

Requirements: Owner of the subscription; a Global Administrator for the setup command.

## Version 1

Version 1 files (`authorize.ps1`, `permissions-lib.ps1`, `permissions.json`) stay here for existing installs.

To authorize version 1 by hand instead of with the multi-tenant app:

1. Install the Marketplace package and wait for the **second** welcome mail, which asks for authorization.
2. Open Azure Cloud Shell as a Global Administrator.
3. Download [`authorize.ps1`](https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/refs/heads/main/M365PermissionsCloud/authorize.ps1).
4. Optionally replace `xxxxx-xxxxxx-xxxxx-xxxxx-xxxxx` in the script with your Azure subscription id.
5. Paste the script into Cloud Shell and follow the instructions it prints.
