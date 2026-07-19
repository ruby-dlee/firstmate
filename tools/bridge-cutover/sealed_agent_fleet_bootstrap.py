from pathlib import Path
import runpy
import sys
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "site-packages"))
runpy.run_module("agent_fleet", run_name="__main__", alter_sys=True)
