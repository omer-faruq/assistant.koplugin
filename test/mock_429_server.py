#!/usr/bin/env python3
"""
Mock LLM API that always returns 429 — for testing the plugin's retry mechanism.

Usage:
  python3 test/mock_429_server.py                          # always 429, Retry-After: 2s
  python3 test/mock_429_server.py --port 8765 --retry-after 3
  python3 test/mock_429_server.py --fail 3 --then 200      # 429 x3 then 200 (test success-after-retries)
  python3 test/mock_429_server.py --retry-after-ms 1500    # test retry-after-ms header
  python3 test/mock_429_server.py --http-date               # test HTTP-date format

Configure the plugin to hit it:
  1. In KOReader: AI Assistant → Settings → Provider API → Add Provider
     handler: openai, base_url: http://127.0.0.1:8765/v1, api_key: sk-test, model: gpt-4
  2. Or add to configuration.sample.lua:
     provider_settings = { openai_mock429 = { handler="openai", base_url="http://127.0.0.1:8765/v1", api_key="sk-test", model="gpt-4" } }

All paths (GET/POST /v1/models, /v1/chat/completions, /v1/messages, etc.) return 429.
"""

import argparse
import json
import random
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timezone, timedelta
from email.utils import formatdate

parser = argparse.ArgumentParser(description="Mock 429 LLM API")
parser.add_argument("--port", type=int, default=8765, help="listen port (default 8765)")
parser.add_argument("--host", default="127.0.0.1", help="listen host (default 127.0.0.1)")
parser.add_argument("--retry-after", type=int, default=None, help="Retry-After seconds (default random 1-10; pass fixed value to disable randomization)")
parser.add_argument("--retry-after-ms", type=int, default=None, help="if set, send retry-after-ms instead")
parser.add_argument("--http-date", action="store_true", help="send Retry-After as HTTP-date instead of delta-seconds")
parser.add_argument("--fail", type=int, default=0, help="return 429 N times then 200 (0 = always 429)")
parser.add_argument("--then", type=int, default=200, help="status after --fail exhausted (default 200)")
args = parser.parse_args()

counter = {"n": 0}

class Handler(BaseHTTPRequestHandler):
    def send_429(self):
        counter["n"] += 1
        n = counter["n"]
        # decide status
        if args.fail > 0 and n > args.fail:
            self.send_response(args.then)
            self.send_header("Content-Type", "application/json")
            body = json.dumps({
                "id": "chatcmpl-mock",
                "choices": [{"message": {"content": f"Mock success after {args.fail} retries (attempt {n})"}, "finish_reason": "stop"}]
            })
            # also handle streaming-like response if client asked stream
            self.end_headers()
            self.wfile.write(body.encode())
            print(f"[{n}] -> {args.then} (success after retries)")
            return

        # 10秒内随机：未指定 --retry-after 时 1-10s 随机，否则用固定值
        delay = args.retry_after if args.retry_after is not None else random.randint(1, 10)
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        if args.retry_after_ms is not None:
            self.send_header("retry-after-ms", str(args.retry_after_ms))
            print(f"[{n}] -> 429 retry-after-ms: {args.retry_after_ms} (delay={delay}s)")
        elif args.http_date:
            future = datetime.now(timezone.utc) + timedelta(seconds=delay)
            http_date = formatdate(timeval=future.timestamp(), usegmt=True)
            self.send_header("Retry-After", http_date)
            print(f"[{n}] -> 429 Retry-After: {http_date} (HTTP-date, delay={delay}s)")
        else:
            self.send_header("Retry-After", str(delay))
            print(f"[{n}] -> 429 Retry-After: {delay}s")
        # useful for verifying non-retryable paths:
        # self.send_header("x-should-retry", "true")

        body = json.dumps({
            "error": {
                "message": f"Rate limit exceeded. Please try again in {delay}.000s.",
                "type": "rate_limit_error",
                "code": "rate_limit_exceeded",
            }
        })
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self): self.send_429()
    def do_POST(self): 
        # drain body
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length: self.rfile.read(length)
        self.send_429()
    def do_OPTIONS(self): self.send_429()
    def log_message(self, format, *a): pass  # suppress default log, we print above

addr = (args.host, args.port)
ra = f"{args.retry_after}s" if args.retry_after is not None else "random 1-10s"
print(f"Mock 429 LLM API listening on http://{args.host}:{args.port}/v1  (Retry-After={ra}, fail={args.fail})")
print(f"  Test: curl -i http://{args.host}:{args.port}/v1/chat/completions -X POST -d '{{\"model\":\"gpt-4\"}}' -H 'Content-Type: application/json'")
print("  KOReader: base_url=http://{}:{}/v1  handler=openai  api_key=sk-test".format(args.host, args.port))
try:
    HTTPServer(addr, Handler).serve_forever()
except KeyboardInterrupt:
    print("\nStopped.")
