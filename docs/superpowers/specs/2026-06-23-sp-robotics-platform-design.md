# SP-Robotics — GINEXUS as an end-to-end robot-building platform (2026-06-23)

**Goal (Principal):** GINEXUS supports building a robot *from start to finish* — design → fabricate
(3D print) → firmware → control (ROS 2). Principal has no printer/slicer yet, so this also recommends
the starter stack.

## Architecture — Mac brain, Linux body

- **GINEXUS (macOS app)** stays the orchestrator/brain/UX. It does NOT run the robot directly.
- **A Linux machine** (a **Jetson Orin Nano** for on-robot compute, or any Ubuntu box / Raspberry Pi
  for the bench) runs **ROS 2 (Jazzy)**, the printer pipeline, and firmware tooling.
- GINEXUS talks to it over the network via **SSH + an MCP server running on the Linux side** (so all
  robot/print tools appear as GINEXUS tools, default-deny + HITL like every other MCP integration).
- Rationale: Linux + ROS 2 is the robotics industry standard; macOS ROS support is weak. Keep the
  great native Mac app as the cockpit; put the real-time/robot work on Linux.

## Recommended starter stack (since none owned yet)

- **Printer:** a **Klipper + Moonraker** machine (e.g. Creality K1C / a Voron) OR a **Prusa MK4**
  (PrusaLink). Both expose a clean REST/WebSocket API → the most automation-friendly. (Bambu P1S works
  too but its LAN API/MQTT is more closed.)
- **Slicer:** **OrcaSlicer** — has a CLI for headless STL→G-code, supports Klipper/Prusa/Bambu.
- **CAD (parametric, code-driven):** **CadQuery** (Python) or **OpenSCAD** — GINEXUS generates the
  model as code, so parts are versionable + regenerable (perfect for an AI agent).
- **Firmware:** **arduino-cli** / **PlatformIO** for ESP32 / RP2040 / Arduino; **pyserial** for serial.
- **Robot control:** **ROS 2 Jazzy** on the Linux/Jetson side.

## Phases (each = its own spec → build → verify; build in this order)

1. **Fabrication pipeline (Phase 1 — start here, most self-contained, immediately useful):**
   `read/generate part → slice (OrcaSlicer CLI) → send to printer (Moonraker/PrusaLink) → monitor job`.
   Delivered as a printer MCP server (REST→MCP) + a `slice` tool. Runs Mac-side (slicer CLI) + the
   printer's API. Lets GINEXUS print robot parts on command with HITL on the actual print start.
2. **CAD generation:** a `generate_cad` tool — GINEXUS writes CadQuery/OpenSCAD, renders to STL,
   feeds Phase 1. "Design a 50mm NEMA-17 motor bracket" → STL → slice → print.
3. **Firmware:** an arduino-cli / PlatformIO MCP — compile + flash microcontrollers, serial monitor.
   HITL on every flash (writes to hardware).
4. **ROS 2 control:** an MCP server on the Linux/Jetson exposing ROS 2 (list nodes/topics, publish
   commands, read telemetry, run launch files). HITL on actuator commands (safety-critical).
5. **Orchestration:** a "Build a robot" project template that chains design → print → assemble
   checklist → firmware → bring-up, with the project's files/instructions grounding it.

## Security / safety (acquisition + physical)

- Every hardware-affecting tool (print start, flash, ROS actuator command) is **HITL/biometric** —
  physical actions are irreversible/dangerous.
- All connectors are MCP (default-deny), credentials in Keychain, same posture as SP-Connect.
- Licenses: OrcaSlicer (AGPL — used as an external CLI, never linked), CadQuery (Apache-2.0),
  arduino-cli (GPL — external CLI), ROS 2 (Apache-2.0). External-process use keeps GINEXUS clean.

## Open decisions (Principal)
- Confirm the printer choice (drives the Phase-1 connector: Moonraker vs PrusaLink vs Bambu).
- Where the Linux/ROS side lives (Jetson on-robot vs a bench Ubuntu box).

**v1 of SP-Robotics = Phase 1 + Phase 2** (generate a part → print it). That's a real, demoable
end-to-end slice and the foundation for the rest.
