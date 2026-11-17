#!/usr/bin/env python3
"""Offline integration: the real Rust binary, stdio RPC and a local OpenAI mock."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent

class API(BaseHTTPRequestHandler):
    calls = []
    partial_seen = threading.Event()
    streaming_enabled = threading.Event()
    def log_message(self, *_): pass
    def reply(self, value, status=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        assert self.path == '/compatible/v1/models'
        assert self.headers.get('Authorization') == 'Bearer fixture-only-key'
        self.reply({'data': [{'id': 'fixture-chat'}]})
    def do_POST(self):
        assert self.path == '/compatible/v1/chat/completions'
        assert self.headers.get('Authorization') == 'Bearer fixture-only-key'
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['model'] == 'deepseek-chat'
        self.calls.append(body)
        assert body['stream'] is True and body['stream_options']['include_usage'] is True
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
        self.end_headers()
        def event(value):
            data = ('data: ' + json.dumps(value, ensure_ascii=False) + '\r\n\r\n').encode()
            for byte in data:
                self.wfile.write(bytes([byte]))
            self.wfile.flush()
        event({'model': 'fixture-chat', 'choices': [{'index': 0, 'delta': {'content': '结论：'}}]})
        if self.streaming_enabled.is_set():
            assert self.partial_seen.wait(timeout=5), 'draft was not delivered until response completed'
        event({'choices': [{'index': 0, 'delta': {'content': '周五发布。'}, 'finish_reason': 'stop'}]})
        event({'choices': [], 'usage': {'prompt_tokens': 21, 'completion_tokens': 8}})
        self.wfile.write(b'data: [DONE]\r\n\r\n')
        self.wfile.flush()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--backend', default=str(ROOT / 'build/meeting-summary'))
    parser.add_argument('--swift', action='store_true')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), API)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}/compatible/v1'
    process = subprocess.Popen([args.backend], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env={'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'})
    messages = queue.Queue()
    def read():
        for line in process.stdout:
            messages.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    def send(identifier, method, params):
        process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()
    try:
        send('handshake', 'initialize', {'protocolVersion': 1})
        handshake = messages.get(timeout=5)
        assert handshake['id'] == 'handshake' and handshake['result']['protocolVersion'] == 1
        params = {'baseURL': base, 'model': 'deepseek-chat', 'apiKey': 'fixture-only-key', 'text': '周五发布。', 'locale': 'zh-CN',
                  'meetingID': 'fixture-meeting', 'inputFingerprint': 'a' * 64}
        API.streaming_enabled.set()
        send('request-1', 'summary/generate', params)
        progress = []
        while True:
            message = messages.get(timeout=5)
            if message.get('method') == 'summary/progress':
                assert message['params']['requestID'] == 'request-1'
                progress.append(message['params'])
                if message['params'].get('draft') == '结论：':
                    API.partial_seen.set()
                continue
            assert message['id'] == 'request-1'
            result = message['result']
            assert result['text'] == '结论：周五发布。' and result['model'] == 'fixture-chat'
            assert result['meetingID'] == params['meetingID'] and result['inputFingerprint'] == params['inputFingerprint']
            assert result['usage'] == {'inputTokens': 21, 'outputTokens': 8}
            break
        assert API.partial_seen.is_set() and len(API.calls) == 1
        assert any(p.get('draft') == '结论：周五发布。' for p in progress)
        API.streaming_enabled.clear()
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert not process.stderr.read()
        if args.swift:
            environment = dict(os.environ, MEETING_TEST_SUMMARY_BASE_URL=base)
            subprocess.run([str(ROOT / 'scripts/test.sh'), '--filter', 'rustSummaryProviderIntegration'], cwd=ROOT, env=environment, check=True)
        print('PASS: streamed SSE → Rust → RPC drafts before HTTP completion; Unicode, usage and clean exit')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        server.shutdown()

if __name__ == '__main__':
    main()
