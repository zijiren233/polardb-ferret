#!/usr/bin/env python3
import datetime
import http.server
import json
import os
import re
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


BASE = os.environ.get("POLARDB_BASE", "/u01/polardb_pg")
DATA_ROOT = os.environ.get("POLARDB_DATA_DIR", "/var/polardb")
PGDATA = os.path.join(DATA_ROOT, "primary_datadir")
PORT = os.environ.get("POLARDB_PORT", "5432")
DB_USER = os.environ.get("POLARDB_USER", "postgres")
DB_PASSWORD = os.environ.get("POLARDB_PASSWORD", "")

POD_NAME = os.environ["POD_NAME"]


def serviceaccount_namespace():
    with open("/var/run/secrets/kubernetes.io/serviceaccount/namespace", encoding="utf-8") as ns_file:
        return ns_file.read().strip()


def resolve_namespace():
    namespace = os.environ.get("POD_NAMESPACE") or os.environ.get("CLUSTER_NAMESPACE")
    if not namespace or namespace.startswith("$("):
        return serviceaccount_namespace()
    return namespace


def component_name_from_pod():
    return re.sub(r"-[0-9]+$", "", POD_NAME)


def resolve_lease_name():
    lease_name = os.environ.get("POLARDB_HA_LEASE_NAME", "polardb-primary")
    component_name = os.environ.get("CLUSTER_COMPONENT_NAME") or component_name_from_pod()
    if "$(CLUSTER_COMPONENT_NAME)" in lease_name:
        lease_name = lease_name.replace("$(CLUSTER_COMPONENT_NAME)", component_name)
    if not lease_name or lease_name.startswith("$("):
        lease_name = f"{component_name}-primary"
    return lease_name


NAMESPACE = resolve_namespace()
LEASE_NAME = resolve_lease_name()
LEASE_DURATION = int(os.environ.get("POLARDB_HA_LEASE_DURATION_SECONDS", "30"))
RETRY_PERIOD = int(os.environ.get("POLARDB_HA_RETRY_PERIOD_SECONDS", "5"))
PROMOTE_TIMEOUT = int(os.environ.get("POLARDB_HA_PROMOTE_TIMEOUT_SECONDS", "60"))
FAILOVER_ENABLED = os.environ.get("POLARDB_HA_FAILOVER_ENABLED", "1").lower() in (
    "1",
    "true",
    "yes",
    "on",
)
PATCH_POD_ROLE = os.environ.get("POLARDB_HA_PATCH_POD_ROLE", "1").lower() in (
    "1",
    "true",
    "yes",
    "on",
)
ROLE_LABEL_KEY = os.environ.get("POLARDB_HA_ROLE_LABEL_KEY", "polardb-role")
ROLE_PRIMARY = os.environ.get("POLARDB_HA_PRIMARY_ROLE_VALUE", "primary")
ROLE_STANDBY = os.environ.get("POLARDB_HA_STANDBY_ROLE_VALUE", "standby")
ROLE_UNKNOWN = os.environ.get("POLARDB_HA_UNKNOWN_ROLE_VALUE", "unknown")
DEMOTED_MARKER = os.path.join(DATA_ROOT, "ha-demoted")
PRIMARY_HEADLESS_TEMPLATE = os.environ.get("POLARDB_HA_PRIMARY_HEADLESS_TEMPLATE", "")
POD_LABEL_SELECTOR = os.environ.get("POLARDB_HA_POD_LABEL_SELECTOR", "")
HTTP_LISTEN = os.environ.get("POLARDB_HA_HTTP_LISTEN", "0.0.0.0")
HTTP_PORT = int(os.environ.get("POLARDB_HA_HTTP_PORT", "5001"))

KUBE_HOST = os.environ.get("KUBERNETES_SERVICE_HOST")
KUBE_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def log(message):
    print(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} {message}", flush=True)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def kube_timestamp(dt=None):
    dt = dt or utc_now()
    return dt.isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_kube_timestamp(value):
    if not value:
        return None
    normalized = value.replace("Z", "+0000")
    if "." in normalized:
        base, rest = normalized.split(".", 1)
        fraction = rest[:6].ljust(6, "0")
        tz = rest[6:] or "+0000"
        if len(tz) == 6 and tz[3] == ":":
            tz = tz[:3] + tz[4:]
        normalized = f"{base}.{fraction}{tz}"
        fmt = "%Y-%m-%dT%H:%M:%S.%f%z"
    else:
        if len(normalized) >= 6 and normalized[-3] == ":" and normalized[-6] in "+-":
            normalized = normalized[:-3] + normalized[-2:]
        fmt = "%Y-%m-%dT%H:%M:%S%z"
    return datetime.datetime.strptime(normalized, fmt)


class KubeClient:
    def __init__(self):
        if not KUBE_HOST:
            raise RuntimeError("KUBERNETES_SERVICE_HOST is not set")
        self.base_url = f"https://{KUBE_HOST}:{KUBE_PORT}"
        with open(TOKEN_PATH, encoding="utf-8") as token_file:
            self.token = token_file.read().strip()
        self.context = ssl.create_default_context(cafile=CA_PATH)

    def request(self, method, path, body=None, content_type="application/json"):
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = content_type
        req = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, context=self.context, timeout=10) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            if exc.code in (404, 409):
                return exc.code, json.loads(raw) if raw else None
            raise RuntimeError(f"Kubernetes API {method} {path} failed: {exc.code} {raw}") from exc

    def get_lease(self):
        status, body = self.request(
            "GET",
            f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases/{LEASE_NAME}",
        )
        return None if status == 404 else body

    def create_lease(self):
        now = kube_timestamp()
        body = {
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": {"name": LEASE_NAME, "namespace": NAMESPACE},
            "spec": {
                "holderIdentity": POD_NAME,
                "leaseDurationSeconds": LEASE_DURATION,
                "acquireTime": now,
                "renewTime": now,
                "leaseTransitions": 0,
            },
        }
        status, lease = self.request(
            "POST",
            f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases",
            body,
        )
        return status == 201, lease

    def update_lease(self, lease, acquire=False):
        spec = lease.get("spec", {})
        previous_holder = spec.get("holderIdentity")
        transitions = int(spec.get("leaseTransitions") or 0)
        now = kube_timestamp()
        if previous_holder != POD_NAME:
            transitions += 1
        new_spec = {
            "holderIdentity": POD_NAME,
            "leaseDurationSeconds": LEASE_DURATION,
            "renewTime": now,
            "leaseTransitions": transitions,
        }
        if acquire or previous_holder != POD_NAME:
            new_spec["acquireTime"] = now
        lease["spec"] = new_spec
        status, body = self.request(
            "PUT",
            f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases/{LEASE_NAME}",
            lease,
        )
        return status == 200, body

    def set_pod_role(self, role):
        if not PATCH_POD_ROLE:
            return
        if role == ROLE_PRIMARY:
            self.clear_other_primary_roles()
        self.patch_pod_role(POD_NAME, role)

    def patch_pod_role(self, pod_name, role):
        patch = {"metadata": {"labels": {ROLE_LABEL_KEY: role}}}
        self.request(
            "PATCH",
            f"/api/v1/namespaces/{NAMESPACE}/pods/{pod_name}",
            patch,
            content_type="application/merge-patch+json",
        )

    def list_pods(self):
        path = f"/api/v1/namespaces/{NAMESPACE}/pods"
        if POD_LABEL_SELECTOR:
            path += "?labelSelector=" + urllib.parse.quote(POD_LABEL_SELECTOR, safe="")
        status, body = self.request("GET", path)
        if status != 200:
            return []
        return body.get("items", [])

    def clear_other_primary_roles(self):
        if not POD_LABEL_SELECTOR:
            return
        for pod in self.list_pods():
            metadata = pod.get("metadata", {})
            pod_name = metadata.get("name")
            labels = metadata.get("labels", {})
            if pod_name and pod_name != POD_NAME and labels.get(ROLE_LABEL_KEY) == ROLE_PRIMARY:
                log(f"clearing stale primary role label from {pod_name}")
                self.patch_pod_role(pod_name, ROLE_UNKNOWN)


def run(cmd, check=False, timeout=10):
    env = os.environ.copy()
    if DB_PASSWORD:
        env["PGPASSWORD"] = DB_PASSWORD
    result = subprocess.run(
        cmd,
        env=env,
        universal_newlines=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {result.stdout.strip()}")
    return result


def run_as_postgres(cmd, check=False, timeout=10):
    if os.geteuid() == 0:
        cmd = ["runuser", "-u", "postgres", "--"] + cmd
    return run(cmd, check=check, timeout=timeout)


def db_ready():
    result = run(
        [os.path.join(BASE, "bin/pg_isready"), "-h", "127.0.0.1", "-p", PORT, "-U", DB_USER, "-d", "postgres", "-q"],
        timeout=5,
    )
    return result.returncode == 0


def in_recovery():
    result = run(
        [
            os.path.join(BASE, "bin/psql"),
            "-h",
            "127.0.0.1",
            "-p",
            PORT,
            "-U",
            DB_USER,
            "-d",
            "postgres",
            "-At",
            "-c",
            "select pg_is_in_recovery()",
        ],
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stdout.strip())
    return result.stdout.strip().lower() in ("t", "true", "1")


def promote():
    log("promoting local standby")
    run_as_postgres(
        [
            os.path.join(BASE, "bin/pg_ctl"),
            "-D",
            PGDATA,
            "promote",
            "-w",
            "-t",
            str(PROMOTE_TIMEOUT),
        ],
        check=True,
        timeout=PROMOTE_TIMEOUT + 5,
    )


def primary_host_for_holder(holder):
    if PRIMARY_HEADLESS_TEMPLATE and holder:
        return PRIMARY_HEADLESS_TEMPLATE.replace("$(POD_NAME)", holder)
    return os.environ.get("POLARDB_HA_PRIMARY_HOST", "")


def psql_literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def current_primary_conninfo():
    result = run(
        [
            os.path.join(BASE, "bin/psql"),
            "-h",
            "127.0.0.1",
            "-p",
            PORT,
            "-U",
            DB_USER,
            "-d",
            "postgres",
            "-At",
            "-c",
            "show primary_conninfo",
        ],
        timeout=10,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def conninfo_host(conninfo):
    match = re.search(r"(?:^|\s)host=('[^']*'|\S+)", conninfo)
    if not match:
        return ""
    host = match.group(1)
    if host.startswith("'") and host.endswith("'"):
        host = host[1:-1]
    return host


def ensure_following(holder):
    if not holder or holder == POD_NAME:
        return
    host = primary_host_for_holder(holder)
    if not host:
        return
    desired = f"host={host} port={PORT} user={DB_USER} dbname=postgres application_name={POD_NAME}"
    if conninfo_host(current_primary_conninfo()) == host:
        return
    log(f"rewriting primary_conninfo to follow {holder}")
    run(
        [
            os.path.join(BASE, "bin/psql"),
            "-h",
            "127.0.0.1",
            "-p",
            PORT,
            "-U",
            DB_USER,
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            f"ALTER SYSTEM SET primary_conninfo = {psql_literal(desired)}",
        ],
        check=True,
        timeout=10,
    )
    run(
        [
            os.path.join(BASE, "bin/psql"),
            "-h",
            "127.0.0.1",
            "-p",
            PORT,
            "-U",
            DB_USER,
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            "SELECT pg_reload_conf()",
        ],
        check=True,
        timeout=10,
    )


def stop_local_primary():
    log("local postgres is primary but this pod does not hold the lease; stopping it")
    with open(DEMOTED_MARKER, "w", encoding="utf-8") as marker:
        marker.write(kube_timestamp() + "\n")
    run_as_postgres(
        [
            os.path.join(BASE, "bin/pg_ctl"),
            "-D",
            PGDATA,
            "-m",
            "fast",
            "-w",
            "stop",
        ],
        timeout=30,
    )


def lease_expired(lease):
    spec = lease.get("spec", {})
    renew_time = parse_kube_timestamp(spec.get("renewTime") or spec.get("acquireTime"))
    duration = int(spec.get("leaseDurationSeconds") or LEASE_DURATION)
    if renew_time is None:
        return True
    return utc_now() - renew_time > datetime.timedelta(seconds=duration)


def detect_role(kube):
    if not db_ready():
        return ROLE_UNKNOWN

    recovery = in_recovery()
    if recovery:
        return ROLE_STANDBY

    lease = kube.get_lease()
    if lease is None:
        return ROLE_UNKNOWN

    spec = lease.get("spec", {})
    if spec.get("holderIdentity") == POD_NAME and not lease_expired(lease):
        return ROLE_PRIMARY
    return ROLE_UNKNOWN


class RoleProbeHandler(http.server.BaseHTTPRequestHandler):
    kube = None

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path != "/v1.0/getrole":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found")
            return

        try:
            role = detect_role(self.kube)
            code = 200
        except Exception as exc:
            log(f"role probe failed: {exc}")
            role = ROLE_UNKNOWN
            code = 200

        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(role.encode("utf-8"))

    def log_message(self, fmt, *args):
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def start_http_server(kube):
    RoleProbeHandler.kube = kube
    server_cls = getattr(http.server, "ThreadingHTTPServer", ThreadingHTTPServer)
    server = server_cls((HTTP_LISTEN, HTTP_PORT), RoleProbeHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log(f"started role probe HTTP server on {HTTP_LISTEN}:{HTTP_PORT}")


def reconcile(kube):
    ready = db_ready()
    recovery = None
    if ready:
        recovery = in_recovery()

    if not ready:
        kube.set_pod_role(ROLE_UNKNOWN)
        return

    lease = kube.get_lease()
    if lease is None:
        if recovery:
            kube.set_pod_role(ROLE_STANDBY)
            return
        created, _ = kube.create_lease()
        if created:
            log("created primary lease")
            kube.set_pod_role(ROLE_PRIMARY)
        return

    holder = lease.get("spec", {}).get("holderIdentity")
    expired = lease_expired(lease)

    if holder == POD_NAME:
        if recovery:
            log("this pod holds the lease but postgres is still in recovery")
            kube.set_pod_role(ROLE_STANDBY)
            return
        updated, _ = kube.update_lease(lease)
        if updated:
            kube.set_pod_role(ROLE_PRIMARY)
        return

    if not expired:
        kube.set_pod_role(ROLE_STANDBY if recovery else ROLE_UNKNOWN)
        if recovery:
            ensure_following(holder)
        if not recovery:
            stop_local_primary()
        return

    if not FAILOVER_ENABLED:
        kube.set_pod_role(ROLE_STANDBY if recovery else ROLE_UNKNOWN)
        if recovery:
            ensure_following(holder)
        return

    if recovery:
        refreshed = kube.get_lease()
        if refreshed is None:
            return
        if not lease_expired(refreshed):
            ensure_following(refreshed.get("spec", {}).get("holderIdentity"))
            kube.set_pod_role(ROLE_STANDBY)
            return
        updated, _ = kube.update_lease(refreshed, acquire=True)
        if not updated:
            return
        log(f"acquired expired lease from {holder}")
        promote()
        kube.set_pod_role(ROLE_PRIMARY)
    else:
        kube.set_pod_role(ROLE_UNKNOWN)
        stop_local_primary()


def should_fence_after_error(kube):
    if not db_ready() or in_recovery():
        return False
    lease = kube.get_lease()
    if lease is None:
        return False
    holder = lease.get("spec", {}).get("holderIdentity")
    return bool(holder and holder != POD_NAME and not lease_expired(lease))


def main():
    kube = KubeClient()
    log(f"starting PolarDB HA manager for pod {POD_NAME}, lease {LEASE_NAME}")
    start_http_server(kube)
    while True:
        try:
            reconcile(kube)
        except Exception as exc:
            log(f"reconcile failed: {exc}")
            try:
                if should_fence_after_error(kube):
                    stop_local_primary()
            except Exception as fence_exc:
                log(f"failed to fence local primary after reconcile error: {fence_exc}")
        time.sleep(RETRY_PERIOD)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
