#!/usr/bin/env python3
"""HTTP front end for the duel referee, run by whoever sets the function.

  POST /query   {"input": "7fffffff"}                    costs 1 query
  POST /check   {"source": "<assembly>"} or {"bin": "<hex words, little-endian bytes>"}
                                                         costs 1 query; over 32 words costs nothing
  GET  /score                                            query count per player
  GET  /log                                              the caller's own log

Every request carries "Authorization: Bearer <token>". Tokens come from DUEL_TOKENS, a file of
"<player> <token>" lines. The secret function is DUEL_SECRET (a .s or .bin path, mounted at run
time), and the logs live in DUEL_STATE. Requests run one at a time, so the log order is the order
the referee answered them.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("duel", os.path.join(HERE, "duel"))
_spec = importlib.util.spec_from_loader("duel", _loader)
duel = importlib.util.module_from_spec(_spec)
_loader.exec_module(duel)

LOCK = threading.Lock()
MAX_BODY = 64 * 1024


def load_tokens():
    tokens = {}
    with open(os.environ["DUEL_TOKENS"]) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and not line.startswith("#"):
                tokens[parts[1]] = parts[0]
    if not tokens:
        sys.exit("no tokens in %s" % os.environ["DUEL_TOKENS"])
    return tokens


TOKENS = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, obj):
        body = (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def player(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:].strip() not in TOKENS:
            self.reply(401, {"error": "unknown token"})
            return None
        return TOKENS[auth[7:].strip()]

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            raise duel.DuelError("request too large")
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise duel.DuelError("body is not JSON")

    def do_GET(self):
        player = self.player()
        if player is None:
            return
        if self.path == "/score":
            names = sorted(set(TOKENS.values()))
            self.reply(200, {p: duel.count(p) for p in names})
        elif self.path == "/log":
            p = os.path.join(duel.state_dir(), "%s.jsonl" % player)
            lines = open(p).read().splitlines() if os.path.exists(p) else []
            self.reply(200, [json.loads(line) for line in lines])
        else:
            self.reply(404, {"error": "no such endpoint"})

    def do_POST(self):
        player = self.player()
        if player is None:
            return
        try:
            req = self.body()
            if self.path == "/query":
                inp = duel.parse_hex(str(req.get("input", "")))
                with LOCK:
                    self.reply(200, duel.do_query(player, inp))
            elif self.path == "/check":
                with tempfile.TemporaryDirectory() as tmp:
                    if "source" in req:
                        path = os.path.join(tmp, "candidate.s")
                        open(path, "w").write(str(req["source"]))
                    elif "bin" in req:
                        path = os.path.join(tmp, "candidate.bin")
                        open(path, "wb").write(bytes.fromhex(str(req["bin"])))
                    else:
                        raise duel.DuelError('send "source" or "bin"')
                    words = duel.assemble(path)
                with LOCK:
                    self.reply(200, duel.do_check(player, words))
            else:
                self.reply(404, {"error": "no such endpoint"})
        except duel.DuelError as e:
            self.reply(400, {"error": str(e)})
        except ValueError as e:
            self.reply(400, {"error": str(e)})


def main():
    global TOKENS
    TOKENS = load_tokens()
    duel.secret()  # fail at startup, not on the first query, if the secret does not assemble
    port = int(os.environ.get("DUEL_PORT", "8080"))
    srv = http.server.ThreadingHTTPServer(("", port), Handler)
    print("duel referee listening on %d, players: %s" % (port, ", ".join(sorted(set(TOKENS.values())))),
          flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
