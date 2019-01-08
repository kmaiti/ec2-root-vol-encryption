#!/bin/bash
#################################################################################################
#Purpose : To Encrypt root volume of aws ec2 instance. Assume it has one volume attached.       #
# Script will take input of instance ID and KMSID                                               #
# Developed By : kamal.maiti                                                                    #
#Prerequiste:                                                                                   #
# Binary required: jq , sed , aws cli, profile that has aws cli access.                         #
#INPUT: Single instance ID and KMSKEYID                                                         #
# Recommend: Run script in linux screen so that terminal timeout will not cause issue.          #
# Ref of screen: https://linoxide.com/linux-command/15-examples-screen-command-linux-terminal/  #
#################################################################################################
#color codes
red='\033[0;31m'
green='\033[0;32m'
nc='\033[0m'
bold=`tput bold`
normal=`tput sgr0`
#Change below profile
PROFILE=default
INSTANCETAG=
UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 9 | head -n 1)
TMPF="/tmp/$UUID"
KMSKEYID=
INSANCEID=
ENCRPSNAPSTATE=dummy
REGION=ap-south-1
VOLATTACHSTATE=dummy
INITIALINSTANCESTATE=dummy
INSTANCESTATE=dummy
ENCRYPTVOLSTATE=dummy
usage(){                                                        #Help function to provide details on how to use this script
echo -e "usage : $0 -i <instance-id> -k KMSID";
}

#Below function will show spinnig symbol while we'll be waiting for some operation.
spin() {
  secs=$1
  lvar=1
   local -a marks=( '/' '-' '\' '|' )
   while [[ $lvar -le $secs ]]; do
     printf '%s\r' "${marks[i++ % ${#marks[@]}]}"
     sleep 1
    ((lvar++))
   done
 }
#below are for taking command line inputs with arguments.

OPTIND=1                                                        #Intitialize OPTIND variable for getopts
FILE=""
items=
while getopts "hi:k:" FLAG                                      #Processing all arguments
   do
    case "$FLAG" in
        h|\?)
           usage
           exit 1
            ;;
        i)
           INSANCEID=$OPTARG                                    #Store filename
          ;;
                k)
        KMSKEYID=$OPTARG
          ;;
     esac
  done
eval set -- $items

#We start actual operaiton from here.
if [[ ! -z $INSANCEID && ! -z $KMSKEYID ]]; then
  #INSANCEID=<test val>
  #step 1. Get instance tag & attached root volume ID.
  INSTANCETAG=$(aws ec2 describe-instances --instance-ids $INSANCEID --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --profile $PROFILE|jq '.[][]'|sed 's/"//g')
  OLDVOLID=$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$INSANCEID --profile $PROFILE|jq '.Volumes[].VolumeId'|sed 's/"//g')

  
  #step 2. Stop ec2 instance now
  INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
  INITIALINSTANCESTATE=$INSTANCESTATE
  if [ $INSTANCESTATE == "running" ];then
    aws ec2 stop-instances --instance-ids $INSANCEID --profile $PROFILE  &> /dev/null
	while [ $INSTANCESTATE != "stopped" ]; do
      #Waiting for 30 seconds till ec2 is stopped.
      spin 20
       INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
    done
   echo -e "Instance $INSANCEID is stopped...${green}[OK]$nc"
  fi

    
  #step 3. Create snapshot of root volume.
  if [ ! -z ${OLDVOLID} ]; then
    #Some varilables are not being replaced directly, hence keep command in file and then execute file.
    echo "aws ec2 create-snapshot --volume-id $OLDVOLID --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=UNENCRYP-SNAP-$OLDVOLID}]' --profile $PROFILE" > $TMPF
    sh $TMPF &> /dev/null

  #step 4. Copy snapshot to same region and enable encryption using default KMS key
  #Get snapshot ID first using tag UNENCRYP-SNAP-$OLDVOLID
  echo "aws ec2 describe-snapshots --filters Name=tag:Name,Values=UNENCRYP-SNAP-$OLDVOLID --query "Snapshots[*].{ID:SnapshotId}" --profile $PROFILE" > $TMPF
  NEWSNAPID=$(sh $TMPF|jq '.[].ID'|sed 's/"//g')
  if [ ! -z $NEWSNAPID ]; then
    #check if snapshot status is completed or not.
    SNAPSTATE=$(aws ec2 describe-snapshots --snapshot-id $NEWSNAPID --profile $PROFILE|jq '.Snapshots[].State'|sed 's/"//g')
      while [ $SNAPSTATE != "completed" ]; do
        #generally for large volume, it takes time. so we put 60 secs for every api call.
        spin 60
            SNAPSTATE=$(aws ec2 describe-snapshots --snapshot-id $NEWSNAPID --profile $PROFILE|jq '.Snapshots[].State'|sed 's/"//g')
      done
        echo -e "Snapshot $NEWSNAPID is $SNAPSTATE...${green}[OK]$nc"
        #Start ec2 instance as snapshot is completed. You may keep ec2 as stopped but if machine needs to be used, then keep this line enabled.
		if [ $INITIALINSTANCESTATE == "running" ]; then 
           aws ec2 start-instances --instance-ids $INSANCEID --profile $PROFILE &> /dev/null
		   echo -e "Started $INSANCEID...[${green}OK${nc}]"
		fi

        #step 5. Start copying this snapshot with encryption enabled.
        echo "aws --region $REGION ec2 copy-snapshot --source-region $REGION --source-snapshot-id $NEWSNAPID  --encrypted --kms-key-id $KMSKEYID --description \"ENCRYP-SNAP-$OLDVOLID\" --profile $PROFILE" > $TMPF
    ENCRYPTEDSNAPID=$(sh $TMPF|jq '.SnapshotId'|sed 's/"//g')
        #tag encrypted snapshot. I kept it disabled as this API didn't work
    # aws ec2 create-tags --resources $ENCRYPTEDSNAPID --tags Key=Name,Value=ENCRYP-SNAP-$OLDVOLID --profile $PROFILE
        #Check if copy is completed or not.
    ENCRPSNAPSTATE=$(aws ec2 describe-snapshots --snapshot-id $ENCRYPTEDSNAPID --profile $PROFILE|jq '.Snapshots[].State'|sed 's/"//g')
    while [ $ENCRPSNAPSTATE != "completed" ]; do
      spin 60
          ENCRPSNAPSTATE=$(aws ec2 describe-snapshots --snapshot-id $ENCRYPTEDSNAPID --profile $PROFILE|jq '.Snapshots[].State'|sed 's/"//g')
    done
        echo -e "Copying Snapshot $ENCRYPTEDSNAPID is $ENCRPSNAPSTATE...[${green}OK$nc]"

  #step 6. Create new volume from encrypted snapshot
  #first get AZ of instance
  INSTANCEAZ=$(aws ec2 describe-instances --instance-ids $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].Placement.AvailabilityZone'|sed 's/"//g')
  #Create encrypted volume
   echo "aws ec2 create-volume --region $REGION --availability-zone $INSTANCEAZ --volume-type gp2 --snapshot-id $ENCRYPTEDSNAPID  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=ENCRYPTED_VOL_$INSTANCETAG}]'  --profile $PROFILE" > $TMPF
   ENCRPVOLID=$(sh $TMPF|jq '.VolumeId'|sed 's/"//g')
   ENCRYPTVOLSTATE=$(aws ec2 describe-volumes --volume-ids $ENCRPVOLID --profile $PROFILE|jq '.Volumes[].State'|sed 's/"//g')
     while [ $ENCRYPTVOLSTATE != "available" ]; do
       spin 60
           ENCRYPTVOLSTATE=$(aws ec2 describe-volumes --volume-ids $ENCRPVOLID --profile $PROFILE|jq '.Volumes[].State'|sed 's/"//g')
     done
   echo -e "New encrypted volume $ENCRPVOLID is available now...[${green}OK$nc]"

  #6. Stop instance if running and get state before unmounting old root volume.

  aws ec2 stop-instances --instance-ids $INSANCEID --profile $PROFILE &> /dev/null
  INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
    while [ $INSTANCESTATE != "stopped" ]; do
      spin 30
      INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
    done
   echo -e "$INSANCEID is stopped now. "
   #Detach old root volume now
   aws ec2 detach-volume --volume-id $OLDVOLID --profile $PROFILE   &> /dev/null
   #wait 30 secs for detachment 
   spin 30

   #Attach encrypted volume now. We have observed that sometime /dev/sda1 doesn't work while using amazon AMI. If so then change it to /dev/xvda  
   
   aws ec2 attach-volume --volume-id $ENCRPVOLID --instance-id $INSANCEID --device /dev/sda1 --profile $PROFILE  &> /dev/null
   #wait for 20 secs for attaching new vol. 
   spin 30
   VOLATTACHSTATE=$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$INSTANCEID --profile $PROFILE|jq '.Volumes[].Attachments[].State'|sed 's/"//g')
   echo -e "Encrypted volume $ENCRPVOLID is $VOLATTACHSTATE to $INSANCEID...[${green}OK${nc}]"
   
   #Start ec2 instance now if required
   if [ $INITIALINSTANCESTATE == "running" ]; then 
        aws ec2 start-instances --instance-ids $INSANCEID --profile $PROFILE  &> /dev/null
		echo -e "Starting $INSANCEID ..."
	   INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
       while [ $INSTANCESTATE != "running" ]; do
         spin 30
         INSTANCESTATE=$(aws ec2 describe-instances --instance-id $INSANCEID --profile $PROFILE|jq '.Reservations[].Instances[].State.Name'|sed 's/"//g')
      done
	  echo -e "Instance $INSANCEID is running now, operation is completed...[${green}OK$nc]"
	else 
      echo -e "Operation is completed...[${green}OK$nc]"	
	fi	  
  else
   echo -e "Got NULL snapshotID...[${red}FAILED$nc]"
  fi

else
  echo -e "Got NULL or invalid volume...[${red}FAILED$nc]"
  exit 1
fi

else
 echo -e "Instance ID or KMSID passed is NULL...[${red}FAILED$nc]"
fi

rm -f $TMPF
##################  END OF SCRIPT ################
