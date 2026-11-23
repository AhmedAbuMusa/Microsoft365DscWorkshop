using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;

namespace Microsoft365DscWorkshop
{
    public sealed class KdbxAssemblyLoader : AssemblyLoadContext
    {
        private readonly Dictionary<string, string> paths =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public KdbxAssemblyLoader(string[] assemblies) : base("Microsoft365DscWorkshop.Kdbx", false)
        {
            foreach (string path in assemblies)
                paths[AssemblyName.GetAssemblyName(path).Name] = Path.GetFullPath(path);
        }

        protected override Assembly Load(AssemblyName name)
        {
            if (name.Name.StartsWith("System.", StringComparison.Ordinal) ||
                name.Name.StartsWith("Microsoft.Win32.", StringComparison.Ordinal))
            {
                try { return Default.LoadFromAssemblyName(name); }
                catch (FileNotFoundException) { }
            }
            return paths.TryGetValue(name.Name, out string path) ? LoadFromAssemblyPath(path) : null;
        }

        public void LoadLibrary(string path)
        {
            // KeePass types must be visible to PowerShell; isolate its .NET 10
            // DataProtection dependencies from the Extensions versions pinned by Az.
            Default.Resolving += ResolveDataProtection;
            Default.LoadFromAssemblyPath(Path.GetFullPath(path));
        }

        private Assembly ResolveDataProtection(AssemblyLoadContext context, AssemblyName name)
        {
            return name.Name.StartsWith("Microsoft.AspNetCore.DataProtection", StringComparison.Ordinal) &&
                name.Version?.Major == 10 ? LoadFromAssemblyName(name) : null;
        }
    }
}
