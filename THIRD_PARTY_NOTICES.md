# Third-party notices and licence decisions

Tactile is MIT-licensed. This file records every external source, what was taken
from it, and how its licence was honoured.

## Nielk1 — TriggerEffectGenerator gist (MIT)

`Sources/TactileCore/TriggerEffect.swift` is adapted from Nielk1's
TriggerEffectGenerator (C#). Parameter ranges, zone bitfields and byte layouts
follow the gist; the Swift is a new translation.

> MIT License — Copyright (c) Nielk1
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in the
> Software without restriction, including without limitation the rights to use, copy,
> modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
> and to permit persons to whom the Software is furnished to do so, subject to the
> following conditions: The above copyright notice and this permission notice shall be
> included in all copies or substantial portions of the Software.
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

*(Maintainer: copy the exact copyright line from the gist header before the first release; it is abbreviated here.)*

## SDL3 — `SDL_hidapi_ps5.c` (zlib)

Used for protocol facts (report layouts, field names). **No SDL code was copied**
into this repository, so no files carry the zlib notice. If code is adapted from SDL
in future, keep the zlib notice in that file and mark it as modified.

## SAxense (MPL-2.0) — decision: clean-room

The Bluetooth audio-haptics framing (`Sources/TactileCore/HapticsReport.swift`) is
implemented **clean-room** from the facts listed in `PROTOCOL.md §Haptics`. No
SAxense source was read into or adapted for this repository, so no MPL-2.0 files
exist here. Unconfirmed framing details are configurable (`HapticsFraming`).

## Linux `hid-playstation.c` (GPL-2.0-or-later) and dualsensectl (GPL-2.0)

Read for **facts only** (offsets, flag bits, calibration maths). No code was copied
or translated.

## Repositories without a licence

nondebug/dualsense and the Opus-audio lead: facts only.

## Trademarks

DualSense and PlayStation are trademarks of Sony Interactive Entertainment Inc.
Tactile is not affiliated with or endorsed by Sony Interactive Entertainment and
uses no Sony logos.
