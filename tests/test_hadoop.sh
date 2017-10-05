#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-05-06 12:12:15 +0100 (Fri, 06 May 2016)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$srcdir/.."

. "$srcdir/utils.sh"

section "H a d o o p"

export HADOOP_VERSIONS="${@:-${HADOOP_VERSIONS:-latest 2.5 2.6 2.7}}"

HADOOP_HOST="${DOCKER_HOST:-${HADOOP_HOST:-${HOST:-localhost}}}"
HADOOP_HOST="${HADOOP_HOST##*/}"
HADOOP_HOST="${HADOOP_HOST%%:*}"
export HADOOP_HOST
# don't need these each script should fall back to using HADOOP_HOST secondary if present
# TODO: make sure new script for block balance does this
#export HADOOP_NAMENODE_HOST="$HADOOP_HOST"
#export HADOOP_DATANODE_HOST="$HADOOP_HOST"
#export HADOOP_YARN_RESOURCE_MANAGER_HOST="$HADOOP_HOST"
#export HADOOP_YARN_NODE_MANAGER_HOST="$HADOOP_HOST"
export HADOOP_NAMENODE_PORT_DEFAULT="50070"
export HADOOP_DATANODE_PORT_DEFAULT="50075"
export HADOOP_YARN_RESOURCE_MANAGER_PORT_DEFAULT="8088"
export HADOOP_YARN_NODE_MANAGER_PORT_DEFAULT="8042"
#export HADOOP_PORTS="8042 8088 50010 50020 50070 50075 50090"

# not used any more, see instead tests/docker/hadoop-docker-compose.yml
#export DOCKER_IMAGE="harisekhon/hadoop-dev"

# still used by docker_exec() function below, must align with what is set in tests/docker/common.yml
export MNTDIR="/pl"

startupwait 30

check_docker_available

trap_debug_env hadoop

docker_exec(){
    #docker-compose exec "$DOCKER_SERVICE" $MNTDIR/$@
    echo "docker exec 'nagiosplugins_${DOCKER_SERVICE}_1' $MNTDIR/$@"
    docker exec "nagiosplugins_${DOCKER_SERVICE}_1" $MNTDIR/$@
}

test_hadoop(){
    local version="$1"
    section2 "Setting up Hadoop $version test container"
    #DOCKER_OPTS="-v $srcdir2/..:$MNTDIR"
    #launch_container "$DOCKER_IMAGE:$version" "$DOCKER_CONTAINER" $HADOOP_PORTS
    # reset state as things like blocks counts and job states, no history, succeeded etc depend on state
    docker-compose down &>/dev/null || :
    VERSION="$version" docker-compose up -d
    echo "getting Hadoop dynamic port mappings"
    printf "getting HDFS NN port => "
    export HADOOP_NAMENODE_PORT="`docker-compose port "$DOCKER_SERVICE" "$HADOOP_NAMENODE_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$HADOOP_NAMENODE_PORT"
    printf "getting HDFS DN port => "
    export HADOOP_DATANODE_PORT="`docker-compose port "$DOCKER_SERVICE" "$HADOOP_DATANODE_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$HADOOP_DATANODE_PORT"
    printf  "getting Yarn RM port => "
    export HADOOP_YARN_RESOURCE_MANAGER_PORT="`docker-compose port "$DOCKER_SERVICE" "$HADOOP_YARN_RESOURCE_MANAGER_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$HADOOP_YARN_RESOURCE_MANAGER_PORT"
    printf "getting Yarn NM port => "
    export HADOOP_YARN_NODE_MANAGER_PORT="`docker-compose port "$DOCKER_SERVICE" "$HADOOP_YARN_NODE_MANAGER_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$HADOOP_YARN_NODE_MANAGER_PORT"
    #local hadoop_ports=`{ for x in $HADOOP_PORTS; do docker-compose port "$DOCKER_SERVICE" "$x"; done; } | sed 's/.*://'`
    export HADOOP_PORTS="$HADOOP_NAMENODE_PORT $HADOOP_DATANODE_PORT $HADOOP_YARN_RESOURCE_MANAGER_PORT $HADOOP_YARN_NODE_MANAGER_PORT"
    when_ports_available "$startupwait" "$HADOOP_HOST" $HADOOP_PORTS
    hr
    # needed for version tests, also don't return container to user before it's ready if NOTESTS
    # also, do this wait before HDFS setup to give datanodes time to come online to copy the file too
    echo "waiting for Yarn RM cluster page to come up..."
    when_url_content "$startupwait" "$HADOOP_HOST:$HADOOP_YARN_RESOURCE_MANAGER_PORT/ws/v1/cluster" hadoop
    hr
    echo "setting up HDFS for tests"
    #docker-compose exec "$DOCKER_SERVICE" /bin/bash <<-EOF
    docker exec -i "nagiosplugins_${DOCKER_SERVICE}_1" /bin/bash <<-EOF
        set -eu
        export JAVA_HOME=/usr
        echo "leaving safe mode"
        hdfs dfsadmin -safemode leave
        echo "removing old hdfs file /tmp/test.txt if present"
        hdfs dfs -rm -f /tmp/test.txt &>/dev/null || :
        echo "creating test hdfs file /tmp/test.txt"
        echo content | hdfs dfs -put - /tmp/test.txt
        # if using wrong port like 50075 ot 50010 then you'll get this exception
        # triggerBlockReport error: java.io.IOException: Failed on local exception: com.google.protobuf.InvalidProtocolBufferException: Protocol message end-group tag did not match expected tag.; Host Details : local host is: "94bab7680584/172.19.0.2"; destination host is: "localhost":50075;
        # this doesn't help get Total Blocks in /blockScannerReport for ./check_hadoop_datanode_blockcount.pl, looks like that information is simply not exposed like that any more
        #hdfs dfsadmin -triggerBlockReport localhost:50020
        echo "dumping fsck log"
        hdfs fsck / &> /tmp/hdfs-fsck.log.tmp && tail -n30 /tmp/hdfs-fsck.log.tmp > /tmp/hdfs-fsck.log
        exit 0
EOF
    echo
    hr
    if [ -n "${NOTESTS:-}" ]; then
        exit 0
    fi
    if [ "$version" = "latest" ]; then
        local version=".*"
    fi
    # docker-compose exec returns $'hostname\r' but not in shell
    hostname="$(docker-compose exec "$DOCKER_SERVICE" hostname | tr -d '$\r')"
    if [ -z "$hostname" ]; then
        echo 'Failed to determine hostname of container via docker-compose exec, cannot continue with tests!'
        exit 1
    fi
    echo "./check_hadoop_namenode_version.py -v -e $version"
    ./check_hadoop_namenode_version.py -v -e "$version"
    hr
    echo "./check_hadoop_datanode_version.py -v -e $version"
    ./check_hadoop_datanode_version.py -v -e "$version"
    hr
    echo "$perl -T ./check_hadoop_datanode_version.pl --node $hostname -v -e $version"
    $perl -T ./check_hadoop_datanode_version.pl --node "$hostname" -v -e "$version"
    hr
    echo "$perl -T ./check_hadoop_yarn_resource_manager_version.pl -v -e $version"
    $perl -T ./check_hadoop_yarn_resource_manager_version.pl -v -e "$version"
    hr
    echo "docker_exec check_hadoop_balance.pl -w 5 -c 10 --hadoop-bin /hadoop/bin/hdfs --hadoop-user root -t 60"
    docker_exec check_hadoop_balance.pl -w 5 -c 10 --hadoop-bin /hadoop/bin/hdfs --hadoop-user root -t 60
    hr
    echo "$perl -T ./check_hadoop_checkpoint.pl"
    $perl -T ./check_hadoop_checkpoint.pl
    hr
    echo "testing failure of checkpoint time:"
    set +e
    echo "$perl -T ./check_hadoop_checkpoint.pl -w 1000: -c 2:"
    $perl -T ./check_hadoop_checkpoint.pl -w 1000: -c 2:
    check_exit_code 1
    hr
    echo "$perl -T ./check_hadoop_checkpoint.pl -w 3000: -c 2000:"
    $perl -T ./check_hadoop_checkpoint.pl -w 3000: -c 2000:
    check_exit_code 2
    set -e
    hr
    # TODO: write replacement python plugin for this
    # XXX: Total Blocks are not available via blockScannerReport from Hadoop 2.7
    if [ "$version" = "2.5" -o "$version" = "2.6" ]; then
        echo "$perl -T ./check_hadoop_datanode_blockcount.pl"
        $perl -T ./check_hadoop_datanode_blockcount.pl
    fi
    hr
    echo "$perl -T ./check_hadoop_datanode_jmx.pl --all-metrics"
    $perl -T ./check_hadoop_datanode_jmx.pl --all-metrics
    hr
    # TODO: write replacement python plugins for this
    # XXX: Hadoop doesn't expose this information in the same way any more via dfshealth.jsp so these plugins are end of life with Hadoop 2.6
    if [ "$version" = "2.5" -o "$version" = "2.6" ]; then
        echo "$perl -T ./check_hadoop_datanodes_block_balance.pl -w 5 -c 10"
        $perl -T ./check_hadoop_datanodes_block_balance.pl -w 5 -c 10
        hr
        echo "$perl -T ./check_hadoop_datanodes_block_balance.pl -w 5 -c 10 -v"
        $perl -T ./check_hadoop_datanodes_block_balance.pl -w 5 -c 10 -v
        hr
        echo "$perl -T ./check_hadoop_datanodes_blockcounts.pl"
        $perl -T ./check_hadoop_datanodes_blockcounts.pl
        hr
    fi
    echo "./check_hadoop_datanodes_block_balance.py -w 5 -c 10"
    ./check_hadoop_datanodes_block_balance.py -w 5 -c 10
    hr
    echo "./check_hadoop_datanodes_block_balance.py -w 5 -c 10 -v"
    ./check_hadoop_datanodes_block_balance.py -w 5 -c 10 -v
    hr
    echo "./check_hadoop_hdfs_balance.py -w 5 -c 10"
    ./check_hadoop_hdfs_balance.py -w 5 -c 10
    hr
    echo "./check_hadoop_hdfs_balance.py -w 5 -c 10 -v"
    ./check_hadoop_hdfs_balance.py -w 5 -c 10 -v
    hr
    echo "$perl -T ./check_hadoop_datanodes.pl"
    $perl -T ./check_hadoop_datanodes.pl
    hr
    echo "$perl -T ./check_hadoop_datanodes.pl --stale-threshold 0"
    $perl -T ./check_hadoop_datanodes.pl --stale-threshold 0
    hr
    echo "./check_hadoop_datanode_last_contact.py -d $hostname"
    ./check_hadoop_datanode_last_contact.py -d "$hostname"
    hr
    docker_exec check_hadoop_dfs.pl --hadoop-bin /hadoop/bin/hadoop --hadoop-user root --hdfs-space -w 80 -c 90
    hr
    docker_exec check_hadoop_dfs.pl --hadoop-bin /hadoop/bin/hdfs --hadoop-user root --replication -w 1 -c 1
    hr
    docker_exec check_hadoop_dfs.pl --hadoop-bin /hadoop/bin/hdfs --hadoop-user root --balance -w 5 -c 10
    hr
    docker_exec check_hadoop_dfs.pl --hadoop-bin /hadoop/bin/hdfs --hadoop-user root --nodes-available -w 1 -c 1
    hr
    echo "./check_hadoop_hdfs_corrupt_files.py"
    ./check_hadoop_hdfs_corrupt_files.py
    hr
    # TODO: create a forced corrupt file and test failure and also -vv mode
    #echo "./check_hadoop_hdfs_corrupt_files.py
    #set +e
    #./check_hadoop_hdfs_corrupt_files.py
    #check_exit_code 2
    #hr
    #echo "./check_hadoop_hdfs_corrupt_files.py -vv"
    #./check_hadoop_hdfs_corrupt_files.py -vv
    #check_exit_code 2
    # set-e
    #hr
    # XXX: Hadoop doesn't expose this information in the same way any more via dfshealth.jsp so this plugin is end of life with Hadoop 2.6
    # XXX: this doesn't seem to even work on Hadoop 2.5.2 any more, use python version below instead
    if [ "$version" = "2.5" -o "$version" = "2.6" ]; then
        # on a real cluster thresholds should be set to millions+, no defaults as must be configured based on NN heap allocated
        echo "$perl -T ./check_hadoop_hdfs_total_blocks.pl -w 10 -c 20"
        $perl -T ./check_hadoop_hdfs_total_blocks.pl -w 10 -c 20
        hr
        echo "testing failure scenarios:"
        set +e
        echo "$perl -T ./check_hadoop_hdfs_total_blocks.pl -w 0 -c 1"
        ./check_hadoop_hdfs_total_blocks.pl -w 0 -c 1
        check_exit_code 1
        hr
        echo "$perl -T ./check_hadoop_hdfs_total_blocks.pl -w 0 -c 0"
        ./check_hadoop_hdfs_total_blocks.pl -w 0 -c 0
        check_exit_code 2
        set -e
        hr
    fi
    # on a real cluster thresholds should be set to millions+, no defaults as must be configured based on NN heap allocated
    echo "./check_hadoop_hdfs_total_blocks.py -w 10 -c 20"
    ./check_hadoop_hdfs_total_blocks.py -w 10 -c 20
    hr
    echo "testing failure scenarios:"
    set +e
    echo "./check_hadoop_hdfs_total_blocks.py -w 0 -c 1"
    ./check_hadoop_hdfs_total_blocks.py -w 0 -c 1
    check_exit_code 1
    hr
    echo "./check_hadoop_hdfs_total_blocks.py -w 0 -c 0"
    ./check_hadoop_hdfs_total_blocks.py -w 0 -c 0
    check_exit_code 2
    set -e
    hr
    # run inside Docker container so it can resolve redirect to DN
    docker_exec check_hadoop_hdfs_file_webhdfs.pl -H localhost -p /tmp/test.txt --owner root --group supergroup --replication 1 --size 8 --last-accessed 600 --last-modified 600 --blockSize 134217728
    hr
    # run inside Docker container so it can resolve redirect to DN
    docker_exec check_hadoop_hdfs_write_webhdfs.pl -H localhost
    hr
    for x in 2.5 2.6 2.7; do
        echo "./check_hadoop_hdfs_fsck.pl -f tests/data/hdfs-fsck-$x.log"
        $perl -T ./check_hadoop_hdfs_fsck.pl -f tests/data/hdfs-fsck-$x.log
        hr
        echo "./check_hadoop_hdfs_fsck.pl -f tests/data/hdfs-fsck-$x.log --stats"
        $perl -T ./check_hadoop_hdfs_fsck.pl -f tests/data/hdfs-fsck-$x.log --stats
        hr
    done
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --stats
    hr
    echo "checking hdfs fsck failure scenarios:"
    set +e
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --last-fsck -w 1 -c 200000000
    check_exit_code 1
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --last-fsck -w 1 -c 1
    check_exit_code 2
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --max-blocks -w 1 -c 2
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --max-blocks -w 0 -c 1
    check_exit_code 1
    hr
    docker_exec check_hadoop_hdfs_fsck.pl -f /tmp/hdfs-fsck.log --max-blocks -w 0 -c 0
    check_exit_code 2
    set -e
    hr
    echo "$perl -T ./check_hadoop_hdfs_space.pl"
    $perl -T ./check_hadoop_hdfs_space.pl
    hr
    echo "./check_hadoop_hdfs_space.py"
    ./check_hadoop_hdfs_space.py
    hr
    # XXX: these ports must be left as this plugin is generic and has no default port, nor does it pick up any environment variables more specific than $PORT
    echo "$perl -T ./check_hadoop_jmx.pl --all -P $HADOOP_NAMENODE_PORT"
    $perl -T ./check_hadoop_jmx.pl --all -P "$HADOOP_NAMENODE_PORT"
    hr
    echo "$perl -T ./check_hadoop_jmx.pl --all -P $HADOOP_DATANODE_PORT"
    $perl -T ./check_hadoop_jmx.pl --all -P "$HADOOP_DATANODE_PORT"
    hr
    echo "$perl -T ./check_hadoop_jmx.pl --all -P $HADOOP_YARN_RESOURCE_MANAGER_PORT"
    $perl -T ./check_hadoop_jmx.pl --all -P "$HADOOP_YARN_RESOURCE_MANAGER_PORT"
    hr
    echo "$perl -T ./check_hadoop_jmx.pl --all -P $HADOOP_YARN_NODE_MANAGER_PORT"
    $perl -T ./check_hadoop_jmx.pl --all -P "$HADOOP_YARN_NODE_MANAGER_PORT"
    hr
    echo "./check_hadoop_namenode_failed_namedirs.py"
    ./check_hadoop_namenode_failed_namedirs.py
    hr
    echo "./check_hadoop_namenode_failed_namedirs.py -v"
    ./check_hadoop_namenode_failed_namedirs.py -v
    hr
    echo "$perl -T ./check_hadoop_namenode_heap.pl"
    $perl -T ./check_hadoop_namenode_heap.pl
    hr
    echo "$perl -T ./check_hadoop_namenode_heap.pl --non-heap"
    $perl -T ./check_hadoop_namenode_heap.pl --non-heap
    hr
    echo "$perl -T ./check_hadoop_namenode_jmx.pl --all-metrics"
    $perl -T ./check_hadoop_namenode_jmx.pl --all-metrics
    hr
    # TODO: write replacement python plugins for this
    # XXX: Hadoop doesn't expose this information in the same way any more via dfshealth.jsp so this plugin is end of life with Hadoop 2.6
    # gets 404 not found
    if [ "$version" = "2.5" -o "$version" = "2.6" ]; then
        echo "$perl -T ./check_hadoop_namenode.pl -v --balance -w 5 -c 10"
        $perl -T ./check_hadoop_namenode.pl -v --balance -w 5 -c 10
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --hdfs-space"
        $perl -T ./check_hadoop_namenode.pl -v --hdfs-space
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --replication -w 10 -c 20"
        $perl -T ./check_hadoop_namenode.pl -v --replication -w 10 -c 20
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --datanode-blocks"
        $perl -T ./check_hadoop_namenode.pl -v --datanode-blocks
        hr
        echo "$perl -T ./check_hadoop_namenode.pl --datanode-block-balance -w 5 -c 20"
        $perl -T ./check_hadoop_namenode.pl --datanode-block-balance -w 5 -c 20
        hr
        echo "$perl -T ./check_hadoop_namenode.pl --datanode-block-balance -w 5 -c 20 -v"
        $perl -T ./check_hadoop_namenode.pl --datanode-block-balance -w 5 -c 20 -v
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --node-count -w 1 -c 1"
        $perl -T ./check_hadoop_namenode.pl -v --node-count -w 1 -c 1
        hr
        echo "checking node count (expecting warning < 2 nodes)"
        set +e
        echo "$perl -T ./check_hadoop_namenode.pl -v --node-count -w 2 -c 1"
        $perl -t ./check_hadoop_namenode.pl -v --node-count -w 2 -c 1
        check_exit_code 1
        hr
        echo "checking node count (expecting critical < 2 nodes)"
        echo "$perl -T ./check_hadoop_namenode.pl -v --node-count -w 2 -c 2"
        $perl -t ./check_hadoop_namenode.pl -v --node-count -w 2 -c 2
        check_exit_code 2
        set -e
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --node-list $hostname"
        $perl -T ./check_hadoop_namenode.pl -v --node-list $hostname
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 80 -c 90"
        $perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 80 -c 90
        hr
        echo "checking we can trigger warning on heap usage"
        set +e
        echo "$perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 1 -c 90"
        $perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 1 -c 90
        check_exit_code 1
        hr
        echo "checking we can trigger critical on heap usage"
        set +e
        echo "$perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 0 -c 1"
        $perl -T ./check_hadoop_namenode.pl -v --heap-usage -w 0 -c 1
        check_exit_code 2
        set -e
        hr
        echo "$perl -T ./check_hadoop_namenode.pl -v --non-heap-usage -w 80 -c 90"
        $perl -T ./check_hadoop_namenode.pl -v --non-heap-usage -w 80 -c 90
        hr
        # these won't trigger as NN has no max non-heap
#        echo "checking we can trigger warning on non-heap usage"
#        set +e
#        $perl -T ./check_hadoop_namenode.pl - P"$HADOOP_NAMENODE_PORT" -v --non-heap-usage -w 1 -c 90
#        check_exit_code 1
#        hr
#        echo "checking we can trigger critical on non-heap usage"
#        set +e
#        $perl -T ./check_hadoop_namenode.pl -P "$HADOOP_NAMENODE_PORT" -v --non-heap-usage -w 0 -c 1
#        check_exit_code 2
#        set -e
#        hr
    fi
    echo "$perl -T ./check_hadoop_namenode_safemode.pl"
    $perl -T ./check_hadoop_namenode_safemode.pl
    hr
    set +o pipefail
    echo "$perl -T ./check_hadoop_namenode_security_enabled.pl | grep -Fx "CRITICAL: namenode security enabled 'false'""
    $perl -T ./check_hadoop_namenode_security_enabled.pl | grep -Fx "CRITICAL: namenode security enabled 'false'"
    set -o pipefail
    hr
    echo "$perl -T ./check_hadoop_namenode_state.pl"
    $perl -T ./check_hadoop_namenode_state.pl
    hr
    echo "$perl -T ./check_hadoop_replication.pl"
    $perl -T ./check_hadoop_replication.pl
    hr
    # ================================================
    set +e
    echo "./check_hadoop_yarn_app_running.py -a '.*'"
    ./check_hadoop_yarn_app_running.py -a '.*'
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_app_running.py -a '.*' -v"
    ./check_hadoop_yarn_app_running.py -a '.*' -v
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_app_last_run.py -a '.*'"
    ./check_hadoop_yarn_app_last_run.py -a '.*'
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_app_last_run.py -a '.*' -v"
    ./check_hadoop_yarn_app_last_run.py -a '.*' -v
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_app_running.py -l"
    ./check_hadoop_yarn_app_running.py -l
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_app_last_run.py -l"
    ./check_hadoop_yarn_app_last_run.py -l
    check_exit_code 2
    hr
    echo "./check_hadoop_yarn_long_running_apps.py -l"
    ./check_hadoop_yarn_long_running_apps.py -l
    check_exit_code 3
    set -e
    hr
    echo "./check_hadoop_yarn_long_running_apps.py"
    ./check_hadoop_yarn_long_running_apps.py
    hr
    echo "./check_hadoop_yarn_long_running_apps.py -v"
    ./check_hadoop_yarn_long_running_apps.py -v
    hr
    # ================================================
    echo "Running sample mapreduce job to test Yarn application /job based plugins against:"
    docker exec -i "nagiosplugins_${DOCKER_SERVICE}_1" /bin/bash <<EOF &
    echo
    echo "running mapreduce job from sample jar"
    echo
    hadoop jar /hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar pi 5 20 &>/dev/null &
    echo
    echo "triggered mapreduce job"
    echo
    disown
    exit
EOF
    hr
    echo "waiting up to 20 secs for job to become available..."
    for x in {1..20}; do
        ./check_hadoop_yarn_app_running.py -a '.*' &>/dev/null && break
        sleep 1
    done
    hr
    set +e
    echo "Checking app listings while there is an app running:"
    echo
    echo
    echo "./check_hadoop_yarn_app_running.py -l"
    ./check_hadoop_yarn_app_running.py -l
    check_exit_code 3
    echo
    echo
    hr
    echo
    echo
    echo "./check_hadoop_yarn_long_running_apps.py -l"
    ./check_hadoop_yarn_long_running_apps.py -l
    check_exit_code 3
    set -e
    echo
    echo
    hr
    echo "./check_hadoop_yarn_app_running.py -a '.*' -v"
    ./check_hadoop_yarn_app_running.py -a '.*' -v
    hr
    echo "./check_hadoop_yarn_app_running.py -a 'monte.*carlo'"
    ./check_hadoop_yarn_app_running.py -a 'monte.*carlo'
    hr
    echo "./check_hadoop_yarn_long_running_apps.py --include=montecarlo"
    ./check_hadoop_yarn_long_running_apps.py --include=montecarlo | tee /dev/stderr | grep -q "checked 1 out of"
    hr
    echo "./check_hadoop_yarn_long_running_apps.py --include='te.*carl'"
    ./check_hadoop_yarn_long_running_apps.py --include='te.*carl' | tee /dev/stderr | grep -q "checked 1 out of"
    hr
    echo "./check_hadoop_yarn_long_running_apps.py --include=montecarlo --exclude=m.nte"
    ./check_hadoop_yarn_long_running_apps.py --include=montecarlo --exclude=m.nte | tee /dev/stderr | grep -q "checked 0 out of"
    hr
    echo "./check_hadoop_yarn_long_running_apps.py --exclude=quasi"
    ./check_hadoop_yarn_long_running_apps.py --exclude=quasi | tee /dev/stderr | grep -q "checked 0 out of"
    hr
    echo "waiting up to 60 secs for job to stop running"
    for x in {1..60}; do
        ./check_hadoop_yarn_app_running.py -a '.*' || break
        sleep 1
    done
    hr
    set +e
    echo "Checking listing app history:"
    echo
    echo
    echo "./check_hadoop_yarn_app_last_run.py -l"
    ./check_hadoop_yarn_app_last_run.py -l
    check_exit_code 3
    set -e
    echo "now testing last run status:"
    echo "./check_hadoop_yarn_app_last_run.py -a '.*' -v"
    ./check_hadoop_yarn_app_last_run.py -a '.*' -v
    hr
    echo "./check_hadoop_yarn_app_last_run.py -a montecarlo"
    ./check_hadoop_yarn_app_last_run.py -a montecarlo
    # ================================================
    hr
    echo "$perl -T ./check_hadoop_yarn_app_stats.pl"
    $perl -T ./check_hadoop_yarn_app_stats.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_app_stats_queue.pl"
    $perl -T ./check_hadoop_yarn_app_stats_queue.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_metrics.pl"
    $perl -T ./check_hadoop_yarn_metrics.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_node_manager.pl"
    $perl -T ./check_hadoop_yarn_node_manager.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_node_managers.pl -w 1 -c 1"
    $perl -T ./check_hadoop_yarn_node_managers.pl -w 1 -c 1
    hr
    echo "$perl -T ./check_hadoop_yarn_node_manager_via_rm.pl --node "$hostname""
    $perl -T ./check_hadoop_yarn_node_manager_via_rm.pl --node "$hostname"
    hr
    echo "$perl -T ./check_hadoop_yarn_queue_capacity.pl"
    $perl -T ./check_hadoop_yarn_queue_capacity.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_queue_capacity.pl --queue default"
    $perl -T ./check_hadoop_yarn_queue_capacity.pl --queue default
    hr
    echo "$perl -T ./check_hadoop_yarn_queue_state.pl"
    $perl -T ./check_hadoop_yarn_queue_state.pl
    hr
    echo "$perl -T ./check_hadoop_yarn_queue_state.pl --queue default"
    $perl -T ./check_hadoop_yarn_queue_state.pl --queue default
    hr
    echo "$perl -T ./check_hadoop_yarn_resource_manager_heap.pl"
    $perl -T ./check_hadoop_yarn_resource_manager_heap.pl
    hr
    # returns -1 for NonHeapMemoryUsage max
    set +e
    echo "$perl -T ./check_hadoop_yarn_resource_manager_heap.pl --non-heap"
    $perl -T ./check_hadoop_yarn_resource_manager_heap.pl --non-heap
    check_exit_code 3
    set -e
    hr
    echo "$perl -T ./check_hadoop_yarn_resource_manager_state.pl"
    $perl -T ./check_hadoop_yarn_resource_manager_state.pl
    hr
    #delete_container
    docker-compose down
    echo
    echo
}

run_test_versions Hadoop
