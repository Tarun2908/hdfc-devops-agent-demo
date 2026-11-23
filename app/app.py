import json, os, sys, time, html, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEED = [("Alpha", "First sample item"), ("Bravo", "Second sample item"), ("Charlie", "Third sample item"),
        ("Delta", "Fourth sample item"), ("Echo", "Fifth sample item")]
DDL = ("CREATE TABLE items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, "
       "description VARCHAR(255), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
CFG = {}


def format_log(level, msg):
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return json.dumps({"timestamp": ts, "level": level, "message": str(msg)})


def log(level, msg):
    print(format_log(level, msg), flush=True)


def render_page(rows):
    e = lambda v: html.escape("" if v is None else str(v))
    li = "".join("<li>%s: <b>%s</b> - %s (%s)</li>" % (e(r[0]), e(r[1]), e(r[2]), e(r[3])) for r in rows)
    return "<!doctype html><html><head><title>Items</title></head><body><h1>Items</h1><ul>%s</ul></body></html>" % li


def render_error():
    return ("<!doctype html><html><head><title>Error</title></head><body><h1>Service unavailable</h1>"
            "<p>The service is temporarily unavailable. Please try again later.</p></body></html>")


def load_secret():
    import boto3
    c = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION"))
    return json.loads(c.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])


def connect(timeout=5, db=True):
    import pymysql
    s = CFG["secret"]
    return pymysql.connect(host=s["host"], port=int(s.get("port", 3306)), user=s["username"], password=s["password"],
                           database=CFG["db"] if db else None, connect_timeout=timeout,
                           read_timeout=timeout, write_timeout=timeout)


def seed(conn):
    cur = conn.cursor()
    cur.execute("SELECT GET_LOCK('seed', 10)")
    if cur.fetchone()[0] != 1:
        raise RuntimeError("could not obtain seed lock")
    try:
        cur.execute("CREATE DATABASE IF NOT EXISTS `%s`" % CFG["db"].replace("`", ""))
        conn.select_db(CFG["db"])
        cur.execute("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='items'")
        if cur.fetchone()[0] == 0:
            cur.execute(DDL)
            cur.executemany("INSERT INTO items (name, description) VALUES (%s, %s)", SEED)
            conn.commit()
            log("INFO", "created table items and inserted %d seed rows" % len(SEED))
    finally:
        cur.execute("SELECT RELEASE_LOCK('seed')")
        cur.fetchall()


def startup(sleep=time.sleep):
    CFG["secret"] = load_secret()
    CFG["db"] = CFG["secret"].get("dbname") or "app"
    for attempt in range(1, 13):
        try:
            conn = connect(10, db=False)
            break
        except Exception as ex:
            log("ERROR", "db connect attempt %d/12 failed: %s" % (attempt, type(ex).__name__))
            if attempt == 12:
                sys.exit(1)
            sleep(5)
    try:
        seed(conn)
    finally:
        conn.close()


def query(sql, timeout):
    conn = connect(timeout)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        return cur.fetchall()
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        log("INFO" if code < 500 else "ERROR", "%s %s -> %d" % (self.command, self.path, code))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/healthz":
            try:
                query("SELECT 1", 2)
                self.reply(200, "ok", "text/plain")
            except Exception as ex:
                log("ERROR", "health check failed: %s" % type(ex).__name__)
                self.reply(503, "unavailable", "text/plain")
        elif path == "/":
            try:
                rows = query("SELECT id, name, description, created_at FROM items ORDER BY id LIMIT 100", 5)
                self.reply(200, render_page(rows))
            except Exception as ex:
                log("ERROR", "query failed: %s" % type(ex).__name__)
                self.reply(503, render_error())
        else:
            self.reply(404, "not found", "text/plain")


if __name__ == "__main__":
    startup()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
