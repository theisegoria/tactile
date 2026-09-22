// Demo: Cross = haptic click, Circle = toggle R2 weapon, left stick = lightbar.
using Tactile;
using UnityEngine;

[RequireComponent(typeof(TactileManager))]
public class TactileDemo : MonoBehaviour
{
    TactileManager manager;
    Buttons previous;
    bool weaponOn;
    TriggerEffect weapon, off;

    void Start()
    {
        manager = GetComponent<TactileManager>();
        weapon = Triggers.Weapon(3, 6, 8);
        off = Triggers.Off();
        manager.ControllerChanged += (c, e) => Debug.Log($"Tactile: {e} {c?.Info.Address}");
    }

    void Update()
    {
        var pad = manager.Controller;
        if (pad == null || !pad.TryGetInput(out var s)) return;
        var pressed = s.buttons & ~previous;
        previous = s.buttons;
        if ((pressed & Buttons.Cross) != 0) pad.Play(HapticEffect.Click);
        if ((pressed & Buttons.Circle) != 0)
        {
            weaponOn = !weaponOn;
            pad.SetTrigger(TriggerSide.Right, weaponOn ? weapon : off);
        }
        if ((pressed & Buttons.PaddleLeft) != 0) Debug.Log("Edge left paddle");
        pad.SetLightbar(new Color32(s.left_x, 64, s.left_y, 255));
    }
}
