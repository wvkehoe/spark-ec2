#!/bin/bash

# Make sure we are in the spark-ec2 directory
cd /root/spark-ec2

source ec2-variables.sh

# Set hostname based on EC2 private DNS name, so that it is set correctly
# even if the instance is restarted with a different private DNS name
PRIVATE_DNS=`wget -q -O - http://instance-data.ec2.internal/latest/meta-data/local-hostname`
hostname $PRIVATE_DNS
echo $PRIVATE_DNS > /etc/hostname
HOSTNAME=$PRIVATE_DNS  # Fix the bash built-in hostname variable too

echo "Setting up slave on `hostname`..."

# Work around for R3 instances without pre-formatted ext3 disks
instance_type=$(curl http://169.254.169.254/latest/meta-data/instance-type 2> /dev/null)
if [[ $instance_type == r3* ]]; then
  # Format & mount using ext4, which has the best performance among ext3, ext4, and xfs based
  # on our shuffle heavy benchmark
  EXT4_MOUNT_OPTS="defaults,noatime,nodiratime"
  rm -rf /mnt*
  mkdir /mnt
  # To turn TRIM support on, uncomment the following line.
  #echo '/dev/sdb /mnt  ext4  defaults,noatime,nodiratime,discard 0 0' >> /etc/fstab
  mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdb
  mount -o $EXT4_MOUNT_OPTS /dev/sdb /mnt

  if [[ $instance_type == "r3.8xlarge" ]]; then
    mkdir /mnt2
    # To turn TRIM support on, uncomment the following line.
    #echo '/dev/sdc /mnt2  ext4  defaults,noatime,nodiratime,discard 0 0' >> /etc/fstab
    mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdc
    mount -o $EXT4_MOUNT_OPTS /dev/sdc /mnt2
  fi
fi

# Mount options to use for ext3 and xfs disks (the ephemeral disks
# are ext3, but we use xfs for EBS volumes to format them faster)
XFS_MOUNT_OPTS="defaults,noatime,nodiratime,allocsize=8m"

# Format and mount EBS volume (/dev/sdv) as /vol if the device exists
if [[ -e /dev/sdv ]]; then
  # Check if /dev/sdv is already formatted
  if ! blkid /dev/sdv; then
    mkdir /vol
    yum install -q -y xfsprogs
    if mkfs.xfs -q /dev/sdv; then
      mount -o $XFS_MOUNT_OPTS /dev/sdv /vol
      chmod -R a+w /vol
    else
      # mkfs.xfs is not installed on this machine or has failed;
      # delete /vol so that the user doesn't think we successfully
      # mounted the EBS volume
      rmdir /vol
    fi
  else
    # EBS volume is already formatted. Mount it if its not mounted yet.
    if ! grep -qs '/vol' /proc/mounts; then
      mkdir /vol
      mount -o $XFS_MOUNT_OPTS /dev/sdv /vol
      chmod -R a+w /vol
    fi
  fi
fi

# Make data dirs writable by non-root users, such as CDH's hadoop user
chmod -R a+w /mnt*

# Remove ~/.ssh/known_hosts because it gets polluted as you start/stop many
# clusters (new machines tend to come up under old hostnames)
rm -f /root/.ssh/known_hosts

# Create swap space on /mnt
/root/spark-ec2/create-swap.sh $SWAP_MB

# Allow memory to be over committed. Helps in pyspark where we fork
echo 1 > /proc/sys/vm/overcommit_memory

# Add github to known hosts to get git@github.com clone to work
# TODO(shivaram): Avoid duplicate entries ?
cat /root/spark-ec2/github.hostkey >> /root/.ssh/known_hosts
