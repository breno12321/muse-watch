from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, unquote
import os

os.chdir(Path(__file__).resolve().parent.parent)
PUBLIC_PATHS = {
    '/Preview/', '/Preview/index.html', '/Preview/app.js', '/Preview/style.css',
    '/MuseWatch/Assets.xcassets/CalAvatar.imageset/avatar.jpg',
}

class Handler(SimpleHTTPRequestHandler):
    def allowed(self):
        return unquote(urlsplit(self.path).path) in PUBLIC_PATHS

    def do_GET(self):
        if not self.allowed():
            self.send_error(404)
            return
        super().do_GET()

    def do_HEAD(self):
        if not self.allowed():
            self.send_error(404)
            return
        super().do_HEAD()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

print('Muse Watch preview: http://127.0.0.1:8765/Preview/', flush=True)
ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
