# Managing exported resources and the Microsoft365DSC version

This guide explains how to change the Microsoft365DSC resources included in this repository's tenant export and how to update the Microsoft365DSC version and its dependency pins.

The export resource list is in [ExportConfiguration.yml](./ExportConfiguration.yml). The direct module version pin and the generated dependency pins are in [RequiredModules.psd1](../RequiredModules.psd1).

## How the export resource list works

The `DscResources` list contains Microsoft365DSC resource names, without the `MSFT_` prefix. The `ExportTenantData` build task reads this YAML file and calls `Export-M365DSCConfiguration` once for each listed resource and each selected tenant environment. The export and conversion tasks are described in [Export your Azure Tenant Configuration to Yaml or Json](./ExportToYaml.md).

For example:

```yaml
DscResources:
- AADApplication
- AADNamedLocationPolicy
- AADAuthenticationMethodPolicy
- AADAuthenticationMethodPolicyAuthenticator
```

In the pinned Microsoft365DSC module, resource folders are named with the `MSFT_` prefix. For instance, the `AADAuthenticationMethodPolicyAuthenticator` resource is found in a folder named `MSFT_AADAuthenticationMethodPolicyAuthenticator`. Use the resource type name (the part after `MSFT_`) in `ExportConfiguration.yml`.

The list determines which resources the export task requests; it does not guarantee that each request will produce data. The module must contain the resource, and the tenant, permissions, licensing, and API support must allow it to be exported. A resource can also return no relevant configuration for a particular tenant. The separate delta/drift report may further filter exported configuration to only differences.

## Add or remove a resource

1. **Check the pinned module version.** Read the `Microsoft365DSC` entry in `RequiredModules.psd1`. Resource availability and names are version-dependent.
2. **Verify the resource name.** After dependencies have been restored, look under `output\RequiredModules\Microsoft365DSC\<version>\DscResources` for the corresponding `MSFT_<ResourceName>` folder. You can also ask PowerShell for the resource type:

   ```powershell
   Get-DscResource -Module Microsoft365DSC |
       Select-Object -ExpandProperty ResourceType |
       Sort-Object
   ```

   Use the returned `ResourceType` value, not the `MSFT_` folder prefix. If the command does not find the resource, check that the repository's module dependencies have been restored and that the resource exists in the pinned version.
3. **Edit `export/ExportConfiguration.yml`.** Add the resource as a new list item under `DscResources`, or remove its existing list item. Keep the YAML indentation and avoid duplicates. Add separate resource types separately when the module exposes a feature as multiple resources—for example, an authentication-method policy and its method-specific resources.
4. **Review access and applicability.** Confirm the export application's permissions and tenant licensing/API support for the resource. Do not put credentials or tenant secrets in the resource list.
5. **Run the export and inspect its output.** From the repository root, run:

   ```powershell
   .\build.ps1 -Tasks export
   .\build.ps1 -Tasks exportConvert
   ```

   Or run both tasks in one invocation:

   ```powershell
   .\build.ps1 -Tasks export, exportConvert
   ```

   Review the generated files under `output\Export\<tenant>\`. Check task output for resource-specific errors and verify that the converted YAML contains the expected resource data. Do not treat the mere presence of a resource in `ExportConfiguration.yml` as proof that the tenant returned data for it.
6. **Review and commit the source change.** Commit the edit to `ExportConfiguration.yml` and any related documentation or tests. Generated export output is not a substitute for reviewing the source list.

To stop requesting a resource in future exports, remove only that resource's list item. This does not delete existing tenant configuration, generated files, or deployed DSC state; it only changes what subsequent export runs request.

## What pinning Microsoft365DSC means

The line below in `RequiredModules.psd1` pins the direct Microsoft365DSC dependency to one exact release:

```powershell
Microsoft365DSC = '1.26.729.2'
```

Pinning means dependency restoration is intended to use that specified version rather than selecting whichever release happens to be latest. It makes resource availability and module behavior more reproducible across local builds and CI agents, and allows changes to module versions to be reviewed as deliberate source changes.

The pin is not a snapshot of the Microsoft 365 tenant or of Microsoft's cloud APIs. It does not freeze service-side behavior, tenant data, permissions, or the behavior of dependencies that are not pinned. It also does not by itself update any module files; the build restores dependencies according to the manifest.

Microsoft365DSC has its own dependency requirements. The dependency entries later in `RequiredModules.psd1` are maintained as a generated pin block. They must be consistent with the chosen Microsoft365DSC release. The repository also has a few explicitly managed modules outside that generated block; follow the comments in `RequiredModules.psd1` when checking related compatibility pins.

## Update the Microsoft365DSC pin

Treat a module upgrade as a dependency update, not just a one-line version edit. Review the release and its compatibility implications, then follow this process from the repository root in PowerShell:

1. **Record the current state.** Check `git status` and preserve any unrelated work, especially changes under `output`. Do not delete or restore files that contain other work.
2. **Change the direct version.** Update the `Microsoft365DSC` version in `RequiredModules.psd1` to the intended exact release. Avoid changing unrelated dependency versions at the same time unless required by the upgrade.
3. **Start a fresh PowerShell session.** This avoids open module handles from the currently loaded Microsoft365DSC version.
4. **Refresh the generated dependency output.** The repository's manifest procedure calls for clearing the generated `output` directory before restoring dependencies. First inspect it and preserve anything valuable or unrelated. Only if it is safe to remove the directory, run:

   ```powershell
   Remove-Item -LiteralPath .\output -Recurse -Force
   ```

   Then restore dependencies:

   ```powershell
   .\build.ps1 -UseModuleFast -ResolveDependency -Tasks noop
   ```

   This restores the requested module version and its dependency files into the repository's dependency output.
5. **Check dependency requirements.** Run:

   ```powershell
   Update-M365DSCDependencies -ValidateOnly
   ```

   Review the reported dependency differences and update the generated Microsoft365DSC dependency section in `RequiredModules.psd1` to match the selected release. The manifest also documents how to format the comparison and inspect the restored module's dependency manifest:

   ```powershell
   Update-M365DSCDependencies -ValidateOnly |
       ForEach-Object { [pscustomobject]$_ } |
       ForEach-Object { "'{0}' = '{1}'" -f $_.ModuleName, $_.RequiredVersion }

   (Import-PowerShellDataFile -Path '.\output\RequiredModules\Microsoft365DSC\*\Dependencies\Manifest.psd1').Dependencies |
       ForEach-Object { "'{0}' = '{1}'" -f $_.ModuleName, $_.RequiredVersion }
   ```

   Compare the output with the dependency entries in `RequiredModules.psd1`; update the generated dependency pins for the new release. Do not replace dependency pins wholesale without reviewing the differences. Preserve separate repository-managed pins and keep any explicitly documented compatibility constraints intact.
6. **Verify the resolved module and resources.** Confirm that the restored `output\RequiredModules\Microsoft365DSC` version is the intended release. Recheck resource types used by `ExportConfiguration.yml`; a resource may have been added, renamed, changed, or removed between releases.
7. **Build and test.** Restore/build using the repository workflow:

   ```powershell
   .\build.ps1 -UseModuleFast -ResolveDependency
   ```

   Also run the focused configuration compile if appropriate:

   ```powershell
   .\build.ps1 -Tasks rsop
   ```

   Run the tenant export in a suitable test environment and inspect the generated output before relying on the upgraded version.
8. **Review the source diff.** Ensure `RequiredModules.psd1` contains the exact direct version and reviewed dependency pins. Check the export resource list against the upgraded module, and include relevant release notes or behavior changes in the change description. Commit the manifest and any intentional export-list or documentation changes together.

The current version in this repository is `1.26.729.2`; the number is an example of the exact version pin to change when upgrading. The authoritative update procedure is the comment in `RequiredModules.psd1`, which should be consulted if it differs from this guide.

## Related documentation

- [Export your Azure Tenant Configuration](./readme.md) covers tenant export setup.
- [Export your Azure Tenant Configuration to Yaml or Json](./ExportToYaml.md) covers the repository's export and conversion tasks.
- [RequiredModules.psd1](../RequiredModules.psd1) contains the actual version pins and the repository's dependency-update instructions.
