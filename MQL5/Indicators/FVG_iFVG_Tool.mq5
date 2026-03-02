//+------------------------------------------------------------------+
//|                                              FVG_iFVG_Zones.mq5  |
//|                        Production-grade FVG + iFVG Zone Indicator |
//|                                                                  |
//|  3-candle FVG detection with lifecycle tracking, clean rendering, |
//|  optional filters, and multi-channel alerts.                     |
//+------------------------------------------------------------------+
#property copyright   "FVG iFVG Zones v1.0"
#property version     "1.00"
#property description "Fair Value Gap & Inverted FVG zone tool with lifecycle state machine"
#property indicator_chart_window
#property indicator_plots 0

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+
enum ENUM_TOUCH_MODE
{
   TOUCH_WICK = 0, // Wick (High/Low intersects zone)
   TOUCH_BODY = 1  // Body (Open/Close intersects zone)
};

enum ENUM_FILL_MODE
{
   FILL_WICK_FAR_EDGE    = 0, // Wick touches far edge
   FILL_CLOSE_BEYOND_FAR = 1  // Close beyond far edge
};

enum ENUM_INVALIDATION_MODE
{
   INVALIDATION_CLOSE_BEYOND = 0, // Close beyond (strict)
   INVALIDATION_WICK_THROUGH = 1  // Wick through (loose)
};

enum ENUM_ZONE_STATE
{
   STATE_FRESH          = 0,
   STATE_TOUCHED        = 1,
   STATE_FILLED         = 2,
   STATE_INVALIDATED    = 3,
   STATE_IFVG_ACTIVE    = 4,
   STATE_IFVG_RETESTED  = 5,
   STATE_IFVG_REJECTED  = 6,
   STATE_EXPIRED        = 7,
   STATE_DELETED        = 8
};

enum ENUM_ZONE_DIR
{
   DIR_BULL = 0,
   DIR_BEAR = 1
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
// --- Detection ---
input int       InpLookbackBars        = 500;         // Lookback Bars
input int       InpMaxZones            = 50;          // Max Active Zones
input bool      InpEvaluateOnNewBar    = true;        // Evaluate Only On New Bar
input double    InpMinGapPoints        = 0;           // Min Gap Size (points, 0=off)

// --- ATR Displacement Filter ---
input bool      InpUseATRFilter        = false;       // Use ATR Displacement Filter
input int       InpATRPeriod           = 14;          // ATR Period
input double    InpATRMultiplier       = 1.0;         // ATR Multiplier for C2 body
input double    InpC2CloseNearExtPct   = 0;           // C2 Close Near Extreme % (0=off)

// --- Touch / Fill / Invalidation ---
input ENUM_TOUCH_MODE        InpTouchMode        = TOUCH_WICK;               // Touch Mode
input ENUM_FILL_MODE         InpFillMode         = FILL_WICK_FAR_EDGE;       // Fill Mode
input ENUM_INVALIDATION_MODE InpInvalidationMode = INVALIDATION_CLOSE_BEYOND;// Invalidation Mode

// --- iFVG ---
input bool      InpEnableIFVG          = true;        // Enable iFVG Inversion
input bool      InpEnableIFVGRetest    = true;        // Track iFVG Retest
input bool      InpEnableIFVGRejection = true;        // Track iFVG Rejection

// --- Expiry / Cleanup ---
input int       InpDeleteFilledAfterBars  = 20;       // Delete Filled Zones After N Bars (0=keep)
input int       InpDeleteExpiredAfterBars = 100;       // Delete Expired Zones After N Bars (0=keep)
input int       InpMaxZoneAgeBars         = 500;       // Max Zone Age in Bars (0=unlimited)

// --- Drawing ---
input bool      InpDrawZones           = true;        // Draw Zone Rectangles
input bool      InpDrawMidline         = false;       // Draw 50% Midline
input bool      InpDrawLabels          = true;        // Draw Zone Labels
input bool      InpExtendZones         = true;        // Extend Active Zones to Current Bar

// --- Colors: FVG ---
input color     InpColorBullFresh      = clrDodgerBlue;   // Bull FVG Fresh
input color     InpColorBullTouched    = clrCornflowerBlue;// Bull FVG Touched
input color     InpColorBearFresh      = clrCrimson;       // Bear FVG Fresh
input color     InpColorBearTouched    = clrIndianRed;     // Bear FVG Touched
input color     InpColorFilled         = clrDimGray;       // Filled Zone

// --- Colors: iFVG ---
input color     InpColorIFVGBullActive   = clrLimeGreen;     // iFVG Bull (support) Active
input color     InpColorIFVGBearActive   = clrOrangeRed;     // iFVG Bear (resistance) Active
input color     InpColorIFVGRetested     = clrGold;          // iFVG Retested
input color     InpColorIFVGRejected     = clrMagenta;       // iFVG Rejected

input int       InpZoneOpacity         = 30;          // Zone Opacity (0-100 -> 0-255 mapped internally)
input int       InpLabelFontSize       = 8;           // Label Font Size
input color     InpLabelColor          = clrWhite;    // Label Color

// --- Alerts ---
input bool      InpAlertNewFVG         = false;       // Alert: New FVG
input bool      InpAlertFirstTouch     = false;       // Alert: First Touch
input bool      InpAlertFill           = false;       // Alert: Fill
input bool      InpAlertInversion      = false;       // Alert: Inversion to iFVG
input bool      InpAlertIFVGRetest     = false;       // Alert: iFVG Retest
input bool      InpAlertIFVGRejection  = false;       // Alert: iFVG Rejection
input bool      InpAlertPopup          = true;        // Channel: Popup
input bool      InpAlertSound          = false;       // Channel: Sound
input bool      InpAlertPush           = false;       // Channel: Push Notification
input bool      InpAlertEmail          = false;       // Channel: Email
input int       InpAlertCooldownSec    = 60;          // Alert Cooldown (seconds)

//+------------------------------------------------------------------+
//| Zone Data Structure                                               |
//+------------------------------------------------------------------+
struct ZoneData
{
   long           id;              // unique id
   string         symbol;
   ENUM_TIMEFRAMES timeframe;
   datetime        originTime;     // time of C2 (middle candle)
   int             originBarShift; // bar shift at creation time
   double          bottom;
   double          top;
   ENUM_ZONE_DIR   direction;      // original direction
   ENUM_ZONE_STATE state;

   // iFVG direction (after inversion)
   ENUM_ZONE_DIR   ifvgDirection;

   // Timestamps
   datetime        touchTime;
   datetime        fillTime;
   datetime        inversionTime;
   datetime        retestTime;
   datetime        rejectionTime;
   datetime        expiryTime;

   // Alert flags (per event, to avoid spam)
   bool            alertedNew;
   bool            alertedTouch;
   bool            alertedFill;
   bool            alertedInversion;
   bool            alertedRetest;
   bool            alertedRejection;
   datetime        lastAlertTime;

   // For cleanup
   int             filledAtBar;
   int             expiredAtBar;

   // Object names (stored for efficient updates)
   string          rectName;
   string          midlineName;
   string          labelName;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
ZoneData     g_zones[];
int          g_zoneCount     = 0;
long         g_nextId        = 1;
datetime     g_lastBarTime   = 0;
int          g_lastBars      = 0;
string       g_prefix;
int          g_atrHandle     = INVALID_HANDLE;
double       g_atrBuffer[];

//+------------------------------------------------------------------+
//| Helper: Generate unique prefix                                    |
//+------------------------------------------------------------------+
string GetPrefix()
{
   return "FVGz_" + _Symbol + "_" + IntegerToString((int)Period()) + "_";
}

//+------------------------------------------------------------------+
//| Helper: Zone object name from zone data                           |
//+------------------------------------------------------------------+
string ZoneRectName(const ZoneData &z)
{
   return g_prefix + "R_" + IntegerToString(z.id);
}

string ZoneMidlineName(const ZoneData &z)
{
   return g_prefix + "M_" + IntegerToString(z.id);
}

string ZoneLabelName(const ZoneData &z)
{
   return g_prefix + "L_" + IntegerToString(z.id);
}

//+------------------------------------------------------------------+
//| Helper: State to string                                           |
//+------------------------------------------------------------------+
string StateToString(ENUM_ZONE_STATE st)
{
   switch(st)
   {
      case STATE_FRESH:         return "Fresh";
      case STATE_TOUCHED:       return "Touched";
      case STATE_FILLED:        return "Filled";
      case STATE_INVALIDATED:   return "Invalidated";
      case STATE_IFVG_ACTIVE:   return "iFVG";
      case STATE_IFVG_RETESTED: return "iFVG Retested";
      case STATE_IFVG_REJECTED: return "iFVG Rejected";
      case STATE_EXPIRED:       return "Expired";
      case STATE_DELETED:       return "Deleted";
   }
   return "?";
}

//+------------------------------------------------------------------+
//| Helper: Direction to string                                       |
//+------------------------------------------------------------------+
string DirToString(ENUM_ZONE_DIR dir)
{
   return (dir == DIR_BULL) ? "Bull" : "Bear";
}

//+------------------------------------------------------------------+
//| Helper: Timeframe to string                                       |
//+------------------------------------------------------------------+
string TFToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
   }
   return EnumToString(tf);
}

//+------------------------------------------------------------------+
//| Helper: Delete all chart objects with our prefix                   |
//+------------------------------------------------------------------+
void DeleteAllObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Helper: Delete objects for a single zone                          |
//+------------------------------------------------------------------+
void DeleteZoneObjects(const ZoneData &z)
{
   ObjectDelete(0, z.rectName);
   ObjectDelete(0, z.midlineName);
   ObjectDelete(0, z.labelName);
}

//+------------------------------------------------------------------+
//| Helper: Map opacity input (0-100) to MQL5 alpha style             |
//+------------------------------------------------------------------+
// MQL5 rectangle fill uses color with OBJPROP_FILL=true.
// We use OBJPROP_COLOR. Transparency via chart background isn't
// directly controllable per object, so we keep fill=true and rely
// on color selection for visual effect.

//+------------------------------------------------------------------+
//| Helper: Get color for zone based on state and direction            |
//+------------------------------------------------------------------+
color GetZoneColor(const ZoneData &z)
{
   switch(z.state)
   {
      case STATE_FRESH:
         return (z.direction == DIR_BULL) ? InpColorBullFresh : InpColorBearFresh;
      case STATE_TOUCHED:
         return (z.direction == DIR_BULL) ? InpColorBullTouched : InpColorBearTouched;
      case STATE_FILLED:
         return InpColorFilled;
      case STATE_INVALIDATED:
         return InpColorFilled;
      case STATE_IFVG_ACTIVE:
         return (z.ifvgDirection == DIR_BULL) ? InpColorIFVGBullActive : InpColorIFVGBearActive;
      case STATE_IFVG_RETESTED:
         return InpColorIFVGRetested;
      case STATE_IFVG_REJECTED:
         return InpColorIFVGRejected;
      case STATE_EXPIRED:
         return InpColorFilled;
      default:
         return InpColorFilled;
   }
}

//+------------------------------------------------------------------+
//| Helper: Check if zone is "alive" (should be tracked/drawn)        |
//+------------------------------------------------------------------+
bool IsZoneAlive(ENUM_ZONE_STATE st)
{
   return (st != STATE_DELETED && st != STATE_EXPIRED);
}

bool IsZoneDrawable(ENUM_ZONE_STATE st)
{
   return (st != STATE_DELETED);
}

//+------------------------------------------------------------------+
//| Add zone to array                                                 |
//+------------------------------------------------------------------+
int AddZone(ZoneData &newZone)
{
   int newSize = g_zoneCount + 1;
   ArrayResize(g_zones, newSize, 64);
   g_zones[g_zoneCount] = newZone;
   g_zoneCount = newSize;
   return g_zoneCount - 1;
}

//+------------------------------------------------------------------+
//| Remove zone at index (swap with last)                             |
//+------------------------------------------------------------------+
void RemoveZone(int idx)
{
   if(idx < 0 || idx >= g_zoneCount)
      return;
   DeleteZoneObjects(g_zones[idx]);
   if(idx < g_zoneCount - 1)
      g_zones[idx] = g_zones[g_zoneCount - 1];
   g_zoneCount--;
   ArrayResize(g_zones, g_zoneCount, 64);
}

//+------------------------------------------------------------------+
//| Enforce MaxZones cap (remove oldest by origin time)               |
//+------------------------------------------------------------------+
void EnforceMaxZones()
{
   while(g_zoneCount > InpMaxZones)
   {
      // find oldest zone
      int oldestIdx = 0;
      datetime oldestTime = g_zones[0].originTime;
      for(int i = 1; i < g_zoneCount; i++)
      {
         if(g_zones[i].originTime < oldestTime)
         {
            oldestTime = g_zones[i].originTime;
            oldestIdx = i;
         }
      }
      RemoveZone(oldestIdx);
   }
}

//+------------------------------------------------------------------+
//| Check for duplicate zone (same origin time + direction)           |
//+------------------------------------------------------------------+
bool IsDuplicateZone(datetime originTime, ENUM_ZONE_DIR dir)
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(g_zones[i].originTime == originTime &&
         g_zones[i].direction == dir &&
         g_zones[i].symbol == _Symbol &&
         g_zones[i].timeframe == Period())
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detection: Check 3-candle FVG at given shifts                     |
//+------------------------------------------------------------------+
// C1 = oldest (shift+2), C2 = middle (shift+1), C3 = newest (shift)
// For most-recent closed: shift=1 → C3=1, C2=2, C1=3
bool DetectFVG(int shiftC3,
               double &zoneBottom, double &zoneTop,
               ENUM_ZONE_DIR &dir, datetime &originTime)
{
   int shiftC2 = shiftC3 + 1;
   int shiftC1 = shiftC3 + 2;

   double highC1  = iHigh(_Symbol, PERIOD_CURRENT, shiftC1);
   double lowC1   = iLow(_Symbol, PERIOD_CURRENT, shiftC1);
   double highC2  = iHigh(_Symbol, PERIOD_CURRENT, shiftC2);
   double lowC2   = iLow(_Symbol, PERIOD_CURRENT, shiftC2);
   double openC2  = iOpen(_Symbol, PERIOD_CURRENT, shiftC2);
   double closeC2 = iClose(_Symbol, PERIOD_CURRENT, shiftC2);
   double highC3  = iHigh(_Symbol, PERIOD_CURRENT, shiftC3);
   double lowC3   = iLow(_Symbol, PERIOD_CURRENT, shiftC3);

   // Validate data
   if(highC1 == 0 || highC2 == 0 || highC3 == 0)
      return false;

   // Bullish FVG: High(C1) < Low(C3)
   if(highC1 < lowC3)
   {
      zoneBottom = highC1;
      zoneTop    = lowC3;
      dir        = DIR_BULL;
      originTime = iTime(_Symbol, PERIOD_CURRENT, shiftC2);

      // Min gap filter
      if(InpMinGapPoints > 0 && (zoneTop - zoneBottom) < InpMinGapPoints * _Point)
         return false;

      // ATR filter
      if(InpUseATRFilter && !PassATRFilter(shiftC2, openC2, closeC2, highC2, lowC2))
         return false;

      return true;
   }

   // Bearish FVG: Low(C1) > High(C3)
   if(lowC1 > highC3)
   {
      zoneBottom = highC3;
      zoneTop    = lowC1;
      dir        = DIR_BEAR;
      originTime = iTime(_Symbol, PERIOD_CURRENT, shiftC2);

      // Min gap filter
      if(InpMinGapPoints > 0 && (zoneTop - zoneBottom) < InpMinGapPoints * _Point)
         return false;

      // ATR filter
      if(InpUseATRFilter && !PassATRFilter(shiftC2, openC2, closeC2, highC2, lowC2))
         return false;

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| ATR Displacement Filter                                           |
//+------------------------------------------------------------------+
bool PassATRFilter(int shiftC2, double openC2, double closeC2,
                   double highC2, double lowC2)
{
   if(g_atrHandle == INVALID_HANDLE)
      return true;

   double atr[];
   if(CopyBuffer(g_atrHandle, 0, shiftC2, 1, atr) < 1)
      return true;

   double bodySize = MathAbs(closeC2 - openC2);

   if(bodySize < InpATRMultiplier * atr[0])
      return false;

   // Close near extreme filter
   if(InpC2CloseNearExtPct > 0)
   {
      double range = highC2 - lowC2;
      if(range <= 0) return false;

      if(closeC2 > openC2) // bullish candle
      {
         double distFromHigh = highC2 - closeC2;
         if((distFromHigh / range) * 100.0 > InpC2CloseNearExtPct)
            return false;
      }
      else // bearish candle
      {
         double distFromLow = closeC2 - lowC2;
         if((distFromLow / range) * 100.0 > InpC2CloseNearExtPct)
            return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Zone Touch Check                                                  |
//+------------------------------------------------------------------+
bool CheckTouch(const ZoneData &z, double high, double low, double open, double close)
{
   if(InpTouchMode == TOUCH_WICK)
   {
      // Wick: candle range intersects zone
      return (low <= z.top && high >= z.bottom);
   }
   else // TOUCH_BODY
   {
      double bodyHi = MathMax(open, close);
      double bodyLo = MathMin(open, close);
      return (bodyLo <= z.top && bodyHi >= z.bottom);
   }
}

//+------------------------------------------------------------------+
//| Zone Fill Check                                                   |
//+------------------------------------------------------------------+
bool CheckFill(const ZoneData &z, double high, double low, double close)
{
   if(z.direction == DIR_BULL)
   {
      // Far edge = bottom; price must reach bottom
      if(InpFillMode == FILL_WICK_FAR_EDGE)
         return (low <= z.bottom);
      else
         return (close <= z.bottom);
   }
   else // DIR_BEAR
   {
      // Far edge = top; price must reach top
      if(InpFillMode == FILL_WICK_FAR_EDGE)
         return (high >= z.top);
      else
         return (close >= z.top);
   }
}

//+------------------------------------------------------------------+
//| Zone Invalidation Check                                           |
//+------------------------------------------------------------------+
bool CheckInvalidation(const ZoneData &z, double high, double low, double close)
{
   if(z.direction == DIR_BULL)
   {
      // Bull invalidation: price closes/wicks below bottom
      if(InpInvalidationMode == INVALIDATION_CLOSE_BEYOND)
         return (close < z.bottom);
      else
         return (low < z.bottom);
   }
   else // DIR_BEAR
   {
      // Bear invalidation: price closes/wicks above top
      if(InpInvalidationMode == INVALIDATION_CLOSE_BEYOND)
         return (close > z.top);
      else
         return (high > z.top);
   }
}

//+------------------------------------------------------------------+
//| iFVG Retest Check                                                 |
//+------------------------------------------------------------------+
bool CheckIFVGRetest(const ZoneData &z, double high, double low)
{
   // Price intersects the zone after inversion
   return (low <= z.top && high >= z.bottom);
}

//+------------------------------------------------------------------+
//| iFVG Rejection Check                                              |
//+------------------------------------------------------------------+
bool CheckIFVGRejection(const ZoneData &z, double close)
{
   if(z.ifvgDirection == DIR_BEAR) // bearish iFVG (resistance)
   {
      // After retest, candle closes back below bottom
      return (close < z.bottom);
   }
   else // bullish iFVG (support)
   {
      // After retest, candle closes back above top
      return (close > z.top);
   }
}

//+------------------------------------------------------------------+
//| Update Zone State Machine for a given bar                         |
//+------------------------------------------------------------------+
void UpdateZoneState(ZoneData &z, int barShift)
{
   if(!IsZoneAlive(z.state))
      return;

   double high  = iHigh(_Symbol, PERIOD_CURRENT, barShift);
   double low   = iLow(_Symbol, PERIOD_CURRENT, barShift);
   double open  = iOpen(_Symbol, PERIOD_CURRENT, barShift);
   double close = iClose(_Symbol, PERIOD_CURRENT, barShift);
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, barShift);

   if(high == 0 || low == 0)
      return;

   // Skip bars at or before zone origin
   if(barTime <= z.originTime)
      return;

   switch(z.state)
   {
      case STATE_FRESH:
      {
         // Check invalidation first (takes priority over touch/fill)
         if(CheckInvalidation(z, high, low, close))
         {
            if(InpEnableIFVG)
            {
               z.state = STATE_IFVG_ACTIVE;
               z.inversionTime = barTime;
               // Invert direction for iFVG
               z.ifvgDirection = (z.direction == DIR_BULL) ? DIR_BEAR : DIR_BULL;
               FireAlert(z, "Inverted to iFVG", InpAlertInversion, z.alertedInversion);
            }
            else
            {
               z.state = STATE_INVALIDATED;
               z.inversionTime = barTime;
            }
            return;
         }
         // Check fill
         if(CheckFill(z, high, low, close))
         {
            z.state = STATE_FILLED;
            z.fillTime = barTime;
            z.filledAtBar = Bars(_Symbol, PERIOD_CURRENT) - barShift;
            FireAlert(z, "Filled", InpAlertFill, z.alertedFill);
            return;
         }
         // Check touch
         if(CheckTouch(z, high, low, open, close))
         {
            z.state = STATE_TOUCHED;
            z.touchTime = barTime;
            FireAlert(z, "First Touch", InpAlertFirstTouch, z.alertedTouch);
         }
         break;
      }

      case STATE_TOUCHED:
      {
         // Check invalidation
         if(CheckInvalidation(z, high, low, close))
         {
            if(InpEnableIFVG)
            {
               z.state = STATE_IFVG_ACTIVE;
               z.inversionTime = barTime;
               z.ifvgDirection = (z.direction == DIR_BULL) ? DIR_BEAR : DIR_BULL;
               FireAlert(z, "Inverted to iFVG", InpAlertInversion, z.alertedInversion);
            }
            else
            {
               z.state = STATE_INVALIDATED;
               z.inversionTime = barTime;
            }
            return;
         }
         // Check fill
         if(CheckFill(z, high, low, close))
         {
            z.state = STATE_FILLED;
            z.fillTime = barTime;
            z.filledAtBar = Bars(_Symbol, PERIOD_CURRENT) - barShift;
            FireAlert(z, "Filled", InpAlertFill, z.alertedFill);
            return;
         }
         break;
      }

      case STATE_IFVG_ACTIVE:
      {
         if(InpEnableIFVGRetest && CheckIFVGRetest(z, high, low))
         {
            z.state = STATE_IFVG_RETESTED;
            z.retestTime = barTime;
            FireAlert(z, "iFVG Retested", InpAlertIFVGRetest, z.alertedRetest);
         }
         break;
      }

      case STATE_IFVG_RETESTED:
      {
         if(InpEnableIFVGRejection && CheckIFVGRejection(z, close))
         {
            z.state = STATE_IFVG_REJECTED;
            z.rejectionTime = barTime;
            FireAlert(z, "iFVG Rejected", InpAlertIFVGRejection, z.alertedRejection);
         }
         break;
      }

      default:
         break;
   }
}

//+------------------------------------------------------------------+
//| Fire Alert with cooldown and per-event flag                       |
//+------------------------------------------------------------------+
void FireAlert(ZoneData &z, string eventName, bool enabled, bool &alertedFlag)
{
   if(!enabled || alertedFlag)
      return;

   // Cooldown check
   datetime now = TimeCurrent();
   if(InpAlertCooldownSec > 0 && (now - z.lastAlertTime) < InpAlertCooldownSec)
      return;

   alertedFlag = true;
   z.lastAlertTime = now;

   string msg = StringFormat("%s %s %s | %s %s | Zone [%.5f - %.5f] | %s",
                             _Symbol, TFToString(Period()),
                             DirToString(z.direction),
                             eventName, StateToString(z.state),
                             z.bottom, z.top,
                             TimeToString(z.originTime));

   if(InpAlertPopup)
      Alert(msg);
   if(InpAlertSound)
      PlaySound("alert.wav");
   if(InpAlertPush)
      SendNotification(msg);
   if(InpAlertEmail)
      SendMail("FVG Alert: " + eventName, msg);
}

//+------------------------------------------------------------------+
//| Renderer: Draw or update zone on chart                            |
//+------------------------------------------------------------------+
void RenderZone(ZoneData &z)
{
   if(!InpDrawZones || !IsZoneDrawable(z.state))
      return;

   // Determine right edge time
   datetime rightTime;
   if(InpExtendZones && IsZoneAlive(z.state))
      rightTime = iTime(_Symbol, PERIOD_CURRENT, 0) + PeriodSeconds();
   else
   {
      // Use last relevant event time or origin + some bars
      datetime endTime = z.originTime;
      if(z.fillTime > 0) endTime = z.fillTime;
      else if(z.inversionTime > 0)
      {
         if(z.rejectionTime > 0) endTime = z.rejectionTime;
         else if(z.retestTime > 0) endTime = z.retestTime;
         else endTime = z.inversionTime;
      }
      else if(z.touchTime > 0) endTime = z.touchTime;
      // Extend a few bars past the event
      rightTime = endTime + PeriodSeconds() * 3;
   }

   color zoneColor = GetZoneColor(z);

   // --- Rectangle ---
   if(ObjectFind(0, z.rectName) < 0)
   {
      ObjectCreate(0, z.rectName, OBJ_RECTANGLE, 0,
                   z.originTime, z.top,
                   rightTime, z.bottom);
      ObjectSetInteger(0, z.rectName, OBJPROP_FILL, true);
      ObjectSetInteger(0, z.rectName, OBJPROP_BACK, true);
      ObjectSetInteger(0, z.rectName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, z.rectName, OBJPROP_HIDDEN, true);
   }

   // Update properties
   ObjectSetInteger(0, z.rectName, OBJPROP_COLOR, zoneColor);
   ObjectSetInteger(0, z.rectName, OBJPROP_TIME, 0, z.originTime);
   ObjectSetDouble(0, z.rectName, OBJPROP_PRICE, 0, z.top);
   ObjectSetInteger(0, z.rectName, OBJPROP_TIME, 1, rightTime);
   ObjectSetDouble(0, z.rectName, OBJPROP_PRICE, 1, z.bottom);

   // --- Midline ---
   if(InpDrawMidline)
   {
      double mid = (z.top + z.bottom) / 2.0;
      if(ObjectFind(0, z.midlineName) < 0)
      {
         ObjectCreate(0, z.midlineName, OBJ_TREND, 0,
                      z.originTime, mid, rightTime, mid);
         ObjectSetInteger(0, z.midlineName, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, z.midlineName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, z.midlineName, OBJPROP_BACK, true);
         ObjectSetInteger(0, z.midlineName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, z.midlineName, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, z.midlineName, OBJPROP_RAY_RIGHT, false);
      }
      ObjectSetInteger(0, z.midlineName, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, z.midlineName, OBJPROP_TIME, 0, z.originTime);
      ObjectSetDouble(0, z.midlineName, OBJPROP_PRICE, 0, mid);
      ObjectSetInteger(0, z.midlineName, OBJPROP_TIME, 1, rightTime);
      ObjectSetDouble(0, z.midlineName, OBJPROP_PRICE, 1, mid);
   }

   // --- Label ---
   if(InpDrawLabels)
   {
      double labelPrice = z.top;
      string labelText;
      double gapPoints = (z.top - z.bottom) / _Point;

      if(z.state >= STATE_IFVG_ACTIVE && z.state <= STATE_IFVG_REJECTED)
      {
         labelText = StringFormat("iFVG %s %s %.0fp",
                                  TFToString(Period()),
                                  DirToString(z.ifvgDirection),
                                  gapPoints);
      }
      else
      {
         labelText = StringFormat("FVG %s %s %.0fp %s",
                                  TFToString(Period()),
                                  DirToString(z.direction),
                                  gapPoints,
                                  StateToString(z.state));
      }

      if(ObjectFind(0, z.labelName) < 0)
      {
         ObjectCreate(0, z.labelName, OBJ_TEXT, 0,
                      z.originTime, labelPrice);
         ObjectSetInteger(0, z.labelName, OBJPROP_FONTSIZE, InpLabelFontSize);
         ObjectSetInteger(0, z.labelName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, z.labelName, OBJPROP_HIDDEN, true);
         ObjectSetString(0, z.labelName, OBJPROP_FONT, "Arial");
         ObjectSetInteger(0, z.labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      }
      ObjectSetString(0, z.labelName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, z.labelName, OBJPROP_COLOR, InpLabelColor);
      ObjectSetDouble(0, z.labelName, OBJPROP_PRICE, 0, labelPrice);
      ObjectSetInteger(0, z.labelName, OBJPROP_TIME, 0, z.originTime);
   }
}

//+------------------------------------------------------------------+
//| Cleanup: Remove old/expired zones                                 |
//+------------------------------------------------------------------+
void CleanupZones()
{
   int currentBars = Bars(_Symbol, PERIOD_CURRENT);

   for(int i = g_zoneCount - 1; i >= 0; i--)
   {
      bool shouldRemove = false;

      // Delete filled zones after N bars
      if(InpDeleteFilledAfterBars > 0 && g_zones[i].state == STATE_FILLED)
      {
         if(g_zones[i].filledAtBar > 0 &&
            (currentBars - g_zones[i].filledAtBar) > InpDeleteFilledAfterBars)
            shouldRemove = true;
      }

      // Max zone age
      if(InpMaxZoneAgeBars > 0)
      {
         int originShift = iBarShift(_Symbol, PERIOD_CURRENT, g_zones[i].originTime);
         if(originShift > InpMaxZoneAgeBars)
         {
            if(IsZoneAlive(g_zones[i].state))
            {
               g_zones[i].state = STATE_EXPIRED;
               g_zones[i].expiredAtBar = currentBars;
            }
         }
      }

      // Delete expired zones after N bars
      if(InpDeleteExpiredAfterBars > 0 && g_zones[i].state == STATE_EXPIRED)
      {
         if(g_zones[i].expiredAtBar > 0 &&
            (currentBars - g_zones[i].expiredAtBar) > InpDeleteExpiredAfterBars)
            shouldRemove = true;
      }

      // Also delete invalidated zones that didn't become iFVG
      if(g_zones[i].state == STATE_INVALIDATED)
         shouldRemove = true;

      // Delete rejected iFVGs after some bars
      if(g_zones[i].state == STATE_IFVG_REJECTED && InpDeleteFilledAfterBars > 0)
         shouldRemove = true;

      if(shouldRemove)
         RemoveZone(i);
   }
}

//+------------------------------------------------------------------+
//| Initial scan: detect historical FVGs in lookback range            |
//+------------------------------------------------------------------+
void ScanHistorical()
{
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   int scanStart = MathMin(InpLookbackBars, bars - 4);
   if(scanStart < 1) return;

   // Scan from oldest to newest so state updates are chronological
   for(int shiftC3 = scanStart; shiftC3 >= 1; shiftC3--)
   {
      double bottom, top;
      ENUM_ZONE_DIR dir;
      datetime originTime;

      if(DetectFVG(shiftC3, bottom, top, dir, originTime))
      {
         if(!IsDuplicateZone(originTime, dir))
         {
            ZoneData z;
            ZeroMemory(z);
            z.id         = g_nextId++;
            z.symbol     = _Symbol;
            z.timeframe  = Period();
            z.originTime = originTime;
            z.originBarShift = shiftC3 + 1; // C2 shift
            z.bottom     = bottom;
            z.top        = top;
            z.direction  = dir;
            z.ifvgDirection = dir; // same until inverted
            z.state      = STATE_FRESH;
            z.rectName    = ZoneRectName(z);
            z.midlineName = ZoneMidlineName(z);
            z.labelName   = ZoneLabelName(z);

            int idx = AddZone(z);

            // Now run state machine forward from the bar after C3
            for(int s = shiftC3 - 1; s >= 1; s--)
            {
               UpdateZoneState(g_zones[idx], s);
               if(!IsZoneAlive(g_zones[idx].state) &&
                  g_zones[idx].state != STATE_FILLED &&
                  g_zones[idx].state != STATE_IFVG_REJECTED)
                  break;
            }
         }
      }
   }

   // Enforce max zones
   EnforceMaxZones();
}

//+------------------------------------------------------------------+
//| Incremental scan: detect FVG on newest closed bar                 |
//+------------------------------------------------------------------+
void ScanNewBar()
{
   // The most recent closed bar: C3=1, C2=2, C1=3
   double bottom, top;
   ENUM_ZONE_DIR dir;
   datetime originTime;

   if(DetectFVG(1, bottom, top, dir, originTime))
   {
      if(!IsDuplicateZone(originTime, dir))
      {
         ZoneData z;
         ZeroMemory(z);
         z.id         = g_nextId++;
         z.symbol     = _Symbol;
         z.timeframe  = Period();
         z.originTime = originTime;
         z.originBarShift = 2;
         z.bottom     = bottom;
         z.top        = top;
         z.direction  = dir;
         z.ifvgDirection = dir;
         z.state      = STATE_FRESH;
         z.rectName    = ZoneRectName(z);
         z.midlineName = ZoneMidlineName(z);
         z.labelName   = ZoneLabelName(z);

         AddZone(z);
         FireAlert(z, "New FVG Detected", InpAlertNewFVG, g_zones[g_zoneCount-1].alertedNew);

         EnforceMaxZones();
      }
   }
}

//+------------------------------------------------------------------+
//| Update all alive zones with the latest closed bar                 |
//+------------------------------------------------------------------+
void UpdateAllZones()
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(IsZoneAlive(g_zones[i].state))
         UpdateZoneState(g_zones[i], 1); // bar shift 1 = last closed bar
   }
}

//+------------------------------------------------------------------+
//| Render all zones                                                  |
//+------------------------------------------------------------------+
void RenderAllZones()
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(IsZoneDrawable(g_zones[i].state))
         RenderZone(g_zones[i]);
      else
         DeleteZoneObjects(g_zones[i]);
   }
}

//+------------------------------------------------------------------+
//| Check if new bar has formed                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_prefix = GetPrefix();
   g_zoneCount = 0;
   g_nextId = 1;
   g_lastBarTime = 0;
   g_lastBars = 0;

   ArrayResize(g_zones, 0, 64);

   // ATR handle
   if(InpUseATRFilter)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
      {
         Print("Warning: Failed to create ATR handle. ATR filter disabled.");
      }
   }

   // Clean any leftover objects from previous instance
   DeleteAllObjects();

   // Initial historical scan
   ScanHistorical();
   RenderAllZones();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteAllObjects();

   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }

   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
}

//+------------------------------------------------------------------+
//| OnCalculate                                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // First call or chart reset: do full rescan
   if(prev_calculated == 0)
   {
      // Full reset
      for(int i = g_zoneCount - 1; i >= 0; i--)
         RemoveZone(i);
      g_lastBarTime = 0;
      g_nextId = 1;

      ScanHistorical();
      CleanupZones();
      RenderAllZones();
      // Set last bar time to suppress immediate new bar trigger
      g_lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      return rates_total;
   }

   if(InpEvaluateOnNewBar)
   {
      if(IsNewBar())
      {
         ScanNewBar();
         UpdateAllZones();
         CleanupZones();
         RenderAllZones();
      }
      else
      {
         // Still update rendering for extending zones (cheap)
         if(InpExtendZones)
            RenderAllZones();
      }
   }
   else
   {
      // Every tick (use cautiously)
      bool newBar = IsNewBar();
      if(newBar)
         ScanNewBar();

      UpdateAllZones();

      if(newBar)
         CleanupZones();

      RenderAllZones();
   }

   return rates_total;
}

//+------------------------------------------------------------------+
//| ChartEvent handler (optional future use)                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // Reserved for future interactive features
   // (e.g., clicking a zone to see details, manual deletion, etc.)
}
//+------------------------------------------------------------------+```
