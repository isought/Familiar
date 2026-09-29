# Third-party notices

The project's own code is licensed under the Apache License 2.0 (see `LICENSE` and `NOTICE`). This file covers software from other projects that ships inside the app, and other projects this code draws on. The full license texts are in the `licenses/` folder. `scripts/build.sh` copies this file, `LICENSE`, `NOTICE` and `licenses/` into every app bundle under `Contents/Resources/Legal/`.

## Shipped inside the app

### uv

- **What:** Python package and project manager. It runs tool-pack scripts and installs their declared dependencies.
- **Where:** `Contents/Resources/bin/uv`. `scripts/build.sh` copies the `uv` found on the build machine; current releases ship uv 0.10.4.
- **Copyright:** Copyright (c) 2025 Astral Software Inc.
- **License:** dual-licensed MIT or Apache-2.0; redistributed here under the MIT License. Both texts are included: `licenses/uv-LICENSE-MIT.txt` and `licenses/uv-LICENSE-APACHE.txt`.
- **Its own dependencies:** uv is a Rust program built from third-party crates, which are listed with their licenses in the uv repository: https://github.com/astral-sh/uv

## Projects this code draws on

These projects are not shipped. Their notices are reproduced here because parts of this codebase were written with reference to them.

### DeskPad

- **Copyright:** Copyright (c) 2022 Bastian Andelefski
- **License:** MIT (`licenses/DeskPad-LICENSE.txt`)
- **Used for:** `Sources/FamiliarVirtualDisplayBridge/FamiliarVirtualDisplayBridge.m` declares macOS's private virtual-display classes. Those declarations were cross-checked against DeskPad's `CGVirtualDisplayPrivate.h`.

### Chromium

- **Copyright:** Copyright 2015 The Chromium Authors
- **License:** BSD 3-Clause (`licenses/Chromium-LICENSE.txt`)
- **Used for:** the same virtual-display declarations were cross-checked against Chromium's `ui/display/mac/test/virtual_display_util_mac.mm`.

### yabai

- **Copyright:** Copyright (c) 2019 Åsmund Vikane
- **License:** MIT (`licenses/yabai-LICENSE.txt`)
- **Used for:** `Sources/Familiar/Native/Control/Background/SkyLightClick.swift` uses yabai's technique for focusing a window without raising it: the SkyLight event-record layout that activates and deactivates a window.
