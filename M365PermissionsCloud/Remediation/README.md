# M365Permissions remediation

A publicly callable script that fixes the findings the M365Permissions.com risk log reports. The portal composes the command,
the administrator pastes it into Azure Cloud Shell or a local PowerShell 7, and the script shows exactly
what it will change before it changes anything.

```
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/Remediation/Invoke-M365PRemediation.ps1))) -Items '<payload>'
```

## Run phasing

| phase | what happens | changes anything |
| --- | --- | --- |
| check | findings parsed, handlers loaded, limits and required fields verified, sign in and permissions tested | no |
| plan | every finding looked up live, turned into concrete changes, printed one per line | no |
| apply | only after the administrator types `yes` | yes |

`-WhatIf` stops after the plan. `-Approve` skips the typed confirmation for scripted use, and still prints
and logs the whole plan.

Everything is delegated: changes are made with the signed in administrator's own access, so Entra,
SharePoint and Azure audit logs name a person, not a service principal. It also means the script can only
change what that person could already change by hand.

## What the portal has to send

One JSON array of findings. Three encodings are accepted and detected automatically:

| shape | when to use |
| --- | --- |
| gzip then base64 | what the portal should send. Paths repeat, so this compresses by five to fifteen times |
| base64 of the JSON | fine for a handful of findings |
| raw JSON | hand written, or through `-ItemsPath` |

Measured, for findings whose paths share a prefix:

| findings | raw JSON | base64 | gzip + base64 |
| --- | --- | --- | --- |
| 10 | 2115 | 2820 | 400 |
| 25 | 5340 | 7120 | 640 |
| 50 | 10715 | 14288 | 1016 |

A pasted command line is limited to roughly 8000 characters, which plain base64 hits at about 28 findings.
Gzipped it is not the payload that limits a batch, so the caps below are about keeping one approval
decision reviewable rather than about size.

### Field names

Short keys keep the command short; the long names are accepted too, so a hand written file stays readable.

| short | long | meaning |
| --- | --- | --- |
| `i` | `id` | the riskQueue row id, logged so a run can be tied back to the finding |
| `r` | `reason` | the riskQueue `reason`, exactly as the scanner wrote it |
| `c` | `category` | the riskQueue `categoryShortName` |
| `p` | `targetPath` | the riskQueue `targetPath` |
| `tt` | `targetType` | the riskQueue `targetType` |
| `ti` | `targetId` | the riskQueue `targetId` |
| `pi` | `principalId` | `principalEntraId`: an object id, or `Anonymous`, `AllInternalUsers`, `AllUsers` |
| `pn` | `principalName` | `principalSysName`, used in the plan so the administrator recognises who this is |
| `pu` | `principalUpn` | the principal's user principal name, where the scan has one |
| `ps` | `principalSysId` | `principalSysId`, which for SharePoint carries the claims login name |
| `pt` | `principalType` | `principalType` |
| `ro` | `role` | `principalRole`: the permission, role or sharing right |
| `th` | `through` | `through`, which says whether this came from a link, a group or a direct grant |
| `cd` | `createdDateTime` | when the scan saw it created, used for the age of a sharing link |
| `sd` | `startDateTime` | fallback for the same |

Dates must be ISO 8601 (`2021-03-04T10:00:00Z`). They are parsed with the invariant culture

### Required fields per reason

| reason | required | strongly recommended | why |
| --- | --- | --- | --- |
| External oversharing | `reason`, `category`, `targetPath`, `principalId` | `principalName`, `principalUpn` | the permission to remove is found by matching the principal against the identities on each permission |
| Orphaned permission | `reason`, `category`, `targetPath`, `principalId` | `principalName` | `principalId` must be the object id: the script re-checks that it really is gone before touching anything |
| Sharing link older than two years | `reason`, `category`, `targetPath` | `principalId`, `role`, `createdDateTime` | without `principalId` the script cannot tell one link on an item from another and will list them all |
| Anonymous link never expires | `reason`, `category`, `targetPath` | - | the anonymous link on the item is unambiguous |
| Anonymous link with write access | `reason`, `category`, `targetPath` | - | as above |
| Internal oversharing | `reason`, `category`, `targetPath` | `principalId`, `principalName` | separates a company wide link from a direct grant to everyone-except-external-users |
| Non-owner access to a personal Onedrive | `reason`, `category`, `targetPath`, `principalUpn` | `principalSysId`, `principalName` | SharePoint knows a person by claims login name, which is built from the UPN |
| Privileged Graph app role | `reason`, `category`, `principalId`, `role` | `targetId`, `principalName` | `principalId` is the holding application's service principal object id, `role` the permission value such as `Sites.FullControl.All` |
| Application holds an admin role | `reason`, `category`, `principalId`, `role`, `targetType` | `principalName` | `role` is the directory role display name, `targetType` decides whether Entra owns the role at all |

A finding missing a required field is reported in the plan as not acted on, with the field named. It never
silently disappears.

## Limits

| limit | value | why |
| --- | --- | --- |
| findings per run | 50, which is also the ceiling. `-MaxItems` can only lower it | one plan an administrator can actually read before approving |

One cap for the whole run, whatever mix of reasons is in it. Over it the run refuses and points at
`-ItemsPath`, which has no practical limit and is the route for a bulk clean up: nobody has to read a
pasted command for those.

## What each reason does

| reason | change | reversible |
| --- | --- | --- |
| Anonymous link never expires | Graph route: sets an expiry, `-LinkExpiryDays` days out, default 30. SharePoint route: deletes the link | Graph yes, SharePoint no |
| Anonymous link with write access | Graph route: downgrades the link to read. SharePoint route: deletes the edit link | Graph yes, SharePoint no |
| Internal oversharing | Graph route: downgrades to read. SharePoint route: deletes the company wide link, and removes an everyone-except-external-users grant | the grant removal yes, the link no |
| Sharing link older than two years | deletes the link | no: a recreated link gets a new id and url, so the log records everything needed to rebuild it by hand |
| External oversharing | removes the permission for that outside party | no, same reason |
| Orphaned permission | removes the Azure role assignment, SharePoint grant, directory role or application permission held by a deleted principal | the SharePoint grant yes, the rest no: a deleted principal cannot be granted anything back |
| Non-owner access to a personal Onedrive | removes the site collection administrator | yes, puts them back |
| Privileged Graph app role | removes that one application permission, leaving the rest | yes, re-adds the assignment |
| Application holds an admin role | removes that one directory role | yes, re-adds the assignment |

Irreversible changes are marked `!` in the plan and counted separately in its summary

## What is not supported, and why

Reported in the plan as not acted on rather than failed:

- **Site level SharePoint findings.** A finding on a site or site collection, which is a SharePoint group
  or a security group on the site, has no list item. Graph cannot change those, and site scoped
  permissions are not implemented on the SharePoint route either. The OneDrive owner case is the one
  exception, because site collection administrators have an API of their own.
- **Exchange.** Calendar publishing, mailbox folder permissions and mailbox delegation live in Exchange
  RBAC. No delegated audience here can reach them without the Exchange Online module.
- **Power BI and Power Platform.** Each has its own API and its own admin consent story.
- **Exchange and Intune roles** in `Application holds an admin role`: Entra does not own those role
  systems, so the admin centre for each is named in the plan instead.
- **Azure RBAC** in `Application holds an admin role`: an Azure role assignment is not a directory role.
  The orphan handler already does Azure, so this is a gap worth closing next.

## Sign in and permissions

An existing sign in is borrowed wherever possible, so that in Cloud Shell nothing is asked at all and no
conditional access policy has anything to block. In order:

| order | source | where it works |
| --- | --- | --- |
| 1 | Azure CLI session (`az account get-access-token`) | Cloud Shell always, a workstation after `az login`. Serves Graph, Azure, SharePoint and Exchange from one sign in |
| 2 | Azure PowerShell session (`Get-AzAccessToken`) | Cloud Shell, or after `Connect-AzAccount`. Serves Graph and Azure, not SharePoint |
| 3 | browser sign in, authorization code with PKCE on a loopback listener | a workstation with a browser. Skipped in Cloud Shell, which has neither a browser nor a way to reach a listener inside the container |
| 4 | device code, only with `-DeviceCode` | never automatic, because conditional access blocks the flow in many tenants |

With no session and no browser the run stops and says to run `az login` or pass `-DeviceCode`. It does not
fall back to device code on its own.

### What that means for sharing

The Azure CLI client's Graph token carries `AppRoleAssignment.ReadWrite.All`,
`Application.ReadWrite.All`, `Directory.AccessAsUser.All`, `DelegatedPermissionGrant.ReadWrite.All`,
`Group.ReadWrite.All` and `User.ReadWrite.All`, which covers every identity level change here. It does not
carry `Sites.ReadWrite.All` or `Files.ReadWrite.All`, so Graph will not let it touch sharing.

The same session can get a SharePoint token with `user_impersonation`, so the sharing handlers use
SharePoint's own API instead, and the run says which route it is on:

| route | when | what it does to a link |
| --- | --- | --- |
| SharePoint | the default, on a borrowed session | removes the link. SharePoint cannot take edit off a link or add an expiry to it |
| Graph | when the token carries Sites or Files write scopes, so after `-DeviceCode` or with a consented application | expires or downgrades the link in place, and that is reversible |

Either way the plan states the exact operation before anything happens

| reason | what it needs |
| --- | --- |
| the five sharing reasons | SharePoint `user_impersonation` (route 1), or Graph `Sites.ReadWrite.All` / `Files.ReadWrite.All` (route 2) |
| Orphaned permission | the above, plus `Directory.AccessAsUser.All` or `RoleManagement.ReadWrite.Directory` and `AppRoleAssignment.ReadWrite.All`, and Azure RBAC write at the scope |
| Privileged Graph app role | `AppRoleAssignment.ReadWrite.All` |
| Application holds an admin role | `RoleManagement.ReadWrite.Directory` or `Directory.AccessAsUser.All` |
| Non-owner access to a personal Onedrive | SharePoint administrator, through the SharePoint token |

## Logs and rollback

Three files per run, under `~/m365permissions-remediation` unless `-LogFolder` says otherwise:

| file | contents |
| --- | --- |
| `remediation-<stamp>.log` | everything the run printed, including the full plan |
| `remediation-<stamp>.actions.jsonl` | one line per action with its outcome, appended as it happens, so an interrupted run is still readable |
| `remediation-<stamp>.rollback.json` | the inverse of every reversible change |

Putting a run back:

```
& ([scriptblock]::Create((irm <the url above>))) -Rollback ~/m365permissions-remediation/remediation-<stamp>.rollback.json
```

The rollback goes through the same plan and approval steps.

## Development

```
.\Invoke-M365PRemediation.ps1 -LocalSource . -ItemsPath .\findings.json -WhatIf
```

`-LocalSource` loads the engine and handlers from a folder instead of the internet, so a change can be
tested before it is pushed.

Adding a reason means one `Register-M365PRemediation` block in a file under `handlers/`, which declares the
categories it supports, the scopes it needs, the fields it requires and its own per-run cap, plus a `Plan`
script block that reads and returns actions. The engine owns the approval, the logging, the rollback file
and the self protection, so a handler cannot skip any of them. New handler files also need adding to the
list in `Invoke-M365PRemediation.ps1`.
