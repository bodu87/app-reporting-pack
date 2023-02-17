# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
from datetime import datetime, timedelta
import itertools
import logging
from rich.logging import RichHandler
from functools import reduce
import pandas as pd
import numpy as np
from google.api_core.exceptions import Conflict

from gaarf.api_clients import GoogleAdsApiClient
from gaarf.utils import get_customer_ids
from gaarf.query_executor import AdsReportFetcher
from gaarf.cli.utils import GaarfConfigBuilder
from gaarf.bq_executor import BigQueryExecutor

from src.queries import ChangeHistory
from src.utils import write_data_to_bq


def restore_history(placeholder_df: pd.DataFrame,
                    partial_history: pd.DataFrame,
                    current_values: pd.DataFrame, name: str) -> pd.DataFrame:
    "Restores dimension history for every date and campaign_id within placeholder_df."
    if not partial_history.empty:
        joined = pd.merge(placeholder_df,
                          partial_history,
                          on=["campaign_id", "date"],
                          how="left")
        joined["filled_backward"] = joined.groupby(
            "campaign_id")["value_old"].bfill()
        joined["filled_forward"] = joined.groupby(
            "campaign_id")["value_new"].ffill()
        joined["filled_forward"] = joined.groupby(
            "campaign_id")["filled_forward"].fillna(
                joined.pop("filled_backward"))
        joined = pd.merge(joined, current_values, on="campaign_id", how="left")
        joined[name] = np.where(joined["filled_forward"].isnull(),
                                joined[name], joined["filled_forward"])
    else:
        joined = pd.merge(placeholder_df,
                          current_values,
                          on="campaign_id",
                          how="left")
    if name != "target_roas":
        joined[name] = joined[name].astype(int)
    return joined[["date", "campaign_id", name]]


def format_partial_change_history(df: pd.DataFrame,
                                  dimension_name: str) -> pd.DataFrame:
    """Performs renaming and selecting last value for the date."""
    df["date"] = df["change_date"].str.split(expand=True)[0]
    df = df.rename(columns={
        f"old_{dimension_name}": "value_old",
        f"new_{dimension_name}": "value_new"
    })[["date", "campaign_id", "value_old", "value_new"]]
    return df.groupby(["date", "campaign_id"]).last()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--config", dest="gaarf_config", default=None)
    parser.add_argument("--output", dest="save", default="bq")
    parser.add_argument("--ads-config", dest="ads_config")
    parser.add_argument("--account", dest="customer_id")
    parser.add_argument("--api-version", dest="api_version", default="12")
    parser.add_argument("--log", "--loglevel", dest="loglevel", default="info")
    parser.add_argument("--customer-ids-query",
                        dest="customer_ids_query",
                        default=None)
    parser.add_argument("--customer-ids-query-file",
                        dest="customer_ids_query_file",
                        default=None)

    args = parser.parse_known_args()

    logging.basicConfig(format="%(message)s",
                        level=args[0].loglevel.upper(),
                        datefmt="%Y-%m-%d %H:%M:%S",
                        handlers=[RichHandler(rich_tracebacks=True)])
    logging.getLogger("google.ads.googleads.client").setLevel(logging.WARNING)
    logging.getLogger("smart_open.smart_open_lib").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)
    logger = logging.getLogger(__name__)

    # Change history can be fetched only for the last 29 days
    days_ago_29 = (datetime.now() - timedelta(days=29)).strftime("%Y-%m-%d")
    days_ago_1 = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    dates = [
        date.strftime("%Y-%m-%d") for date in pd.date_range(
            days_ago_29, days_ago_1).to_pydatetime().tolist()
    ]
    config = GaarfConfigBuilder(args).build()
    bq_project = config.writer_params.get("project")
    bq_dataset = config.writer_params.get("dataset")

    google_ads_client = GoogleAdsApiClient(path_to_config=args[0].ads_config,
                                           version=f"v{config.api_version}")
    customer_ids = get_customer_ids(google_ads_client, config.account,
                                    config.customer_ids_query)
    logger.info("Restoring change history for %d accounts: %s",
                len(customer_ids), customer_ids)
    report_fetcher = AdsReportFetcher(google_ads_client, customer_ids)

    # extract change history report
    change_history = report_fetcher.fetch(
        ChangeHistory(days_ago_29, days_ago_1)).to_pandas()

    logger.info("Restoring change history for %d accounts: %s",
                len(customer_ids), customer_ids)
    # Filter rows where budget change occurred
    budgets = change_history.loc[(change_history["old_budget_amount"] > 0)
                                 & (change_history["new_budget_amount"] > 0)]
    if not budgets.empty:
        budgets = format_partial_change_history(budgets, "budget_amount")
        logger.info("%d budgets events were found", len(budgets))
    else:
        logger.info("no budgets events were found")

    # Filter rows where bid change occurred
    bids = change_history.loc[change_history["old_target_cpa"] > 0]
    if not bids.empty:
        bids = format_partial_change_history(bids, "target_cpa")
        logger.info("%d target_cpa events were found", len(bids))
    else:
        logger.info("no target_cpa events were found")

    bq_executor = BigQueryExecutor(project_id=bq_project)

    # get all campaigns with an non-zero impressions to build placeholders df
    campaign_ids = bq_executor.execute(
        query_text=
        f"SELECT DISTINCT campaign_id FROM {bq_project}.{bq_dataset}.asset_performance",
        script_name=None,
        params=None)
    logger.info("Change history will be restored for %d campaign_ids",
                len(campaign_ids))

    # get latest bids and budgets to replace values in campaigns without any changes
    current_bids_budgets = bq_executor.execute(
        query_text=f"SELECT * FROM {bq_project}.{bq_dataset}.bid_budget",
        script_name=None,
        params=None)

    # generate a placeholder dataframe that contain possible variations of
    # campaign_ids with non-zero impressions and last 29 days date range
    placeholders = pd.DataFrame(data=list(
        itertools.product(list(campaign_ids.campaign_id.values), dates)),
                                columns=["campaign_id", "date"])

    restored_budgets = restore_history(placeholders, budgets,
                                       current_bids_budgets, "budget_amount")
    restored_target_cpas = restore_history(placeholders, bids,
                                           current_bids_budgets, "target_cpa")
    restored_target_roas = restore_history(placeholders, bids,
                                           current_bids_budgets, "target_roas")
    # Combine restored change histories
    restored_bid_budget_history = reduce(
        lambda left, right: pd.merge(
            left, right, on=["date", "campaign_id"], how="left"),
        [restored_budgets, restored_target_cpas, restored_target_roas])

    # Writer data for each date to BigQuery dated table (with _YYYYMMDD suffix)
    for date in dates:
        daily_history = restored_bid_budget_history.loc[
            restored_bid_budget_history["date"] == date]
        table_id = f"{bq_project}.{bq_dataset}.bid_budgets_{date.replace('-','')}"
        try:
            write_data_to_bq(bq_client=bq_executor.client,
                             data=daily_history,
                             table_id=table_id,
                             write_disposition="WRITE_EMPTY")
        except Conflict as e:
            logger.warning("table '%s' already exists", table_id)


if __name__ == "__main__":
    main()