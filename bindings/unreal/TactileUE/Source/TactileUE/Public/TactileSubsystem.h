// Game-instance subsystem wrapping the Tactile C ABI for Blueprints and C++.
#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "Tickable.h"
#include "TactileSubsystem.generated.h"

struct tactile_context;
struct tactile_controller;

UENUM(BlueprintType)
enum class ETactileTriggerSide : uint8 { Left = 0, Right = 1 };

UENUM(BlueprintType)
enum class ETactileHapticEffect : uint8 { Click = 0, Detent = 1, Texture = 2, Impact = 3 };

UENUM(BlueprintType)
enum class ETactileHapticSide : uint8 { Left = 0, Right = 1, Both = 2 };

// Not BlueprintType: Blueprint enums must be uint8. Blueprints use int32 masks with BitmaskEnum.
UENUM(meta = (Bitflags, UseEnumValuesAsMaskValuesInEditor = "true"))
enum class ETactileButton : int32
{
    None = 0 UMETA(Hidden),
    Square = 1 << 0, Cross = 1 << 1, Circle = 1 << 2, Triangle = 1 << 3,
    L1 = 1 << 4, R1 = 1 << 5, L2 = 1 << 6, R2 = 1 << 7,
    Create = 1 << 8, Options = 1 << 9, L3 = 1 << 10, R3 = 1 << 11,
    PS = 1 << 12, Touchpad = 1 << 13, Mute = 1 << 14,
    DpadUp = 1 << 15, DpadRight = 1 << 16, DpadDown = 1 << 17, DpadLeft = 1 << 18,
    FnLeft = 1 << 19, FnRight = 1 << 20, PaddleLeft = 1 << 21, PaddleRight = 1 << 22,
};
ENUM_CLASS_FLAGS(ETactileButton);

/** 11-byte adaptive-trigger effect. Build with the UTactileSubsystem::Trigger* functions. */
USTRUCT(BlueprintType)
struct FTactileTriggerEffect
{
    GENERATED_BODY()
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") TArray<uint8> Bytes;
    bool IsValid() const { return Bytes.Num() == 11; }
};

USTRUCT(BlueprintType)
struct FTactileInputState
{
    GENERATED_BODY()
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") FVector2D LeftStick = FVector2D::ZeroVector;   // -1..1
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") FVector2D RightStick = FVector2D::ZeroVector;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") float L2 = 0.f;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") float R2 = 0.f;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile", meta = (Bitmask, BitmaskEnum = "/Script/TactileUE.ETactileButton")) int32 Buttons = 0;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") FVector GyroDegPerSec = FVector::ZeroVector;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") FVector AccelG = FVector::ZeroVector;
    UPROPERTY(BlueprintReadOnly, Category = "Tactile") int32 BatteryPercent = -1;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FTactileConnectionChanged, bool, bConnected);

UCLASS()
class TACTILEUE_API UTactileSubsystem : public UGameInstanceSubsystem, public FTickableGameObject
{
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    // FTickableGameObject
    virtual void Tick(float DeltaTime) override;
    virtual TStatId GetStatId() const override { RETURN_QUICK_DECLARE_CYCLE_STAT(UTactileSubsystem, STATGROUP_Tickables); }
    virtual bool IsTickable() const override { return Context != nullptr; }
    virtual ETickableTickType GetTickableTickType() const override { return ETickableTickType::Conditional; }

    UPROPERTY(BlueprintAssignable, Category = "Tactile") FTactileConnectionChanged OnConnectionChanged;

    UFUNCTION(BlueprintPure, Category = "Tactile") bool IsControllerConnected() const { return bConnected; }
    UFUNCTION(BlueprintPure, Category = "Tactile") FTactileInputState GetInput() const { return Input; }
    UFUNCTION(BlueprintPure, Category = "Tactile")
    bool IsButtonMaskDown(UPARAM(meta = (Bitmask, BitmaskEnum = "/Script/TactileUE.ETactileButton")) int32 Mask) const { return (Input.Buttons & Mask) != 0; }
    UFUNCTION(BlueprintPure, Category = "Tactile")
    bool WasButtonMaskPressed(UPARAM(meta = (Bitmask, BitmaskEnum = "/Script/TactileUE.ETactileButton")) int32 Mask) const { return (PressedEdges & Mask) != 0; }
    bool IsButtonDown(ETactileButton Button) const { return IsButtonMaskDown(static_cast<int32>(Button)); }
    bool WasButtonPressed(ETactileButton Button) const { return WasButtonMaskPressed(static_cast<int32>(Button)); }

    UFUNCTION(BlueprintCallable, Category = "Tactile") void SetLightbar(FColor Color);
    UFUNCTION(BlueprintCallable, Category = "Tactile") void SetPlayerLeds(int32 Mask);
    UFUNCTION(BlueprintCallable, Category = "Tactile") void SetRumble(float Left, float Right);
    UFUNCTION(BlueprintCallable, Category = "Tactile") void SetTrigger(ETactileTriggerSide Side, const FTactileTriggerEffect& Effect);
    UFUNCTION(BlueprintCallable, Category = "Tactile") void Neutralize();
    UFUNCTION(BlueprintCallable, Category = "Tactile") void PlayHaptic(ETactileHapticEffect Effect, float Intensity = 1.f, ETactileHapticSide Side = ETactileHapticSide::Both);
    /** Feeds interleaved float PCM to the voice coils (one producer thread). */
    int32 WritePcm(const float* Interleaved, int32 Frames, int32 Channels, double SampleRate);

    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers") static FTactileTriggerEffect TriggerOff();
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers") static FTactileTriggerEffect TriggerFeedback(int32 Position, int32 Strength);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers") static FTactileTriggerEffect TriggerWeapon(int32 Start, int32 End, int32 Strength);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers") static FTactileTriggerEffect TriggerVibration(int32 Position, int32 Amplitude, int32 Frequency);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers") static FTactileTriggerEffect TriggerSlopeFeedback(int32 StartPosition, int32 EndPosition, int32 StartStrength, int32 EndStrength);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers|Unofficial") static FTactileTriggerEffect TriggerBow(int32 Start, int32 End, int32 Strength, int32 SnapForce);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers|Unofficial") static FTactileTriggerEffect TriggerGalloping(int32 Start, int32 End, int32 FirstFoot, int32 SecondFoot, int32 Frequency);
    UFUNCTION(BlueprintPure, Category = "Tactile|Triggers|Unofficial") static FTactileTriggerEffect TriggerMachine(int32 Start, int32 End, int32 AmplitudeA, int32 AmplitudeB, int32 Frequency, int32 Period);

private:
    tactile_context* Context = nullptr;
    tactile_controller* Pad = nullptr;
    FTactileInputState Input;
    int32 PreviousButtons = 0;
    int32 PressedEdges = 0;
    bool bConnected = false;
};
