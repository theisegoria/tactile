#pragma once

#include "Modules/ModuleManager.h"

class FTactileUEModule : public IModuleInterface
{
public:
    virtual void StartupModule() override;
    virtual void ShutdownModule() override;
};
