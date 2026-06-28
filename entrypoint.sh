#!/bin/bash

# 1. Determine Hardware Profile (Default to MINIMAL if not set)
PROFILE=${PROFILE:-MINIMAL}

echo "Starting Big Data Sandbox with Profile: $PROFILE"

if [ "$PROFILE" = "MINIMAL" ]; then
  # Minimal specs: 4GB Host RAM
  export HADOOP_HEAP="256m"
  export CASSANDRA_HEAP="256M"
  export CASSANDRA_NEW="64M"
elif [ "$PROFILE" = "BALANCED" ]; then
  # Balanced specs: 8GB - 16GB Host RAM
  export HADOOP_HEAP="1024m"
  export CASSANDRA_HEAP="1024M"
  export CASSANDRA_NEW="256M"
elif [ "$PROFILE" = "PERFORMANCE" ]; then
  # High-end specs: 16GB+ Host RAM
  export HADOOP_HEAP="4096m"
  export CASSANDRA_HEAP="4096M"
  export CASSANDRA_NEW="800M"
else
  echo "Invalid profile. Please use MINIMAL, BALANCED, or PERFORMANCE."
  exit 1
fi

# 2. Hadoop Memory Limits are applied dynamically via hadoop-env.sh using the HADOOP_HEAP variable
export HADOOP_USER_NAME=${HADOOP_USER_NAME:-cloudera}
{
  echo "export HADOOP_USER_NAME=$HADOOP_USER_NAME"
  echo "export HADOOP_HEAP=$HADOOP_HEAP"
  echo "export MAX_HEAP_SIZE=$CASSANDRA_HEAP"
  echo "export HEAP_NEWSIZE=$CASSANDRA_NEW"
} > /etc/profile.d/hadoop_user.sh

# Correct ownership of runtime mounted volumes (which might default to host root user)
mkdir -p /tmp/hadoop-cloudera/hive
chown -R cloudera:cloudera /tmp/hadoop-cloudera /opt/cassandra/data

# 3. Apply Cassandra Memory Limits Dynamically
export MAX_HEAP_SIZE=$CASSANDRA_HEAP
export HEAP_NEWSIZE=$CASSANDRA_NEW

# 4. Start System Services (SSH, PostgreSQL, MySQL)
service ssh start
service postgresql start


# 4b. Start and configure MariaDB
service mariadb start
chmod 755 /var/run/mysqld
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'cloudera';" || true
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY 'cloudera' WITH GRANT OPTION; FLUSH PRIVILEGES;" || true

# Initialize sample database and table for Sqoop import tests
mysql -u root -pcloudera -e "
CREATE DATABASE IF NOT EXISTS zeyodb;
USE zeyodb;
CREATE TABLE IF NOT EXISTS zeyotab (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50),
    city VARCHAR(50),
    amount DECIMAL(10,2)
);
TRUNCATE TABLE zeyotab;
INSERT INTO zeyotab (name, city, amount) VALUES 
('Rajesh', 'chennai', 5000.00),
('Anusha', 'chennai', 7500.00),
('Suresh', 'bangalore', 6000.00),
('Kiran', 'hyderabad', 8000.00);
" || true



# 5. Start Cassandra as cloudera user (does not need -R anymore)
su - cloudera -c "$CASSANDRA_HOME/bin/cassandra"
sleep 15

# 6. Format HDFS NameNode (Only if not already formatted)
# For the cloudera user, the default name directory is /tmp/hadoop-cloudera/dfs/name
if [ ! -d "/tmp/hadoop-cloudera/dfs/name" ]; then
  echo "Formatting HDFS NameNode..."
  su - cloudera -c "$HADOOP_HOME/bin/hdfs namenode -format"
fi

# 7. Start Hadoop Services as cloudera user
su - cloudera -c "$HADOOP_HOME/sbin/start-dfs.sh"
su - cloudera -c "$HADOOP_HOME/sbin/start-yarn.sh"

# Wait for HDFS to exit safemode, force it to leave safemode, then create the default directories
echo "Waiting for HDFS to start up..."
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfsadmin -safemode wait"
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfsadmin -safemode leave"
echo "Creating default HDFS directory /user/$HADOOP_USER_NAME..."
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -mkdir -p /user/$HADOOP_USER_NAME"
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -chown -R $HADOOP_USER_NAME:$HADOOP_USER_NAME /user/$HADOOP_USER_NAME" || true
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -chmod 777 /user/$HADOOP_USER_NAME"
if [ "$HADOOP_USER_NAME" != "cloudera" ]; then
  su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -mkdir -p /user/cloudera"
  su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -chmod 777 /user/cloudera"
fi
echo "Creating default Hive Warehouse directory /user/hive/warehouse..."
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -mkdir -p /user/hive/warehouse"
su - cloudera -c "HADOOP_USER_NAME=cloudera \$HADOOP_HOME/bin/hdfs dfs -chmod 777 /user/hive/warehouse"

# 8. Start Hive Metastore as cloudera user
if [ ! -d "/tmp/hadoop-cloudera/hive/metastore_db" ]; then
  echo "Initializing Hive Metastore Schema..."
  su - cloudera -c "cd \$HIVE_HOME && ./bin/schematool -dbType derby -initSchema"
fi
su - cloudera -c "HADOOP_OPTS=\"-Xmx$HADOOP_HEAP\" nohup \$HIVE_HOME/bin/hive --service metastore >/dev/null 2>&1 &"

# 9. Keep container alive
echo "Sandbox Ready. Profile: $PROFILE."
exec tail -f /dev/null
