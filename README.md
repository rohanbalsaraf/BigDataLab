# Minimalist Big Data Sandbox

A lightweight, containerized sandbox environment containing a fully configured Big Data stack. The sandbox runs entirely under a non-root system user (`cloudera`) and is optimized for low-overhead local development.

---

## 🛠️ Included Stack & Services

| Component | Version | Port (Container) | Port (Host Mapped) | Role |
| :--- | :--- | :--- | :--- | :--- |
| **Apache Hadoop (HDFS)** | 3.3.6 | `9000` (RPC), `9870` (UI) | `9870` | Distributed File System |
| **Apache Hadoop (YARN)** | 3.3.6 | `8088` (UI) | `8088` | Job & Resource Management |
| **Apache Spark** | 3.4.1 | - | - | Distributed Engine (on YARN) |
| **Apache Hive** | 3.1.3 | `9083` (Metastore) | - | Relational Data Warehouse |
| **Apache Cassandra** | 4.1.3 | `9042` (CQL) | `9042` (Optional) | NoSQL Database |
| **MySQL Server** | 8.0 | `3306` | `3307` | Relational Database (Sqoop Source) |
| **PostgreSQL Server** | 14 | `5432` | - | Relational Database |
| **Apache Sqoop** | 1.4.7 | - | - | SQL-to-Hadoop Data Transfer |

---

## 📋 Prerequisites Installation

### 🐧 Linux (Debian/Ubuntu/Arch)
1. Install **Docker** or **Podman**:
   * **Ubuntu/Debian:** `sudo apt-get install docker.io docker-compose`
   * **Arch Linux:** `sudo pacman -S podman docker-compose slirp4netns`
2. Start and enable the service:
   * **Docker:** `sudo systemctl enable --now docker`
   * **Podman (Rootless Compose API support):** Run `systemctl --user enable --now podman.socket` (this starts the user-space daemon socket at `/run/user/1000/podman/podman.sock` so `docker-compose` can execute container operations).

### 🍏 macOS
1. Install **Homebrew** (if not already installed): `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
2. Install **Docker Desktop** (or Podman Desktop):
   * `brew install --cask docker` (or `brew install podman-desktop`)
3. Launch the installed app to start the container engine.

### 🪟 Windows
1. Download and install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) (select the **WSL 2 backend** option during setup).
2. Alternatively, install [Podman for Windows](https://podman.io).
3. Restart your computer if prompted.

---

## 🚀 How to Build and Run the Sandbox

### Method A: Docker Compose (Recommended)
This starts all components and automatically mounts persistent storage volumes.
```bash
# 1. Build and start the sandbox in the background
docker-compose up -d --build

# 2. Stop the sandbox without deleting data
docker-compose down
```

### Method B: Docker CLI
If you prefer running manual commands:
```bash
# 1. Build the image
docker build -t minimal-bigdata .

# 2. Run the container with persistent volumes
docker run -d \
  --replace \
  --name bigdata-performance \
  -m 16g \
  -e PROFILE=PERFORMANCE \
  -p 2222:22 \
  -p 3307:3306 \
  -v hdfs-data:/tmp/hadoop-cloudera \
  -v mysql-data:/var/lib/mysql \
  -v postgres-data:/var/lib/postgresql \
  -v cassandra-data:/opt/cassandra/data \
  --network slirp4netns \
  localhost/minimal-bigdata
```

---

## 🔌 Connecting to the Sandbox

### 1. SSH Shell Access
You can log directly into the sandbox shell:
* **Host Address:** `127.0.0.1` (or `localhost` using the `-4` IPv4 flag)
* **Port:** `2222`
* **Username:** `cloudera`
* **Password:** `cloudera`
* **Command:**
  ```bash
  ssh cloudera@127.0.0.1 -p 2222
  ```

### 2. Database Logins
* **MySQL:** User `root` / Password `cloudera`
  * Inside SSH shell: `mysql -uroot -pcloudera`
  * From host machine: `mysql -h 127.0.0.1 -P 3307 -uroot -pcloudera`
* **PostgreSQL:** User `postgres` (no password locally)
  * Inside SSH shell: `psql -U postgres`
* **Cassandra:** Native cqlsh
  * Inside SSH shell: `cqlsh`

---

## 🎯 Verification and Usage Guide

Once logged in via SSH as the `cloudera` user, run the following verification checks:

### 1. HDFS & Safe Mode
Ensure HDFS is online and writeable:
```bash
# Check HDFS status
hdfs dfsadmin -safemode get

# List root directory
hdfs dfs -ls /
```

### 2. Sqoop Imports (MySQL to HDFS)
Import test rows from MySQL into the HDFS directory:
```bash
# Seed MySQL with test data
mysql -uroot -pcloudera -e "create database if not exists zeyodb; use zeyodb; drop table if exists zeyotab; create table zeyotab(id int,name varchar(100),city varchar(100)); insert into zeyotab values(1,'sai','chennai'),(2,'ravi','hyderabad'),(3,'rani','chennai'),(4,'vasu','bangalore');"

# Run Sqoop import
sqoop import --connect jdbc:mysql://localhost:3306/zeyodb --username root --password cloudera --m 1 --table zeyotab --delete-target-dir --target-dir /user/cloudera/firstimport

# Verify the imported files in HDFS
hdfs dfs -cat /user/cloudera/firstimport/part-m-00000
```

### 3. Apache Spark / PySpark
Run interactive Scala, Python, or SQL workloads on YARN:
```bash
# Open Python Spark shell
pyspark

# Open Scala Spark shell
spark-shell

# Open Spark SQL shell
spark-sql
```

### 4. Apache Hive
Interact with the SQL data warehouse:
```bash
# Open Hive query CLI
hive

# (Inside Hive shell)
CREATE DATABASE sandbox_test;
SHOW DATABASES;
```

---

## 🔍 Troubleshooting

### 1. `kex_exchange_identification: Connection reset` during SSH
* **Cause:** Rootless Podman network configurations bind loopback listeners to IPv4 (`127.0.0.1`), whereas your SSH client defaults to the IPv6 loopback (`::1`).
* **Fix:** Explicitly connect using `127.0.0.1` or the `-4` flag:
  `ssh cloudera@127.0.0.1 -p 2222` or `ssh -4 cloudera@localhost -p 2222`

### 2. `pasta failed: Failed to open() /dev/net/tun: No such device`
* **Cause:** Podman's default `pasta` network driver fails when the host's TUN device is missing.
* **Fix:** Run the container using the `--network slirp4netns` flag (and install `slirp4netns` via package manager if not present).

### 3. Hadoop scheduling priority errors (`renice` blocks startup)
* **Cause:** Containers running rootless are prohibited from changing system scheduling priorities (niceness), crashing Hadoop's default daemons on boot.
* **Fix:** The sandbox includes a mock `renice` command located at `/usr/local/bin/renice` that catches these calls and returns success (`exit 0`), allowing daemons to boot.

### 4. `failed to connect to the docker API at unix:///run/user/.../podman/podman.sock` (Compose API Failure)
* **Cause:** `docker-compose` expects a running Docker daemon socket API. When using rootless Podman, this user-space socket is not started by default.
* **Fix:** Start and enable Podman's rootless API socket service for your user account:
  ```bash
  systemctl --user enable --now podman.socket
  ```
