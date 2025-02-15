#!/bin/bash

replSetName=$1
secondaryNodes=$2
mongoAdminUser=$3
mongoAdminPasswd=$4
secondaryNodeOne=$5
secondaryNodeTwo=$6
staticIp=$7
inputArray=("$@")

#remove all non-ip values from array
ipAddresses=${inputArray[@]:5}

install_mongo3() {

#create repo
cat > /etc/yum.repos.d/mongodb-org-3.4.repo <<EOF
[mongodb-org-3.4]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/3.4/x86_64/
gpgcheck=0
enabled=1
EOF

	#install
	yum install -y mongodb-org

	#ignore update
	sed -i '$a exclude=mongodb-org,mongodb-org-server,mongodb-org-shell,mongodb-org-mongos,mongodb-org-tools' /etc/yum.conf

	#disable selinux
	sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
	sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
	setenforce 0

	#kernel settings
	if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]];then
		echo never > /sys/kernel/mm/transparent_hugepage/enabled
	fi
	if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]];then
		echo never > /sys/kernel/mm/transparent_hugepage/defrag
	fi

	#configure
	sed -i 's/\(bindIp\)/#\1/' /etc/mongod.conf
}

disk_format() {
	cd /tmp
	yum install wget -y
	for ((j=1;j<=3;j++))
	do
		wget https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/shared_scripts/ubuntu/vm-disk-utils-0.1.sh 
		if [[ -f /tmp/vm-disk-utils-0.1.sh ]]; then
			bash /tmp/vm-disk-utils-0.1.sh -b /var/lib/mongo -s
			if [[ $? -eq 0 ]]; then
				sed -i 's/disk1//' /etc/fstab
				umount /var/lib/mongo/disk1
				mount /dev/md0 /var/lib/mongo
			fi
			break
		else
			echo "download vm-disk-utils-0.1.sh failed. try again."
			continue
		fi
	done
		
}

install_mongo3
disk_format

#start mongod
mongod --dbpath /var/lib/mongo/ --logpath /var/log/mongodb/mongod.log --fork

sleep 30
ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep
n=$(ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep |wc -l)
echo "the number of mongod process is: $n"
if [[ $n -eq 1 ]];then
    echo "mongod started successfully"
else
    echo "Error: The number of mongod processes is 2+ or mongod failed to start because of the db path issue!"
fi

#create users
mongo <<EOF
use admin
db.createUser({user:"$mongoAdminUser",pwd:"$mongoAdminPasswd",roles:[{role: "userAdminAnyDatabase", db: "admin" },{role: "readWriteAnyDatabase", db: "admin" },{role: "root", db: "admin" }]})
exit
EOF
if [[ $? -eq 0 ]];then
    echo "mongo user added succeefully."
else
    echo "mongo user added failed!"
fi

#stop mongod
sleep 15
echo "the running mongo process id is below:"
ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep |awk '{print $2}'
MongoPid=`ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep |awk '{print $2}'`
kill -2 $MongoPid


#set keyfile
echo "vfr4CDE1" > /etc/mongokeyfile
chown mongod:mongod /etc/mongokeyfile
chmod 600 /etc/mongokeyfile
sed -i 's/^#security/security/' /etc/mongod.conf
sed -i '/^security/akeyFile: /etc/mongokeyfile' /etc/mongod.conf
sed -i 's/^keyFile/  keyFile/' /etc/mongod.conf

sleep 15
MongoPid1=`ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep |awk '{print $2}'`
if [[ -z $MongoPid1 ]];then
    echo "shutdown mongod successfully"
else
    echo "shutdown mongod failed!"
    kill $MongoPid1
    sleep 15
fi

#restart mongod with auth and replica set
mongod --dbpath /var/lib/mongo/ --replSet $replSetName --logpath /var/log/mongodb/mongod.log --fork --config /etc/mongod.conf

#initiate replica set
for((i=1;i<=3;i++))
    do
        sleep 15
        n=`ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep  |wc -l`
        if [[ $n -eq 1 ]];then
            echo "mongo replica set started successfully"
            break
        else
            mongod --dbpath /var/lib/mongo/ --replSet $replSetName --logpath /var/log/mongodb/mongod.log --fork --config /etc/mongod.conf
            continue
        fi
    done

n=`ps -ef |grep "mongod --dbpath /var/lib/mongo/" | grep -v grep  |wc -l`
if [[ $n -ne 1 ]];then
    echo "mongo replica set tried to start 3 times but failed!"
fi

#echo "start initiating the replica set"
#publicIp=`curl -s ip.cn|grep -Po '\d+.\d+.\d+.\d+'`
#if [[ -z $publicIp ]];then
#	finalIp=$staticIp
#else
#	finalIp=$publicIp
#fi


echo "start initiating the replica set"

#grab the last address in the array and set it as primary node's IP 
primaryNodeIp=${ipAddresses[-1]}
echo "the ip address is $primaryNodeIp"

#configure primary node
mongo<<EOF
use admin
db.auth("$mongoAdminUser", "$mongoAdminPasswd")
config ={_id:"$replSetName",members:[{_id:0,host:"$primaryNodeIp:27017"}]}
rs.initiate(config)
exit
EOF
if [[ $? -eq 0 ]];then
    echo "replica set initiation succeeded."
else
    echo "replica set initiation failed!"
fi


#add secondary nodes
for((i=0;i<$secondaryNodes;i++))
    do
        mongo -u "$mongoAdminUser" -p "$mongoAdminPasswd" "admin" --eval "printjson(rs.add('${ipAddresses[$i]}:27017'))"
        if [[ $? -eq 0 ]];then
            echo "adding server ${ipAddresses[$i]} successfully"
        else
            echo "adding server ${ipAddresses[$i]} failed!"
        fi
    done
	
	
#set mongod auto start
cat > /etc/init.d/mongod1 <<EOF
#!/bin/bash
#chkconfig: 35 84 15
#description: mongod auto start
. /etc/init.d/functions

Name=mongod1
start() {
if [[ ! -d /var/run/mongodb ]];then
mkdir /var/run/mongodb
chown -R mongod:mongod /var/run/mongodb
fi
mongod --dbpath /var/lib/mongo/ --replSet $replSetName --logpath /var/log/mongodb/mongod.log --fork --config /etc/mongod.conf
}
stop() {
pkill mongod
}
restart() {
stop
sleep 15
start
}

case "\$1" in 
    start)
	start;;
	stop)
	stop;;
	restart)
	restart;;
	status)
	status \$Name;;
	*)
	echo "Usage: service mongod1 start|stop|restart|status"
esac
EOF
chmod +x /etc/init.d/mongod1
chkconfig mongod1 on


