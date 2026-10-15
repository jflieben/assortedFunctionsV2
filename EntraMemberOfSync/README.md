# EntraMemberOfSync

A drop-in replacement for the deprecated Entra ID dynamic group **memberOf** feature.

Microsoft is retiring dynamic membership rules of the form `user.memberOf -any (group.objectId -in ['guid','guid'])`. 

`Invoke-Sync.ps1` replaces it as Azure Automation runbook: it keeps a group's membership equal to the union of one or more source groups.

No dependencies and free to use. Uses a Managed Identity, direct Graph calls, and a marker in the description of the group you want managed, so the configuration stays visible in the portal.

It also does something extra: **per group** you decide whether source groups are read as direct members or transitively (includes nested groups!)

## How It Works

```mermaid
flowchart TD
    A([🚀 Start]) --> B

    subgraph DISCOVER ["🔍 Discovery"]
        direction TB
        B["Get token from\nManaged Identity"] --> C{"$search on\ndescription available?"}
        C -- "✅ Yes" --> D[/"groups?$search=\n&quot;description:EntraMemberOfSync&quot;"/]
        C -- "❌ No" --> E[/"Enumerate all groups\n(fallback)"/]
        D --> F["Re-validate every\ncandidate with regex"]
        E --> F
    end

    F --> G

    subgraph GUARDS ["🛡️ Per group guards"]
        direction TB
        G[[For each marked group]] --> H{"Marker in\ndescription?"}
        H -- "❌ No" --> SKIP(["⏭️ Skip"])
        H -- "✅ Yes" --> I{"Dynamic\nmembership rule?"}
        I -- "⚠️ Yes" --> FLAG(["🚩 Skip, flag issue"])
        I -- "No" --> J{"Synced from\non-prem AD?"}
        J -- "⚠️ Yes" --> FLAG
        J -- "No" --> K["Flag broken markers,\nstrip self-reference"]
    end

    K --> L

    subgraph RESOLVE ["📥 Resolve membership"]
        direction TB
        L[[For each source group]] --> M{"Mode in\nthe marker?"}
        M -- "direct" --> N[("/members")]
        M -- "transitive" --> O[("/transitiveMembers")]
        N --> P["Filter on type"]
        O --> P
        P --> Q{{"Union of\nall sources"}}
    end

    Q --> R

    subgraph DIFF ["⚖️ Diff & guard"]
        direction TB
        R["Read current members\nof the target"] --> S{"Source unreadable\nor marker broken?"}
        S -- "⚠️ Yes" --> T["Adds only,\nremovals blocked"]
        S -- "No" --> U{"Desired set empty\nbut group populated?"}
        U -- "Yes" --> U2{"Second read\nconfirms empty?"}
        U2 -- "⚠️ No" --> T
        U2 -- "Yes" --> V
        U -- "No" --> V["Full sync:\nadds + removals"]
    end

    T --> W
    V --> W

    subgraph WRITE ["✏️ Apply"]
        direction TB
        W{"readOnly?"}
        W -- "Yes" --> X["Log planned changes\nonly"]
        W -- "No" --> Y["PATCH members@odata.bind\n(batches of 20)"]
        Y --> Z["DELETE members/{id}/$ref"]
    end

    X --> G
    Z --> G
    SKIP --> G
    FLAG --> G
    G -- "All done" --> AA

    subgraph DONE ["📊 Finish"]
        AA([🏁 Summary\n+ fail job if any group had issues])
    end

    style A fill:#43a047,stroke:#2e7d32,color:#fff,stroke-width:2px
    style AA fill:#1e88e5,stroke:#1565c0,color:#fff,stroke-width:2px
    style SKIP fill:#78909c,stroke:#546e7a,color:#fff,stroke-width:2px
    style FLAG fill:#fb8c00,stroke:#ef6c00,color:#fff,stroke-width:2px
    style T fill:#fb8c00,stroke:#ef6c00,color:#fff,stroke-width:2px
    style Y fill:#43a047,stroke:#2e7d32,color:#fff,stroke-width:2px
    style Z fill:#e53935,stroke:#c62828,color:#fff,stroke-width:2px
```

## Marker Syntax

Put the marker in the **description of the target group**, the group whose membership you want managed. It may sit anywhere in the text, is case insensitive, and tolerates whitespace around the colons and commas.

| Marker | Effect |
| --- | --- |
| `EntraMemberOfSync:<guid>[,<guid>...]` | Direct members of the source groups. This is the default and matches the old memberOf behaviour. |
| `EntraMemberOfSync:direct:<guid>[,<guid>...]` | Identical, spelled out for clarity. |
| `EntraMemberOfSync:transitive:<guid>[,<guid>...]` | Transitive members, so users inside nested source groups are included too. |

Example description:

```
Visio license group. Managed by IT, do not edit members by hand.
EntraMemberOfSync:transitive: 2f1a7c44-9d3e-4b0a-8f61-1c9e0a5b7d22, 9c40b1e8-77af-4d2c-b3a9-5e8f6d1a0c34
```

You can use more than one marker in a single description, each with its own mode. The results are combined:

```
EntraMemberOfSync:direct:2f1a7c44-9d3e-4b0a-8f61-1c9e0a5b7d22
EntraMemberOfSync:transitive:9c40b1e8-77af-4d2c-b3a9-5e8f6d1a0c34
```

The mode applies to how **source** groups are read. The target group's own membership is always read and written as direct members.

Only **user and device** objects are synced by default. A nested group or service principal found inside a source group is ignored, which also means the runbook will never remove a group or service principal that you assigned to the target group directly, if you do want this, modify $supportedMemberTypes

## Setup

1. Create or reuse an Azure Automation account and enable its **system assigned Managed Identity**.
2. Grant that identity the Graph application permission **`GroupMember.ReadWrite.All`**. The quickest way is https://lieben.nu/tools/SPNRoleMgr.
3. Import `Invoke-Sync.ps1` as a PowerShell runbook and publish it. There are no module dependencies.
4. Run it once with `-readOnly` and read the output carefully before going live.
5. Link a schedule (e.g. hourly, monitor how long it takes and adjust as desired)

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-readOnly` | off | Dry run. Reports every addition and removal it would make, writes nothing. |
| `-markerKeyword` | `EntraMemberOfSync` | The keyword to look for in descriptions. Change it to run two independent populations, or to use your own naming. |

## Migrating from a memberOf dynamic group

1. Open the dynamic group and copy the group GUIDs out of the existing rule (`user.memberOf -any (group.objectId -in [...])`).
2. Change the group's membership type from **Dynamic** to **Assigned**. Entra keeps the members that are currently in the group, so nothing is lost in the switchover, and the runbook is skipped for groups that still carry a dynamic rule.
3. Add `EntraMemberOfSync:<those guids>` to the group's description. Use `direct` (or leave the mode out) to reproduce the old behaviour exactly. Use `transitive` if you also want members of groups nested inside those sources, which the old rule could not do.
4. Run the runbook with `-readOnly` and confirm the reported changes are what you expect. Right after a conversion the difference should be zero or very small.
5. Enable the schedule.

Repeat per group. There is nothing to register centrally, the runbook picks up any newly marked group on its next run.

## Safety guards

- Groups that still have a dynamic membership rule are skipped, with a message telling you to convert them first.
- Groups synced from on premises Active Directory are skipped, since AD Connect owns their membership.
- A group that lists itself as a source has that entry stripped.
- A marker that cannot be fully parsed (a typo in a GUID, GUIDs separated by spaces instead of commas) is reported, and its source groups count as unreadable. Only GUIDs may follow a comma, so end the marker with a period or a new line before any other text.
- If **any** source group cannot be read during a run, all removals for that target are cancelled for that run. Additions from the sources that did respond still happen. A transient Graph failure or a typo can therefore never empty a production group.
- A Graph response without a member collection counts as a failed read, never as an empty group.
- If all source groups are empty while the target still has members, the sources are read a second time. When that confirms they are empty, the target is emptied as well. Otherwise removals are cancelled for that run.
- Throttling (429) and transient server errors are retried up to five times, honouring `Retry-After`.
- Any group with an issue (one of the guards above, an unreadable source, or a failed add or remove) is listed at the end of the output. The runbook still finishes all other groups and then throws, so the Automation job ends in **Failed** status and your alerting picks it up.

## Limitations

- Membership follows on a schedule, so changes land within the sync interval you define, rather than instantly.
- Only union-of-groups semantics. Other dynamic rule expressions (department, country, extension attributes) are out of scope, keep using regular dynamic groups for those (e.g. as source groups)
- Roughly 20 source groups per target, because a group description caps out at 1024 characters.
- A marked group used as a source for another marked group converges over successive runs rather than within a single run.
