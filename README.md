# XDRStat

An iStat Menus–style menu bar monitor built for the 2026 MacBook Pro (M5 Pro / Max, Mac17,x).
Four menu bar items (CPU & GPU, Memory, Network, Sensors), each opening a detail panel. No root needed.

## Build & run

Requires only the Command Line Tools (no Xcode).

```bash
scripts/build-app.sh --run
```

The app bundle lands in `build/XDRStat.app`. Copy it to `/Applications` and enable
**Launch at login** in Settings (the gear in any panel).

## Where the data comes from

| Area | Source |
|---|---|
| Per-core CPU usage | `host_processor_info` (logical 0–5 = Perf cluster 1, 6–11 = Perf cluster 2, 12–17 = Super) |
| Cluster/core frequency & power, GPU freq/power, DRAM/display/fabric power | IOReport (`Energy Model`, `CPU/GPU Performance States`) + pmgr `voltage-states*-sram` tables |
| GPU utilisation & memory | IOAccelerator `PerformanceStatistics` |
| Temperatures, fans, power rails, voltages, currents | AppleSMC (~270 temps, catalogued in `Sensors/SensorCatalog.swift`) |
| Battery | AppleSmartBattery |
| Memory | `host_statistics64`, `kern.memorystatus_level`, `vm.swapusage` |
| Network | `NET_RT_IFLIST2` 64-bit counters, SystemConfiguration, CoreWLAN |

Hardware probe notes and raw dumps are in `docs/`.

## QA snapshots

`swift build`, then:

```bash
XDRSTAT_SNAPSHOT=/tmp/xdr .build/debug/XDRStat                              # panels (mock data, light/dark/empty) + labels.png
XDRSTAT_SNAPSHOT=/tmp/xdr XDRSTAT_SNAPSHOT_LIVE=1 .build/debug/XDRStat      # real data after 15 s
XDRSTAT_SNAPSHOT=/tmp/xdr XDRSTAT_SNAPSHOT_SETTINGS=1 .build/debug/XDRStat  # the Settings tabs
XDRSTAT_SNAPSHOT=site/img XDRSTAT_SNAPSHOT_SITE=1 .build/debug/XDRStat      # website screenshots (demo data)
XDRSTAT_OPEN=cpu,close,sensors .build/debug/XDRStat                         # opens/closes panels, 4 s apart
```

## App icon

`Resources/AppIcon/source.jpg` is the original art (on white). Regenerate the transparent PNG and `.icns` with:

```bash
swift scripts/make-icon.swift Resources/AppIcon/source.jpg Resources/AppIcon/icon-1024.png
```

then rebuild the iconset with `sips`/`iconutil` into `Resources/AppIcon.icns` (the build script copies it into the bundle).

## Notes
- Menu bar labels are drawn with Core Graphics (`UI/MenuBar/MenuBarLabel.swift`), not SwiftUI's
  `ImageRenderer`, which holds ~100 MB of Metal memory for the life of the process. A label is only handed
  to AppKit when its pixels change, since every status item update is costly on recent macOS.
- Samplers do the expensive work (IOReport, fans, battery, per-process scans, Wi‑Fi) only while the panel
  that shows it is open, and fetch it immediately when that panel opens. Pinned sensors are always read.
- Process lists group helpers under their app (Chrome helpers → Google Chrome), and XPC services such as
  WebKit's WebContent are charged to the app responsible for them, like Activity Monitor.
- Fans read **Off** when the SMC parks them at 0 rpm (normal when cool).
- The Wi‑Fi network name needs Location permission; everything else works without it.
- `@State` is a macro the Command Line Tools can't expand, so views use `@LocalState` (a typealias).
