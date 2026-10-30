#!/usr/bin/env python3
# ============================================================================
# 无头浏览器的 DOM 取回工具（只用标准库，自己实现 WebSocket 帧）。
#
# 为什么不用 `--dump-dom`：Edge 156 起，`--dump-dom` / `--screenshot` 在这台
# 机器上即使换了全新的 --user-data-dir 也一个字都不输出（rc=0、stdout 空），
# 老版 --headless 同样如此；而 CDP 口子是好的。所以自测一律走 CDP：
# 起浏览器 → 读 DevToolsActivePort → 连页面目标 → 等页面自己说「报告好了」
# → 取 outerHTML。
#
# 用法（命令行，方便手动排查）:
#   python tools/domfetch.py <url> [等待秒数] —— 打印取回的 DOM 前 2000 字符
# 作为库:
#   from domfetch import fetch_dom
#   html = fetch_dom(edge, url, ready_js, timeout_s=40, profdir=...)
# ============================================================================
import base64, json, os, shutil, socket, struct, subprocess, sys, time
import urllib.request

def _kill_by_profdir(profdir):
    """按 profile 路径收掉还活着的浏览器进程（只用在自己测出来的那一个目录上）。

    为什么不能只 kill 启动器：msedge.exe 被拉起来后立刻退出，真正的浏览器是
    被系统重新挂到别处的进程，kill 启动器完全够不着它。CDP 的 Browser.close
    能收干净，但万一连不上，就靠这个按命令行路径精确匹配兜底。
    """
    if os.name != "nt" or not profdir:
        return
    pat = profdir.replace("'", "''")
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" "
          "| Where-Object { $_.CommandLine -like '*" + pat + "*' } "
          "| ForEach-Object { taskkill /PID $_.ProcessId /F | Out-Null }")
    try:
        subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=60)
    except Exception:
        pass


class _WS:
    """刚好够用：文本帧、客户端掩码、不分片。"""

    def __init__(self, url, timeout=60):
        assert url.startswith("ws://")
        hostport, _, path = url[5:].partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key))
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("websocket 握手时连接被关闭")
            buf += chunk
        if b" 101 " not in buf.split(b"\r\n")[0]:
            raise IOError("websocket 握手失败: " + buf[:160].decode("latin1"))
        self.buf = buf.split(b"\r\n\r\n", 1)[1]

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("CDP 连接被关闭")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        data = text.encode()
        n = len(data)
        if n < 126:
            head = struct.pack("!BB", 0x81, 0x80 | n)
        elif n <= 0xFFFF:
            head = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            head = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        while True:
            b0, b1 = struct.unpack("!BB", self._read(2))
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(n) if n else b""
            if op == 0x8:
                raise IOError("服务端关闭了 CDP 连接")
            if op in (0x1, 0x2):
                return payload.decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class _CDP:
    def __init__(self, wsurl):
        self.ws = _WS(wsurl)
        self.seq = 0

    def call(self, method, params=None, timeout=60):
        self.seq += 1
        mid = self.seq
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise IOError("%s -> %s" % (method, json.dumps(msg["error"])[:300]))
                return msg.get("result", {})
        raise IOError("CDP 调用超时: " + method)

    def eval(self, expr):
        res = self.call("Runtime.evaluate", {"expression": expr, "returnByValue": True})
        return res.get("result", {}).get("value")


def _wait_port(profdir, proc, timeout=45):
    """等 DevToolsActivePort 出现。

    注意：msedge.exe 的启动器进程经常「rc=0 立刻退出」，真正的浏览器进程随后
    才写这个文件 —— 所以不能因为启动器退出就判失败，只能等文件。
    """
    apfile = os.path.join(profdir, "DevToolsActivePort")
    end = time.time() + timeout
    while time.time() < end:
        try:
            with open(apfile, encoding="utf-8") as fh:
                port = int(fh.readline().strip())
            if port:
                return port
        except Exception:
            pass
        time.sleep(0.3)
    raise IOError("等不到 DevToolsActivePort（启动器 rc=%s）" % proc.poll())


def _page_target(port, want, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        try:
            raw = urllib.request.urlopen("http://127.0.0.1:%d/json/list" % port, timeout=3).read()
            tabs = [t for t in json.loads(raw.decode("utf-8", "replace"))
                    if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
            for t in tabs:
                if not want or want in (t.get("url") or ""):
                    return t["webSocketDebuggerUrl"]
        except Exception:
            pass
        time.sleep(0.4)
    raise IOError("等不到页面目标（%s）" % want)


def _new_profdir():
    return os.path.join(os.environ.get("TEMP", "/tmp"),
                        "domfetch_%d_%d" % (os.getpid(), int(time.time() * 1000)))


class Session(object):
    """打开 → 等就绪 → 取 DOM / 截图，用完一定把进程收掉。

    profdir 每次都要是新的：上一次被强杀的实例会留下 SingletonLock，
    新实例会「委托」给已经不存在的进程，于是端口永远等不到。
    """

    def __init__(self, edge, url, profdir=None, width=500, height=1400,
                 scale=1, timeout_s=45, poll_ms=200):
        self.edge, self.url = edge, url
        self.profdir = profdir or _new_profdir()
        self.width, self.height, self.scale = width, height, scale
        self.timeout_s, self.poll_ms = timeout_s, poll_ms
        self.proc = None
        self.cdp = None

    def __enter__(self):
        if os.path.isdir(self.profdir):
            shutil.rmtree(self.profdir, ignore_errors=True)
        cmd = [self.edge, "--headless=new", "--disable-gpu", "--no-sandbox",
               "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
               "--disable-extensions", "--disable-sync",
               "--window-size=%d,%d" % (self.width, self.height),
               "--remote-debugging-port=0",
               "--user-data-dir=" + self.profdir, self.url]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        port = _wait_port(self.profdir, self.proc)
        want = self.url.split("?")[0].rstrip("/").split("/")[-1]
        self.cdp = _CDP(_page_target(port, want))
        self.cdp.call("Runtime.enable")
        self.cdp.call("Page.enable")
        if self.scale != 1:
            # 2 倍像素密度：截出来的图给文档/酷安用，不糊
            self.cdp.call("Emulation.setDeviceMetricsOverride", {
                "width": self.width, "height": self.height,
                "deviceScaleFactor": self.scale, "mobile": False})
        return self

    def wait(self, ready_js):
        end = time.time() + self.timeout_s
        while time.time() < end:
            try:
                if self.cdp.eval("(function(){try{return !!(%s)}catch(e){return false}})()"
                                 % ready_js):
                    return True
            except IOError:
                pass
            time.sleep(self.poll_ms / 1000.0)
        return False

    def dom(self):
        return self.cdp.eval("document.documentElement.outerHTML") or ""

    def png(self, path):
        m = self.cdp.call("Page.getLayoutMetrics")
        size = m.get("cssContentSize") or m.get("contentSize") or {}
        h = int(size.get("height") or self.height)
        res = self.cdp.call("Page.captureScreenshot", {
            "format": "png", "captureBeyondViewport": True,
            "clip": {"x": 0, "y": 0, "width": self.width, "height": h, "scale": 1}})
        with open(path, "wb") as fh:
            fh.write(base64.b64decode(res["data"]))
        return path

    def __exit__(self, *exc):
        if self.cdp:
            self.cdp.ws.close()
        # 先让浏览器自己收：它会把所有子进程一起带走。kill 启动器没用 ——
        # msedge.exe 的启动器只是壳，真正的浏览器进程还活着，
        # 会一直占着 profile（下一次 rmtree 就报 WinError 32）和端口。
        if self.cdp:
            try:
                self.cdp.call("Browser.close", timeout=5)
            except Exception:
                pass
        if self.proc:
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/T", "/F"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    self.proc.kill()
            except Exception:
                pass
            # 等它真的死掉再走：否则 profile 里的缓存文件还开着，
            # 调用方紧接着 rmtree 会 PermissionError（Windows 就是这样）。
            try:
                self.proc.wait(timeout=10)
            except Exception:
                pass
        time.sleep(0.4)
        if os.path.isdir(self.profdir):
            _kill_by_profdir(self.profdir)
            time.sleep(0.3)
        shutil.rmtree(self.profdir, ignore_errors=True)
        return False


def fetch_dom(edge, url, ready_js, timeout_s=45, profdir=None,
              width=500, height=1400, poll_ms=200):
    """开一个无头浏览器打开 url，等 ready_js 为真（或超时）后返回 outerHTML。"""
    with Session(edge, url, profdir=profdir, width=width, height=height,
                 timeout_s=timeout_s, poll_ms=poll_ms) as s:
        s.wait(ready_js)
        return s.dom()


def capture_png(edge, url, out_png, ready_js="true", timeout_s=45, profdir=None,
                width=500, height=1400, scale=2):
    """同 fetch_dom，但截一张整页 PNG（默认 2 倍像素密度）。"""
    with Session(edge, url, profdir=profdir, width=width, height=height,
                 scale=scale, timeout_s=timeout_s) as s:
        s.wait(ready_js)
        return s.png(out_png)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    url = sys.argv[1]
    wait = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
    edge = (os.environ.get("EDGE_PATH")
            or r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
    html = fetch_dom(edge, url, "true", timeout_s=wait)
    print("DOM %d 字符" % len(html))
    print(html[:2000])
    return 0


if __name__ == "__main__":
    sys.exit(main())