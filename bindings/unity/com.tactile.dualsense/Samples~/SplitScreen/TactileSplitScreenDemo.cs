// Split-screen demo: one cube per player, moved by that player's left stick.
// Cross plays a click on that player's controller only.
using Tactile;
using UnityEngine;

[RequireComponent(typeof(TactileManager))]
public class TactileSplitScreenDemo : MonoBehaviour
{
    TactileManager manager;
    readonly Transform[] avatars = new Transform[4];
    readonly Buttons[] previous = new Buttons[4];
    static readonly Color[] colors = { new Color(0f, .25f, 1f), new Color(1f, .12f, .12f), new Color(.12f, .88f, .25f), new Color(.94f, .19f, .78f) };

    void Start()
    {
        manager = GetComponent<TactileManager>();
        manager.PlayerChanged += (c, player) => Debug.Log($"Tactile: {c.Info.Address} is now player {player}");
        for (int i = 0; i < avatars.Length; i++)
        {
            var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
            cube.name = $"Player {i + 1}";
            cube.transform.position = new Vector3(i * 2.5f - 3.75f, 0, 0);
            cube.GetComponent<Renderer>().material.color = colors[i];
            avatars[i] = cube.transform;
        }
    }

    void Update()
    {
        for (int i = 0; i < avatars.Length; i++)
        {
            var pad = manager.GetPlayer(i + 1);
            if (pad == null || !pad.TryGetInput(out var s)) continue;
            var stick = new Vector2((s.left_x - 128) / 127.5f, -(s.left_y - 128) / 127.5f);
            avatars[i].position += new Vector3(stick.x, 0, stick.y) * (Time.deltaTime * 4);
            var pressed = s.buttons & ~previous[i];
            previous[i] = s.buttons;
            if ((pressed & Buttons.Cross) != 0) pad.Play(HapticEffect.Click);
        }
    }
}
