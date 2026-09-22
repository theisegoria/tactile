#include "TactileDemoActor.h"

#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "TactileSubsystem.h"

ATactileDemoActor::ATactileDemoActor()
{
    PrimaryActorTick.bCanEverTick = true;
}

void ATactileDemoActor::Tick(float DeltaSeconds)
{
    Super::Tick(DeltaSeconds);
    UGameInstance* GI = GetWorld() ? GetWorld()->GetGameInstance() : nullptr;
    UTactileSubsystem* Pad = GI ? GI->GetSubsystem<UTactileSubsystem>() : nullptr;
    if (!Pad || !Pad->IsControllerConnected()) return;

    if (Pad->WasButtonPressed(ETactileButton::Cross)) { Pad->PlayHaptic(ETactileHapticEffect::Click); }
    if (Pad->WasButtonPressed(ETactileButton::Circle))
    {
        bWeaponOn = !bWeaponOn;
        Pad->SetTrigger(ETactileTriggerSide::Right, bWeaponOn ? UTactileSubsystem::TriggerWeapon(3, 6, 8) : UTactileSubsystem::TriggerOff());
    }
    const FTactileInputState In = Pad->GetInput();
    Pad->SetLightbar(FColor(static_cast<uint8>((In.LeftStick.X + 1.f) * 127.5f), 64, static_cast<uint8>((In.LeftStick.Y + 1.f) * 127.5f)));
}
