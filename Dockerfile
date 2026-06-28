FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install System Utilities, Java, and SQL (PostgreSQL or MySQL)
RUN apt-get update && apt-get install -y \
    openjdk-8-jdk \
    openssh-server \
    wget \
    curl \
    gnupg \
    sudo \
    postgresql postgresql-contrib \
    mysql-server \
    && rm -rf /var/lib/apt/lists/*

# Configure MySQL to listen on all interfaces
RUN sed -i 's/bind-address\s*=\s*127.0.0.1/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf


# 2. Set Environment Variables
ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV HADOOP_HOME=/opt/hadoop
ENV HIVE_HOME=/opt/hive
ENV CASSANDRA_HOME=/opt/cassandra
ENV SQOOP_HOME=/opt/sqoop
ENV SPARK_HOME=/opt/spark
ENV PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$CASSANDRA_HOME/bin:$SQOOP_HOME/bin:$SPARK_HOME/bin

# Export environment variables to system profile.d so they are loaded in all shells (including non-interactive su calls)
RUN echo 'export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64' > /etc/profile.d/bigdata.sh && \
    echo 'export HADOOP_HOME=/opt/hadoop' >> /etc/profile.d/bigdata.sh && \
    echo 'export HIVE_HOME=/opt/hive' >> /etc/profile.d/bigdata.sh && \
    echo 'export CASSANDRA_HOME=/opt/cassandra' >> /etc/profile.d/bigdata.sh && \
    echo 'export SQOOP_HOME=/opt/sqoop' >> /etc/profile.d/bigdata.sh && \
    echo 'export SPARK_HOME=/opt/spark' >> /etc/profile.d/bigdata.sh && \
    echo 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$CASSANDRA_HOME/bin:$SQOOP_HOME/bin:$SPARK_HOME/bin' >> /etc/profile.d/bigdata.sh && \
    echo 'export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:.' >> /etc/profile.d/bigdata.sh && \
    echo 'if [ -f /etc/profile.d/bigdata.sh ]; then . /etc/profile.d/bigdata.sh; fi' >> /etc/bash.bashrc


# 3. Download and Install Big Data Stack (Using verified mirrors/archives)
WORKDIR /opt

# Use verified archive mirror for Hadoop 3.3.6 (Java 8 compatible) and show progress
RUN wget --progress=dot:giga https://archive.apache.org/dist/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz && \
    tar -xzf hadoop-3.3.6.tar.gz && mv hadoop-3.3.6 hadoop && rm hadoop-3.3.6.tar.gz

RUN wget --progress=dot:giga https://archive.apache.org/dist/hive/hive-3.1.3/apache-hive-3.1.3-bin.tar.gz && \
    tar -xzf apache-hive-3.1.3-bin.tar.gz && mv apache-hive-3.1.3-bin hive && rm apache-hive-3.1.3-bin.tar.gz

RUN wget --progress=dot:giga https://archive.apache.org/dist/cassandra/4.1.3/apache-cassandra-4.1.3-bin.tar.gz && \
    tar -xzf apache-cassandra-4.1.3-bin.tar.gz && mv apache-cassandra-4.1.3 cassandra && rm apache-cassandra-4.1.3-bin.tar.gz

# Note: Sqoop is an Apache Attic (retired) project but available via archives
RUN wget --progress=dot:giga https://archive.apache.org/dist/sqoop/1.4.7/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz && \
    tar -xzf sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz && mv sqoop-1.4.7.bin__hadoop-2.6.0 sqoop && rm sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz

# Download and install Apache Spark 3.4.1 (Java 8/11/17 and Hadoop 3 compatible)
RUN wget --progress=dot:giga https://archive.apache.org/dist/spark/spark-3.4.1/spark-3.4.1-bin-hadoop3.tgz && \
    tar -xzf spark-3.4.1-bin-hadoop3.tgz && mv spark-3.4.1-bin-hadoop3 spark && rm spark-3.4.1-bin-hadoop3.tgz

# Fix Hive-Hadoop Guava version mismatch
RUN rm $HIVE_HOME/lib/guava-19.0.jar && \
    cp $HADOOP_HOME/share/hadoop/common/lib/guava-*.jar $HIVE_HOME/lib/

# Fix Sqoop missing dependencies and download MySQL JDBC driver
RUN cp $HADOOP_HOME/share/hadoop/yarn/timelineservice/lib/commons-lang-2.6.jar $SQOOP_HOME/lib/ && \
    wget --progress=dot:giga -P $SQOOP_HOME/lib/ https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.48/mysql-connector-java-5.1.48.jar && \
    cp $SQOOP_HOME/lib/mysql-connector-java-5.1.48.jar $HIVE_HOME/lib/
# Mock renice command to prevent Hadoop from failing on scheduling priority sets in rootless containers
RUN echo '#!/bin/sh\nexit 0' > /usr/local/bin/renice && \
    chmod +x /usr/local/bin/renice

# 4. Create cloudera user and configure SSH Access & Passwordless SSH for Hadoop
RUN useradd -m -s /bin/bash cloudera && \
    usermod -aG mysql cloudera && \
    echo 'cloudera:cloudera' | chpasswd && \
    echo 'root:bigdata' | chpasswd && \
    echo "cloudera ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    su - cloudera -c "ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa && \
                      cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
                      chmod 0600 ~/.ssh/authorized_keys && \
                      echo 'StrictHostKeyChecking no' >> ~/.ssh/config && \
                      echo 'UserKnownHostsFile /dev/null' >> ~/.ssh/config"

# Change ownership of big data applications to the cloudera user
RUN chown -R cloudera:cloudera /opt/hadoop /opt/hive /opt/cassandra /opt/sqoop /opt/spark

# 5. Copy your tuned config files into the image
COPY hadoop-env.sh $HADOOP_HOME/etc/hadoop/hadoop-env.sh
COPY core-site.xml $HADOOP_HOME/etc/hadoop/core-site.xml
COPY hdfs-site.xml $HADOOP_HOME/etc/hadoop/hdfs-site.xml
COPY mapred-site.xml $HADOOP_HOME/etc/hadoop/mapred-site.xml
COPY yarn-site.xml $HADOOP_HOME/etc/hadoop/yarn-site.xml
RUN chown cloudera:cloudera $HADOOP_HOME/etc/hadoop/hadoop-env.sh $HADOOP_HOME/etc/hadoop/*.xml

# Copy Hive configuration file
COPY hive-site.xml $HIVE_HOME/conf/hive-site.xml
RUN chown cloudera:cloudera $HIVE_HOME/conf/hive-site.xml

# Configure Spark with Hive configurations and JDBC driver
RUN cp $HIVE_HOME/conf/hive-site.xml $SPARK_HOME/conf/ && \
    cp $SQOOP_HOME/lib/mysql-connector-java-5.1.48.jar $SPARK_HOME/jars/ && \
    chown -R cloudera:cloudera $SPARK_HOME/conf $SPARK_HOME/jars

# 6. Expose relevant ports (SSH, Hadoop Web UI, Cassandra, Hive)
EXPOSE 22 9870 8088 9042 10000 3306

# Copy entrypoint execution script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
