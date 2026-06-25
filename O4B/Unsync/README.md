# Detect Extra OneDrive Sync

Finds Intune-managed devices where the **logged-on user** is synchronizing **more than just their personal OneDrive for Business** — i.e. they've used the OneDrive client's **Sync** button to add SharePoint / Teams document libraries as separate sync roots.

Deployed as an **Intune Remediation** in *detection-only* mode: it never changes anything on the device. The list of separately-synced sites is written to the script's output, which Intune captures as the **pre-remediation detection output**, giving you a per-device overview directly in the Intune portal.

## Why a remediation script (and not central Graph)?

Which SharePoint sites a user syncs lives **only in that user's `HKCU` registry** (`HKCU:\Software\SyncEngines\Providers\OneDrive`). There is no Graph/Intune inventory for it, and `HKCU` can only be read reliably in the logged-on user's context — hence an on-device remediation detection script run as the user.

## How it works

For each sync scope under `HKCU:\Software\SyncEngines\Providers\OneDrive` the detection script reads `LibraryType`, `UrlNamespace` and **`MountPoint`**. The `MountPoint` is what separates a real separate sync from a harmless shortcut:

| Scope | Example MountPoint | Verdict |
|---|---|---|
| Personal OneDrive (`mysite`/`personal`, `-my.sharepoint.com/personal/`) | `C:\Users\me\OneDrive - Contoso` | ignored |
| **"Add shortcut to OneDrive"** link | `C:\Users\me\OneDrive - Contoso\Marketing - Documents` *(under the OneDrive folder)* | ignored |
| **Separately synced library** (the *Sync* button) | `C:\Users\me\Contoso\Marketing - Documents` *(own root, beside OneDrive)* | **flagged** |

1. Personal OneDrive scopes define the OneDrive folder root(s).
2. A non-personal scope whose MountPoint sits **under** a personal root is an *Add shortcut to OneDrive* link → ignored.
3. A non-personal scope whose MountPoint is **not** under any personal root is a separately synced library → flagged.

| Exit code | Detection output | Meaning |
|---|---|---|
| `0` | `OK: only personal OneDrive for Business is synced.` | Nothing flagged |
| `1` | `EXTRASYNC (n): <url> \| <url> \| ...` | User is syncing n SharePoint/Teams libraries |

## Files

| File | Role |
|---|---|
| `Detect-ExtraOneDriveSync.ps1` | Intune Remediation **detection** script. Reports flagged sites; never remediates. |
| `Remediate-ExtraOneDriveSync.ps1` | **No-op** remediation (optional). Performs nothing — this is a reporting-only solution. |

## Deploy in Intune

1. **Intune admin center** → *Devices* → *Remediations* → **Create**.
2. Give it a name, e.g. `Extra OneDrive Sync Detection`.
3. Upload `Detect-ExtraOneDriveSync.ps1` as the **detection** script. Optionally upload `Remediate-ExtraOneDriveSync.ps1` as the remediation script (or leave it empty — it isn't required).
4. **Settings:**
   - **Run this script using the logged-on credentials:** **Yes** *(required — reads `HKCU`)*
   - **Run script in 64-bit PowerShell:** Yes
   - **Enforce script signature check:** No *(unless you sign the scripts)*
5. **Assign** to the device/user groups in scope and set a schedule (daily is fine).

## Viewing results

In the Intune portal open the remediation → **Device status**. Each device shows its detection state and the **pre-remediation detection output** — the `EXTRASYNC (n): ...` line lists exactly which SharePoint/Teams libraries that user is syncing. Filter on devices with detection output starting with `EXTRASYNC` to get your overview. (Export to CSV from this view if you want it offline.)

## Notes & limits

- Per-user: a device only reports once the targeted user has logged on and OneDrive has synced at least once.
- Intune stores roughly the first ~2 KB of detection output; for users syncing very many sites the output is capped and marked `...[truncated]`.
- Detection errors are reported in the output but exit `0`, so they never trigger the (no-op) remediation.

## License

Copyright Jos Lieben / Lieben Consultancy — see [license terms](https://www.lieben.nu/liebensraum/commercial-use/). Commercial (re)use not allowed without prior written consent; otherwise free to use/modify as long as the headers are kept intact.
