# Tactile for Unreal Engine (plugin module)

The main Unreal DualSense plugin is Windows-only; this one targets macOS.

1. `bindings/unreal/install-thirdparty.sh` (copies `tactile.h` and the dylib).
2. Copy `bindings/unreal/TactileUE` into your project's `Plugins/` folder, regenerate
   project files and build.
3. Use `UTactileSubsystem` from C++ or Blueprints (`Get Game Instance Subsystem`),
   or drop `ATactileDemoActor` into a level.

Ticked on the game thread; output calls never block. Not compiled by the author
(no Unreal install available).
