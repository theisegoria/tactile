using System.IO;
using UnrealBuildTool;

public class TactileUE : ModuleRules
{
    public TactileUE(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new[] { "Core", "CoreUObject", "Engine" });

        string ThirdParty = Path.Combine(ModuleDirectory, "..", "ThirdParty", "CTactile");
        PublicIncludePaths.Add(Path.Combine(ThirdParty, "include"));

        if (Target.Platform == UnrealTargetPlatform.Mac)
        {
            string Dylib = Path.Combine(ThirdParty, "lib", "Mac", "libCTactile.dylib");
            PublicAdditionalLibraries.Add(Dylib);
            PublicDelayLoadDLLs.Add(Dylib);
            RuntimeDependencies.Add("$(BinaryOutputDir)/libCTactile.dylib", Dylib);
        }
    }
}
