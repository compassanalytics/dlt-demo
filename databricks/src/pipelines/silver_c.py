from pyspark import pipelines as dp
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

spark = SparkSession.builder.getOrCreate()


@dp.materialized_view(
    name="silver_customer_summary",
    comment="Silver layer: customer order rollup — STUB, populated by tackle session",
    schema=(
        "id STRING, name STRING, region STRING, "
        "total_orders BIGINT, total_amount DOUBLE, last_order_date STRING"
    ),
)
def silver_customer_summary():
    customers = spark.read.table("bronze_customers")
    _orders = spark.read.table("bronze_orders")  # read kept so DAG edge to bronze_orders registers
    # TODO(tackle): Replace with real join + rollup aggregation
    # e.g.: (customers.join(orders, customers.id == orders.customer_id, "left")
    #           .groupBy(customers.id, customers.name, customers.region)
    #           .agg(F.count("order_id").alias("total_orders"),
    #                F.sum(F.col("amount").cast("double")).alias("total_amount"),
    #                F.max("order_date").alias("last_order_date")))
    return (
        customers.limit(0).select(
            customers.id,
            customers.name,
            customers.region,
            F.lit(0).cast("bigint").alias("total_orders"),
            F.lit(0.0).cast("double").alias("total_amount"),
            customers.signup_date.alias("last_order_date"),
        )
    )
