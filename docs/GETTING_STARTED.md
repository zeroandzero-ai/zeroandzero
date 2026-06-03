# Getting Started

This guide is the shortest path from a fresh clone to a local build, first launch, and Paper-first configuration.

ZeroandZero is a macOS app for governed, local-first investing workflows. It is not investment advice and does not promise returns.

## 1. Platform

- macOS with Xcode and the Swift toolchain installed.
- A local macOS user account with Keychain access.
- Optional Touch ID or Mac password support for Live order user-presence protection.
- Apple Silicon and Intel Macs should both be treated as supported macOS development targets when the installed Xcode toolchain can build the workspace.

## 2. Clone, Build, And Test

```bash
git clone https://github.com/zeroandzero-ai/zeroandzero.git
cd zeroandzero
xcodebuild -workspace AlgoTradingMac.xcworkspace -scheme AlgoTradingMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Run app tests:

```bash
xcodebuild -workspace AlgoTradingMac.xcworkspace -scheme AlgoTradingMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AlgoTradingMacTests
```

Run `TradingKit` tests:

```bash
cd Packages/TradingKit
swift test
```

## 3. First Launch Expectations

On first launch, expect a local workstation with no bundled credentials, no bundled brokerage account, no bundled model access, no bundled private strategy, and no hidden subscription-backed inference path.

You configure local runtime records, provider profiles, account credentials, Telegram settings if used, Strategy Briefs, Analyst Charters, and Skills Library content for your own use.

The repo may include public default or example RSS/feed sources when they are public-safe and intentionally tracked. You only need to set up additional RSS/feed sources if you want more or different sources. Private, paid, tokenized, subscriber, user-specific, and fetched article/feed history stays local and is not included.

## 4. Credentials

Store secrets in macOS Keychain and configure the app with lookup labels or app-owned provider profiles. Do not put credentials in source files, issue text, screenshots, logs, or docs.

Common credential categories:

- OpenAI API credentials for PM and Analyst runtime calls.
- Anthropic API credentials when using Anthropic runtime profiles.
- Alpaca Paper credentials for Paper workflow validation.
- Alpaca Live credentials only if you understand and accept Live trading risk.
- Optional Telegram bot token if you enable Telegram transport. Telegram requires intentional bot setup and in-app route binding before it should be relied on for continuity.

### Telegram Setup And Safety

Telegram is an optional companion transport for PM continuity. It is intended to provide communication and notification capabilities and should not be treated as a trading authority.

When configuring Telegram:

1. Create your own Telegram bot using BotFather.
2. Store the bot token securely and never commit it to source control.
3. Do not share bot tokens, chat IDs, route IDs, screenshots, logs, or configuration values publicly.
4. Configure Telegram through the app and complete any required route binding or authorization steps before relying on it.

Important safety boundaries:

- Telegram is transport-only and does not grant trading authority.
- Telegram cannot final-approve Live trades.
- Telegram cannot arm Live trading.
- Telegram cannot bypass proposal review workflows.
- Telegram cannot bypass LocalAuthentication requirements.
- Telegram cannot bypass Engine safety gates.
- Telegram cannot bypass the macOS application’s Live execution protections.

Always treat Telegram as a communication layer rather than an execution layer.

ZeroandZero does not use ChatGPT or Claude consumer subscription login, browser cookies, or web sessions as PM/Analyst runtime credentials. Provider API usage may incur separate provider charges under your own accounts. Use provider-side controls such as budgets, spend limits, project keys, service accounts, workspaces, or separate billing profiles where available.

## 5. Paper-First Workflow

Start with Paper.

1. Configure Paper credentials.
2. Confirm the active environment before any order workflow.
3. Use Paper to validate watchlists, PM/Analyst artifacts, proposal review, order review, and local IPC tools.
4. Confirm WebSocket/order-state behavior and startup reconciliation before considering Live.
5. Keep Live disarmed until you intentionally choose to test Live behavior.

ZeroandZero's Alpaca integration does not provide funding, withdrawal, transfer, or account-management flows. Use the broker's official surfaces for those account operations.

## 6. Live Safety Workflow

Live mode has explicit safety boundaries:

- Live starts disarmed on app launch.
- The kill switch blocks Live `NEW` and `REPLACE` orders.
- Live `CANCEL` remains available for risk reduction.
- Manual UI, PM-assisted, strategy, proposal, and review paths all route through the Engine order pipeline.
- Optional LocalAuthentication requires Touch ID or Mac password before Live order submission.
- PM, Analyst, Skills, Telegram, and provider outputs cannot bypass Live arming, kill switch, LocalAuthentication, proposal review, PM approval, or Engine gates.

Use Live only when you have reviewed the active environment, open orders, account state, kill switch, arming state, and local user-presence settings.

## 7. Create Your Own Operating Materials

The public repo does not include private strategy content. Create your own materials locally.

### Portfolio Strategy Brief

Use a Strategy Brief to describe your own objective, constraints, risk posture, portfolio construction assumptions, review cadence, and escalation rules. Keep it specific to your own workflow, and treat it as local operating context rather than investment advice.

### Analyst Charters

Create Analyst Charters to define analyst roles, allowed sources, research expectations, constraints, expected outputs, and runtime defaults. Keep private strategy details local.

### Skills Library

Use Skills to capture methodology guidance, review checklists, and repeatable analysis patterns. Skills should help the PM or analysts reason consistently; they do not grant trading authority.

### RSS And Feed Sources

Configure only public, non-tokenized, non-account-specific feeds in repo-tracked examples. Add or replace RSS/feed sources only when you want more or different sources than any shipped public defaults. Keep private, paid, tokenized, subscriber, user-specific feed state, and fetched feed/article history local.

## 8. Useful Local Commands

With the app not running, this should fail cleanly with a missing-runtime response:

```bash
cd Packages/TradingKit
swift run alpaca_agentctl status
```

With the app running, it should return local status JSON from the loopback IPC server.

## 9. Known Limitations

- Local macOS app, not a hosted trading service.
- No bundled brokerage account or credentials.
- No bundled OpenAI, Anthropic, Telegram, or Alpaca usage.
- Provider API usage may incur separate costs.
- No investment, legal, tax, or financial advice.
- No performance guarantee.
- Live trading can lose money.
- Alpaca funding, withdrawal, transfer, and account-management flows are outside the current app integration.
- Public docs are starting points for local development, not personalized strategy.

English is the canonical documentation language for launch. Translations can be added later if they can be maintained and reviewed with the same safety and accuracy standards.
