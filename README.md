# Azure Firewall with Management Interface for NVA Chaining & Forced Tunneling

A Bicep-based deployment of a hub-and-spoke network topology in Azure with an Azure Firewall (Standard tier) including a dedicated management interface.

The management interface (`AzureFirewallManagementSubnet` + dedicated public IP) provides an out-of-band path for Azure's control plane, independent of data-plane traffic. See [Azure Firewall forced tunneling](https://learn.microsoft.com/azure/firewall/forced-tunneling) for full details. You need it when:

- **Forced tunneling is enabled** — `0.0.0.0/0` on `AzureFirewallSubnet` points to on-premises via ExpressRoute/VPN. Without a management interface, Azure loses the ability to reach the firewall for health monitoring and updates.
- **NVA chaining** — Azure Firewall sits behind a third-party NVA (Zscaler, Palo Alto, Fortinet) and a UDR on `AzureFirewallSubnet` points to that NVA instead of the internet.
- **Compliance mandates (FedRAMP, DoD IL4/5, PCI-DSS)** — policies that prohibit any default internet egress without inspection make forced tunneling non-negotiable, which in turn requires the management interface.
- **Private/zero-trust deployments** — the firewall's data-plane public IP is removed entirely and all egress is private; the management interface keeps Azure platform operations functional.

## Architecture

Hub VNet (`10.0.0.0/24`) containing the Azure Firewall, peered to two spoke VNets. All spoke egress is routed through the firewall via UDRs.

- **Hub**: `vnet-corp-hub` — `AzureFirewallSubnet` (10.0.0.0/26) + `AzureFirewallManagementSubnet` (10.0.0.64/26)
- **Spoke 1**: `vnet-corp-spoke1` — workload subnet (10.1.0.0/24), UDR → firewall
- **Spoke 2**: `vnet-corp-spoke2` — workload subnet (10.2.0.0/24), UDR → firewall

### Resources Deployed

| Resource | Name | Details |
|---|---|---|
| Resource Group | `rg-corp-network-centralus` | Central US |
| Log Analytics Workspace | `log-corp-hub` | 30-day retention |
| Hub VNet | `vnet-corp-hub` | 10.0.0.0/24 |
| Azure Firewall | `afw-corp-hub` | Standard tier, zone-redundant, private IP 10.0.0.4 |
| Firewall Policy | `afwp-corp-hub` | Standard tier, threat intel: Alert |
| Rule Collection Group | `rcg-corp-default` | See Firewall Rules below |
| Firewall PIP (data) | `pip-corp-fw` | Standard SKU, static, zone-redundant |
| Firewall PIP (mgmt) | `pip-corp-fw-mgmt` | Standard SKU, static, zone-redundant — dedicated management interface |
| Spoke 1 VNet | `vnet-corp-spoke1` | 10.1.0.0/24 |
| Spoke 2 VNet | `vnet-corp-spoke2` | 10.2.0.0/24 |
| Route Table (spoke1) | `rt-corp-spoke1` | 0.0.0.0/0 → 10.0.0.4, 10.2.0.0/24 → 10.0.0.4 |
| Route Table (spoke2) | `rt-corp-spoke2` | 0.0.0.0/0 → 10.0.0.4, 10.1.0.0/24 → 10.0.0.4 |

### Key Design Decisions

- **Management interface**: The firewall has a dedicated `AzureFirewallManagementSubnet` with its own public IP, providing an out-of-band path that Azure uses to manage the firewall independently of data-plane traffic. This is needed whenever a UDR on `AzureFirewallSubnet` overrides the default route — without it, Azure loses the ability to reach the firewall for health monitoring and updates. Common scenarios where this applies:
  - **Forced tunneling to on-premises** — routing all internet-bound firewall traffic back through ExpressRoute or VPN to a corporate security stack. The management interface ensures Azure's control plane can still reach the firewall even when `0.0.0.0/0` points on-prem.
  - **NVA sandwich / firewall chaining** — Azure Firewall sitting behind a third-party NVA (e.g. Zscaler, Palo Alto, Fortinet), where a UDR on `AzureFirewallSubnet` points to the NVA instead of the internet.
  - **Strict compliance environments** — FedRAMP High, DoD IL4/5, PCI-DSS — where policy mandates no traffic leaves via a default internet route without explicit inspection, making forced tunneling non-negotiable.
  - **Zero-trust / private-only deployments** — environments where the firewall's data-plane public IP is removed entirely and all egress is private; the management interface keeps Azure's platform operations functional.
  
  In this lab the UDRs are only on the spoke subnets, so the management interface is not strictly required today — it is included to avoid a breaking change if forced tunneling is enabled later.
- **Firewall Policy**: A `firewallPolicies` resource is used (vs. classic rules) — the recommended modern approach allowing rule inheritance and hierarchy.
- **UDRs on spokes**: Both spoke workload subnets have UDRs for `0.0.0.0/0` **and** an explicit route for the other spoke's /16 prefix, both pointing to the firewall. The explicit /16 routes override the more-specific peering system routes, ensuring spoke-to-spoke traffic is inspected rather than bypassing the firewall.
- **BGP propagation disabled**: Route tables have `disableBgpRoutePropagation: true` to prevent gateway routes from overriding the firewall UDRs.
- **Bidirectional peerings**: Both hub→spoke and spoke→hub peerings are created with `allowForwardedTraffic: true`.
- **Availability Zones**: The firewall and both public IPs are deployed across zones 1, 2, and 3 by default. Set the `zones` parameter to `[]` for regions that do not support Availability Zones (e.g. West US).
- **Diagnostic logging**: All firewall log categories (`AzureFirewallApplicationRule`, `AzureFirewallNetworkRule`, `AzureFirewallDnsProxy`) and metrics are streamed to the Log Analytics workspace.

### Firewall Rules

All traffic is denied by default. The following rules are defined in `rcg-corp-default`:

| Priority | Type | Name | Source | Destination | Action |
|---|---|---|---|---|---|
| 100 | Network | `allow-spoke-to-spoke` | 10.1.0.0/24, 10.2.0.0/24 | 10.1.0.0/24, 10.2.0.0/24 | Allow |
| 200 | Application | `allow-http-https` | 10.1.0.0/24, 10.2.0.0/24 | `*` (HTTP/HTTPS) | Allow |

## File Structure

```
azure-firewall-ft-lab/
├── infra/
│   ├── main.bicep          # Subscription-scope entry point; creates resource group and calls network module
│   ├── main.bicepparam     # Bicep parameters file (location, prefix)
│   └── network.bicep       # All network resources (VNets, subnets, firewall, PIPs, UDRs, peerings)
└── README.md
```

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and logged in (`az login`)
- Bicep CLI — installed automatically by Azure CLI
- Contributor access on the target subscription

## Deploy

```bash
az deployment sub create \
  --name hub-spoke-deployment \
  --location centralus \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --subscription <your-subscription-id>
```

Deployment takes approximately **8-10 minutes**, most of which is Azure Firewall provisioning.

## Customise

Edit `infra/main.bicepparam` to change the prefix, region, or zone configuration:

```bicep
using './main.bicep'

param location = 'centralus'     // any Azure region
param prefix   = 'corp'          // resource name prefix
param zones    = ['1', '2', '3'] // set to [] for regions without Availability Zone support (e.g. westus)
```

## Teardown

```bash
az group delete \
  --name rg-corp-network-centralus \
  --subscription <your-subscription-id> \
  --yes
```

## Next Steps

- Deploy workload VMs or App Service environments into the spoke subnets
- Add an **Azure VPN Gateway** or **ExpressRoute** to the hub for on-premises connectivity
