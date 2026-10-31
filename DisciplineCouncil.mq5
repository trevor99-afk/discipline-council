#property copyright "Discipline Desk"
#property version "2.00"
#property description "War Council: KING (risk), SAMURAI (emotions), SNIPER (level), STRATEGIST (timing/news), WOLF (trend)."
#property description "All 5 must say YES or the trade is not sent. Trades placed outside the Council are closed."
#property description "Also: risk cap 0.5-1%, mandatory SL, no SL widening, daily limits, cooldown, CSV journal."

#include <Trade/Trade.mqh>

#define PFX "DD_"
#define MAGIC 20261031
#define JOURNAL_FILE "DisciplineDesk_journal.csv"
#define VIOLATIONS_FILE "DisciplineDesk_violations.csv"
#define COUNCIL_FILE "DisciplineDesk_council.csv"

input group "War Council"
input bool InpCouncilOnly = true; // Close any trade that did not pass the Council (phone, one-click...)
input double InpMinRR = 2.0; // KING: minimum reward:risk (2.0 = 1:2)
input int InpMinState = 6; // SAMURAI: minimum mental state (1-10)
input double InpLevelZone = 2.0; // SNIPER: max distance from your marked level (gold: 2.0 = $2)
input double InpMaxSpread = 0.60; // SNIPER: max spread in price (gold: 0.60 = 60 cents)
input int InpSession1Start = 7; // STRATEGIST: session 1 start hour (server time)
input int InpSession1End = 11; // STRATEGIST: session 1 end hour
input int InpSession2Start = 13; // STRATEGIST: session 2 start hour
input int InpSession2End = 17; // STRATEGIST: session 2 end hour
input int InpNewsMinutes = 30; // STRATEGIST: no trade +/- N min around high-impact news
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H4; // WOLF: trend timeframe
input int InpFastEMA = 50; // WOLF: fast EMA
input int InpSlowEMA = 200; // WOLF: slow EMA
input double InpDefaultSL = 5.0; // Panel default SL distance (gold: 5.0 = $5)
input double InpDefaultTP = 10.0; // Panel default TP distance

input group "Risk per trade"
input double InpRiskPercent = 1.0; // Risk per trade, % of day-start balance (forced 0.5-1.0)
input double InpRiskTolerance = 1.10; // Slack for lot rounding (1.10 = +10%)

input group "Daily limits"
input int InpMaxTradesPerDay = 3; // Max new trades per day
input int InpMaxLossesPerDay = 2; // Losing trades before lockout
input double InpDailyLossPct = 2.0; // Daily loss limit % (closed + floating)
input double InpDailyProfitStopR = 0.0; // Stop for the day after +N R (0 = off)
input int InpCooldownMinutes = 15; // Mandatory break after a losing trade

input group "Stop loss"
input int InpSLGraceSeconds = 30; // Seconds allowed to attach an SL (non-Council trades)

input group "Journal"
input bool InpWriteJournal = true; // Write trades, violations and Council votes to CSV

struct PosRecord
  {
   ulong ticket;
   double sl;
   datetime seen;
   bool checked;
  };

struct DayStats
  {
   int trades;
   int losses;
   double closedPL;
   datetime lastLoss;
  };

CTrade g_trade;
PosRecord g_pos[];
double g_riskPct = 1.0;
int g_violations = 0;
datetime g_violDay = 0;
string g_lastMsg = "none";

int g_dir = 1;
int g_hFast = INVALID_HANDLE;
int g_hSlow = INVALID_HANDLE;
int g_state = 0;
datetime g_stateDay = 0;
string g_verdict = "Waiting for your request.";
color g_verdictClr = clrSilver;

datetime g_newsAt = 0;
bool g_newsHit = false;
string g_newsWhat = "";

string g_agent[5] = {"KING", "SAMURAI", "SNIPER", "STRATEGIST", "WOLF"};

int OnInit()
  {
   g_riskPct = MathMax(0.5, MathMin(1.0, InpRiskPercent));
   if(MathAbs(g_riskPct - InpRiskPercent) > 1e-9)
      Alert("Discipline Council: risk forced to ", DoubleToString(g_riskPct, 2), "% (allowed range 0.5-1%).");

   g_trade.SetDeviationInPoints(100);
   g_trade.SetAsyncMode(false);
   g_trade.SetExpertMagicNumber(MAGIC);

   g_hFast = iMA(_Symbol, InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(GlobalVariableCheck("DD_state"))
     {
      g_state = (int)GlobalVariableGet("DD_state");
      g_stateDay = (datetime)GlobalVariableGet("DD_stateDay");
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      AddPos(t, sl, true);
      if(sl <= 0)
         Alert("Discipline Council: position #", t, " has NO stop loss. Add one within ",
               InpSLGraceSeconds, "s or it will be closed.");
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      Alert("Discipline Council: turn ON 'Algo Trading', otherwise the Council cannot protect you.");

   BuildPanel();
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   if(g_hFast != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   ChartRedraw();
  }

void OnTimer() { Guard(); }

void OnTradeTransaction(const MqlTradeTransaction &tx,
                        const MqlTradeRequest &rq,
                        const MqlTradeResult &rs)
  {
   if(tx.type == TRADE_TRANSACTION_DEAL_ADD && InpWriteJournal)
      JournalDeal(tx.deal);
   Guard();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == PFX + "buy") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); Request(1); }
      else if(sparam == PFX + "sell") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); Request(-1); }
      else if(sparam == PFX + "minus") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); ChangeState(-1); }
      else if(sparam == PFX + "plus") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); ChangeState(1); }
      else if(sparam == PFX + "vbuy") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); g_dir = 1; }
      else if(sparam == PFX + "vsell") { ObjectSetInteger(0, sparam, OBJPROP_STATE, false); g_dir = -1; }
      Guard();
     }
   else if(id == CHARTEVENT_OBJECT_ENDEDIT)
      Guard();
  }

int Evaluate(int dir, DayStats &s, double riskMoney, double lossLimit,
             bool &ok[], string &why[], double &lots)
  {
   double slD = StringToDouble(ObjectGetString(0, PFX + "sl", OBJPROP_TEXT));
   double tpD = StringToDouble(ObjectGetString(0, PFX + "tp", OBJPROP_TEXT));
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (dir > 0) ? ask : bid;
   long ptype = (dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   lots = 0;

   ok[0] = false;
   if(slD <= 0)
      why[0] = "set a stop-loss distance";
   else
     {
      double rpl = RiskMoney(_Symbol, ptype, 1.0, entry, entry - dir * slD);
      if(rpl > 0)
         lots = NormalizeVol(_Symbol, riskMoney / rpl);
      double rr = (tpD > 0) ? tpD / slD : 0;
      if(rpl <= 0)
         why[0] = "cannot price the risk";
      else if(lots < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         why[0] = "SL too wide for 1R even at min lot";
      else if(rr < InpMinRR)
         why[0] = StringFormat("R:R 1:%.1f is below 1:%.1f", rr, InpMinRR);
      else if(s.closedPL <= -lossLimit)
         why[0] = "daily loss limit hit - capital first";
      else if(InpDailyProfitStopR > 0 && s.closedPL >= InpDailyProfitStopR * riskMoney)
         why[0] = "day target reached - protect it";
      else
        {
         ok[0] = true;
         why[0] = StringFormat("1R=%.2f  %.2f lots  R:R 1:%.1f", riskMoney, lots, rr);
        }
     }

   ok[1] = false;
   bool stateSet = (g_stateDay == DayStart());
   long cdLeft = (s.lastLoss > 0) ? (long)(s.lastLoss + InpCooldownMinutes * 60 - TimeCurrent()) : 0;
   if(!stateSet)
      why[1] = "rate your mental state first (- / +)";
   else if(g_state < InpMinState)
      why[1] = StringFormat("state %d/10 - observe only today", g_state);
   else if(cdLeft > 0)
      why[1] = StringFormat("cooldown %d:%02d - breathe, walk away", (int)(cdLeft / 60), (int)(cdLeft % 60));
   else if(s.losses >= InpMaxLossesPerDay)
      why[1] = StringFormat("%d losses today - no revenge", s.losses);
   else if(s.trades >= InpMaxTradesPerDay)
      why[1] = "trade quota used - no overtrading";
   else
     {
      ok[1] = true;
      why[1] = StringFormat("calm and ready (state %d/10)", g_state);
     }

   ok[2] = false;
   double spread = ask - bid;
   double dist = 0;
   if(spread > InpMaxSpread)
      why[2] = "spread " + DoubleToString(spread, dg) + " too wide";
   else if(!NearestLevel(entry, dist))
      why[2] = "no levels marked (draw H-lines / zones)";
   else if(dist > InpLevelZone)
      why[2] = DoubleToString(dist, dg) + " away from your level - wait";
   else
     {
      ok[2] = true;
      why[2] = (dist == 0) ? "price inside your zone" : "at your level (" + DoubleToString(dist, dg) + " away)";
     }

   ok[3] = false;
   MqlDateTime t;
   TimeToStruct(TimeTradeServer(), t);
   bool inSession = (t.hour >= InpSession1Start && t.hour < InpSession1End) ||
                    (t.hour >= InpSession2Start && t.hour < InpSession2End);
   string news = "";
   if(!inSession)
      why[3] = StringFormat("%02d:%02d is outside your sessions", t.hour, t.min);
   else if(NewsNear(news))
      why[3] = "red news: " + news;
   else
     {
      ok[3] = true;
      why[3] = "good session, no red news";
     }

   ok[4] = false;
   double f[], sl[];
   if(CopyBuffer(g_hFast, 0, 0, 1, f) < 1 || CopyBuffer(g_hSlow, 0, 0, 1, sl) < 1)
      why[4] = "trend data loading...";
   else
     {
      string tf = StringSubstr(EnumToString(InpTrendTF), 7);
      bool up = (entry > sl[0] && f[0] > sl[0]);
      bool dn = (entry < sl[0] && f[0] < sl[0]);
      if(dir > 0 && up) { ok[4] = true; why[4] = tf + " trend UP - buying with it"; }
      else if(dir < 0 && dn) { ok[4] = true; why[4] = tf + " trend DOWN - selling with it"; }
      else if(up) why[4] = tf + " trend UP - no selling against it";
      else if(dn) why[4] = tf + " trend DOWN - no buying against it";
      else why[4] = tf + " no clear trend - stay out";
     }

   int no = 0;
   for(int i = 0; i < 5; i++)
      if(!ok[i])
         no++;
   return no;
  }

void Request(int dir)
  {
   g_dir = dir;
   DayStats s;
   GetDayStats(s);
   double dayBal = AccountInfoDouble(ACCOUNT_BALANCE) - s.closedPL;
   double riskMoney = dayBal * g_riskPct / 100.0;
   double lossLimit = dayBal * InpDailyLossPct / 100.0;

   bool ok[5];
   string why[5];
   double lots = 0;
   int no = Evaluate(dir, s, riskMoney, lossLimit, ok, why, lots);
   string d = (dir > 0) ? "BUY" : "SELL";

   string votes = "";
   for(int i = 0; i < 5; i++)
      votes += g_agent[i] + "=" + (ok[i] ? "YES" : "NO (" + why[i] + ")") + "; ";

   if(no > 0)
     {
      g_verdict = StringFormat("REJECTED %s - %d agent(s) said NO. No trade.", d, no);
      g_verdictClr = clrTomato;
      Alert("War Council: ", d, " REJECTED. The sniper waits.");
      CouncilLog(d, "REJECTED", votes);
      return;
     }

   double slD = StringToDouble(ObjectGetString(0, PFX + "sl", OBJPROP_TEXT));
   double tpD = StringToDouble(ObjectGetString(0, PFX + "tp", OBJPROP_TEXT));
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool sent;
   if(dir > 0)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sent = g_trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(ask - slD, dg),
                         NormalizeDouble(ask + tpD, dg), "Council 5/5");
     }
   else
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sent = g_trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(bid + slD, dg),
                          NormalizeDouble(bid - tpD, dg), "Council 5/5");
     }

   if(sent && (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      g_verdict = StringFormat("APPROVED 5/5 - %s %.2f lots sent. Hands off now.", d, lots);
      g_verdictClr = clrLimeGreen;
      CouncilLog(d, "APPROVED", votes);
     }
   else
     {
      g_verdict = "Approved, but order failed: " + g_trade.ResultRetcodeDescription();
      g_verdictClr = clrOrange;
      CouncilLog(d, "ORDER FAILED", g_trade.ResultRetcodeDescription());
     }
  }

void ChangeState(int delta)
  {
   if(g_stateDay != DayStart())
     {
      g_state = 5;
      g_stateDay = DayStart();
     }
   g_state = MathMax(1, MathMin(10, g_state + delta));
   GlobalVariableSet("DD_state", g_state);
   GlobalVariableSet("DD_stateDay", (double)g_stateDay);
  }

bool NearestLevel(double price, double &best)
  {
   best = DBL_MAX;
   bool found = false;
   int n = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < n; i++)
     {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, PFX) == 0)
         continue;
      long type = ObjectGetInteger(0, name, OBJPROP_TYPE);
      if(type == OBJ_HLINE)
        {
         double p = ObjectGetDouble(0, name, OBJPROP_PRICE, 0);
         best = MathMin(best, MathAbs(price - p));
         found = true;
        }
      else if(type == OBJ_RECTANGLE)
        {
         double p1 = ObjectGetDouble(0, name, OBJPROP_PRICE, 0);
         double p2 = ObjectGetDouble(0, name, OBJPROP_PRICE, 1);
         double lo = MathMin(p1, p2), hi = MathMax(p1, p2);
         double d = (price >= lo && price <= hi) ? 0 : MathMin(MathAbs(price - lo), MathAbs(price - hi));
         best = MathMin(best, d);
         found = true;
        }
     }
   return found;
  }

bool NewsNear(string &what)
  {
   if(TimeCurrent() - g_newsAt < 60)
     {
      what = g_newsWhat;
      return g_newsHit;
     }
   g_newsAt = TimeCurrent();
   g_newsHit = false;
   g_newsWhat = "";

   datetime now = TimeTradeServer();
   string cur[2];
   cur[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   cur[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   for(int c = 0; c < 2 && !g_newsHit; c++)
     {
      MqlCalendarValue v[];
      if(!CalendarValueHistory(v, now - InpNewsMinutes * 60, now + InpNewsMinutes * 60, NULL, cur[c]))
         continue;
      for(int i = 0; i < ArraySize(v); i++)
        {
         MqlCalendarEvent ev;
         if(CalendarEventById(v[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            g_newsHit = true;
            g_newsWhat = StringSubstr(ev.name, 0, 26) + " " + TimeToString(v[i].time, TIME_MINUTES);
            break;
           }
        }
     }
   what = g_newsWhat;
   return g_newsHit;
  }

void Guard()
  {
   DayStats s;
   GetDayStats(s);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayBal = bal - s.closedPL;
   double riskMoney = dayBal * g_riskPct / 100.0;
   double lossLimit = dayBal * InpDailyLossPct / 100.0;

   double floating = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0)
         floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   if(s.closedPL + floating <= -lossLimit && PositionsTotal() > 0)
      CloseAll("Daily loss limit hit: all positions closed. Platform OFF for today.");

   string lock = EntryLock(s, riskMoney, lossLimit);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong o = OrderGetTicket(i);
      if(o == 0)
         continue;
      string why = "";
      if(InpCouncilOnly && OrderGetInteger(ORDER_MAGIC) != MAGIC)
         why = "did not pass the War Council";
      else if(lock != "")
         why = lock;
      else if(s.trades >= InpMaxTradesPerDay)
         why = "max trades per day reached";
      if(why != "" && g_trade.OrderDelete(o))
         Notify("Pending order deleted - " + why, true);
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      long magic = PositionGetInteger(POSITION_MAGIC);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double eps = SymbolInfoDouble(sym, SYMBOL_POINT) * 0.5;

      int k = FindPos(t);

      if(k < 0)
        {
         string why = "";
         if(magic != MAGIC)
           {
            if(InpCouncilOnly)
               why = "trade bypassed the War Council";
            else if(lock != "")
               why = lock;
            else if(s.trades > InpMaxTradesPerDay)
               why = "max trades per day already taken";
           }
         if(why != "")
           {
            ClosePos(t, "Entry blocked - " + why);
            continue;
           }
         AddPos(t, sl, false);
         k = ArraySize(g_pos) - 1;
        }

      if(g_pos[k].sl <= 0)
        {
         if(sl > 0)
            g_pos[k].sl = sl;
         else
           {
            if(TimeCurrent() - g_pos[k].seen > InpSLGraceSeconds)
               ClosePos(t, "No stop loss within " + IntegerToString(InpSLGraceSeconds) + "s");
            continue;
           }
        }

      if(!g_pos[k].checked)
        {
         g_pos[k].checked = true;
         double r = RiskMoney(sym, type, vol, open, g_pos[k].sl);
         if(r > riskMoney * InpRiskTolerance)
           {
            double okVol = NormalizeVol(sym, vol * riskMoney / r);
            double minV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            if(okVol < minV)
              {
               ClosePos(t, "Risk too big: SL too wide even at minimum lot");
               continue;
              }
            double cut = NormalizeVol(sym, vol - okVol);
            if(cut >= minV && g_trade.PositionClosePartial(t, cut))
               Notify(StringFormat("Oversized: %.2f lots cut to %.2f", vol, okVol), true);
           }
        }

      bool widened = (sl <= 0) ||
                     (type == POSITION_TYPE_BUY && sl < g_pos[k].sl - eps) ||
                     (type == POSITION_TYPE_SELL && sl > g_pos[k].sl + eps);
      if(widened)
        {
         if(g_trade.PositionModify(t, g_pos[k].sl, tp))
            Notify("SL widened/removed on #" + (string)t + " - restored", true);
         else
            ClosePos(t, "SL moved and could not be restored");
        }
      else if(MathAbs(sl - g_pos[k].sl) > eps)
         g_pos[k].sl = sl;
     }

   PrunePos();
   UpdatePanel(s, dayBal, riskMoney, lossLimit, floating, lock);
  }

string EntryLock(DayStats &s, double riskMoney, double lossLimit)
  {
   if(s.closedPL <= -lossLimit)
      return "Daily loss limit reached";
   if(s.losses >= InpMaxLossesPerDay)
      return IntegerToString(s.losses) + " losses today - done for the day";
   if(InpDailyProfitStopR > 0 && s.closedPL >= InpDailyProfitStopR * riskMoney)
      return "Profit target reached - the King protects his capital";
   if(s.lastLoss > 0 && TimeCurrent() < s.lastLoss + InpCooldownMinutes * 60)
      return "Cooldown after a loss";
   return "";
  }

void GetDayStats(DayStats &s)
  {
   s.trades = 0;
   s.losses = 0;
   s.closedPL = 0;
   s.lastLoss = 0;
   if(!HistorySelect(DayStart(), TimeCurrent() + 3600))
      return;

   ulong ids[];
   double pl[];
   datetime outT[];
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;

      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
               + HistoryDealGetDouble(d, DEAL_COMMISSION);
      s.closedPL += p;

      if(entry == DEAL_ENTRY_IN)
        {
         s.trades++;
         continue;
        }

      ulong pid = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < ArraySize(ids); j++)
         if(ids[j] == pid) { k = j; break; }
      if(k < 0)
        {
         k = ArraySize(ids);
         ArrayResize(ids, k + 1);
         ArrayResize(pl, k + 1);
         ArrayResize(outT, k + 1);
         ids[k] = pid;
         pl[k] = 0;
        }
      pl[k] += p;
      outT[k] = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
     }

   for(int k = 0; k < ArraySize(ids); k++)
     {
      if(PositionSelectByTicket(ids[k]))
         continue;
      if(pl[k] < 0)
        {
         s.losses++;
         if(outT[k] > s.lastLoss)
            s.lastLoss = outT[k];
        }
     }
  }

void ClosePos(ulong t, string why)
  {
   if(g_trade.PositionClose(t))
      Notify(why + " (#" + (string)t + " closed)", true);
   else
      Print("Discipline Council: close failed #", t, " retcode ", g_trade.ResultRetcode());
  }

void CloseAll(string why)
  {
   bool any = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && g_trade.PositionClose(t))
         any = true;
     }
   if(any)
      Notify(why, false);
  }

void Notify(string msg, bool isViolation)
  {
   if(DayStart() != g_violDay)
     {
      g_violDay = DayStart();
      g_violations = 0;
     }
   if(isViolation)
      g_violations++;
   g_lastMsg = TimeToString(TimeCurrent(), TIME_MINUTES) + " " + msg;
   Alert("Discipline Council: ", msg);
   SendNotification("Discipline Council: " + msg);
   if(InpWriteJournal)
      AppendCsv(VIOLATIONS_FILE, "Time,Type,Message",
                TimeToString(TimeCurrent()) + "," + (isViolation ? "VIOLATION" : "RULE") + "," + Quote(msg));
  }

void CouncilLog(string dir, string verdict, string details)
  {
   if(InpWriteJournal)
      AppendCsv(COUNCIL_FILE, "Time,Symbol,Direction,Verdict,Votes",
                TimeToString(TimeCurrent()) + "," + _Symbol + "," + dir + "," + verdict + "," + Quote(details));
  }

void JournalDeal(ulong deal)
  {
   if(!HistoryDealSelect(deal))
      return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(PositionSelectByTicket(pid))
      return;
   if(!HistorySelectByPosition(pid))
      return;

   string sym = "", dir = "", via = "outside";
   double lots = 0, inPrice = 0, outPrice = 0, pl = 0;
   datetime inTime = 0, outTime = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
          + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(e == DEAL_ENTRY_IN)
        {
         sym = HistoryDealGetString(d, DEAL_SYMBOL);
         dir = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? "BUY" : "SELL";
         lots += HistoryDealGetDouble(d, DEAL_VOLUME);
         inPrice = HistoryDealGetDouble(d, DEAL_PRICE);
         inTime = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) == MAGIC)
            via = "Council";
        }
      else
        {
         outPrice = HistoryDealGetDouble(d, DEAL_PRICE);
         outTime = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
        }
     }
   if(sym == "")
      return;

   double oneR = AccountInfoDouble(ACCOUNT_BALANCE) * g_riskPct / 100.0;
   double r = (oneR > 0) ? pl / oneR : 0;
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   string header = "Opened,Closed,Symbol,Direction,Via,Lots,Entry,Exit,Result,R,"
                   "Setup,RulesFollowed(Y/N),EmotionBefore,EmotionDuring,EmotionAfter,Grade(A-F),Lesson";
   string line = TimeToString(inTime) + "," + TimeToString(outTime) + "," + sym + "," + dir + "," + via + "," +
                 DoubleToString(lots, 2) + "," + DoubleToString(inPrice, dg) + "," +
                 DoubleToString(outPrice, dg) + "," + DoubleToString(pl, 2) + "," +
                 DoubleToString(r, 2) + ",,,,,,,";
   AppendCsv(JOURNAL_FILE, header, line);
  }

void AppendCsv(string file, string header, string line)
  {
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWriteString(h, header + "\r\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

string Quote(string s)
  {
   StringReplace(s, "\"", "'");
   return "\"" + s + "\"";
  }

void BuildPanel()
  {
   string bg = PFX + "bg";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 500);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 390);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,22,30');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   Label("stl", 15, 116, "Mental state:", clrSilver);
   Button("minus", 135, 113, 26, 22, "-", C'60,60,70');
   Button("plus", 250, 113, 26, 22, "+", C'60,60,70');

   Label("sll", 15, 146, "SL", clrSilver);
   Edit("sl", 40, 143, 60, 22, DoubleToString(InpDefaultSL, 2));
   Label("tpl", 112, 146, "TP", clrSilver);
   Edit("tp", 137, 143, 60, 22, DoubleToString(InpDefaultTP, 2));

   Button("buy", 15, 176, 150, 30, "REQUEST BUY", C'0,120,60');
   Button("sell", 175, 176, 150, 30, "REQUEST SELL", C'160,40,40');
   Button("vbuy", 340, 176, 70, 30, "view BUY", C'50,50,60');
   Button("vsell", 415, 176, 75, 30, "view SELL", C'50,50,60');
  }

void UpdatePanel(DayStats &s, double dayBal, double riskMoney, double lossLimit, double floating, string lock)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string status;
   color stClr = clrLimeGreen;
   if(lock != "")
     {
      status = "LOCKED - " + lock;
      stClr = clrTomato;
     }
   else if(s.trades >= InpMaxTradesPerDay)
     {
      status = "LOCKED - trade quota used. Review your journal.";
      stClr = clrTomato;
     }
   else
      status = "OPEN - wait for an A+ setup. No setup, no trade.";

   Label("t0", 15, 28, "DISCIPLINE DESK - WAR COUNCIL   " + _Symbol, clrGold, 11);
   Label("t1", 15, 52, status, stClr);
   Label("t2", 15, 72, StringFormat("1R = %.2f %s (%.2f%%) | Trades %d/%d | Losses %d/%d",
                                    riskMoney, cur, g_riskPct, s.trades, InpMaxTradesPerDay,
                                    s.losses, InpMaxLossesPerDay), clrWhite);
   Label("t3", 15, 92, StringFormat("Day P/L %.2f closed | %.2f open | limit -%.2f | viol. %d",
                                    s.closedPL, floating, lossLimit,
                                    (g_violDay == DayStart()) ? g_violations : 0), clrWhite);

   bool stateSet = (g_stateDay == DayStart());
   Label("stv", 168, 116, stateSet ? StringFormat("%d / 10", g_state) : "? / 10",
         !stateSet ? clrOrange : (g_state >= InpMinState ? clrLimeGreen : clrTomato));
   Label("sth", 285, 116, stateSet ? "" : "rate yourself before trading", clrOrange);

   bool ok[5];
   string why[5];
   double lots = 0;
   int no = Evaluate(g_dir, s, riskMoney, lossLimit, ok, why, lots);

   Label("lots", 210, 146, StringFormat("-> %.2f lots for 1R", lots), clrWhite);
   Label("hdr", 15, 216, StringFormat("COUNCIL (live, %s):  %d/5 YES", g_dir > 0 ? "BUY" : "SELL", 5 - no),
         no == 0 ? clrLimeGreen : clrGold, 10);
   for(int i = 0; i < 5; i++)
      Label("a" + IntegerToString(i), 15, 240 + 22 * i,
            (ok[i] ? "[YES] " : "[NO]  ") + StringFormat("%-10s ", g_agent[i]) + why[i],
            ok[i] ? clrLimeGreen : clrTomato);

   Label("vd", 15, 356, g_verdict, g_verdictClr);
   Label("ev", 15, 380, "Last: " + g_lastMsg, clrSilver, 8);
   ChartRedraw();
  }

void Label(string name, int x, int y, string text, color clr, int size = 9)
  {
   string n = PFX + name;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
     }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   if(StringLen(text) > 62)
      text = StringSubstr(text, 0, 62);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
  }

void Button(string name, int x, int y, int w, int h, string text, color bg)
  {
   string n = PFX + name;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI");
   ObjectSetString(0, n, OBJPROP_TEXT, text);
  }

void Edit(string name, int x, int y, int w, int h, string def)
  {
   string n = PFX + name;
   if(ObjectFind(0, n) >= 0)
      return;
   ObjectCreate(0, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, C'35,40,50');
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, n, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetInteger(0, n, OBJPROP_READONLY, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, n, OBJPROP_TEXT, def);
  }

double RiskMoney(string sym, long type, double vol, double open, double sl)
  {
   if(sl <= 0)
      return -1;
   double p = 0;
   ENUM_ORDER_TYPE ot = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, sym, vol, open, sl, p))
      return -1;
   return -p;
  }

double NormalizeVol(string sym, double vol)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;
   double v = MathFloor(vol / step + 1e-9) * step;
   return NormalizeDouble(v, 2);
  }

datetime DayStart()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min = 0;
   t.sec = 0;
   return StructToTime(t);
  }

int FindPos(ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(g_pos[i].ticket == ticket)
         return i;
   return -1;
  }

void AddPos(ulong ticket, double sl, bool checked)
  {
   int n = ArraySize(g_pos);
   ArrayResize(g_pos, n + 1);
   g_pos[n].ticket = ticket;
   g_pos[n].sl = sl;
   g_pos[n].seen = TimeCurrent();
   g_pos[n].checked = checked;
  }

void PrunePos()
  {
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(g_pos[i].ticket))
        {
         int last = ArraySize(g_pos) - 1;
         g_pos[i] = g_pos[last];
         ArrayResize(g_pos, last);
        }
  }
