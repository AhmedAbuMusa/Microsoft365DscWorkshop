# M365DscWorkshop - Controlling your Entra ID and Microsoft 365 with DSC

## Where do we come from?

### The [DscWorkshop](https://github.com/dsccommunity/DscWorkshop)

The [DscWorkshop](https://github.com/dsccommunity/DscWorkshop) blueprint was started in 2017. The main purpose of the project was and still is to collect the best practices developed by the DSC community over the past several years. The [DscWorkshop](https://github.com/dsccommunity/DscWorkshop) is primarily for managing on-premises or cloud-hosted server infrastructure.

To understand the concepts and tools used here, please also refer to the [DscWorkshop](https://github.com/dsccommunity/DscWorkshop), especially its [exercises](https://github.com/dsccommunity/DscWorkshop/tree/main/Exercises), which provide a quick but comprehensive introduction.

### [Microsoft365DSC - Your Cloud Configuration](https://microsoft365dsc.com/)

[Microsoft365DSC - Your Cloud Configuration](https://microsoft365dsc.com/) provides almost 300 DSC resources to manage Microsoft Entra ID, Exchange Online, SharePoint Online, Teams, and many more services. This project combines the power of [Microsoft365DSC - Your Cloud Configuration](https://microsoft365dsc.com/) and the [DscWorkshop](https://github.com/dsccommunity/DscWorkshop).

### What you get

Like DscWorkshop, M365DscWorkshop provides robust, scalable tooling for managing Azure tenants with DSC and keeping their configuration in source control.

The concept supports managing one or multiple Azure tenants. The configuration data for the tenants is managed in a [Datum](https://github.com/gaelcolas/Datum) YAML file hierarchy. This solution is an ideal way to keep tenants for Dev, Test, and Production in sync. The hierarchical configuration data allows defining a baseline intended for all tenants. This baseline can be customized at a higher level in the hierarchy, for example, to relax security settings in the Dev tenant.

Most automation systems are supported. Azure DevOps is preferred for easy integration with Azure security. The solution supports self-hosted build agents with a user-assigned managed identity or Microsoft-hosted agents with certificate authentication.

![Overview](docs/Overview-Push%20Mode.drawio.svg)

### Getting Started

To get started, please refer to the [technical guide](./docs/readme.md).
