"""Run once after the compiler/cache materialization slot is granted."""
import os
from prepare_sources import main as sources
from prepare_cache import main as cache
from snapshot_build import main as snapshot
if __name__=='__main__':
    os.umask(0o077)
    sources()
    cache()
    snapshot()
