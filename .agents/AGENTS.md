# Big Data Sandbox & Podman Networking Guidelines

## 1. Podman Rootless Networking Troubleshooting
When running containers under rootless Podman (often emulating the `docker` command):
- **Error:** `pasta failed with exit code 1: Failed to open() /dev/net/tun: No such device`
- **Root Cause:** Podman's default `pasta` network driver requires the host's `/dev/net/tun` device. This module may be missing, or on Arch Linux, the module directory may have been deleted during a pacman kernel update prior to a reboot.
- **Solutions:**
  1. **Load the module:** Run `sudo modprobe tun` (requires a reboot if a kernel update was recently applied on Arch).
  2. **Use user-mode networking:** Add the `--network slirp4netns` flag to the container execution. Note: This requires the `slirp4netns` package (install via `sudo pacman -S slirp4netns` on Arch).
  3. **Recreate existing failed containers:** Use `docker rm <name>` or `--replace` to free up the container name.
- **SSH Connection Reset (IPv6 loopback):**
  - **Symptom:** `kex_exchange_identification: read: Connection reset by peer` or `Connection reset by ::1 port 2222`.
  - **Root Cause:** The SSH client defaults to connecting via the IPv6 loopback (`::1`), whereas Podman's `slirp4netns` driver defaults to listening and forwarding on IPv4 (`127.0.0.1`).
  - **Solution:** Force IPv4 connection by targeting `127.0.0.1` explicitly or using the `-4` flag:
    `ssh cloudera@127.0.0.1 -p 2222` or `ssh -4 cloudera@localhost -p 2222`

## 2. Big Data Stack Sandbox Configurations
- **Apache Spark Integration (Core Processing Engine):**
  - For a minimal yet complete data engineering stack, **Apache Spark 3.x** should be integrated into the sandbox. Spark executes on-demand using YARN resources (without requiring background Spark master/worker daemons, keeping memory footprint low).
  - To enable Spark to access Hive Metastore and databases:
    * Set `SPARK_HOME=/opt/spark` and register it in paths.
    * Copy `hive-site.xml` to `$SPARK_HOME/conf/` so Spark can query the Hive tables directly.
    * Copy the MySQL connector JDBC jar to `$SPARK_HOME/jars/` to allow Spark SQL to read/write to relational databases.
- **HDFS Safemode Bypass on Boot:**
  - **Symptom:** Client shells (like Hive or Sqoop) fail during initial setup with `SafeModeException: Cannot create directory ... Name node is in safe mode`.
  - **Root Cause:** When HDFS NameNode starts, it registers blocks from DataNodes and triggers a "safe mode extension" timer (typically 30 seconds) during which the filesystem is read-only.
  - **Solution:** Execute `hdfs dfsadmin -safemode leave` right after the startup wait command in the container entrypoint. This forces the NameNode to exit safe mode immediately, allowing clients to write database tables without waiting.
- **Hive Metastore Connection & Warehouse Setup:**
  - **Symptom:** Hive shell commands fail with `FAILED: HiveException java.lang.RuntimeException: Unable to instantiate org.apache.hadoop.hive.ql.metadata.SessionHiveMetaStoreClient`.
  - **Root Cause:** By default, if no `hive-site.xml` configuration exists, Hive CLI launches an embedded metastore locally, locking the Derby database (`metastore_db`). This collides with the running background Hive Metastore service that holds the database lock.
  - **Solution:** 
    1. Configure `hive-site.xml` to point to the Thrift service URI `thrift://localhost:9083` and set `hive.metastore.warehouse.dir` to `/user/hive/warehouse`.
    2. Explicitly define an absolute path Connection URL for Derby (e.g. `jdbc:derby:;databaseName=/opt/hive/metastore_db;create=true`) inside `hive-site.xml`. If left as relative, the metastore service daemon and client tools will seek and initialize separate databases based on their different current working directories, causing `Version information not found` errors.
    3. During container boot, ensure `/user/hive/warehouse` is automatically created on HDFS and permissions are set to `777` (e.g. `hdfs dfs -mkdir -p /user/hive/warehouse && hdfs dfs -chmod 777 /user/hive/warehouse`) so that database creation commands can write their directories.
- **Hadoop HDFS Mode Configuration (Standalone vs Pseudo-Distributed):**
  - By default, Hadoop runs in standalone (local filesystem) mode if no XML configs are provided, causing HDFS commands to fail with `FileSystem file:/// is not an HDFS file system` and Sqoop to fail to create paths under `/user/...`.
  - Always configure HDFS in pseudo-distributed mode by copying standard configurations:
    * `core-site.xml`: Set `fs.defaultFS` to `hdfs://localhost:9000`.
    * `hdfs-site.xml`: Set `dfs.replication` to `1`.
    * `mapred-site.xml`: Set `mapreduce.framework.name` to `yarn`.
    * `yarn-site.xml`: Set `yarn.nodemanager.aux-services` to `mapreduce_shuffle`.
- **HDFS User Directory Auto-Creation:**
  - To prevent manual bootstrap commands, the entrypoint script should automatically block until HDFS exits safemode (`hdfs dfsadmin -safemode wait`) and then create the default user directory (`hdfs dfs -mkdir -p /user/<username>`).
- **Data Persistence across Restarts (Docker Volumes):**
  - Containers are ephemeral by default. To preserve database schemas, records, and HDFS filesystem contents across container restarts, replacements, or reboots, always map host or named volumes to the respective storage paths:
    * HDFS: `/tmp/hadoop-cloudera`
    * MySQL: `/var/lib/mysql`
    * PostgreSQL: `/var/lib/postgresql`
    * Cassandra: `/opt/cassandra/data`
- **Java Stack Version Compatibility (Hadoop, Hive, Cassandra, Sqoop):**
  - Hadoop 3.5.0 requires Java 17, which conflicts with Hive 3.1.3 and Sqoop 1.4.7 (built for Java 8).
  - To maintain a stable, single-Java-version environment, align the versions by using **Hadoop 3.3.6** and running the entire sandbox under **Java 8** (`openjdk-8-jdk`).
- **Non-Root Daemon Execution (cloudera user):**
  - Always set up a dedicated system user (e.g. `cloudera` with password `cloudera`) instead of `root` to run daemon processes. This aligns with standard security practices and prevents file permission conflicts in user namespaces.
  - In `hadoop-env.sh`, export the daemon variables specifying the `cloudera` user:
    ```bash
    export HDFS_NAMENODE_USER=cloudera
    export HDFS_DATANODE_USER=cloudera
    export HDFS_SECONDARYNAMENODE_USER=cloudera
    export YARN_RESOURCEMANAGER_USER=cloudera
    export YARN_NODEMANAGER_USER=cloudera
    ```
  - In the entrypoint script, use `su - cloudera -c "..."` to run Cassandra, format/start HDFS, and launch YARN/Hive Metastore.
- **MySQL Unix Socket Permission (mysql group & directory chmod):**
  - **Symptom:** Local non-root users (like `cloudera`) get `Permission denied (13)` when connecting to MySQL via Unix socket `/var/run/mysqld/mysqld.sock` even when they are in the `mysql` group.
  - **Root Cause:** The MySQL socket directory `/var/run/mysqld` is created with permissions `0700` (read/write/enter for user `mysql` only).
  - **Solution:** Add the non-root user to the `mysql` group (e.g. `usermod -aG mysql cloudera`) AND change the directory permissions to `0755` (e.g. `chmod 755 /var/run/mysqld`) in the container entrypoint after starting MySQL.
- **Hadoop Daemon Scheduling Priority (renice mock):**
  - **Symptom:** Hadoop daemons (NameNode, DataNode, NodeManager) fail to start with the error `ERROR: Cannot set priority of [daemon] process [PID]`.
  - **Root Cause:** Inside rootless containers, modifying process priorities via `renice` is prohibited by host kernel security policies. Hadoop's startup scripts call `renice` and exit immediately if it fails.
  - **Solution:** Place a mock `renice` shell script (e.g., `echo '#!/bin/sh\nexit 0' > /usr/local/bin/renice && chmod +x /usr/local/bin/renice`) in `/usr/local/bin/` so that it intercepts the call, exits with `0`, and allows the daemons to boot.
- **Hadoop Loopback SSH:**
  - Hadoop startup scripts require passwordless SSH to `localhost` and `0.0.0.0`.
  - Always generate SSH keys, authorize them (`authorized_keys`), and configure SSH to bypass host key prompts (`StrictHostKeyChecking no`).
  - Always set `export JAVA_HOME` explicitly inside `hadoop-env.sh`, as non-interactive SSH connections do not preserve parent process environment variables.
- **SSH Environment Variable Persistence (No Shell Recursion):**
  - Docker `ENV` variables are not automatically passed to SSH login sessions.
  - To persist paths without causing infinite shell recursion (which crashes SSH connections immediately upon login), write all path and variable exports directly to `/etc/bash.bashrc`. Avoid sourcing `/etc/profile` inside `/etc/bash.bashrc` (since `/etc/profile` already sources `/etc/bash.bashrc` by default).
- **Sqoop Dependencies & JDBC Connector:**
  - Sqoop 1.4.7 depends on `commons-lang-2.6.jar` which is not included in Hadoop 3.x's default classpath. Copy it from Hadoop's timeline service folder (`$HADOOP_HOME/share/hadoop/yarn/timelineservice/lib/commons-lang-2.6.jar`) to `$SQOOP_HOME/lib/`.
  - To perform Sqoop database operations on MySQL, download `mysql-connector-java-5.1.48.jar` and place it in `$SQOOP_HOME/lib/` and `$HIVE_HOME/lib/`.
- **Hive Metastore Schema:**
  - Hive 3.x requires explicit schema initialization before starting the metastore service.
  - Run `schematool -dbType derby -initSchema` from the Hive installation directory before starting `hive --service metastore`.
- **Hive-Hadoop Guava Jar Compatibility:**
  - Hive 3.x and Hadoop 3.x have conflicting Guava jar versions.
  - Always replace Hive's old `guava-19.0.jar` (in `$HIVE_HOME/lib`) with the newer `guava-*.jar` from Hadoop's shared common library directory to avoid JVM `NoSuchMethodError` crashes.
- **Cassandra Memory Limits:**
  - Do not overwrite `cassandra-env.sh` with raw JVM flags (e.g. `-Xmx256M`). It is a shell script; writing raw flags will crash the startup.
  - Let Cassandra use its default `cassandra-env.sh` script and pass memory limits dynamically by exporting `MAX_HEAP_SIZE` and `HEAP_NEWSIZE` env variables.
