# Discipline Council

A MetaTrader 5 Expert Advisor that stands between you and the order button. Five agents vote on every manual trade, and a single NO stops it.

It does not look for trades or open them on its own. You pick the setup and press the button. The Council decides whether the order goes out, then enforces your risk rules while the trade is open.

## The five agents

| Agent | Job | Says NO when (default settings) |
| --- | --- | --- |
| KING | Risk | No stop loss, reward:risk below 1:2, the stop is too wide for 1R at minimum lot, or the daily loss limit is hit |
| SAMURAI | Emotions | You have not rated your mental state today, it is below 6/10, you are in the 15-minute cooldown after a loss, or you have reached 2 losses or 3 trades today |
| SNIPER | Entry | Spread is above 0.60, or price is more than 2.0 away from a level you drew on the chart |
| STRATEGIST | Timing | Outside the 07-11 and 13-17 server-time sessions, or within 30 minutes of high-impact news for the symbol's currencies |
| WOLF | Trend | The trade goes against the H4 trend, or the trend is unclear (50 and 200 EMA) |

All five must say YES. The panel shows the live vote, so you can see what is blocking a trade before you request it.

## Rules it enforces at all times

- Closes positions and deletes pending orders that did not go through the Council
- Closes everything when closed and floating losses reach 2% of the day-start balance
- Closes any position that has no stop loss after 30 seconds
- Restores a stop loss that was widened or removed, while still letting you tighten it
- Sizes each trade to 1R, and trims oversized positions back to that risk
- Caps risk at 0.5-1% per trade, whatever you enter in the settings
- Logs trades, rule violations and every Council vote to CSV files in `MQL5/Files`

Every limit is an input you can change in the EA's settings, apart from the 0.5-1% risk cap.

## Read this before using it

- **It acts on the whole account, not just the chart it is attached to.** With `InpCouncilOnly` on, which is the default, it closes trades from other EAs, your phone or any other symbol. Positions already open when you attach it are kept, though the stop loss rules still apply to them. Existing pending orders are deleted. Set `InpCouncilOnly` to `false` if you run anything else on the account.
- **The defaults are tuned for gold.** The SL, TP, level and spread settings are price distances, so change them for any other symbol.
- **It only works while MetaTrader is running with the EA attached.** Nothing is enforced while the terminal is closed.

This is a discipline tool, not a trading strategy, and it makes no promise of profit. Trading leveraged products can lose you money. Try it on a demo account first.

## Set it up

1. In MetaTrader 5, open **File > Open Data Folder** and copy `DisciplineCouncil.mq5` into `MQL5/Experts`.
2. Open the file in MetaEditor and compile it with F7.
3. Attach the EA to the chart you trade and turn on **Algo Trading**.
4. Draw your levels as horizontal lines or rectangles.
5. Rate your mental state with the - and + buttons, and set your SL and TP distances.
6. Press **REQUEST BUY** or **REQUEST SELL**.

## Built with

MQL5 and the standard `Trade.mqh` library. There are no other dependencies.
