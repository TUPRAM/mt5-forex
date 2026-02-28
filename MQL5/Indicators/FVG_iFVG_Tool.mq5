#property strict
#property indicator_chart_window
#property indicator_plots 0

//+------------------------------------------------------------------+
//| FVG + iFVG lifecycle tool (single-timeframe v1)                 |
//+------------------------------------------------------------------+

enum ENUM_TOUCH_MODE
  {
   TOUCH_WICK = 0,
   TOUCH_BODY = 1
  };

enum ENUM_FILL_MODE
  {
   FILL_WICK_FAR_EDGE = 0,
   FILL_CLOSE_BEYOND_FAR_EDGE = 1
  };

enum ENUM_INVALIDATION_MODE
  {
   INVALIDATE_CLOSE_BEYOND = 0,
   INVALIDATE_WICK_THROUGH = 1
  };

enum ENUM_ZONE_STATE
  {
   STATE_FRESH = 0,
   STATE_TOUCHED,
   STATE_FILLED,
   STATE_INVALIDATED,
   STATE_IFVG_ACTIVE,
   STATE_IFVG_RETESTED,
   STATE_IFVG_REJECTED,
   STATE_EXPIRED,
   STATE_DELETED
  };

input int                    InpLookbackBars = 800;
input int                    InpMaxZones = 120;
input double                 InpMinGapPoints = 50;
input ENUM_TOUCH_MODE        InpTouchMode = TOUCH_WICK;
input ENUM_FILL_MODE         InpFillMode = FILL_WICK_FAR_EDGE;
input ENUM_INVALIDATION_MODE InpInvalidationMode = INVALIDATE_CLOSE_BEYOND;
input bool                   InpEvaluateOnNewBar = true;
input int                    InpDeleteFilledAfterBars = 150;
input int                    InpDeleteAfterDays = 14;
input bool                   InpEnableIFVGRetest = true;
input bool                   InpEnableIFVGRejection = true;

input bool                   InpUseATRFilter = false;
input int                    InpATRPeriod = 14;
input double                 InpATRMultiplier = 1.0;
input bool                   InpUseC2CloseExtremeFilter = false;
input double                 InpC2CloseExtremePct = 70.0;

input bool                   InpDrawMidline = true;
input bool                   InpDrawLabel = true;
input int                    InpExtendBars = 250;
input int                    InpRectangleWidth = 1;
input int                    InpMidlineWidth = 1;
input int                    InpOpacity = 70;

input color                  InpColorBullFresh = clrPaleGreen;
input color                  InpColorBearFresh = clrMistyRose;
input color                  InpColorTouched = clrKhaki;
input color                  InpColorFilled = clrDarkKhaki;
input color                  InpColorIFVG = clrSteelBlue;
input color                  InpColorIFVGRetested = clrMediumPurple;
input color                  InpColorIFVGRejected = clrTomato;

input bool                   InpAlertNewFVG = false;
input bool                   InpAlertFirstTouch = false;
input bool                   InpAlertFill = false;
input bool                   InpAlertInversion = false;
input bool                   InpAlertIFVGRetest = false;
input bool                   InpAlertIFVGRejection = false;
input int                    InpAlertCooldownSec = 30;
input bool                   InpAlertPopup = true;
input bool                   InpAlertSound = false;
input bool                   InpAlertPush = false;
input bool                   InpAlertEmail = false;
input string                 InpAlertSoundFile = "alert.wav";

struct Zone
  {
   string            id;
   string            symbol;
   ENUM_TIMEFRAMES   tf;
   datetime          origin_time;
   double            bottom;
   double            top;
   bool              is_bull; // original FVG direction
   ENUM_ZONE_STATE   state;
   bool              deleted;

   datetime          first_touch_time;
   datetime          fill_time;
   datetime          invalidation_time;
   datetime          retest_time;

   bool              alerted_new;
   bool              alerted_touch;
   bool              alerted_fill;
   bool              alerted_inversion;
   bool              alerted_retest;
   bool              alerted_rejection;
   datetime          last_alert_time;
  };

Zone     g_zones[];
string   g_prefix = "";
datetime g_last_bar_time = 0;
int      g_last_rates_total = 0;

//+------------------------------------------------------------------+
string TfToStr(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1: return "M1";
      case PERIOD_M2: return "M2";
      case PERIOD_M3: return "M3";
      case PERIOD_M4: return "M4";
      case PERIOD_M5: return "M5";
      case PERIOD_M6: return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1: return "H1";
      case PERIOD_H2: return "H2";
      case PERIOD_H3: return "H3";
      case PERIOD_H4: return "H4";
      case PERIOD_H6: return "H6";
      case PERIOD_H8: return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1: return "D1";
      case PERIOD_W1: return "W1";
      case PERIOD_MN1: return "MN1";
      default: return IntegerToString((int)tf);
     }
  }

string StateToStr(ENUM_ZONE_STATE st)
  {
   switch(st)
     {
      case STATE_FRESH: return "FRESH";
      case STATE_TOUCHED: return "TOUCHED";
      case STATE_FILLED: return "FILLED";
      case STATE_INVALIDATED: return "INVALIDATED";
      case STATE_IFVG_ACTIVE: return "IFVG_ACTIVE";
      case STATE_IFVG_RETESTED: return "IFVG_RETESTED";
      case STATE_IFVG_REJECTED: return "IFVG_REJECTED";
      case STATE_EXPIRED: return "EXPIRED";
      case STATE_DELETED: return "DELETED";
      default: return "UNKNOWN";
     }
  }

bool IsIFVGState(ENUM_ZONE_STATE st)
  {
   return (st == STATE_IFVG_ACTIVE || st == STATE_IFVG_RETESTED || st == STATE_IFVG_REJECTED);
  }

bool IsIntersectWick(double bar_low,double bar_high,double z_bottom,double z_top)
  {
   return (bar_low <= z_top && bar_high >= z_bottom);
  }

bool IsIntersectBody(double bar_open,double bar_close,double z_bottom,double z_top)
  {
   double btm = MathMin(bar_open,bar_close);
   double top = MathMax(bar_open,bar_close);
   return (btm <= z_top && top >= z_bottom);
  }

bool TouchesZone(const int shift,const double &open[],const double &high[],const double &low[],const double &close[],const Zone &z)
  {
   if(InpTouchMode == TOUCH_WICK)
      return IsIntersectWick(low[shift],high[shift],z.bottom,z.top);
   return IsIntersectBody(open[shift],close[shift],z.bottom,z.top);
  }

bool FillsZone(const int shift,const double &high[],const double &low[],const double &close[],const Zone &z)
  {
   if(z.is_bull)
     {
      if(InpFillMode == FILL_WICK_FAR_EDGE)
         return (low[shift] <= z.bottom);
      return (close[shift] <= z.bottom);
     }

   if(InpFillMode == FILL_WICK_FAR_EDGE)
      return (high[shift] >= z.top);
   return (close[shift] >= z.top);
  }

bool InvalidatesZone(const int shift,const double &high[],const double &low[],const double &close[],const Zone &z)
  {
   if(z.is_bull)
     {
      if(InpInvalidationMode == INVALIDATE_CLOSE_BEYOND)
         return (close[shift] < z.bottom);
      return (low[shift] < z.bottom);
     }

   if(InpInvalidationMode == INVALIDATE_CLOSE_BEYOND)
      return (close[shift] > z.top);
   return (high[shift] > z.top);
  }

bool RejectionAfterRetest(const int shift,const double &close[],const Zone &z)
  {
   // Bull FVG -> bearish iFVG rejection close back below bottom
   if(z.is_bull)
      return (close[shift] < z.bottom);
   // Bear FVG -> bullish iFVG rejection close back above top
   return (close[shift] > z.top);
  }

string BuildZoneId(datetime origin_time,bool is_bull,double bottom,double top)
  {
   string dir = is_bull ? "BULL" : "BEAR";
   return StringFormat("%s_%s_%I64d_%s_%d_%d",_Symbol,TfToStr((ENUM_TIMEFRAMES)_Period),(long)origin_time,dir,(int)MathRound(bottom/_Point),(int)MathRound(top/_Point));
  }

int FindZoneById(const string id)
  {
   int n = ArraySize(g_zones);
   for(int i=0; i<n; i++)
     {
      if(g_zones[i].id == id)
         return i;
     }
   return -1;
  }

bool ATRPass(const int c3_shift,const double &open[],const double &high[],const double &low[],const double &close[])
  {
   if(!InpUseATRFilter)
      return true;

   int start = c3_shift + 1;
   int end = start + InpATRPeriod - 1;
   if(end >= ArraySize(close))
      return false;

   double sum_tr = 0.0;
   for(int s=start; s<=end; s++)
     {
      double prev_close = close[s+1];
      double tr1 = high[s] - low[s];
      double tr2 = MathAbs(high[s] - prev_close);
      double tr3 = MathAbs(low[s] - prev_close);
      sum_tr += MathMax(tr1,MathMax(tr2,tr3));
     }
   double atr = sum_tr / (double)InpATRPeriod;

   int c2_shift = c3_shift + 1;
   double c2_body = MathAbs(close[c2_shift] - open[c2_shift]);
   if(c2_body < (InpATRMultiplier * atr))
      return false;

   if(InpUseC2CloseExtremeFilter)
     {
      double c2_range = high[c2_shift] - low[c2_shift];
      if(c2_range <= 0.0)
         return false;

      double pct = MathMax(0.0,MathMin(100.0,InpC2CloseExtremePct)) / 100.0;
      if(close[c2_shift] >= open[c2_shift])
        {
         double threshold = high[c2_shift] - c2_range * (1.0 - pct);
         if(close[c2_shift] < threshold)
            return false;
        }
      else
        {
         double threshold = low[c2_shift] + c2_range * (1.0 - pct);
         if(close[c2_shift] > threshold)
            return false;
        }
     }

   return true;
  }

bool AlertAllowed(Zone &z)
  {
   if(InpAlertCooldownSec <= 0)
      return true;
   if(z.last_alert_time == 0)
      return true;
   return ((TimeCurrent() - z.last_alert_time) >= InpAlertCooldownSec);
  }

void EmitAlert(const string msg)
  {
   if(InpAlertPopup)
      Alert(msg);
   if(InpAlertSound)
      PlaySound(InpAlertSoundFile);
   if(InpAlertPush)
      SendNotification(msg);
   if(InpAlertEmail)
      SendMail("FVG_iFVG_Tool",msg);
  }

void AlertEvent(Zone &z,const string event_name,bool &already_sent)
  {
   if(already_sent)
      return;
   if(!AlertAllowed(z))
      return;

   string msg = StringFormat("[%s %s] %s | zone=%s | [%.5f, %.5f]",z.symbol,TfToStr(z.tf),event_name,z.id,z.bottom,z.top);
   EmitAlert(msg);
   z.last_alert_time = TimeCurrent();
   already_sent = true;
  }

void TriggerConfiguredAlerts(Zone &z,const string event_name)
  {
   if(event_name == "NEW_FVG" && InpAlertNewFVG)
      AlertEvent(z,event_name,z.alerted_new);
   else if(event_name == "FIRST_TOUCH" && InpAlertFirstTouch)
      AlertEvent(z,event_name,z.alerted_touch);
   else if(event_name == "FILL" && InpAlertFill)
      AlertEvent(z,event_name,z.alerted_fill);
   else if(event_name == "INVERSION_IFVG" && InpAlertInversion)
      AlertEvent(z,event_name,z.alerted_inversion);
   else if(event_name == "IFVG_RETEST" && InpAlertIFVGRetest)
      AlertEvent(z,event_name,z.alerted_retest);
   else if(event_name == "IFVG_REJECTION" && InpAlertIFVGRejection)
      AlertEvent(z,event_name,z.alerted_rejection);
  }

void DeleteZoneObjects(const Zone &z)
  {
   ObjectDelete(0,g_prefix + z.id + "_RECT");
   ObjectDelete(0,g_prefix + z.id + "_MID");
   ObjectDelete(0,g_prefix + z.id + "_LBL");
  }

color ZoneColor(const Zone &z)
  {
   if(z.state == STATE_IFVG_REJECTED)
      return InpColorIFVGRejected;
   if(z.state == STATE_IFVG_RETESTED)
      return InpColorIFVGRetested;
   if(IsIFVGState(z.state) || z.state == STATE_INVALIDATED)
      return InpColorIFVG;
   if(z.state == STATE_FILLED)
      return InpColorFilled;
   if(z.state == STATE_TOUCHED)
      return InpColorTouched;
   return z.is_bull ? InpColorBullFresh : InpColorBearFresh;
  }

void DrawOrUpdateZone(const Zone &z,datetime now_time)
  {
   if(z.deleted || z.state == STATE_DELETED || z.state == STATE_EXPIRED)
      return;

   string rect_name = g_prefix + z.id + "_RECT";
   string mid_name = g_prefix + z.id + "_MID";
   string lbl_name = g_prefix + z.id + "_LBL";

   datetime t1 = z.origin_time;
   datetime t2 = now_time + (datetime)(PeriodSeconds((ENUM_TIMEFRAMES)_Period) * InpExtendBars);
   color c = ZoneColor(z);
   long argb = ColorToARGB(c,(uchar)MathMax(0,MathMin(255,(int)MathRound(255.0 * (InpOpacity / 100.0)))));

   if(ObjectFind(0,rect_name) < 0)
      ObjectCreate(0,rect_name,OBJ_RECTANGLE,0,t1,z.bottom,t2,z.top);

   ObjectSetInteger(0,rect_name,OBJPROP_TIME,0,t1);
   ObjectSetDouble(0,rect_name,OBJPROP_PRICE,0,z.bottom);
   ObjectSetInteger(0,rect_name,OBJPROP_TIME,1,t2);
   ObjectSetDouble(0,rect_name,OBJPROP_PRICE,1,z.top);
   ObjectSetInteger(0,rect_name,OBJPROP_COLOR,(color)argb);
   ObjectSetInteger(0,rect_name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,rect_name,OBJPROP_WIDTH,InpRectangleWidth);
   ObjectSetInteger(0,rect_name,OBJPROP_FILL,true);
   ObjectSetInteger(0,rect_name,OBJPROP_BACK,true);

   if(InpDrawMidline)
     {
      double mid = (z.bottom + z.top) * 0.5;
      if(ObjectFind(0,mid_name) < 0)
         ObjectCreate(0,mid_name,OBJ_TREND,0,t1,mid,t2,mid);
      ObjectSetInteger(0,mid_name,OBJPROP_TIME,0,t1);
      ObjectSetDouble(0,mid_name,OBJPROP_PRICE,0,mid);
      ObjectSetInteger(0,mid_name,OBJPROP_TIME,1,t2);
      ObjectSetDouble(0,mid_name,OBJPROP_PRICE,1,mid);
      ObjectSetInteger(0,mid_name,OBJPROP_COLOR,c);
      ObjectSetInteger(0,mid_name,OBJPROP_WIDTH,InpMidlineWidth);
      ObjectSetInteger(0,mid_name,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,mid_name,OBJPROP_RAY,false);
     }
   else
      ObjectDelete(0,mid_name);

   if(InpDrawLabel)
     {
      string kind = IsIFVGState(z.state) || z.state == STATE_INVALIDATED ? "iFVG" : "FVG";
      string txt = StringFormat("%s %s | %s | %.1f pts",kind,TfToStr((ENUM_TIMEFRAMES)_Period),StateToStr(z.state),(z.top-z.bottom)/_Point);
      if(ObjectFind(0,lbl_name) < 0)
         ObjectCreate(0,lbl_name,OBJ_TEXT,0,t2,z.top);
      ObjectSetInteger(0,lbl_name,OBJPROP_TIME,0,t2);
      ObjectSetDouble(0,lbl_name,OBJPROP_PRICE,0,z.top);
      ObjectSetString(0,lbl_name,OBJPROP_TEXT,txt);
      ObjectSetInteger(0,lbl_name,OBJPROP_COLOR,c);
      ObjectSetInteger(0,lbl_name,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,lbl_name,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,lbl_name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
     }
   else
      ObjectDelete(0,lbl_name);
  }

void MarkDeleted(Zone &z)
  {
   z.deleted = true;
   z.state = STATE_DELETED;
   DeleteZoneObjects(z);
  }

void EnforceMaxZones()
  {
   while(ArraySize(g_zones) > InpMaxZones)
     {
      int oldest_idx = -1;
      datetime oldest = D'3000.01.01 00:00';
      for(int i=0; i<ArraySize(g_zones); i++)
        {
         if(g_zones[i].deleted)
            continue;
         if(g_zones[i].origin_time < oldest)
           {
            oldest = g_zones[i].origin_time;
            oldest_idx = i;
           }
        }
      if(oldest_idx < 0)
         break;
      MarkDeleted(g_zones[oldest_idx]);
     }
  }

void CompactDeletedZones()
  {
   Zone kept[];
   ArrayResize(kept,0);
   for(int i=0; i<ArraySize(g_zones); i++)
     {
      if(g_zones[i].deleted)
         continue;
      int n = ArraySize(kept);
      ArrayResize(kept,n+1);
      kept[n] = g_zones[i];
     }
   g_zones = kept;
  }

void ExpireOldZones(datetime now_time)
  {
   for(int i=0; i<ArraySize(g_zones); i++)
     {
      if(g_zones[i].deleted)
         continue;

      bool should_delete = false;
      if(InpDeleteFilledAfterBars > 0 && g_zones[i].fill_time > 0)
        {
         int bars_since_fill = iBarShift(_Symbol,(ENUM_TIMEFRAMES)_Period,g_zones[i].fill_time,false) - iBarShift(_Symbol,(ENUM_TIMEFRAMES)_Period,now_time,false);
         if(bars_since_fill >= InpDeleteFilledAfterBars)
            should_delete = true;
        }

      if(InpDeleteAfterDays > 0)
        {
         long seconds_alive = (long)(now_time - g_zones[i].origin_time);
         if(seconds_alive >= (long)InpDeleteAfterDays * 86400)
            should_delete = true;
        }

      if(should_delete)
        {
         g_zones[i].state = STATE_EXPIRED;
         MarkDeleted(g_zones[i]);
        }
     }
   CompactDeletedZones();
  }

void AddZone(datetime origin_time,bool is_bull,double bottom,double top)
  {
   if(top <= bottom)
      return;
   if((top - bottom) < InpMinGapPoints * _Point)
      return;

   string id = BuildZoneId(origin_time,is_bull,bottom,top);
   if(FindZoneById(id) >= 0)
      return;

   Zone z;
   z.id = id;
   z.symbol = _Symbol;
   z.tf = (ENUM_TIMEFRAMES)_Period;
   z.origin_time = origin_time;
   z.bottom = bottom;
   z.top = top;
   z.is_bull = is_bull;
   z.state = STATE_FRESH;
   z.deleted = false;

   z.first_touch_time = 0;
   z.fill_time = 0;
   z.invalidation_time = 0;
   z.retest_time = 0;

   z.alerted_new = false;
   z.alerted_touch = false;
   z.alerted_fill = false;
   z.alerted_inversion = false;
   z.alerted_retest = false;
   z.alerted_rejection = false;
   z.last_alert_time = 0;

   int n = ArraySize(g_zones);
   ArrayResize(g_zones,n+1);
   g_zones[n] = z;

   TriggerConfiguredAlerts(g_zones[n],"NEW_FVG");
   EnforceMaxZones();
  }

void ProcessZoneOnBar(Zone &z,const int shift,const datetime bar_time,const double &open[],const double &high[],const double &low[],const double &close[])
  {
   if(z.deleted)
      return;
   if(bar_time <= z.origin_time)
      return;

   if(z.state == STATE_INVALIDATED)
      z.state = STATE_IFVG_ACTIVE;

   bool intersects = TouchesZone(shift,open,high,low,close,z);

   if(!IsIFVGState(z.state))
     {
      if(z.first_touch_time == 0 && intersects)
        {
         z.first_touch_time = bar_time;
         if(z.state == STATE_FRESH)
            z.state = STATE_TOUCHED;
         TriggerConfiguredAlerts(z,"FIRST_TOUCH");
        }

      if(z.fill_time == 0 && FillsZone(shift,high,low,close,z))
        {
         z.fill_time = bar_time;
         z.state = STATE_FILLED;
         TriggerConfiguredAlerts(z,"FILL");
        }

      if(InvalidatesZone(shift,high,low,close,z))
        {
         z.invalidation_time = bar_time;
         z.state = STATE_INVALIDATED;
         TriggerConfiguredAlerts(z,"INVERSION_IFVG");
         z.state = STATE_IFVG_ACTIVE;
        }
      return;
     }

   if(InpEnableIFVGRetest && z.retest_time == 0 && z.invalidation_time > 0 && bar_time > z.invalidation_time && intersects)
     {
      z.retest_time = bar_time;
      z.state = STATE_IFVG_RETESTED;
      TriggerConfiguredAlerts(z,"IFVG_RETEST");
     }

   if(InpEnableIFVGRejection && z.retest_time > 0 && bar_time >= z.retest_time && RejectionAfterRetest(shift,close,z))
     {
      if(z.state != STATE_IFVG_REJECTED)
        {
         z.state = STATE_IFVG_REJECTED;
         TriggerConfiguredAlerts(z,"IFVG_REJECTION");
        }
     }
  }

void ProcessExistingZonesForBar(const int shift,const datetime bar_time,const double &open[],const double &high[],const double &low[],const double &close[])
  {
   for(int i=0; i<ArraySize(g_zones); i++)
      ProcessZoneOnBar(g_zones[i],shift,bar_time,open,high,low,close);
  }

void DetectAtShift(const int c3_shift,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[])
  {
   int c2_shift = c3_shift + 1;
   int c1_shift = c3_shift + 2;
   if(c1_shift >= ArraySize(time))
      return;

   if(!ATRPass(c3_shift,open,high,low,close))
      return;

   // Bullish FVG: High(C1) < Low(C3)
   if(high[c1_shift] < low[c3_shift])
      AddZone(time[c3_shift],true,high[c1_shift],low[c3_shift]);

   // Bearish FVG: Low(C1) > High(C3)
   if(low[c1_shift] > high[c3_shift])
      AddZone(time[c3_shift],false,high[c3_shift],low[c1_shift]);
  }

void BootstrapHistory(const int rates_total,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[])
  {
   int max_c3_shift = MathMin(InpLookbackBars,rates_total-3);
   if(max_c3_shift < 1)
      return;

   for(int s=max_c3_shift; s>=1; s--)
      DetectAtShift(s,time,open,high,low,close);

   for(int i=ArraySize(g_zones)-1; i>=0; i--)
     {
      int origin_shift = iBarShift(_Symbol,(ENUM_TIMEFRAMES)_Period,g_zones[i].origin_time,false);
      if(origin_shift < 0)
         continue;
      for(int s=origin_shift-1; s>=1; s--)
         ProcessZoneOnBar(g_zones[i],s,time[s],open,high,low,close);
     }
  }

void RedrawAllZones(datetime now_time)
  {
   for(int i=0; i<ArraySize(g_zones); i++)
      DrawOrUpdateZone(g_zones[i],now_time);
  }

void DeleteAllPrefixedObjects()
  {
   int total = ObjectsTotal(0,0,-1);
   for(int i=total-1; i>=0; i--)
     {
      string name = ObjectName(0,i,0,-1);
      if(StringFind(name,g_prefix,0) == 0)
         ObjectDelete(0,name);
     }
  }

int OnInit()
  {
   g_prefix = StringFormat("FVGIFVG_%s_%s_",_Symbol,TfToStr((ENUM_TIMEFRAMES)_Period));
   ArrayResize(g_zones,0);
   DeleteAllPrefixedObjects();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   DeleteAllPrefixedObjects();
  }

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
   if(rates_total < 5)
      return rates_total;

   bool first_run = (prev_calculated == 0 || g_last_rates_total == 0 || ArraySize(g_zones) == 0);
   bool is_new_bar = (g_last_bar_time != time[0]);

   if(first_run)
     {
      BootstrapHistory(rates_total,time,open,high,low,close);
      g_last_bar_time = time[0];
      g_last_rates_total = rates_total;
      ExpireOldZones(time[1]);
      RedrawAllZones(time[1]);
      return rates_total;
     }

   if(InpEvaluateOnNewBar)
     {
      if(is_new_bar)
        {
         ProcessExistingZonesForBar(1,time[1],open,high,low,close);
         DetectAtShift(1,time,open,high,low,close);
         ExpireOldZones(time[1]);
        }
     }
   else
     {
      ProcessExistingZonesForBar(1,time[1],open,high,low,close);
      DetectAtShift(1,time,open,high,low,close);
      ExpireOldZones(time[1]);
     }

   RedrawAllZones(time[1]);

   g_last_bar_time = time[0];
   g_last_rates_total = rates_total;
   return rates_total;
  }
//+------------------------------------------------------------------+
