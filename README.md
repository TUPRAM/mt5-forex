# mt5-forex
Portfolio MT5 (MQL5) codebase: EA + indicators, strategy research notes, and backtest presets.

## Included Indicator

### `FVG_iFVG_Tool` (MQL5/Indicators/FVG_iFVG_Tool.mq5)
Production-focused MetaTrader 5 indicator that detects and manages 3-candle Fair Value Gaps (FVG), tracks lifecycle state transitions, and inverts invalidated zones into iFVG support/resistance zones.

Core behavior implemented:
- 3-candle closed-bar FVG detection:
  - Bull FVG: `High(C1) < Low(C3)`, zone `[High(C1), Low(C3)]`
  - Bear FVG: `Low(C1) > High(C3)`, zone `[High(C3), Low(C1)]`
- Zone lifecycle state machine:
  - `FRESH -> TOUCHED -> FILLED`
  - invalidation to iFVG (`INVALIDATED -> IFVG_ACTIVE`)
  - optional `IFVG_RETESTED` and `IFVG_REJECTED`
  - time/bar-based cleanup into deleted/expired zones
- Configurable touch/fill/invalidation logic
- Min-gap filter and optional ATR displacement filter
- Object-based rendering with stable naming and incremental updates
- Optional alerts (popup/sound/push/email) with per-zone cooldown and event flags

## Installation
1. Copy `MQL5/Indicators/FVG_iFVG_Tool.mq5` into your terminal data folder under `MQL5/Indicators/`.
2. In MetaEditor, open the file and compile.
3. In MT5 Navigator, refresh indicators and attach **FVG_iFVG_Tool** to a chart.

## Usage Notes
- v1 operates on the current chart timeframe only.
- Default processing is on new closed bars (`EvaluateOnNewBar=true`) for performance.
- Use `LookbackBars` to control initialization scan size.
- Use `MaxZones` to cap object count and keep charts responsive.
- Use `MinGapPoints` to ignore tiny gaps.

Recommended starting configuration:
- `LookbackBars=800`
- `MaxZones=120`
- `MinGapPoints=50` (adjust per symbol volatility)
- `TouchMode=Wick`
- `FillMode=WickFarEdge`
- `InvalidationMode=CloseBeyond`
- `EvaluateOnNewBar=true`

## How to test
1. Attach the indicator to an active symbol/timeframe (for stress test: M1 XAUUSD).
2. Scroll back and verify zones are drawn for valid 3-candle patterns:
   - Bull example: candle C1 high is below candle C3 low.
   - Bear example: candle C1 low is above candle C3 high.
3. Let new bars close and verify state progression on labels/colors:
   - first intersection -> `TOUCHED`
   - far-edge rule satisfied -> `FILLED`
4. Verify inversion behavior:
   - Bull FVG invalidation when close/low breaks below `bottom` (based on mode) converts to bearish iFVG with same boundaries.
   - Bear FVG invalidation when close/high breaks above `top` converts to bullish iFVG with same boundaries.
5. If enabled, validate iFVG retest/rejection events and alerts.
6. Change timeframe away and back; verify no duplicate rectangle buildup and stable object updates.
