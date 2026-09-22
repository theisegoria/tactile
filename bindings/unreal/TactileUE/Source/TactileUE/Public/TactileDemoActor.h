// Sample: Cross = haptic click, Circle = toggle R2 weapon, left stick = lightbar.
#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "TactileDemoActor.generated.h"

UCLASS()
class TACTILEUE_API ATactileDemoActor : public AActor
{
    GENERATED_BODY()
public:
    ATactileDemoActor();
    virtual void Tick(float DeltaSeconds) override;
private:
    bool bWeaponOn = false;
};
