from pyspark import pipelines as dp
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()


@dp.table(
    name="bronze_orders",
    comment="Bronze layer: raw orders — STUB, populated by tackle session",
    schema="order_id STRING, customer_id STRING, amount STRING, order_date STRING",
)
def bronze_orders():
    # TODO(tackle): Replace with Auto Loader read from seed Volume path
    # e.g.: return (spark.readStream.format("cloudFiles")
    #                  .option("cloudFiles.format", "csv")
    #                  .option("header", "true")
    #                  .schema("order_id STRING, customer_id STRING, amount STRING, order_date STRING")
    #                  .load(f"/Volumes/{catalog}/{schema}/seed_data/orders/"))
    return (
        spark.readStream.format("rate").load()
        .selectExpr(
            "CAST(NULL AS STRING) AS order_id",
            "CAST(NULL AS STRING) AS customer_id",
            "CAST(NULL AS STRING) AS amount",
            "CAST(NULL AS STRING) AS order_date",
        )
        .where("1 = 0")
    )
