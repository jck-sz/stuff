# Self-hosted Azure DevOps agent + image-build pipeline

Everything needed to run the Packer build from Azure DevOps on a cheap
self-hosted agent. The agent is a small **Ubuntu 24.04** VM — it only
orchestrates Packer; the heavy Windows build happens on the temporary
`Standard_D8s_v5` VM that Packer creates (and deletes) itself.

| File | Purpose |
|---|---|
| `deploy-agent-vm.sh` | Creates RG + VNet + NSG + VM, installs the agent via cloud-init |
| `cloud-init.tpl.yaml` | Installs Azure CLI, Packer, and the ADO agent (systemd service) |
| `create-service-connection.sh` | Service principal + ARM service connection in the project |
| `create-pipeline.sh` | Pushes this repo to Azure Repos and creates the pipeline |
| `../azure-pipelines.yml` | The pipeline: `packer init/validate/build` via `AzureCLI@2` |

## Cost

- `Standard_B2s` (2 vCPU / 4 GiB, default): ~€35/month in westeurope.
  Set `VM_SIZE=Standard_B1ms` (1 vCPU / 2 GiB) to roughly halve that.
- Standard SSD 64 GB OS disk: ~€5/month. Public IP: ~€3/month.
- Deallocate when idle (`az vm deallocate -g rg-ado-agent -n vm-ado-agent`) —
  a stopped B-series VM costs only the disk/IP.

## Run order

```bash
az login                     # once

# 1. Agent VM. PAT scope needed: "Agent Pools (Read & manage)"
#    (User settings -> Personal access tokens in Azure DevOps)
AZP_URL=https://dev.azure.com/<org> ./deploy-agent-vm.sh
#    -> verify the agent shows Online in Organization settings -> Agent pools -> Default

# 2. Service connection (SP with Contributor on the subscription)
ORG_URL=https://dev.azure.com/<org> PROJECT=<project> ./create-service-connection.sh

# 3. Edit ../azure-pipelines.yml variables: subscriptionId, galleryResourceGroup,
#    galleryName, galleryImageName (must match your Compute Gallery setup).

# 4. Push repo + create pipeline
ORG_URL=https://dev.azure.com/<org> PROJECT=<project> ./create-pipeline.sh

# 5. Run it
az pipelines run --name win11-image-build \
  --organization https://dev.azure.com/<org> --project <project>
```

The gallery + image definition must exist first — see the one-time setup in
the main [README](../README.md).

## Notes

- **SSH** to the VM is allowed only from the public IP you deployed from
  (`ssh azureuser@<vm-ip>`). Everything else inbound is denied; the agent
  only needs outbound HTTPS to Azure DevOps.
- The **PAT is used once** at registration and then scrubbed from the VM
  (bootstrap script self-redacts and cloud-init user-data is deleted).
  The agent itself authenticates with its own listener token afterwards, so
  PAT expiry does not affect a registered agent.
- The service principal secret expires after ~1 year (az default); the
  script prints the rotation command.
- Agent troubleshooting on the VM: `sudo journalctl -u 'vsts.agent.*'` and
  `/var/log/ado-agent-bootstrap.log`.
- The pipeline is `trigger: none` (manual) since a build takes 1.5–3 h and
  costs real money; schedule it monthly with a `schedules:` block if wanted.
