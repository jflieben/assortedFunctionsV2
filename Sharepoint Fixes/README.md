# SPPathFixer

**SharePoint Online Long Path Scanner & Fixer**

Scans your SharePoint Online environment for files and folders that exceed path length limits you decide, then fixes them! Automatically or with a preview-first workflow.

## Why?

SharePoint Online allows paths up to ~400 characters, but many desktop apps (Office, OneDrive sync, Explorer) break at **256** characters — or even **218** for Excel/legacy formats. SPPathFixer finds these problem paths and shortens them before they cause sync failures, broken links, or lost files.

## Quick Start

```powershell
Install-Module SPPathFixer        # One-time install from PSGallery
Import-Module SPPathFixer          # Opens the GUI automatically
```

A browser window opens at `http://localhost:8090`. From there:

1. **Connect** — Sign in with your Microsoft 365 account (or use certificate auth for automation)
2. **Scan** — Pick sites or scan everything. Set your max path threshold (e.g. 256)
3. **Review** — Browse results, filter by site/extension/type, export to Excel
4. **Fix** — Preview changes first (WhatIf), then apply. Three strategies available

## How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SPPathFixer GUI                             │
│                    (Browser @ localhost:8099)                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐ │
│   │ Dashboard │───▶│   Scan    │───▶│  Results  │───▶│    Fix    │ │
│   │           │    │           │    │           │    │           │ │
│   │ Connect   │    │ Select    │    │ Browse    │    │ Preview   │ │
│   │ Status    │    │ sites     │    │ Filter    │    │ Apply     │ │
│   │ Auth mode │    │ Set max   │    │ Export    │    │ Monitor   │ │
│   └───────────┘    │ path len  │    │ Sort      │    │ progress  │ │
│                    └─────┬─────┘    └─────┬─────┘    └─────┬─────┘ │
│                          │                │                │       │
├──────────────────────────┼────────────────┼────────────────┼───────┤
│                   .NET 8 Engine (C#)                               │
│                          │                │                │       │
│                    ┌─────▼─────┐    ┌─────▼─────┐    ┌─────▼─────┐│
│                    │  Graph    │    │  SQLite   │    │  Graph    ││
│                    │  API      │    │  Database │    │  API      ││
│                    │           │    │           │    │           ││
│                    │ Enumerate │    │ Store     │    │ Rename /  ││
│                    │ sites,    │    │ scan      │    │ Move      ││
│                    │ libraries,│    │ results,  │    │ items via ││
│                    │ items     │    │ config,   │    │ PATCH     ││
│                    │           │    │ fix logs  │    │ requests  ││
│                    └─────┬─────┘    └───────────┘    └─────┬─────┘│
│                          │                                 │       │
├──────────────────────────┼─────────────────────────────────┼───────┤
│                          ▼                                 ▼       │
│                 Microsoft Graph API (v1.0)                         │
│                          │                                 │       │
│                          ▼                                 ▼       │
│              SharePoint Online (your tenant)                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Fix Strategies

| Strategy | What it does | Best for |
|----------|-------------|----------|
| **Shorten Name** | Trims the file/folder name to bring the full path under the limit. Extensions preserved. | Most cases — quick, safe, minimal disruption |
| **Move Up** | Moves the item one level up in the folder hierarchy | Deeply nested files that don't need their subfolder |
| **Flatten Path** | Moves the item to the library root (or a target folder). Auto-handles duplicate names | Bulk cleanup of deep folder trees |

## Path Length Limits

The **Scan** page uses a threshold to find problem files (e.g. 200 = flag everything over 200 chars).

The **Fix** page has independent limits that control how much to shorten:

| Setting | Default | Purpose |
|---------|---------|---------|
| Max Path Length | 256 | Standard Windows/SharePoint limit |
| Max Path Length (special) | 218 | For legacy formats (.xlsx, .xls) with stricter limits |
| Special Extensions | .xlsx,.xls | Which extensions use the stricter limit |

## Authentication

| Mode | Use case | Setup |
|------|----------|-------|
| **Delegated** (default) | Interactive use — signs in as you | Just click Connect |
| **Certificate** | Unattended / automation | Requires app registration + certificate |

Both modes use Microsoft Graph API with `Sites.ReadWrite.All` permissions.

## Features

- **Stale detection** — Before fixing, verifies each item hasn't been deleted, renamed, or moved since the scan
- **WhatIf preview** — See exactly what would change before committing
- **Progress tracking** — Real-time progress bar, item counts, and log during fixes
- **Excel export** — Download scan results as .xlsx or .csv
- **Multiple scans** — Keep history, compare results across runs
- **Configurable** — All thresholds, thread counts, and extensions adjustable via GUI or PowerShell

## Requirements

- PowerShell 7.4+
- .NET 8.0 Runtime
- Microsoft 365 account with SharePoint access

## License

Free for non-commercial use.  
Commercial use requires a license — see [liebensraum/commercial-use](https://www.lieben.nu/liebensraum/commercial-use/).

**Author:** Jos Lieben (jos@lieben.nu) — [Lieben Consultancy](https://www.lieben.nu)
