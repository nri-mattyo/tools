"""athena_ddl.py: table-name derivation, the traditional (Glue Catalog-
registered) partition DDL, and the MSCK REPAIR TABLE statement that keeps
partitions current. Replaced an earlier partition-projection design -- see
athena_ddl.py's module docstring for why."""
from athena_ddl import build_ddl, default_table_name, repair_table_sql
from cloudtrail_schema import DDL_COLUMNS


def test_default_table_name_uses_last_path_segment():
    assert default_table_name("cloudtrail/prod/") == "prod"
    assert default_table_name("cloudtrail/") == "cloudtrail"


def test_default_table_name_falls_back_on_empty_prefix():
    assert default_table_name("") == "cloudtrail_logs"
    assert default_table_name("/") == "cloudtrail_logs"


def test_build_ddl_includes_every_schema_column():
    ddl = build_ddl("db", "tbl", "my-bucket", "cloudtrail/")
    for col in DDL_COLUMNS:
        assert f"{col} STRING" in ddl, f"missing column {col} in generated DDL"


def test_build_ddl_declares_partitions_without_projection():
    """No projection TBLPROPERTIES -- partitions are real Glue Catalog
    entries, registered via repair_table_sql()'s MSCK REPAIR TABLE, not
    computed from a declared range at query time."""
    ddl = build_ddl("db", "tbl", "my-bucket", "cloudtrail/")
    assert "PARTITIONED BY (year STRING, month STRING, day STRING)" in ddl
    assert "TBLPROPERTIES" not in ddl
    assert "projection" not in ddl.lower()


def test_build_ddl_location_matches_the_prefix():
    ddl = build_ddl("db", "tbl", "my-bucket", "cloudtrail")  # no trailing slash
    assert "LOCATION 's3://my-bucket/cloudtrail/'" in ddl


def test_repair_table_sql_targets_the_right_database_and_table():
    sql = repair_table_sql("cloudtrail_logs", "consolidated")
    assert sql == "MSCK REPAIR TABLE cloudtrail_logs.consolidated;"
