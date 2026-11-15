### Azure worker storage

The current worker deployment uses a Bicep template, Azure managed disks, and Azure VM Run Command. It does not use AutomatedLab LabSources or require a storage account for VM provisioning or agent setup. Storage accounts created by older deployments are not automatically modified or deleted.
