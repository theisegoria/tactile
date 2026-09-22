#include "TactileSubsystem.h"

THIRD_PARTY_INCLUDES_START
#include "tactile.h"
THIRD_PARTY_INCLUDES_END

DEFINE_LOG_CATEGORY_STATIC(LogTactile, Log, All);

namespace
{
    FTactileTriggerEffect ToEffect(int32 Result, const tactile_trigger_effect& E)
    {
        FTactileTriggerEffect Out;
        if (Result == TACTILE_OK) { Out.Bytes.Append(E.bytes, 11); }
        return Out;
    }
    float Axis(uint8 V) { return (static_cast<int32>(V) - 128) / 127.5f; }
    uint8 To8(float V) { return static_cast<uint8>(FMath::Clamp(V, 0.f, 1.f) * 255.f); }

    // Returns a retained handle to the first controller delivering input (filling
    // S), or nullptr. Non-blocking: get_input only copies a snapshot.
    tactile_controller* FindReporting(tactile_context* Context, tactile_controller* Skip, tactile_input_state& S)
    {
        const int32 N = tactile_context_controller_count(Context);
        for (int32 I = 0; I < N; ++I)
        {
            tactile_controller* C = nullptr;
            if (tactile_context_get_controller(Context, I, &C) != TACTILE_OK || !C) { continue; }
            S.struct_size = sizeof(S);
            if (C != Skip && tactile_controller_get_input(C, &S) == TACTILE_OK) { return C; }
            tactile_controller_release(C);
        }
        return nullptr;
    }
}

void UTactileSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
    Super::Initialize(Collection);
    if ((tactile_abi_version() >> 16) != TACTILE_ABI_VERSION_MAJOR)
    {
        UE_LOG(LogTactile, Error, TEXT("Tactile: native library ABI mismatch"));
        return;
    }
    if (tactile_permission_status() != TACTILE_PERMISSION_GRANTED) { tactile_permission_request(); }
    tactile_options Options{};
    Options.struct_size = sizeof(Options);
    Options.mode = TACTILE_MODE_SHARED;
    if (tactile_context_create(&Options, &Context) != TACTILE_OK) { Context = nullptr; }
}

void UTactileSubsystem::Deinitialize()
{
    if (Pad) { tactile_controller_release(Pad); Pad = nullptr; }
    if (Context) { tactile_context_destroy(Context); Context = nullptr; }  // restores neutral output
    Input = FTactileInputState();
    PreviousButtons = PressedEdges = 0;
    bConnected = false;
    Super::Deinitialize();
}

void UTactileSubsystem::Tick(float)
{
    bool bNow = false;
    tactile_input_state S{};
    S.struct_size = sizeof(S);
    if (Pad) { bNow = tactile_controller_get_input(Pad, &S) == TACTILE_OK; }
    bool bSwitched = false;
    if (!bNow)
    {
        // The context lists every controller it has ever seen, so index 0 may be
        // a pad that is gone for good. Follow whichever one is reporting.
        if (tactile_controller* Live = FindReporting(Context, Pad, S))
        {
            bSwitched = Pad != nullptr;
            if (Pad) { tactile_controller_release(Pad); }
            Pad = Live;
            bNow = true;
        }
        else if (!Pad && tactile_context_controller_count(Context) > 0)
        {
            // Nothing reporting yet: hold the first one so output calls reach it.
            tactile_context_get_controller(Context, 0, &Pad);
        }
    }
    if (bSwitched && bConnected)
    {
        bConnected = false;
        OnConnectionChanged.Broadcast(false);
    }
    if (bNow)
    {
        Input.LeftStick = FVector2D(Axis(S.left_x), Axis(S.left_y));
        Input.RightStick = FVector2D(Axis(S.right_x), Axis(S.right_y));
        Input.L2 = S.l2 / 255.f;
        Input.R2 = S.r2 / 255.f;
        Input.Buttons = static_cast<int32>(S.buttons);
        Input.GyroDegPerSec = FVector(S.gyro_dps[0], S.gyro_dps[1], S.gyro_dps[2]);
        Input.AccelG = FVector(S.accel_g[0], S.accel_g[1], S.accel_g[2]);
        Input.BatteryPercent = S.battery_percent;
    }
    else
    {
        Input = FTactileInputState();
    }
    PressedEdges = Input.Buttons & ~PreviousButtons;
    PreviousButtons = Input.Buttons;
    if (bNow != bConnected)
    {
        bConnected = bNow;
        OnConnectionChanged.Broadcast(bConnected);
    }
    if (Pad)
    {
        if (int32 Err = tactile_controller_last_error(Pad))
        {
            UE_LOG(LogTactile, Warning, TEXT("Tactile output error: %hs"), tactile_result_string(Err));
        }
    }
}

void UTactileSubsystem::SetLightbar(FColor C) { if (Pad) tactile_controller_set_lightbar(Pad, C.R, C.G, C.B); }
void UTactileSubsystem::SetPlayerLeds(int32 Mask) { if (Pad) tactile_controller_set_player_leds(Pad, static_cast<uint8>(Mask)); }
void UTactileSubsystem::SetRumble(float L, float R) { if (Pad) tactile_controller_set_rumble(Pad, To8(L), To8(R)); }
void UTactileSubsystem::Neutralize() { if (Pad) tactile_controller_neutralize(Pad); }

void UTactileSubsystem::SetTrigger(ETactileTriggerSide Side, const FTactileTriggerEffect& Effect)
{
    if (!Pad || !Effect.IsValid()) return;
    tactile_trigger_effect E{};
    FMemory::Memcpy(E.bytes, Effect.Bytes.GetData(), 11);
    tactile_controller_set_trigger(Pad, static_cast<int32>(Side), &E);
}

void UTactileSubsystem::PlayHaptic(ETactileHapticEffect Effect, float Intensity, ETactileHapticSide Side)
{
    if (Pad) tactile_haptics_play(Pad, static_cast<int32>(Effect), Intensity, static_cast<int32>(Side));
}

int32 UTactileSubsystem::WritePcm(const float* Interleaved, int32 Frames, int32 Channels, double SampleRate)
{
    return Pad ? tactile_haptics_write_pcm(Pad, Interleaved, Frames, Channels, SampleRate) : TACTILE_ERR_NOT_CONNECTED;
}

FTactileTriggerEffect UTactileSubsystem::TriggerOff() { tactile_trigger_effect E{}; tactile_trigger_off(&E); return ToEffect(TACTILE_OK, E); }
FTactileTriggerEffect UTactileSubsystem::TriggerFeedback(int32 P, int32 S) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_feedback(P, S, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerWeapon(int32 A, int32 B, int32 S) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_weapon(A, B, S, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerVibration(int32 P, int32 A, int32 F) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_vibration(P, A, F, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerSlopeFeedback(int32 SP, int32 EP, int32 SS, int32 ES) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_slope_feedback(SP, EP, SS, ES, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerBow(int32 A, int32 B, int32 S, int32 N) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_bow(A, B, S, N, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerGalloping(int32 A, int32 B, int32 F1, int32 F2, int32 F) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_galloping(A, B, F1, F2, F, &E), E); }
FTactileTriggerEffect UTactileSubsystem::TriggerMachine(int32 A, int32 B, int32 X, int32 Y, int32 F, int32 P) { tactile_trigger_effect E{}; return ToEffect(tactile_trigger_machine(A, B, X, Y, F, P, &E), E); }
