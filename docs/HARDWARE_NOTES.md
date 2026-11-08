# MacBook Pro (M5 Pro, Mac17,12) hardware notes — probed 2026-11-07

Machine: Apple M5 Pro, 6 **Super** cores (hw.perflevel0, name "Super") + 12 **Performance**
cores (hw.perflevel1, name "Performance"), 20-core GPU, 64 GB, 2 fans. macOS 27.2.
No Xcode — only CommandLineTools; build with SwiftPM. Everything below works WITHOUT root.

Working probe programs (copy freely): docs/probes/smc.swift, hid.swift, ior.swift.

## SMC (AppleSMC, IOConnectCallStructMethod selector 2)
* Struct MUST be 80 bytes: in Swift the keyInfo tuple needs 3 trailing UInt8 pad bytes
  (see docs/probes/smc.swift) — otherwise #KEY returns 0.
* 3861 keys. Index enumeration: data8=8 (kSMCGetKeyFromIndex), info data8=9, read data8=5.
* Full dump of T/F/P/V/I/B/D keys with decoded flt values: docs/smc-dump.txt
  (format "KEY type value"). Most sensors are type `flt ` (little-endian Float32).
* Temperature families seen (°C, idle machine):
  - Tp00..Tp1g (~23 keys, ~44°C): CPU die sensors — performance-cluster area
  - Ts00..Ts0a (~11 keys): CPU die sensors — super-cluster area
    (Ts0P / Ts1P ~32°C are NOT CPU — palm rest / enclosure)
  - Tg08..Tg43 (~40 keys): GPU die sensors
  - Tm00..Tm2n (~40 keys, ~45°C): memory / SoC fabric dies
  - Ta00..Ta0R (~45°C): ANE?/SoC; TaLP TaLT TaLW TaRF TaRT TaRW TaTP: airflow / enclosure left/right
  - TB0T TB1T TB2T: battery
  - TH0a TH0b TH0x: SSD (NAND) ; TN00-03 also NAND/SSD channels
  - TW0P: Wi‑Fi/BT module
  - TD00..TD34, TDC0..6, TD0C/1C/2C, TDTC TDTP TDVx: Display (XDR panel) region / display driver
  - TAOC TAOI TAOJ TAOP: ambient-ish ~27°C (airflow inlet)
  - TPD0..f TPDX, TRD0..f TRDX, TUD0..f TUDX: power delivery / PMU die sensors (X = max)
  - TVD0 TVDA TVDC TVDG TVDM TVDP TVMR TVNN TVS0-2 TVmS: VRM / power stage
  - TCHP: charger, TCMb, TJUN junction, TMVR, TF2S, TSG1, TS0P, TPMP, TPSP, TPH3: misc
  - TfC0..TfCF: fabric
  - Reject values <= 0 or >= 130, and keys returning garbage.
* Fans: FNum=2. F{n}Ac actual rpm, F{n}Mn min, F{n}Mx max, F{n}Tg target (all flt). F0 max 6250, F1 max 6750.
  F0 = left, F1 = right.
* Power (W, flt): PSTR system total (~16.8W), PPBR battery rail, PDTR may be absent,
  PHPC ~ CPU-ish?, PMVR, PBUS (bus voltage-ish), PZC0/PZC1 adapter?, Pb0f battery.
  Treat unknown P keys as generic "Rail XXXX" only in an "All rails" detail list.
* Voltages V*, Currents I* similar. VD0C ≈ 16V (DC in), Vb0f battery V, Ib0f battery A.

## HID temperature sensors (IOHIDEventSystemClient, usage page 0xff00 usage 5)
Generic names only: "PMU tdie1..14" (×3 PMUs), "PMU tcal", "NAND CH0 temp", "gas gauge battery".
"PMU tdevN" return garbage (-9200) → discard. Use only as a fallback if SMC fails. docs/hid-sample.txt

## IOReport (link -lIOReport, private, works unprivileged) — docs/ioreport-sample.txt
* Group "Energy Model" (deltas in mJ, except "GPU Energy" in nJ):
  - "CPU Energy" total; "PCPU" = super cluster total; "MCPU0", "MCPU1" = perf clusters
  - per-core: PACC_0..5 (super cores), MCPU0_0..5, MCPU1_0..5 (perf cores); *_SRAM, *DTL* = sub-parts (ignore)
  - "GPU Energy" (nJ!) and "GPU0" (mJ); others: ANE?, "DRAM0", "DISP0", "DISPEXT0", "FAB0",
    "AMCC0", "DCS0", "AFR0", "ISP0", "AVE0", "MSR0". Unit label via IOReportChannelGetUnitLabel — always use it.
* Group "CPU Stats" / subgroup "CPU Core Performance States": channels PCPU0..5 (super, 22 states:
  DOWN, IDLE, V0P19..V19P0) and MCPU00..05, MCPU10..15 (perf, 17 states: DOWN?, IDLE, V0P14..V14P0).
  Residency of non-IDLE/DOWN states → active P-state distribution.
* Group "GPU Stats" / subgroup "GPU Performance States": channel GPUPH: OFF, P1..P15.
* Frequency tables: ioreg -rn pmgr -d1 -a, data properties "voltage-statesN" = pairs of UInt32 (freq, volt).
  - voltage-states5  (20 entries) ↔ super cores. Values are NOT Hz on M5: 50103 … 14222 (decreasing as
    voltage rises → period-like). Estimated MHz ≈ 6.556e7 / value (calibrated so top = ~4610 MHz). Mark "estimated".
  - voltage-states22/23 (15 entries) ↔ perf cluster 0/1, same encoding (top ≈ 4380 MHz est.).
  - voltage-states31 (13 entries, Hz/1e6): 338 … 1620 MHz ↔ GPU P1..P13 (GPUPH has 15 P-states; clamp).
    voltage-states9/14 have a leading 0 then the same list — prefer 31 or strip the 0.
  - Detect generically: if values > 1e8 treat as Hz; else apply the period formula.

## Other sources
* GPU: IOServiceMatching("IOAccelerator") → "PerformanceStatistics" dict: "Device Utilization %",
  "Renderer Utilization %", "Tiler Utilization %", "In use system memory", "Alloc system memory".
  "model" = "Apple M5 Pro", "gpu-core-count" = 20.
* Battery: IOServiceMatching("AppleSmartBattery"): CurrentCapacity(%), MaxCapacity(%), CycleCount,
  Voltage(mV), Amperage/InstantAmperage (signed Int64 stored as UInt64 → reinterpret!),
  Temperature (centi-°C?), AppleRawMaxCapacity, DesignCapacity, NominalChargeCapacity,
  IsCharging, ExternalConnected, FullyCharged, AvgTimeToEmpty, AdapterDetails / AppleRawAdapterDetails (Watts, Name).
  "BatteryData" sub-dict has FullChargeCapacity/DesignCapacity.
