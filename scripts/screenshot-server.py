#!/usr/bin/env python3
"""Local demo API and image for documentation captures; no external service needed."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent.parent

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/preview.png':
            data = (ROOT / 'TinyEdit/Assets.xcassets/AppIconNotepad.imageset/icon.png')
            body = data.read_bytes()
            content_type = 'image/png'
        elif self.path == '/v1/notes':
            body = json.dumps({'notes': [{'id': 1, 'title': 'Release checklist', 'done': True}, {'id': 2, 'title': 'Write something useful', 'done': False}], 'total': 2}).encode()
            content_type = 'application/json'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(('localhost', 18473), Handler).serve_forever()
