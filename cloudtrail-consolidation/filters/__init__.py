"""Filter plugin contract.

A filter is a module with:
  SUBPATH: str          -- appended to --to's prefix for this filter's own
                            partitioned-Parquet output, e.g. "errors_and_writes/"
  matches(record) -> bool  -- record is one raw (un-flattened) CloudTrail
                              record dict; return True to include it in this
                              filter's output.

Filters run in addition to (not instead of) the primary consolidated output --
every record always goes to the primary --to destination; a record additionally
goes to a filter's destination when matches() returns True.
"""
import importlib


def load_filter(spec):
    """spec like "filters.errors_and_writes" -> the imported module, validated
    to have SUBPATH and matches()."""
    mod = importlib.import_module(spec)
    if not hasattr(mod, "SUBPATH") or not hasattr(mod, "matches"):
        raise ValueError(f"{spec} is not a valid filter module (needs SUBPATH and matches())")
    return mod
