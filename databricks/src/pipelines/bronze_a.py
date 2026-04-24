from pyspark import pipelines as dp
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()


@dp.table(
    name="bronze_customers",
    comment="Bronze layer: raw customers — STUB, populated by tackle session",
    schema="id STRING, name STRING, region STRING, signup_date STRING",
)
def bronze_customers():
    # TODO(tackle): Replace with Auto Loader read from seed Volume path
    # e.g.: return (spark.readStream.format("cloudFiles")
    #                  .option("cloudFiles.format", "csv")
    #                  .option("header", "true")
    #                  .schema("id STRING, name STRING, region STRING, signup_date STRING")
    #                  .load(f"/Volumes/{catalog}/{schema}/seed_data/customers/"))
    return (
        spark.readStream.format("rate").load()
        .selectExpr(
            "CAST(NULL AS STRING) AS id",
            "CAST(NULL AS STRING) AS name",
            "CAST(NULL AS STRING) AS region",
            "CAST(NULL AS STRING) AS signup_date",
        )
        .where("1 = 0")
    )
