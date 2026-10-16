import os

import pandas as pd
import streamlit as st

st.set_page_config(page_title="Supplier Risk Radar", page_icon=":radar:", layout="wide")

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))
session = conn.session()

RISK = "AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK"
SUMM = "AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_ISSUE_SUMMARY"
DEFECTS = "AUTO_MFG_DW.QUALITY.DEFECTS"
BAND_COLORS = {"HIGH": "#d62728", "MEDIUM": "#ff7f0e", "LOW": "#2ca02c"}


@st.cache_data(show_spinner="Loading suppliers...")
def load_risk() -> pd.DataFrame:
    return session.sql(
        f"""
        SELECT SUPPLIER_ID, SUPPLIER_NAME, SUPPLIER_TIER, STATUS, COUNTRY_CODE,
               RISK_SCORE, RISK_BAND, QUALITY_RATING, ON_TIME_PCT,
               TOTAL_DEFECTS, CRITICAL_DEFECTS, DEFECTS_LAST_90D, DEFECTS_PRIOR_90D,
               WARRANTY_COST, SPEND, RECOMMENDED_ACTION
        FROM {RISK}
        ORDER BY RISK_SCORE DESC
        """
    ).to_pandas()


@st.cache_data(show_spinner="Loading supplier detail...")
def load_summary(supplier_id: int) -> str:
    rows = session.sql(
        f"SELECT ISSUE_SUMMARY FROM {SUMM} WHERE SUPPLIER_ID = ?",
        params=[supplier_id],
    ).collect()
    return rows[0]["ISSUE_SUMMARY"] if rows else ""


@st.cache_data(show_spinner="Loading defects...")
def load_defects(supplier_id: int) -> pd.DataFrame:
    return session.sql(
        f"""
        SELECT DATE_TRUNC('month', DISCOVERED_DATE) AS MONTH, DEFECT_TYPE, SEVERITY,
               COUNT(*) AS DEFECTS
        FROM {DEFECTS}
        WHERE SUPPLIER_ID = ?
        GROUP BY 1, 2, 3
        ORDER BY 1
        """,
        params=[supplier_id],
    ).to_pandas()


def clear_cache():
    load_risk.clear()
    load_summary.clear()
    load_defects.clear()


st.title(":radar: Supplier Risk Radar")
st.caption("Ranks suppliers by risk, explains why, and recommends an action.")

df = load_risk()

with st.sidebar:
    st.header("Filters")
    bands = st.multiselect("Risk band", ["HIGH", "MEDIUM", "LOW"], default=["HIGH", "MEDIUM"])
    tiers = st.multiselect("Tier", sorted(df["SUPPLIER_TIER"].dropna().unique()), default=[])
    statuses = st.multiselect("Status", sorted(df["STATUS"].dropna().unique()), default=[])
    st.button("Refresh data", on_click=clear_cache)

view = df[df["RISK_BAND"].isin(bands)] if bands else df
if tiers:
    view = view[view["SUPPLIER_TIER"].isin(tiers)]
if statuses:
    view = view[view["STATUS"].isin(statuses)]

c1, c2, c3, c4 = st.columns(4)
c1.metric("Suppliers", f"{len(df):,}")
c2.metric("High risk", int((df["RISK_BAND"] == "HIGH").sum()))
c3.metric("Critical defects", int(df["CRITICAL_DEFECTS"].sum()))
c4.metric("Warranty cost (linked parts)", f"${df['WARRANTY_COST'].sum():,.0f}")

tab_watch, tab_detail, tab_chat = st.tabs(["Watchlist", "Supplier drill-down", "Ask the radar"])

with tab_watch:
    st.subheader(f"Watchlist ({len(view)} suppliers)")
    st.dataframe(
        view[
            [
                "SUPPLIER_NAME", "SUPPLIER_TIER", "STATUS", "RISK_SCORE", "RISK_BAND",
                "QUALITY_RATING", "ON_TIME_PCT", "TOTAL_DEFECTS", "CRITICAL_DEFECTS",
                "DEFECTS_LAST_90D", "DEFECTS_PRIOR_90D", "RECOMMENDED_ACTION",
            ]
        ].head(100),
        use_container_width=True,
        hide_index=True,
        column_config={
            "RISK_SCORE": st.column_config.ProgressColumn(
                "Risk score", min_value=0, max_value=60, format="%.1f"
            ),
        },
    )
    st.subheader("Risk by tier")
    by_tier = df.groupby(["SUPPLIER_TIER", "RISK_BAND"]).size().unstack(fill_value=0)
    st.bar_chart(by_tier)

with tab_detail:
    options = view if len(view) else df
    name = st.selectbox("Supplier", options["SUPPLIER_NAME"].tolist())
    row = df[df["SUPPLIER_NAME"] == name].iloc[0]
    sid = int(row["SUPPLIER_ID"])

    d1, d2, d3, d4 = st.columns(4)
    d1.metric("Risk score", f"{row['RISK_SCORE']:.1f}", row["RISK_BAND"], delta_color="off")
    d2.metric("Quality rating", f"{row['QUALITY_RATING']:.1f}")
    d3.metric("On-time %", f"{row['ON_TIME_PCT']:.1f}")
    d4.metric("Defects 90d vs prior", int(row["DEFECTS_LAST_90D"]),
              int(row["DEFECTS_LAST_90D"] - row["DEFECTS_PRIOR_90D"]), delta_color="inverse")

    st.info(f"**Recommended action:** {row['RECOMMENDED_ACTION']}")

    summary = load_summary(sid)
    if summary:
        st.subheader("Why this supplier is risky (AI summary of defects)")
        st.write(summary)

    defects = load_defects(sid)
    if len(defects):
        left, right = st.columns(2)
        with left:
            st.subheader("Defects by month")
            st.bar_chart(defects.groupby("MONTH")["DEFECTS"].sum())
        with right:
            st.subheader("Defects by type")
            st.bar_chart(defects.groupby("DEFECT_TYPE")["DEFECTS"].sum())
    else:
        st.write("No defects recorded for this supplier.")

with tab_chat:
    st.caption("Answers are grounded in the live risk table (top 40 suppliers by risk).")
    if "messages" not in st.session_state:
        st.session_state.messages = []

    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.write(msg["content"])

    if prompt := st.chat_input("e.g. Which suppliers should we audit first and why?"):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.write(prompt)

        context = df.head(40)[
            [
                "SUPPLIER_NAME", "SUPPLIER_TIER", "STATUS", "RISK_SCORE", "RISK_BAND",
                "QUALITY_RATING", "ON_TIME_PCT", "TOTAL_DEFECTS", "CRITICAL_DEFECTS",
                "DEFECTS_LAST_90D", "DEFECTS_PRIOR_90D", "WARRANTY_COST", "RECOMMENDED_ACTION",
            ]
        ].to_csv(index=False)
        full_prompt = (
            "You are a supplier quality analyst. Answer only from the data below; "
            "if the data does not answer the question, say so. Be concise, lead with a ranked "
            "list, cite the numbers, and end with a recommended action.\n\n"
            f"SUPPLIER DATA (CSV, higher RISK_SCORE is riskier):\n{context}\n\n"
            f"QUESTION: {prompt}"
        )
        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                answer = session.sql(
                    "SELECT AI_COMPLETE('llama3.3-70b', ?) AS A",
                    params=[full_prompt],
                ).collect()[0]["A"]
            st.write(answer)
        st.session_state.messages.append({"role": "assistant", "content": answer})
