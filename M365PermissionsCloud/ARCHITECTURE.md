# M365PermissionsCloud - Technical Architecture

This document tracks the technical architecture deployed through Azure Marketplace.

This is for reference only, the deployment is fully automated.

> **Privacy & Control:** The entire solution is deployed **inside your Azure Subscription**. No data leaves your tenant. The processing logic, database, and reporting interface reside wholly within the Resource Group you designate.

## 🏗️ Architecture Overview of the Standard Edition

The solution utilizes Platform-as-a-Service (PaaS) for the backend and database to minimize maintenance, while using a specialized Compute instance (VM) for high-performance scanning.

``` mermaid
graph TD
    subgraph "Microsoft"
        GR[Microsoft Graph <br/>and other API's]
    end
    subgraph "Your Azure Subscription"
        subgraph "Resource Group"
            
            subgraph "Processing Core"
                VM[Windows VM <br/> Scanner Engine]
                AA[Automation Account <br/> Scheduler]
            end

            subgraph "Data and Config"
                SQL[(Azure SQL <br/> Database)]
                KV[Key Vault <br/> Secrets & Config]
            end

            subgraph "Presentation & Monitoring"
                WEB[Linux App Service <br/> Dashboard]
                LAW[Log Analytics <br/> Workspace]
                AI[App Insights <br/> Telemetry]
            end
        end
    end

    %% Data Flow
    AA -->|Triggers| VM
    VM -->|Writes Permissions Data| SQL
    GR -.->|Retrieves permissions| VM
    WEB -->|Reads Reports| SQL
    
    %% Security Flow
    VM -.->|Managed Identity| KV
    
    %% Monitoring
    VM -->|Logs| LAW
    WEB -->|Telemetry| AI
```

## 🏗️ Architecture Overview of the Enterprise Edition

The Enterprise solution deploys a Virtual Network (VNet) and projects PaaS services (SQL, Key Vault, Web App) into that network using Private Endpoints.

``` mermaid
graph TD
    subgraph "Microsoft"
        GR[Microsoft Graph <br/>and other API's]
    end
    subgraph "Your Azure Subscription"
        subgraph "Resource Group"
            
            subgraph "Virtual Network (10.86.0.0/16)"
                subgraph "Subnet: Default"
                    VM[Windows VM <br/> Scanner Engine]
                end

                subgraph "Subnet: PrivateLink"
                    PE_SQL((PE: SQL))
                    PE_KV((PE: KeyVault))
                    PE_WEB((PE: WebApp))
                end

                subgraph "Subnet: AppSvc (Delegated)"
                    WEB_INT[WebApp VNet Integration]
                end
            end

            subgraph "PaaS Resources"
                SQL[(Azure SQL <br/> *Public Access Disabled*)]
                KV[Key Vault <br/> *Public Access Disabled*]
                WEB[Linux App Service]
                AA[Automation Account]
            end
            
            subgraph "Monitoring"
                LAW[Log Analytics]
                AI[App Insights]
            end
        end
    end

    %% Network Flow
    VM <-->|Private IP| PE_SQL
    VM <-->|Private IP| PE_KV`
    GR -.->|Retrieves permissions| VM
    
    %% PaaS Links
    PE_SQL -.->|Private Link| SQL
    PE_KV -.->|Private Link| KV
    PE_WEB -.->|Private Link| WEB
    
    %% Web Flow
    WEB_INT -->|Reads Reports| PE_SQL
    WEB -.->|VNet Integrated| WEB_INT

    %% Monitoring
    VM -->|Logs| LAW
    WEB -->|Telemetry| AI

    %% Identity
    AA -->|Trigger| VM
```

## 🌐 Connectivity & Internet Exposure

The solution is designed with a "Secure by Default" posture. Only specific endpoints are accessible from the internet.
The Enterprise version includes private endpoints for additional integration options and attack surface reduction.

| Component | Internet Accessible? | Protocol | Standard Security Controls | Enterprise version |
|-----------|----------------------|----------|-------------------|--------------------|
| **Web Dashboard** | ✅ **Yes** | HTTPS | TLS 1.3 Only. Authentication required via Entra ID (auto configured). | **Management (SCM) endpoint is locked** to internal VNet IPs only. <br/> Optional lock / integration with your own vnets / IP's etc |
| **SQL Database** | ⚠️ **Azure Only** | TCP 1433 | Firewall restricted to "Azure Services Only". No open public internet access. | **Public Network Access is DISABLED.** <br/> Accessible *only* via the Private Endpoint in the VNet (TCP 1433). |
| **Scanner VM** | ❌ **No** | N/A | **No Public IP address** / isolated. Outbound internet access required for Graph API. | **Private Endpoint ONLY** |
| **Key Vault** | ❌ **No** | HTTPS | RBAC restricted. Accessible only by specific Managed Identities within the Resource Group. | **Private Endpoint ONLY**. |

## 🔐 Identity & Access Model

We utilize **System Assigned Managed Identities** to eliminate hardcoded credentials and secret rotation. The frontend does NOT have access to anything except the database, thereby assuring that even if it is compromised, no direct access to the tenant can occur.

``` mermaid
sequenceDiagram
    participant VM as Scanner VM
    participant KV as Key Vault
    participant SQL as SQL Database
    participant M365 as Microsoft 365 API's

    Note over VM: Build Process / Daily Scan
    VM->>KV: Request Config at boot (via Managed Identity)
    KV-->>VM: Returns Credentials / Config
    
    VM->>M365: Scan Permissions (MI auth to Graph API)
    M365-->>VM: Permission information
    
    VM->>SQL: Store Processed Data (Encrypted Connection)
```

## 📦 Component Bill of Materials

| Resource Type | SKU | Purpose | Version |
|---------------|-----|---------|---------|
| `Microsoft.Compute/virtualMachines` | User Selected | **The Worker.** Runs the scanning engine on a hardened image. | Both |
| `Microsoft.Sql/servers/databases` | Standard | **The Memory.** Stores discovered permission data (incl historical). | Both |
| `Microsoft.Web/sites` (App Service) | F1 or B1 | **The Interface.** Linux container hosting the secure dashboard. | Both |
| `Microsoft.KeyVault/vaults` | Standard | **The Safe.** Stores (internal) secrets and persistented configuration. | Both |
| `Microsoft.Automation/automationAccounts` | Basic | **The Clock.** Managed the wake/sleep times of the VM. | Both |
| `Microsoft.Insights/components` | Standard | **The Pulse.** Monitors application health and performance. | Both |
| `Microsoft.Network/privateEndpoints` | N/A | **The Bridges.** Connects PaaS services to the VNet. | Enterprise |
| `Microsoft.Network/privateDnsZones` | N/A | **The Map.** Handles internal DNS resolution for Private Endpoints. | Enterprise |

## 🛡️ Permissions Required

Resources in the Azure part of M365Permissions require specific RBAC assignments to function, these are **assigned automatically**:

1. **Scanner VM**: Assigned `Owner` on the Resource Group to facilitate self-healing and auto-scaling operations.
2. **Scanner VM**: Assigned `Key Vault Administrator` to manage internal secrets.
3. **SQL Admin**: The VM's Managed Identity is set as the Active Directory Administrator for the SQL Server.
