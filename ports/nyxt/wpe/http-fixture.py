#!/usr/bin/env python3
"""Local HTTP/TLS test origin, never an engine or guest OS dependency."""
import gzip
import argparse
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, required=True)
parser.add_argument('--tls', action='store_true')
args = parser.parse_args()
d = args.directory
d.mkdir(parents=True, exist_ok=True)
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        if isinstance(self.connection, ssl.SSLSocket):
            print("TLS-SESSION", self.server.server_port,
                  "resumed=" + str(self.connection.session_reused), flush=True)
        route = self.path.split('?')[0]
        if route == '/media.webm':
            media = Path(__file__).resolve().parents[3]/'build/wpe-assessment/media.webm'
            body = media.read_bytes()
            start, end = 0, len(body)-1
            requested = self.headers.get('Range', '')
            if requested.startswith('bytes='):
                first, last = requested[6:].split('-', 1)
                start, end = int(first or 0), int(last or end)
                if start > end or end >= len(body):
                    self.send_error(416); return
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
            else:
                self.send_response(200)
            body = body[start:end+1]
            self.send_header('Content-Type', 'video/webm')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
        body = b'DARTERFLY-GIO-HTTP\n'
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/cookie')
            self.send_header('Set-Cookie', 'darter=world; Path=/; Secure; HttpOnly')
            body = b''
        elif self.path == '/cookie':
            body = b'COOKIE-PASS' if 'darter=world' in self.headers.get('Cookie','') else b'COOKIE-FAIL'
            self.send_response(200)
        else:
            self.send_response(200)
        content_type = 'text/plain'
        if self.path.split('?')[0] == '/browser':
            content_type = 'text/html; charset=utf-8'
            body = b'''<!doctype html><meta charset=utf-8>
<title>Nyxt on Darterfly</title>
<style>html,body{margin:0;background:#203040;color:#edf4eb;font:18px sans-serif}
main{padding:36px}h1{color:#ef7d27;font-size:30px}input{position:absolute;
left:36px;top:160px;width:320px;height:36px;font:22px sans-serif}
small{display:block;margin-top:100px;color:#b0c8c0}</style>
<main><h1>Nyxt on Darterfly</h1><p>A native WPE page. Lisp is in command.</p>
<input id=entry placeholder="Type here"><small>HTTPS / isolated worlds / CPU rendering</small></main>
<script>window.realClicks=0;window.realKeys=0;
document.addEventListener('click',e=>{if(e.isTrusted)window.realClicks++});
document.addEventListener('keydown',e=>{if(e.isTrusted)window.realKeys++});</script>'''
        elif route == '/media':
            content_type = 'text/html; charset=utf-8'
            body = b'''<!doctype html><meta charset=utf-8><title>Darterfly media</title>
<style>body{background:#203040;color:white;font:20px sans-serif}video{width:640px;height:360px}</style>
<h1>Native video and audio</h1><video id=v controls preload=auto src=/media.webm></video>
<p id=status>Loading</p><script>
window.events=[];window.videoFrames=0;
for(const name of ['loadedmetadata','playing','pause','seeking','seeked','ended','error'])
v.addEventListener(name,()=>{events.push({event:name,time:v.currentTime});
document.querySelector('#status').textContent=JSON.stringify(events);});
if(v.requestVideoFrameCallback){let tick=()=>{window.videoFrames++;v.requestVideoFrameCallback(tick)};
v.requestVideoFrameCallback(tick);}
</script>'''
        elif self.path == '/page':
            content_type = 'text/html; charset=utf-8'
            body = (b'<!doctype html><meta charset=utf-8><title>Loading</title>'
                    b'<link rel="stylesheet" href="/page.css"><div id="box"></div>'
                    b'<script src="/page.js"></script>')
        elif self.path == '/page.css':
            content_type = 'text/css'
            body = (b'html,body{margin:0;background:#203040;overflow:hidden}'
                    b'#box{position:absolute;left:16px;top:16px;width:64px;height:32px}')
        elif self.path == '/page.js':
            content_type = 'application/javascript'
            body = (b"const box=document.querySelector('#box');"
                    b"box.dataset.answer=String(6*7);box.style.backgroundColor='#ef7d27';"
                    b"document.title='Darterfly '+box.dataset.answer;")
        if self.path == '/gzip':
            body = gzip.compress(b'DARTERFLY-GZIP')
            self.send_header('Content-Encoding','gzip')
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding','chunked')
            body = b'6\r\nDARTER\r\n3\r\nFLY\r\n0\r\n\r\n'
        else:
            self.send_header('Content-Length',str(len(body)))
        self.send_header('Content-Type',content_type)
        self.send_header('Connection','close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Connection','close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
    def log_message(self, fmt, *values):
        print("ORIGIN", self.server.server_port, fmt % values, flush=True)
def openssl(*args):
    env = dict(os.environ)
    for key in ['LD_LIBRARY_PATH', 'LD_PRELOAD', 'OPENSSL_CONF', 'OPENSSL_MODULES']:
        env.pop(key, None)
    subprocess.run(['openssl', *map(str,args)], cwd=d, check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
class Origin(ThreadingHTTPServer):
    def get_request(self):
        try:
            return super().get_request()
        except ssl.SSLError as error:
            print("TLS-HANDSHAKE", self.server_port, str(error), flush=True)
            raise
    def shutdown_request(self, request):
        if isinstance(request, ssl.SSLSocket):
            # Send TLS close_notify rather than truncating the TLS stream.
            request.settimeout(3)
            try: request = request.unwrap()
            except (OSError, ssl.SSLError): pass
        super().shutdown_request(request)
servers = [Origin(('127.0.0.1',18765), Handler)]
if args.tls:
    for name in ['ca', 'untrusted-ca']:
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','2',
                '-subj','/CN=Darterfly test '+name,'-keyout',name+'.key',
                '-out',name+'.pem','-addext','basicConstraints=critical,CA:TRUE')
    openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=localhost',
            '-keyout','server.key','-out','server.csr')
    (d/'server.ext').write_text('subjectAltName=DNS:localhost,IP:10.0.2.2\n'
                              'extendedKeyUsage=serverAuth\n'
                              'basicConstraints=critical,CA:FALSE\n')
    openssl('x509','-req','-in','server.csr','-CA','ca.pem','-CAkey','ca.key',
            '-CAcreateserial','-days','2','-extfile','server.ext','-out','server.pem')
    (d/'index').write_text('')
    (d/'serial').write_text('1000\n')
    (d/'ca.conf').write_text("""[ ca ]
default_ca = test
[ test ]
database = index
serial = serial
new_certs_dir = .
certificate = ca.pem
private_key = ca.key
default_md = sha256
policy = policy
unique_subject = no
[ policy ]
commonName = supplied
""")
    for name, start, end in [('expired','20000101000000Z','20000102000000Z'),
                             ('future','20990101000000Z','21000101000000Z')]:
        openssl('ca','-batch','-config','ca.conf','-in','server.csr',
                '-startdate',start,'-enddate',end,'-extfile','server.ext',
                '-out',name+'.pem','-notext')
    (d/'wrong-host.ext').write_text('subjectAltName=DNS:wrong.invalid\n'
                                   'extendedKeyUsage=serverAuth\n'
                                   'basicConstraints=critical,CA:FALSE\n')
    for name, authority, ext in [('wrong-host','ca','wrong-host.ext'),
                                  ('untrusted','untrusted-ca','server.ext')]:
        openssl('x509','-req','-in','server.csr','-CA',authority+'.pem',
                '-CAkey',authority+'.key','-CAcreateserial','-days','2',
                '-extfile',ext,'-out',name+'.pem')
    for port, version, cert in [(18766,ssl.TLSVersion.TLSv1_3,'server'),
                                (18767,ssl.TLSVersion.TLSv1_2,'server'),
                                (18768,ssl.TLSVersion.TLSv1_3,'expired'),
                                (18769,ssl.TLSVersion.TLSv1_3,'future'),
                                (18770,ssl.TLSVersion.TLSv1_3,'wrong-host'),
                                (18771,ssl.TLSVersion.TLSv1_3,'untrusted'),
                                (18772,ssl.TLSVersion.TLSv1_3,'server')]:
        server=Origin(('127.0.0.1',port),Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version=context.maximum_version=version
        if port == 18772:
            context.set_ecdh_curve('prime256v1')  # Exercise HelloRetryRequest.
        context.load_cert_chain(d/(cert+'.pem'),d/'server.key')
        server.socket=context.wrap_socket(server.socket,server_side=True)
        servers.append(server)
for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()
(d/'ready').write_text('ready\n')
try:
    while True: time.sleep(3600)
finally:
    for server in servers: server.server_close()
