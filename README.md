
Your legacy worksheets have been moved to your personal workspace ("My Workspace").
Show me now
Workspaces
Databases
Supplier Risk Radar
A Snowflake-native app for supplier quality and procurement managers. It ranks suppliers by risk, explains why with defect and warranty evidence, and recommends an action.

Built on the AUTO_MFG_DW database.

What it includes
Component	Object	Purpose
Risk score view	AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK	0-100 score per supplier (higher is riskier), band (HIGH / MEDIUM / LOW) and recommended action
AI summaries	AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_ISSUE_SUMMARY	AI_AGG summary of recurring defect themes and root causes, for HIGH-risk suppliers only
Semantic view	AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_SV	Lets Cortex Analyst answer natural-language questions
Cortex Agent	AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_AGENT	Ranks suppliers and recommends actions
Streamlit app	streamlit_app.py	Watchlist, supplier drill-down and an "Ask the radar" chat box
How the risk score works
Weighted blend of: quality rating (25%), on-time delivery (20%, capped at 100%), defects per 1,000 orders (25%), critical-defect share (10%), defect increase over the last 90 days vs the prior 90 (10%), and warranty cost of parts the supplier provides (10%, percentile rank).

Bands: HIGH >= 40, MEDIUM 25-40, LOW < 25. The weights and cutoffs are judgment calls; edit them in setup.sql.

Warranty cost is linked to suppliers through purchase orders (supplier -> part -> warranty claim), so a part bought from several suppliers counts toward each.

Setup
Make sure these exist: AUTO_MFG_DW.SUPPLY_CHAIN.SUPPLIERS, SUPPLY_CHAIN.PURCHASE_ORDERS, QUALITY.DEFECTS, QUALITY.WARRANTY_CLAIMS.
Run setup.sql top to bottom. It creates the schema, view, summary table, semantic view and agent.
Step 2 calls AI_AGG over the defect text of HIGH-risk suppliers, which uses Cortex credits. Your role needs access to Cortex AI functions.
The agent uses the warehouse DEFAULT_WH; change it if needed.
Open this folder as a Streamlit app in a Snowsight Workspace and click Run.
snowflake.yml sets DEFAULT_WH and SYSTEM_COMPUTE_POOL_CPU. Change both if your account differs, or remove them and set them in App Settings.
Using it
Watchlist: filter by risk band, tier and status.
Supplier drill-down: risk, quality, on-time %, defect trend, the AI summary and the recommended action.
Ask the radar: the app's chat box calls AI_COMPLETE (llama3.3-70b) with the top 40 suppliers by risk as context.
Agent: in Snowsight, open AI & ML > Agents > SUPPLIER_RISK_AGENT and ask, for example, "Which 5 suppliers are the highest risk and why?"
Notes and limits
The summaries are a snapshot. Re-run step 2 of setup.sql to refresh them after the data changes.
ON_TIME_DELIVERY_PCT has values above 100 in the source; the view caps them at 100.
The in-app chat box does not call the Cortex Agent; the agent is used from Snowsight.
The app queries tables in AUTO_MFG_DW, so the app's role needs SELECT on them and on the SUPPLIER_RADAR schema.
# Supplier Risk Radar

A Snowflake-native app for supplier quality and procurement managers. It ranks suppliers by risk, explains why with defect and warranty evidence, and recommends an action.

Built on the `AUTO_MFG_DW` database.

## What it includes

| Component | Object | Purpose |
|---|---|---|
| Risk score view | `AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK` | 0-100 score per supplier (higher is riskier), band (HIGH / MEDIUM / LOW) and recommended action |
| AI summaries | `AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_ISSUE_SUMMARY` | `AI_AGG` summary of recurring defect themes and root causes, for HIGH-risk suppliers only |
| Semantic view | `AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_SV` | Lets Cortex Analyst answer natural-language questions |
| Cortex Agent | `AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_AGENT` | Ranks suppliers and recommends actions |
| Streamlit app | `streamlit_app.py` | Watchlist, supplier drill-down and an "Ask the radar" chat box |

## How the risk score works

Weighted blend of: quality rating (25%), on-time delivery (20%, capped at 100%), defects per 1,000 orders (25%), critical-defect share (10%), defect increase over the last 90 days vs the prior 90 (10%), and warranty cost of parts the supplier provides (10%, percentile rank).

Bands: HIGH >= 40, MEDIUM 25-40, LOW < 25. The weights and cutoffs are judgment calls; edit them in `setup.sql`.

Warranty cost is linked to suppliers through purchase orders (supplier -> part -> warranty claim), so a part bought from several suppliers counts toward each.

## Setup

1. Make sure these exist: `AUTO_MFG_DW.SUPPLY_CHAIN.SUPPLIERS`, `SUPPLY_CHAIN.PURCHASE_ORDERS`, `QUALITY.DEFECTS`, `QUALITY.WARRANTY_CLAIMS`.
2. Run `setup.sql` top to bottom. It creates the schema, view, summary table, semantic view and agent.
   - Step 2 calls `AI_AGG` over the defect text of HIGH-risk suppliers, which uses Cortex credits. Your role needs access to Cortex AI functions.
   - The agent uses the warehouse `DEFAULT_WH`; change it if needed.
3. Open this folder as a Streamlit app in a Snowsight Workspace and click **Run**.
   - `snowflake.yml` sets `DEFAULT_WH` and `SYSTEM_COMPUTE_POOL_CPU`. Change both if your account differs, or remove them and set them in App Settings.

## Using it

- **Watchlist:** filter by risk band, tier and status.
- **Supplier drill-down:** risk, quality, on-time %, defect trend, the AI summary and the recommended action.
- **Ask the radar:** the app's chat box calls `AI_COMPLETE` (`llama3.3-70b`) with the top 40 suppliers by risk as context.
- **Agent:** in Snowsight, open AI & ML > Agents > `SUPPLIER_RISK_AGENT` and ask, for example, "Which 5 suppliers are the highest risk and why?"

# dataindconferencehackthon
