#!/usr/bin/env python3
"""Tiny sync server for myhn.html hidden story IDs.

GET  /  -> JSON array of hidden IDs, newest first (entries older than 7 days are pruned)
POST /  -> JSON array of IDs to mark hidden now, returns 204

No auth: if exposed publicly, put it behind a reverse proxy on a non-guessable path.
"""

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MAX_AGE_SECONDS = 7 * 86400


class Store:
    def __init__(self, path):
        self.path = path
        self.ids = {}  # str(id) -> unix timestamp
        if os.path.exists(path):
            with open(path) as f:
                self.ids = json.load(f)

    def prune(self):
        cutoff = time.time() - MAX_AGE_SECONDS
        self.ids = {k: v for k, v in self.ids.items() if v >= cutoff}

    def get_ids(self):
        self.prune()
        return [int(k) for k, _ in sorted(self.ids.items(), key=lambda kv: kv[1], reverse=True)]

    def add_ids(self, ids):
        now = time.time()
        for i in ids:
            self.ids[str(int(i))] = now
        self.prune()
        with open(self.path, 'w') as f:
            json.dump(self.ids, f)


class Handler(BaseHTTPRequestHandler):
    store = None
    path_prefix = '/'

    def _check_path(self):
        if self.path.rstrip('/') != self.path_prefix.rstrip('/'):
            self._headers(404)
            return False
        return True

    def _headers(self, status, length=0):
        self.send_response(status)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        if length:
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(length))
        self.end_headers()

    def do_OPTIONS(self):
        if not self._check_path():
            return
        self._headers(204)

    def do_GET(self):
        if not self._check_path():
            return
        body = json.dumps(self.store.get_ids()).encode()
        self._headers(200, len(body))
        self.wfile.write(body)

    def do_POST(self):
        if not self._check_path():
            return
        try:
            length = int(self.headers.get('Content-Length', 0))
            ids = json.loads(self.rfile.read(length))
            self.store.add_ids(ids)
            self._headers(204)
        except (ValueError, TypeError):
            self._headers(400)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8017)
    parser.add_argument('--db', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hidden_ids.json'))
    parser.add_argument('--path', default='/', help='only answer on this path, e.g. /hn-<secret>')
    args = parser.parse_args()

    Handler.store = Store(args.db)
    Handler.path_prefix = args.path
    print(f'Serving on port {args.port}, db: {args.db}')
    HTTPServer(('', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
