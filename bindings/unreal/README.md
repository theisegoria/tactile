# Tactile for Unreal Engine (plugin module)

The main Unreal DualSense plugin is Windows-only; this one targets macOS.

1. `bindings/unreal/install-thirdparty.sh` (copies `tactile.h` and a universal
   arm64 + x86_64 dylib; `ARCHS=arm64` for a single architecture).
2. Copy `bindings/unreal/TactileUE` into your project's `Plugins/` folder, regenerate
   project files and build.
3. Use `UTactileSubsystem` from C++ or Blueprints (`Get Game Instance Subsystem`),
   or drop `ATactileDemoActor` into a level.

Ticked on the game thread; output calls never block. The subsystem follows
whichever DualSense is reporting: if its controller goes away and another one is
connected, it switches to that one. Not compiled by the author
(no Unreal install available).
