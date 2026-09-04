import sys, os
from lupa import LuaRuntime

root = os.path.dirname(os.path.abspath(__file__))
proj = os.path.dirname(root)
script = os.path.join(root, sys.argv[1]).replace("\\", "/")
target = sys.argv[2]

L = LuaRuntime(unpack_returned_tuples=True)
L.execute("arg = {...}", target)
src = open(script, encoding="utf-8").read().replace("os.exit(", "EXITCODE=(")
try:
    L.execute(src)
    code = L.eval("EXITCODE") or 0
except Exception as e:
    print("LUA ERROR:", e)
    code = 2
sys.exit(int(code) if isinstance(code, (int, float)) else (0 if code else 1))
