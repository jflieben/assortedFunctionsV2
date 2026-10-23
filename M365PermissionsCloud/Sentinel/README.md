# M365Permissions to Microsoft Sentinel

One click sets up the supported way for M365Permissions to send permission changes to your Log Analytics
workspace. Pick your workspace, select Create, done. Nothing has to be entered in the M365Permissions
portal afterwards.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Fmain%2FM365PermissionsCloud%2FSentinel%2FmainTemplate.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fjflieben%2FassortedFunctionsV2%2Fmain%2FM365PermissionsCloud%2FSentinel%2FuiFormDefinition.json)

The form asks for one thing: which Log Analytics workspace to write to. Your scan nodes are found for
you, from the `M365PNodeType` tag Azure put on them, so there is nothing to look up or paste.

## Why this replaces the workspace key

The workspace id and key route uses the HTTP Data Collector API. Support for that API ended on
14 September 2026, it cannot deliver to a workspace behind private link, and because the key is a
password for the whole workspace it has to be stored encrypted and rotated by hand.

This route uses the Logs ingestion API instead, which authenticates the scanner's own managed identity
against a data collection rule in your subscription. There is no secret anywhere, the access is visible
and revocable in Azure, and it is scoped to one rule that can write to one table.

The key route keeps working until a rule exists, and is never used again once one does. You can leave
the workspace key in the M365Permissions portal as a fallback, or clear it.

## What it creates

All of it next to your workspace, in the workspace's own resource group and region:

| what | why |
| --- | --- |
| table `M365PermissionsDelta_CL` | one column per field the scanner sends |
| data collection rule `dcr-m365permissions-delta` | routes the incoming stream into that table, and carries its own ingestion endpoint |
| role `Monitoring Metrics Publisher` on that rule, per scan node | lets the scanner post, and nothing else |
| role `Reader` on that rule, per scan node | lets the scanner read the rule's endpoint and immutable id, which is how it knows where to post |

Both role assignments are scoped to the rule itself, so the scanner can see that one rule and nothing
else in your subscription. The resource group you pick in the deployment form only holds the deployment
record.

The rule name and the table name can be changed under Names in the form. The rule is tagged
`M365PermissionsSentinel`, which is what the scanner looks for, so names are yours to choose.

No data collection endpoint is created. The rule is `kind: Direct`, which gives it an ingestion endpoint
of its own. A workspace behind private link does still need a data collection endpoint, which this does
not set up yet.

## What you need

In the subscription that holds the workspace:

| to | role that grants it |
| --- | --- |
| create the data collection rule | Monitoring Contributor |
| create the table | Log Analytics Contributor on the workspace |
| assign the two roles on the rule | Owner, or User Access Administrator |

Owner on the workspace's resource group covers all three. The scanner needs nothing from you: it already
has the managed identity the roles are assigned to.

## After it runs

The scanner looks for the rule on every queue run, so within ten minutes it finds it, records it, and
turns the Sentinel integration on by itself. From then on it sends a record for every permission added,
changed or removed, as soon as the first full scan of the tenant has completed.

Check that it arrived:

```kusto
M365PermissionsDelta_CL
| sort by TimeGenerated desc
| take 50
```

The portal's Configure SIEM/SOAR screen still asks for a workspace id and key, because it does not know
about rules yet. Leave it empty. It will show the integration as enabled once the scanner has found the
rule.

## The data

One record per change. `logType` is `permissionAdded`, `permissionModified` or `permissionDeleted`.

| column | what it holds |
| --- | --- |
| `TimeGenerated` | when the change reached the workspace |
| `logType` | which of the three kinds of change this is |
| `targetId` | the scanner's id for the object the permission sits on |
| `targetIdentifier` | the object's own identifier, such as a site url or a subscription id |
| `targetSecondaryIdentifier` | secondary identifier, where the object has one |
| `targetName` | display name of the object |
| `targetCategory` | Sharepoint, Onedrive, Entra, Azure, ExoRecipients and so on |
| `targetType` | type within the category, such as Site or List or Library |
| `permissionId` | identifies this permission across scans |
| `permissionTargetPath` | path the permission applies to |
| `permissionPrincipalEntraId` | object id of who holds it, or `Anonymous`, `AllUsers`, `AllInternalUsers` |
| `permissionprincipalEntraStatus` | Enabled, Disabled, Deleted or N/A |
| `permissionPrincipalName` | name of who holds it, as the source system knows them |
| `permissionPrincipalType` | Internal User, External User, EntraSecurityGroup, SharingLink and so on |
| `permissionPrincipalRole` | the permission, role or sharing right itself |
| `permissionPrincipalRoleType` | Allow or Deny |
| `permissionPrincipalTenure` | Permanent or Eligible |
| `permissionThrough` | Direct, SharingLink, or the group it comes through |
| `permissionIsUnique` | 1 when the permission reaches exactly one person |

A deletion carries only the target columns, `logType` and `permissionId`: the permission it refers to is
gone, so there is nothing left to describe. Join on `permissionId` to find what it was.

### Queries to start from

Something was shared outside the organisation:

```kusto
M365PermissionsDelta_CL
| where logType == "permissionAdded" and permissionPrincipalType has "External"
| project TimeGenerated, targetCategory, permissionTargetPath, permissionPrincipalName, permissionPrincipalRole
```

An anonymous link appeared:

```kusto
M365PermissionsDelta_CL
| where logType != "permissionDeleted" and permissionPrincipalEntraId == "Anonymous"
| project TimeGenerated, permissionTargetPath, permissionPrincipalRole, permissionThrough
```

Someone was given an admin role:

```kusto
M365PermissionsDelta_CL
| where targetCategory == "Admins" and logType == "permissionAdded"
| project TimeGenerated, targetName, permissionPrincipalName, permissionPrincipalRole, permissionPrincipalTenure
```

### Coming from the workspace key route

Records sent with the workspace key landed in a different table, and that API added a type suffix to
every column name. The move is not automatic:

| then | now |
| --- | --- |
| a classic custom table, usually `M365PermissionsDelta_CL_CL`, because that API appends a `_CL` of its own to the type it was given | table `M365PermissionsDelta_CL` |
| `targetName_s`, `permissionIsUnique_d` | `targetName`, `permissionIsUnique` |

To find the old table, look for the one whose records have `SourceSystem == "RestAPI"`, or list the
tables whose `schema.tableSubType` is `Classic`.

Update analytics rules, workbooks and hunting queries to the new table before you rely on them. Data in
the old table stays queryable until its retention period ends, and nothing deletes it.

If you already have a classic table under the name this wants to use, give the new one a different name
under Names in the form. Writing this schema over a classic table would stop that table ingesting.

## Undoing it

Delete the data collection rule. Its two role assignments go with it, the scanner notices within ten
minutes, and it falls back to the workspace key if one is configured, or says what happened in the
M365Permissions portal if not.

The table is left alone by that, because it holds your data. Delete it separately if you want it gone.

## Scripted instead

The same template, without the portal:

```bash
az deployment group create \
  --resource-group <any resource group> \
  --template-uri https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/Sentinel/mainTemplate.json \
  --parameters workspaceResourceId=<workspace resource id> scannerPrincipalIds=<object id,object id>
```

`scannerPrincipalIds` is a comma separated list of the object ids of your scan nodes' managed
identities, which you can find with:

```bash
az graph query -q "resources | where type =~ 'microsoft.compute/virtualmachines' | where tostring(tags) contains 'M365PNodeType' | project name, principalId = tostring(identity.principalId)"
```

The deployment is idempotent, so running it again is safe and reports no changes when there are none.

## Changing the form

`uiFormDefinition.json` is a portal [Form view](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/form-view-overview), which is the format the portal reads when a form is attached to a
template url with `uiFormDefinitionUri`. It is not the `createUiDefinition.json` format Azure Managed
Applications use: that one is passed in through a marketplace offer, not through a url, and the portal
answers an attempt to use it with nothing more than "the extension encountered an unexpected error".

Preview and iterate on it in the [Form view sandbox](https://aka.ms/form/sandbox), which takes pasted
JSON and so needs no commit. The schema is published, so a form can also be checked offline against
`https://schema.management.azure.com/schemas/2021-09-09/uiFormDefinition.schema.json` with any validator
that handles `oneOf`. PowerShell's `Test-Json` does not, and reports both branches of every `oneOf` as
errors.

The template itself is checked with the repository's arm-ttk: `Test-AzTemplate -TemplatePath <this folder>`.
