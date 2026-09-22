#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "tactile_pad.h"

using namespace godot;

static void initialize_tactile(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    GDREGISTER_CLASS(TactilePad);
}

static void uninitialize_tactile(ModuleInitializationLevel level) {
    (void)level;
}

extern "C" GDExtensionBool GDE_EXPORT tactile_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                           GDExtensionClassLibraryPtr library,
                                                           GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_tactile);
    init.register_terminator(uninitialize_tactile);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
